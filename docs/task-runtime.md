# TaskRuntime

`TaskRuntime` provides cancellable scheduling and deterministic cleanup for Polytoria scripts. It is designed for systems that start temporary work, connect signals, create objects, or run background loops that must stop cleanly later.

## Why this is needed

Most game systems have a lifecycle. A round starts and ends. A player joins and leaves. A boat is spawned and destroyed. A menu opens and closes. During that lifecycle, the system may start delayed callbacks, repeating loops, signal connections, temporary instances, and child systems.

Without a cleanup system, those resources can outlive the system that created them. Common results include:

- an old round timer ending the next round
- duplicate signal callbacks after a system is restarted
- repeating loops continuing after a player or vehicle is gone
- temporary objects and connections remaining referenced
- old and new versions of a system running at the same time
- increasing memory use, CPU work, network traffic, and hard-to-reproduce bugs

`TaskRuntime` solves this by giving each system a cleanup scope. Anything registered with that scope can be cancelled, disconnected, destroyed, or otherwise cleaned when the system ends.

A cleanup scope only manages resources that are registered with it. Code that uses raw `spawn`, raw signal connections, or unregistered temporary objects still needs to be cleaned manually.

## Project files

- `scripts/modules/TaskRuntime.luau`: reusable ModuleScript
- `scripts/server/script.server.luau`: root server lifecycle example
- `scripts/tests/task-runtime-test.server.luau`: linked Creator self-test

In Creator, `scripts/modules/TaskRuntime.luau` must be linked to a `ModuleScript` named `TaskRuntime` under `ScriptService`.

```text
ScriptService
├── TaskRuntime
├── script
└── task-runtime-test
```

The exact names of the server scripts can differ, but the module must be available at:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
```

## Quick start

Create one scope for a system, register its temporary work, then destroy the scope when the system ends.

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

When `stopRound()` runs, the pending delay is cancelled and the signal connection is disconnected.

## Scheduled tasks

Every scheduled callback receives a cancellation token as its first argument. Arguments passed after the callback follow the token.

### Run immediately

```luau
local handle = TaskRuntime.spawn(function(token, playerName)
	if token:IsCancelled() then
		return
	end

	print("Preparing data for " .. playerName)
	return true
end, "PlayerOne")
```

### Run on a later frame

```luau
TaskRuntime.defer(function(token)
	if token:IsCancelled() then
		return
	end

	print("Runs after the current work yields")
end)
```

### Run after a delay

```luau
local delayedTask = TaskRuntime.delay(10, function(token)
	if token:IsCancelled() then
		return
	end

	print("Ten seconds passed")
end)
```

### Wait inside a task

```luau
TaskRuntime.spawn(function(token)
	if not token:Wait(5) then
		return
	end

	print("Five seconds passed without cancellation")
end)
```

`token:Wait(seconds)` returns `false` when cancellation is requested before the delay finishes.

### Cancel a task

```luau
delayedTask:Cancel("player left")
```

The same operation is available through:

```luau
TaskRuntime.cancel(delayedTask, "player left")
```

### Wait for completion

```luau
local taskHandle = TaskRuntime.spawn(function(token)
	if not token:Wait(1) then
		return nil
	end

	return 50, "finished"
end)

local success, value, message = taskHandle:Await()

if success then
	print(value, message)
else
	warn("Task did not complete:", value)
