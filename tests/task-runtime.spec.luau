-- Run this file manually from Creator after linking TaskRuntime under ScriptService.

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

-- A running task must remain active in the cancelling state until its callback
-- observes the token and exits.
local runningStarted = false
local allowRunningTaskToExit = false
local running = TaskRuntime.spawn(function(token)
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

expect(running:Cancel("cooperative cancellation test"), "running task should accept cancellation")
expect(running.State == "cancelling", "running task should enter cancelling state")
expect(not running:IsDone(), "cancelling task should not report done before callback exits")
expect(running.Token:GetReason() == "cooperative cancellation test", "token should expose cancellation reason")

allowRunningTaskToExit = true
local runningSucceeded, runningReason = running:Await()
expect(not runningSucceeded, "cancelled running task should not report success")
expect(runningReason == "cooperative cancellation test", "Await should return cancellation reason")
expect(running.State == "cancelled", "running task should finish cancelled after callback exits")

-- Completed tasks should detach themselves from long-lived scopes.
local autoScope = TaskRuntime.scope("AutomaticTaskRemoval")
local scopedCompletion = autoScope:Spawn(function()
	return "complete"
end)
expect(autoScope:GetCount() == 1, "scope should initially own scheduled task")
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
