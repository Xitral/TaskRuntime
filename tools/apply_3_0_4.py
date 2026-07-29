from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding="utf-8", newline="\n")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def replace_regex_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one match, found {count}")
    return updated


def update_runtime() -> None:
    path = "scripts/modules/TaskRuntime.luau"
    text = read(path)
    text = replace_once(
        text,
        'TaskRuntime.VERSION = "3.0.3"',
        'TaskRuntime.VERSION = "3.0.4"',
        "runtime version",
    )

    text = replace_once(
        text,
        '''local VALID_QUEUE_OPTIONS = {
\tname = true,
\tscope = true,
}
''',
        '''local VALID_QUEUE_OPTIONS = {
\tname = true,
\tscope = true,
}

local VALID_CALLBACK_MODES = {
\tprotected = true,
\tdirect = true,
}
''',
        "callback mode constants",
    )

    text = replace_once(
        text,
        '''local function assertKnownOptions(options, allowed, apiName)
\tif options == nil then
\t\treturn {}
\tend
\tif type(options) ~= "table" then
\t\terror(apiName .. " expects options to be a table or nil", 3)
\tend
\tfor key in pairs(options) do
\t\tif not allowed[key] then
\t\t\terror(apiName .. " received unknown option " .. tostring(key), 3)
\t\tend
\tend
\treturn options
end
''',
        '''local function assertKnownOptions(options, allowed, apiName)
\tif options == nil then
\t\treturn {}
\tend
\tif type(options) ~= "table" then
\t\terror(apiName .. " expects options to be a table or nil", 3)
\tend
\tfor key in pairs(options) do
\t\tif not allowed[key] then
\t\t\terror(apiName .. " received unknown option " .. tostring(key), 3)
\t\tend
\tend
\treturn options
end

local function normalizeCallbackMode(mode)
\tmode = mode or "protected"
\tif not VALID_CALLBACK_MODES[mode] then
\t\terror("TaskRuntime callbackMode must be 'protected' or 'direct'", 3)
\tend
\treturn mode
end
''',
        "callback mode validation",
    )

    replacement = '''function Runtime:_RunCallback(handle, callback, args)
\tif handle:IsDone() then
\t\treturn
\tend
\tif handle.Cancelled or self._shuttingDown then
\t\tif not handle.Cancelled then
\t\t\thandle:Cancel(self._shutdownReason or "runtime shutdown")
\t\tend
\t\treturn
\tend
\thandle.State = "running"
\thandle.StartedAt = self:_Now()

\t-- Polytoria's custom pcall runs callbacks in a nested Lua thread. Current engine
\t-- builds can intermittently terminate the process when that nested thread yields.
\t-- Direct mode keeps yield-capable callbacks in the engine-supported spawn thread.
\tif self._callbackMode == "direct" then
\t\tlocal callbackThread = coroutine and coroutine.running and coroutine.running() or nil
\t\tif callbackThread ~= nil then
\t\t\tself._currentTasks[callbackThread] = handle
\t\tend
\t\tlocal results = pack(callback(handle.Token, unpackPacked(args)))
\t\tif callbackThread ~= nil then
\t\t\tself._currentTasks[callbackThread] = nil
\t\tend
\t\tif handle.Cancelled then
\t\t\tself:_FinishHandle(handle, "cancelled")
\t\telse
\t\t\tself:_CompleteHandle(handle, results)
\t\tend
\t\treturn
\tend

\tlocal callbackThread = nil
\tlocal callResults = pack(pcall(function()
\t\tcallbackThread = coroutine and coroutine.running and coroutine.running() or nil
\t\tif callbackThread ~= nil then
\t\t\tself._currentTasks[callbackThread] = handle
\t\tend
\t\treturn callback(handle.Token, unpackPacked(args))
\tend))
\tif callbackThread ~= nil then
\t\tself._currentTasks[callbackThread] = nil
\tend
\tif handle.Cancelled then
\t\tself:_FinishHandle(handle, "cancelled")
\t\treturn
\tend
\tif callResults[1] then
\t\tlocal results = { n = callResults.n - 1 }
\t\tfor index = 2, callResults.n do
\t\t\tresults[index - 1] = callResults[index]
\t\tend
\t\tself:_CompleteHandle(handle, results)
\telse
\t\tlocal rawError = callResults[2]
\t\tself:_FailHandle(handle, self:_MakeTaskError(handle, "CALLBACK_FAILED", tostring(rawError), {
\t\t\tCause = rawError,
\t\t\tTraceback = safeTraceback(rawError),
\t\t}), handle.Metadata.suppressErrorHandler == true)
\tend
end
'''
    text = replace_regex_once(
        text,
        r"function Runtime:_RunCallback\(handle, callback, args\).*?\nend\n\nfunction TaskHandle:SetName",
        replacement + "\nfunction TaskHandle:SetName",
        "task callback dispatcher",
    )

    text = replace_once(
        text,
        '''function Runtime:retry(attemptCount, callback, options, ...)
\tassertPositiveInteger(attemptCount, "Runtime:retry")
\tassertCallback(callback, "Runtime:retry")
''',
        '''function Runtime:retry(attemptCount, callback, options, ...)
\tassertPositiveInteger(attemptCount, "Runtime:retry")
\tassertCallback(callback, "Runtime:retry")
\tif self._callbackMode == "direct" then
\t\terror("Runtime:retry requires protected callback mode because retries depend on catching callback errors", 2)
\tend
''',
        "direct retry guard",
    )

    text = replace_once(
        text,
        '''\tlocal results = pack(pcall(callback, ...))
\tself:Release()
\tif not results[1] then
\t\terror(results[2], 2)
\tend
\treturn true, table.unpack(results, 2, results.n)
end

function Runtime:semaphore(limit)
''',
        '''\tif self._runtime._callbackMode == "direct" then
\t\tlocal results = pack(callback(...))
\t\tself:Release()
\t\treturn true, unpackPacked(results)
\tend
\tlocal results = pack(pcall(callback, ...))
\tself:Release()
\tif not results[1] then
\t\terror(results[2], 2)
\tend
\treturn true, table.unpack(results, 2, results.n)
end

function Runtime:semaphore(limit)
''',
        "semaphore direct callback",
    )

    text = replace_once(
        text,
        '''\t\tlocal results = pack(pcall(callback, token, unpackPacked(args)))
\t\tself.Semaphore:Release()
\t\tif not results[1] then
\t\t\terror(results[2], 0)
\t\tend
\t\treturn table.unpack(results, 2, results.n)
\tend)
''',
        '''\t\tif self._runtime._callbackMode == "direct" then
\t\t\tlocal results = pack(callback(token, unpackPacked(args)))
\t\t\tself.Semaphore:Release()
\t\t\treturn unpackPacked(results)
\t\tend
\t\tlocal results = pack(pcall(callback, token, unpackPacked(args)))
\t\tself.Semaphore:Release()
\t\tif not results[1] then
\t\t\terror(results[2], 0)
\t\tend
\t\treturn table.unpack(results, 2, results.n)
\tend)
''',
        "queue direct callback",
    )

    text = replace_once(
        text,
        '''\t\tlocal callbackResults = pack(pcall(callback, context, token, unpackPacked(args)))
\t\tlocal shutdownSuccess, shutdownReason = context:Close("task context completed", context.ChildShutdownTimeout)
\t\tif not shutdownSuccess then
\t\t\terror("task context cleanup failed: " .. tostring(shutdownReason), 0)
\t\tend
\t\tif not callbackResults[1] then
\t\t\terror(callbackResults[2], 0)
\t\tend
\t\treturn table.unpack(callbackResults, 2, callbackResults.n)
''',
        '''\t\tif self._runtime._callbackMode == "direct" then
\t\t\tlocal callbackResults = pack(callback(context, token, unpackPacked(args)))
\t\t\tlocal shutdownSuccess, shutdownReason = context:Close("task context completed", context.ChildShutdownTimeout)
\t\t\tif not shutdownSuccess then
\t\t\t\terror("task context cleanup failed: " .. tostring(shutdownReason), 0)
\t\t\tend
\t\t\treturn unpackPacked(callbackResults)
\t\tend
\t\tlocal callbackResults = pack(pcall(callback, context, token, unpackPacked(args)))
\t\tlocal shutdownSuccess, shutdownReason = context:Close("task context completed", context.ChildShutdownTimeout)
\t\tif not shutdownSuccess then
\t\t\terror("task context cleanup failed: " .. tostring(shutdownReason), 0)
\t\tend
\t\tif not callbackResults[1] then
\t\t\terror(callbackResults[2], 0)
\t\tend
\t\treturn table.unpack(callbackResults, 2, callbackResults.n)
''',
        "context direct callback",
    )

    text = replace_once(
        text,
        '''function Runtime:context(name, options)
\tlocal rootScope = self:scope(name or "TaskContextRoot")
\tlocal source = self:cancellationSource()
\treturn TaskContext.new(self, rootScope, source.Token, options or { name = name })
end

function Runtime.create(options)
''',
        '''function Runtime:context(name, options)
\tlocal rootScope = self:scope(name or "TaskContextRoot")
\tlocal source = self:cancellationSource()
\treturn TaskContext.new(self, rootScope, source.Token, options or { name = name })
end

function Runtime:getCallbackMode()
\treturn self._callbackMode
end

function Runtime.create(options)
''',
        "callback mode getter",
    )

    text = replace_once(
        text,
        '''\tlocal runtime = setmetatable({
\t\t_scheduler = normalizeScheduler(options.scheduler),
\t\t_nextTaskId = 0,
\t\t_activeTasks = {},
\t\t_currentTasks = {},
''',
        '''\tlocal runtime = setmetatable({
\t\t_scheduler = normalizeScheduler(options.scheduler),
\t\t_callbackMode = normalizeCallbackMode(options.callbackMode),
\t\t_nextTaskId = 0,
\t\t_activeTasks = {},
\t\t_currentTasks = setmetatable({}, { __mode = "k" }),
''',
        "runtime callback mode state",
    )

    text = replace_once(
        text,
        '''local defaultRuntime = Runtime.create()

local function proxy(name)
''',
        '''TaskRuntime.CALLBACK_MODE_PROTECTED = "protected"
TaskRuntime.CALLBACK_MODE_DIRECT = "direct"
TaskRuntime.SUPPORTS_POLYTORIA_SAFE_CALLBACKS = true

function TaskRuntime.createPolytoriaSafe(options)
\tlocal safeOptions = shallowCopy(options)
\tif safeOptions.callbackMode ~= nil and safeOptions.callbackMode ~= "direct" then
\t\terror("TaskRuntime.createPolytoriaSafe callbackMode must be 'direct' when provided", 2)
\tend
\tsafeOptions.callbackMode = "direct"
\treturn Runtime.create(safeOptions)
end

TaskRuntime.CreatePolytoriaSafe = TaskRuntime.createPolytoriaSafe

local defaultRuntime = Runtime.create()

local function proxy(name)
''',
        "safe runtime constructor",
    )

    text = replace_once(
        text,
        '''\t"getStats",
\t"configureDiagnostics",
''',
        '''\t"getStats",
\t"getCallbackMode",
\t"configureDiagnostics",
''',
        "callback mode proxy",
    )

    write(path, text)


