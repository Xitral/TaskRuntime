# TaskRuntime

`TaskRuntime` is an asynchronous task and cleanup library for Polytoria Luau. It provides scheduling, cooperative cancellation, task composition, lifecycle scopes, bounded concurrency, cleanup deadlines, diagnostics, and deterministic virtual-time testing.

Current version:

```text
3.0.0
```

## Why this is needed

Most game systems create work that should only exist for part of the game session. Examples include:

- round timers
- player autosaves
- vehicle update loops
- temporary effects
- signal connections
- delayed callbacks
- background requests
- child systems

Without explicit ownership, old work can continue after the system that created it has ended. This can cause duplicate callbacks, stale timers, memory retention, extra physics work, repeated saves, and old systems interfering with new ones.

`TaskRuntime` gives that work an owner and a clear stopping path.

## What happens without it

Consider a round script that creates a delayed callback and a player connection every time a round starts. If the round restarts without cleaning those resources, every old callback and connection can remain active.

After several rounds, one player join may trigger several handlers and several old timers may end the wrong round. The bug appears to be random, but the actual cause is work surviving past its intended lifecycle.

A cleanup scope prevents that:

```luau
local roundScope = TaskRuntime.scope("Round")

roundScope:Delay(60, function(token)
	endRound()
end)

roundScope:Connect(game["Players"].PlayerAdded, function(player)
	print(player.Name, "joined")
end)

function stopRound()
	roundScope:Destroy("round ended")
end
```

Destroying the scope cancels the timer and disconnects the signal.

## Project files

- `scripts/modules/TaskRuntime.luau`: runtime module
- `scripts/modules/TaskRuntimeTypes.luau`: optional exported Luau types
- `scripts/server/script.server.luau`: server root example
- `scripts/tests/task-runtime-test.server.luau`: Creator self-test
- `docs/task-runtime.md`: main documentation
- `docs/task-runtime-examples.md`: copy-paste examples

## Creator setup

Link `scripts/modules/TaskRuntime.luau` to a `ModuleScript` named `TaskRuntime` under `ScriptService`.

```text
ScriptService
├── TaskRuntime
├── script
└── task-runtime-test
```

Load the module with:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
```

Check the installed version with:

```luau
print(TaskRuntime.VERSION)
```

## Compatibility

The existing APIs remain available:

```luau
TaskRuntime.spawn(callback, ...)
TaskRuntime.defer(callback, ...)
TaskRuntime.delay(seconds, callback, ...)
TaskRuntime.every(seconds, callback, ...)
TaskRuntime.wait(seconds?)
TaskRuntime.scope(name?, options?)
```

Existing task handles still support:

```luau
handle:Cancel(reason?)
handle:Await(timeoutSeconds?)
handle:IsDone()
handle:IsCancelled()
```

## Task callback convention

Every scheduled callback receives a `CancellationToken` as its first argument. Extra arguments follow it.

```luau
local task = TaskRuntime.spawn(function(token, left, right)
	if token:IsCancelled() then
		return
	end

	return left + right
end, 2, 3)
```

## Task states

A task can be in one of these states:

- `scheduled`
- `running`
- `cancelling`
- `completed`
- `cancelled`
- `failed`

Pending tasks cancel immediately. Running callbacks use cooperative cancellation. A running callback enters `cancelling` and remains active until its code exits.

## Scheduling

### Run immediately

```luau
local task = TaskRuntime.spawn(function(token)
	return loadPlayerData()
end)
```

### Run on a later scheduler step

```luau
TaskRuntime.defer(function(token)
	initializeAfterStartup()
end)
```

### Run after a delay

```luau
TaskRuntime.delay(5, function(token)
	print("Five seconds passed")
end)
```

### Repeat without overlap

```luau
local heartbeat = TaskRuntime.every(10, function(token)
	saveDirtyProfiles()
end)
```

The first run happens after one interval. Repeating callbacks never overlap. If a callback takes longer than its interval, missed runs are counted in `SkippedIntervals` and skipped instead of replayed in a burst.

## Cancellation

### Cancel a task

```luau
worker:Cancel("system ended")
```

### Check cancellation inside a callback

```luau
local worker = TaskRuntime.spawn(function(token)
	while not token:IsCancelled() do
		performOneStep()
		TaskRuntime.wait(0)
	end
end)
```

### Wait while remaining cancellable

```luau
if not token:Wait(5) then
	return
