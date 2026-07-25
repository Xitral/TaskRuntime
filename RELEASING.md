# Releasing TaskRuntime

## 1. Choose the version

Update all of these together:

- `VERSION`
- `TaskRuntime.VERSION` in `scripts/modules/TaskRuntime.luau`
- the current version in `README.md`
- the current version in `docs/task-runtime.md`
- the newest section in `CHANGELOG.md`

## 2. Validate the repository

```text
python3 tools/validate_release.py
python3 tools/build_release.py
```

Inspect the generated files under `dist/`.

## 3. Run Creator tests

Run the integration test with the stress test disabled:

```text
scripts/tests/task-runtime-test.server.luau
```

Then run the stress test with the integration test disabled:

```text
scripts/tests/task-runtime-stress-test.server.luau
```

Both tests must pass with the exact module being released.

## 4. Tag the release

```text
git tag -a v3.0.3 -m "TaskRuntime 3.0.3"
git push origin v3.0.3
```

Replace `3.0.3` with the version in `VERSION`.

## 5. Verify the GitHub release

Pushing the tag starts `.github/workflows/release.yml`. The workflow validates the tag, builds the distributable archive, creates checksums, and publishes a GitHub release.

Verify that the release contains:

- `TaskRuntime.luau`
- `TaskRuntimeTypes.luau`
- `taskruntime-<version>.zip`
- `SHA256SUMS.txt`

## 6. Post-release check

Download the release archive, sync its module into a clean Creator project, and run the integration self-test once more.