end
```

For a failed task, `Await()` returns `false` and the error message. For a cancelled task, it returns `false` and the cancellation reason.

## Task states and information

A task can be in one of these states:

- `scheduled`
- `running`
- `cancelling`
- `completed`
- `cancelled`
- `failed`

Useful task fields include:

- `Id`
- `Kind`
- `State`
- `Cancelled`
- `CancelReason`
- `CreatedAt`
- `StartedAt`
- `FinishedAt`
- `Error`
- `Results`
- `Token`
- `Iterations`
- `SkippedIntervals`

Useful methods include:

- `Cancel(reason?)`
- `IsCancelled()`
- `IsCancellationRequested()`
- `IsDone()`
- `Await()`

## Cooperative cancellation

Polytoria game scripts cannot forcibly terminate a callback that is already running. Cancellation is cooperative, which means long-running code must check its token and return.

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

Pending tasks become `cancelled` immediately. Running tasks enter `cancelling` and remain active until their callback exits. This keeps `Await()` and active-task counts honest.

A task that ignores its token can continue running after cancellation has been requested. It can also cause `DestroyAndAwait()` to time out or wait forever if no timeout is provided.

## Immediate cancellation callbacks

Use `token:OnCancel(callback)` when cleanup must happen immediately when cancellation is requested.

```luau
local worker = TaskRuntime.spawn(function(token)
	local connection = token:OnCancel(function(reason)
		print("Worker is stopping because:", reason)
	end)

	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)
```

`OnCancel` returns a connection with `Disconnect()`.

```luau
local cancelConnection = token:OnCancel(function()
	print("This will not run after disconnection")
end)

cancelConnection:Disconnect()
```

Registering an `OnCancel` callback after the token has already been cancelled invokes the callback immediately and returns a disconnected connection.

## Repeating tasks

Use `TaskRuntime.every` or `scope:Every` for autosaves, regeneration, timers, status updates, and similar repeating work.

```luau
local autosave = TaskRuntime.every(30, function(token)
	savePlayers()
end)

local success, reason = autosave:Await()
```

Cancel it when it is no longer needed:

```luau
autosave:Cancel("server shutting down")
```

A repeating task waits one interval before its first run. Iterations are sequential and never overlap. If a callback takes longer than its interval, missed runs are skipped instead of being replayed in a burst.

```luau
local statusScope = TaskRuntime.scope("StatusUpdates")

local statusTask = statusScope:Every(1, function(token)
	updateStatusDisplay()
end)

print(statusTask.Iterations)
print(statusTask.SkippedIntervals)
```

Passing `0` runs once per physics frame:

```luau
local frameTask = scope:Every(0, function(token)
	updateCustomMovement()
end)
```

Use frame-based repeating work carefully. Expensive work every physics frame can hurt server performance.

## Cleanup scopes

A cleanup scope owns temporary resources for one system.

```luau
local scope = TaskRuntime.scope("Boat")
```

A scope can own:

- scheduled tasks
- repeating tasks
- signal connections
- child scopes
- instances and other objects
- custom cleanup callbacks

Cleanup runs in reverse registration order. The most recently added resource is cleaned first.

### Register a signal connection

```luau
scope:Connect(game["Players"].PlayerAdded, function(player)
	print(player.Name)
end)
```

### Register a task

```luau
scope:Spawn(function(token)
	while not token:IsCancelled() do
		updateBoatPhysics()
		TaskRuntime.wait(0)
	end
end)
```

### Register a delayed task

```luau
scope:Delay(15, function(token)
	removeTemporaryProtection()
end)
```

### Register a repeating task

```luau
scope:Every(5, function(token)
	checkBoatOccupants()
end)
```

### Register an instance or object

```luau
local temporaryPart = Instance.New("Part")
temporaryPart.Parent = game["Environment"]

scope:Add(temporaryPart, "Destroy")
```

### Register custom cleanup code

```luau
scope:Add(function()
	print("Boat resources cleaned")
end)
```

### Automatic cleanup method detection

When no cleanup method is provided, the scope checks for these methods in order:

- `Cancel`
- `Disconnect`
- `Cleanup`
- `Destroy`
- `Close`

```luau
scope:Add(connection)
scope:Add(taskHandle)
scope:Add(temporaryObject)
```

Providing the method explicitly is clearer when a resource supports more than one cleanup method.

```luau
scope:Add(temporaryObject, "Destroy")
```

Completed, failed, and cancelled tasks automatically detach from their scope, so long-lived scopes do not retain old task handles.

## Child scopes

Child scopes are useful when a larger system contains smaller systems.

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
```

