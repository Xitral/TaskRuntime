-- TaskRuntime self-test.
-- Link this file to a ServerScript under ScriptService and run a local playtest.

local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])

local function expect(condition, message)
	if not condition then
		error("TaskRuntime self-test failed: " .. message)
	end
end

local function expectEqual(actual, expected, message)
	if actual ~= expected then
		error("TaskRuntime self-test failed: " .. message .. " (" .. tostring(actual) .. " ~= " .. tostring(expected) .. ")")
	end
end

local function expectContains(value, fragment, message)
	expect(type(value) == "string" and string.find(value, fragment, 1, true) ~= nil, message)
end

expect(type(TaskRuntime.VERSION) == "string", "VERSION should be available")

local capturedTaskErrors = {}
local capturedCleanupErrors = {}
TaskRuntime.setErrorHandler(function(message, handle, taskError)
	table.insert(capturedTaskErrors, {
		Message = message,
		Handle = handle,
		Error = taskError,
	})
end)
TaskRuntime.setCleanupErrorHandler(function(message, scope, record)
	table.insert(capturedCleanupErrors, {
		Message = message,
		Scope = scope,
		Record = record,
	})
end)

-- Basic task execution, metadata, results, and completion observers.
local completed = TaskRuntime.spawn(function(token, left, right)
	expect(not token:IsCancelled(), "new token should start active")
	return left + right, left * right
end, 4, 6)
completed:SetName("calculation")
completed:SetMetadata("suite", "core")

local completionCount = 0
local completionConnection = completed:OnComplete(function(handle)
	completionCount = completionCount + 1
	expectEqual(handle.Name, "calculation", "completion observer should receive the task")
end)

local completedSuccessfully, sum, product = completed:Await(1)
expect(completedSuccessfully, "spawned task should complete")
expectEqual(sum, 10, "spawn should preserve arguments")
expectEqual(product, 24, "spawn should preserve multiple results")
expectEqual(completionCount, 1, "completion observer should fire once")
expect(not completionConnection.Connected, "completion connection should disconnect after firing")
expectEqual(completed:GetMetadata("suite"), "core", "metadata should round-trip")
expect(completed:GetElapsedTime() >= 0, "elapsed time should be non-negative")

local completedOutcome = completed:GetOutcome()
expect(completedOutcome.Success, "completed outcome should report success")
expectEqual(completedOutcome.Values[1], 10, "completed outcome should include values")

-- Await timeout does not cancel the task.
-- Use clearly separated deadlines because Creator/server waits resume on scheduler ticks.
local delayedResult = TaskRuntime.delay(0.5, function()
	return "later"
end)
local timedOutcome = delayedResult:AwaitOutcome(0.05)
expectEqual(timedOutcome.Status, "timeout", "AwaitOutcome should report timeout")
expectEqual(timedOutcome.Error.Code, "AWAIT_TIMEOUT", "timeout outcome should have a code")
expect(not delayedResult:IsCancelled(), "await timeout should not cancel the task")
local delayedSuccess, delayedValue = delayedResult:Await(1)
expect(delayedSuccess and delayedValue == "later", "task should remain awaitable after timeout")

-- Cooperative cancellation and cancellation observers.
local workerStarted = false
local cancellationReason = nil
local worker = TaskRuntime.spawn(function(token)
	workerStarted = true
	token:OnCancel(function(reason)
		cancellationReason = reason
	end)
	while not token:IsCancelled() do
		token:Wait(0)
	end
end)
while not workerStarted do
	TaskRuntime.wait(0)
end
worker:Cancel("worker stopped")
local workerSuccess, workerReason = worker:Await(1)
expect(not workerSuccess and workerReason == "worker stopped", "cancelled task should return its reason")
expectEqual(cancellationReason, "worker stopped", "OnCancel should receive the reason")

-- Deadlines and timeout cancellation.
local timedWorker = TaskRuntime.withTimeout(0.02, function(token)
	while not token:IsCancelled() do
		token:Wait(0)
	end
end)
local timedWorkerSuccess, timedWorkerReason = timedWorker:Await(1)
expect(not timedWorkerSuccess and timedWorkerReason == "timeout", "withTimeout should cancel with timeout")
expect(timedWorker.DeadlineAt ~= nil, "timed task should expose its deadline")

