#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
from typing import Any, Iterable

SCOPE = "project-source-v2"
MANIFEST_NAME = "SOURCE-MANIFEST.json"
IGNORED_DIR_NAMES = {
    ".git", "__pycache__", "node_modules", ".venv", "tokens",
    ".pytest_cache", ".mypy_cache", ".ruff_cache",
}
IGNORED_FILE_NAMES = {
    MANIFEST_NAME,
    ".qdrant-base",
    ".qdrant-initialized",
    ".qdrant-native-portable-instance",
    "runtime.env",
    "secrets.env",
}
IGNORED_SUFFIXES = (
    ".pyc", ".pyo", ".log", ".snapshot", ".snapshot.sha256",
)
# Benchmark/result archives are reproducible runtime output, not public source.
# Keep this list deliberately narrow so arbitrary ZIPs or SHA files still dirty
# the canonical source tree and therefore remain auditable.
GENERATED_ARTIFACT_PATTERNS = (
    "qdrant-benchmarks-*.zip",
    "qdrant-benchmarks-*.zip.sha256",
    "profile-ab-*.zip",
    "profile-ab-*.zip.sha256",
)

# Source files that existed in older private revisions but are intentionally
# absent from the current canonical public tree. These are the ONLY source
# paths that the fresh benchmark entrypoint may auto-remove after detecting
# an unzip/copy overlay. Each entry maps a relative path to its expected
# SHA256 hash; an empty string means the hash is unknown and repair is
# REFUSED (fail-closed).
LEGACY_STALE_SOURCE_FILES: dict[str, str] = {
    "docs/PROFILE-BENCHMARKS.md": "",
    "docs/PROFILE-BENCHMARKS.vi.md": "",
    "docs/SOURCE-INTEGRITY.md": "",
    "docs/SOURCE-INTEGRITY.vi.md": "",
    "scripts/resource-monitor.py": "",
    "scripts/source-fingerprint.py": "",
}


def generated_artifact_relative_path(rel: Path) -> bool:
    name = rel.name
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in GENERATED_ARTIFACT_PATTERNS)


def ignored_relative_path(rel: Path) -> bool:
    if any(part in IGNORED_DIR_NAMES for part in rel.parts[:-1]):
        return True
    # Only ignore root-level temp/ directory, not nested ones.
    if len(rel.parts) > 1 and rel.parts[0] == "temp":
        return True
    name = rel.name
    if name in IGNORED_FILE_NAMES:
        return True
    return name.endswith(IGNORED_SUFFIXES)


def iter_source_files(root: Path) -> Iterable[Path]:
    root = root.resolve()
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        base = Path(dirpath)

        retained_dirs: list[str] = []
        symlink_dirs: list[str] = []

        for name in sorted(dirnames):
            path = base / name

            if name in IGNORED_DIR_NAMES:
                continue
            if base == root and name == "temp":
                continue

            if path.is_symlink():
                symlink_dirs.append(name)
            else:
                retained_dirs.append(name)

        dirnames[:] = retained_dirs

        for name in symlink_dirs:
            path = base / name
            rel = path.relative_to(root)
            if generated_artifact_relative_path(rel) or ignored_relative_path(rel):
                continue
            yield path

        for name in sorted(filenames):
            path = base / name
            rel = path.relative_to(root)
            if generated_artifact_relative_path(rel) or ignored_relative_path(rel):
                continue
            if path.is_symlink() or path.is_file():
                yield path


def file_digest(path: Path) -> str:
    h = hashlib.sha256()
    if path.is_symlink():
        h.update(os.readlink(path).encode("utf-8", errors="surrogateescape"))
        return h.hexdigest()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def file_record(root: Path, path: Path) -> dict[str, Any]:
    rel = path.relative_to(root).as_posix()
    if path.is_symlink():
        size = len(os.readlink(path).encode("utf-8", errors="surrogateescape"))
        kind = "symlink"
    else:
        size = path.stat().st_size
        kind = "file"
    return {"path": rel, "sha256": file_digest(path), "size": size, "kind": kind}


def records_for_root(root: Path) -> list[dict[str, Any]]:
    root = root.resolve()
    return [file_record(root, p) for p in iter_source_files(root)]


def ignored_generated_files(root: Path) -> list[str]:
    root = root.resolve()
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in IGNORED_DIR_NAMES)
        base = Path(dirpath)
        for name in sorted(filenames):
            path = base / name
            rel = path.relative_to(root)
            if generated_artifact_relative_path(rel):
                found.append(rel.as_posix())
    return sorted(found)