end
```

### React immediately to cancellation

```luau
local connection = token:OnCancel(function(reason)
	print("Stopping:", reason)
end)
```

### Throw when cancelled

```luau
token:ThrowIfCancelled()
```

## Cancellation sources

A cancellation source lets several operations share one cancellation signal.

```luau
local source = TaskRuntime.cancellationSource()

TaskRuntime.spawn(function(token)
	while not source.Token:IsCancelled() do
		performBackgroundWork()
		source.Token:Wait(1)
	end
end)

source:Cancel("feature disabled")
```

Link a child source to a parent token:

```luau
local childSource = TaskRuntime.cancellationSource(parentToken)
```

Cancelling the parent cancels the child source with the same reason.

## Waiting and outcomes

### Await a result

```luau
local success, value = task:Await(5)
```

`Await(5)` stops waiting after five seconds. It does not cancel the task.

### Read a structured outcome

```luau
local outcome = task:AwaitOutcome(5)

if outcome.Status == "completed" then
	print(outcome.Values[1])
elseif outcome.Status == "failed" then
	print(outcome.Error.Code, outcome.Error.Message)
elseif outcome.Status == "cancelled" then
	print(outcome.CancellationReason)
elseif outcome.Status == "timeout" then
	print("The task is still running")
end
```

Possible outcome statuses include:

- `completed`
- `failed`
- `cancelled`
- `timeout`

### Read an outcome without waiting

```luau
if task:IsDone() then
	local outcome = task:GetOutcome()
end
```

## Structured errors

Failed tasks expose both compatibility and structured fields:

```luau
print(task.Error)
print(task.ErrorInfo.Code)
print(task.ErrorInfo.Message)
print(task.ErrorInfo.TaskId)
print(task.ErrorInfo.TaskName)
print(task.ErrorInfo.TaskKind)
print(task.ErrorInfo.ParentTaskId)
print(task.ErrorInfo.ScopeName)
```

Common error codes include:

- `CALLBACK_FAILED`
- `AWAIT_TIMEOUT`
- `CHILD_TASK_FAILED`
- `RACE_WINNER_FAILED`
- `ALL_TASKS_FAILED`
- `CLEANUP_FAILED`
- `CLEANUP_TIMEOUT`
- `SCOPE_CLEANUP_TIMEOUT`

## Deadlines

### Cancel after a deadline

```luau
local deadline = worker:CancelAfter(5, "worker deadline")
```

The returned deadline handle supports:

```luau
deadline:Cancel()
deadline:Disconnect()
deadline:Destroy()
```

### Create a task with a timeout

```luau
local worker = TaskRuntime.withTimeout(5, function(token)
	while not token:IsCancelled() do
		performOneStep()
		token:Wait(0)
	end
end)
```

Timeout cancellation remains cooperative. A callback that ignores its token can continue running.

## Completion chains

### Then

Run a callback after successful completion:

```luau
local finalTask = loadTask:Then(function(token, profile)
	return buildInventory(profile)
end)
```

### Catch

Recover from a failed or cancelled source task:

```luau
local recovered = requestTask:Catch(function(token, taskError, cancellationReason, outcome)
	warn(taskError and taskError.Message or cancellationReason)
	return defaultValue
end)
```

### Finally

Run cleanup or logging after any terminal state:

```luau
local observed = task:Finally(function(token, outcome)
	print("Task finished with", outcome.Status)
end)
```

Each method returns a new `TaskHandle`.

## Retries

```luau
local request = TaskRuntime.retry(4, function(token, attempt, playerID)
	return loadRemoteProfile(playerID)
end, {
	delaySeconds = 0.25,
	backoffFactor = 2,
	maxDelaySeconds = 2,
	jitter = 0.1,
	shouldRetry = function(message, attempt)
		return string.find(message, "temporary", 1, true) ~= nil
	end,
	onRetry = function(message, attempt, nextDelay)
		warn("Retrying", attempt, nextDelay, message)
	end,
}, player.UserID)
```

The callback receives:

```text
token, attemptNumber, ...originalArguments
```

A normal return succeeds. Throw an error to request another attempt.

## Task composition

Composition is event-driven. Child completion callbacks wake the aggregate instead of each aggregate checking every physics frame.

### all

Wait for every task and preserve input order:

```luau
local group = TaskRuntime.all({ profileTask, inventoryTask })
local success, results = group:Await(5)