-- Structured errors and outcomes.
local failed = TaskRuntime.spawn(function()
	error("expected structured failure")
end)
local failedOutcome = failed:AwaitOutcome(1)
expectEqual(failedOutcome.Status, "failed", "failing task should produce failed outcome")
expectEqual(failedOutcome.Error.Code, "CALLBACK_FAILED", "failure should include a structured code")
expectContains(failedOutcome.Error.Message, "expected structured failure", "structured error should preserve message")
expectEqual(failedOutcome.Error.TaskName, failed.Name, "structured error should identify the task")

-- Then, Catch, and Finally chains.
local finallyRan = false
local chained = TaskRuntime.spawn(function()
	return 5
end):Then(function(token, value)
	return value * 3
end):Finally(function(token, outcome)
	finallyRan = true
	expect(outcome.Success, "Finally should receive successful outcome")
end)
local chainedSuccess, chainedValue = chained:Await(1)
expect(chainedSuccess and chainedValue == 15, "Then should transform results")
expect(finallyRan, "Finally should run")

local recovered = TaskRuntime.spawn(function()
	error("recover me")
end):Catch(function(token, taskError)
	return taskError.Code
end)
local recoveredSuccess, recoveredCode = recovered:Await(1)
expect(recoveredSuccess and recoveredCode == "CALLBACK_FAILED", "Catch should recover a failed task")

-- Retrying with backoff and jitter support.
local retryAttempts = 0
local retried = TaskRuntime.retry(4, function(token, attempt)
	retryAttempts = retryAttempts + 1
	if attempt < 3 then
		error("temporary")
	end
	return "recovered", attempt
end, {
	delaySeconds = 0.005,
	backoffFactor = 2,
	maxDelaySeconds = 0.02,
	jitter = 0,
})
local retrySuccess, retryValue, successfulAttempt = retried:Await(1)
expect(retrySuccess and retryValue == "recovered", "retry should return successful result")
expectEqual(successfulAttempt, 3, "retry should expose successful attempt")
expectEqual(retryAttempts, 3, "retry should stop after success")

-- Waiting from inside a task callback must not be mistaken for callback completion.
local nestedAwait = TaskRuntime.spawn(function()
	local child = TaskRuntime.delay(0.05, function()
		return "child done"
	end)
	local childSuccess, childValue = child:Await(1)
	expect(childSuccess and childValue == "child done", "task callback should await its child")
	return "parent done"
end)
local nestedAwaitSuccess, nestedAwaitValue = nestedAwait:Await(2)
expect(nestedAwaitSuccess and nestedAwaitValue == "parent done", "nested await should complete the parent")

-- all, settle, race, and any use completion callbacks rather than frame polling.
local first = TaskRuntime.delay(0.02, function()
	return "first"
end)
local second = TaskRuntime.delay(0.005, function()
	return "second"
end)
local allTask = TaskRuntime.all({ first, second })
local allSuccess, allResults = allTask:Await(1)
expect(allSuccess, "all should complete when every child succeeds")
expectEqual(allResults[1][1], "first", "all should preserve input order")
expectEqual(allResults[2][1], "second", "all should preserve second result")

local settleSuccessTask = TaskRuntime.spawn(function()
	return 10
end)
local settleFailureTask = TaskRuntime.spawn(function()
	error("settled failure")
end)
local settled = TaskRuntime.settle({ settleSuccessTask, settleFailureTask })
local settledSuccess, outcomes = settled:Await(1)
expect(settledSuccess, "settle should complete with outcomes")
expect(outcomes[1].Success, "settle should represent success")
expect(not outcomes[2].Success, "settle should represent failure")
expectEqual(outcomes[2].Error.Code, "CALLBACK_FAILED", "settled failure should retain structured error")

local raceFast = TaskRuntime.delay(0.005, function()
	return "fast"
end)
local raceSlow = TaskRuntime.delay(0.1, function()
	return "slow"
end)
local raced = TaskRuntime.race({ raceFast, raceSlow })
local raceSuccess, raceIndex, raceValue = raced:Await(1)
expect(raceSuccess and raceIndex == 1 and raceValue == "fast", "race should return the first terminal task")
expectEqual(raceSlow.State, "cancelled", "race should cancel losers")

