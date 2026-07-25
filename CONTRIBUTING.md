# Contributing

Thanks for helping improve TaskRuntime.

## Before opening a change

- Keep the public API small and predictable.
- Preserve existing behavior unless the change is intentionally breaking.
- Do not add promotional wording or exaggerated claims.
- Use plain, direct documentation.
- Avoid engine assumptions that are not verified against Polytoria.

## Development checks

Run:

```text
python3 tools/validate_release.py
python3 tools/build_release.py
```

Then sync the module and tests into Creator. Run the integration test first and the stress test separately:

```text
scripts/tests/task-runtime-test.server.luau
scripts/tests/task-runtime-stress-test.server.luau
```

## Pull requests

A pull request should:

- explain the user-facing problem
- describe the behavior before and after the change
- include or update a regression test
- update documentation and the changelog when behavior changes
- avoid unrelated formatting or refactoring
- keep compatibility with the Polytoria scheduler

## Version changes

- Patch: compatible bug fixes
- Minor: compatible new APIs
- Major: incompatible API or behavior changes

Update `VERSION`, `TaskRuntime.VERSION`, `CHANGELOG.md`, and the version shown in the documentation together.
