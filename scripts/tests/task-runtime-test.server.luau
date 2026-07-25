-- TaskRuntime self-test.
-- Link this file to a ServerScript under ScriptService and run a local playtest.

local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])

local function expect(condition, message)
	if not condition then
		error("TaskRuntime self-test failed: " .. message)
	end
end

local function expectContains(value, fragment, message)
	expect(type(value) == "string" and string.find(value, fragment, 1, true) ~= nil, message)
end

local capturedTaskErrors = {}
local capturedCleanupErrors = {}

TaskRuntime.setErrorHandler(function(message, handle)
	table.insert(capturedTaskErrors, {
		Message = message,
		Handle = handle,
	})
end)

TaskRuntime.setCleanupErrorHandler(function(message, scope, record)
	table.insert(capturedCleanupErrors, {
		Message = message,
		Scope = scope,
		Record = record,
	})
end)

-- Basic execution, arguments, results, names, metadata, and elapsed time.
local completed = TaskRuntime.spawn(function(token, left, right)
	expect(not token:IsCancelled(), "new task token should be active")
	TaskRuntime.wait(0.01)
	return left + right, "done"
end, 2, 3)

completed:SetName("addition-test")
completed:SetMetadata("suite", "core")
local completedSuccessfully, sum, label = completed:Await()
expect(completedSuccessfully, "spawned task should complete")
expect(sum == 5 and label == "done", "spawned task should preserve arguments and results")
expect(completed.Name == "addition-test", "SetName should rename a task")
expect(completed:GetMetadata("suite") == "core", "task metadata should round-trip")
expect(completed:GetElapsedTime() >= 0, "elapsed time should be non-negative")

-- Completion observers execute exactly once and support disconnection.
local completionCount = 0
local observedState = nil
local observed = TaskRuntime.delay(0.01, function()
	return "observed"
end)
local completionConnection = observed:OnComplete(function(handle)
	completionCount = completionCount + 1
	observedState = handle.State
end)
expect(completionConnection.Connected, "OnComplete should return a connected handle")
observed:Await()
expect(completionCount == 1 and observedState == "completed", "completion observer should run once")
expect(not completionConnection.Connected, "completion connection should disconnect after firing")

local disconnectedCompletionRan = false
local disconnectedCompletionTask = TaskRuntime.delay(0.01, function() end)
local disconnectedCompletion = disconnectedCompletionTask:OnComplete(function()
	disconnectedCompletionRan = true
end)
expect(disconnectedCompletion:Disconnect(), "completion observer should disconnect")
disconnectedCompletionTask:Await()
expect(not disconnectedCompletionRan, "disconnected completion observer must not run")

local lateCompletionCount = 0
local lateCompletionConnection = completed:OnComplete(function(handle)
	lateCompletionCount = lateCompletionCount + 1
	expect(handle == completed, "late completion observer should receive the task")
end)
expect(lateCompletionCount == 1, "late completion observer should run immediately")
expect(not lateCompletionConnection.Connected, "late completion connection should be disconnected")

-- Await timeout is bounded and does not cancel the underlying task.
local bounded = TaskRuntime.delay(0.05, function()
	return "late result"
end)
local boundedSuccess, boundedReason = bounded:Await(0.005)
expect(not boundedSuccess and boundedReason == "timeout", "Await should return timeout")
expect(not bounded:IsCancelled(), "timed-out Await should not cancel its task")
local boundedEventuallySucceeded, boundedValue = bounded:Await()
expect(boundedEventuallySucceeded and boundedValue == "late result", "task should remain awaitable after timeout")

-- Pending cancellation prevents delayed work from executing.
local delayedRan = false
local delayed = TaskRuntime.delay(0.05, function()
	delayedRan = true
end)
expect(TaskRuntime.cancel(delayed, "test cancellation"), "pending delay should cancel")
TaskRuntime.wait(0.08)
expect(not delayedRan, "cancelled delay must not execute")
expect(delayed.State == "cancelled", "cancelled pending task should finish immediately")

-- Running cancellation remains cooperative and invokes cancellation observers.
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

