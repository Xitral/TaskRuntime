# TaskRuntime Examples

This guide contains copy-paste patterns for common Polytoria systems. The function names such as `savePlayer`, `updateBoatPhysics`, and `loadProfile` represent your own game code.

All examples assume `TaskRuntime` is linked as a `ModuleScript` named `TaskRuntime` under `ScriptService`:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
```

## Run work immediately

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

## Pass arguments and return multiple values

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

## Run on a later frame

Use `defer` when work should happen after the current callback yields.

```luau
TaskRuntime.defer(function(token)
	print("Runs on a later frame")
end)
```

## Run after a delay

```luau
local delayedMessage = TaskRuntime.delay(5, function(token)
	print("Five seconds passed")
end)
```

Cancel it before it runs:

```luau
delayedMessage:Cancel("message no longer needed")
```

## Wait inside a cancellable task

Use `token:Wait()` instead of a raw wait when cancellation should interrupt the delay.

```luau
local worker = TaskRuntime.spawn(function(token)
	if not token:Wait(10) then
		return
	end

	print("The task was not cancelled")
end)

worker:Cancel("system stopped")
```

## Repeat work on an interval

```luau
local autosave = TaskRuntime.every(60, function(token)
	saveAllPlayers()
end)

-- Later:
autosave:Cancel("server shutting down")
autosave:Await()
```

Repeating callbacks never overlap. When one iteration takes too long, missed intervals are skipped rather than replayed in a burst.

## Run once per physics frame

Passing `0` to `every` runs once per physics frame.

```luau
local movementLoop = TaskRuntime.every(0, function(token)
	updateCustomMovement()
end)
```

Keep frame callbacks small. Use a slower interval for work that does not need frame-level updates.

## Give a task a readable name and metadata

```luau
local task = TaskRuntime.spawn(function(token)
	loadInventory()
end)

task:SetName("LoadInventory")
task:SetMetadata("playerID", player.UserID)
task:SetMetadata("system", "inventory")

print(task.Name)
print(task:GetMetadata("playerID"))
print(task:GetElapsedTime())
```

Names and metadata appear in runtime snapshots.

## React without blocking

```luau
local task = TaskRuntime.spawn(function(token)
	return loadProfile()
end)

local connection = task:OnComplete(function(handle)
	if handle.State == "completed" then
		print("Profile loaded")
	elseif handle.State == "failed" then
		warn(handle.Error)
	end
end)
```

Disconnect the observer when it is no longer needed:

```luau
connection:Disconnect()
```

## Stop waiting after a deadline

`Await(timeout)` stops waiting but leaves the task running.

```luau
local task = TaskRuntime.spawn(function(token)
	return performSlowOperation()
end)

local success, result = task:Await(2)
if not success and result == "timeout" then
	warn("The task is still running")
end
```

You can await the same task again later.

## Cancel a task after a deadline

```luau
local worker = TaskRuntime.spawn(function(token)
	while not token:IsCancelled() do
		performOneWorkStep()
		TaskRuntime.wait(0)
	end
end)

worker:CancelAfter(5, "worker deadline")
```

The task must still check its token and exit cooperatively.

## Create a task with a timeout

```luau
local request = TaskRuntime.withTimeout(3, function(token)
	while not token:IsCancelled() do
		local result = pollForResult()
		if result ~= nil then
			return result
		end
		TaskRuntime.wait(0)
	end
end)

local success, value = request:Await(5)
if not success then
	warn("Request ended:", value)
end
```

## Share cancellation between several systems

```luau
local source = TaskRuntime.cancellationSource()

TaskRuntime.spawn(function(token)
	while not token:IsCancelled() and not source.Token:IsCancelled() do
		updateWeather()
		TaskRuntime.wait(1)
	end
end)

TaskRuntime.spawn(function(token)
	while not token:IsCancelled() and not source.Token:IsCancelled() do
		updateLighting()
		TaskRuntime.wait(1)
	end
end)

