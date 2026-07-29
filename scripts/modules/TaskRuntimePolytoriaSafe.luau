-- TaskRuntime Polytoria-safe callback adapter.
--
-- Link this module beside TaskRuntime under ScriptService, then require this module
-- instead of TaskRuntime when callbacks need to yield on current Polytoria builds.
-- Protected callback handling remains the default for existing consumers.

local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])

if TaskRuntime.SUPPORTS_POLYTORIA_SAFE_CALLBACKS == true then
	return TaskRuntime
end

local Runtime = TaskRuntime.Runtime
local Semaphore = TaskRuntime.Semaphore
local TaskQueue = TaskRuntime.TaskQueue
local CleanupScope = TaskRuntime.CleanupScope
local TaskContext = TaskRuntime.TaskContext

local protectedRunCallback = Runtime._RunCallback
local protectedRetry = Runtime.retry
local protectedMapLimit = Runtime.mapLimit
local protectedWithPermit = Semaphore.WithPermit
local protectedQueueAdd = TaskQueue.Add
local protectedScopeRun = CleanupScope.Run
local originalCreate = TaskRuntime.create

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

local function isPositiveInteger(value)
	return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function usesDirectCallbacks(runtime)
	return runtime ~= nil and runtime._callbackMode == "direct"
end

-- Polytoria's custom pcall executes its callback inside a nested Lua thread.
-- Current engine builds can terminate the process when that nested thread yields.
-- Direct mode keeps yield-capable callbacks in the scheduler's spawn thread.
function Runtime:_RunCallback(handle, callback, args)
	if not usesDirectCallbacks(self) then
		return protectedRunCallback(self, handle, callback, args)
	end
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

	local callbackThread = coroutine and coroutine.running and coroutine.running() or nil
	if callbackThread ~= nil then
		self._currentTasks[callbackThread] = handle
	end

	local results = pack(callback(handle.Token, unpackPacked(args)))

	if callbackThread ~= nil then
		self._currentTasks[callbackThread] = nil
	end
	if handle.Cancelled then
		self:_FinishHandle(handle, "cancelled")
	else
		self:_CompleteHandle(handle, results)
	end
end

function Runtime:getCallbackMode()
	return self._callbackMode or "protected"
end

function Runtime:retry(attemptCount, callback, options, ...)
	if usesDirectCallbacks(self) then
		error("Runtime:retry requires protected callback mode because retries depend on catching callback errors", 2)
	end
	return protectedRetry(self, attemptCount, callback, options, ...)
end

function Semaphore:WithPermit(token, callback, timeoutSeconds, ...)
	if not usesDirectCallbacks(self._runtime) then
		return protectedWithPermit(self, token, callback, timeoutSeconds, ...)
	end
	if type(callback) ~= "function" then
		error("Semaphore:WithPermit expects a function callback", 2)
	end
	local acquired, reason = self:Acquire(token, timeoutSeconds)
	if not acquired then
		return false, reason
	end
	local results = pack(callback(...))
	self:Release()
	return true, unpackPacked(results)
end

function TaskQueue:Add(callback, ...)
	if not usesDirectCallbacks(self._runtime) then
		return protectedQueueAdd(self, callback, ...)
	end
	if self.Closed then
		error("cannot add work to a closed TaskQueue", 2)
	end
	if type(callback) ~= "function" then
		error("TaskQueue:Add expects a function callback", 2)
	end

	local args = pack(...)
	local task = self._runtime:spawn(function(token)
		local acquired, reason = self.Semaphore:Acquire(token)
		if not acquired then
			error(reason or "queue acquire failed", 0)
		end
		local results = pack(callback(token, unpackPacked(args)))
		self.Semaphore:Release()
		return unpackPacked(results)
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

function Runtime:mapLimit(items, concurrency, callback, options)
	if not usesDirectCallbacks(self) then
		return protectedMapLimit(self, items, concurrency, callback, options)
	end
	if type(items) ~= "table" then
		error("Runtime:mapLimit expects an array", 2)
	end
	if not isPositiveInteger(concurrency) then
		error("Runtime:mapLimit expects a positive integer", 2)
	end
	if type(callback) ~= "function" then
		error("Runtime:mapLimit expects a function callback", 2)
	end

	options = options or {}
	local semaphore = self:semaphore(concurrency)
	local tasks = {}
	for index, item in ipairs(items) do
		tasks[index] = self:spawn(function(token)
			local acquired, reason = semaphore:Acquire(token, options.acquireTimeout)
			if not acquired then
				error(reason or "semaphore acquire failed", 0)
			end
			local results = pack(callback(token, item, index))
			semaphore:Release()
			return unpackPacked(results)
		end)
		tasks[index].Kind = "map"
	end
	return self:all(tasks, {
		failFast = options.failFast ~= false,
		cancelRemaining = options.cancelRemaining ~= false,
		cancelOnCancel = true,
	})
end

function CleanupScope:Run(callback, options, ...)
	if not usesDirectCallbacks(self._runtime) then
		return protectedScopeRun(self, callback, options, ...)
	end
	if type(callback) ~= "function" then
		error("CleanupScope:Run expects a function callback", 2)
	end
	if options ~= nil and type(options) ~= "table" then
		error("CleanupScope:Run expects options to be a table or nil", 2)
	end

	local args = pack(...)
	local handle = nil
	handle = self:Spawn(function(token)
		local context = TaskContext.new(self._runtime, self, token, options)
		context.RootTaskId = handle and handle.Id or nil
		local callbackResults = pack(callback(context, token, unpackPacked(args)))
		local shutdownSuccess, shutdownReason = context:Close("task context completed", context.ChildShutdownTimeout)
		if not shutdownSuccess then
			error("task context cleanup failed: " .. tostring(shutdownReason), 0)
		end
		return unpackPacked(callbackResults)
	end)
	handle.Kind = "context"
	handle.Name = (options and options.name) or (self.Name .. ":context#" .. tostring(handle.Id))
	return handle
end

local function createWithMode(options)
	local createOptions = shallowCopy(options)
	local callbackMode = createOptions.callbackMode or "protected"
	if callbackMode ~= "protected" and callbackMode ~= "direct" then
		error("TaskRuntime callbackMode must be 'protected' or 'direct'", 3)
	end
	createOptions.callbackMode = nil
	local runtime = originalCreate(createOptions)
	runtime._callbackMode = callbackMode
	runtime._currentTasks = setmetatable(runtime._currentTasks or {}, { __mode = "k" })
	return runtime
end

function TaskRuntime.createPolytoriaSafe(options)
	local safeOptions = shallowCopy(options)
	if safeOptions.callbackMode ~= nil and safeOptions.callbackMode ~= "direct" then
		error("TaskRuntime.createPolytoriaSafe callbackMode must be 'direct' when provided", 2)
	end
	safeOptions.callbackMode = "direct"
	return createWithMode(safeOptions)
end

TaskRuntime.create = createWithMode
Runtime.create = createWithMode
TaskRuntime.CreatePolytoriaSafe = TaskRuntime.createPolytoriaSafe
TaskRuntime.CALLBACK_MODE_PROTECTED = "protected"
TaskRuntime.CALLBACK_MODE_DIRECT = "direct"
TaskRuntime.SUPPORTS_POLYTORIA_SAFE_CALLBACKS = true
TaskRuntime.POLYTORIA_SAFE_ADAPTER_VERSION = "1.0.0"

return TaskRuntime
