-- Linked ServerScript self-test. Start a local playtest and watch the console.

local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])

local function expect(condition, message)
	if not condition then
		error("TaskRuntime self-test failed: " .. message)
	end
end

local completed = TaskRuntime.spawn(function(token, left, right)
	expect(not token:IsCancelled(), "new task token should be active")
	TaskRuntime.wait(0.01)
	return left + right, "done"
end, 2, 3)

local completedSuccessfully, sum, label = completed:Await()
expect(completedSuccessfully, "spawned task should complete")
expect(sum == 5, "spawned task should preserve arguments and results")
expect(label == "done", "spawned task should preserve multiple results")

local delayedRan = false
local delayed = TaskRuntime.delay(0.05, function()
	delayedRan = true
end)

expect(TaskRuntime.cancel(delayed, "test cancellation"), "pending delay should cancel")
TaskRuntime.wait(0.1)
expect(not delayedRan, "cancelled delay must not execute")
expect(delayed.State == "cancelled", "cancelled pending task should finish immediately")

-- Cancellation callbacks should execute immediately, exactly once, and expose the reason.
local runningStarted = false
local allowRunningTaskToExit = false
local cancellationCallbackCount = 0
local cancellationCallbackReason = nil
local cancellationConnection = nil

local running = TaskRuntime.spawn(function(token)
	cancellationConnection = token:OnCancel(function(reason)
		cancellationCallbackCount = cancellationCallbackCount + 1
		cancellationCallbackReason = reason
	end)

	runningStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
	while not allowRunningTaskToExit do
		TaskRuntime.wait(0)
	end
end)

while not runningStarted do
	TaskRuntime.wait(0)
end

expect(cancellationConnection ~= nil and cancellationConnection.Connected, "OnCancel should return a connected handle")
expect(running:Cancel("cooperative cancellation test"), "running task should accept cancellation")
expect(cancellationCallbackCount == 1, "OnCancel callback should run synchronously")
expect(cancellationCallbackReason == "cooperative cancellation test", "OnCancel should receive cancellation reason")
expect(not cancellationConnection.Connected, "cancellation connection should disconnect after firing")
expect(running.State == "cancelling", "running task should enter cancelling state")
expect(not running:IsDone(), "cancelling task should not report done before callback exits")
expect(running.Token:GetReason() == "cooperative cancellation test", "token should expose cancellation reason")

local lateCancellationCallbackCount = 0
local lateConnection = running.Token:OnCancel(function(reason)
	lateCancellationCallbackCount = lateCancellationCallbackCount + 1
	cancellationCallbackReason = reason
end)
expect(lateCancellationCallbackCount == 1, "late OnCancel registration should run immediately")
expect(not lateConnection.Connected, "late OnCancel connection should already be disconnected")

allowRunningTaskToExit = true
local runningSucceeded, runningReason = running:Await()
expect(not runningSucceeded, "cancelled running task should not report success")
expect(runningReason == "cooperative cancellation test", "Await should return cancellation reason")
expect(running.State == "cancelled", "running task should finish cancelled after callback exits")

-- Disconnected cancellation callbacks must not run.
local disconnectedStarted = false
local disconnectedCallbackRan = false
local disconnectedTask = TaskRuntime.spawn(function(token)
	local connection = token:OnCancel(function()
		disconnectedCallbackRan = true
	end)
	expect(connection:Disconnect(), "cancellation callback connection should disconnect")
	disconnectedStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)

while not disconnectedStarted do
	TaskRuntime.wait(0)
end

disconnectedTask:Cancel("disconnected callback test")
disconnectedTask:Await()
expect(not disconnectedCallbackRan, "disconnected cancellation callback must not run")

-- Completed tasks should detach themselves from long-lived scopes.
local autoScope = TaskRuntime.scope("AutomaticTaskRemoval")
local allowScopedTaskToFinish = false
local scopedCompletion = autoScope:Spawn(function()
	while not allowScopedTaskToFinish do
		TaskRuntime.wait(0)
	end
	return "complete"
end)

expect(autoScope:GetCount() == 1, "scope should initially own scheduled task")
allowScopedTaskToFinish = true
local scopedSucceeded = scopedCompletion:Await()
expect(scopedSucceeded, "scope-owned task should complete")
expect(autoScope:GetCount() == 0, "completed task should automatically detach from scope")
autoScope:Destroy()

-- Named resources should replace and clean old values, then support explicit removal.
local keyedScope = TaskRuntime.scope("KeyedResources")
local firstResource = { Destroyed = false }
function firstResource:Destroy()
	self.Destroyed = true
end
local secondResource = { Destroyed = false }
function secondResource:Destroy()
	self.Destroyed = true
end

keyedScope:Set("RoundTimer", firstResource, "Destroy")
expect(keyedScope:Get("RoundTimer") == firstResource, "Set should register named resource")
expect(keyedScope:Has("RoundTimer"), "Has should detect named resource")

