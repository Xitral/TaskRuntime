-- TaskRuntime
-- Structured asynchronous tasks, cooperative cancellation, and deterministic cleanup for Polytoria Luau.
--
-- Design goals:
--   * predictable task state transitions
--   * cancellation that remains honest about running callbacks
--   * deterministic, reverse-order resource cleanup
--   * bounded waits, retries, and task composition
--   * observability suitable for production debugging

local TaskRuntime = {}

local TaskHandle = {}
TaskHandle.__index = TaskHandle

local CancellationToken = {}
CancellationToken.__index = CancellationToken

local CancellationSource = {}
CancellationSource.__index = CancellationSource

local CallbackConnection = {}
CallbackConnection.__index = CallbackConnection

local CleanupScope = {}
CleanupScope.__index = CleanupScope

local TERMINAL_STATES = {
	completed = true,
	cancelled = true,
	failed = true,
}

local nextTaskId = 0
local activeTasks = {}
local runtimeShuttingDown = false
local runtimeShutdownReason = nil

local function pack(...)
	return {
		n = select("#", ...),
		...,
	}
end

local function unpackPacked(values)
	return table.unpack(values, 1, values.n)
end

local function assertCallback(callback, apiName)
	if type(callback) ~= "function" then
		error(apiName .. " expects a function callback", 3)
	end
end

local function assertSeconds(seconds, apiName, allowNil)
	if seconds == nil and allowNil then
		return
	end
	if type(seconds) ~= "number" then
		error(apiName .. " expects seconds to be a number", 3)
	end
	if seconds < 0 then
		error(apiName .. " expects a non-negative duration", 3)
	end
end

local function assertTaskHandle(handle, apiName)
	if getmetatable(handle) ~= TaskHandle then
		error(apiName .. " expects a TaskHandle", 3)
	end
end

local function assertTaskList(handles, apiName, allowEmpty)
	if type(handles) ~= "table" then
		error(apiName .. " expects an array of TaskHandles", 3)
	end
	if not allowEmpty and #handles == 0 then
		error(apiName .. " expects at least one TaskHandle", 3)
	end
	for index, handle in ipairs(handles) do
		if getmetatable(handle) ~= TaskHandle then
			error(apiName .. " received a non-TaskHandle at index " .. tostring(index), 3)
		end
	end
end

local function defaultTaskErrorHandler(message, handle)
	warn(
		"[TaskRuntime] task "
			.. tostring(handle.Id)
			.. " ("
			.. tostring(handle.Name)
			.. ") failed: "
			.. tostring(message)
	)
end

local function defaultCleanupErrorHandler(message, scope)
	warn("[TaskRuntime] cleanup failed in " .. tostring(scope.Name) .. ": " .. tostring(message))
end

local taskErrorHandler = defaultTaskErrorHandler
local cleanupErrorHandler = defaultCleanupErrorHandler

local function invokeSafely(callback, contextMessage, ...)
	local succeeded, callbackError = pcall(callback, ...)
	if not succeeded then
		warn("[TaskRuntime] " .. contextMessage .. ": " .. tostring(callbackError))
	end
	return succeeded, callbackError
end

function CallbackConnection:Disconnect()
	if not self.Connected then
		return false
	end

	self.Connected = false
	local entry = self._entry
	if entry ~= nil then
		entry.Active = false
		entry.Callback = nil
	end
	self._entry = nil
	return true
end

local function disconnectedConnection()
	return setmetatable({
		Connected = false,
		_entry = nil,
	}, CallbackConnection)
end

local function registerCallback(entries, callback)
	local entry = {
		Active = true,
		Callback = callback,
	}
	table.insert(entries, entry)
	return setmetatable({
		Connected = true,
		_entry = entry,
	}, CallbackConnection)
end

local function makeToken()
	return setmetatable({
		_cancelled = false,
		_reason = nil,
		_cancelCallbacks = {},
	}, CancellationToken)
end

function CancellationToken:IsCancelled()
	return self._cancelled
end

function CancellationToken:GetReason()
	return self._reason
end

function CancellationToken:ThrowIfCancelled()
	if self._cancelled then
		error(self._reason or "cancelled", 2)
	end
end

function CancellationToken:OnCancel(callback)
	assertCallback(callback, "CancellationToken:OnCancel")

	if self._cancelled then
		invokeSafely(callback, "cancellation callback failed", self._reason)
		return disconnectedConnection()
	end

	return registerCallback(self._cancelCallbacks, callback)
end

