# TaskRuntime Examples

This guide contains copy-paste patterns for common Polytoria systems. Replace placeholder functions such as `savePlayer`, `loadProfile`, and `updateBoatPhysics` with your own game code.

All examples assume:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
```

## 1. Run work immediately

```luau
local task = TaskRuntime.spawn(function(token)
	print("Task started")
	return 25
end)

local success, value = task:Await()
if success then
	print("Result:", value)
end
```

## 2. Pass arguments and return multiple values

```luau
local calculation = TaskRuntime.spawn(function(token, left, right)
	return left + right, left * right
end, 4, 6)

local success, sum, product = calculation:Await()
if success then
	print("Sum:", sum)
	print("Product:", product)
end
```

## 3. Run work later

```luau
TaskRuntime.defer(function(token)
	print("Runs on a later scheduler step")
end)
```

## 4. Run after a delay

```luau
local reminder = TaskRuntime.delay(10, function(token, player)
	showReminder(player)
end, player)
```

## 5. Cancel a pending delay

```luau
local delayedExplosion = TaskRuntime.delay(5, function(token)
	explodeBomb()
end)

delayedExplosion:Cancel("bomb defused")
```

## 6. Repeat without overlap

```luau
local autosave = TaskRuntime.every(30, function(token)
	saveDirtyProfiles()
end)
```

## 7. Run once per physics frame

```luau
local updater = TaskRuntime.every(0, function(token)
	updateVehiclePhysics()
end)
```

Keep frame callbacks small.

## 8. Stop a repeating task

```luau
autosave:Cancel("server stopping")
autosave:Await(2)
```

## 9. Cooperative worker loop

```luau
local worker = TaskRuntime.spawn(function(token)
	while not token:IsCancelled() do
		processOneQueueItem()
		TaskRuntime.wait(0)
	end
end)
```

## 10. Cancellable sleep

```luau
local worker = TaskRuntime.spawn(function(token)
	print("Waiting")

	if not token:Wait(5) then
		print("Cancelled before five seconds")
		return
	end

	print("Five seconds passed")
end)
```

## 11. Cancellation callback

```luau
local worker = TaskRuntime.spawn(function(token)
	local connection = token:OnCancel(function(reason)
		print("Worker cancellation requested:", reason)
	end)

	while not token:IsCancelled() do
		token:Wait(0)
	end
end)
```

## 12. Shared cancellation source

```luau
local source = TaskRuntime.cancellationSource()

TaskRuntime.spawn(function(token)
	while not source.Token:IsCancelled() do
		updateMapMarkers()
		source.Token:Wait(1)
	end
end)

TaskRuntime.spawn(function(token)
	while not source.Token:IsCancelled() do
		updateQuestArrows()
		source.Token:Wait(1)
	end
end)

source:Cancel("HUD closed")
```

## 13. Linked cancellation source

```luau
local function runChildWork(parentToken)
	local childSource = TaskRuntime.cancellationSource(parentToken)

	TaskRuntime.spawn(function(token)
		while not childSource.Token:IsCancelled() do
			performChildStep()
			childSource.Token:Wait(0)
		end
	end)

	return childSource
end
```

## 14. Await with a timeout

```luau
local success, value = loadTask:Await(3)

if not success and value == "timeout" then
	warn("Load is still running")
end
```

The task is not cancelled by the wait timeout.

## 15. Read a structured outcome

```luau
local outcome = loadTask:AwaitOutcome(3)

if outcome.Status == "completed" then
	local profile = outcome.Values[1]
	useProfile(profile)
elseif outcome.Status == "failed" then
	warn(outcome.Error.Code, outcome.Error.Message)
elseif outcome.Status == "cancelled" then
	warn("Cancelled:", outcome.CancellationReason)
elseif outcome.Status == "timeout" then
	warn("Still running")
end
```

## 16. Cancel after a deadline

```luau
local worker = TaskRuntime.spawn(function(token)
	while not token:IsCancelled() do
		doExpensiveWork()
		token:Wait(0)
	end
end)

worker:CancelAfter(5, "worker deadline")
```

## 17. Task with a timeout

```luau
local request = TaskRuntime.withTimeout(4, function(token)
	return performRequest(token)
end)
```

## 18. Observe completion without blocking

```luau
local connection = request:OnComplete(function(handle)
	print(handle.Name, handle.State)
end)
```

## 19. Name and tag tasks

```luau
local task = TaskRuntime.spawn(function(token)
	return savePlayer(player)
end)

