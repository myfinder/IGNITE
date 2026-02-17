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
          -> agent server start
            -> leader start
              -> sub-leaders start (optional)
                -> ignitians start (optional)
                  -> runtime.yaml / sessions.yaml
                    -> watcher start (optional)
                      -> queue_monitor start
```

## Exclusive Resources (Contention Points)

- **Session management**
  - Agent server startup and shutdown must be serialized
- **Runtime directory**
  - `dashboard.md`, `runtime.yaml`, `state/`, etc. may conflict on concurrent writes
- **Log files**
  - Concurrent appends to `logs/*.log` have ordering dependencies and cannot be parallelized
- **Temporary files**
  - Naming collisions must be prevented when sharing `tmp/`

## Parallelizable Scope

- **Sub-Leaders / IGNITIANs startup**
  - opencode serve startup, health check waiting, and session creation can run in parallel

- **Watcher / queue_monitor startup**
  - Can be started in parallel once agent processes are established
  - However, writing initial log headers requires mutual exclusion

- **Cost tracking / session info recording**
  - Can be parallelized after `runtime.yaml` / `sessions.yaml` generation is complete

## Non-parallelizable Reasons and Exceptions

- **Before setup_workspace_config**
  - Parallelizing before config/runtime/instructions switching causes configuration conflicts

- **Before/after agent server start**
  - Agent server startup must be serialized as a single operation

- **dashboard.md initialization**
  - Initial generation must complete as a single operation and cannot be parallelized

- **Exceptions**
  - `--dry-run` mode does not start agent server/Watcher/Monitor, so parallelization is not applicable
  - `agent_mode=leader` excludes Sub-Leaders/IGNITIANs from the startup scope

## Notes (Operational Guidelines)

- Parallelization is limited to **after agent server startup and shared file initialization**
- Updates to logs/dashboard/state files should be consolidated through a **single write path**
