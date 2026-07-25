# TaskRuntime

`TaskRuntime` provides a cancellable scheduling API and deterministic resource cleanup for Polytoria scripts.

## Files

- `scripts/modules/TaskRuntime.luau`: reusable ModuleScript.
- `scripts/client/script.server.luau`: server lifecycle bootstrap using a root cleanup scope.

In Creator, link `TaskRuntime.luau` as a `ModuleScript` named `TaskRuntime` under `ScriptService`. The server bootstrap expects it at `game["ScriptService"]["TaskRuntime"]`.

## Scheduler API

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])

local spawned = TaskRuntime.spawn(function(name)
	print("Hello " .. name)
end, "world")

local deferred = TaskRuntime.defer(function()
	print("Runs on a later physics frame")
end)

local delayed = TaskRuntime.delay(10, function()
	print("Runs after ten seconds")
end)

TaskRuntime.cancel(delayed, "no longer needed")

local elapsed = TaskRuntime.wait(1)
print("Waited " .. tostring(elapsed) .. " seconds")
```

A task handle exposes:

- `Cancel(reason?)`
- `IsCancelled()`
- `IsDone()`
- `Await()`
- `State`, `Error`, `CancelReason`, and timing fields

Pending tasks are prevented from starting after cancellation. A callback that has already begun cannot be forcibly interrupted by game-side code; cancellation is cooperative until the engine exposes coroutine termination.

## Cleanup scopes

A cleanup scope owns tasks, signal connections, child scopes, instances, and custom cleanup callbacks. Cleanup runs in reverse registration order.

```luau
local scope = TaskRuntime.scope("Round")

scope:Delay(30, function()
	print("Round timeout")
end)

scope:Connect(game["Players"].PlayerAdded, function(player)
	print(player.Name)
end)

scope:Add(function()
	print("Custom cleanup")
end)

local childScope = scope:Child("RoundUI")

scope:Destroy("round ended")
```

`Add(resource, cleanupMethod?)` accepts:

- A cleanup callback.
- A resource plus a method name such as `"Destroy"`.
- A resource with an auto-detected `Cancel`, `Disconnect`, `Cleanup`, `Destroy`, or `Close` method.

## Script lifecycle

Use one root scope per long-running script:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
local scope = TaskRuntime.scope("MyScript")

function Shutdown()
	scope:Destroy("script shutdown")
end

function _Dispose()
	Shutdown()
end
```

The current game-side runtime does not automatically invoke `_Dispose()`. `Shutdown()` can be called explicitly with `BaseScript:Call()` today, while `_Dispose()` is already in place for a future engine lifecycle hook.