task:SetName("SavePlayer")
task:SetMetadata("playerID", player.UserID)
task:SetMetadata("reason", "autosave")
```

## 20. Transform a successful result

```luau
local inventoryTask = loadProfileTask:Then(function(token, profile)
	return buildInventory(profile)
end)
```

## 21. Recover from a failure

```luau
local safeTask = remoteLoadTask:Catch(function(token, taskError, cancellationReason)
	warn(taskError and taskError.Message or cancellationReason)
	return createDefaultProfile()
end)
```

## 22. Always run final logic

```luau
local observedTask = requestTask:Finally(function(token, outcome)
	setLoadingIconVisible(false)
	print("Request ended with", outcome.Status)
end)
```

## 23. Retry a temporary operation

```luau
local saveTask = TaskRuntime.retry(4, function(token, attempt, player)
	return savePlayer(player)
end, {
	delaySeconds = 0.25,
	backoffFactor = 2,
	maxDelaySeconds = 2,
	jitter = 0.1,
	shouldRetry = function(message, attempt)
		return string.find(message, "temporary", 1, true) ~= nil
	end,
	onRetry = function(message, attempt, nextDelay)
		warn("Save retry", attempt, nextDelay, message)
	end,
}, player)
```

## 24. Load two systems in parallel

```luau
local profileTask = TaskRuntime.spawn(function(token)
	return loadProfile(player)
end)

local inventoryTask = TaskRuntime.spawn(function(token)
	return loadInventory(player)
end)

local group = TaskRuntime.all({ profileTask, inventoryTask })
local success, results = group:Await(5)

if success then
	local profile = results[1][1]
	local inventory = results[2][1]
	startPlayer(player, profile, inventory)
end
```

## 25. Collect every outcome

```luau
local group = TaskRuntime.settle({ firstTask, secondTask, thirdTask })
local success, outcomes = group:Await(5)

for index, outcome in ipairs(outcomes) do
	print(index, outcome.Status)
end
```

## 26. Use the fastest request

```luau
local primary = TaskRuntime.spawn(function(token)
	return loadFromPrimary(token)
end)

local mirror = TaskRuntime.spawn(function(token)
	return loadFromMirror(token)
end)

local fastest = TaskRuntime.race({ primary, mirror })
local success, winnerIndex, value = fastest:Await(3)
```

## 27. Use the first successful source

```luau
local cacheTask = TaskRuntime.spawn(function(token)
	return loadFromCache()
end)

local networkTask = TaskRuntime.spawn(function(token)
	return loadFromNetwork()
end)

local fallbackTask = TaskRuntime.spawn(function(token)
	return createFallbackData()
end)

local firstSuccess = TaskRuntime.any({ cacheTask, networkTask, fallbackTask })
local success, winnerIndex, value = firstSuccess:Await(5)
```

## 28. Process an array in parallel

```luau
local task = TaskRuntime.map(parts, function(token, part, index)
	return calculatePartData(part)
end)
```

## 29. Limit expensive parallel work

```luau
local task = TaskRuntime.mapLimit(npcs, 4, function(token, npc, index)
	return calculatePath(npc)
end)
```

Only four callbacks run inside the protected section at once.

## 30. Limit profile saves with a semaphore

```luau
local saveSemaphore = TaskRuntime.semaphore(3)

local function saveWithLimit(token, player)
	local acquired, reason = saveSemaphore:Acquire(token, 2)
	if not acquired then
		return false, reason
	end

	local succeeded, result = pcall(savePlayer, player)
	saveSemaphore:Release()

	if not succeeded then
		error(result)
	end

	return true
end
```

## 31. Use `WithPermit`

```luau
local success, result = semaphore:WithPermit(token, function(player)
	return savePlayer(player)
end, 2, player)
```

## 32. Create a bounded work queue

```luau
local saveQueue = TaskRuntime.queue(3, {
	name = "ProfileSaves",
})

local task = saveQueue:Add(function(token, player)
	return savePlayer(player)
end, player)
```

## 33. Close a queue

```luau
saveQueue:Close("server shutdown")
```

Pending and running queue tasks receive cancellation.

## 34. Debounce repeated saves

```luau
local function requestSave(player)
	return TaskRuntime.debounce(player.UserID, 0.5, function(token)
		return savePlayer(player)
	end)
end
```

Every new call inside the window cancels the previous pending save.

## 35. Throttle network updates

```luau
local function sendPosition(player)
	local task, existingTask = TaskRuntime.throttle(player.UserID, 0.1, function(token)
		return sendPositionUpdate(player)
	end)

	if task == nil then
		return existingTask
	end

	return task
end
```

## 36. Basic cleanup scope

```luau
local scope = TaskRuntime.scope("Round")

scope:Delay(60, function(token)
	endRound()
end)

scope:Every(5, function(token)
	updateRoundUI()
end)