-- Waits in short slices so cancellation can be observed before the full duration elapses.
-- Returns false when cancelled and true when the duration completes.
function CancellationToken:Wait(seconds, pollInterval)
	assertSeconds(seconds, "CancellationToken:Wait", false)
	if pollInterval ~= nil then
		assertSeconds(pollInterval, "CancellationToken:Wait", false)
	end

	if self._cancelled then
		return false
	end

	if seconds == 0 then
		wait(0)
		return not self._cancelled
	end

	local interval = pollInterval or 0.05
	if interval == 0 then
		interval = 0.05
	end

	local deadline = time() + seconds
	while not self._cancelled do
		local remaining = deadline - time()
		if remaining <= 0 then
			return true
		end
		wait(math.min(interval, remaining))
	end

	return false
end

function CancellationToken:_Cancel(reason)
	if self._cancelled then
		return false
	end

	self._cancelled = true
	self._reason = reason or "cancelled"

	local callbacks = self._cancelCallbacks
	self._cancelCallbacks = {}
	for _, entry in ipairs(callbacks) do
		if entry.Active and entry.Callback ~= nil then
			local callback = entry.Callback
			entry.Active = false
			entry.Callback = nil
			invokeSafely(callback, "cancellation callback failed", self._reason)
		end
	end

	return true
end

function CancellationSource.new(parentToken)
	if parentToken ~= nil and getmetatable(parentToken) ~= CancellationToken then
		error("CancellationSource.new expects a CancellationToken or nil", 2)
	end

	local source = setmetatable({
		Token = makeToken(),
		_parentConnection = nil,
	}, CancellationSource)

	if parentToken ~= nil then
		source._parentConnection = parentToken:OnCancel(function(reason)
			source:Cancel(reason)
		end)
	end

	return source
end

function CancellationSource:Cancel(reason)
	local changed = self.Token:_Cancel(reason)
	if self._parentConnection ~= nil then
		self._parentConnection:Disconnect()
		self._parentConnection = nil
	end
	return changed
end

function CancellationSource:IsCancelled()
	return self.Token:IsCancelled()
end

function CancellationSource:Destroy(reason)
	return self:Cancel(reason or "cancellation source destroyed")
end

local function makeHandle(kind)
	nextTaskId = nextTaskId + 1
	local id = nextTaskId

	local handle = setmetatable({
		Id = id,
		Kind = kind,
		Name = kind .. "#" .. tostring(id),
		State = "scheduled",
		Cancelled = false,
		CancelReason = nil,
		CreatedAt = time(),
		StartedAt = nil,
		FinishedAt = nil,
		Error = nil,
		Results = nil,
		Iterations = 0,
		SkippedIntervals = 0,
		Metadata = {},
		Token = makeToken(),
		_completionCallbacks = {},
	}, TaskHandle)

	activeTasks[handle.Id] = handle
	return handle
end

local function finishHandle(handle, state)
	if TERMINAL_STATES[handle.State] then
		return false
	end

	handle.State = state
	handle.FinishedAt = time()
	activeTasks[handle.Id] = nil

	local callbacks = handle._completionCallbacks
	handle._completionCallbacks = {}
	for _, entry in ipairs(callbacks) do
		if entry.Active and entry.Callback ~= nil then
			local callback = entry.Callback
			entry.Active = false
			entry.Callback = nil
			invokeSafely(callback, "completion callback failed", handle)
		end
	end

	return true
end

local function runCallback(handle, callback, args)
	if handle:IsDone() then
		return
	end

	if handle.Cancelled or runtimeShuttingDown then
		if not handle.Cancelled then
			handle:Cancel(runtimeShutdownReason or "runtime shutdown")
		end
		return
	end

	handle.State = "running"
	handle.StartedAt = time()

	local callResults = pack(pcall(callback, handle.Token, unpackPacked(args)))
	local succeeded = callResults[1]

	if handle.Cancelled then
		finishHandle(handle, "cancelled")
		return
	end

	if succeeded then
		local results = { n = callResults.n - 1 }
		for index = 2, callResults.n do
			results[index - 1] = callResults[index]
		end
		handle.Results = results
		finishHandle(handle, "completed")
	else
		handle.Error = tostring(callResults[2])
		finishHandle(handle, "failed")

		local handlerSucceeded, handlerError = pcall(taskErrorHandler, handle.Error, handle)
		if not handlerSucceeded then
			warn("[TaskRuntime] task error handler failed: " .. tostring(handlerError))
		end
	end
end

function TaskHandle:SetName(name)
	if type(name) ~= "string" or name == "" then
		error("TaskHandle:SetName expects a non-empty string", 2)
	end
	self.Name = name
	return self