def fingerprint(records: Iterable[dict[str, Any]]) -> str:
    h = hashlib.sha256()
    for record in sorted(records, key=lambda x: x["path"]):
        h.update(record["path"].encode("utf-8"))
        h.update(b"\0")
        h.update(record["sha256"].encode("ascii"))
        h.update(b"\0")
        h.update(str(record.get("size", "")).encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()


_SHA256_RE = __import__("re").compile(r"^[0-9a-f]{64}$")


def validate_manifest(manifest: Any) -> list[str]:
    """Validate manifest schema and invariants. Returns list of errors (empty = valid)."""
    errors: list[str] = []

    if not isinstance(manifest, dict):
        return ["manifest is not a JSON object"]

    # Top-level invariants.
    if manifest.get("schema_version") != 2:
        errors.append(f"schema_version is not 2 (got {manifest.get('schema_version')!r})")
    if manifest.get("scope") != SCOPE:
        errors.append(f"scope is not {SCOPE!r} (got {manifest.get('scope')!r})")

    root_name = manifest.get("root_name")
    if not isinstance(root_name, str) or not root_name:
        errors.append(f"root_name must be a non-empty string (got {root_name!r})")

    if not isinstance(manifest.get("canonical_file_count"), int) or isinstance(manifest.get("canonical_file_count"), bool):
        errors.append(f"canonical_file_count must be an integer (got {manifest.get('canonical_file_count')!r})")

    canonical_sha256 = manifest.get("canonical_sha256")
    if not isinstance(canonical_sha256, str) or not _SHA256_RE.match(canonical_sha256):
        errors.append(f"canonical_sha256 is not a valid SHA256 hex digest (got {canonical_sha256!r})")

    # files list invariant.
    files = manifest.get("files")
    if not isinstance(files, list):
        errors.append(f"files must be a list (got {type(files).__name__})")
        return errors  # cannot validate records without a list

    if not errors:
        # Only check count match when the count is a valid integer.
        count_val = manifest.get("canonical_file_count")
        if isinstance(count_val, int) and not isinstance(count_val, bool) and count_val != len(files):
            errors.append(f"canonical_file_count ({count_val}) != len(files) ({len(files)})")

    # Record-level invariants.
    seen_paths: set[str] = set()
    for i, record in enumerate(files):
        prefix = f"files[{i}]"
        if not isinstance(record, dict):
            errors.append(f"{prefix} is not an object")
            continue

        # path
        path = record.get("path")
        if not isinstance(path, str) or not path:
            errors.append(f"{prefix}: path must be a non-empty string (got {path!r})")
        else:
            if path.startswith("/"):
                errors.append(f"{prefix}: path must not be absolute: {path}")
            parts = path.split("/")
            if "." in parts or ".." in parts:
                errors.append(f"{prefix}: path contains unsafe traversal component: {path}")
            if path in seen_paths:
                errors.append(f"{prefix}: duplicate path: {path}")
            seen_paths.add(path)

        # sha256
        sha = record.get("sha256")
        if not isinstance(sha, str) or not _SHA256_RE.match(sha):
            errors.append(f"{prefix}: sha256 is not a valid 64-char hex digest (got {sha!r})")

        # size
        size = record.get("size")
        if not isinstance(size, int) or isinstance(size, bool):
            errors.append(f"{prefix}: size must be a non-negative integer (got {size!r})")
        elif size < 0:
            errors.append(f"{prefix}: size must not be negative ({size})")

        # kind
        kind = record.get("kind")
        if kind not in ("file", "symlink"):
            errors.append(f"{prefix}: kind must be 'file' or 'symlink' (got {kind!r})")

    # Aggregate fingerprint invariant.
    if not errors and isinstance(canonical_sha256, str) and _SHA256_RE.match(canonical_sha256):
        computed = fingerprint(files)
        if canonical_sha256 != computed:
            errors.append(f"canonical_sha256 does not match computed fingerprint")

    return errors


def build_manifest(root: Path) -> dict[str, Any]:
    records = records_for_root(root)
    digest = fingerprint(records)
    return {
        "schema_version": 2,
        "scope": SCOPE,
        "root_name": root.resolve().name,
        "canonical_sha256": digest,
        "canonical_file_count": len(records),
        "files": records,
    }


def write_json(path: Path | None, value: dict[str, Any]) -> None:
    text = json.dumps(value, indent=2, sort_keys=False) + "\n"
    if path is None:
        print(text, end="")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def check_root(root: Path, manifest_path: Path) -> dict[str, Any]:
    root = root.resolve()
    working_records = records_for_root(root)
    ignored_generated = ignored_generated_files(root)
    working_by_path = {x["path"]: x for x in working_records}
    working_digest = fingerprint(working_records)

    if not manifest_path.is_file():
        return {
            "schema_version": 2,
            "scope": SCOPE,
            "root_name": root.name,
            "canonical_manifest": str(manifest_path),
            "canonical_manifest_present": False,
            "integrity_status": "NO_MANIFEST",
            "sha256": working_digest,
            "working_tree_sha256": working_digest,
            "working_file_count": len(working_records),
            "canonical_sha256": None,
            "canonical_file_count": None,
            "modified_files": [],
            "missing_files": [],
            "unexpected_files": [],
            "repairable_overlay_files": [],
            "unknown_unexpected_files": [],
            "ignored_generated_files": ignored_generated,
        }

    try:
        manifest = json.loads(manifest_path.read_text())
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        return {
            "schema_version": 2,
            "scope": SCOPE,
            "root_name": root.name,
            "canonical_manifest": str(manifest_path),
            "canonical_manifest_present": True,
            "integrity_status": "INVALID_MANIFEST",
            "sha256": working_digest,
            "working_tree_sha256": working_digest,
            "working_file_count": len(working_records),
            "canonical_sha256": None,
            "canonical_file_count": None,
            "modified_files": [],
            "missing_files": [],
            "unexpected_files": [],
            "repairable_overlay_files": [],
            "unknown_unexpected_files": [],
            "ignored_generated_files": ignored_generated,
            "manifest_errors": [f"manifest is not valid JSON: {exc}"],
        }
    manifest_errors = validate_manifest(manifest)
    if manifest_errors:
        return {
            "schema_version": 2,
            "scope": manifest.get("scope", SCOPE) if isinstance(manifest, dict) else SCOPE,
            "root_name": root.name,
            "canonical_manifest": str(manifest_path),
            "canonical_manifest_present": True,
            "integrity_status": "INVALID_MANIFEST",
            "sha256": working_digest,
            "working_tree_sha256": working_digest,
            "working_file_count": len(working_records),
            "canonical_sha256": manifest.get("canonical_sha256") if isinstance(manifest, dict) else None,
            "canonical_file_count": manifest.get("canonical_file_count") if isinstance(manifest, dict) else None,
            "modified_files": [],
            "missing_files": [],
            "unexpected_files": [],
            "repairable_overlay_files": [],
            "unknown_unexpected_files": [],
            "ignored_generated_files": ignored_generated,
            "manifest_errors": manifest_errors,
        }

    canonical_records = manifest.get("files") or []
    canonical_by_path = {x["path"]: x for x in canonical_records}
    modified = sorted(
        path for path in (canonical_by_path.keys() & working_by_path.keys())
        if canonical_by_path[path].get("sha256") != working_by_path[path].get("sha256")
        or canonical_by_path[path].get("size") != working_by_path[path].get("size")
        or canonical_by_path[path].get("kind", "file") != working_by_path[path].get("kind", "file")
    )
    missing = sorted(canonical_by_path.keys() - working_by_path.keys())
    unexpected = sorted(working_by_path.keys() - canonical_by_path.keys())
    repairable_overlay = sorted(path for path in unexpected if path in LEGACY_STALE_SOURCE_FILES)
    unknown_unexpected = sorted(path for path in unexpected if path not in LEGACY_STALE_SOURCE_FILES)
    canonical_digest = manifest.get("canonical_sha256")
    clean = not modified and not missing and not unexpected and working_digest == canonical_digest
    return {
        "schema_version": 2,
        "scope": manifest.get("scope", SCOPE),
        "root_name": root.name,
        "canonical_manifest": str(manifest_path),
        "canonical_manifest_present": True,
        "integrity_status": "CLEAN" if clean else "DIRTY",
        # `sha256` remains an easy compatibility alias for the current tree.
        "sha256": working_digest,
        "working_tree_sha256": working_digest,
        "working_file_count": len(working_records),
        "canonical_sha256": canonical_digest,
        "canonical_file_count": int(manifest.get("canonical_file_count", len(canonical_records))),
        "modified_files": modified,
        "missing_files": missing,
        "unexpected_files": unexpected,
        "repairable_overlay_files": repairable_overlay,
        "unknown_unexpected_files": unknown_unexpected,
        "ignored_generated_files": ignored_generated,
    }


def repair_overlay(root: Path, manifest_path: Path, apply: bool) -> tuple[dict[str, Any], int]:
    """Plan or apply a narrow repair for known private-revision overlay files.

    Refuse if canonical files are modified/missing or if ANY unexpected path is
    outside LEGACY_STALE_SOURCE_FILES. Refuse if any allowlisted file has an
    unknown SHA256 (empty string). This function never removes directories and
    never follows symlinks; allowlisted file/symlink entries are unlinked only
    after SHA256 verification.
    """
    root = root.resolve()
    pre = check_root(root, manifest_path)
    base: dict[str, Any] = {
        "schema_version": 1,
        "root_name": root.name,
        "canonical_manifest": str(manifest_path),
        "apply": bool(apply),
        "repair_status": "REFUSED",
        "reason": None,
        "planned_files": list(pre.get("repairable_overlay_files", [])),
        "repaired_files": [],
        "unknown_unexpected_files": list(pre.get("unknown_unexpected_files", [])),
        "pre_check": pre,
        "post_check": pre,
    }

    if pre.get("integrity_status") == "NO_MANIFEST":
        base["reason"] = "canonical manifest is missing"
        return base, 3
    if pre.get("integrity_status") == "INVALID_MANIFEST":
        base["reason"] = f"canonical manifest is invalid: {'; '.join(pre.get('manifest_errors', []))}"
        return base, 4
    if pre.get("integrity_status") == "CLEAN":
        base["repair_status"] = "NO_ACTION"
        base["reason"] = "source is already CLEAN"
        return base, 0
    if pre.get("modified_files"):
        base["reason"] = "canonical source files are modified"
        return base, 2
    if pre.get("missing_files"):
        base["reason"] = "canonical source files are missing"
        return base, 2
    if pre.get("unknown_unexpected_files"):
        base["reason"] = "unknown unexpected source files are present"
        return base, 2

    planned = list(pre.get("repairable_overlay_files", []))
    if not planned:
        base["reason"] = "DIRTY source is not a recognized legacy overlay"
        return base, 2

    # Validate the whole repair set before deleting the first entry.
    for rel in planned:
        if rel not in LEGACY_STALE_SOURCE_FILES:
            base["reason"] = f"path is not allowlisted for overlay repair: {rel}"
            return base, 2
        expected_hash = LEGACY_STALE_SOURCE_FILES[rel]
        if not expected_hash:
            base["reason"] = f"SHA256 hash unknown for overlay repair candidate: {rel}"
            return base, 2
        candidate = root / rel
        if not (candidate.is_symlink() or candidate.is_file()):
            base["reason"] = f"repair candidate is not a regular file/symlink: {rel}"
            return base, 2
        if file_digest(candidate) != expected_hash:
            base["reason"] = f"SHA256 mismatch for overlay repair candidate: {rel}"
            return base, 2

    if not apply:
        base["repair_status"] = "PLANNED"
        base["reason"] = "known legacy overlay can be repaired safely"
        return base, 0

    repaired: list[str] = []
    for rel in planned:
        (root / rel).unlink()
        repaired.append(rel)
    post = check_root(root, manifest_path)
    base["repaired_files"] = repaired
    base["post_check"] = post
    if post.get("integrity_status") != "CLEAN":
        base["repair_status"] = "FAILED"
        base["reason"] = "overlay files were removed but source is still not CLEAN"
        return base, 2
    base["repair_status"] = "REPAIRED"
    base["reason"] = "known legacy overlay removed and canonical source restored"
    return base, 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Canonical Qdrant Native Portable source manifest/integrity helper")
    sub = p.add_subparsers(dest="command", required=True)

    pm = sub.add_parser("manifest", help="Generate canonical source manifest")
    pm.add_argument("--root", required=True)
    pm.add_argument("--output", required=True)

    pc = sub.add_parser("check", help="Compare working source with canonical manifest")
    pc.add_argument("--root", required=True)
    pc.add_argument("--manifest")
    pc.add_argument("--json-output")
    pc.add_argument("--require-clean", action="store_true")

    pr = sub.add_parser("repair-overlay", help="Plan/apply removal of known stale private-revision overlay files")
    pr.add_argument("--root", required=True)
    pr.add_argument("--manifest")
    pr.add_argument("--json-output")
    pr.add_argument("--apply", action="store_true", help="Actually unlink the allowlisted stale files")
    return p


def main() -> int:
    args = parser().parse_args()
    root = Path(args.root).resolve()
    if not root.is_dir():
        raise SystemExit(f"source root is not a directory: {root}")

    if args.command == "manifest":
        output = Path(args.output).resolve()
        value = build_manifest(root)
        write_json(output, value)
        print(value["canonical_sha256"])
        return 0

    manifest_path = Path(args.manifest).resolve() if args.manifest else root / MANIFEST_NAME
    if args.command == "repair-overlay":
        value, rc = repair_overlay(root, manifest_path, bool(args.apply))
        output = Path(args.json_output).resolve() if args.json_output else None
        write_json(output, value)
        return rc

    value = check_root(root, manifest_path)
    output = Path(args.json_output).resolve() if args.json_output else None
    write_json(output, value)
    if args.require_clean and value["integrity_status"] != "CLEAN":
        if value["integrity_status"] == "INVALID_MANIFEST":
            return 4
        return 2 if value["integrity_status"] == "DIRTY" else 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
