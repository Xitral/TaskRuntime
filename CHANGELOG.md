# Changelog

All notable changes to TaskRuntime are documented here.

The project follows semantic versioning.

## [3.0.3] - 2026-07-25

First supported public release.

### Added

- Cancellable and awaitable task handles
- Cancellation tokens and linked cancellation sources
- Delays, repeating tasks, timeouts, and cancellable deadlines
- Completion chains through `Then`, `Catch`, and `Finally`
- Retry policies with delay, backoff, jitter, filtering, and callbacks
- Task composition through `all`, `settle`, `race`, and `any`
- Bounded concurrency through semaphores, queues, and `mapLimit`
- Debounce and throttle helpers
- Cleanup scopes, named resources, child scopes, and task contexts
- Per-resource and whole-scope cleanup deadlines
- Structured task and cleanup errors
- Runtime snapshots, history, statistics, and long-running task warnings
- Optional exported Luau types
- Deterministic virtual-time testing
- Creator integration and stress tests
- Automated validation and tagged-release packaging
- Public disclosure of AI-assisted development and documentation

### Fixed

- Await timeouts no longer race normal task completion on Polytoria scheduler ticks
- Retry waits now resume correctly inside task callbacks
- `race`, `any`, and fail-fast `all` cancel unfinished children before observers resume
- Waits inside Polytoria's custom `pcall` no longer return early
- `mapLimit` now enforces its configured concurrency under Polytoria's scheduler

### Compatibility

- The default scheduler uses Polytoria's `wait` implementation
- Custom schedulers must explicitly opt into raw coroutine parking
- Cancellation remains cooperative and cannot forcibly terminate a running callback
