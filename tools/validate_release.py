from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_FILES = (
    "VERSION",
    "README.md",
    "LICENSE",
    "AI_DISCLOSURE.md",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "CODE_OF_CONDUCT.md",
    "RELEASING.md",
    "scripts/modules/TaskRuntime.luau",
    "scripts/modules/TaskRuntimePolytoriaSafe.luau",
    "scripts/modules/TaskRuntimeTypes.luau",
    "scripts/tests/task-runtime-test.server.luau",
    "scripts/tests/task-runtime-stress-test.server.luau",
    "scripts/tests/task-runtime-polytoria-safe-test.server.luau",
    "docs/task-runtime.md",
    "docs/task-runtime-examples.md",
    "docs/polytoria-safe-callbacks.md",
    ".github/workflows/validate.yml",
    ".github/workflows/release.yml",
)


def fail(message: str) -> None:
    print(f"release validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing required file: {relative}")
    return path.read_text(encoding="utf-8")


def main() -> None:
    for relative in REQUIRED_FILES:
        if not (ROOT / relative).is_file():
            fail(f"missing required file: {relative}")

    version = read("VERSION").strip()
    if re.fullmatch(r"\d+\.\d+\.\d+", version) is None:
        fail(f"VERSION is not semantic version text: {version!r}")

    module = read("scripts/modules/TaskRuntime.luau")
    match = re.search(r'TaskRuntime\.VERSION\s*=\s*"([^"]+)"', module)
    if match is None:
        fail("TaskRuntime.VERSION was not found")
    if match.group(1) != version:
        fail(
            "module version does not match VERSION "
            f"({match.group(1)!r} != {version!r})"
        )

    adapter = read("scripts/modules/TaskRuntimePolytoriaSafe.luau")
    if "TaskRuntime.SUPPORTS_POLYTORIA_SAFE_CALLBACKS = true" not in adapter:
        fail("Polytoria-safe adapter feature flag is missing")
    if "function TaskRuntime.createPolytoriaSafe" not in adapter:
        fail("Polytoria-safe runtime constructor is missing")
    if 'callbackMode ~= "protected" and callbackMode ~= "direct"' not in adapter:
        fail("Polytoria-safe callback mode validation is missing")

    readme = read("README.md")
    docs = read("docs/task-runtime.md")
    safe_docs = read("docs/polytoria-safe-callbacks.md")
    changelog = read("CHANGELOG.md")
    disclosure = read("AI_DISCLOSURE.md")
    if f"Current release: {version}" not in readme:
        fail("README current release does not match VERSION")
    if f"```text\n{version}\n```" not in docs:
        fail("documentation current version does not match VERSION")
    if f"## [{version}]" not in changelog:
        fail("CHANGELOG has no section for VERSION")
    if "createPolytoriaSafe" not in readme or "createPolytoriaSafe" not in safe_docs:
        fail("Polytoria-safe adapter documentation is incomplete")
    if "[AI assistance disclosure](AI_DISCLOSURE.md)" not in readme:
        fail("README does not link to AI_DISCLOSURE.md")
    if "generative AI" not in disclosure or "project maintainer" not in disclosure:
        fail("AI disclosure is incomplete")

    self_test = read("scripts/tests/task-runtime-test.server.luau")
    stress_test = read("scripts/tests/task-runtime-stress-test.server.luau")
    safe_test = read("scripts/tests/task-runtime-polytoria-safe-test.server.luau")
    if "TaskRuntime self-test passed" not in self_test:
        fail("integration self-test success marker is missing")
    if "TaskRuntime stress test passed" not in stress_test:
        fail("stress-test success marker is missing")
    if "TaskRuntime Polytoria-safe adapter test passed" not in safe_test:
        fail("Polytoria-safe adapter test success marker is missing")

    banned = "industry" + "-grade"
    for path in ROOT.rglob("*"):
        if not path.is_file() or ".git" in path.parts or "dist" in path.parts:
            continue
        if path.suffix.lower() not in {".md", ".luau", ".yml", ".yaml"}:
            continue
        text = path.read_text(encoding="utf-8")
        if banned in text.lower():
            fail(f"promotional wording found in {path.relative_to(ROOT)}")

    workflows = ROOT / ".github" / "workflows"
    for path in workflows.glob("*.yml"):
        lowered = path.name.lower()
        if "prepare-taskruntime" in lowered or "fix-taskruntime" in lowered:
            fail(f"one-time workflow was not removed: {path.name}")
        if "apply-3-0-4" in lowered:
            fail(f"stalled migration workflow was not removed: {path.name}")

    if (ROOT / "tools" / "apply_3_0_4.py").exists():
        fail("stalled 3.0.4 migration script was not removed")

    ref_type = os.environ.get("GITHUB_REF_TYPE")
    ref_name = os.environ.get("GITHUB_REF_NAME")
    if ref_type == "tag" and ref_name != f"v{version}":
        fail(f"release tag {ref_name!r} must match VERSION as v{version}")

    newline_files = set(REQUIRED_FILES) | {
        ".editorconfig",
        ".gitignore",
        ".github/CODEOWNERS",
        ".github/PULL_REQUEST_TEMPLATE.md",
        ".github/ISSUE_TEMPLATE/bug_report.yml",
        ".github/ISSUE_TEMPLATE/feature_request.yml",
        ".github/ISSUE_TEMPLATE/config.yml",
        "tools/validate_release.py",
        "tools/build_release.py",
    }
    for relative in sorted(newline_files):
        path = ROOT / relative
        data = path.read_bytes()
        if data and not data.endswith(b"\n"):
            fail(f"missing final newline: {relative}")

    print(f"release validation passed for TaskRuntime {version}")


if __name__ == "__main__":
    main()