end

function TaskHandle:SetMetadata(key, value)
	if key == nil then
		error("TaskHandle:SetMetadata expects a non-nil key", 2)
	end
	self.Metadata[key] = value
	return self
end

function TaskHandle:GetMetadata(key)
	return self.Metadata[key]
end

function TaskHandle:GetElapsedTime()
	local startTime = self.StartedAt or self.CreatedAt
	local endTime = self.FinishedAt or time()
	return endTime - startTime
end

function TaskHandle:Cancel(reason)
	if TERMINAL_STATES[self.State] or self.State == "cancelling" then
		return false
	end

	self.Cancelled = true
	self.CancelReason = reason or "cancelled"
	self.Token:_Cancel(self.CancelReason)

	if self.State == "running" then
		self.State = "cancelling"
	else
		finishHandle(self, "cancelled")
	end

	return true
end

function TaskHandle:CancelAfter(seconds, reason)
	assertSeconds(seconds, "TaskHandle:CancelAfter", false)
	if self:IsDone() then
		return nil
	end

	local timer = TaskRuntime.delay(seconds, function()
		self:Cancel(reason or "timeout")
	end)
	timer:SetName(self.Name .. ":cancel-after")

	self:OnComplete(function()
		timer:Cancel("source task completed")
	end)

	return timer
end

function TaskHandle:IsCancelled()
	return self.Cancelled
end

function TaskHandle:IsCancellationRequested()
	return self.Token:IsCancelled()
end

function TaskHandle:IsDone()
	return TERMINAL_STATES[self.State] == true
end

function TaskHandle:OnComplete(callback)
	assertCallback(callback, "TaskHandle:OnComplete")
	if self:IsDone() then
		invokeSafely(callback, "completion callback failed", self)
		return disconnectedConnection()
	end
	return registerCallback(self._completionCallbacks, callback)
end

function TaskHandle:_OnFinished(callback)
	return self:OnComplete(callback)
end

-- Returns false, "timeout" if the optional timeout elapses. A timed-out Await does
-- not cancel the task; call CancelAfter or withTimeout when cancellation is desired.
function TaskHandle:Await(timeoutSeconds)
	if timeoutSeconds ~= nil then
		assertSeconds(timeoutSeconds, "TaskHandle:Await", false)
	end

	local deadline = nil
	if timeoutSeconds ~= nil then
		deadline = time() + timeoutSeconds
	end

	while not self:IsDone() do
		if deadline ~= nil and time() >= deadline then
			return false, "timeout"
		end
		wait(0)
	end

	if self.State == "failed" then
		return false, self.Error
	end

	if self.State == "cancelled" then
		return false, self.CancelReason
	end

	if self.Results == nil then
		return true
	end

	return true, unpackPacked(self.Results)
end

function TaskRuntime.spawn(callback, ...)
	assertCallback(callback, "TaskRuntime.spawn")
	if runtimeShuttingDown then
		error("TaskRuntime is shut down", 2)
	end

	local handle = makeHandle("spawn")
	local args = pack(...)
	spawn(function()
		runCallback(handle, callback, args)
	end)
	return handle
end

function TaskRuntime.defer(callback, ...)
	assertCallback(callback, "TaskRuntime.defer")
	if runtimeShuttingDown then
		error("TaskRuntime is shut down", 2)
	end

	local handle = makeHandle("defer")
	local args = pack(...)
	spawn(function()
		if not handle.Token:Wait(0) then
			return
		end
		runCallback(handle, callback, args)
	end)
	return handle
end

function TaskRuntime.delay(seconds, callback, ...)
	assertSeconds(seconds, "TaskRuntime.delay", false)
	assertCallback(callback, "TaskRuntime.delay")
	if runtimeShuttingDown then
		error("TaskRuntime is shut down", 2)
	end

	local handle = makeHandle("delay")
	local args = pack(...)
	spawn(function()
		if not handle.Token:Wait(seconds) then
			return
		end
		runCallback(handle, callback, args)
	end)
	return handle
end

