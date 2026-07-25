-- TaskRuntime stress test.
-- Run this separately from task-runtime-test.server.luau.
-- Link it to a ServerScript under ScriptService and start a local playtest.

local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])

local function expect(condition, message)
	if not condition then
		error("TaskRuntime stress test failed: " .. message)
	end
end

local itemCount = 240
local concurrency = 12
local items = {}

for index = 1, itemCount do
	items[index] = index
end

local active = 0
local peakActive = 0
local processed = 0

local mapped = TaskRuntime.mapLimit(items, concurrency, function(token, item)
	active = active + 1
	peakActive = math.max(peakActive, active)

	if not token:Wait(0.01) then
		active = active - 1
		return nil
	end

	processed = processed + 1
	active = active - 1
	return item * 2
end)

local mappedSuccess, mappedResults = mapped:Await(15)
expect(mappedSuccess, "mapLimit workload should complete")
expect(processed == itemCount, "every map item should be processed")
expect(peakActive == concurrency, "mapLimit should reach but not exceed its limit")
expect(mappedResults[itemCount][1] == itemCount * 2, "map results should preserve input order")

local cancellationCount = 500
local cancellationTasks = {}

for index = 1, cancellationCount do
	cancellationTasks[index] = TaskRuntime.delay(10, function()
		error("cancelled stress task should never execute")
	end)
end

for _, task in ipairs(cancellationTasks) do
	task:Cancel("stress cancellation")
end

local settled = TaskRuntime.settle(cancellationTasks)
local settledSuccess, outcomes = settled:Await(5)
expect(settledSuccess, "cancelled tasks should settle")

for _, outcome in ipairs(outcomes) do
	expect(outcome.Status == "cancelled", "every cancelled task should report cancellation")
end

TaskRuntime.wait(0)

local snapshot = TaskRuntime.getSnapshot()
expect(snapshot.ActiveCount == 0, "stress test should release every task")
expect(snapshot.PendingDeadlines == 0, "stress test should release every deadline")

print("TaskRuntime stress test passed")