def update_types() -> None:
    path = "scripts/modules/TaskRuntimeTypes.luau"
    text = read(path)
    text = replace_once(
        text,
        '''-- Optional type definitions for TaskRuntime consumers.
''',
        '''-- Optional type definitions for TaskRuntime consumers.

export type CallbackMode = "protected" | "direct"

export type RuntimeOptions = {
\tscheduler: any?,
\tcallbackMode: CallbackMode?,
\thistorySize: number?,
\tcaptureCreationTrace: boolean?,
\twarningHandler: ((string) -> ())?,
}
''',
        "runtime option types",
    )
    text = replace_once(
        text,
        '''\tgetStats: (self: Runtime) -> { [string]: any },
\tconfigureDiagnostics: (self: Runtime, options: any?) -> any,
''',
        '''\tgetStats: (self: Runtime) -> { [string]: any },
\tgetCallbackMode: (self: Runtime) -> CallbackMode,
\tconfigureDiagnostics: (self: Runtime, options: any?) -> any,
''',
        "callback mode runtime type",
    )
    write(path, text)


def update_self_test() -> None:
    path = "scripts/tests/task-runtime-test.server.luau"
    text = read(path)
    text = replace_once(
        text,
        '''expect(type(TaskRuntime.VERSION) == "string", "VERSION should be available")
''',
        '''expect(type(TaskRuntime.VERSION) == "string", "VERSION should be available")
expect(type(TaskRuntime.createPolytoriaSafe) == "function", "Polytoria-safe constructor should be available")
expectEqual(TaskRuntime.getCallbackMode(), "protected", "default runtime should preserve protected callbacks")

local polytoriaSafeRuntime = TaskRuntime.createPolytoriaSafe({ historySize = 16 })
expectEqual(polytoriaSafeRuntime:getCallbackMode(), "direct", "safe runtime should use direct callbacks")
local safeYieldTask = polytoriaSafeRuntime:spawn(function(token)
\texpect(token:Wait(0.01), "direct callback wait should complete")
\treturn "safe"
end)
local safeYieldSuccess, safeYieldValue = safeYieldTask:Await(1)
expect(safeYieldSuccess and safeYieldValue == "safe", "direct callback should yield and resume")
polytoriaSafeRuntime:shutdown("safe constructor self-test complete")
''',
        "safe runtime self-test",
    )
    write(path, text)