-- Repeats without overlap. The first run occurs after one interval. Missed
-- intervals are counted and skipped instead of replayed in a burst.
function TaskRuntime.every(seconds, callback, ...)
	assertSeconds(seconds, "TaskRuntime.every", false)
	assertCallback(callback, "TaskRuntime.every")
	if runtimeShuttingDown then
		error("TaskRuntime is shut down", 2)
	end

	local handle = makeHandle("every")
	local args = pack(...)

	local function repeatCallback(token)
		local nextRunAt = time() + seconds
		while not token:IsCancelled() do
			if seconds == 0 then
				if not token:Wait(0) then
					break
				end
			else
				local remaining = nextRunAt - time()
				if remaining > 0 and not token:Wait(remaining) then
					break
				end
				if token:IsCancelled() then
					break
				end
			end

			callback(token, unpackPacked(args))
			handle.Iterations = handle.Iterations + 1

			if seconds > 0 then
				nextRunAt = nextRunAt + seconds
				local now = time()
				if nextRunAt <= now then
					local skipped = math.floor((now - nextRunAt) / seconds) + 1
					handle.SkippedIntervals = handle.SkippedIntervals + skipped
					nextRunAt = nextRunAt + (skipped * seconds)
				end
			end
		end

		return handle.Iterations
	end

	spawn(function()
		runCallback(handle, repeatCallback, pack())
	end)
	return handle
end

function TaskRuntime.withTimeout(seconds, callback, ...)
	assertSeconds(seconds, "TaskRuntime.withTimeout", false)
	assertCallback(callback, "TaskRuntime.withTimeout")
	local handle = TaskRuntime.spawn(callback, ...)
	handle:CancelAfter(seconds, "timeout")
	return handle
end

-- Retries only when the callback throws. A successful callback may return any values.
-- The callback receives (token, attemptNumber, ...originalArguments).
function TaskRuntime.retry(attemptCount, callback, options, ...)
	if type(attemptCount) ~= "number" or attemptCount < 1 or attemptCount % 1 ~= 0 then
		error("TaskRuntime.retry expects attemptCount to be a positive integer", 2)
	end
	assertCallback(callback, "TaskRuntime.retry")

	if options == nil then
		options = {}
	elseif type(options) ~= "table" then
		error("TaskRuntime.retry expects options to be a table or nil", 2)
	end

	local delaySeconds = options.delaySeconds or 0
	local backoffFactor = options.backoffFactor or 1
	local maxDelaySeconds = options.maxDelaySeconds
	assertSeconds(delaySeconds, "TaskRuntime.retry delaySeconds", false)
	if type(backoffFactor) ~= "number" or backoffFactor < 0 then
		error("TaskRuntime.retry backoffFactor must be a non-negative number", 2)
	end
	if maxDelaySeconds ~= nil then
		assertSeconds(maxDelaySeconds, "TaskRuntime.retry maxDelaySeconds", false)
	end
	if options.shouldRetry ~= nil then
		assertCallback(options.shouldRetry, "TaskRuntime.retry shouldRetry")
	end
	if options.onRetry ~= nil then
		assertCallback(options.onRetry, "TaskRuntime.retry onRetry")
	end

	local args = pack(...)
	local handle = TaskRuntime.spawn(function(token)
		local currentDelay = delaySeconds
		local lastError = nil

		for attempt = 1, attemptCount do
			if token:IsCancelled() then
				return nil
			end

			local attemptResults = pack(pcall(callback, token, attempt, unpackPacked(args)))
			if attemptResults[1] then
				local results = { n = attemptResults.n - 1 }
				for index = 2, attemptResults.n do
					results[index - 1] = attemptResults[index]
				end
				return unpackPacked(results)
			end

			lastError = tostring(attemptResults[2])
			if attempt >= attemptCount then
				break
			end

			if options.shouldRetry ~= nil and not options.shouldRetry(lastError, attempt) then
				break
			end

			local nextDelay = currentDelay
			if options.onRetry ~= nil then
				options.onRetry(lastError, attempt, nextDelay)
			end

			if nextDelay > 0 and not token:Wait(nextDelay) then
				return nil
			end

			currentDelay = currentDelay * backoffFactor
			if maxDelaySeconds ~= nil then
				currentDelay = math.min(currentDelay, maxDelaySeconds)
			end
		end

		error(lastError or "retry failed", 0)
	end)
	handle.Kind = "retry"
	handle.Name = "retry#" .. tostring(handle.Id)
	return handle
end

local function cancelRemaining(handles, winnerIndex, reason)
	for index, handle in ipairs(handles) do
		if index ~= winnerIndex and not handle:IsDone() then
			handle:Cancel(reason)
		end
	end
end