expect(cancellationConnection ~= nil and cancellationConnection.Connected, "OnCancel should return a connection")
expect(running:Cancel("cooperative cancellation test"), "running task should accept cancellation")
expect(cancellationCallbackCount == 1, "OnCancel should run synchronously and once")
expect(cancellationCallbackReason == "cooperative cancellation test", "OnCancel should receive the reason")
expect(running.State == "cancelling", "running task should enter cancelling state")
expect(not running:IsDone(), "cancelling task should remain active until callback exits")
expect(running.Token:GetReason() == "cooperative cancellation test", "token should expose its reason")

local throwSucceeded, throwError = pcall(function()
	running.Token:ThrowIfCancelled()
end)
expect(not throwSucceeded, "ThrowIfCancelled should throw after cancellation")
expectContains(tostring(throwError), "cooperative cancellation test", "ThrowIfCancelled should include the reason")

local lateCancellationCount = 0
local lateCancellationConnection = running.Token:OnCancel(function(reason)
	lateCancellationCount = lateCancellationCount + 1
	expect(reason == "cooperative cancellation test", "late OnCancel should receive the reason")
end)
expect(lateCancellationCount == 1, "late OnCancel should run immediately")
expect(not lateCancellationConnection.Connected, "late OnCancel connection should be disconnected")

allowRunningTaskToExit = true
local runningSucceeded, runningReason = running:Await()
expect(not runningSucceeded and runningReason == "cooperative cancellation test", "Await should return cancellation")
expect(running.State == "cancelled", "running task should become cancelled after callback exits")

-- Linked cancellation sources propagate parent cancellation and can be independently destroyed.
local parentSource = TaskRuntime.cancellationSource()
local childSource = TaskRuntime.cancellationSource(parentSource.Token)
expect(not childSource:IsCancelled(), "linked child source should start active")
parentSource:Cancel("parent stopped")
expect(childSource:IsCancelled(), "parent cancellation should reach child source")
expect(childSource.Token:GetReason() == "parent stopped", "linked source should preserve reason")
expect(not childSource:Cancel("again"), "cancellation source should be idempotent")

local independentSource = TaskRuntime.cancellationSource()
expect(independentSource:Destroy("source complete"), "Destroy should cancel a source")
expect(independentSource.Token:GetReason() == "source complete", "Destroy should preserve source reason")

-- CancelAfter and withTimeout request cooperative cancellation.
local timeoutStarted = false
local timed = TaskRuntime.withTimeout(0.02, function(token)
	timeoutStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)
while not timeoutStarted do
	TaskRuntime.wait(0)
end
local timedSucceeded, timedReason = timed:Await(1)
expect(not timedSucceeded and timedReason == "timeout", "withTimeout should cancel with timeout reason")
expect(timed.State == "cancelled", "timed task should finish cancelled")

local manualTimeoutStarted = false
local manuallyTimed = TaskRuntime.spawn(function(token)
	manualTimeoutStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)
manuallyTimed:SetName("manual-timeout")
while not manualTimeoutStarted do
	TaskRuntime.wait(0)
end
local cancellationTimer = manuallyTimed:CancelAfter(0.02, "manual deadline")
expect(cancellationTimer ~= nil, "CancelAfter should return its timer")
local manuallyTimedSuccess, manuallyTimedReason = manuallyTimed:Await(1)
expect(not manuallyTimedSuccess and manuallyTimedReason == "manual deadline", "CancelAfter should use custom reason")

-- Retry succeeds after transient failures and exposes retry callbacks.
local retryAttempts = 0
local retryNotifications = 0
local retried = TaskRuntime.retry(4, function(token, attempt, expected)
	retryAttempts = retryAttempts + 1
	expect(attempt == retryAttempts, "retry attempt number should be sequential")
	expect(expected == "payload", "retry should preserve arguments")
	if attempt < 3 then
		error("transient " .. tostring(attempt))
	end
	return "recovered", attempt
end, {
	delaySeconds = 0.005,
	backoffFactor = 2,
	maxDelaySeconds = 0.02,
	onRetry = function(message, attempt, nextDelay)
		retryNotifications = retryNotifications + 1
		expectContains(message, "transient", "onRetry should receive the failure")
		expect(attempt < 3 and nextDelay >= 0, "onRetry should receive retry details")
	end,
}, "payload")