local anyFailure = TaskRuntime.spawn(function()
	error("not this one")
end)
local anySuccessTask = TaskRuntime.delay(0.005, function()
	return "winner"
end)
local anyTask = TaskRuntime.any({ anyFailure, anySuccessTask })
local anySuccess, anyIndex, anyValue = anyTask:Await(1)
expect(anySuccess and anyIndex == 2 and anyValue == "winner", "any should return the first successful task")

-- Semaphores and mapLimit enforce bounded concurrency.
local simultaneous = 0
local maximumSimultaneous = 0
local mapped = TaskRuntime.mapLimit({ 1, 2, 3, 4, 5 }, 2, function(token, value)
	simultaneous = simultaneous + 1
	maximumSimultaneous = math.max(maximumSimultaneous, simultaneous)
	token:Wait(0.01)
	simultaneous = simultaneous - 1
	return value * 10
end)
local mappedSuccess, mappedResults = mapped:Await(2)
expect(mappedSuccess, "mapLimit should complete")
expectEqual(maximumSimultaneous, 2, "mapLimit should enforce concurrency")
expectEqual(mappedResults[5][1], 50, "mapLimit should preserve input order")

local semaphore = TaskRuntime.semaphore(1)
local permitSuccess = semaphore:Acquire(nil, 0.1)
expect(permitSuccess, "semaphore should grant available permit")
expectEqual(semaphore.Available, 0, "acquire should consume permit")
semaphore:Release()
expectEqual(semaphore.Available, 1, "release should restore permit")

-- Queue work uses the same bounded concurrency primitive.
local queue = TaskRuntime.queue(2, { name = "SelfTestQueue" })
local queueActive = 0
local queueMaximum = 0
local queueTasks = {}
for index = 1, 4 do
	queueTasks[index] = queue:Add(function(token, value)
		queueActive = queueActive + 1
		queueMaximum = math.max(queueMaximum, queueActive)
		token:Wait(0.01)
		queueActive = queueActive - 1
		return value
	end, index)
end
local queueGroup = TaskRuntime.all(queueTasks)
expect(queueGroup:Await(2), "queue tasks should complete")
expectEqual(queueMaximum, 2, "queue should enforce concurrency")
queue:Close("test complete")

-- Debounce replaces pending work. Throttle suppresses calls inside its window.
local debounceCount = 0
local firstDebounce = TaskRuntime.debounce("self-test", 0.2, function()
	debounceCount = debounceCount + 1
end)
TaskRuntime.wait(0.05)
local secondDebounce = TaskRuntime.debounce("self-test", 0.2, function()
	debounceCount = debounceCount + 1
end)
expectEqual(firstDebounce.State, "cancelled", "debounce should cancel previous work")
expect(secondDebounce:Await(1), "replacement debounce should run")
expectEqual(debounceCount, 1, "only the latest debounce should execute")

local firstThrottle = TaskRuntime.throttle("self-test", 0.2, function()
	return "first"
end)
local blockedThrottle, activeThrottle = TaskRuntime.throttle("self-test", 0.2, function()
	return "blocked"
end)
expect(blockedThrottle == nil and activeThrottle == firstThrottle, "throttle should return the active call")
expect(firstThrottle:Await(1), "first throttle call should complete")
TaskRuntime.wait(0.25)
local laterThrottle = TaskRuntime.throttle("self-test", 0.2, function()
	return "later"
end)
local laterThrottleSuccess, laterThrottleValue = laterThrottle:Await(1)
expect(laterThrottleSuccess and laterThrottleValue == "later", "throttle should allow a later call")