if success then
	local profile = results[1][1]
	local inventory = results[2][1]
end
```

By default, one failed or cancelled child fails the group and cancels unfinished siblings.

### settle

Wait for every task and receive every outcome:

```luau
local group = TaskRuntime.settle({ firstTask, secondTask })
local success, outcomes = group:Await(5)

for _, outcome in ipairs(outcomes) do
	print(outcome.Status)
end
```

### race

Use the first terminal task:

```luau
local race = TaskRuntime.race({ primaryTask, fallbackTask })
local success, winnerIndex, value = race:Await(3)
```

The unfinished losers are cancelled by default.

### any

Use the first successful task:

```luau
local any = TaskRuntime.any({ cacheTask, networkTask, fallbackTask })
local success, winnerIndex, value = any:Await(3)
```

Failed children are ignored until one task succeeds or every task fails.

## Mapping and bounded concurrency

### Map every item

```luau
local mapped = TaskRuntime.map(items, function(token, item, index)
	return processItem(item)
end)
```

### Limit simultaneous work

```luau
local mapped = TaskRuntime.mapLimit(items, 4, function(token, item, index)
	return processItem(item)
end)
```

Only four callbacks can hold a permit at one time.

## Semaphores

```luau
local semaphore = TaskRuntime.semaphore(3)

local acquired, reason = semaphore:Acquire(token, 2)
if not acquired then
	return
end

local succeeded, result = pcall(doExpensiveWork)
semaphore:Release()

if not succeeded then
	error(result)
end
```

Useful methods:

```luau
semaphore:GetWaitingCount()
semaphore:Acquire(token?, timeoutSeconds?)
semaphore:Release(count?)
semaphore:WithPermit(token?, callback, timeoutSeconds?, ...)
```

## Task queues

```luau
local queue = TaskRuntime.queue(3, {
	name = "ProfileSaves",
})

local saveTask = queue:Add(function(token, player)
	return savePlayer(player)
end, player)
```

Only three queued callbacks run at once.

```luau
queue:GetActiveCount()
queue:Close("server shutdown")
```

A queue can be registered with a cleanup scope:

```luau
local queue = TaskRuntime.queue(3, {
	name = "ProfileSaves",
	scope = serverScope,
})
```

## Debounce and throttle

### Debounce

Cancel previous pending work with the same key:

```luau
TaskRuntime.debounce(player.UserID, 0.5, function(token)
	savePlayer(player)
end)
```

### Throttle

Allow one leading call per time window:

```luau
local task, activeTask = TaskRuntime.throttle(player.UserID, 1, function(token)
	sendPositionUpdate(player)
end)

if task == nil then
	print("Suppressed. Existing task:", activeTask)
end
```

## Cleanup scopes

A scope can own:

- tasks
- repeating tasks
- signal connections
- child scopes
- queues
- instances
- cancellation sources
- custom cleanup callbacks

Cleanup uses reverse registration order.

```luau
local scope = TaskRuntime.scope("Vehicle")

scope:Every(0, function(token)
	updateVehicle()
end)

scope:Add(vehicleModel, "Destroy")

