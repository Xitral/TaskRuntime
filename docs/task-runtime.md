# TaskRuntime

`TaskRuntime` is a structured asynchronous task and cleanup library for Polytoria Luau. It combines cancellable scheduling, bounded waiting, retries, task composition, production diagnostics, and deterministic resource cleanup.

## Why this is needed

Most game systems have a lifecycle. A round starts and ends. A player joins and leaves. A vehicle is spawned and destroyed. During that lifecycle, scripts often create delayed callbacks, repeating loops, signal connections, temporary instances, and child systems.

Without lifecycle ownership, old work can outlive the system that created it. Common results include:

- an old timer affecting a new round
- duplicate signal callbacks after a restart
- loops continuing after a player or vehicle is gone
- temporary instances remaining referenced
- old and new versions of a system running together
- increasing CPU work, memory use, and network traffic
- shutdown code that sometimes works and sometimes leaks

`TaskRuntime` gives each system an explicit cleanup scope. Everything registered with that scope can be cancelled, disconnected, destroyed, or otherwise cleaned when the system ends.

A scope only manages resources registered with it. Raw `spawn`, raw signal connections, and unregistered objects still require manual cleanup.

## Project files

- `scripts/modules/TaskRuntime.luau`: reusable ModuleScript
- `scripts/server/script.server.luau`: root server lifecycle example
- `scripts/tests/task-runtime-test.server.luau`: Creator self-test

In Creator, link `scripts/modules/TaskRuntime.luau` to a `ModuleScript` named `TaskRuntime` under `ScriptService`.

```text
ScriptService
├── TaskRuntime
├── script
└── task-runtime-test
```

Load it with:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
```

## Quick start

Create one scope for a system, register temporary work, then destroy the scope when the system ends.

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
local roundScope = TaskRuntime.scope("Round")

roundScope:Delay(60, function(token)
	if token:IsCancelled() then
		return
	end
	endRound()
end)

roundScope:Connect(game["Players"].PlayerAdded, function(player)
	print(player.Name .. " joined during the round")
end)

function stopRound()
	roundScope:Destroy("round ended")
end
```

When `stopRound()` runs, the pending timer is cancelled and the signal connection is disconnected.

## Task model

Every scheduled callback receives a `CancellationToken` as its first argument. Extra arguments follow the token.

```luau
local task = TaskRuntime.spawn(function(token, left, right)
	if token:IsCancelled() then
		return nil
	end
	return left + right
end, 2, 3)

local success, value = task:Await()
```

Task states are:

- `scheduled`
- `running`
- `cancelling`
- `completed`
- `cancelled`
- `failed`

Pending tasks cancel immediately. Running callbacks use cooperative cancellation. They enter `cancelling` and remain active until their code exits.

## Scheduling

```luau
TaskRuntime.spawn(callback, ...)
TaskRuntime.defer(callback, ...)
TaskRuntime.delay(seconds, callback, ...)
TaskRuntime.every(seconds, callback, ...)
```

`every()` waits one interval before its first run. Iterations never overlap. When a callback takes longer than its interval, missed intervals are counted in `SkippedIntervals` and skipped instead of replayed in a burst.

Passing `0` to `every()` runs once per physics frame. Keep frame-based callbacks small.

## Cancellation

```luau
local worker = TaskRuntime.spawn(function(token)
	while not token:IsCancelled() do
		performOneWorkStep()
		TaskRuntime.wait(0)
	end
end)

worker:Cancel("system ended")
worker:Await()
```

For cancellable waits inside a task:

```luau
if not token:Wait(5) then
	return
end
```

Immediate cancellation callbacks:

```luau
local connection = token:OnCancel(function(reason)
	print("Stopping because:", reason)
end)

connection:Disconnect()
```

`token:ThrowIfCancelled()` raises the cancellation reason when returning manually would make the code harder to read.

## Cancellation sources