scope:Add(function(reason)
	clearRoundState()
end)
```

## 37. Clean a signal connection

```luau
scope:Connect(game["Players"].PlayerAdded, function(player)
	addPlayerToRound(player)
end)
```

## 38. Clean an instance

```luau
local temporaryPart = createTemporaryPart()
scope:Add(temporaryPart, "Destroy")
```

## 39. Resource options

```luau
scope:Add(profileCache, {
	method = "Close",
	name = "ProfileCache",
	timeout = 2,
})
```

## 40. Replace a named timer

```luau
roundScope:Set("RoundTimer", TaskRuntime.delay(60, function(token)
	endRound()
end))

roundScope:Set("RoundTimer", TaskRuntime.delay(90, function(token)
	endRound()
end))
```

The second call cancels the first timer.

## 41. Remove a named resource

```luau
local timer = roundScope:Remove("RoundTimer")
```

Pass `false` as the second argument to detach without cleaning:

```luau
local timer = roundScope:Remove("RoundTimer", false)
```

## 42. Child scopes

```luau
local matchScope = TaskRuntime.scope("Match")
local roundScope = matchScope:Child("Round")
local effectsScope = roundScope:Child("Effects")
```

Destroying `matchScope` destroys both descendants.

## 43. Player lifecycle scope

```luau
local playerScopes = {}

local function startPlayer(player)
	local scope = TaskRuntime.scope("Player:" .. tostring(player.UserID), {
		cleanupTimeout = 5,
		resourceCleanupTimeout = 1,
	})
	playerScopes[player] = scope

	scope:Every(30, function(token)
		savePlayer(player)
	end)

	scope:Spawn(function(token)
		while not token:IsCancelled() do
			updatePlayerState(player)
			token:Wait(0)
		end
	end)
end

local function stopPlayer(player)
	local scope = playerScopes[player]
	playerScopes[player] = nil

	if scope ~= nil then
		scope:Destroy("player left")
	end
end
```

## 44. Round lifecycle

```luau
local currentRoundScope = nil

local function startRound()
	if currentRoundScope ~= nil then
		currentRoundScope:Destroy("round replaced")
	end

	local scope = TaskRuntime.scope("Round")
	currentRoundScope = scope

	scope:Delay(120, function(token)
		finishRound()
	end)

	scope:Every(1, function(token)
		updateRoundClock()
	end)
end

local function stopRound()
	if currentRoundScope ~= nil then
		currentRoundScope:Destroy("round ended")
		currentRoundScope = nil
	end
end
```

## 45. Boat controller lifecycle

```luau
local function startBoat(boat)
	local scope = TaskRuntime.scope("Boat")

	scope:Every(0, function(token)
		updateBoatPhysics(boat)
	end)

	scope:Connect(boat.Destroying, function()
		scope:Destroy("boat removed")
	end)

	scope:Add(function(reason)
		resetBoatForces(boat)
	end)

	return scope
end
```

## 46. Temporary effect lifecycle

```luau
local function playEffect(target)
	local scope = TaskRuntime.scope("TemporaryEffect")
	local effect = createEffect(target)

	scope:Add(effect, "Destroy")
	scope:Delay(2, function(token)
		scope:Destroy("effect finished")
	end)

	return scope
end
```

## 47. Cleanup deadlines

```luau
local scope = TaskRuntime.scope("ServerShutdown", {
	cleanupTimeout = 5,
	resourceCleanupTimeout = 1,
})

scope:Add(profileCache, {
	method = "Close",
	name = "ProfileCache",
	timeout = 2,
})

scope:Add(networkClient, {
	method = "Disconnect",
	name = "NetworkClient",
	timeout = 0.5,
})

local success, reason, errors = scope:DestroyAndAwait("server shutdown", 6)
```

## 48. Inspect cleanup errors

```luau
for _, cleanupError in ipairs(scope:GetCleanupErrors()) do
	warn(cleanupError.Code, cleanupError.Message, cleanupError.ScopeName)
end
```

## 49. Stop a scope when one worker fails

```luau
local scope = TaskRuntime.scope("CriticalSystem", {
	cancelOnTaskFailure = true,
})

scope:Spawn(function(token)
	runCriticalWorker(token)
end):SetName("CriticalWorker")
```

## 50. Root task context

```luau
local scope = TaskRuntime.scope("InventorySystem")

