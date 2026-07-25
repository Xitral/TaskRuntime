-- TaskRuntime
-- Structured asynchronous tasks, cooperative cancellation, task composition,
-- bounded concurrency, diagnostics, and deterministic cleanup for Polytoria Luau.

local TaskRuntime = {}
TaskRuntime.VERSION = "3.0.0"

local Runtime = {}
Runtime.__index = Runtime

local TaskHandle = {}
TaskHandle.__index = TaskHandle

local TaskError = {}
TaskError.__index = TaskError

local TaskOutcome = {}
TaskOutcome.__index = TaskOutcome

local CancellationToken = {}
CancellationToken.__index = CancellationToken

local CancellationSource = {}
CancellationSource.__index = CancellationSource

local CallbackConnection = {}
CallbackConnection.__index = CallbackConnection

local DeadlineHandle = {}
DeadlineHandle.__index = DeadlineHandle

local CleanupScope = {}
CleanupScope.__index = CleanupScope

local TaskContext = {}
TaskContext.__index = TaskContext

local Semaphore = {}
Semaphore.__index = Semaphore

local TaskQueue = {}
TaskQueue.__index = TaskQueue

local TestScheduler = {}
TestScheduler.__index = TestScheduler

local TERMINAL_STATES = {
	completed = true,
	cancelled = true,
	failed = true,
}

local VALID_SCOPE_OPTIONS = {
	cancelOnTaskFailure = true,
	cleanupTimeout = true,
	resourceCleanupTimeout = true,
}

local VALID_CONTEXT_OPTIONS = {
	cancelOnChildFailure = true,
	childShutdownTimeout = true,
	name = true,
}

local VALID_RETRY_OPTIONS = {
	delaySeconds = true,
	backoffFactor = true,
	maxDelaySeconds = true,
	jitter = true,
	shouldRetry = true,
	onRetry = true,
}

local VALID_COMPOSITION_OPTIONS = {
	failFast = true,
	cancelRemaining = true,
	cancelOnCancel = true,
}

local VALID_QUEUE_OPTIONS = {
	name = true,
	scope = true,
}

local function pack(...)
	return {
		n = select("#", ...),
		...,
	}
end

local function unpackPacked(values)
	if values == nil then
		return
	end
	return table.unpack(values, 1, values.n)
end

local function shallowCopy(source)
	local copy = {}
	if source ~= nil then
		for key, value in pairs(source) do
			copy[key] = value
		end
	end
	return copy
end

local function copyArray(source)
	local copy = {}
	for index, value in ipairs(source) do
		copy[index] = value
	end
	return copy
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

local function assertPositiveInteger(value, apiName)
	if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
		error(apiName .. " expects a positive integer", 3)
	end
end

local function assertKnownOptions(options, allowed, apiName)
	if options == nil then
		return {}
	end
	if type(options) ~= "table" then
		error(apiName .. " expects options to be a table or nil", 3)
	end
	for key in pairs(options) do
		if not allowed[key] then
			error(apiName .. " received unknown option " .. tostring(key), 3)
		end
	end
	return options
end

local function isYieldable()
	if coroutine == nil or coroutine.running == nil or coroutine.yield == nil then
		return false
	end
	if coroutine.isyieldable ~= nil then
		return coroutine.isyieldable()
	end
	local thread = coroutine.running()
	return thread ~= nil
end

local function safeTraceback(message)
	if debug ~= nil and debug.traceback ~= nil then
		local succeeded, trace = pcall(debug.traceback, tostring(message), 3)
		if succeeded then
			return trace
		end
	end
	return tostring(message)
end

local function defaultWarn(message)
	if warn ~= nil then
		warn(message)
	elseif print ~= nil then
		print(message)
	end
end

local function normalizeScheduler(scheduler)
	if scheduler == nil then
		return {
			now = function()
				return time()
			end,
			spawn = function(callback)
				return spawn(callback)
			end,
			sleep = function(seconds)
				return wait(seconds or 0)
			end,
			resume = function(thread, ...)
				local args = pack(...)
				spawn(function()
					local succeeded, resumeError = coroutine.resume(thread, unpackPacked(args))
					if not succeeded then
						defaultWarn("[TaskRuntime] failed to resume waiter: " .. tostring(resumeError))
					end
				end)
			end,
		}
	end

	if type(scheduler) ~= "table" then
		error("TaskRuntime.create scheduler must be a table", 3)
	end

	if type(scheduler.now) == "function" and type(scheduler.spawn) == "function" and type(scheduler.sleep) == "function" then
		return {
			now = scheduler.now,
			spawn = scheduler.spawn,
			sleep = scheduler.sleep,
			resume = scheduler.resume or function(thread, ...)
				local args = pack(...)
				scheduler.spawn(function()
					coroutine.resume(thread, unpackPacked(args))
				end)
			end,
		}
	end

	if type(scheduler.Now) == "function" and type(scheduler.Spawn) == "function" and type(scheduler.Sleep) == "function" then
		return {
			now = function()
				return scheduler:Now()
			end,
			spawn = function(callback)
				return scheduler:Spawn(callback)
			end,
			sleep = function(seconds)
				return scheduler:Sleep(seconds)
			end,
			resume = function(thread, ...)
				if type(scheduler.Resume) == "function" then
					return scheduler:Resume(thread, ...)
				end
				local args = pack(...)
				return scheduler:Spawn(function()
					coroutine.resume(thread, unpackPacked(args))
				end)
			end,
		}
	end

	error("TaskRuntime.create scheduler must provide now/spawn/sleep or Now/Spawn/Sleep", 3)
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
		entry.Connection = nil
	end
	self._entry = nil
	return true
end

function CallbackConnection:Destroy()
	return self:Disconnect()
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
		Connection = nil,
	}
	local connection = setmetatable({
		Connected = true,
		_entry = entry,
	}, CallbackConnection)
	entry.Connection = connection
	table.insert(entries, entry)
	return connection
end

local function consumeCallback(entry)
	if not entry.Active or entry.Callback == nil then
		return nil
	end
	local callback = entry.Callback
	entry.Active = false
	entry.Callback = nil
	local connection = entry.Connection
	if connection ~= nil then
		connection.Connected = false
		connection._entry = nil
	end
	entry.Connection = nil
	return callback
end

local function invokeSafely(runtime, callback, contextMessage, ...)
	local succeeded, callbackError = pcall(callback, ...)
	if not succeeded then
		runtime:_Warn("[TaskRuntime] " .. contextMessage .. ": " .. tostring(callbackError))
	end
	return succeeded, callbackError
end

function TaskError.new(code, message, fields)
	fields = fields or {}
	return setmetatable({
		Code = code or "TASK_ERROR",
		Message = tostring(message or code or "task error"),
		Cause = fields.Cause,
		TaskId = fields.TaskId,
		TaskName = fields.TaskName,
		TaskKind = fields.TaskKind,
		Attempt = fields.Attempt,
		Metadata = shallowCopy(fields.Metadata),
		ParentTaskId = fields.ParentTaskId,
		ScopeName = fields.ScopeName,
		Traceback = fields.Traceback,
	}, TaskError)
end

function TaskError:ToString()
	local prefix = self.Code and ("[" .. tostring(self.Code) .. "] ") or ""
	return prefix .. tostring(self.Message)
end

TaskError.__tostring = TaskError.ToString

local function errorForHandle(handle, code, message, fields)
	fields = fields or {}
	fields.TaskId = fields.TaskId or handle.Id
	fields.TaskName = fields.TaskName or handle.Name
	fields.TaskKind = fields.TaskKind or handle.Kind
	fields.Metadata = fields.Metadata or handle.Metadata
	fields.ParentTaskId = fields.ParentTaskId or handle.ParentTaskId
	fields.ScopeName = fields.ScopeName or handle.OwnerScopeName
	return TaskError.new(code, message, fields)
end

function TaskOutcome.new(status, handle, values, taskError, reason)
	return setmetatable({
		Status = status,
		Success = status == "completed",
		Values = values,
		Error = taskError,
		CancellationReason = reason,
		Task = handle,
	}, TaskOutcome)
end

function TaskOutcome:IsSuccess()
	return self.Success
end

function TaskOutcome:Unpack()
	if not self.Success then
		return false, self.Error or self.CancellationReason or self.Status
	end
	return true, unpackPacked(self.Values)
end

function TaskOutcome:ThrowIfFailed()
	if self.Success then
		return unpackPacked(self.Values)
	end
	error(tostring(self.Error or self.CancellationReason or self.Status), 2)
end

