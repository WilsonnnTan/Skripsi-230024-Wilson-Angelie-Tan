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
     edge subnet (172.28.0.0/24) -- i.e. the loader-facing link, NOT the backend
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
# Name of the per-netns ifb mirror device used for ingress (downlink) shaping.
IFB_DEV = os.environ.get("IFB_DEV", "ifb0")

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
    # Egress: delete the root qdisc (no-op/error if none exists -> ignored).
    _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "del", "dev", iface, "root"])
    # Ingress: delete the ingress qdisc that redirects into the ifb device.
    _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "del", "dev", iface, "ingress"])
    # Tear down the per-netns ifb mirror device, if we created one.
    _run(["nsenter", "-t", pid, "-n", "ip", "link", "set", IFB_DEV, "down"])
    _run(["nsenter", "-t", pid, "-n", "ip", "link", "del", IFB_DEV])


def show_qdisc(pid, iface):
    rc, out, err = _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "show", "dev", iface])
    eg = out if rc == 0 else err
    # Also surface the ifb (ingress) qdisc so callers can verify symmetry.
    rc2, out2, _ = _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "show", "dev", IFB_DEV])
    if rc2 == 0 and out2:
        return eg + " || ifb: " + out2
    return eg


def _as_number(text):
    if not text:
        return 0.0
    m = re.match(r"^[0-9]+(\.[0-9]+)?", text)
    return float(m.group(0)) if m else 0.0


def _netem_args(rate, delay, jitter, loss):
    """Build the trailing `netem ...` argv shared by egress and ingress."""
    netem = ["netem"]
    if _as_number(delay) > 0:
        netem += ["delay", delay]
        if _as_number(jitter) > 0:
            netem += [jitter]
    if _as_number(loss) > 0:
        netem += ["loss", loss]
    # netem's built-in token-bucket rate limiter = bandwidth cap.
    if rate and rate != "0":
        netem += ["rate", rate]
    return netem


def _setup_ingress(pid, iface, netem):
    """Shape the INGRESS of `iface` by mirroring it onto an ifb device.

    netem is egress-only, so to emulate the DOWNLINK (server->client responses
    arriving at this loader) we redirect ingress packets to an ifb device and
    apply the same netem there. Requires the host `ifb` kernel module (loaded at
    startup); if unavailable these commands fail and the error propagates.
    """
    # Create + bring up the ifb device inside the target netns.
    rc, out, err = _run(["nsenter", "-t", pid, "-n", "ip", "link", "add", IFB_DEV, "type", "ifb"])
    if rc != 0 and "File exists" not in (err or ""):
        raise RuntimeError(f"cannot create {IFB_DEV} (is the host 'ifb' module loaded?): {err or out}")
    rc, out, err = _run(["nsenter", "-t", pid, "-n", "ip", "link", "set", IFB_DEV, "up"])
    if rc != 0:
        raise RuntimeError(f"cannot bring up {IFB_DEV}: {err or out}")

    # Attach an ingress qdisc on the real iface and redirect everything to ifb.
    _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "add", "dev", iface, "handle", "ffff:", "ingress"])
    rc, out, err = _run(["nsenter", "-t", pid, "-n", "tc", "filter", "add", "dev", iface,
                         "parent", "ffff:", "protocol", "all", "u32",
                         "match", "u32", "0", "0",
                         "action", "mirred", "egress", "redirect", "dev", IFB_DEV])
    if rc != 0:
        raise RuntimeError(f"ingress redirect to {IFB_DEV} failed: {err or out}")

    # Apply netem on the ifb device = the emulated downlink.
    rc, out, err = _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "add",
                         "dev", IFB_DEV, "root", "handle", "1:"] + netem)
    if rc != 0:
        raise RuntimeError(f"ifb netem failed: {err or out}")


def apply_rules(container, params):
    """Apply a netem qdisc described by `params` to the edge interface.

    `direction` selects which link(s) are shaped:
      both    (default) -> egress + ingress (full symmetric per-client link)
      egress            -> client->server uplink only
      ingress           -> server->client downlink only
    """
    rate = (params.get("rate", [""])[0] or "").strip()
    delay = (params.get("delay", [""])[0] or "").strip()
    jitter = (params.get("jitter", [""])[0] or "").strip()
    loss = (params.get("loss", [""])[0] or "").strip()
    direction = (params.get("direction", ["both"])[0] or "both").strip().lower()

    for label, value in (("rate", rate), ("delay", delay), ("jitter", jitter), ("loss", loss)):
        if value and not VALUE_RE.match(value):
            raise ValueError(f"invalid {label} value: {value!r}")
    if direction not in ("both", "egress", "ingress"):
        raise ValueError(f"invalid direction: {direction!r}")

    pid = container_pid(container)
    iface = detect_interface(pid)
    clear_rules(pid, iface)

    netem = _netem_args(rate, delay, jitter, loss)

    if len(netem) == 1:
        # Nothing to apply => unrestricted baseline.
        return {
            "container": container,
            "interface": iface,
            "direction": direction,
            "applied": {},
            "qdisc": show_qdisc(pid, iface),
        }

    if direction in ("both", "egress"):
        rc, out, err = _run(["nsenter", "-t", pid, "-n", "tc", "qdisc", "add",
                             "dev", iface, "root", "handle", "1:"] + netem)
        if rc != 0:
            raise RuntimeError(f"egress tc failed: {err or out}")

    if direction in ("both", "ingress"):
        _setup_ingress(pid, iface, netem)

    qdisc = show_qdisc(pid, iface)
    if "netem" not in qdisc:
        raise RuntimeError("rule verification failed: netem qdisc not present")

    return {
        "container": container,
        "interface": iface,
        "direction": direction,
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
    # Ingress (downlink) shaping mirrors traffic onto an ifb device, which needs
    # the host 'ifb' kernel module. docker-tc runs privileged in the host PID +
    # net namespaces, so load it once here; symmetric shaping fails loudly later
    # if the WSL2/host kernel has no ifb module.
    rc, _out, err = _run(["modprobe", "ifb", "numifbs=0"])
    if rc == 0:
        print("[docker-tc] ifb kernel module loaded (ingress shaping available)")
    else:
        print(f"[docker-tc] WARNING: could not load ifb module: {err} "
              "(direction=ingress/both will fail)")

    server = ThreadingHTTPServer((HTTP_BIND, HTTP_PORT), Handler)
    print(f"[docker-tc] listening on {HTTP_BIND}:{HTTP_PORT}, default target='{DEFAULT_CONTAINER}'")
    server.serve_forever()