source:Cancel("world cycle stopped")
```

## Link cancellation to a parent task

```luau
local parent = TaskRuntime.spawn(function(parentToken)
	local childSource = TaskRuntime.cancellationSource(parentToken)

	TaskRuntime.spawn(function(token)
		while not childSource.Token:IsCancelled() do
			performChildWork()
			TaskRuntime.wait(0)
		end
	end)

	while not parentToken:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)
```

Cancelling the parent token also cancels the linked source.

## Retry temporary failures

```luau
local profileRequest = TaskRuntime.retry(4, function(token, attempt, playerID)
	return loadRemoteProfile(playerID)
end, {
	delaySeconds = 0.25,
	backoffFactor = 2,
	maxDelaySeconds = 2,
	shouldRetry = function(message, attempt)
		return string.find(message, "temporary", 1, true) ~= nil
	end,
	onRetry = function(message, attempt, nextDelay)
		warn("Retrying profile load", attempt, nextDelay, message)
	end,
}, player.UserID)

local success, profile = profileRequest:Await(10)
if not success then
	warn("Profile load failed:", profile)
end
```

A retry happens only when the callback throws an error. A normal return counts as success.

## Wait for several tasks

```luau
local profileTask = TaskRuntime.spawn(function(token)
	return loadProfile()
end)

local inventoryTask = TaskRuntime.spawn(function(token)
	return loadInventory()
end)

local settingsTask = TaskRuntime.spawn(function(token)
	return loadSettings()
end)

local group = TaskRuntime.all({
	profileTask,
	inventoryTask,
	settingsTask,
})

local success, results = group:Await(5)
if success then
	local profile = results[1][1]
	local inventory = results[2][1]
	local settings = results[3][1]
end
```

By default, a failed or cancelled child fails the group and cancels unfinished siblings.

## Collect every task outcome

Use non-fail-fast mode when every result matters.

```luau
local group = TaskRuntime.all({ firstTask, secondTask, thirdTask }, {
	failFast = false,
	cancelRemaining = false,
})

local success, outcomes = group:Await(10)
if success then
	for index, outcome in ipairs(outcomes) do
		if outcome.Success then
			print(index, outcome.Values[1])
		else
			warn(index, outcome.State, outcome.Error)
		end
	end
end
```

## Use the first completed task

```luau
local primary = TaskRuntime.spawn(function(token)
	return requestPrimarySource()
end)

local fallback = TaskRuntime.delay(0.25, function(token)
	return requestFallbackSource()
end)

local race = TaskRuntime.race({ primary, fallback })
local success, winnerIndex, value = race:Await(3)

if success then
	print("Winner:", winnerIndex, value)
end
```

The unfinished loser is cancelled by default.

## Own a system with a cleanup scope

```luau
local systemScope = TaskRuntime.scope("RoundSystem")

systemScope:Every(1, function(token)
	updateRoundClock()
end)

systemScope:Delay(120, function(token)
	requestRoundEnd()
end)

systemScope:Connect(game["Players"].PlayerAdded, function(player)
	addPlayerToRound(player)
end)

function stopRound()
	systemScope:Destroy("round ended")
end
```

Destroying the scope cancels its tasks and disconnects its connections.

## Wait for complete scope shutdown

```luau
local success, reason, errors = systemScope:DestroyAndAwait("system stopped", 5)

if not success then
	warn("Shutdown did not finish cleanly:", reason)
end
```

Use a timeout so a task that ignores cancellation cannot block forever.

## Clean up a temporary instance

```luau
local effectScope = TaskRuntime.scope("ExplosionEffect")
local effectPart = Instance.New("Part")

effectPart.Parent = game["Environment"]
effectScope:Add(effectPart, "Destroy")

effectScope:Delay(3, function(token)
	effectScope:Destroy("effect expired")
end)
```

## Run custom cleanup code

```luau
local vehicleScope = TaskRuntime.scope("Vehicle")