def create_engine_regression_test() -> None:
    path = ROOT / "scripts/tests/task-runtime-polytoria-safe.server.luau"
    path.write_text(
        '''-- TaskRuntime regression test for Polytoria issue #758.
-- Link beside TaskRuntime in Creator and run several fresh playtests.

local TaskRuntime = require(game["ScriptService"]["TaskRuntime"])
local runtime = TaskRuntime.createPolytoriaSafe({ historySize = 32 })

if runtime:getCallbackMode() ~= "direct" then
\terror("TaskRuntime Polytoria-safe test did not enter direct callback mode")
end

local scope = runtime:scope("PolytoriaSafeYieldRegression")
local completed = 0
local workerCount = 128

for _ = 1, workerCount do
\tscope:Spawn(function(token)
\t\tfor _ = 1, 8 do
\t\t\tif not token:Wait(0) then
\t\t\t\treturn
\t\t\tend
\t\tend
\t\tcompleted = completed + 1
\tend)
end

local deadline = tick() + 10
while completed < workerCount and tick() < deadline do
\twait(0)
end

if completed ~= workerCount then
\terror("TaskRuntime Polytoria-safe yield test timed out: " .. tostring(completed) .. "/" .. tostring(workerCount))
end

local pulses = 0
local repeating = scope:Every(0.01, function(token)
\tif token:IsCancelled() then
\t\treturn
\tend
\tpulses = pulses + 1
end)

local pulseDeadline = tick() + 5
while pulses < 20 and tick() < pulseDeadline do
\twait(0)
end

if pulses < 20 then
\terror("TaskRuntime Polytoria-safe repeating task stalled at " .. tostring(pulses))
end

repeating:Cancel("regression complete")
scope:Destroy("regression complete")
runtime:shutdown("regression complete")

print("TaskRuntime Polytoria-safe yield test passed")
''',
        encoding="utf-8",
        newline="\n",
    )