-- Task contexts own their child tasks and cancel them when the root exits.
local contextScope = TaskRuntime.scope("ContextTest")
local childCancelled = false
local rootContextTask = contextScope:Run(function(context, token)
	context:Spawn(function(childToken)
		childToken:OnCancel(function()
			childCancelled = true
		end)
		while not childToken:IsCancelled() do
			childToken:Wait(0.01)
		end
	end):SetName("ContextChild")
	token:Wait(0.02)
	return "root done"
end, {
	name = "ContextRoot",
	childShutdownTimeout = 1,
	cancelOnChildFailure = true,
})
local rootContextSuccess, rootContextValue = rootContextTask:Await(2)
expect(rootContextSuccess and rootContextValue == "root done", "context root should return its result")
expect(childCancelled, "context should cancel child tasks on exit")
expect(rootContextTask.ParentTaskId == nil, "root context should not invent a parent")

-- Scope cleanup deadlines continue after one cleanup operation times out.
local timedCleanupFinished = false
local cleanupScope = TaskRuntime.scope("CleanupTimeoutTest", {
	resourceCleanupTimeout = 0.05,
	cleanupTimeout = 0.5,
})
cleanupScope:Add(function()
	TaskRuntime.wait(0.2)
	timedCleanupFinished = true
end, {
	name = "SlowCleanup",
	timeout = 0.05,
})
local laterCleanupRan = false
cleanupScope:Add(function()
	laterCleanupRan = true
end, {
	name = "LaterCleanup",
})
cleanupScope:Destroy("cleanup test")
local cleanupSuccess, cleanupReason, cleanupErrors = cleanupScope:DestroyAndAwait("cleanup test", 1)
expect(not cleanupSuccess and cleanupReason == "cleanup failed", "cleanup timeout should be reported")
expect(#cleanupErrors >= 1, "cleanup timeout should produce an error record")
expectEqual(cleanupErrors[1].Code, "CLEANUP_TIMEOUT", "cleanup error should have a code")
expect(laterCleanupRan, "cleanup should continue after a timeout")
TaskRuntime.wait(0.25)
expect(timedCleanupFinished, "cooperative cleanup callback should eventually exit")

-- Diagnostics include history, stats, parents, scopes, and deadlines.
TaskRuntime.configureDiagnostics({
	historySize = 200,
	captureCreationTrace = false,
})
local diagnostic = TaskRuntime.delay(0.01, function()
	return true
end)
diagnostic:SetName("DiagnosticTask")
diagnostic:SetMetadata("system", "self-test")
local activeSnapshot = TaskRuntime.getSnapshot()
expect(activeSnapshot.ActiveCount >= 1, "snapshot should include active tasks")
expect(activeSnapshot.PendingDeadlines >= 1, "snapshot should include pending deadlines")
expect(diagnostic:Await(1), "diagnostic task should complete")
local history = TaskRuntime.getHistory()
local stats = TaskRuntime.getStats()
expect(#history > 0, "history should retain completed tasks")
expect(stats.DiagnosticTask ~= nil, "stats should group by task name")
expect(stats.DiagnosticTask.AverageDuration >= 0, "stats should include average duration")

-- Virtual-time scheduler makes long timers deterministic and instant in tests.
local scheduler = TaskRuntime.TestScheduler.new(100)
local virtualRuntime = TaskRuntime.create({
	scheduler = scheduler,
	historySize = 20,
})
local virtualDelay = virtualRuntime:delay(3600, function()
	return "one hour"
end)
expectEqual(virtualDelay.State, "scheduled", "virtual delay should start scheduled")
scheduler:Advance(3599)
expect(not virtualDelay:IsDone(), "virtual delay should not run early")
scheduler:Advance(1)
local virtualSuccess, virtualValue = virtualDelay:Await()
expect(virtualSuccess and virtualValue == "one hour", "virtual scheduler should advance long delays instantly")

-- Unknown options should fail early instead of being silently ignored.
local unknownOptionSucceeded = pcall(function()
	TaskRuntime.scope("Invalid", {
		unknownOption = true,
	})
end)
expect(not unknownOptionSucceeded, "unknown scope options should be rejected")

TaskRuntime.setErrorHandler(nil)
TaskRuntime.setCleanupErrorHandler(nil)
TaskRuntime.wait(0.05)
expect(TaskRuntime.getActiveCount() == 0, "all self-test tasks should be released")
expect(#capturedTaskErrors >= 3, "expected task failures should reach the error handler")
expect(#capturedCleanupErrors >= 1, "cleanup timeout should reach the cleanup error handler")

print("TaskRuntime self-test passed")