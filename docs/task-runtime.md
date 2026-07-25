# TaskRuntime

`TaskRuntime` provides cancellable scheduling and deterministic cleanup for Polytoria scripts.

## Files

- `scripts/modules/TaskRuntime.luau`: reusable ModuleScript.
- `scripts/server/script.server.luau`: server lifecycle bootstrap using a root cleanup scope.
- `tests/task-runtime.spec.luau`: Creator self-test source.

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
- `Iterations` and `SkippedIntervals` for repeating tasks

Task states are `scheduled`, `running`, `cancelling`, `completed`, `cancelled`, and `failed`.

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

## Immediate cancellation callbacks

Use `token:OnCancel(callback)` when cleanup must happen as soon as cancellation is requested rather than during the next polling loop.

```luau
local worker = TaskRuntime.spawn(function(token)
	local connection = token:OnCancel(function(reason)
		print("Worker stopping:", reason)
	end)

	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)
```

`OnCancel` returns a connection with `Disconnect()`. It can be registered in a cleanup scope because the scope automatically recognizes the `Disconnect` method. Registering after cancellation invokes the callback immediately and returns an already-disconnected connection.

The token exposes:

- `IsCancelled()`
- `GetReason()`
- `Wait(seconds, pollInterval?)`
- `OnCancel(callback)`

## Repeating tasks

Use `TaskRuntime.every` or `scope:Every` for autosaves, regeneration, status updates, and other repeating work.

```luau
local autosave = TaskRuntime.every(30, function(token)
	savePlayers()
end)

-- Later:
autosave:Cancel("server shutting down")
autosave:Await()
```

A repeating task waits one interval before its first run. Iterations execute sequentially and never overlap. Its schedule remains anchored to the intended cadence; if a callback takes too long, missed intervals are counted in `SkippedIntervals` and skipped instead of replayed in a burst.

```luau
local scope = TaskRuntime.scope("Round")

local statusTask = scope:Every(1, function(token)
	updateRoundTimer()
end)
```

Passing `0` runs once per physics frame.

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

## Guaranteed awaited cleanup

`Destroy()` requests cleanup and returns immediately. `DestroyAndAwait()` waits until all directly owned tasks and all nested child scopes have actually finished cleaning up.

```luau
local success, reason = roundScope:DestroyAndAwait("round ended", 5)

if not success then
	warn("Round cleanup timed out:", reason)
end
```

The timeout is optional. Without it, the call waits indefinitely for every cooperative task to exit. With a timeout, it returns `false, "timeout"` if cleanup takes too long. `IsCleanupComplete()` reports whether the scope and all nested work are fully finished.

Do not call `DestroyAndAwait()` from a task owned by the same scope, because that task would be waiting for itself to finish. Request destruction from an external controller or use `Destroy()` inside the owned task.

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
	print(handle.Id, handle.Kind, handle.State, handle.Iterations)
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

function ShutdownAndAwait()
	return scope:DestroyAndAwait("script shutdown", 5)
end

function _Dispose()
	Shutdown()
end
```

The current game-side runtime does not automatically invoke `_Dispose()`. `Shutdown()` or `ShutdownAndAwait()` can be called explicitly with `BaseScript:Call()` today, while `_Dispose()` is already in place for a future engine lifecycle hook.

## Verification in Creator

Normal Creator builds cannot execute a loose `.luau` file directly. Create a temporary `ServerScript` under `ScriptService`, link it to a `.server.luau` file, copy in the contents of `tests/task-runtime.spec.luau`, then start a local playtest.

The test verifies result forwarding, pending and running cancellation, immediate cancellation callbacks, disconnected callbacks, automatic scope detachment, named resources, non-overlapping repeating tasks, recursive `DestroyAndAwait`, reverse-order cleanup, error handling, and task release. A successful run prints:

```text
TaskRuntime self-test passed
```