local retrySucceeded, retryValue, successfulAttempt = retried:Await(1)
expect(retrySucceeded and retryValue == "recovered" and successfulAttempt == 3, "retry should return success values")
expect(retryAttempts == 3 and retryNotifications == 2, "retry should stop after success")
expect(retried.Kind == "retry", "retry task should expose retry kind")

local stoppedRetryAttempts = 0
local stoppedRetry = TaskRuntime.retry(5, function()
	stoppedRetryAttempts = stoppedRetryAttempts + 1
	error("permanent")
end, {
	shouldRetry = function(message, attempt)
		expectContains(message, "permanent", "shouldRetry should receive the failure")
		return attempt < 2
	end,
})
local stoppedRetrySucceeded, stoppedRetryError = stoppedRetry:Await(1)
expect(not stoppedRetrySucceeded, "retry should fail when shouldRetry stops it")
expectContains(stoppedRetryError, "permanent", "retry failure should preserve final error")
expect(stoppedRetryAttempts == 2, "shouldRetry should stop additional attempts")

-- all composes successful results in input order.
local allFirst = TaskRuntime.delay(0.02, function()
	return "first", 1
end)
local allSecond = TaskRuntime.delay(0.005, function()
	return "second", 2
end)
local allAggregate = TaskRuntime.all({ allFirst, allSecond })
local allSucceeded, allResults = allAggregate:Await(1)
expect(allSucceeded, "all should complete when every child succeeds")
expect(allResults[1][1] == "first" and allResults[1][2] == 1, "all should preserve first result tuple")
expect(allResults[2][1] == "second" and allResults[2][2] == 2, "all should preserve input order")
expect(allAggregate.Kind == "all", "all aggregate should expose all kind")

-- all fails fast and cancels unfinished siblings.
local allFailure = TaskRuntime.delay(0.005, function()
	error("group failure")
end)
local allSiblingStarted = false
local allSibling = TaskRuntime.spawn(function(token)
	allSiblingStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)
while not allSiblingStarted do
	TaskRuntime.wait(0)
end
local failedAll = TaskRuntime.all({ allFailure, allSibling })
local failedAllSucceeded, failedAllError = failedAll:Await(1)
expect(not failedAllSucceeded, "all should fail when a child fails")
expectContains(failedAllError, "group failure", "all should expose child failure")
allSibling:Await(1)
expect(allSibling.State == "cancelled", "all should cancel unfinished siblings by default")

-- Non-fail-fast all returns structured outcomes.
local outcomeSuccess = TaskRuntime.spawn(function()
	return 10
end)
local outcomeFailure = TaskRuntime.spawn(function()
	error("outcome failure")
end)
local outcomesTask = TaskRuntime.all({ outcomeSuccess, outcomeFailure }, {
	failFast = false,
	cancelRemaining = false,
})
local outcomesSucceeded, outcomes = outcomesTask:Await(1)
expect(outcomesSucceeded, "non-fail-fast all should complete with outcomes")
expect(outcomes[1].Success and outcomes[1].Values[1] == 10, "successful outcome should include values")
expect(not outcomes[2].Success and outcomes[2].State == "failed", "failed outcome should be represented")
expectContains(outcomes[2].Error, "outcome failure", "failed outcome should include error")

-- race returns the winner and cancels losers.
local raceWinner = TaskRuntime.delay(0.005, function()
	return "winner"
end)
local raceLoserStarted = false
local raceLoser = TaskRuntime.spawn(function(token)
	raceLoserStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)
while not raceLoserStarted do
	TaskRuntime.wait(0)
end
local raced = TaskRuntime.race({ raceWinner, raceLoser })
local raceSucceeded, winnerIndex, winnerValue = raced:Await(1)
expect(raceSucceeded and winnerIndex == 1 and winnerValue == "winner", "race should return winner index and values")
raceLoser:Await(1)
expect(raceLoser.State == "cancelled", "race should cancel losers by default")
expect(raced.Kind == "race", "race aggregate should expose race kind")