A cancellation source is useful when several pieces of work should share one signal without belonging to a single task.

```luau
local source = TaskRuntime.cancellationSource()

TaskRuntime.spawn(function(token)
	while not source.Token:IsCancelled() do
		performBackgroundWork()
		TaskRuntime.wait(0)
	end
end)

source:Cancel("system stopped")
```

Link a source to a parent token:

```luau
local childSource = TaskRuntime.cancellationSource(parentToken)
```

Cancelling the parent cancels the child source with the same reason.

## Bounded waiting and timeouts

`Await(timeoutSeconds?)` can stop waiting without cancelling the task.

```luau
local success, result = task:Await(2)
if not success and result == "timeout" then
	warn("Task is still running")
end
```

Use `CancelAfter()` when the deadline should request cancellation:

```luau
worker:CancelAfter(5, "worker deadline")
```

Or create the task with a timeout:

```luau
local worker = TaskRuntime.withTimeout(5, function(token)
	while not token:IsCancelled() do
		performOneWorkStep()
		TaskRuntime.wait(0)
	end
end)
```

Timeout cancellation is cooperative. Code that ignores its token can continue running.

## Completion observers

`OnComplete()` reacts to completion without blocking.

```luau
local connection = task:OnComplete(function(handle)
	print(handle.Name, handle.State)
end)
```

The callback runs once. Registering after completion invokes it immediately and returns a disconnected connection.

## Names, metadata, and timing

```luau
local task = TaskRuntime.spawn(function(token)
	loadInventory()
end)

task:SetName("LoadInventory")
task:SetMetadata("playerID", player.UserID)

print(task:GetMetadata("playerID"))
print(task:GetElapsedTime())
```

Names and metadata appear in production snapshots.

## Retries

`retry()` reruns callbacks that throw. The callback receives the token, attempt number, then the original arguments.

```luau
local request = TaskRuntime.retry(4, function(token, attempt, playerID)
	return loadRemoteProfile(playerID)
end, {
	delaySeconds = 0.25,
	backoffFactor = 2,
	maxDelaySeconds = 2,
	shouldRetry = function(message, attempt)
		return string.find(message, "temporary", 1, true) ~= nil
	end,
	onRetry = function(message, attempt, nextDelay)
		warn("Retrying", attempt, nextDelay, message)
	end,
}, player.UserID)

local success, profile = request:Await(10)
```

A normal return is successful. Throw an error to request another attempt.

## Task composition

### Wait for all tasks

`TaskRuntime.all()` is fail-fast by default. A successful aggregate returns packed result arrays in input order.

```luau
local profileTask = TaskRuntime.spawn(function(token)
	return getProfile()
end)

local inventoryTask = TaskRuntime.spawn(function(token)
	return getInventory()
end)

local group = TaskRuntime.all({ profileTask, inventoryTask })
local success, results = group:Await(5)

if success then
	local profile = results[1][1]
	local inventory = results[2][1]
end
```

A failed or cancelled child fails the aggregate and cancels unfinished siblings. Pass `{ failFast = false }` to receive a structured outcome for every task.

### Use the first completed task

```luau
local race = TaskRuntime.race({ primaryRequest, fallbackRequest })
local success, winnerIndex, value = race:Await(3)
```

The unfinished losers are cancelled by default. Both composition functions support `cancelRemaining` and `cancelOnCancel` options.

## Cleanup scopes

A scope can own:

- tasks
- repeating tasks
- signal connections
- child scopes
- instances and other objects
- custom cleanup callbacks

Cleanup runs in reverse registration order.

```luau
local scope = TaskRuntime.scope("Boat")

scope:Spawn(function(token)
	while not token:IsCancelled() do
		updateBoatPhysics()
		TaskRuntime.wait(0)
	end
end)

scope:Connect(boat.Destroying, function()
	scope:Destroy("boat removed")
end)

scope:Add(function(reason)
	resetBoatForces(boat)
end)
```

