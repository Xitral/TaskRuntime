# TaskRuntime

`TaskRuntime` is an asynchronous task and cleanup library for Polytoria Luau. It provides scheduling, cooperative cancellation, task composition, lifecycle scopes, bounded concurrency, cleanup deadlines, diagnostics, and deterministic virtual-time testing.

Current version:

```text
3.0.3
```

## Release status

Version 3.0.3 is the first supported public release. TaskRuntime follows semantic versioning and keeps compatible APIs stable within the same major version.

An unreleased additive compatibility adapter is available at `scripts/modules/TaskRuntimePolytoriaSafe.luau`. See [Polytoria-safe callbacks](polytoria-safe-callbacks.md) for its setup, behavior, and limitations.

## Why this is needed

Most game systems create work that should only exist for part of the game session. Examples include:

- round timers
- player autosaves
- vehicle update loops
- temporary effects
- signal connections
- delayed callbacks
- background requests
- child systems

Without explicit ownership, old work can continue after the system that created it has ended. This can cause duplicate callbacks, stale timers, memory retention, extra physics work, repeated saves, and old systems interfering with new ones.

`TaskRuntime` gives that work an owner and a clear stopping path.

## What happens without it

Consider a round script that creates a delayed callback and a player connection every time a round starts. If the round restarts without cleaning those resources, every old callback and connection can remain active.

After several rounds, one player join may trigger several handlers and several old timers may end the wrong round. The bug appears to be random, but the actual cause is work surviving past its intended lifecycle.

A cleanup scope prevents that:

```luau
local roundScope = TaskRuntime.scope("Round")

roundScope:Delay(60, function(token)
	endRound()
end)

roundScope:Connect(game["Players"].PlayerAdded, function(player)
	print(player.Name, "joined")
end)

function stopRound()
	roundScope:Destroy("round ended")
end
```

Destroying the scope cancels the timer and disconnects the signal.

## Project files

- `scripts/modules/TaskRuntime.luau`: runtime module
- `scripts/modules/TaskRuntimePolytoriaSafe.luau`: optional direct-callback compatibility adapter
- `scripts/modules/TaskRuntimeTypes.luau`: optional exported Luau types
- `scripts/server/script.server.luau`: server root example
- `scripts/tests/task-runtime-test.server.luau`: Creator self-test
- `scripts/tests/task-runtime-stress-test.server.luau`: optional Creator stress test
- `scripts/tests/task-runtime-polytoria-safe-test.server.luau`: adapter regression test
- `docs/task-runtime.md`: main documentation
- `docs/task-runtime-examples.md`: copy-paste examples
- `docs/polytoria-safe-callbacks.md`: safe callback guide

## Creator setup

Link `scripts/modules/TaskRuntime.luau` to a `ModuleScript` named `TaskRuntime` under `ScriptService`.

```text
ScriptService
├── TaskRuntime
├── script
└── task-runtime-test
```

Load the module with:

```luau
local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
```

Check the installed version with:

```luau
print(TaskRuntime.VERSION)
```

## Compatibility

The existing APIs remain available:

```luau
TaskRuntime.spawn(callback, ...)
TaskRuntime.defer(callback, ...)
TaskRuntime.delay(seconds, callback, ...)
TaskRuntime.every(seconds, callback, ...)
TaskRuntime.wait(seconds?)
TaskRuntime.scope(name?, options?)
```

Existing task handles still support:

```luau
handle:Cancel(reason?)
handle:Await(timeoutSeconds?)
handle:IsDone()
handle:IsCancelled()
```

For yield-heavy systems affected by Polytoria's nested `pcall` callback behavior, link and require `TaskRuntimePolytoriaSafe`, then create a direct runtime with `TaskRuntime.createPolytoriaSafe()`. The normal module-level runtime remains protected and unchanged.

## Task callback convention

Every scheduled callback receives a `CancellationToken` as its first argument. Extra arguments follow it.

```luau
local task = TaskRuntime.spawn(function(token, left, right)
	if token:IsCancelled() then
		return
	end

	return left + right
end, 2, 3)
```

## Task states

A task can be in one of these states:

- `scheduled`
- `running`
- `cancelling`
- `completed`
- `cancelled`
- `failed`

Pending tasks cancel immediately. Running callbacks use cooperative cancellation. A running callback enters `cancelling` and remains active until its code exits.

## Scheduling

### Run immediately

```luau
local task = TaskRuntime.spawn(function(token)
	return loadPlayerData()
end)
```

### Run on a later scheduler step

```luau
TaskRuntime.defer(function(token)
	initializeAfterStartup()
end)
```

### Run after a delay

```luau
TaskRuntime.delay(5, function(token)
	print("Five seconds passed")
end)
```

### Repeat without overlap

```luau
local heartbeat = TaskRuntime.every(10, function(token)
	saveDirtyProfiles()
end)
```

The first run happens after one interval. Repeating callbacks never overlap. If a callback takes longer than its interval, missed runs are counted in `SkippedIntervals` and skipped instead of replayed in a burst.

## Cancellation

### Cancel a task

```luau
worker:Cancel("system ended")
```

### Check cancellation inside a callback

```luau
local worker = TaskRuntime.spawn(function(token)
	while not token:IsCancelled() do
		performOneStep()
		TaskRuntime.wait(0)
	end
end)
```

### Wait while remaining cancellable

```luau
if not token:Wait(5) then
	return
end
```

### React immediately to cancellation

```luau
local connection = token:OnCancel(function(reason)
	print("Stopping:", reason)
end)
```

### Throw when cancelled

```luau
token:ThrowIfCancelled()
```

## Cancellation sources

A cancellation source lets several operations share one cancellation signal.