-- Promise.all-like task composition. By default, the aggregate fails fast and
-- cancels unfinished children. On success it returns an array of packed result arrays.
function TaskRuntime.all(handles, options)
	assertTaskList(handles, "TaskRuntime.all", true)
	options = options or {}
	if type(options) ~= "table" then
		error("TaskRuntime.all expects options to be a table or nil", 2)
	end

	local failFast = options.failFast ~= false
	local cancelRemainingOnFailure = options.cancelRemaining ~= false
	local cancelChildrenOnAggregateCancel = options.cancelOnCancel ~= false

	local aggregate = TaskRuntime.spawn(function(token)
		local cancellationConnection = nil
		if cancelChildrenOnAggregateCancel then
			cancellationConnection = token:OnCancel(function(reason)
				cancelRemaining(handles, nil, reason or "aggregate cancelled")
			end)
		end

		while true do
			local allDone = true
			for index, handle in ipairs(handles) do
				if not handle:IsDone() then
					allDone = false
				elseif failFast and handle.State ~= "completed" then
					if cancelRemainingOnFailure then
						cancelRemaining(handles, index, "TaskRuntime.all child failed")
					end
					if cancellationConnection ~= nil then
						cancellationConnection:Disconnect()
					end
					local reason = handle.Error or handle.CancelReason or handle.State
					error("child " .. tostring(index) .. " " .. handle.State .. ": " .. tostring(reason), 0)
				end
			end

			if allDone then
				break
			end
			if not token:Wait(0) then
				if cancellationConnection ~= nil then
					cancellationConnection:Disconnect()
				end
				return nil
			end
		end

		if cancellationConnection ~= nil then
			cancellationConnection:Disconnect()
		end

		local results = {}
		for index, handle in ipairs(handles) do
			if failFast then
				results[index] = handle.Results or { n = 0 }
			else
				results[index] = {
					Success = handle.State == "completed",
					State = handle.State,
					Values = handle.Results,
					Error = handle.Error or handle.CancelReason,
				}
			end
		end
		return results
	end)
	aggregate.Kind = "all"
	aggregate.Name = "all#" .. tostring(aggregate.Id)
	return aggregate
end

-- Promise.race-like composition. The aggregate adopts the first terminal task.
-- On a successful winner it returns winnerIndex followed by the winner's results.
function TaskRuntime.race(handles, options)
	assertTaskList(handles, "TaskRuntime.race", false)
	options = options or {}
	if type(options) ~= "table" then
		error("TaskRuntime.race expects options to be a table or nil", 2)
	end

	local cancelLosers = options.cancelRemaining ~= false
	local cancelChildrenOnAggregateCancel = options.cancelOnCancel ~= false

	local aggregate = TaskRuntime.spawn(function(token)
		local cancellationConnection = nil
		if cancelChildrenOnAggregateCancel then
			cancellationConnection = token:OnCancel(function(reason)
				cancelRemaining(handles, nil, reason or "race cancelled")
			end)
		end

		while true do
			for index, handle in ipairs(handles) do
				if handle:IsDone() then
					if cancelLosers then
						cancelRemaining(handles, index, "TaskRuntime.race lost")
					end
					if cancellationConnection ~= nil then
						cancellationConnection:Disconnect()
					end

					if handle.State == "completed" then
						if handle.Results == nil then
							return index
						end
						return index, unpackPacked(handle.Results)
					end

					local reason = handle.Error or handle.CancelReason or handle.State
					error("winner " .. tostring(index) .. " " .. handle.State .. ": " .. tostring(reason), 0)
				end
			end

			if not token:Wait(0) then
				if cancellationConnection ~= nil then
					cancellationConnection:Disconnect()
				end
				return nil
			end
		end
	end)
	aggregate.Kind = "race"
	aggregate.Name = "race#" .. tostring(aggregate.Id)
	return aggregate
end

function TaskRuntime.wait(seconds)
	assertSeconds(seconds, "TaskRuntime.wait", true)
	local startedAt = time()
	wait(seconds or 0)
	return time() - startedAt
end

function TaskRuntime.cancel(handle, reason)
	assertTaskHandle(handle, "TaskRuntime.cancel")
	return handle:Cancel(reason)
end

function TaskRuntime.isCancelled(handle)
	return getmetatable(handle) == TaskHandle and handle:IsCancelled()
end

function TaskRuntime.isDone(handle)
	return getmetatable(handle) == TaskHandle and handle:IsDone()
end

function TaskRuntime.getActiveCount(kind)
	local count = 0
	for _, handle in pairs(activeTasks) do
		if kind == nil or handle.Kind == kind then
			count = count + 1
		end
	end
	return count
end

function TaskRuntime.getActiveTasks()
	local tasks = {}
	for _, handle in pairs(activeTasks) do
		table.insert(tasks, handle)
	end
	table.sort(tasks, function(left, right)
		return left.Id < right.Id
	end)
	return tasks
end

