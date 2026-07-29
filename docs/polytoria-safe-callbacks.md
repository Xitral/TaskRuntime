# Polytoria-safe callbacks

`TaskRuntimePolytoriaSafe.luau` is an optional adapter for systems whose task callbacks yield frequently on current Polytoria engine builds.

## Why it exists

The normal TaskRuntime execution path protects callbacks with `pcall` so thrown errors become structured failed task outcomes. Current Polytoria builds execute a `pcall` callback in a nested Lua thread. Yielding from that nested thread can destabilize the process in some workloads.

Direct callback mode avoids that nested protected thread. The callback runs directly in TaskRuntime's scheduler-managed spawn thread, where `wait`, `token:Wait`, and task awaits follow the engine-supported yield path.

## Creator setup

Link both modules under `ScriptService`:

```text
ScriptService
├── TaskRuntime
└── TaskRuntimePolytoriaSafe
```

Require the adapter and create an isolated direct-mode runtime:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntimePolytoriaSafe"])
local runtime = TaskRuntime.createPolytoriaSafe()
```

The equivalent explicit form is:

```luau
local runtime = TaskRuntime.create({
	callbackMode = "direct",
})
```

## Example

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntimePolytoriaSafe"])
local runtime = TaskRuntime.createPolytoriaSafe()
local scope = runtime:scope("BoatPhysics")

scope:Every(0, function(token)
	updateBoatPhysics()
	token:Wait(0)
end)

function stopBoatPhysics()
	scope:Destroy("boat removed")
end
```

## Error behavior

Protected mode remains the default and is appropriate for callbacks that may throw. It converts errors into failed handles and invokes TaskRuntime's error handler.

Direct mode cannot safely provide that conversion without returning to the nested `pcall` path it is designed to avoid. In direct mode:

- callback errors escape the scheduler thread;
- a callback that throws may remain represented by a running handle;
- cleanup code placed after the throwing statement does not run automatically;
- `retry` is unavailable because it depends on catching callback failures.

Use direct mode only for controlled, yield-heavy loops. Validate data before scheduling, avoid assertions in the callback body, and keep cleanup owned by a `CleanupScope` whenever possible.

## Mixing modes

Modes belong to runtime instances, so one game can use both:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntimePolytoriaSafe"])

local protectedRuntime = TaskRuntime.create()
local physicsRuntime = TaskRuntime.createPolytoriaSafe()
```

The module-level helpers such as `TaskRuntime.spawn()` continue using the original protected default runtime. Existing projects therefore keep their current behavior unless they explicitly create a direct-mode runtime.

## Validation

Run `scripts/tests/task-runtime-polytoria-safe-test.server.luau` in Creator. A successful run prints:

```text
TaskRuntime Polytoria-safe adapter test passed
```