-- Completed scope-owned tasks detach automatically.
local autoScope = TaskRuntime.scope("AutomaticTaskRemoval")
local allowScopedTaskToFinish = false
local scopedCompletion = autoScope:Spawn(function()
	while not allowScopedTaskToFinish do
		TaskRuntime.wait(0)
	end
	return "complete"
end)
expect(autoScope:GetCount() == 1, "scope should own scheduled task")
allowScopedTaskToFinish = true
expect(scopedCompletion:Await(), "scope-owned task should complete")
expect(autoScope:GetCount() == 0, "completed task should detach from scope")
autoScope:Destroy()

-- Named resources replace and clean previous values.
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
expect(keyedScope:Get("RoundTimer") == firstResource and keyedScope:Has("RoundTimer"), "Set should register named resource")
keyedScope:Set("RoundTimer", secondResource, "Destroy")
expect(firstResource.Destroyed, "replacing a key should clean previous resource")
expect(keyedScope:GetCount() == 1, "replacement should not duplicate entries")
local removedResource = keyedScope:Remove("RoundTimer")
expect(removedResource == secondResource and secondResource.Destroyed, "Remove should clean and return resource")
expect(not keyedScope:Has("RoundTimer") and keyedScope:GetCount() == 0, "removed key should detach")
keyedScope:Destroy()

-- Repeating tasks never overlap and stop cleanly.
local repeatingScope = TaskRuntime.scope("RepeatingTasks")
local repeatCount = 0
local simultaneousRepeats = 0
local maximumSimultaneousRepeats = 0
local repeatingTask = repeatingScope:Every(0.01, function()
	simultaneousRepeats = simultaneousRepeats + 1
	maximumSimultaneousRepeats = math.max(maximumSimultaneousRepeats, simultaneousRepeats)
	repeatCount = repeatCount + 1
	TaskRuntime.wait(0.02)
	simultaneousRepeats = simultaneousRepeats - 1
end)
while repeatCount < 3 do
	TaskRuntime.wait(0)
end
local repeatingCleanupSucceeded, repeatingCleanupError = repeatingScope:DestroyAndAwait("repeating complete", 1)
expect(repeatingCleanupSucceeded, "DestroyAndAwait should finish repeating task: " .. tostring(repeatingCleanupError))
expect(repeatingTask.State == "cancelled", "repeating task should finish cancelled")
expect(repeatingTask.Iterations >= 3 and maximumSimultaneousRepeats == 1, "repeating callbacks must be sequential")
local repeatCountAfterCleanup = repeatCount
TaskRuntime.wait(0.04)
expect(repeatCount == repeatCountAfterCleanup, "repeating task must stop after cleanup")

-- Nested DestroyAndAwait includes running tasks in child scopes.
local parentScope = TaskRuntime.scope("AwaitedParent")
local childScope = parentScope:Child("AwaitedChild")
local childTaskStarted = false
local childTaskExited = false
childScope:Spawn(function(token)
	childTaskStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
	TaskRuntime.wait(0.02)
	childTaskExited = true
end)
while not childTaskStarted do
	TaskRuntime.wait(0)
end
local parentCleanupSucceeded, parentCleanupError = parentScope:DestroyAndAwait("recursive shutdown", 1)
expect(parentCleanupSucceeded, "recursive cleanup should complete: " .. tostring(parentCleanupError))
expect(childTaskExited and childScope:IsCleanupComplete() and parentScope:IsCleanupComplete(), "parent should await child work")

-- Cleanup is reverse-order and completion observers fire once.
local cleanupOrder = {}
local cleanupScope = TaskRuntime.scope("CleanupOrder")
local scopeCompletionCount = 0
cleanupScope:OnCleanupComplete(function(scope)
	scopeCompletionCount = scopeCompletionCount + 1
	expect(scope == cleanupScope, "scope completion should receive scope")
end)
cleanupScope:Add(function()
	table.insert(cleanupOrder, "first")
end)
cleanupScope:Add(function()
	table.insert(cleanupOrder, "second")
end)
expect(cleanupScope:Destroy("order test"), "scope should destroy once")
expect(cleanupOrder[1] == "second" and cleanupOrder[2] == "first", "cleanup must run in reverse order")
expect(scopeCompletionCount == 1, "scope completion observer should run once")
expect(not cleanupScope:Destroy(), "destroying scope twice should be harmless")