def update_validation() -> None:
    path = "tools/validate_release.py"
    text = read(path)
    text = replace_once(
        text,
        '''    "scripts/tests/task-runtime-stress-test.server.luau",
''',
        '''    "scripts/tests/task-runtime-stress-test.server.luau",
    "scripts/tests/task-runtime-polytoria-safe.server.luau",
''',
        "required regression test",
    )
    text = replace_once(
        text,
        '''    stress_test = read("scripts/tests/task-runtime-stress-test.server.luau")
''',
        '''    stress_test = read("scripts/tests/task-runtime-stress-test.server.luau")
    polytoria_safe_test = read("scripts/tests/task-runtime-polytoria-safe.server.luau")
''',
        "read regression test",
    )
    text = replace_once(
        text,
        '''    if "TaskRuntime stress test passed" not in stress_test:
        fail("stress-test success marker is missing")
''',
        '''    if "TaskRuntime stress test passed" not in stress_test:
        fail("stress-test success marker is missing")
    if "TaskRuntime Polytoria-safe yield test passed" not in polytoria_safe_test:
        fail("Polytoria-safe regression success marker is missing")
''',
        "validate regression marker",
    )
    write(path, text)


def update_readme() -> None:
    path = "README.md"
    text = read(path)
    text = text.replace("**Current release: 3.0.3**", "**Current release: 3.0.4**")
    text = replace_once(
        text,
        '''- Polytoria-specific handling for waits inside the engine's custom `pcall`
''',
        '''- Protected callbacks for structured failure outcomes
- Optional Polytoria-safe direct callbacks for yield-heavy runtime work
''',
        "readme highlights",
    )
    text = replace_once(
        text,
        '''Destroying the scope cancels its tasks and cleans every registered resource.
''',
        '''Destroying the scope cancels its tasks and cleans every registered resource.

For callbacks that call `wait`, `token:Wait`, or signal `Wait` on Polytoria builds affected by
[engine issue #758](https://github.com/Polytoria/polytoria-game/issues/758), create an isolated
safe runtime:

```luau
local SafeTasks = TaskRuntime.createPolytoriaSafe()
local scope = SafeTasks:scope("YieldingSystems")
```

Safe runtimes execute callbacks directly in Polytoria's supported `spawn` thread instead of the
engine's nested `pcall` coroutine. See the compatibility notes before using failure-driven APIs.
''',
        "readme safe mode",
    )
    text = replace_once(
        text,
        '''scripts/tests/task-runtime-stress-test.server.luau
''',
        '''scripts/tests/task-runtime-stress-test.server.luau
scripts/tests/task-runtime-polytoria-safe.server.luau
''',
        "readme test list",
    )
    text = replace_once(
        text,
        '''TaskRuntime stress test passed
''',
        '''TaskRuntime stress test passed
TaskRuntime Polytoria-safe yield test passed
''',
        "readme success markers",
    )
    text = replace_once(
        text,
        '''TaskRuntime uses Polytoria's supported `wait` path for the default scheduler. Raw coroutine parking is only enabled for custom schedulers that explicitly declare support.
''',
        '''TaskRuntime uses Polytoria's supported `wait` path for the default scheduler. Raw coroutine parking is only enabled for custom schedulers that explicitly declare support.

The default runtime uses `callbackMode = "protected"` and preserves structured task failures. A
runtime created with `createPolytoriaSafe()` uses `callbackMode = "direct"`, allowing callbacks to
yield without entering Polytoria's custom nested-`pcall` coroutine. In direct mode, callback errors
are reported by the engine and cannot be converted into `failed` task outcomes. `retry` therefore
requires protected mode, and direct-mode callbacks should return normally rather than throw.
''',
        "readme compatibility",
    )
    write(path, text)


