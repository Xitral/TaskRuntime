-- Run this file manually from Creator after linking TaskRuntime under ScriptService.

local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])

local function expect(condition, message)
	if not condition then
		error("TaskRuntime self-test failed: " .. message)
	end
end

local completed = TaskRuntime.spawn(function(left, right)
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
expect(delayed.State == "cancelled", "cancelled task should expose cancelled state")

local cleanupOrder = {}
local scope = TaskRuntime.scope("SelfTest")
scope:Add(function()
	table.insert(cleanupOrder, "first")
end)
scope:Add(function()
	table.insert(cleanupOrder, "second")
end)

local scopedDelayRan = false
local scopedDelay = scope:Delay(0.05, function()
	scopedDelayRan = true
end)

expect(scope:Destroy("self-test complete"), "scope should destroy exactly once")
TaskRuntime.wait(0.1)
expect(cleanupOrder[1] == "second" and cleanupOrder[2] == "first", "cleanup must run in reverse order")
expect(not scopedDelayRan, "destroying a scope should cancel its pending tasks")
expect(scopedDelay.State == "cancelled", "scope-owned task should expose cancelled state")
expect(not scope:Destroy(), "destroying a scope twice should be harmless")

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
expect(failureMessage ~= nil, "Await should return the failure message")
expect(TaskRuntime.getActiveCount() == 0, "all self-test tasks should be released")

print("TaskRuntime self-test passed")
