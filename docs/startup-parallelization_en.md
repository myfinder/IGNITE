# Startup Flow Dependency Graph and Parallelization Scope

## Purpose

Document the dependency graph and exclusive resources of the startup flow, and clarify the scope and constraints of parallelization.

## Dependency Graph (Overview)

```
setup_workspace
  -> setup_workspace_config
    -> cli_load_config
      -> validate configs (optional)
        -> init runtime dirs/db/dashboard
          -> tmux session create
            -> leader start
              -> sub-leaders start (optional)
                -> ignitians start (optional)
                  -> runtime.yaml / sessions.yaml / costs
                    -> watcher start (optional)
                      -> queue_monitor start
```

## Exclusive Resources (Contention Points)

- **tmux session**
  - Pane creation and naming within a single session must be serialized
- **Runtime directory**
  - `dashboard.md`, `runtime.yaml`, `state/`, etc. may conflict on concurrent writes
- **Log files**
  - Concurrent appends to `logs/*.log` have ordering dependencies and cannot be parallelized
- **Temporary files**
  - Naming collisions must be prevented when sharing `tmp/`

## Parallelizable Scope

- **Sub-Leaders / IGNITIANs startup**
  - tmux pane creation must be serialized, but
    `cli_wait_tui_ready` / prompt injection after CLI launch can run in parallel

- **Watcher / queue_monitor startup**
  - Can be started in parallel once the tmux session is established
  - However, writing initial log headers requires mutual exclusion

- **Cost tracking / session info recording**
  - Can be parallelized after `runtime.yaml` / `sessions.yaml` generation is complete

## Non-parallelizable Reasons and Exceptions

- **Before setup_workspace_config**
  - Parallelizing before config/runtime/instructions switching causes configuration conflicts

- **Before/after tmux session create**
  - tmux session creation must be serialized as a single operation

- **dashboard.md initialization**
  - Initial generation must complete as a single operation and cannot be parallelized

- **Exceptions**
  - `--dry-run` mode does not start tmux/CLI/Watcher/Monitor, so parallelization is not applicable
  - `agent_mode=leader` excludes Sub-Leaders/IGNITIANs from the startup scope

## Notes (Operational Guidelines)

- Parallelization is limited to **after tmux pane creation and shared file initialization**
- Updates to logs/dashboard/state files should be consolidated through a **single write path**
