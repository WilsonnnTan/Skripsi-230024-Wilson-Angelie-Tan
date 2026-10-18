# Automation Scripts Overview

The benchmark campaign is orchestrated entirely by bash and Python scripts located in the `scripts/` directory.

## Script Inventory

| Script | Language | Responsibility |
| --- | --- | --- |
| `run_experiments.sh` | Bash | Orchestrates the 150-run factorial experiment matrix |
| `export_results.sh` | Bash + PromQL | Queries Prometheus and outputs CSV result summaries |
| `set_network_scenario.sh` | Bash + cURL | Communicates with `docker-tc` to enforce network limits |
| `reset_network.sh` | Bash + cURL | Flushes active netem rules between runs |
| `wait_for_services.sh` | Bash | Health-checks services before beginning runs |
| `compute_percentiles.py` | Python 3 | Calculates p50, p90, p95, and p99 statistics from raw metrics |
| `scenarios.conf` | Configuration | Defines parameter values for scenarios S1 through S5 |

## Execution Workflow

```mermaid
flowchart TD
    START([Start Campaign]) --> WAIT[./scripts/wait_for_services.sh]
    WAIT --> LOOP[For each Protocol, Scenario, and Repetition]
    
    subgraph RunLifecycle ["Per-Run Lifecycle"]
        SET[Apply Scenario: set_network_scenario.sh] --> WARM[Warmup Phase 10s]
        WARM --> STEADY[Steady Measurement 60s]
        STEADY --> COOL[Cooldown Phase 10s]
        COOL --> RESET[Reset Network: reset_network.sh]
    end

    LOOP --> RunLifecycle
    RunLifecycle --> EXPORT[./scripts/export_results.sh]
    EXPORT --> COMPUTE[python3 compute_percentiles.py]
    COMPUTE --> END([Final CSVs Generated])
```
