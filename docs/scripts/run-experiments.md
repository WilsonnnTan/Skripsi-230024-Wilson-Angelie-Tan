# run_experiments.sh

`scripts/run_experiments.sh` is the master orchestration script that executes the 150-run experimental benchmark campaign.

## Campaign Matrix

The test matrix consists of:
- **3 Protocols**: HTTP/1.1 (`h1`), HTTP/2 (`h2`), HTTP/3 (`h3`)
- **5 Scenarios**: S1 (LAN baseline), S2 (High Latency WAN), S3 (Packet Loss), S4 (Constrained Bandwidth), S5 (Adverse Combined)
- **Total**: 3 × 5 × 10 = 150 runs.

## Usage

```bash
# Execute entire 150-run matrix
./scripts/run_experiments.sh

# Target specific protocol or scenario
PROTOCOL=h3 SCENARIO=S3 ./scripts/run_experiments.sh
```

## Internal Workflow

```mermaid
sequenceDiagram
    participant O as run_experiments.sh
    participant W as wait_for_services.sh
    participant TC as set_network_scenario.sh
    participant H as h2load Containers
    participant R as reset_network.sh

    O->>W: Verify all 7 containers are UP & healthy
    loop For each Protocol (h1, h2, h3)
        loop For each Scenario (S1..S5)
            loop 1..10 Repetitions
                O->>TC: POST /apply {scenario parameters}
                O->>H: Launch 10x h2load instances (80s duration)
                Note over H: 10s Warmup | 60s Steady-State | 10s Cooldown
                H-->>O: h2load containers complete
                O->>R: POST /reset (flush netem)
                O->>O: Sleep 5s (settling buffer)
            end
        end
    end
```

## Logging and Checkpoints

Each run writes its execution metadata and timestamps to `results/experiment_log.txt`:
```text
[2026-10-18 10:00:00] RUN 001/150: PROTO=h1 SCEN=S1 REP=01 START=1729245600 END=1729245680
[2026-10-18 10:01:25] RUN 002/150: PROTO=h1 SCEN=S1 REP=02 START=1729245685 END=1729245765
```
This checkpoint log enables recovery and deterministic time-window queries against Prometheus.