vehicleScope:Add(function(reason)
	resetVehicleForces(vehicle)
	print("Vehicle cleanup:", reason)
end)
```

Custom cleanup callbacks receive the cleanup reason.

## Manage a signal connection

```luau
local playerScope = TaskRuntime.scope("PlayerSignals")

playerScope:Connect(player.CharacterAdded, function(character)
	prepareCharacter(character)
end)

-- Later:
playerScope:Destroy("player left")
```

## Replace one named resource

This pattern is useful for cooldowns, timers, active effects, and current requests.

```luau
local abilityScope = TaskRuntime.scope("Ability")

local function startCooldown(seconds)
	abilityScope:Set("Cooldown", TaskRuntime.delay(seconds, function(token)
		setAbilityReady(true)
	end))
end

startCooldown(10)
startCooldown(5) -- Cancels and replaces the first cooldown.
```

Read or remove the resource:

```luau
local cooldown = abilityScope:Get("Cooldown")
local hasCooldown = abilityScope:Has("Cooldown")
abilityScope:Remove("Cooldown")
```

Pass `false` as the second argument to detach without cleaning:

```luau
local detached = abilityScope:Remove("Cooldown", false)
```

## Create child scopes

```luau
local matchScope = TaskRuntime.scope("Match")
local roundScope = matchScope:Child("Round")
local effectsScope = roundScope:Child("Effects")

roundScope:Every(1, function(token)
	updateRoundClock()
end)

effectsScope:Delay(10, function(token)
	removeRoundEffect()
end)

matchScope:Destroy("match ended")
```

Destroying the parent destroys every child scope.

## Player lifecycle

```luau
local playersScope = TaskRuntime.scope("Players")

playersScope:Connect(game["Players"].PlayerAdded, function(player)
	local key = "Player_" .. tostring(player.UserID)
	local playerScope = TaskRuntime.scope(key)
	playersScope:Set(key, playerScope, "Destroy")

	playerScope:Every(60, function(token)
		savePlayer(player)
	end)

	playerScope:Connect(player.CharacterAdded, function(character)
		prepareCharacter(player, character)
	end)
end)

playersScope:Connect(game["Players"].PlayerRemoved, function(player)
	local key = "Player_" .. tostring(player.UserID)
	playersScope:Remove(key, true, "player left")
end)
```

## Round lifecycle

```luau
local currentRoundScope = nil

local function startRound()
	if currentRoundScope ~= nil then
		currentRoundScope:Destroy("round replaced")
	end

	local roundScope = TaskRuntime.scope("Round")
	currentRoundScope = roundScope

	roundScope:Every(1, function(token)
		updateRoundClock()
	end)

	roundScope:Delay(120, function(token)
		requestRoundEnd()
	end)
end

local function finishRound()
	local roundScope = currentRoundScope
	currentRoundScope = nil

	if roundScope ~= nil then
		local success, reason = roundScope:DestroyAndAwait("round finished", 5)
		if not success then
			warn("Round cleanup issue:", reason)
		end
	end

	startRound()
end
```

This prevents timers and loops from the old round from reaching the new round.

## Boat or vehicle lifecycle

```luau
local function startBoatController(boat)
	local boatScope = TaskRuntime.scope("BoatController")

	boatScope:Every(0, function(token)
		updateBoatMovement(boat)
	end):SetName("BoatMovement")

	boatScope:Every(1, function(token)
		checkBoatState(boat)
	end):SetName("BoatStateCheck")

	boatScope:Add(function(reason)
		resetBoatForces(boat)
	end)

	return boatScope
end

local boatScope = startBoatController(boat)

local function removeBoat()
	boatScope:Destroy("boat removed")
	boat:Destroy()
end
```

## Temporary player effect

```luau
local effectScope = TaskRuntime.scope("SpeedBoost")

applySpeedBoost(player)

effectScope:Add(function(reason)
	removeSpeedBoost(player)
end)