scope:Add(function(reason)
	resetVehicleForces()
end)
```

### Named resources

Replace one resource without destroying the entire scope:

```luau
scope:Set("RespawnTimer", TaskRuntime.delay(10, function(token)
	respawnPlayer()
end))
```

Replacing the same key cleans the previous resource first.

```luau
scope:Get("RespawnTimer")
scope:Has("RespawnTimer")
scope:Remove("RespawnTimer")
```

### Per-resource cleanup options

```luau
scope:Add(resource, {
	method = "Destroy",
	name = "TemporaryMap",
	timeout = 1,
})
```

The older form still works:

```luau
scope:Add(resource, "Destroy")
```

## Cleanup deadlines

Configure deadlines when one cleanup operation must not block the rest:

```luau
local scope = TaskRuntime.scope("Server", {
	cleanupTimeout = 5,
	resourceCleanupTimeout = 1,
})
```

A resource can override the default:

```luau
scope:Add(cache, {
	method = "Close",
	name = "ProfileCache",
	timeout = 2,
})
```

Timed-out cleanup is recorded while later resources continue cleaning.

```luau
local success, reason, errors = scope:DestroyAndAwait("shutdown", 6)
```

Possible cleanup codes include:

- `CLEANUP_FAILED`
- `CLEANUP_TIMEOUT`
- `CLEANUP_CANCELLED`
- `SCOPE_CLEANUP_TIMEOUT`
- `CHILD_CLEANUP_FAILED`

A timed-out callback cannot be forcefully terminated. Cancellation remains cooperative.

## Task contexts

A task context owns all work created through it. When the root callback exits, child work is cancelled and awaited.

```luau
local systemScope = TaskRuntime.scope("InventorySystem")

local rootTask = systemScope:Run(function(context, token, player)
	context:Every(30, function(childToken)
		saveInventory(player)
	end)

	context:Spawn(function(childToken)
		watchInventoryChanges(player, childToken)
	end)

	return loadInventory(player)
end, {
	name = "InventoryRoot",
	cancelOnChildFailure = true,
	childShutdownTimeout = 5,
}, player)
```

Context-created tasks inherit:

- parent cancellation
- parent task ID in diagnostics
- child scope ownership
- optional child failure cancellation

Context methods include:

```luau
context:Spawn(...)
context:Defer(...)
context:Delay(...)
context:Every(...)
context:WithTimeout(...)
context:Retry(...)
context:Child(...)
context:Cancel(...)
context:Close(...)
```

## Scope supervision

A scope can stop its remaining resources when an owned task fails:

```luau
local scope = TaskRuntime.scope("CriticalSystem", {
	cancelOnTaskFailure = true,
})
```

Inspect failures with:

```luau
local failures = scope:GetTaskFailures()
```

## Runtime diagnostics

### Active snapshot

```luau
local snapshot = TaskRuntime.getSnapshot()

print(snapshot.Version)
print(snapshot.ActiveCount)
print(snapshot.PeakActiveCount)
print(snapshot.PendingDeadlines)
```

Each active task includes:

- ID
- name
- kind
- state
- age
- elapsed time
- iteration count
- skipped interval count
- metadata
- parent task ID
- owning scope
- deadline
- optional creation trace

### Completed history

```luau
local history = TaskRuntime.getHistory()
```

History uses a bounded buffer.

### Aggregated statistics

```luau
local stats = TaskRuntime.getStats()
local saveStats = stats.SavePlayer

print(saveStats.Count)
print(saveStats.Completed)
print(saveStats.Failed)
print(saveStats.Cancelled)
print(saveStats.AverageDuration)
print(saveStats.MaxDuration)
```

### Configure diagnostics

```luau
TaskRuntime.configureDiagnostics({
	historySize = 200,
	captureCreationTrace = false,
})
```

Creation traces are optional because they add work and memory use.

### Warn about long-running work

```luau
TaskRuntime.warnLongRunning(10)
```

## Runtime instances

The module exports one default runtime, but isolated runtimes can also be created:

```luau
local runtime = TaskRuntime.create({
	historySize = 50,
})

local task = runtime:spawn(function(token)
	return 10
end)
```

Do not combine task handles from different runtime instances in `all`, `race`, `any`, or `settle`.

## Virtual-time testing

`TestScheduler` lets tests advance time without waiting in real time.

```luau
local scheduler = TaskRuntime.TestScheduler.new(0)
local runtime = TaskRuntime.create({
	scheduler = scheduler,
})

local delayed = runtime:delay(3600, function(token)
	return "one hour"
end)

scheduler:Advance(3600)

local success, value = delayed:Await()
```

Useful scheduler methods:

```luau
scheduler:Now()
scheduler:Spawn(callback)
scheduler:Sleep(seconds)
scheduler:Advance(seconds)
scheduler:RunReady()
scheduler:RunUntilIdle()
scheduler:GetErrors()
```

The Creator self-test remains the engine integration test. Virtual time is for deterministic module tests.

## Optional type definitions

`TaskRuntimeTypes.luau` exports types for editor tooling:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
local TaskRuntimeTypes = require(game["ScriptService"]["TaskRuntimeTypes"])

type TaskHandle = TaskRuntimeTypes.TaskHandle
type TaskOutcome = TaskRuntimeTypes.TaskOutcome
```