When no cleanup method is supplied, a scope checks for these methods in order:

1. `Cancel`
2. `Disconnect`
3. `Cleanup`
4. `Destroy`
5. `Close`

You can provide an explicit method:

```luau
scope:Add(temporaryPart, "Destroy")
```

## Named resources

Named resources allow one item to be replaced without destroying the entire scope.

```luau
roundScope:Set("RoundTimer", TaskRuntime.delay(60, function(token)
	endRound()
end))

roundScope:Set("RoundTimer", TaskRuntime.delay(90, function(token)
	endRound()
end))
```

The second `Set` cancels and replaces the first timer.

```luau
local timer = roundScope:Get("RoundTimer")
local exists = roundScope:Has("RoundTimer")
roundScope:Remove("RoundTimer")
```

`Remove` cleans by default. Pass `false` as the second argument to detach without cleaning.

## Child scopes

```luau
local matchScope = TaskRuntime.scope("Match")
local roundScope = matchScope:Child("Round")
local effectsScope = roundScope:Child("Effects")
```

Destroying `matchScope` also destroys both child scopes.

Completed tasks and completed child scopes automatically detach from long-lived parents, preventing stale references.

## Scope supervision

A supervising scope can shut down its remaining resources when an owned task fails.

```luau
local systemScope = TaskRuntime.scope("InventorySystem", {
	cancelOnTaskFailure = true,
})

systemScope:Spawn(function(token)
	runInventoryWorker(token)
end):SetName("InventoryWorker")
```

Use `GetTaskFailures()` to inspect recorded failures.

## Cleanup errors

Cleanup continues after an individual resource fails. Every failure is recorded and sent to the cleanup error handler.

```luau
TaskRuntime.setCleanupErrorHandler(function(message, scope, record)
	warn("Cleanup failure", scope.Name, message)
end)
```

`DestroyAndAwait()` reports cleanup errors:

```luau
local success, reason, errors = scope:DestroyAndAwait("system stopped", 5)
```

When errors exist, it returns `false`, `"cleanup failed"`, and the error records. Use `GetCleanupErrors()` and `HasCleanupErrors()` to inspect them later.

## Destroy versus DestroyAndAwait

Use `Destroy()` to request cleanup without waiting:

```luau
scope:Destroy("boat removed")
```

Use `DestroyAndAwait()` when the next action must not begin until all owned tasks and child scopes have stopped:

```luau
local success, reason = scope:DestroyAndAwait("round ended", 5)
```

A timeout is recommended for production shutdown paths. Do not call `DestroyAndAwait()` from a task owned by the same scope because that task would wait for itself.

## Production diagnostics

```luau
local snapshot = TaskRuntime.getSnapshot()
print("Active tasks:", snapshot.ActiveCount)

for kind, count in pairs(snapshot.ByKind) do
	print(kind, count)
end

for _, task in ipairs(snapshot.Tasks) do
	print(task.Id, task.Name, task.State, task.Age)
end
```

Other helpers:

```luau
TaskRuntime.getActiveCount()
TaskRuntime.getActiveCount("retry")
TaskRuntime.getActiveTasks()
TaskRuntime.warnLongRunning(10)
```

## Error handling

Task callbacks run through `pcall`. Failed tasks enter `failed`, store their error in `handle.Error`, and invoke the global error handler.

```luau
TaskRuntime.setErrorHandler(function(message, handle)
	warn("Task failed", handle.Id, handle.Name, message)
end)
```

Restore defaults with:

```luau
TaskRuntime.setErrorHandler(nil)
TaskRuntime.setCleanupErrorHandler(nil)
```

## Common use cases

TaskRuntime is especially useful for:

- round and match lifecycles
- player-specific workers and autosaves
- vehicle controllers
- temporary effects
- replaceable cooldowns
- server maintenance loops
- network request deadlines
- parallel loading operations
- external calls that need retries
- systems that must shut down after one worker fails

