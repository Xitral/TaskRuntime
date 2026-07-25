-- TaskRuntime
-- Cancellable scheduling and deterministic resource cleanup for Polytoria Luau.
--
-- Every scheduled callback receives a CancellationToken as its first argument.
-- Pending tasks cancel immediately. Running tasks enter the "cancelling" state
-- and remain active until their callback exits cooperatively.

local TaskRuntime = {}

local TaskHandle = {}
TaskHandle.__index = TaskHandle

local CancellationToken = {}
CancellationToken.__index = CancellationToken

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
		error(apiName .. " expects a non-negative delay", 3)
	end
end

local function reportError(message, handle)
	warn("[TaskRuntime] task " .. tostring(handle.Id) .. " failed: " .. tostring(message))
end

local errorHandler = reportError

local function makeToken()
	return setmetatable({
		_cancelled = false,
		_reason = nil,
	}, CancellationToken)
end

function CancellationToken:IsCancelled()
	return self._cancelled
end

function CancellationToken:GetReason()
	return self._reason
end

-- Waits in short slices so cancellation can be observed without waiting for the
-- entire duration. Returns false when cancelled and true when the delay elapses.
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
	return true
end

local function makeHandle(kind)
	nextTaskId = nextTaskId + 1

	local handle = setmetatable({
		Id = nextTaskId,
		Kind = kind,
		State = "scheduled",
		Cancelled = false,
		CancelReason = nil,
		CreatedAt = time(),
		StartedAt = nil,
		FinishedAt = nil,
		Error = nil,
		Results = nil,
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
	for _, callback in ipairs(callbacks) do
		local succeeded, callbackError = pcall(callback, handle)
		if not succeeded then
			warn("[TaskRuntime] completion callback failed: " .. tostring(callbackError))
		end
	end

	return true
end

local function runCallback(handle, callback, args)
	if handle.Cancelled or runtimeShuttingDown then
		if not handle.Cancelled then
			handle:Cancel(runtimeShutdownReason or "runtime shutdown")
		end
		return
	end

	handle.State = "running"
	handle.StartedAt = time()

	local callResults = pack(pcall(callback, handle.Token, table.unpack(args, 1, args.n)))
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

		local handlerSucceeded, handlerError = pcall(errorHandler, handle.Error, handle)
		if not handlerSucceeded then
			warn("[TaskRuntime] error handler failed: " .. tostring(handlerError))
		end
	end
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

function TaskHandle:IsCancelled()
	return self.Cancelled
end

function TaskHandle:IsCancellationRequested()
	return self.Token:IsCancelled()
end

function TaskHandle:IsDone()
	return TERMINAL_STATES[self.State] == true
end

function TaskHandle:Await()
	while not self:IsDone() do
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

	return true, table.unpack(self.Results, 1, self.Results.n)
end

function TaskHandle:_OnFinished(callback)
	assertCallback(callback, "TaskHandle:_OnFinished")
	if self:IsDone() then
		callback(self)
	else
		table.insert(self._completionCallbacks, callback)
	end
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
		wait(0)
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
		wait(seconds)
		runCallback(handle, callback, args)
	end)

	return handle
end

function TaskRuntime.wait(seconds)
	assertSeconds(seconds, "TaskRuntime.wait", true)
	local startedAt = time()
	wait(seconds or 0)
	return time() - startedAt
end

function TaskRuntime.cancel(handle, reason)
	if getmetatable(handle) ~= TaskHandle then
		error("TaskRuntime.cancel expects a task handle", 2)
	end
	return handle:Cancel(reason)
end

function TaskRuntime.isCancelled(handle)
	return getmetatable(handle) == TaskHandle and handle:IsCancelled()
end

function TaskRuntime.isDone(handle)
	return getmetatable(handle) == TaskHandle and handle:IsDone()
end

function TaskRuntime.getActiveCount()
	local count = 0
	for _ in pairs(activeTasks) do
		count = count + 1
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

function TaskRuntime.setErrorHandler(handler)
	if handler == nil then
		errorHandler = reportError
		return
	end

	assertCallback(handler, "TaskRuntime.setErrorHandler")
	errorHandler = handler
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
		cleanupMethod(resource)
		return
	end

	if type(resource) == "function" and cleanupMethod == nil then
		resource()
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
	method(resource)
end

function CleanupScope.new(name)
	return setmetatable({
		Name = name or "CleanupScope",
		_entries = {},
		_keyedEntries = {},
		_destroyed = false,
		_cleaning = false,
	}, CleanupScope)
end

function CleanupScope:IsDestroyed()
	return self._destroyed
end

function CleanupScope:GetCount()
	return #self._entries
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

	-- Completed tasks should not remain strongly referenced for the lifetime of a
	-- long-running scope.
	if getmetatable(resource) == TaskHandle then
		resource:_OnFinished(function()
			self:_DetachEntry(entry)
		end)
	end

	return resource
end

function CleanupScope:Add(resource, cleanupMethod)
	return self:_AddEntry(resource, cleanupMethod, nil)
end

-- Registers a named resource. Replacing a key cleans the previous resource first.
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

-- Removes a named resource. Cleanup is enabled by default.
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
			warn("[TaskRuntime] cleanup failed in " .. self.Name .. ": " .. tostring(cleanupError))
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

function CleanupScope:Child(name)
	return self:Add(CleanupScope.new(name), "Destroy")
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
		entry.Active = false

		local succeeded, cleanupError = pcall(
			cleanupResource,
			entry.Resource,
			entry.CleanupMethod,
			reason or (self.Name .. " cleaned up")
		)
		if not succeeded then
			warn("[TaskRuntime] cleanup failed in " .. self.Name .. ": " .. tostring(cleanupError))
		end
	end

	self._cleaning = false
	self._destroyed = true
	return true
end

function CleanupScope:Destroy(reason)
	return self:Cleanup(reason or (self.Name .. " destroyed"))
end

function CleanupScope:_Dispose()
	return self:Destroy(self.Name .. " disposed")
end

function TaskRuntime.scope(name)
	return CleanupScope.new(name)
end

TaskRuntime.Handle = TaskHandle
TaskRuntime.CancellationToken = CancellationToken
TaskRuntime.CleanupScope = CleanupScope

return TaskRuntime