The runtime module remains usable without the type module.

## Error handlers

```luau
TaskRuntime.setErrorHandler(function(message, handle, taskError)
	warn(handle.Name, taskError.Code, message)
end)

TaskRuntime.setCleanupErrorHandler(function(message, scope, record)
	warn(scope.Name, record.Code, message)
end)
```

Restore defaults with:

```luau
TaskRuntime.setErrorHandler(nil)
TaskRuntime.setCleanupErrorHandler(nil)
```

## Root server lifecycle

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
local rootScope = TaskRuntime.scope("ServerRoot", {
	cleanupTimeout = 5,
	resourceCleanupTimeout = 1,
})

function Shutdown()
	rootScope:Destroy("server shutdown")
end

function ShutdownAndAwait()
	return rootScope:DestroyAndAwait("server shutdown", 6)
end

function _Dispose()
	Shutdown()
end
```

Use `TaskRuntime.shutdown()` only when the entire runtime is ending. It cancels every active task and prevents new work from being scheduled during that session.

## Testing in Creator

Link this file to a temporary `ServerScript`:

```text
scripts/tests/task-runtime-test.server.luau
```

Start a normal local playtest. A successful run prints:

```text
TaskRuntime self-test passed
```

The test covers:

- scheduling and results
- cooperative cancellation
- deadlines and timeout outcomes
- structured errors
- completion chains
- retries
- `all`, `settle`, `race`, and `any`
- semaphores and queues
- `mapLimit`
- debounce and throttle
- task contexts
- cleanup deadlines
- diagnostics and history
- virtual-time scheduling
- unknown option validation
- active task release

Remove or disable the test script after verification.

## API reference

### TaskRuntime and Runtime

- `VERSION`
- `create(options?)`
- `spawn(callback, ...)`
- `defer(callback, ...)`
- `delay(seconds, callback, ...)`
- `every(seconds, callback, ...)`
- `withTimeout(seconds, callback, ...)`
- `retry(attemptCount, callback, options?, ...)`
- `all(handles, options?)`
- `settle(handles)`
- `race(handles, options?)`
- `any(handles, options?)`
- `map(items, callback, options?)`
- `mapLimit(items, concurrency, callback, options?)`
- `wait(seconds?)`
- `cancel(handle, reason?)`
- `isCancelled(handle)`
- `isDone(handle)`
- `semaphore(limit)`
- `queue(concurrency, options?)`
- `debounce(key, seconds, callback, ...)`
- `throttle(key, seconds, callback, ...)`
- `scope(name?, options?)`
- `context(name?, options?)`
- `getActiveCount(kind?)`
- `getActiveTasks()`
- `getSnapshot()`
- `getHistory()`
- `getStats()`
- `configureDiagnostics(options?)`
- `warnLongRunning(thresholdSeconds)`
- `setErrorHandler(handler?)`
- `setCleanupErrorHandler(handler?)`
- `setWarningHandler(handler?)`
- `cancellationSource(parentToken?)`
- `shutdown(reason?)`

### TaskHandle

- `SetName(name)`
- `SetMetadata(key, value)`
- `GetMetadata(key)`
- `GetElapsedTime()`
- `GetOutcome()`
- `Cancel(reason?)`
- `CancelAfter(seconds, reason?)`
- `IsCancelled()`
- `IsCancellationRequested()`
- `IsDone()`
- `OnComplete(callback)`
- `Await(timeoutSeconds?)`
- `AwaitOutcome(timeoutSeconds?)`
- `Then(callback)`
- `Catch(callback)`
- `Finally(callback)`

### CancellationToken

- `IsCancelled()`
- `GetReason()`
- `ThrowIfCancelled()`
- `OnCancel(callback)`
- `Wait(seconds)`

### CleanupScope

- `Add(resource, cleanupMethod?, options?)`
- `Set(key, resource, cleanupMethod?, options?)`
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
- `Run(callback, options?, ...)`
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