function TaskRuntime.getSnapshot()
	local snapshot = {
		Timestamp = time(),
		ActiveCount = 0,
		ByKind = {},
		ByState = {},
		Tasks = {},
	}

	for _, handle in ipairs(TaskRuntime.getActiveTasks()) do
		snapshot.ActiveCount = snapshot.ActiveCount + 1
		snapshot.ByKind[handle.Kind] = (snapshot.ByKind[handle.Kind] or 0) + 1
		snapshot.ByState[handle.State] = (snapshot.ByState[handle.State] or 0) + 1
		table.insert(snapshot.Tasks, {
			Id = handle.Id,
			Name = handle.Name,
			Kind = handle.Kind,
			State = handle.State,
			Age = time() - handle.CreatedAt,
			Elapsed = handle:GetElapsedTime(),
			Iterations = handle.Iterations,
			SkippedIntervals = handle.SkippedIntervals,
			Metadata = handle.Metadata,
		})
	end

	return snapshot
end

function TaskRuntime.warnLongRunning(thresholdSeconds)
	assertSeconds(thresholdSeconds, "TaskRuntime.warnLongRunning", false)
	local count = 0
	for _, handle in ipairs(TaskRuntime.getActiveTasks()) do
		local age = time() - handle.CreatedAt
		if age >= thresholdSeconds then
			count = count + 1
			warn(
				"[TaskRuntime] long-running task "
					.. tostring(handle.Id)
					.. " ("
					.. tostring(handle.Name)
					.. ") age="
					.. tostring(age)
			)
		end
	end
	return count
end

function TaskRuntime.setErrorHandler(handler)
	if handler == nil then
		taskErrorHandler = defaultTaskErrorHandler
		return
	end
	assertCallback(handler, "TaskRuntime.setErrorHandler")
	taskErrorHandler = handler
end

function TaskRuntime.setCleanupErrorHandler(handler)
	if handler == nil then
		cleanupErrorHandler = defaultCleanupErrorHandler
		return
	end
	assertCallback(handler, "TaskRuntime.setCleanupErrorHandler")
	cleanupErrorHandler = handler
end

function TaskRuntime.shutdown(reason)
	if runtimeShuttingDown then
		return false
	end

	runtimeShuttingDown = true
	runtimeShutdownReason = reason or "runtime shutdown"
	local handles = TaskRuntime.getActiveTasks()
	for _, handle in ipairs(handles) do
		handle:Cancel(runtimeShutdownReason)
	end
	return true
end

function TaskRuntime.cancellationSource(parentToken)
	return CancellationSource.new(parentToken)
end

local function findCleanupMethod(resource)
	local methodNames = {
		"Cancel",
		"Disconnect",
		"Cleanup",
		"Destroy",
		"Close",
	}

	for _, methodName in ipairs(methodNames) do
		local succeeded, method = pcall(function()
			return resource[methodName]
		end)
		if succeeded and type(method) == "function" then
			return methodName
		end
	end
	return nil
end

local function cleanupResource(resource, cleanupMethod, reason)
	if getmetatable(resource) == TaskHandle then
		resource:Cancel(reason)
		return
	end

	if type(cleanupMethod) == "function" then
		cleanupMethod(resource, reason)
		return
	end

	if type(resource) == "function" and cleanupMethod == nil then
		resource(reason)
		return
	end

	if cleanupMethod == nil then
		cleanupMethod = findCleanupMethod(resource)
	end
	if cleanupMethod == nil then
		error("no cleanup method found for resource")
	end

	local method = resource[cleanupMethod]
	if type(method) ~= "function" then
		error("cleanup method " .. tostring(cleanupMethod) .. " is not callable")
	end
	method(resource, reason)
end

function CleanupScope.new(name, options)
	if options == nil then
		options = {}
	elseif type(options) ~= "table" then
		error("CleanupScope.new expects options to be a table or nil", 2)
	end

	return setmetatable({
		Name = name or "CleanupScope",
		CancelOnTaskFailure = options.cancelOnTaskFailure == true,
		_entries = {},
		_keyedEntries = {},
		_destroyed = false,
		_cleaning = false,
		_cleanupComplete = false,
		_cleanupCallbacks = {},
		_cleanupErrors = {},
		_taskFailures = {},
		_pendingTasks = {},
		_pendingScopes = {},
	}, CleanupScope)
end

function CleanupScope:IsDestroyed()
	return self._destroyed
end

function CleanupScope:IsCleanupComplete()
	return self._cleanupComplete
end

function CleanupScope:GetCount()
	return #self._entries
end

function CleanupScope:GetCleanupErrors()
	local errors = {}
	for index, value in ipairs(self._cleanupErrors) do
		errors[index] = value
	end
	return errors
