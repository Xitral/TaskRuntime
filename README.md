# TaskRuntime

TaskRuntime is a structured asynchronous task and lifecycle library for Polytoria Luau.

**Current release: 3.0.3**

Polytoria provides low-level primitives such as `spawn`, `wait`, and `pcall`. TaskRuntime builds a managed layer on top of them with cancellable task handles, timeouts, retries, task composition, bounded concurrency, cleanup scopes, diagnostics, and deterministic test scheduling.

## Highlights

- Cooperative cancellation with shared cancellation tokens
- Awaitable task handles with structured outcomes and errors
- `all`, `settle`, `race`, `any`, `Then`, `Catch`, and `Finally`
- Retries with backoff, jitter, filtering, and retry callbacks
- Semaphores, queues, `map`, and `mapLimit`
- Debounce and throttle helpers
- Cleanup scopes that own tasks, connections, instances, queues, and callbacks
- Cleanup deadlines and failure reporting
- Runtime snapshots, bounded history, and aggregated task statistics
- A virtual-time scheduler for deterministic tests
- Polytoria-specific handling for waits inside the engine's custom `pcall`

## Install

1. Download `TaskRuntime.luau` from a tagged GitHub release.
2. Link it in Creator as a `ModuleScript` named `TaskRuntime` under `ScriptService`.
3. Require it from your script.

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
```

The optional `TaskRuntimeTypes.luau` module provides exported types for editor tooling.

## Quick example

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])

local roundScope = TaskRuntime.scope("Round")

roundScope:Every(30, function(token)
	saveDirtyProfiles()
end)

roundScope:Delay(300, function(token)
	endRound()
end)

function stopRound()
	roundScope:Destroy("round ended")
end
```

Destroying the scope cancels its tasks and cleans every registered resource.

## Documentation

- [Complete guide](docs/task-runtime.md)
- [Copy-paste examples](docs/task-runtime-examples.md)
- [Contributing](CONTRIBUTING.md)
- [Release process](RELEASING.md)
- [Security policy](SECURITY.md)
- [Changelog](CHANGELOG.md)

## Validation

Run the repository checks:

```text
python3 tools/validate_release.py
python3 tools/build_release.py
```

For engine validation, sync these scripts into Creator and run them separately:

```text
scripts/tests/task-runtime-test.server.luau
scripts/tests/task-runtime-stress-test.server.luau
```

Successful runs print:

```text
TaskRuntime self-test passed
TaskRuntime stress test passed
```

## Compatibility notes

Cancellation is cooperative. A running callback must check its token or use `token:Wait()` to stop promptly.

TaskRuntime uses Polytoria's supported `wait` path for the default scheduler. Raw coroutine parking is only enabled for custom schedulers that explicitly declare support.

## Versioning

TaskRuntime follows semantic versioning. Public API removals or incompatible behavior changes require a major version update.

## License

MIT. See [LICENSE](LICENSE).