keyedScope:Set("RoundTimer", secondResource, "Destroy")
expect(firstResource.Destroyed, "replacing a key should clean previous resource")
expect(keyedScope:Get("RoundTimer") == secondResource, "replacement should become current resource")
expect(keyedScope:GetCount() == 1, "replacement should not duplicate scope entry")

local removedResource = keyedScope:Remove("RoundTimer")
expect(removedResource == secondResource, "Remove should return removed resource")
expect(secondResource.Destroyed, "Remove should clean resource by default")
expect(not keyedScope:Has("RoundTimer"), "removed key should no longer exist")
expect(keyedScope:GetCount() == 0, "removed resource should detach from scope")
keyedScope:Destroy()

-- Every should run sequentially, never overlap, and stop cleanly with its scope.
local repeatingScope = TaskRuntime.scope("RepeatingTasks")
local repeatCount = 0
local simultaneousRepeats = 0
local maximumSimultaneousRepeats = 0

local repeatingTask = repeatingScope:Every(0.01, function()
	simultaneousRepeats = simultaneousRepeats + 1
	if simultaneousRepeats > maximumSimultaneousRepeats then
		maximumSimultaneousRepeats = simultaneousRepeats
	end

	repeatCount = repeatCount + 1
	TaskRuntime.wait(0.02)
	simultaneousRepeats = simultaneousRepeats - 1
end)

while repeatCount < 3 do
	TaskRuntime.wait(0)
end

local repeatingCleanupSucceeded, repeatingCleanupError = repeatingScope:DestroyAndAwait("repeating test complete", 1)
expect(repeatingCleanupSucceeded, "DestroyAndAwait should finish repeating task: " .. tostring(repeatingCleanupError))
expect(repeatingTask.State == "cancelled", "repeating task should finish cancelled")
expect(repeatingTask.Iterations >= 3, "repeating task should track completed iterations")
expect(maximumSimultaneousRepeats == 1, "repeating callbacks must never overlap")
local repeatCountAfterCleanup = repeatCount
TaskRuntime.wait(0.05)
expect(repeatCount == repeatCountAfterCleanup, "repeating task must not run after cleanup")

-- DestroyAndAwait should include running tasks inside child scopes.
local parentScope = TaskRuntime.scope("AwaitedParent")
local childScope = parentScope:Child("AwaitedChild")
local childTaskStarted = false
local childTaskExited = false

childScope:Spawn(function(token)
	childTaskStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end

	TaskRuntime.wait(0.03)
	childTaskExited = true
end)

while not childTaskStarted do
	TaskRuntime.wait(0)
end

local awaitedCleanupSucceeded, awaitedCleanupError = parentScope:DestroyAndAwait("recursive shutdown test", 1)
expect(awaitedCleanupSucceeded, "recursive DestroyAndAwait should complete: " .. tostring(awaitedCleanupError))
expect(childTaskExited, "DestroyAndAwait should wait for child-scope tasks to exit")
expect(childScope:IsCleanupComplete(), "child scope should report cleanup complete")
expect(parentScope:IsCleanupComplete(), "parent scope should report cleanup complete")

local cleanupOrder = {}
local cleanupScope = TaskRuntime.scope("CleanupOrder")
cleanupScope:Add(function()
	table.insert(cleanupOrder, "first")
end)
cleanupScope:Add(function()
	table.insert(cleanupOrder, "second")
end)

local scopedDelayRan = false
local scopedDelay = cleanupScope:Delay(0.05, function()
	scopedDelayRan = true
end)

expect(cleanupScope:Destroy("self-test complete"), "scope should destroy exactly once")
TaskRuntime.wait(0.1)
expect(cleanupOrder[1] == "second" and cleanupOrder[2] == "first", "cleanup must run in reverse order")
expect(not scopedDelayRan, "destroying a scope should cancel its pending tasks")
expect(scopedDelay.State == "cancelled", "scope-owned task should expose cancelled state")
expect(cleanupScope:IsCleanupComplete(), "scope with only pending tasks should complete cleanup immediately")
expect(not cleanupScope:Destroy(), "destroying a scope twice should be harmless")

local capturedError = nil
TaskRuntime.setErrorHandler(function(message)
	capturedError = message
end)

local failed = TaskRuntime.spawn(function()
	error("expected failure")
end)

local failedSuccessfully, failureMessage = failed:Await()
TaskRuntime.setErrorHandler(nil)

expect(not failedSuccessfully, "failing task should report failure")
expect(failed.State == "failed", "failing task should expose failed state")
expect(capturedError ~= nil, "custom error handler should receive failures")
expect(failureMessage ~= nil, "Await should return failure message")
expect(TaskRuntime.getActiveCount() == 0, "all self-test tasks should be released")

print("TaskRuntime self-test passed")
