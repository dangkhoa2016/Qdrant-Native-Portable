#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

VALID_SUITE_STATUSES = {"READY", "PROVISIONAL"}


def metadata(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line or line.lstrip().startswith("#"):
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def report_status(path: Path) -> str:
    if not path.is_file():
        return "MISSING"
    try:
        raw = json.loads(path.read_text())
    except Exception:
        return "UNKNOWN"
    value = str(raw.get("suite_status", "UNKNOWN")).upper()
    return value if value in VALID_SUITE_STATUSES else "UNKNOWN"


def overall_status(quick: str, full: str, full_requested: bool) -> str:
    statuses = [quick] + ([full] if full_requested else [])
    for state in ("SKIPPED_MEMORY", "MISSING", "UNKNOWN"):
        if state in statuses:
            return state
    if "PROVISIONAL" in statuses:
        return "PROVISIONAL"
    if statuses and all(x == "READY" for x in statuses):
        return "READY"
    return "UNKNOWN"


def source_info(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {
            "integrity_status": "NO_MANIFEST",
            "canonical_sha256": None,
            "working_tree_sha256": None,
        }
    try:
        raw = json.loads(path.read_text())
    except Exception:
        return {
            "integrity_status": "NO_MANIFEST",
            "canonical_sha256": None,
            "working_tree_sha256": None,
        }
    return raw


def bool_meta(value: str | None) -> bool | None:
    if value == "1":
        return True
    if value == "0":
        return False
    return None


def baseline_info(meta: dict[str, str]) -> tuple[bool | None, str | None]:
    """Return semantic baseline freshness, with fail-closed provenance validation.

    New-format metadata must pair `fresh_baseline=1` with a recognized origin.
    Old artifacts that only contain `clean_reinstall` remain supported.
    """
    fresh_raw = meta.get("fresh_baseline")
    clean = bool_meta(meta.get("clean_reinstall"))
    origin = meta.get("baseline_origin") or None

    if fresh_raw in {"0", "1"}:
        fresh = bool_meta(fresh_raw)
        if fresh is True:
            if origin not in {"purge-all-test", "clean-reinstall"}:
                return None, origin
            return True, origin
        if origin not in {None, "existing-runtime"}:
            return None, origin
        return False, origin or "existing-runtime"

    if clean is True:
        return True, "clean-reinstall"
    if clean is False:
        return False, "existing-runtime"
    return None, origin


def comparability(source_integrity: str, fresh_baseline: bool | None) -> str:
    if source_integrity == "DIRTY":
        return "DIRTY_SOURCE"
    if source_integrity != "CLEAN":
        return "SOURCE_UNVERIFIED"
    if fresh_baseline is True:
        return "CLEAN_BASELINE"
    if fresh_baseline is False:
        return "EXISTING_RUNTIME"
    return "UNVERIFIED"


def build(run_dir: Path) -> dict[str, Any]:
    meta = metadata(run_dir / "run-metadata.txt")
    full_requested = meta.get("full_suite", "1") == "1"
    quick = report_status(run_dir / "quick-suite" / "benchmark-report.json")
    if not full_requested:
        full = "NOT_REQUESTED"
    elif not (run_dir / "full-suite" / "benchmark-report.json").is_file() and meta.get("full_suite_skipped_reason") == "memory-safety":
        full = "SKIPPED_MEMORY"
    else:
        full = report_status(run_dir / "full-suite" / "benchmark-report.json")
    overall = overall_status(quick, full, full_requested)
    source = source_info(run_dir / "source-integrity.json")
    source_status = str(source.get("integrity_status", "NO_MANIFEST"))
    clean_reinstall = bool_meta(meta.get("clean_reinstall"))
    fresh_baseline, baseline_origin = baseline_info(meta)
    comp = comparability(source_status, fresh_baseline)
    return {
        "schema_version": 3,
        "run_dir": str(run_dir),
        "quick_status": quick,
        "full_status": full,
        "full_requested": full_requested,
        "overall_status": overall,
        "source_integrity": source_status,
        "canonical_source_sha256": source.get("canonical_sha256"),
        "working_tree_sha256": source.get("working_tree_sha256") or source.get("sha256"),
        "clean_reinstall": clean_reinstall,
        "fresh_baseline": fresh_baseline,
        "baseline_origin": baseline_origin,
        "comparability": comp,
        "ready_for_ranking": overall == "READY" and comp == "CLEAN_BASELINE",
    }


def md(x: dict[str, Any]) -> str:
    return "\n".join([
        "# Benchmark status",
        "",
        f"- Overall status: **{x['overall_status']}**",
        f"- Quick suite: `{x['quick_status']}`",
        f"- Full suite: `{x['full_status']}`",
        f"- Source integrity: `{x['source_integrity']}`",
        f"- Smart-wrapper clean reinstall: `{x['clean_reinstall']}`",
        f"- Fresh baseline: `{x['fresh_baseline']}`",
        f"- Baseline origin: `{x['baseline_origin']}`",
        f"- Comparability: **{x['comparability']}**",
        f"- Ready for comparable ranking: `{str(x['ready_for_ranking']).lower()}`",
        "",
    ])


def main() -> int:
    p = argparse.ArgumentParser(description="Classify Qdrant benchmark readiness and comparability")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--json-output")
    p.add_argument("--markdown-output")
    p.add_argument("--require-ready", action="store_true")
    p.add_argument("--require-clean-baseline", action="store_true")
    a = p.parse_args()
    run_dir = Path(a.run_dir).resolve()
    if not run_dir.is_dir():
        p.error(f"run directory does not exist: {run_dir}")
    result = build(run_dir)
    text = json.dumps(result, indent=2) + "\n"
    if a.json_output:
        Path(a.json_output).write_text(text)
    else:
        print(text, end="")
    if a.markdown_output:
        Path(a.markdown_output).write_text(md(result))

    if a.require_ready:
        if result["overall_status"] == "PROVISIONAL":
            return 2
        if result["overall_status"] != "READY":
            return 3
    if a.require_clean_baseline and result["comparability"] != "CLEAN_BASELINE":
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