def update_docs() -> None:
    path = "docs/task-runtime.md"
    text = read(path)
    text = text.replace("```text\n3.0.3\n```", "```text\n3.0.4\n```", 1)
    text = replace_once(
        text,
        '''Version 3.0.3 is the first supported public release. TaskRuntime follows semantic versioning and keeps compatible APIs stable within the same major version.
''',
        '''Version 3.0.4 adds an opt-in Polytoria-safe callback mode for yield-heavy work while preserving the protected callback behavior of 3.0.3 by default. TaskRuntime follows semantic versioning and keeps compatible APIs stable within the same major version.
''',
        "docs release status",
    )
    text = replace_once(
        text,
        '''## Task callback convention
''',
        '''## Callback execution modes

The default runtime uses protected callbacks:

```luau
local ProtectedTasks = TaskRuntime.create({ callbackMode = "protected" })
```

Protected mode converts callback errors into structured `failed` outcomes, enabling `Catch`,
failure-driven `retry`, and scope failure policies. Polytoria implements `pcall` by creating a
nested Lua thread. Engine issue #758 reports intermittent process crashes when nested coroutines
yield, so callbacks that call `wait`, `token:Wait`, or signal `Wait` can instead use direct mode:

```luau
local SafeTasks = TaskRuntime.createPolytoriaSafe()
local scope = SafeTasks:scope("YieldingSystems")

scope:Every(1, function(token)
\tif not token:Wait(0.1) then
\t\treturn
\tend
\tupdateSystem()
end)
```

Direct mode keeps the callback inside Polytoria's engine-supported `spawn` thread. Because the
engine does not provide an error result for `spawn`, thrown callback errors cannot be converted
into TaskRuntime outcomes. A direct-mode callback that throws may remain recorded as running until
its scope is destroyed. Write direct-mode callbacks to return normally, use cancellation checks,
and let expected failures be represented as values. `Runtime:retry` is unavailable in direct mode
because its contract depends on catching callback errors.

`runtime:getCallbackMode()` reports `"protected"` or `"direct"`.

## Task callback convention
''',
        "docs callback modes",
    )
    write(path, text)


