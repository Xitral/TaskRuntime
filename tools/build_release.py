from __future__ import annotations

import hashlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def add_to_zip(
    archive: zipfile.ZipFile,
    source: Path,
    archive_name: str,
) -> None:
    info = zipfile.ZipInfo(archive_name, date_time=(2026, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    archive.writestr(info, source.read_bytes())


def main() -> None:
    subprocess.run(
        [sys.executable, str(ROOT / "tools" / "validate_release.py")],
        cwd=ROOT,
        check=True,
    )

    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)

    runtime_asset = DIST / "TaskRuntime.luau"
    types_asset = DIST / "TaskRuntimeTypes.luau"
    shutil.copy2(ROOT / "scripts/modules/TaskRuntime.luau", runtime_asset)
    shutil.copy2(ROOT / "scripts/modules/TaskRuntimeTypes.luau", types_asset)

    archive_path = DIST / f"taskruntime-{version}.zip"
    package_root = f"TaskRuntime-{version}"
    package_files = (
        ("README.md", "README.md"),
        ("LICENSE", "LICENSE"),
        ("AI_DISCLOSURE.md", "AI_DISCLOSURE.md"),
        ("CHANGELOG.md", "CHANGELOG.md"),
        ("scripts/modules/TaskRuntime.luau", "TaskRuntime.luau"),
        ("scripts/modules/TaskRuntimeTypes.luau", "TaskRuntimeTypes.luau"),
        ("docs/task-runtime.md", "docs/task-runtime.md"),
        ("docs/task-runtime-examples.md", "docs/task-runtime-examples.md"),
    )

    with zipfile.ZipFile(archive_path, "w") as archive:
        for source_name, destination_name in package_files:
            add_to_zip(
                archive,
                ROOT / source_name,
                f"{package_root}/{destination_name}",
            )

    checksum_targets = (runtime_asset, types_asset, archive_path)
    checksums = DIST / "SHA256SUMS.txt"
    checksums.write_text(
        "".join(
            f"{sha256(path)}  {path.name}\n"
            for path in checksum_targets
        ),
        encoding="utf-8",
        newline="\n",
    )

    with zipfile.ZipFile(archive_path, "r") as archive:
        bad_file = archive.testzip()
        if bad_file is not None:
            raise RuntimeError(f"corrupt release archive entry: {bad_file}")

    print(f"built TaskRuntime {version} release assets in {DIST}")


if __name__ == "__main__":
    main()