end

function CleanupScope:HasCleanupErrors()
	return #self._cleanupErrors > 0
end

function CleanupScope:GetTaskFailures()
	local failures = {}
	for index, value in ipairs(self._taskFailures) do
		failures[index] = value
	end
	return failures
end

function CleanupScope:OnCleanupComplete(callback)
	assertCallback(callback, "CleanupScope:OnCleanupComplete")
	if self._cleanupComplete then
		invokeSafely(callback, "scope completion callback failed", self)
		return disconnectedConnection()
	end
	return registerCallback(self._cleanupCallbacks, callback)
end

function CleanupScope:_OnCleanupComplete(callback)
	return self:OnCleanupComplete(callback)
end

function CleanupScope:_RecordCleanupError(message, resource, method)
	local record = {
		Message = tostring(message),
		Resource = resource,
		CleanupMethod = method,
	}
	table.insert(self._cleanupErrors, record)

	local handlerSucceeded, handlerError = pcall(cleanupErrorHandler, record.Message, self, record)
	if not handlerSucceeded then
		warn("[TaskRuntime] cleanup error handler failed: " .. tostring(handlerError))
	end
end

function CleanupScope:_CheckCleanupComplete()
	if not self._destroyed or self._cleanupComplete then
		return false
	end
	if next(self._pendingTasks) ~= nil or next(self._pendingScopes) ~= nil then
		return false
	end

	self._cleanupComplete = true
	local callbacks = self._cleanupCallbacks
	self._cleanupCallbacks = {}
	for _, entry in ipairs(callbacks) do
		if entry.Active and entry.Callback ~= nil then
			local callback = entry.Callback
			entry.Active = false
			entry.Callback = nil
			invokeSafely(callback, "scope completion callback failed", self)
		end
	end
	return true
end

function CleanupScope:_TrackTask(handle)
	if handle:IsDone() or self._pendingTasks[handle] then
		return
	end

	self._pendingTasks[handle] = true
	handle:OnComplete(function()
		self._pendingTasks[handle] = nil
		self:_CheckCleanupComplete()
	end)
end

function CleanupScope:_TrackScope(scope)
	if scope:IsCleanupComplete() or self._pendingScopes[scope] then
		return
	end

	self._pendingScopes[scope] = true
	scope:OnCleanupComplete(function()
		self._pendingScopes[scope] = nil
		for _, childError in ipairs(scope:GetCleanupErrors()) do
			self:_RecordCleanupError(
				"child scope " .. tostring(scope.Name) .. ": " .. tostring(childError.Message),
				childError.Resource,
				childError.CleanupMethod
			)
		end
		self:_CheckCleanupComplete()
	end)
end

function CleanupScope:_DetachEntry(entry)
	if not entry.Active then
		return false
	end

	entry.Active = false
	if entry.Key ~= nil and self._keyedEntries[entry.Key] == entry then
		self._keyedEntries[entry.Key] = nil
	end

	for index = #self._entries, 1, -1 do
		if self._entries[index] == entry then
			table.remove(self._entries, index)
			break
		end
	end
	return true
end

function CleanupScope:_AddEntry(resource, cleanupMethod, key)
	if self._destroyed or self._cleaning then
		error("cannot add resources to a destroyed cleanup scope", 3)
	end
	if resource == nil then
		error("cleanup scope cannot register nil", 3)
	end
	if cleanupMethod ~= nil and type(cleanupMethod) ~= "string" and type(cleanupMethod) ~= "function" then
		error("cleanup method must be a method name, function, or nil", 3)
	end

	local entry = {
		Resource = resource,
		CleanupMethod = cleanupMethod,
		Key = key,
		Active = true,
	}
	table.insert(self._entries, entry)
	if key ~= nil then
		self._keyedEntries[key] = entry
	end

	if getmetatable(resource) == TaskHandle then
		resource:OnComplete(function(handle)
			self:_DetachEntry(entry)
			if handle.State == "failed" then
				table.insert(self._taskFailures, {
					Handle = handle,
					Error = handle.Error,
				})
				if self.CancelOnTaskFailure and not self._destroyed and not self._cleaning then
					self:Destroy("owned task failed: " .. tostring(handle.Name))
				end
			end
		end)
	elseif getmetatable(resource) == CleanupScope then
		resource:OnCleanupComplete(function()
			self:_DetachEntry(entry)
		end)
	end

	return resource
end

function CleanupScope:Add(resource, cleanupMethod)
	return self:_AddEntry(resource, cleanupMethod, nil)
end

