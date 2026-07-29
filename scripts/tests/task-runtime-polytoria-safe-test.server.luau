-- TaskRuntime Polytoria-safe adapter self-test.
-- Link TaskRuntime and TaskRuntimePolytoriaSafe under ScriptService, then run this
-- script as a ServerScript in Creator.

local TaskRuntime = require(game["ScriptService"]["TaskRuntimePolytoriaSafe"])

local function expect(condition, message)
	if not condition then
		error("TaskRuntime Polytoria-safe adapter test failed: " .. message)
	end
end

local function expectEqual(actual, expected, message)
	if actual ~= expected then
		error(
			"TaskRuntime Polytoria-safe adapter test failed: "
				.. message
				.. " ("
				.. tostring(actual)
				.. " ~= "
				.. tostring(expected)
				.. ")"
		)
	end
end

expect(TaskRuntime.SUPPORTS_POLYTORIA_SAFE_CALLBACKS == true, "adapter feature flag should be available")
expectEqual(TaskRuntime.POLYTORIA_SAFE_ADAPTER_VERSION, "1.0.0", "adapter version should be available")

local protectedScheduler = TaskRuntime.TestScheduler.new()
local protectedRuntime = TaskRuntime.create({ scheduler = protectedScheduler })
expectEqual(protectedRuntime:getCallbackMode(), "protected", "ordinary runtimes should remain protected")

local scheduler = TaskRuntime.TestScheduler.new()
local runtime = TaskRuntime.createPolytoriaSafe({ scheduler = scheduler })
expectEqual(runtime:getCallbackMode(), "direct", "safe runtimes should use direct callbacks")

local task = runtime:spawn(function(token, left, right)
	expect(token:Wait(1), "direct callback should yield and resume")
	return left + right, "resumed"
end, 4, 6)

scheduler:RunReady()
expectEqual(task.State, "running", "task should remain active while waiting")
scheduler:Advance(1)

local succeeded, sum, marker = task:Await(0)
expect(succeeded, "yielding direct callback should complete")
expectEqual(sum, 10, "direct callback should preserve results")
expectEqual(marker, "resumed", "direct callback should resume after yielding")

local retryAccepted = pcall(function()
	runtime:retry(2, function()
		return true
	end)
end)
expect(not retryAccepted, "direct mode should reject retry because retry requires protected errors")

print("TaskRuntime Polytoria-safe adapter test passed")
