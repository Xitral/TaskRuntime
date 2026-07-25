-- Root server lifecycle bootstrap.
--
-- TaskRuntime should be linked as a ModuleScript named "TaskRuntime" under
-- ScriptService. Keep all resources owned by this script inside rootScope.

local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
local rootScope = TaskRuntime.scope("ServerRoot")

-- Example:
-- rootScope:Delay(5, function(token)
-- 	if token:IsCancelled() then
-- 		return
-- 	end
-- 	print("Five seconds elapsed")
-- end)
--
-- rootScope:Connect(game["Players"].PlayerAdded, function(player)
-- 	print(player.Name .. " joined")
-- end)

function Shutdown()
	rootScope:Destroy("server root shutdown")
end

-- This is ready for the engine lifecycle hook once Polytoria invokes _Dispose.
-- Until then, Shutdown() can be called explicitly through BaseScript:Call().
function _Dispose()
	Shutdown()
end