function CleanupScope:Set(key, resource, cleanupMethod)
	if key == nil then
		error("CleanupScope:Set expects a non-nil key", 2)
	end
	self:Remove(key, true, "resource replaced: " .. tostring(key))
	return self:_AddEntry(resource, cleanupMethod, key)
end

function CleanupScope:Get(key)
	local entry = self._keyedEntries[key]
	if entry == nil or not entry.Active then
		return nil
	end
	return entry.Resource
end

function CleanupScope:Has(key)
	return self:Get(key) ~= nil
end

function CleanupScope:Remove(key, shouldCleanup, reason)
	local entry = self._keyedEntries[key]
	if entry == nil or not entry.Active then
		return nil
	end

	self:_DetachEntry(entry)
	if shouldCleanup ~= false then
		local succeeded, cleanupError = pcall(
			cleanupResource,
			entry.Resource,
			entry.CleanupMethod,
			reason or ("resource removed: " .. tostring(key))
		)
		if not succeeded then
			self:_RecordCleanupError(cleanupError, entry.Resource, entry.CleanupMethod)
		end
	end
	return entry.Resource
end

function CleanupScope:Connect(signal, callback)
	assertCallback(callback, "CleanupScope:Connect")
	local connection = signal:Connect(callback)
	return self:Add(connection, "Disconnect")
end

function CleanupScope:Spawn(callback, ...)
	return self:Add(TaskRuntime.spawn(callback, ...), "Cancel")
end

function CleanupScope:Defer(callback, ...)
	return self:Add(TaskRuntime.defer(callback, ...), "Cancel")
end

function CleanupScope:Delay(seconds, callback, ...)
	return self:Add(TaskRuntime.delay(seconds, callback, ...), "Cancel")
end

function CleanupScope:Every(seconds, callback, ...)
	return self:Add(TaskRuntime.every(seconds, callback, ...), "Cancel")
end

function CleanupScope:WithTimeout(seconds, callback, ...)
	return self:Add(TaskRuntime.withTimeout(seconds, callback, ...), "Cancel")
end

function CleanupScope:Retry(attemptCount, callback, options, ...)
	return self:Add(TaskRuntime.retry(attemptCount, callback, options, ...), "Cancel")
end

function CleanupScope:Child(name, options)
	return self:Add(CleanupScope.new(name, options), "Destroy")
end

function CleanupScope:Cleanup(reason)
	if self._destroyed or self._cleaning then
		return false
	end

	self._cleaning = true
	local entries = self._entries
	self._entries = {}
	self._keyedEntries = {}

	for index = #entries, 1, -1 do
		local entry = entries[index]
		local resource = entry.Resource
		entry.Active = false

		if getmetatable(resource) == TaskHandle then
			self:_TrackTask(resource)
		elseif getmetatable(resource) == CleanupScope then
			self:_TrackScope(resource)
		end

		local succeeded, cleanupError = pcall(
			cleanupResource,
			resource,
			entry.CleanupMethod,
			reason or (self.Name .. " cleaned up")
		)
		if not succeeded then
			self:_RecordCleanupError(cleanupError, resource, entry.CleanupMethod)
		end
	end

	self._cleaning = false
	self._destroyed = true
	self:_CheckCleanupComplete()
	return true
end

function CleanupScope:Destroy(reason)
	return self:Cleanup(reason or (self.Name .. " destroyed"))
end

function CleanupScope:DestroyAndAwait(reason, timeoutSeconds)
	if timeoutSeconds ~= nil then
		assertSeconds(timeoutSeconds, "CleanupScope:DestroyAndAwait", false)
	end

	if not self._destroyed then
		self:Destroy(reason or (self.Name .. " destroyed and awaited"))
	end

	local deadline = nil
	if timeoutSeconds ~= nil then
		deadline = time() + timeoutSeconds
	end

	while not self:IsCleanupComplete() do
		if deadline ~= nil and time() >= deadline then
			return false, "timeout"
		end
		wait(0)
	end

	if self:HasCleanupErrors() then
		return false, "cleanup failed", self:GetCleanupErrors()
	end
	return true
end

function CleanupScope:_Dispose()
	return self:Destroy(self.Name .. " disposed")
end

function TaskRuntime.scope(name, options)
	return CleanupScope.new(name, options)
end

TaskRuntime.Handle = TaskHandle
TaskRuntime.CancellationToken = CancellationToken
TaskRuntime.CancellationSource = CancellationSource
TaskRuntime.CallbackConnection = CallbackConnection
TaskRuntime.CleanupScope = CleanupScope

return TaskRuntime