Destroying `matchScope` also destroys `roundScope` and `effectsScope`.

## Destroy versus DestroyAndAwait

Use `Destroy()` when cleanup should be requested and the caller does not need to wait for running callbacks to exit.

```luau
scope:Destroy("boat removed")
```

Use `DestroyAndAwait()` when the next action must not begin until all owned tasks and child scopes have fully stopped.

```luau
local success, reason = roundScope:DestroyAndAwait("round ended", 5)

if not success then
	warn("Round cleanup did not finish:", reason)
end
```

The timeout is optional:

```luau
roundScope:DestroyAndAwait("round ended")
```

Without a timeout, it can wait forever for a task that does not cooperate with cancellation. A timeout is recommended for production shutdown paths.

Do not call `DestroyAndAwait()` from a task owned by the same scope. That task would wait for itself to finish. Use `Destroy()` from inside an owned task, or ask an external controller to perform the awaited shutdown.

Check cleanup state with:

```luau
if scope:IsCleanupComplete() then
	print("Cleanup is fully finished")
end
```

## Named resources

Named resources let a system replace or remove one specific resource without destroying its entire scope.

### Replace a round timer

```luau
local roundScope = TaskRuntime.scope("Round")

roundScope:Set("RoundTimer", TaskRuntime.delay(60, function(token)
	endRound()
end))

roundScope:Set("RoundTimer", TaskRuntime.delay(90, function(token)
	endRound()
end))
```

The second `Set` cancels and replaces the first timer.

### Read or remove a named resource

```luau
local timer = roundScope:Get("RoundTimer")

if roundScope:Has("RoundTimer") then
	print("Round timer is active")
end

roundScope:Remove("RoundTimer")
```

`Remove` cleans the resource by default. Pass `false` to detach it without cleaning it:

```luau
local timer = roundScope:Remove("RoundTimer", false)
```

Named-resource methods:

- `Set(key, resource, cleanupMethod?)`
- `Get(key)`
- `Has(key)`
- `Remove(key, shouldCleanup?, reason?)`

## Common use cases

### Round lifecycle

```luau
local roundScope = TaskRuntime.scope("Round")

roundScope:Every(1, function(token)
	updateRoundClock()
end)

roundScope:Delay(120, function(token)
	requestRoundEnd()
end)

function finishRound()
	local success = roundScope:DestroyAndAwait("round finished", 5)
	if success then
		startNextRound()
	end
end
```

This prevents the old round clock or timeout from affecting the next round.

### Player lifecycle

```luau
local serverScope = TaskRuntime.scope("Players")

serverScope:Connect(game["Players"].PlayerAdded, function(player)
	local key = "Player_" .. tostring(player.UserID)
	local playerScope = TaskRuntime.scope(key)

	serverScope:Set(key, playerScope, "Destroy")

	playerScope:Every(10, function(token)
		savePlayerProgress(player)
	end)
end)

serverScope:Connect(game["Players"].PlayerRemoved, function(player)
	local key = "Player_" .. tostring(player.UserID)
	serverScope:Remove(key, true, "player left")
end)
```

This stops player-specific work when the player leaves.

### Boat or vehicle lifecycle

```luau
local function startBoatController(boat)
	local boatScope = TaskRuntime.scope("BoatController")

	boatScope:Every(0, function(token)
		updateBoatMovement(boat)
	end)

	boatScope:Every(1, function(token)
		checkBoatState(boat)
	end)

	boatScope:Add(function()
		resetBoatForces(boat)
	end)

	return boatScope
end

local boatScope = startBoatController(boat)

function removeBoat()
	boatScope:Destroy("boat removed")
	boat:Destroy()
end
```

This prevents physics and status loops from continuing after the boat is removed.

### Temporary effect