-- Cleanup failures are collected without preventing later cleanup.
local cleanupFailureScope = TaskRuntime.scope("CleanupFailures")
local laterCleanupRan = false
cleanupFailureScope:Add(function()
	laterCleanupRan = true
end)
cleanupFailureScope:Add(function()
	error("expected cleanup failure")
end)
local cleanupFailureSucceeded, cleanupFailureReason, cleanupFailureRecords = cleanupFailureScope:DestroyAndAwait("failure test", 1)
expect(not cleanupFailureSucceeded and cleanupFailureReason == "cleanup failed", "DestroyAndAwait should report cleanup errors")
expect(laterCleanupRan, "one cleanup failure must not stop remaining cleanup")
expect(#cleanupFailureRecords == 1 and cleanupFailureScope:HasCleanupErrors(), "scope should retain cleanup error records")
expectContains(cleanupFailureRecords[1].Message, "expected cleanup failure", "cleanup record should include failure")

-- Supervising scopes can destroy siblings when an owned task fails.
local supervisedScope = TaskRuntime.scope("Supervisor", {
	cancelOnTaskFailure = true,
})
local supervisedSiblingStarted = false
local supervisedSibling = supervisedScope:Spawn(function(token)
	supervisedSiblingStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)
while not supervisedSiblingStarted do
	TaskRuntime.wait(0)
end
local supervisedFailure = supervisedScope:Spawn(function()
	error("supervised failure")
end)
supervisedFailure:Await(1)
local supervisedCleanupSucceeded, supervisedCleanupError = supervisedScope:DestroyAndAwait("ensure supervised cleanup", 1)
expect(supervisedCleanupSucceeded, "supervised scope should cleanly stop siblings: " .. tostring(supervisedCleanupError))
supervisedSibling:Await(1)
expect(supervisedScope:IsDestroyed(), "failed owned task should destroy supervising scope")
expect(supervisedSibling.State == "cancelled", "supervisor should cancel sibling tasks")
local taskFailures = supervisedScope:GetTaskFailures()
expect(#taskFailures == 1, "supervisor should record owned task failure")
expectContains(taskFailures[1].Error, "supervised failure", "task failure record should include error")

-- Snapshot and active-count filtering expose runtime diagnostics.
local diagnosticStarted = false
local diagnosticTask = TaskRuntime.spawn(function(token)
	diagnosticStarted = true
	while not token:IsCancelled() do
		TaskRuntime.wait(0)
	end
end)
diagnosticTask:SetName("diagnostic-worker")
diagnosticTask:SetMetadata("system", "self-test")
while not diagnosticStarted do
	TaskRuntime.wait(0)
end
local snapshot = TaskRuntime.getSnapshot()
expect(snapshot.ActiveCount >= 1, "snapshot should include active tasks")
expect(snapshot.ByKind.spawn ~= nil and TaskRuntime.getActiveCount("spawn") >= 1, "snapshot should group by kind")
local foundDiagnosticTask = false
for _, taskInfo in ipairs(snapshot.Tasks) do
	if taskInfo.Id == diagnosticTask.Id then
		foundDiagnosticTask = true
		expect(taskInfo.Name == "diagnostic-worker", "snapshot should include task name")
		expect(taskInfo.Metadata.system == "self-test", "snapshot should include metadata")
	end
end
expect(foundDiagnosticTask, "snapshot should list diagnostic task")
diagnosticTask:Cancel("diagnostic complete")
diagnosticTask:Await(1)

-- Expected failures should have reached the configured handlers.
expect(#capturedTaskErrors >= 4, "task error handler should receive task and aggregate failures")
expect(#capturedCleanupErrors >= 1, "cleanup error handler should receive cleanup failures")

TaskRuntime.setErrorHandler(nil)
TaskRuntime.setCleanupErrorHandler(nil)

-- All test-owned work must be gone. CancelAfter timer cleanup may need one frame.
TaskRuntime.wait(0)
expect(TaskRuntime.getActiveCount() == 0, "all self-test tasks should be released")

print("TaskRuntime self-test passed")
