-- TaskRuntime
-- A small cancellable scheduler and deterministic cleanup scope for Polytoria Luau.
--
-- Pending tasks can be cancelled before their callback starts. Once a callback is
-- running, cancellation is cooperative because the current runtime does not expose
-- coroutine termination to scripts.

local TaskRuntime = {}

local TaskHandle = {}
TaskHandle.__index = TaskHandle

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

local function reportError(message, handle)
	warn("[TaskRuntime] task " .. tostring(handle.Id) .. " failed: " .. tostring(message))
end

local errorHandler = reportError

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
	}, TaskHandle)

	activeTasks[handle.Id] = handle
	return handle
end

local function finishHandle(handle, state)
	handle.State = state
	handle.FinishedAt = time()
	activeTasks[handle.Id] = nil
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

	local callResults = pack(pcall(callback, table.unpack(args, 1, args.n)))
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
	if TERMINAL_STATES[self.State] then
		return false
	end

	self.Cancelled = true
	self.CancelReason = reason or "cancelled"
	finishHandle(self, "cancelled")
	return true
end

function TaskHandle:IsCancelled()
	return self.Cancelled
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
	if type(seconds) ~= "number" then
		error("TaskRuntime.delay expects seconds to be a number", 2)
	end
	if seconds < 0 then
		error("TaskRuntime.delay expects a non-negative delay", 2)
	end
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
	if seconds ~= nil and type(seconds) ~= "number" then
		error("TaskRuntime.wait expects seconds to be a number or nil", 2)
	end
	if seconds ~= nil and seconds < 0 then
		error("TaskRuntime.wait expects a non-negative delay", 2)
	end

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

	local handles = {}
	for _, handle in pairs(activeTasks) do
		table.insert(handles, handle)
	end

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

local function cleanupEntry(entry)
	local resource = entry.Resource
	local cleanupMethod = entry.CleanupMethod

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
	method(resource)
end

function CleanupScope.new(name)
	return setmetatable({
		Name = name or "CleanupScope",
		_entries = {},
		_destroyed = false,
		_cleaning = false,
	}, CleanupScope)
end

function CleanupScope:IsDestroyed()
	return self._destroyed
end

function CleanupScope:Add(resource, cleanupMethod)
	if self._destroyed or self._cleaning then
		error("cannot add resources to a destroyed cleanup scope", 2)
	end
	if resource == nil then
		error("CleanupScope:Add cannot register nil", 2)
	end
	if cleanupMethod ~= nil and type(cleanupMethod) ~= "string" and type(cleanupMethod) ~= "function" then
		error("cleanup method must be a method name, function, or nil", 2)
	end

	table.insert(self._entries, {
		Resource = resource,
		CleanupMethod = cleanupMethod,
	})

	return resource
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

	for index = #entries, 1, -1 do
		local entry = entries[index]
		local resource = entry.Resource

		if getmetatable(resource) == TaskHandle and reason ~= nil then
			resource:Cancel(reason)
		else
			local succeeded, cleanupError = pcall(cleanupEntry, entry)
			if not succeeded then
				warn("[TaskRuntime] cleanup failed in " .. self.Name .. ": " .. tostring(cleanupError))
			end
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
TaskRuntime.CleanupScope = CleanupScope

return TaskRuntime
