#!/usr/bin/env python3
"""
=============================================================================
docker-tc (extended) - REST-controlled network emulation for one container
=============================================================================
Applies Linux `tc netem` rules to the CLIENT-FACING network interface of a
target container (by default: Caddy), so that a load generator experiences the
emulated bandwidth / delay / jitter / packet-loss of each network scenario.

Why a custom controller?
  * The upstream `lukaszlach/docker-tc` API supports rate/delay/loss/corrupt/
    duplicate but NOT jitter, and jitter is required by the methodology.
  * This server keeps the same REST convention:
        POST   /<container>   body: rate=10mbit&delay=100ms&jitter=15ms&loss=2.5%
        DELETE /<container>   clear all rules
        GET    /<container>   show the current qdisc
        GET    /health        liveness probe

How the rule is applied:
  1. Find the target container's PID with `docker inspect`.
  2. `nsenter -t <pid> -n` to enter ITS network namespace (so we never touch
     the host or the backend).
  3. Auto-detect the interface whose IPv4 address belongs to the emulated
     edge subnet (172.28.0.0/24) -- i.e. the k6-facing link, NOT the backend
     link. This keeps server-side traffic free of emulation.
  4. Replace the root qdisc with a single `netem` qdisc carrying delay, jitter,
     loss and rate.

This file is intentionally dependency-free (stdlib only) and Linux-only.
=============================================================================
"""

import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HTTP_BIND = os.environ.get("HTTP_BIND", "0.0.0.0")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "4080"))
DEFAULT_CONTAINER = os.environ.get("TARGET_CONTAINER", "caddy")
EDGE_SUBNET_PREFIX = os.environ.get("EDGE_SUBNET_PREFIX", "172.28.")
DEFAULT_IFACE = os.environ.get("TARGET_IFACE", "")

# ---- input validation (defense in depth; we never use a shell) -------------
VALUE_RE = re.compile(r"^[0-9]+(\.[0-9]+)?(bit|kbit|mbit|gbit|tbit|bps|kbps|mbps|gbps|tbps|%|s|sec|secs|ms|msec|msecs|us|usec|usecs)?$")


def _run(args):
    """Run a command, returning (returncode, stdout, stderr)."""
    proc = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def container_pid(name):
    rc, out, err = _run(["docker", "inspect", "-f", "{{.State.Pid}}", name])
    if rc != 0 or not out.isdigit() or out == "0":
        raise RuntimeError(f"cannot resolve PID for container '{name}': {err or out}")
    return out


def detect_interface(pid):
    """Return the target container's emulated (edge) interface name."""
    if DEFAULT_IFACE:
        return DEFAULT_IFACE

    rc, out, _ = _run(["nsenter", "-t", pid, "-n", "ip", "-o", "-4", "addr", "show"])
    if rc != 0:
        raise RuntimeError("failed to inspect interfaces inside target netns")

    for line in out.splitlines():
        # e.g. "3: eth0    inet 172.28.0.4/24 brd ..."
        match = re.search(r"^\d+:\s+([^:\s@]+).*?\sinet\s+(\d+\.\d+\.\d+\.\d+)/", line)
        if not match:
            continue
        iface, ip = match.group(1), match.group(2)
        if ip.startswith(EDGE_SUBNET_PREFIX):
            return iface

    # Fallback: first non-loopback interface.
    for line in out.splitlines():
        match = re.search(r"^\d+:\s+([^:\s@]+)", line)
        if match and match.group(1) != "lo":
            return match.group(1)

    raise RuntimeError("could not auto-detect an edge network interface")


def clear_rules(pid, iface):
    # Deleting a non-existent root qdisc returns an error; ignore it.
    _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "del", "dev", iface, "root"])


def show_qdisc(pid, iface):
    rc, out, err = _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "show", "dev", iface])
    return out if rc == 0 else err


def apply_rules(container, params):
    """Apply a netem qdisc described by `params` to the edge interface."""
    rate = (params.get("rate", [""])[0] or "").strip()
    delay = (params.get("delay", [""])[0] or "").strip()
    jitter = (params.get("jitter", [""])[0] or "").strip()
    loss = (params.get("loss", [""])[0] or "").strip()

    for label, value in (("rate", rate), ("delay", delay), ("jitter", jitter), ("loss", loss)):
        if value and not VALUE_RE.match(value):
            raise ValueError(f"invalid {label} value: {value!r}")

    pid = container_pid(container)
    iface = detect_interface(pid)
    clear_rules(pid, iface)

    netem = ["netem"]

    # delay [JITTER]; a bare 0 delay is rejected by tc, so only add when > 0.
    def as_number(text):
        if not text:
            return 0.0
        m = re.match(r"^[0-9]+(\.[0-9]+)?", text)
        return float(m.group(0)) if m else 0.0

    if as_number(delay) > 0:
        netem += ["delay", delay]
        if as_number(jitter) > 0:
            netem += [jitter]

    if as_number(loss) > 0:
        netem += ["loss", loss]

    # netem's built-in token-bucket rate limiter = bandwidth cap.
    if rate and rate != "0":
        netem += ["rate", rate]

    if len(netem) == 1:
        # Nothing to apply => unrestricted baseline.
        return {
            "container": container,
            "interface": iface,
            "applied": {},
            "qdisc": show_qdisc(pid, iface),
        }

    rc, out, err = _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "add",
                         "dev", iface, "root", "handle", "1:"] + netem)
    if rc != 0:
        raise RuntimeError(f"tc failed: {err or out}")

    qdisc = show_qdisc(pid, iface)
    if "netem" not in qdisc:
        raise RuntimeError("rule verification failed: netem qdisc not present")

    return {
        "container": container,
        "interface": iface,
        "applied": {"rate": rate, "delay": delay, "jitter": jitter, "loss": loss},
        "qdisc": qdisc,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "docker-tc-ext/1.0"

    # ---- helpers ----------------------------------------------------------
    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _target(self):
        path = urlparse(self.path).path.strip("/")
        if path in ("", "health", "list"):
            return path or DEFAULT_CONTAINER
        return path

    def log_message(self, fmt, *args):  # keep logs tidy
        sys.stderr.write("[docker-tc] " + fmt % args + "\n")

    # ---- routes -----------------------------------------------------------
    def do_GET(self):
        target = self._target()
        if target == "health":
            self._send(200, {"status": "ok"})
            return
        try:
            pid = container_pid(target)
            iface = detect_interface(pid)
            self._send(200, {
                "container": target,
                "interface": iface,
                "qdisc": show_qdisc(pid, iface),
            })
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"error": str(exc)})

    def do_POST(self):
        target = self._target()
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        params = parse_qs(raw)
        try:
            self._send(200, apply_rules(target, params))
        except Exception as exc:  # noqa: BLE001
            self._send(400, {"error": str(exc), "container": target})

    def do_DELETE(self):
        target = self._target()
        try:
            pid = container_pid(target)
            iface = detect_interface(pid)
            clear_rules(pid, iface)
            self._send(200, {
                "container": target,
                "interface": iface,
                "cleared": True,
                "qdisc": show_qdisc(pid, iface),
            })
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"error": str(exc)})

    def do_PUT(self):
        # API-compatibility no-op: re-enables management of the container.
        self._send(200, {"container": self._target(), "managed": True})


if __name__ == "__main__":
    server = ThreadingHTTPServer((HTTP_BIND, HTTP_PORT), Handler)
    print(f"[docker-tc] listening on {HTTP_BIND}:{HTTP_PORT}, default target='{DEFAULT_CONTAINER}'")
    server.serve_forever()