effectScope:Delay(10, function(token)
	effectScope:Destroy("boost expired")
end)
```

Destroy the same scope early if the player dies, leaves, or the effect is replaced.

## Supervise a group of workers

A supervising scope can shut down its remaining resources when one owned task fails.

```luau
local systemScope = TaskRuntime.scope("InventorySystem", {
	cancelOnTaskFailure = true,
})

systemScope:Spawn(function(token)
	runInventoryWorker(token)
end):SetName("InventoryWorker")

systemScope:Spawn(function(token)
	runSaveWorker(token)
end):SetName("SaveWorker")
```

Inspect failures later:

```luau
for _, failure in ipairs(systemScope:GetTaskFailures()) do
	warn(failure.Handle.Name, failure.Error)
end
```

## Handle cleanup failures

Cleanup continues even when one resource throws.

```luau
TaskRuntime.setCleanupErrorHandler(function(message, scope, record)
	warn("Cleanup failed", scope.Name, message)
end)

local success, reason, errors = systemScope:DestroyAndAwait("system stopped", 5)
if not success and reason == "cleanup failed" then
	for _, cleanupError in ipairs(errors) do
		warn(cleanupError.Message)
	end
end
```

Restore the default handler:

```luau
TaskRuntime.setCleanupErrorHandler(nil)
```

## Handle task failures globally

```luau
TaskRuntime.setErrorHandler(function(message, handle)
	warn("Task failed", handle.Id, handle.Name, message)
end)
```

Restore the default handler:

```luau
TaskRuntime.setErrorHandler(nil)
```

## Inspect active tasks

```luau
local snapshot = TaskRuntime.getSnapshot()

print("Active tasks:", snapshot.ActiveCount)

for kind, count in pairs(snapshot.ByKind) do
	print(kind, count)
end

for _, taskInfo in ipairs(snapshot.Tasks) do
	print(
		taskInfo.Id,
		taskInfo.Name,
		taskInfo.Kind,
		taskInfo.State,
		taskInfo.Age
	)
end
```

## Warn about long-running tasks

```luau
local count = TaskRuntime.warnLongRunning(10)
print("Long-running tasks:", count)
```

Set useful task names first so warnings identify the responsible system.

## Root server lifecycle

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
local rootScope = TaskRuntime.scope("ServerRoot")

rootScope:Every(60, function(token)
	cleanupUnusedObjects()
end):SetName("UnusedObjectCleanup")

rootScope:Every(300, function(token)
	saveAllPlayers()
end):SetName("GlobalAutosave")

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

The current game runtime does not automatically call `_Dispose()`. Call `Shutdown()` or `ShutdownAndAwait()` explicitly through `BaseScript:Call()`.

## Final runtime shutdown

Use global shutdown only when the entire task runtime is ending.

```luau
TaskRuntime.shutdown("server process ending")
```

After global shutdown, new tasks cannot be scheduled during that session. Do not use it to end a normal round, player session, vehicle controller, or menu. Destroy that system's scope instead.

## Common mistakes

### Using raw waits in cancellable work

```luau
-- Avoid when cancellation should interrupt the delay.
wait(10)

-- Prefer:
if not token:Wait(10) then
	return
end
```

### Ignoring the cancellation token

```luau
-- This cannot stop cooperatively.
while true do
	performWork()
	TaskRuntime.wait(0)
end

-- Prefer:
while not token:IsCancelled() do
	performWork()
	TaskRuntime.wait(0)
end
```

### Forgetting to register a resource

A scope only cleans resources added through `Add`, `Set`, `Connect`, `Spawn`, `Delay`, `Every`, `WithTimeout`, `Retry`, or `Child`.

### Awaiting a scope from one of its own tasks

Do not call `DestroyAndAwait()` from a task owned by that same scope. The task would wait for itself to finish. Call `Destroy()` from inside the task, or let an external controller perform the awaited shutdown.