local function makeToken(runtime)
	return setmetatable({
		_runtime = runtime,
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
		invokeSafely(self._runtime, callback, "cancellation callback failed", self._reason)
		return disconnectedConnection()
	end
	return registerCallback(self._cancelCallbacks, callback)
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
		local callback = consumeCallback(entry)
		if callback ~= nil then
			invokeSafely(self._runtime, callback, "cancellation callback failed", self._reason)
		end
	end
	return true
end

function CancellationToken:Wait(seconds)
	assertSeconds(seconds, "CancellationToken:Wait", false)
	if self._cancelled then
		return false
	end
	if seconds == 0 then
		self._runtime:_Sleep(0)
		return not self._cancelled
	end

	local result = self._runtime:_AwaitRegistration(function(resolve)
		local cancellationConnection = self:OnCancel(function()
			resolve(false)
		end)
		local deadline = self._runtime:_ScheduleDeadline(seconds, function()
			resolve(true)
		end, "token wait")
		return function()
			cancellationConnection:Disconnect()
			deadline:Cancel()
		end
	end)
	return result == true
end

function CancellationSource.new(runtime, parentToken)
	if parentToken ~= nil and getmetatable(parentToken) ~= CancellationToken then
		error("CancellationSource.new expects a CancellationToken or nil", 2)
	end
	local source = setmetatable({
		_runtime = runtime,
		Token = makeToken(runtime),
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

function DeadlineHandle:Cancel()
	if not self.Active then
		return false
	end
	self.Active = false
	self.Callback = nil
	return true
end

function DeadlineHandle:Disconnect()
	return self:Cancel()
end

function DeadlineHandle:Destroy()
	return self:Cancel()
end

function Runtime:_Warn(message)
	local warningHandler = self._warningHandler
	if warningHandler ~= nil then
		local succeeded = pcall(warningHandler, message)
		if succeeded then
			return
		end
	end
	defaultWarn(message)
end

function Runtime:_Now()
	return self._scheduler.now()
end

function Runtime:_SpawnThread(callback)
	return self._scheduler.spawn(callback)
end

function Runtime:_Sleep(seconds)
	return self._scheduler.sleep(seconds or 0)
end

function Runtime:_Resume(thread, ...)
	return self._scheduler.resume(thread, ...)
end

function Runtime:_ScheduleDeadline(seconds, callback, label)
	assertSeconds(seconds, "Runtime:_ScheduleDeadline", false)
	assertCallback(callback, "Runtime:_ScheduleDeadline")
	self._nextDeadlineId = self._nextDeadlineId + 1
	local deadline = setmetatable({
		Id = self._nextDeadlineId,
		At = self:_Now() + seconds,
		Callback = callback,
		Label = label,
		Active = true,
	}, DeadlineHandle)
	table.insert(self._deadlines, deadline)
	if self._deadlineWakeAt == nil or deadline.At < self._deadlineWakeAt then
		self:_StartDeadlinePump(deadline.At)
	end
	return deadline
end

function Runtime:_NextActiveDeadline()
	local earliest = nil
	local compact = {}
	for _, deadline in ipairs(self._deadlines) do
		if deadline.Active then
			table.insert(compact, deadline)
			if earliest == nil or deadline.At < earliest.At then
				earliest = deadline
			end
		end
	end
	self._deadlines = compact
	return earliest
end

function Runtime:_StartDeadlinePump(wakeAt)
	self._deadlineGeneration = self._deadlineGeneration + 1
	local generation = self._deadlineGeneration
	self._deadlineWakeAt = wakeAt
	self:_SpawnThread(function()
		local remaining = wakeAt - self:_Now()
		if remaining > 0 then
			self:_Sleep(remaining)
		end
		if generation ~= self._deadlineGeneration then
			return
		end
		self._deadlineWakeAt = nil
		local now = self:_Now()
		local due = {}
		local pending = {}
		for _, deadline in ipairs(self._deadlines) do
			if deadline.Active and deadline.At <= now then
				deadline.Active = false
				table.insert(due, deadline)
			elseif deadline.Active then
				table.insert(pending, deadline)
			end
		end
		self._deadlines = pending
		for _, deadline in ipairs(due) do
			local callback = deadline.Callback
			deadline.Callback = nil
			if callback ~= nil then
				invokeSafely(self, callback, "deadline callback failed")
			end
		end
		local nextDeadline = self:_NextActiveDeadline()
		if nextDeadline ~= nil then
			self:_StartDeadlinePump(nextDeadline.At)
		end
	end)
end

function Runtime:_AwaitRegistration(register, timeoutSeconds, timeoutValues)
	local resolved = false
	local values = nil
	local cleanup = nil
	local parkedThread = nil

	local function resolve(...)
		if resolved then
			return false
		end
		resolved = true
		values = pack(...)
		if cleanup ~= nil then
			local currentCleanup = cleanup
			cleanup = nil
			invokeSafely(self, currentCleanup, "wait cleanup failed")
		end
		if parkedThread ~= nil then
			local thread = parkedThread
			parkedThread = nil
			self:_Resume(thread, unpackPacked(values))
		end
		return true
	end

	cleanup = register(resolve)
	if resolved then
		if cleanup ~= nil then
			local currentCleanup = cleanup
			cleanup = nil
			invokeSafely(self, currentCleanup, "wait cleanup failed")
		end
		return unpackPacked(values)
	end

	local timeoutHandle = nil
	if timeoutSeconds ~= nil then
		assertSeconds(timeoutSeconds, "Runtime:_AwaitRegistration timeout", false)
		timeoutHandle = self:_ScheduleDeadline(timeoutSeconds, function()
			if timeoutValues ~= nil then
				resolve(unpackPacked(timeoutValues))
			else
				resolve(false, "timeout")
			end
		end, "await timeout")
		local previousCleanup = cleanup
		cleanup = function()
			if previousCleanup ~= nil then
				previousCleanup()
			end
			timeoutHandle:Cancel()
		end
	end

	if isYieldable() then
		parkedThread = coroutine.running()
		return coroutine.yield({ __taskRuntimePark = true })
	end

	while not resolved do
		self:_Sleep(0)
	end
	return unpackPacked(values)
end

function Runtime:_MakeTaskError(handle, code, message, fields)
	return errorForHandle(handle, code, message, fields)
end

function Runtime:_RecordHistory(handle)
	local historySize = self._diagnostics.historySize
	if historySize <= 0 then
		return
	end
	local record = {
		Id = handle.Id,
		Name = handle.Name,
		Kind = handle.Kind,
		State = handle.State,
		CreatedAt = handle.CreatedAt,
		StartedAt = handle.StartedAt,
		FinishedAt = handle.FinishedAt,
		Elapsed = handle:GetElapsedTime(),
		Iterations = handle.Iterations,
		SkippedIntervals = handle.SkippedIntervals,
		Metadata = shallowCopy(handle.Metadata),
		ParentTaskId = handle.ParentTaskId,
		OwnerScopeName = handle.OwnerScopeName,
		Error = handle.ErrorInfo,
		CancelReason = handle.CancelReason,
		CreationTrace = handle.CreationTrace,
	}
	table.insert(self._history, record)
	while #self._history > historySize do
		table.remove(self._history, 1)
	end

	local stats = self._stats[handle.Name]
	if stats == nil then
		stats = {
			Count = 0,
			Completed = 0,
			Failed = 0,
			Cancelled = 0,
			TotalDuration = 0,
			MaxDuration = 0,
		}
		self._stats[handle.Name] = stats
	end
	local duration = handle:GetElapsedTime()
	stats.Count = stats.Count + 1
	stats.TotalDuration = stats.TotalDuration + duration
	stats.MaxDuration = math.max(stats.MaxDuration, duration)
	if handle.State == "completed" then
		stats.Completed = stats.Completed + 1
	elseif handle.State == "failed" then
		stats.Failed = stats.Failed + 1
	elseif handle.State == "cancelled" then
		stats.Cancelled = stats.Cancelled + 1
	end
end

function Runtime:_MakeHandle(kind, options)
	options = options or {}
	self._nextTaskId = self._nextTaskId + 1
	local id = self._nextTaskId
	local handle = setmetatable({
		_runtime = self,
		Id = id,
		Kind = kind,
		Name = options.name or (kind .. "#" .. tostring(id)),
		State = "scheduled",
		Cancelled = false,
		CancelReason = nil,
		CreatedAt = self:_Now(),
		StartedAt = nil,
		FinishedAt = nil,
		Error = nil,
		ErrorInfo = nil,
		Results = nil,
		Iterations = 0,
		SkippedIntervals = 0,
		Metadata = shallowCopy(options.metadata),
		Token = makeToken(self),
		ParentTaskId = options.parentTaskId or (self:_GetCurrentTask() and self:_GetCurrentTask().Id or nil),
		OwnerScopeName = options.ownerScopeName,
		DeadlineAt = options.deadlineAt,
		CreationTrace = self._diagnostics.captureCreationTrace and safeTraceback("task created") or nil,
		_completionCallbacks = {},
		_cancelHooks = {},
	}, TaskHandle)
	self._activeTasks[id] = handle
	local activeCount = self:getActiveCount()
	if activeCount > self._peakActiveCount then
		self._peakActiveCount = activeCount
	end
	return handle
end

function Runtime:_InvokeCancelHooks(handle)
	local hooks = handle._cancelHooks
	handle._cancelHooks = {}
	for _, callback in ipairs(hooks) do
		invokeSafely(self, callback, "task cancellation hook failed", handle.CancelReason)
	end
end

function Runtime:_FinishHandle(handle, state)
	if TERMINAL_STATES[handle.State] then
		return false
	end
	handle.State = state
	handle.FinishedAt = self:_Now()
	self._activeTasks[handle.Id] = nil
	self:_RecordHistory(handle)
	local callbacks = handle._completionCallbacks
	handle._completionCallbacks = {}
	for _, entry in ipairs(callbacks) do
		local callback = consumeCallback(entry)
		if callback ~= nil then
			invokeSafely(self, callback, "completion callback failed", handle)
		end
	end
	return true
end

function Runtime:_CompleteHandle(handle, results)
	if handle.Cancelled then
		return self:_FinishHandle(handle, "cancelled")
	end
	handle.Results = results or { n = 0 }
	return self:_FinishHandle(handle, "completed")
end

function Runtime:_FailHandle(handle, taskError, suppressHandler)
	if handle.Cancelled then
		return self:_FinishHandle(handle, "cancelled")
	end
	if getmetatable(taskError) ~= TaskError then
		taskError = self:_MakeTaskError(handle, "CALLBACK_FAILED", tostring(taskError), {
			Cause = taskError,
			Traceback = safeTraceback(taskError),
		})
	end
	handle.ErrorInfo = taskError
	handle.Error = taskError.Message
	self:_FinishHandle(handle, "failed")
	if not suppressHandler then
		local succeeded, handlerError = pcall(self._taskErrorHandler, handle.Error, handle, taskError)
		if not succeeded then
			self:_Warn("[TaskRuntime] task error handler failed: " .. tostring(handlerError))
		end
	end
	return true
end

function Runtime:_GetCurrentTask()
	if coroutine == nil or coroutine.running == nil then
		return nil
	end
	local thread = coroutine.running()
	if thread == nil then
		return nil
	end
	return self._currentTasks[thread]
end

function Runtime:_RunCallback(handle, callback, args)
	if handle:IsDone() then
		return
	end
	if handle.Cancelled or self._shuttingDown then
		if not handle.Cancelled then
			handle:Cancel(self._shutdownReason or "runtime shutdown")
		end
		return
	end
	handle.State = "running"
	handle.StartedAt = self:_Now()
	local thread = coroutine and coroutine.running and coroutine.running() or nil
	if thread ~= nil then
		self._currentTasks[thread] = handle
	end
	local callResults = pack(pcall(callback, handle.Token, unpackPacked(args)))
	if thread ~= nil then
		self._currentTasks[thread] = nil
	end
	if handle.Cancelled then
		self:_FinishHandle(handle, "cancelled")
		return
	end
	if callResults[1] then
		local results = { n = callResults.n - 1 }
		for index = 2, callResults.n do
			results[index - 1] = callResults[index]
		end
		self:_CompleteHandle(handle, results)
	else
		local rawError = callResults[2]
		self:_FailHandle(handle, self:_MakeTaskError(handle, "CALLBACK_FAILED", tostring(rawError), {
			Cause = rawError,
			Traceback = safeTraceback(rawError),
		}), handle.Metadata.suppressErrorHandler == true)
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
	local endTime = self.FinishedAt or self._runtime:_Now()
	return endTime - startTime
end

function TaskHandle:GetOutcome()
	if self.State == "completed" then
		return TaskOutcome.new("completed", self, self.Results or { n = 0 }, nil, nil)
	elseif self.State == "failed" then
		return TaskOutcome.new("failed", self, nil, self.ErrorInfo, nil)
	elseif self.State == "cancelled" then
		return TaskOutcome.new("cancelled", self, nil, nil, self.CancelReason)
	end
	return TaskOutcome.new(self.State, self, nil, nil, nil)
end

function TaskHandle:Cancel(reason)
	if TERMINAL_STATES[self.State] or self.State == "cancelling" then
		return false
	end
	self.Cancelled = true
	self.CancelReason = reason or "cancelled"
	self.Token:_Cancel(self.CancelReason)
	self._runtime:_InvokeCancelHooks(self)
	if self.State == "running" then
		self.State = "cancelling"
	else
		self._runtime:_FinishHandle(self, "cancelled")
	end
	return true
end

function TaskHandle:CancelAfter(seconds, reason)
	assertSeconds(seconds, "TaskHandle:CancelAfter", false)
	if self:IsDone() then
		return nil
	end
	local deadline = self._runtime:_ScheduleDeadline(seconds, function()
		self:Cancel(reason or "timeout")
	end, self.Name .. " deadline")
	self.DeadlineAt = deadline.At
	self:OnComplete(function()
		deadline:Cancel()
	end)
	return deadline
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
		invokeSafely(self._runtime, callback, "completion callback failed", self)
		return disconnectedConnection()
	end
	return registerCallback(self._completionCallbacks, callback)
end

function TaskHandle:AwaitOutcome(timeoutSeconds)
	if timeoutSeconds ~= nil then
		assertSeconds(timeoutSeconds, "TaskHandle:AwaitOutcome", false)
	end
	if self:IsDone() then
		return self:GetOutcome()
	end
	return self._runtime:_AwaitRegistration(function(resolve)
		local connection = self:OnComplete(function(handle)
			resolve(handle:GetOutcome())
		end)
		return function()
			connection:Disconnect()
		end
	end, timeoutSeconds, pack(TaskOutcome.new("timeout", self, nil, TaskError.new("AWAIT_TIMEOUT", "await timed out", {
		TaskId = self.Id,
		TaskName = self.Name,
		TaskKind = self.Kind,
		Metadata = self.Metadata,
	}), nil)))
end

function TaskHandle:Await(timeoutSeconds)
	local outcome = self:AwaitOutcome(timeoutSeconds)
	if outcome.Status == "timeout" then
		return false, "timeout"
	elseif outcome.Status == "failed" then
		return false, outcome.Error and outcome.Error.Message or self.Error
	elseif outcome.Status == "cancelled" then
		return false, outcome.CancellationReason
	elseif outcome.Status ~= "completed" then
		return false, outcome.Status
	end
	return true, unpackPacked(outcome.Values)
end

function TaskHandle:Then(callback)
	assertCallback(callback, "TaskHandle:Then")
	local source = self
	local chained = self._runtime:spawn(function(token)
		local outcome = source:AwaitOutcome()
		token:ThrowIfCancelled()
		if not outcome.Success then
			if outcome.Status == "cancelled" then
				error(outcome.CancellationReason or "source cancelled", 0)
			end
			error(outcome.Error and outcome.Error.Message or "source failed", 0)
		end
		return callback(token, unpackPacked(outcome.Values))
	end)
	chained.Kind = "then"
	chained.Name = self.Name .. ":then"
	chained.ParentTaskId = self.Id
	return chained
end

function TaskHandle:Catch(callback)
	assertCallback(callback, "TaskHandle:Catch")
	local source = self
	local chained = self._runtime:spawn(function(token)
		local outcome = source:AwaitOutcome()
		token:ThrowIfCancelled()
		if outcome.Success then
			return unpackPacked(outcome.Values)
		end
		return callback(token, outcome.Error, outcome.CancellationReason, outcome)
	end)
	chained.Kind = "catch"
	chained.Name = self.Name .. ":catch"
	chained.ParentTaskId = self.Id
	return chained
end

function TaskHandle:Finally(callback)
	assertCallback(callback, "TaskHandle:Finally")
	local source = self
	local chained = self._runtime:spawn(function(token)
		local outcome = source:AwaitOutcome()
		callback(token, outcome)
		if outcome.Success then
			return unpackPacked(outcome.Values)
		end
		if outcome.Status == "cancelled" then
			error(outcome.CancellationReason or "source cancelled", 0)
		end
		error(outcome.Error and outcome.Error.Message or "source failed", 0)
	end)
	chained.Kind = "finally"
	chained.Name = self.Name .. ":finally"
	chained.ParentTaskId = self.Id
	return chained
end

function Runtime:spawn(callback, ...)
	assertCallback(callback, "Runtime:spawn")
	if self._shuttingDown then
		error("TaskRuntime is shut down", 2)
	end
	local handle = self:_MakeHandle("spawn")
	local args = pack(...)
	self:_SpawnThread(function()
		self:_RunCallback(handle, callback, args)
	end)
	return handle
end

function Runtime:defer(callback, ...)
	assertCallback(callback, "Runtime:defer")
	if self._shuttingDown then
		error("TaskRuntime is shut down", 2)
	end
	local handle = self:_MakeHandle("defer")
	local args = pack(...)
	self:_SpawnThread(function()
		if not handle.Token:Wait(0) then
			if not handle:IsDone() then
				self:_FinishHandle(handle, "cancelled")
			end
			return
		end
		self:_RunCallback(handle, callback, args)
	end)
	return handle
end

function Runtime:delay(seconds, callback, ...)
	assertSeconds(seconds, "Runtime:delay", false)
	assertCallback(callback, "Runtime:delay")
	if self._shuttingDown then
		error("TaskRuntime is shut down", 2)
	end
	local handle = self:_MakeHandle("delay")
	local args = pack(...)
	local deadline = self:_ScheduleDeadline(seconds, function()
		if not handle:IsDone() and not handle.Cancelled then
			self:_SpawnThread(function()
				self:_RunCallback(handle, callback, args)
			end)
		end
	end, handle.Name)
	handle.DeadlineAt = deadline.At
	table.insert(handle._cancelHooks, function()
		deadline:Cancel()
	end)
	return handle
end

function Runtime:every(seconds, callback, ...)
	assertSeconds(seconds, "Runtime:every", false)
	assertCallback(callback, "Runtime:every")
	if self._shuttingDown then
		error("TaskRuntime is shut down", 2)
	end
	local handle = self:_MakeHandle("every")
	local args = pack(...)
	self:_SpawnThread(function()
		self:_RunCallback(handle, function(token)
			local nextRunAt = self:_Now() + seconds
			while not token:IsCancelled() do
				if seconds == 0 then
					if not token:Wait(0) then
						break
					end
				else
					local remaining = nextRunAt - self:_Now()
					if remaining > 0 and not token:Wait(remaining) then
						break
					end
				end
				if token:IsCancelled() then
					break
				end
				callback(token, unpackPacked(args))
				handle.Iterations = handle.Iterations + 1
				if seconds > 0 then
					nextRunAt = nextRunAt + seconds
					local now = self:_Now()
					if nextRunAt <= now then
						local skipped = math.floor((now - nextRunAt) / seconds) + 1
						handle.SkippedIntervals = handle.SkippedIntervals + skipped
						nextRunAt = nextRunAt + (skipped * seconds)
					end
				end
			end
			return handle.Iterations
		end, pack())
	end)
	return handle
end

function Runtime:withTimeout(seconds, callback, ...)
	assertSeconds(seconds, "Runtime:withTimeout", false)
	assertCallback(callback, "Runtime:withTimeout")
	local handle = self:spawn(callback, ...)
	handle.Kind = "timeout"
	handle.Name = "timeout#" .. tostring(handle.Id)
	handle:CancelAfter(seconds, "timeout")
	return handle
end

function Runtime:retry(attemptCount, callback, options, ...)
	assertPositiveInteger(attemptCount, "Runtime:retry")
	assertCallback(callback, "Runtime:retry")
	options = assertKnownOptions(options, VALID_RETRY_OPTIONS, "Runtime:retry")
	local delaySeconds = options.delaySeconds or 0
	local backoffFactor = options.backoffFactor or 1
	local maxDelaySeconds = options.maxDelaySeconds
	local jitter = options.jitter or 0
	assertSeconds(delaySeconds, "Runtime:retry delaySeconds", false)
	if type(backoffFactor) ~= "number" or backoffFactor < 0 then
		error("Runtime:retry backoffFactor must be a non-negative number", 2)
	end
	if maxDelaySeconds ~= nil then
		assertSeconds(maxDelaySeconds, "Runtime:retry maxDelaySeconds", false)
	end
	if type(jitter) ~= "number" or jitter < 0 or jitter > 1 then
		error("Runtime:retry jitter must be between 0 and 1", 2)
	end
	if options.shouldRetry ~= nil then
		assertCallback(options.shouldRetry, "Runtime:retry shouldRetry")
	end
	if options.onRetry ~= nil then
		assertCallback(options.onRetry, "Runtime:retry onRetry")
	end
	local args = pack(...)
	local handle = self:spawn(function(token)
		local currentDelay = delaySeconds
		local lastError = nil
		for attempt = 1, attemptCount do
			token:ThrowIfCancelled()
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
			if jitter > 0 and nextDelay > 0 then
				local randomPart = (math.random() * 2) - 1
				nextDelay = math.max(0, nextDelay * (1 + randomPart * jitter))
			end
			if options.onRetry ~= nil then
				options.onRetry(lastError, attempt, nextDelay)
			end
			if nextDelay > 0 and not token:Wait(nextDelay) then
				token:ThrowIfCancelled()
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

local function assertTaskHandle(handle, apiName, runtime)
	if getmetatable(handle) ~= TaskHandle then
		error(apiName .. " expects a TaskHandle", 3)
	end
	if runtime ~= nil and handle._runtime ~= runtime then
		error(apiName .. " cannot combine tasks from different runtimes", 3)
	end
end

local function assertTaskList(handles, apiName, allowEmpty, runtime)
	if type(handles) ~= "table" then
		error(apiName .. " expects an array of TaskHandles", 3)
	end
	if not allowEmpty and #handles == 0 then
		error(apiName .. " expects at least one TaskHandle", 3)
	end
	for index, handle in ipairs(handles) do
		local succeeded, checkError = pcall(assertTaskHandle, handle, apiName, runtime)
		if not succeeded then
			error(apiName .. " received an invalid task at index " .. tostring(index) .. ": " .. tostring(checkError), 3)
		end
	end
end

local function cancelRemaining(handles, winnerIndex, reason)
	for index, handle in ipairs(handles) do
		if index ~= winnerIndex and not handle:IsDone() then
			handle:Cancel(reason)
		end
	end
end

function Runtime:_Aggregate(kind, handles, setup)
	local aggregate = self:_MakeHandle(kind)
	local connections = {}
	local settled = false
	local function disconnectAll()
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		connections = {}
	end
	local function complete(values)
		if settled or aggregate:IsDone() then
			return false
		end
		settled = true
		disconnectAll()
		self:_CompleteHandle(aggregate, values)
		return true
	end
	local function fail(taskError)
		if settled or aggregate:IsDone() then
			return false
		end
		settled = true
		disconnectAll()
		self:_FailHandle(aggregate, taskError)
		return true
	end
	table.insert(aggregate._cancelHooks, function(reason)
		disconnectAll()
		if setup.cancelOnCancel then
			cancelRemaining(handles, nil, reason or (kind .. " cancelled"))
		end
	end)
	setup.start(aggregate, connections, complete, fail)
	return aggregate
end

function Runtime:all(handles, options)
	assertTaskList(handles, "Runtime:all", true, self)
	options = assertKnownOptions(options, VALID_COMPOSITION_OPTIONS, "Runtime:all")
	local failFast = options.failFast ~= false
	local cancelOnFailure = options.cancelRemaining ~= false
	local cancelOnCancel = options.cancelOnCancel ~= false
	if #handles == 0 then
		local aggregate = self:_MakeHandle("all")
		self:_CompleteHandle(aggregate, pack({}))
		return aggregate
	end
	return self:_Aggregate("all", handles, {
		cancelOnCancel = cancelOnCancel,
		start = function(aggregate, connections, complete, fail)
			local remaining = #handles
			local outcomes = {}
			local function childCompleted(index, handle)
				if aggregate:IsDone() then
					return
				end
				local outcome = handle:GetOutcome()
				outcomes[index] = outcome
				remaining = remaining - 1
				if failFast and not outcome.Success then
					local reason = outcome.Error and outcome.Error.Message or outcome.CancellationReason or outcome.Status
					local settledNow = fail(self:_MakeTaskError(aggregate, "CHILD_TASK_FAILED", "child " .. tostring(index) .. " " .. outcome.Status .. ": " .. tostring(reason), {
						Cause = outcome.Error,
					}))
					if settledNow and cancelOnFailure then
						cancelRemaining(handles, index, "TaskRuntime.all child did not complete")
					end
					return
				end
				if remaining == 0 then
					if failFast then
						local results = {}
						for childIndex, child in ipairs(handles) do
							results[childIndex] = child.Results or { n = 0 }
						end
						complete(pack(results))
					else
						complete(pack(outcomes))
					end
				end
			end
			for index, handle in ipairs(handles) do
				if aggregate:IsDone() then
					break
				end
				connections[index] = handle:OnComplete(function(completedHandle)
					childCompleted(index, completedHandle)
				end)
			end
		end,
	})
end

function Runtime:settle(handles)
	return self:all(handles, {
		failFast = false,
		cancelRemaining = false,
		cancelOnCancel = true,
	})
end

function Runtime:race(handles, options)
	assertTaskList(handles, "Runtime:race", false, self)
	options = assertKnownOptions(options, VALID_COMPOSITION_OPTIONS, "Runtime:race")
	local cancelLosers = options.cancelRemaining ~= false
	local cancelOnCancel = options.cancelOnCancel ~= false
	return self:_Aggregate("race", handles, {
		cancelOnCancel = cancelOnCancel,
		start = function(aggregate, connections, complete, fail)
			for index, handle in ipairs(handles) do
				if aggregate:IsDone() then
					break
				end
				connections[index] = handle:OnComplete(function(completedHandle)
					if aggregate:IsDone() then
						return
					end
					local outcome = completedHandle:GetOutcome()
					local settledNow = false
					if outcome.Success then
						local values = { n = (outcome.Values and outcome.Values.n or 0) + 1 }
						values[1] = index
						if outcome.Values ~= nil then
							for valueIndex = 1, outcome.Values.n do
								values[valueIndex + 1] = outcome.Values[valueIndex]
							end
						end
						settledNow = complete(values)
					else
						local reason = outcome.Error and outcome.Error.Message or outcome.CancellationReason or outcome.Status
						settledNow = fail(self:_MakeTaskError(aggregate, "RACE_WINNER_FAILED", "winner " .. tostring(index) .. " " .. outcome.Status .. ": " .. tostring(reason), {
							Cause = outcome.Error,
						}))
					end
					if settledNow and cancelLosers then
						cancelRemaining(handles, index, "TaskRuntime.race lost")
					end
				end)
			end
		end,
	})
end

function Runtime:any(handles, options)
	assertTaskList(handles, "Runtime:any", false, self)
	options = assertKnownOptions(options, VALID_COMPOSITION_OPTIONS, "Runtime:any")
	local cancelLosers = options.cancelRemaining ~= false
	local cancelOnCancel = options.cancelOnCancel ~= false
	return self:_Aggregate("any", handles, {
		cancelOnCancel = cancelOnCancel,
		start = function(aggregate, connections, complete, fail)
			local remaining = #handles
			local failures = {}
			for index, handle in ipairs(handles) do
				if aggregate:IsDone() then
					break
				end
				connections[index] = handle:OnComplete(function(completedHandle)
					if aggregate:IsDone() then
						return
					end
					local outcome = completedHandle:GetOutcome()
					remaining = remaining - 1
					if outcome.Success then
						local values = { n = (outcome.Values and outcome.Values.n or 0) + 1 }
						values[1] = index
						if outcome.Values ~= nil then
							for valueIndex = 1, outcome.Values.n do
								values[valueIndex + 1] = outcome.Values[valueIndex]
							end
						end
						local settledNow = complete(values)
						if settledNow and cancelLosers then
							cancelRemaining(handles, index, "TaskRuntime.any lost")
						end
						return
					end
					failures[index] = outcome
					if remaining == 0 then
						fail(self:_MakeTaskError(aggregate, "ALL_TASKS_FAILED", "all tasks failed or were cancelled", {
							Cause = failures,
						}))
					end
				end)
			end
		end,
	})
end

function Runtime:mapLimit(items, concurrency, callback, options)
	if type(items) ~= "table" then
		error("Runtime:mapLimit expects an array", 2)
	end
	assertPositiveInteger(concurrency, "Runtime:mapLimit")
	assertCallback(callback, "Runtime:mapLimit")
	options = options or {}
	local semaphore = self:semaphore(concurrency)
	local tasks = {}
	for index, item in ipairs(items) do
		tasks[index] = self:spawn(function(token)
			local acquired, reason = semaphore:Acquire(token, options.acquireTimeout)
			if not acquired then
				error(reason or "semaphore acquire failed", 0)
			end
			local callbackResults = pack(pcall(callback, token, item, index))
			semaphore:Release()
			if not callbackResults[1] then
				error(callbackResults[2], 0)
			end
			return table.unpack(callbackResults, 2, callbackResults.n)
		end)
		tasks[index].Kind = "map"
	end
	return self:all(tasks, {
		failFast = options.failFast ~= false,
		cancelRemaining = options.cancelRemaining ~= false,
		cancelOnCancel = true,
	})
end

function Runtime:map(items, callback, options)
	local concurrency = #items
	if concurrency < 1 then
		local aggregate = self:_MakeHandle("map")
		self:_CompleteHandle(aggregate, pack({}))
		return aggregate
	end
	return self:mapLimit(items, concurrency, callback, options)
end

function Runtime:wait(seconds)
	assertSeconds(seconds, "Runtime:wait", true)
	local startedAt = self:_Now()
	self:_Sleep(seconds or 0)
	return self:_Now() - startedAt
end

function Runtime:cancel(handle, reason)
	assertTaskHandle(handle, "Runtime:cancel", self)
	return handle:Cancel(reason)
end

function Runtime:isCancelled(handle)
	return getmetatable(handle) == TaskHandle and handle._runtime == self and handle:IsCancelled()
end

function Runtime:isDone(handle)
	return getmetatable(handle) == TaskHandle and handle._runtime == self and handle:IsDone()
end

function Runtime:getActiveCount(kind)
	local count = 0
	for _, handle in pairs(self._activeTasks) do
		if kind == nil or handle.Kind == kind then
			count = count + 1
		end
	end
	return count
end

function Runtime:getActiveTasks()
	local tasks = {}
	for _, handle in pairs(self._activeTasks) do
		table.insert(tasks, handle)
	end
	table.sort(tasks, function(left, right)
		return left.Id < right.Id
	end)
	return tasks
end

function Runtime:getSnapshot()
	local snapshot = {
		Version = TaskRuntime.VERSION,
		Timestamp = self:_Now(),
		ActiveCount = 0,
		PeakActiveCount = self._peakActiveCount,
		ByKind = {},
		ByState = {},
		PendingDeadlines = 0,
		Tasks = {},
	}
	for _, deadline in ipairs(self._deadlines) do
		if deadline.Active then
			snapshot.PendingDeadlines = snapshot.PendingDeadlines + 1
		end
	end
	for _, handle in ipairs(self:getActiveTasks()) do
		snapshot.ActiveCount = snapshot.ActiveCount + 1
		snapshot.ByKind[handle.Kind] = (snapshot.ByKind[handle.Kind] or 0) + 1
		snapshot.ByState[handle.State] = (snapshot.ByState[handle.State] or 0) + 1
		table.insert(snapshot.Tasks, {
			Id = handle.Id,
			Name = handle.Name,
			Kind = handle.Kind,
			State = handle.State,
			Age = self:_Now() - handle.CreatedAt,
			Elapsed = handle:GetElapsedTime(),
			Iterations = handle.Iterations,
			SkippedIntervals = handle.SkippedIntervals,
			Metadata = shallowCopy(handle.Metadata),
			ParentTaskId = handle.ParentTaskId,
			OwnerScopeName = handle.OwnerScopeName,
			DeadlineAt = handle.DeadlineAt,
			CreationTrace = handle.CreationTrace,
		})
	end
	return snapshot
end

function Runtime:getHistory()
	return copyArray(self._history)
end

function Runtime:getStats()
	local result = {}
	for name, stats in pairs(self._stats) do
		result[name] = shallowCopy(stats)
		if stats.Count > 0 then
			result[name].AverageDuration = stats.TotalDuration / stats.Count
		else
			result[name].AverageDuration = 0
		end
	end
	return result
end

function Runtime:configureDiagnostics(options)
	if options == nil then
		return shallowCopy(self._diagnostics)
	end
	if type(options) ~= "table" then
		error("Runtime:configureDiagnostics expects a table or nil", 2)
	end
	for key in pairs(options) do
		if key ~= "historySize" and key ~= "captureCreationTrace" then
			error("Runtime:configureDiagnostics received unknown option " .. tostring(key), 2)
		end
	end
	if options.historySize ~= nil then
		if type(options.historySize) ~= "number" or options.historySize < 0 or options.historySize % 1 ~= 0 then
			error("historySize must be a non-negative integer", 2)
		end
		self._diagnostics.historySize = options.historySize
		while #self._history > options.historySize do
			table.remove(self._history, 1)
		end
	end
	if options.captureCreationTrace ~= nil then
		self._diagnostics.captureCreationTrace = options.captureCreationTrace == true
	end
	return shallowCopy(self._diagnostics)
end

function Runtime:warnLongRunning(thresholdSeconds)
	assertSeconds(thresholdSeconds, "Runtime:warnLongRunning", false)
	local count = 0
	for _, handle in ipairs(self:getActiveTasks()) do
		local age = self:_Now() - handle.CreatedAt
		if age >= thresholdSeconds then
			count = count + 1
			self:_Warn("[TaskRuntime] long-running task " .. tostring(handle.Id) .. " (" .. tostring(handle.Name) .. ") age=" .. tostring(age))
		end
	end
	return count
end

function Runtime:setErrorHandler(handler)
	if handler == nil then
		self._taskErrorHandler = self._defaultTaskErrorHandler
		return
	end
	assertCallback(handler, "Runtime:setErrorHandler")
	self._taskErrorHandler = handler
end

function Runtime:setCleanupErrorHandler(handler)
	if handler == nil then
		self._cleanupErrorHandler = self._defaultCleanupErrorHandler
		return
	end
	assertCallback(handler, "Runtime:setCleanupErrorHandler")
	self._cleanupErrorHandler = handler
end

function Runtime:setWarningHandler(handler)
	if handler ~= nil then
		assertCallback(handler, "Runtime:setWarningHandler")
	end
	self._warningHandler = handler
end

function Runtime:shutdown(reason)
	if self._shuttingDown then
		return false
	end
	self._shuttingDown = true
	self._shutdownReason = reason or "runtime shutdown"
	for _, handle in ipairs(self:getActiveTasks()) do
		handle:Cancel(self._shutdownReason)
	end
	return true
end

function Runtime:cancellationSource(parentToken)
	return CancellationSource.new(self, parentToken)
end

function Semaphore.new(runtime, limit)
	assertPositiveInteger(limit, "Semaphore.new")
	return setmetatable({
		_runtime = runtime,
		Limit = limit,
		Available = limit,
		_waiters = {},
	}, Semaphore)
end

function Semaphore:GetWaitingCount()
	local count = 0
	for _, waiter in ipairs(self._waiters) do
		if waiter.Active then
			count = count + 1
		end
	end
	return count
end

function Semaphore:Acquire(token, timeoutSeconds)
	if token ~= nil and getmetatable(token) ~= CancellationToken then
		error("Semaphore:Acquire expects a CancellationToken or nil", 2)
	end
	if timeoutSeconds ~= nil then
		assertSeconds(timeoutSeconds, "Semaphore:Acquire", false)
	end
	if token ~= nil and token:IsCancelled() then
		return false, token:GetReason()
	end
	if self.Available > 0 then
		self.Available = self.Available - 1
		return true
	end
	return self._runtime:_AwaitRegistration(function(resolve)
		local waiter = {
			Active = true,
			Resolve = resolve,
		}
		table.insert(self._waiters, waiter)
		local cancelConnection = nil
		if token ~= nil then
			cancelConnection = token:OnCancel(function(reason)
				if waiter.Active then
					waiter.Active = false
					resolve(false, reason or "cancelled")
				end
			end)
		end
		return function()
			waiter.Active = false
			if cancelConnection ~= nil then
				cancelConnection:Disconnect()
			end
		end
	end, timeoutSeconds, pack(false, "timeout"))
end

function Semaphore:Release(count)
	count = count or 1
	assertPositiveInteger(count, "Semaphore:Release")
	for _ = 1, count do
		local resumed = false
		while #self._waiters > 0 do
			local waiter = table.remove(self._waiters, 1)
			if waiter.Active then
				waiter.Active = false
				waiter.Resolve(true)
				resumed = true
				break
			end
		end
		if not resumed then
			if self.Available >= self.Limit then
				error("Semaphore:Release would exceed the configured limit", 2)
			end
			self.Available = self.Available + 1
		end
	end
	return true
end

function Semaphore:WithPermit(token, callback, timeoutSeconds, ...)
	assertCallback(callback, "Semaphore:WithPermit")
	local acquired, reason = self:Acquire(token, timeoutSeconds)
	if not acquired then
		return false, reason
	end
	local results = pack(pcall(callback, ...))
	self:Release()
	if not results[1] then
		error(results[2], 2)
	end
	return true, table.unpack(results, 2, results.n)
end

function Runtime:semaphore(limit)
	return Semaphore.new(self, limit)
end

function TaskQueue.new(runtime, concurrency, options)
	assertPositiveInteger(concurrency, "TaskQueue.new")
	options = assertKnownOptions(options, VALID_QUEUE_OPTIONS, "TaskQueue.new")
	return setmetatable({
		_runtime = runtime,
		Name = options.name or "TaskQueue",
		Scope = options.scope,
		Semaphore = Semaphore.new(runtime, concurrency),
		Closed = false,
		_tasks = {},
	}, TaskQueue)
end

function TaskQueue:Add(callback, ...)
	if self.Closed then
		error("cannot add work to a closed TaskQueue", 2)
	end
	assertCallback(callback, "TaskQueue:Add")
	local args = pack(...)
	local task = self._runtime:spawn(function(token)
		local acquired, reason = self.Semaphore:Acquire(token)
		if not acquired then
			error(reason or "queue acquire failed", 0)
		end
		local results = pack(pcall(callback, token, unpackPacked(args)))
		self.Semaphore:Release()
		if not results[1] then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end)
	task.Kind = "queue"
	task.Name = self.Name .. "#" .. tostring(task.Id)
	self._tasks[task] = true
	task:OnComplete(function()
		self._tasks[task] = nil
	end)
	if self.Scope ~= nil then
		self.Scope:Add(task, "Cancel")
	end
	return task
end

function TaskQueue:GetActiveCount()
	local count = 0
	for task in pairs(self._tasks) do
		if not task:IsDone() then
			count = count + 1
		end
	end
	return count
end

function TaskQueue:Close(reason)
	if self.Closed then
		return false
	end
	self.Closed = true
	for task in pairs(self._tasks) do
		if not task:IsDone() then
			task:Cancel(reason or "queue closed")
		end
	end
	return true
end

function TaskQueue:Destroy(reason)
	return self:Close(reason)
end

function Runtime:queue(concurrency, options)
	return TaskQueue.new(self, concurrency, options)
end

function Runtime:debounce(key, seconds, callback, ...)
	if key == nil then
		error("Runtime:debounce expects a non-nil key", 2)
	end
	assertSeconds(seconds, "Runtime:debounce", false)
	assertCallback(callback, "Runtime:debounce")
	local existing = self._debounced[key]
	if existing ~= nil and not existing:IsDone() then
		existing:Cancel("debounced")
	end
	local handle = self:delay(seconds, callback, ...)
	handle.Kind = "debounce"
	handle.Name = "debounce:" .. tostring(key)
	self._debounced[key] = handle
	handle:OnComplete(function()
		if self._debounced[key] == handle then
			self._debounced[key] = nil
		end
	end)
	return handle
end

function Runtime:throttle(key, seconds, callback, ...)
	if key == nil then
		error("Runtime:throttle expects a non-nil key", 2)
	end
	assertSeconds(seconds, "Runtime:throttle", false)
	assertCallback(callback, "Runtime:throttle")
	local now = self:_Now()
	local entry = self._throttled[key]
	if entry ~= nil and now < entry.NextAt then
		return nil, entry.Handle
	end
	local handle = self:spawn(callback, ...)
	handle.Kind = "throttle"
	handle.Name = "throttle:" .. tostring(key)
	self._throttled[key] = {
		NextAt = now + seconds,
		Handle = handle,
	}
	return handle
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

function CleanupScope.new(runtime, name, options)
	options = assertKnownOptions(options, VALID_SCOPE_OPTIONS, "CleanupScope.new")
	if options.cleanupTimeout ~= nil then
		assertSeconds(options.cleanupTimeout, "CleanupScope cleanupTimeout", false)
	end
	if options.resourceCleanupTimeout ~= nil then
		assertSeconds(options.resourceCleanupTimeout, "CleanupScope resourceCleanupTimeout", false)
	end
	return setmetatable({
		_runtime = runtime,
		Name = name or "CleanupScope",
		CancelOnTaskFailure = options.cancelOnTaskFailure == true,
		CleanupTimeout = options.cleanupTimeout,
		ResourceCleanupTimeout = options.resourceCleanupTimeout,
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
		_cleanupDriver = nil,
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
	return copyArray(self._cleanupErrors)
end

function CleanupScope:HasCleanupErrors()
	return #self._cleanupErrors > 0
end

function CleanupScope:GetTaskFailures()
	return copyArray(self._taskFailures)
end

function CleanupScope:OnCleanupComplete(callback)
	assertCallback(callback, "CleanupScope:OnCleanupComplete")
	if self._cleanupComplete then
		invokeSafely(self._runtime, callback, "scope completion callback failed", self)
		return disconnectedConnection()
	end
	return registerCallback(self._cleanupCallbacks, callback)
end

function CleanupScope:_RecordCleanupError(code, message, resource, method, cause)
	local record = {
		Code = code or "CLEANUP_FAILED",
		Message = tostring(message),
		Resource = resource,
		CleanupMethod = method,
		Cause = cause,
		ScopeName = self.Name,
		Timestamp = self._runtime:_Now(),
	}
	table.insert(self._cleanupErrors, record)
	local succeeded, handlerError = pcall(self._runtime._cleanupErrorHandler, record.Message, self, record)
	if not succeeded then
		self._runtime:_Warn("[TaskRuntime] cleanup error handler failed: " .. tostring(handlerError))
	end
	return record
end

function CleanupScope:_CheckCleanupComplete()
	if not self._destroyed or self._cleanupComplete then
		return false
	end
	if next(self._pendingTasks) ~= nil or next(self._pendingScopes) ~= nil then
		return false
	end
	if self._cleanupDriver ~= nil and not self._cleanupDriver:IsDone() then
		return false
	end
	self._cleanupComplete = true
	local callbacks = self._cleanupCallbacks
	self._cleanupCallbacks = {}
	for _, entry in ipairs(callbacks) do
		local callback = consumeCallback(entry)
		if callback ~= nil then
			invokeSafely(self._runtime, callback, "scope completion callback failed", self)
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
			self:_RecordCleanupError("CHILD_CLEANUP_FAILED", "child scope " .. tostring(scope.Name) .. ": " .. tostring(childError.Message), childError.Resource, childError.CleanupMethod, childError)
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

function CleanupScope:_AddEntry(resource, cleanupMethod, key, options)
	if self._destroyed or self._cleaning then
		error("cannot add resources to a destroyed cleanup scope", 3)
	end
	if resource == nil then
		error("cleanup scope cannot register nil", 3)
	end
	if cleanupMethod ~= nil and type(cleanupMethod) ~= "string" and type(cleanupMethod) ~= "function" then
		error("cleanup method must be a method name, function, or nil", 3)
	end
	options = options or {}
	local entry = {
		Resource = resource,
		CleanupMethod = cleanupMethod,
		Key = key,
		Name = options.name,
		Timeout = options.timeout,
		Active = true,
	}
	if entry.Timeout ~= nil then
		assertSeconds(entry.Timeout, "CleanupScope resource timeout", false)
	end
	table.insert(self._entries, entry)
	if key ~= nil then
		self._keyedEntries[key] = entry
	end
	if getmetatable(resource) == TaskHandle then
		resource.OwnerScopeName = self.Name
		resource:OnComplete(function(handle)
			self:_DetachEntry(entry)
			if handle.State == "failed" then
				table.insert(self._taskFailures, {
					Handle = handle,
					Error = handle.ErrorInfo,
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

function CleanupScope:Add(resource, cleanupMethod, options)
	if type(cleanupMethod) == "table" and options == nil then
		options = cleanupMethod
		cleanupMethod = options.method
	end
	return self:_AddEntry(resource, cleanupMethod, nil, options)
end

function CleanupScope:Set(key, resource, cleanupMethod, options)
	if key == nil then
		error("CleanupScope:Set expects a non-nil key", 2)
	end
	if type(cleanupMethod) == "table" and options == nil then
		options = cleanupMethod
		cleanupMethod = options.method
	end
	self:Remove(key, true, "resource replaced: " .. tostring(key))
	return self:_AddEntry(resource, cleanupMethod, key, options)
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
		local succeeded, cleanupError = pcall(cleanupResource, entry.Resource, entry.CleanupMethod, reason or ("resource removed: " .. tostring(key)))
		if not succeeded then
			self:_RecordCleanupError("CLEANUP_FAILED", cleanupError, entry.Resource, entry.CleanupMethod, cleanupError)
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
	return self:Add(self._runtime:spawn(callback, ...), "Cancel")
end

function CleanupScope:Defer(callback, ...)
	return self:Add(self._runtime:defer(callback, ...), "Cancel")
end

function CleanupScope:Delay(seconds, callback, ...)
	return self:Add(self._runtime:delay(seconds, callback, ...), "Cancel")
end

function CleanupScope:Every(seconds, callback, ...)
	return self:Add(self._runtime:every(seconds, callback, ...), "Cancel")
end

function CleanupScope:WithTimeout(seconds, callback, ...)
	return self:Add(self._runtime:withTimeout(seconds, callback, ...), "Cancel")
end

function CleanupScope:Retry(attemptCount, callback, options, ...)
	return self:Add(self._runtime:retry(attemptCount, callback, options, ...), "Cancel")
end

function CleanupScope:Child(name, options)
	return self:Add(CleanupScope.new(self._runtime, name, options), "Destroy")
end

function CleanupScope:Run(callback, options, ...)
	assertCallback(callback, "CleanupScope:Run")
	if options ~= nil and type(options) ~= "table" then
		error("CleanupScope:Run expects options to be a table or nil", 2)
	end
	local args = pack(...)
	local handle = nil
	handle = self:Spawn(function(token)
		local context = TaskContext.new(self._runtime, self, token, options)
		context.RootTaskId = handle and handle.Id or nil
		local callbackResults = pack(pcall(callback, context, token, unpackPacked(args)))
		local shutdownSuccess, shutdownReason = context:Close("task context completed", context.ChildShutdownTimeout)
		if not shutdownSuccess then
			error("task context cleanup failed: " .. tostring(shutdownReason), 0)
		end
		if not callbackResults[1] then
			error(callbackResults[2], 0)
		end
		return table.unpack(callbackResults, 2, callbackResults.n)
	end)
	handle.Kind = "context"
	handle.Name = (options and options.name) or (self.Name .. ":context#" .. tostring(handle.Id))
	return handle
end

function CleanupScope:_RunCleanupEntry(entry, reason, timeoutSeconds)
	local resource = entry.Resource
	if getmetatable(resource) == TaskHandle then
		self:_TrackTask(resource)
		resource:Cancel(reason)
		return true
	elseif getmetatable(resource) == CleanupScope then
		self:_TrackScope(resource)
		resource:Destroy(reason)
		return true
	end

	if timeoutSeconds == nil then
		local succeeded, cleanupError = pcall(cleanupResource, resource, entry.CleanupMethod, reason)
		if not succeeded then
			self:_RecordCleanupError("CLEANUP_FAILED", cleanupError, resource, entry.CleanupMethod, cleanupError)
		end
		return succeeded
	end

	local cleanupTask = self._runtime:spawn(function()
		cleanupResource(resource, entry.CleanupMethod, reason)
	end)
	cleanupTask.Kind = "cleanup"
	cleanupTask.Name = self.Name .. ":cleanup:" .. tostring(entry.Name or entry.Key or cleanupTask.Id)
	cleanupTask:SetMetadata("suppressErrorHandler", true)
	local outcome = cleanupTask:AwaitOutcome(timeoutSeconds)
	if outcome.Status == "timeout" then
		cleanupTask:Cancel("resource cleanup timeout")
		self:_RecordCleanupError("CLEANUP_TIMEOUT", "cleanup timed out after " .. tostring(timeoutSeconds) .. " seconds", resource, entry.CleanupMethod, nil)
		return false
	elseif outcome.Status == "failed" then
		self:_RecordCleanupError("CLEANUP_FAILED", outcome.Error and outcome.Error.Message or "cleanup failed", resource, entry.CleanupMethod, outcome.Error)
		return false
	elseif outcome.Status == "cancelled" then
		self:_RecordCleanupError("CLEANUP_CANCELLED", outcome.CancellationReason or "cleanup cancelled", resource, entry.CleanupMethod, nil)
		return false
	end
	return true
end

function CleanupScope:_FinishCleanup()
	self._cleaning = false
	self._destroyed = true
	self:_CheckCleanupComplete()
end

function CleanupScope:Cleanup(reason)
	if self._destroyed or self._cleaning then
		return false
	end
	self._cleaning = true
	local entries = self._entries
	self._entries = {}
	self._keyedEntries = {}
	local cleanupReason = reason or (self.Name .. " cleaned up")
	local useDriver = self.CleanupTimeout ~= nil or self.ResourceCleanupTimeout ~= nil

	if not useDriver then
		for index = #entries, 1, -1 do
			local entry = entries[index]
			entry.Active = false
			self:_RunCleanupEntry(entry, cleanupReason, entry.Timeout)
		end
		self:_FinishCleanup()
		return true
	end

	local startedAt = self._runtime:_Now()
	local driver = self._runtime:spawn(function(token)
		for index = #entries, 1, -1 do
			if token:IsCancelled() then
				break
			end
			local entry = entries[index]
			entry.Active = false
			local timeout = entry.Timeout or self.ResourceCleanupTimeout
			if self.CleanupTimeout ~= nil then
				local remaining = self.CleanupTimeout - (self._runtime:_Now() - startedAt)
				if remaining <= 0 then
					self:_RecordCleanupError("SCOPE_CLEANUP_TIMEOUT", "scope cleanup timed out after " .. tostring(self.CleanupTimeout) .. " seconds", nil, nil, nil)
					break
				end
				if timeout == nil or timeout > remaining then
					timeout = remaining
				end
			end
			self:_RunCleanupEntry(entry, cleanupReason, timeout)
		end
	end)
	driver.Kind = "cleanup-driver"
	driver.Name = self.Name .. ":cleanup-driver"
	driver:SetMetadata("suppressErrorHandler", true)
	self._cleanupDriver = driver
	if self.CleanupTimeout ~= nil then
		driver:CancelAfter(self.CleanupTimeout, "scope cleanup timeout")
	end
	driver:OnComplete(function(completedDriver)
		if completedDriver.State == "failed" then
			self:_RecordCleanupError("CLEANUP_DRIVER_FAILED", completedDriver.Error or "cleanup driver failed", completedDriver, nil, completedDriver.ErrorInfo)
		elseif completedDriver.State == "cancelled" and completedDriver.CancelReason == "scope cleanup timeout" then
			self:_RecordCleanupError("SCOPE_CLEANUP_TIMEOUT", "scope cleanup timed out after " .. tostring(self.CleanupTimeout) .. " seconds", completedDriver, nil, nil)
		end
		self:_FinishCleanup()
	end)
	return true
end

function CleanupScope:Destroy(reason)
	return self:Cleanup(reason or (self.Name .. " destroyed"))
end

function CleanupScope:DestroyAndAwait(reason, timeoutSeconds)
	if timeoutSeconds ~= nil then
		assertSeconds(timeoutSeconds, "CleanupScope:DestroyAndAwait", false)
	end
	if not self._destroyed and not self._cleaning then
		self:Destroy(reason or (self.Name .. " destroyed and awaited"))
	end
	if not self:IsCleanupComplete() then
		local result = self._runtime:_AwaitRegistration(function(resolve)
			local connection = self:OnCleanupComplete(function()
				resolve(true)
			end)
			return function()
				connection:Disconnect()
			end
		end, timeoutSeconds, pack(false, "timeout"))
		if result ~= true then
			return false, "timeout"
		end
	end
	if self:HasCleanupErrors() then
		return false, "cleanup failed", self:GetCleanupErrors()
	end
	return true
end

function CleanupScope:_Dispose()
	return self:Destroy(self.Name .. " disposed")
end

function TaskContext.new(runtime, ownerScope, parentToken, options)
	options = assertKnownOptions(options, VALID_CONTEXT_OPTIONS, "TaskContext.new")
	local name = options.name or (ownerScope.Name .. ":children")
	local childScope = ownerScope:Child(name, {
		cancelOnTaskFailure = options.cancelOnChildFailure == true,
	})
	local source = runtime:cancellationSource(parentToken)
	local context = setmetatable({
		_runtime = runtime,
		Name = name,
		Scope = childScope,
		Source = source,
		Token = source.Token,
		CancelOnChildFailure = options.cancelOnChildFailure == true,
		ChildShutdownTimeout = options.childShutdownTimeout or 5,
		Closed = false,
		RootTaskId = runtime:_GetCurrentTask() and runtime:_GetCurrentTask().Id or nil,
	}, TaskContext)
	parentToken:OnCancel(function(reason)
		context:Cancel(reason)
	end)
	return context
end

function TaskContext:_Own(handle)
	handle.ParentTaskId = self.RootTaskId
	handle.OwnerScopeName = self.Scope.Name
	self.Scope:Add(handle, "Cancel")
	if self.CancelOnChildFailure then
		handle:OnComplete(function(completed)
			if completed.State == "failed" then
				self:Cancel("child task failed: " .. tostring(completed.Name))
			end
		end)
	end
	return handle
end

function TaskContext:Spawn(callback, ...)
	return self:_Own(self._runtime:spawn(callback, ...))
end

function TaskContext:Defer(callback, ...)
	return self:_Own(self._runtime:defer(callback, ...))
end

function TaskContext:Delay(seconds, callback, ...)
	return self:_Own(self._runtime:delay(seconds, callback, ...))
end

function TaskContext:Every(seconds, callback, ...)
	return self:_Own(self._runtime:every(seconds, callback, ...))
end

function TaskContext:WithTimeout(seconds, callback, ...)
	return self:_Own(self._runtime:withTimeout(seconds, callback, ...))
end

function TaskContext:Retry(attemptCount, callback, options, ...)
	return self:_Own(self._runtime:retry(attemptCount, callback, options, ...))
end

function TaskContext:Child(name, options)
	local childOptions = shallowCopy(options)
	if childOptions.name == nil then
		childOptions.name = name
	end
	return TaskContext.new(self._runtime, self.Scope, self.Token, childOptions)
end

function TaskContext:Cancel(reason)
	if self.Closed then
		return false
	end
	self.Source:Cancel(reason or "task context cancelled")
	self.Scope:Destroy(reason or "task context cancelled")
	return true
end

function TaskContext:Close(reason, timeoutSeconds)
	if self.Closed then
		if self.Scope:IsCleanupComplete() then
			return true
		end
		return self.Scope:DestroyAndAwait(reason, timeoutSeconds)
	end
	self.Closed = true
	self.Source:Cancel(reason or "task context closed")
	return self.Scope:DestroyAndAwait(reason or "task context closed", timeoutSeconds)
end

function Runtime:scope(name, options)
	return CleanupScope.new(self, name, options)
end

function Runtime:context(name, options)
	local rootScope = self:scope(name or "TaskContextRoot")
	local source = self:cancellationSource()
	return TaskContext.new(self, rootScope, source.Token, options or { name = name })
end

function Runtime.create(options)
	options = options or {}
	if type(options) ~= "table" then
		error("TaskRuntime.create expects a table or nil", 2)
	end
	local runtime = setmetatable({
		_scheduler = normalizeScheduler(options.scheduler),
		_nextTaskId = 0,
		_activeTasks = {},
		_currentTasks = {},
		_shuttingDown = false,
		_shutdownReason = nil,
		_nextDeadlineId = 0,
		_deadlines = {},
		_deadlineGeneration = 0,
		_deadlineWakeAt = nil,
		_peakActiveCount = 0,
		_history = {},
		_stats = {},
		_diagnostics = {
			historySize = options.historySize or 100,
			captureCreationTrace = options.captureCreationTrace == true,
		},
		_debounced = {},
		_throttled = {},
		_warningHandler = options.warningHandler,
	}, Runtime)
	runtime._defaultTaskErrorHandler = function(message, handle)
		runtime:_Warn("[TaskRuntime] task " .. tostring(handle.Id) .. " (" .. tostring(handle.Name) .. ") failed: " .. tostring(message))
	end
	runtime._defaultCleanupErrorHandler = function(message, scope)
		runtime:_Warn("[TaskRuntime] cleanup failed in " .. tostring(scope.Name) .. ": " .. tostring(message))
	end
	runtime._taskErrorHandler = runtime._defaultTaskErrorHandler
	runtime._cleanupErrorHandler = runtime._defaultCleanupErrorHandler
	return runtime
end

function TestScheduler.new(startTime)
	return setmetatable({
		_time = startTime or 0,
		_ready = {},
		_sleeping = {},
		_errors = {},
		_nextSequence = 0,
	}, TestScheduler)
end

function TestScheduler:Now()
	return self._time
end

function TestScheduler:_Enqueue(thread, args)
	self._nextSequence = self._nextSequence + 1
	table.insert(self._ready, {
		Thread = thread,
		Args = args or { n = 0 },
		Sequence = self._nextSequence,
	})
end

function TestScheduler:Spawn(callback)
	assertCallback(callback, "TestScheduler:Spawn")
	local thread = coroutine.create(callback)
	self:_Enqueue(thread)
	return thread
end

function TestScheduler:Resume(thread, ...)
	self:_Enqueue(thread, pack(...))
end

function TestScheduler:Sleep(seconds)
	assertSeconds(seconds, "TestScheduler:Sleep", true)
	return coroutine.yield({
		__taskRuntimeSleep = true,
		WakeAt = self._time + (seconds or 0),
	})
end

function TestScheduler:_ResumeEntry(entry)
	local succeeded, yielded = coroutine.resume(entry.Thread, unpackPacked(entry.Args))
	if not succeeded then
		table.insert(self._errors, tostring(yielded))
		return
	end
	if coroutine.status(entry.Thread) == "dead" then
		return
	end
	if type(yielded) == "table" and yielded.__taskRuntimeSleep then
		table.insert(self._sleeping, {
			Thread = entry.Thread,
			WakeAt = yielded.WakeAt,
			Sequence = entry.Sequence,
		})
	elseif type(yielded) == "table" and yielded.__taskRuntimePark then
		return
	else
		self:_Enqueue(entry.Thread)
	end
end

function TestScheduler:_WakeDue()
	local pending = {}
	for _, sleeper in ipairs(self._sleeping) do
		if sleeper.WakeAt <= self._time then
			self:_Enqueue(sleeper.Thread)
		else
			table.insert(pending, sleeper)
		end
	end
	self._sleeping = pending
end

function TestScheduler:RunReady(maxSteps)
	maxSteps = maxSteps or 100000
	local steps = 0
	while #self._ready > 0 do
		steps = steps + 1
		if steps > maxSteps then
			error("TestScheduler exceeded maxSteps", 2)
		end
		local entry = table.remove(self._ready, 1)
		self:_ResumeEntry(entry)
		self:_WakeDue()
	end
	if #self._errors > 0 then
		error(self._errors[1], 2)
	end
	return steps
end

function TestScheduler:Advance(seconds, maxSteps)
	assertSeconds(seconds, "TestScheduler:Advance", false)
	local target = self._time + seconds
	local steps = 0
	while true do
		self:_WakeDue()
		steps = steps + self:RunReady(maxSteps)
		local nextWake = nil
		for _, sleeper in ipairs(self._sleeping) do
			if nextWake == nil or sleeper.WakeAt < nextWake then
				nextWake = sleeper.WakeAt
			end
		end
		if nextWake == nil or nextWake > target then
			break
		end
		self._time = nextWake
	end
	self._time = target
	self:_WakeDue()
	steps = steps + self:RunReady(maxSteps)
	return steps
end

function TestScheduler:RunUntilIdle(maxSteps)
	maxSteps = maxSteps or 100000
	local steps = 0
	while #self._ready > 0 or #self._sleeping > 0 do
		self:_WakeDue()
		steps = steps + self:RunReady(maxSteps)
		if #self._ready == 0 and #self._sleeping > 0 then
			local nextWake = nil
			for _, sleeper in ipairs(self._sleeping) do
				if nextWake == nil or sleeper.WakeAt < nextWake then
					nextWake = sleeper.WakeAt
				end
			end
			self._time = nextWake
		end
		if steps > maxSteps then
			error("TestScheduler exceeded maxSteps", 2)
		end
	end
	return steps
end

function TestScheduler:GetErrors()
	return copyArray(self._errors)
end

local defaultRuntime = Runtime.create()

local function proxy(name)
	TaskRuntime[name] = function(...)
		return defaultRuntime[name](defaultRuntime, ...)
	end
end

for _, methodName in ipairs({
	"spawn",
	"defer",
	"delay",
	"every",
	"withTimeout",
	"retry",
	"all",
	"settle",
	"race",
	"any",
	"map",
	"mapLimit",
	"wait",
	"cancel",
	"isCancelled",
	"isDone",
	"getActiveCount",
	"getActiveTasks",
	"getSnapshot",
	"getHistory",
	"getStats",
	"configureDiagnostics",
	"warnLongRunning",
	"setErrorHandler",
	"setCleanupErrorHandler",
	"setWarningHandler",
	"shutdown",
	"cancellationSource",
	"semaphore",
	"queue",
	"debounce",
	"throttle",
	"scope",
	"context",
}) do
	proxy(methodName)
end

TaskRuntime.create = Runtime.create
TaskRuntime.Runtime = Runtime
TaskRuntime.Handle = TaskHandle
TaskRuntime.TaskError = TaskError
TaskRuntime.TaskOutcome = TaskOutcome
TaskRuntime.CancellationToken = CancellationToken
TaskRuntime.CancellationSource = CancellationSource
TaskRuntime.CallbackConnection = CallbackConnection
TaskRuntime.DeadlineHandle = DeadlineHandle
TaskRuntime.CleanupScope = CleanupScope
TaskRuntime.TaskContext = TaskContext
TaskRuntime.Semaphore = Semaphore
TaskRuntime.TaskQueue = TaskQueue
TaskRuntime.TestScheduler = TestScheduler

return TaskRuntime