```luau
local effectScope = TaskRuntime.scope("SpeedBoost")

applySpeedBoost(player)

effectScope:Add(function()
	removeSpeedBoost(player)
end)

effectScope:Delay(10, function(token)
	effectScope:Destroy("boost expired")
end)
```

### Replaceable cooldown

```luau
local abilityScope = TaskRuntime.scope("Ability")

local function startCooldown(seconds)
	abilityScope:Set("Cooldown", TaskRuntime.delay(seconds, function(token)
		setAbilityReady(true)
	end))
end
```

Starting a new cooldown automatically cancels the old one.

### Server maintenance loop

```luau
local serverScope = TaskRuntime.scope("Server")

serverScope:Every(60, function(token)
	cleanupUnusedObjects()
end)

serverScope:Every(300, function(token)
	saveAllPlayers()
end)
```

## Error handling

Task callbacks run through `pcall`. Failed tasks enter the `failed` state and store the error in `handle.Error`.

Set a custom global error handler:

```luau
TaskRuntime.setErrorHandler(function(message, handle)
	warn(
		"Task failed",
		handle.Id,
		handle.Kind,
		message
	)
end)
```

Restore the default handler:

```luau
TaskRuntime.setErrorHandler(nil)
```

A failure inside one task does not automatically destroy its scope. The system that owns the scope should decide whether the failure is recoverable or should trigger cleanup.

## Debugging active tasks

```luau
print("Active tasks:", TaskRuntime.getActiveCount())

for _, handle in ipairs(TaskRuntime.getActiveTasks()) do
	print(
		handle.Id,
		handle.Kind,
		handle.State,
		handle.Iterations,
		handle.SkippedIntervals
	)
end
```

This is useful for finding loops or delayed tasks that remain active after a system should have ended.

## Root script lifecycle

Use one root scope for a long-running server script.

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

The current game runtime does not automatically invoke `_Dispose()`. `Shutdown()` or `ShutdownAndAwait()` can be called explicitly through `BaseScript:Call()`.

Use `TaskRuntime.shutdown()` only when the entire runtime is ending. It cancels every active task and prevents new tasks from being scheduled for the rest of that session.

```luau
TaskRuntime.shutdown("server process ending")
```

Do not use `TaskRuntime.shutdown()` to end an ordinary round, player session, boat controller, or UI screen. Destroy that system's scope instead.

## Testing in Creator

The linked test script is:

```text
scripts/tests/task-runtime-test.server.luau
```

Start a normal local playtest. The test runs automatically and should print:

```text
TaskRuntime self-test passed
```

The test covers:

- argument and result forwarding
- pending cancellation
- cooperative running-task cancellation
- immediate cancellation callbacks
- disconnected cancellation callbacks
- automatic task detachment from scopes
- named resource replacement and removal
- non-overlapping repeating tasks
- recursive `DestroyAndAwait`
- reverse-order cleanup
- error handling
- active-task release

After verification, disable or remove the test `ServerScript` so it does not run during ordinary development.

## API reference

### TaskRuntime

- `spawn(callback, ...)`
- `defer(callback, ...)`
- `delay(seconds, callback, ...)`
- `every(seconds, callback, ...)`
- `wait(seconds?)`
- `cancel(handle, reason?)`
- `isCancelled(handle)`
- `isDone(handle)`
- `getActiveCount()`
- `getActiveTasks()`
- `setErrorHandler(handler?)`
- `shutdown(reason?)`
- `scope(name?)`

### CancellationToken

- `IsCancelled()`
- `GetReason()`
- `Wait(seconds, pollInterval?)`
- `OnCancel(callback)`

### TaskHandle

- `Cancel(reason?)`
- `IsCancelled()`
- `IsCancellationRequested()`
- `IsDone()`
- `Await()`

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
- `Child(name?)`
- `GetCount()`
- `IsDestroyed()`
- `IsCleanupComplete()`
- `Cleanup(reason?)`
- `Destroy(reason?)`
- `DestroyAndAwait(reason?, timeoutSeconds?)`