local rootTask = scope:Run(function(context, token, player)
	context:Every(30, function(childToken)
		saveInventory(player)
	end)

	context:Spawn(function(childToken)
		watchInventory(player, childToken)
	end)

	return loadInventory(player)
end, {
	name = "InventoryRoot",
	cancelOnChildFailure = true,
	childShutdownTimeout = 5,
}, player)
```

When the root callback returns, its context cancels and awaits the child tasks.

## 51. Nested task contexts

```luau
scope:Run(function(context, token)
	local effectsContext = context:Child("Effects", {
		cancelOnChildFailure = false,
	})

	effectsContext:Every(0, function(effectToken)
		updateEffects()
	end)

	token:Wait(10)
	effectsContext:Close("effects complete", 2)
end)
```

## 52. Context cancellation from a child failure

```luau
scope:Run(function(context, token)
	context:Spawn(function(childToken)
		error("critical child failed")
	end)

	while not token:IsCancelled() and not context.Token:IsCancelled() do
		context.Token:Wait(0)
	end
end, {
	cancelOnChildFailure = true,
})
```

## 53. Active task snapshot

```luau
local snapshot = TaskRuntime.getSnapshot()

print("Active:", snapshot.ActiveCount)
print("Peak:", snapshot.PeakActiveCount)
print("Deadlines:", snapshot.PendingDeadlines)

for _, taskInfo in ipairs(snapshot.Tasks) do
	print(
		taskInfo.Id,
		taskInfo.Name,
		taskInfo.Kind,
		taskInfo.State,
		taskInfo.ParentTaskId,
		taskInfo.OwnerScopeName
	)
end
```

## 54. Completed task history

```luau
TaskRuntime.configureDiagnostics({
	historySize = 200,
	captureCreationTrace = false,
})

for _, record in ipairs(TaskRuntime.getHistory()) do
	print(record.Name, record.State, record.Elapsed)
end
```

## 55. Task statistics

```luau
local stats = TaskRuntime.getStats()

for name, values in pairs(stats) do
	print(
		name,
		values.Count,
		values.Completed,
		values.Failed,
		values.Cancelled,
		values.AverageDuration,
		values.MaxDuration
	)
end
```

## 56. Long-running task warning

```luau
TaskRuntime.warnLongRunning(10)
```

## 57. Custom error handlers

```luau
TaskRuntime.setErrorHandler(function(message, handle, taskError)
	warn("Task failed", handle.Name, taskError.Code, message)
end)

TaskRuntime.setCleanupErrorHandler(function(message, scope, record)
	warn("Cleanup failed", scope.Name, record.Code, message)
end)
```

## 58. Isolated runtime instance

```luau
local runtime = TaskRuntime.create({
	historySize = 50,
})

local task = runtime:spawn(function(token)
	return 5
end)
```

Task handles from different runtime instances cannot be combined.

## 59. Virtual-time timer test

```luau
local scheduler = TaskRuntime.TestScheduler.new(0)
local runtime = TaskRuntime.create({
	scheduler = scheduler,
})

local task = runtime:delay(3600, function(token)
	return "one hour"
end)

scheduler:Advance(3600)

local success, value = task:Await()
assert(success and value == "one hour")
```

## 60. Virtual-time retry test

```luau
local scheduler = TaskRuntime.TestScheduler.new(0)
local runtime = TaskRuntime.create({
	scheduler = scheduler,
})

local attempts = 0
local task = runtime:retry(3, function(token, attempt)
	attempts = attempts + 1
	if attempt < 3 then
		error("temporary")
	end
	return "done"
end, {
	delaySeconds = 60,
})

scheduler:Advance(120)

local success, value = task:Await()
assert(success and value == "done")
assert(attempts == 3)
```

## 61. Server root scope

```luau
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

## 62. Full runtime shutdown

```luau
TaskRuntime.shutdown("server session ended")
```

Use this only when the entire runtime is ending. New tasks are rejected after shutdown.

## Common mistakes

### Ignoring the token

Incorrect:

```luau
TaskRuntime.spawn(function(token)
	while true do
		doWork()
		TaskRuntime.wait(0)
	end
end)
```

Correct:

```luau
TaskRuntime.spawn(function(token)
	while not token:IsCancelled() do
		doWork()
		TaskRuntime.wait(0)
	end
end)
```

### Creating raw work inside a scope-owned system

Incorrect:

```luau
local scope = TaskRuntime.scope("Round")

spawn(function()
	runRoundLoop()
end)
```

Correct:

```luau
scope:Spawn(function(token)
	runRoundLoop(token)
end)
```

### Waiting for a scope from one of its own tasks

Do not call `DestroyAndAwait()` from a task owned directly by the same scope. The task would wait for itself.

Use `Destroy()` from inside the owned task, or call `DestroyAndAwait()` from an outside owner.

### Forgetting to release a semaphore

Use `pcall` or `WithPermit` so a thrown error does not permanently consume the permit.

### Treating an await timeout as task cancellation

```luau
local success, reason = task:Await(1)
```

When `reason == "timeout"`, the task is still active. Use `CancelAfter()` or `withTimeout()` when the task itself should receive cancellation.

### Combining runtimes

Do not pass handles from two different `TaskRuntime.create()` instances into one composition call.