## Root script lifecycle

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
local rootScope = TaskRuntime.scope("ServerRoot")

function Shutdown()
	rootScope:Destroy("server root shutdown")
end

function ShutdownAndAwait()
	return rootScope:DestroyAndAwait("server root shutdown", 5)
end

function _Dispose()
	Shutdown()
end
```

The current game runtime does not automatically invoke `_Dispose()`. Call `Shutdown()` or `ShutdownAndAwait()` explicitly through `BaseScript:Call()`.

Use `TaskRuntime.shutdown()` only when the entire runtime is ending. It cancels every active task and prevents new tasks from being scheduled for the rest of that session.

## Testing in Creator

The linked test is:

```text
scripts/tests/task-runtime-test.server.luau
```

Start a normal local playtest. A successful run prints:

```text
TaskRuntime industry-grade self-test passed
```

The self-test covers normal execution and intentional failure paths, including:

- argument and result forwarding
- pending and cooperative cancellation
- cancellation and completion observers
- bounded waits and timeouts
- linked cancellation sources
- retry policies and backoff
- `all()` and `race()` behavior
- automatic scope detachment
- named-resource replacement
- non-overlapping repeating tasks
- recursive awaited cleanup
- reverse cleanup order
- supervising scopes
- cleanup error aggregation
- diagnostic snapshots
- active-task release

Disable or remove the test `ServerScript` after verification so it does not run during ordinary development.

## API reference

### TaskRuntime

- `spawn(callback, ...)`
- `defer(callback, ...)`
- `delay(seconds, callback, ...)`
- `every(seconds, callback, ...)`
- `withTimeout(seconds, callback, ...)`
- `retry(attemptCount, callback, options?, ...)`
- `all(handles, options?)`
- `race(handles, options?)`
- `wait(seconds?)`
- `cancel(handle, reason?)`
- `isCancelled(handle)`
- `isDone(handle)`
- `getActiveCount(kind?)`
- `getActiveTasks()`
- `getSnapshot()`
- `warnLongRunning(thresholdSeconds)`
- `setErrorHandler(handler?)`
- `setCleanupErrorHandler(handler?)`
- `cancellationSource(parentToken?)`
- `shutdown(reason?)`
- `scope(name?, options?)`

### CancellationToken

- `IsCancelled()`
- `GetReason()`
- `Wait(seconds, pollInterval?)`
- `OnCancel(callback)`
- `ThrowIfCancelled()`

### CancellationSource

- `Cancel(reason?)`
- `IsCancelled()`
- `Destroy(reason?)`
- `Token`

### TaskHandle

- `SetName(name)`
- `SetMetadata(key, value)`
- `GetMetadata(key)`
- `GetElapsedTime()`
- `Cancel(reason?)`
- `CancelAfter(seconds, reason?)`
- `IsCancelled()`
- `IsCancellationRequested()`
- `IsDone()`
- `OnComplete(callback)`
- `Await(timeoutSeconds?)`

### CleanupScope

- `Add(resource, cleanupMethod?)`
- `Set(key, resource, cleanupMethod?)`
- `Get(key)`
- `Has(key)`
- `Remove(key, shouldCleanup?, reason?)`
- `Connect(signal, callback)`
- `Spawn(callback, ...)`
- `Defer(callback, ...)`
- `Delay(seconds, callback, ...)`
- `Every(seconds, callback, ...)`
- `WithTimeout(seconds, callback, ...)`
- `Retry(attemptCount, callback, options?, ...)`
- `Child(name?, options?)`
- `GetCount()`
- `GetTaskFailures()`
- `GetCleanupErrors()`
- `HasCleanupErrors()`
- `OnCleanupComplete(callback)`
- `IsDestroyed()`
- `IsCleanupComplete()`
- `Cleanup(reason?)`
- `Destroy(reason?)`
- `DestroyAndAwait(reason?, timeoutSeconds?)`