def update_changelog() -> None:
    path = "CHANGELOG.md"
    text = read(path)
    entry = '''## [3.0.4] - 2026-07-29

### Added

- `TaskRuntime.createPolytoriaSafe(options?)` for yield-heavy callbacks on affected Polytoria builds
- `callbackMode = "protected" | "direct"` on `TaskRuntime.create`
- `runtime:getCallbackMode()` and callback-mode constants
- Creator regression coverage for repeated direct callback waits

### Fixed

- Yield-capable task bodies can now avoid Polytoria's nested custom-`pcall` coroutine, matching the engine-supported `spawn` path and mitigating Polytoria engine issue #758
- Runtime current-task bookkeeping now uses weak coroutine keys
- Repository validation now runs on the actual `main` branch

### Compatibility

- Protected mode remains the default and preserves structured failed outcomes
- Direct mode does not catch thrown callback errors; `retry` requires protected mode
- Queue, semaphore, and task-context callbacks run directly when their runtime uses direct mode

'''
    text = replace_once(text, "## [3.0.3] - 2026-07-25\n", entry + "## [3.0.3] - 2026-07-25\n", "changelog entry")
    write(path, text)


def update_workflow() -> None:
    path = ".github/workflows/validate.yml"
    text = read(path)
    text = text.replace("      - master\n", "      - main\n")
    if "master" in text:
        raise RuntimeError("validate workflow still references master")
    write(path, text)


def main() -> None:
    write("VERSION", "3.0.4\n")
    update_runtime()
    update_types()
    update_self_test()
    create_engine_regression_test()
    update_validation()
    update_readme()
    update_docs()
    update_changelog()
    update_workflow()
    print("TaskRuntime 3.0.4 migration applied")


if __name__ == "__main__":
    main()
