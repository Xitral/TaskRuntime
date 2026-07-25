# TaskRuntime

`TaskRuntime` provides cancellable scheduling and deterministic cleanup for Polytoria scripts.

## Files

- `scripts/modules/TaskRuntime.luau`: reusable ModuleScript.
- `scripts/server/script.server.luau`: server lifecycle bootstrap using a root cleanup scope.
- `tests/task-runtime.spec.luau`: manual Creator self-test.

In Creator, link `TaskRuntime.luau` as a `ModuleScript` named `TaskRuntime` under `ScriptService`. The server bootstrap expects it at `game["ScriptService"]["TaskRuntime"]`.

## Scheduler API

Every scheduled callback receives a cancellation token as its first argument. Any arguments supplied after the callback follow the token.

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])

local spawned = TaskRuntime.spawn(function(token, name)
	if token:IsCancelled() then
		return
	end
	print("Hello " .. name)
end, "world")

local deferred = TaskRuntime.defer(function(token)
	print("Runs on a later physics frame")
end)

local delayed = TaskRuntime.delay(10, function(token)
	print("Runs after ten seconds")
end)

TaskRuntime.cancel(delayed, "no longer needed")

local elapsed = TaskRuntime.wait(1)
print("Waited " .. tostring(elapsed) .. " seconds")
```

A task handle exposes:

- `Cancel(reason?)`
- `IsCancelled()`
- `IsCancellationRequested()`
- `IsDone()`
- `Await()`
- `Token`
- `State`, `Error`, `CancelReason`, results, and timing fields

Task states are:

- `scheduled`
- `running`
- `cancelling`
- `completed`
- `cancelled`
- `failed`

Pending tasks cancel immediately. Running tasks enter `cancelling` and remain active until their callback exits, so `Await()` and `getActiveCount()` do not report a task as finished while its code is still executing.

## Cooperative cancellation

Polytoria currently does not let game scripts forcibly terminate running coroutines. Long-running callbacks should periodically inspect their token and exit when cancellation is requested.

```luau
local worker = TaskRuntime.spawn(function(token)
	while not token:IsCancelled() do
		performOneWorkStep()
		TaskRuntime.wait(0)
	end
end)

worker:Cancel("system ended")
local success, reason = worker:Await()
```

For cancellable delays inside a running callback, use `token:Wait(seconds)`. It returns `false` early when cancellation is requested.

```luau
TaskRuntime.spawn(function(token)
	while token:Wait(1) do
		print("Still running")
	end
end)
```

The token exposes:

- `IsCancelled()`
- `GetReason()`
- `Wait(seconds, pollInterval?)`

## Cleanup scopes

A cleanup scope owns tasks, signal connections, child scopes, instances, and custom cleanup callbacks. Cleanup runs in reverse registration order.

```luau
local scope = TaskRuntime.scope("Round")

scope:Delay(30, function(token)
	endRound()
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

Completed, failed, and cancelled tasks automatically detach from their scope, preventing long-lived scopes from retaining old task handles. `scope:GetCount()` returns the number of resources the scope currently owns.

## Named resources

Use named resources when a system should replace or remove one specific resource without destroying its entire scope.

```luau
local roundScope = TaskRuntime.scope("Round")

roundScope:Set("RoundTimer", TaskRuntime.delay(60, function(token)
	endRound()
end))

-- Cancels and replaces the previous timer.
roundScope:Set("RoundTimer", TaskRuntime.delay(90, function(token)
	endRound()
end))

local currentTimer = roundScope:Get("RoundTimer")
print(roundScope:Has("RoundTimer"))

-- Removes and cancels it.
roundScope:Remove("RoundTimer")
```

Named-resource methods:

- `Set(key, resource, cleanupMethod?)`
- `Get(key)`
- `Has(key)`
- `Remove(key, shouldCleanup?, reason?)`

`Set` cleans an existing resource before replacing it. `Remove` cleans by default; pass `false` as its second argument to detach the resource without cleaning it.

## Debugging

```luau
print(TaskRuntime.getActiveCount())

for _, handle in ipairs(TaskRuntime.getActiveTasks()) do
	print(handle.Id, handle.Kind, handle.State)
end
```

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

## Verification

After linking the module, run `tests/task-runtime.spec.luau` manually in Creator. It verifies result forwarding, pending and running cancellation, cancellation-token behavior, automatic scope detachment, named resources, reverse-order cleanup, error handling, and task release.
