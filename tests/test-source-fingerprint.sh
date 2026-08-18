#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/qdrant-native-portable-v1.0.0"
mkdir -p "$fixture/scripts" "$fixture/docs"
printf '1.0.0\n' > "$fixture/VERSION"
printf 'alpha\n' > "$fixture/scripts/a.sh"
printf 'docs\n' > "$fixture/docs/readme.md"

python3 "$PROJECT_DIR/scripts/source-integrity.py" manifest \
  --root "$fixture" --output "$fixture/SOURCE-MANIFEST.json"
python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$fixture" --json-output "$tmp/clean.json" --require-clean
python3 - "$tmp/clean.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['scope']=='project-source-v2'
assert x['integrity_status']=='CLEAN'
assert x['canonical_file_count']==3
assert x['working_file_count']==3
assert x['modified_files']==[]
assert x['missing_files']==[]
assert x['unexpected_files']==[]
assert x['canonical_sha256']==x['working_tree_sha256']==x['sha256']
PY

# Known generated/runtime files must not dirty canonical source provenance.
printf '/tmp/runtime\n' > "$fixture/.qdrant-base"
mkdir -p "$fixture/__pycache__"
printf 'cache' > "$fixture/__pycache__/x.pyc"
printf 'log' > "$fixture/local.log"
printf 'zip' > "$fixture/qdrant-benchmarks-codesandbox-4101mb-20260814T024835Z.zip"
printf 'sha' > "$fixture/qdrant-benchmarks-codesandbox-4101mb-20260814T024835Z.zip.sha256"
printf 'ab' > "$fixture/profile-ab-100000p-768d-20260814T072322Z-codesandbox-4101mb.zip"
printf 'ab-sha' > "$fixture/profile-ab-100000p-768d-20260814T072322Z-codesandbox-4101mb.zip.sha256"
python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$fixture" --json-output "$tmp/generated.json" --require-clean
python3 - "$tmp/generated.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status']=='CLEAN'
assert x['unexpected_files']==[]
assert x['working_file_count']==3
assert x['ignored_generated_files']==[
    'profile-ab-100000p-768d-20260814T072322Z-codesandbox-4101mb.zip',
    'profile-ab-100000p-768d-20260814T072322Z-codesandbox-4101mb.zip.sha256',
    'qdrant-benchmarks-codesandbox-4101mb-20260814T024835Z.zip',
    'qdrant-benchmarks-codesandbox-4101mb-20260814T024835Z.zip.sha256',
]
PY

# Only known benchmark result names are ignored; an arbitrary archive remains source.
printf 'arbitrary' > "$fixture/manual-source-bundle.zip"
if python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$fixture" --json-output "$tmp/arbitrary-zip.json" --require-clean; then
  echo 'FAIL: arbitrary ZIP was incorrectly ignored' >&2
  exit 1
fi
python3 - "$tmp/arbitrary-zip.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status']=='DIRTY'
assert x['unexpected_files']==['manual-source-bundle.zip']
PY
rm "$fixture/manual-source-bundle.zip"

# A real source modification must be reported precisely.
printf 'changed\n' > "$fixture/scripts/a.sh"
if python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$fixture" --json-output "$tmp/dirty.json" --require-clean; then
  echo 'FAIL: dirty source passed --require-clean' >&2
  exit 1
fi
python3 - "$tmp/dirty.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status']=='DIRTY'
assert x['modified_files']==['scripts/a.sh']
PY

# Missing and unexpected public files are also explicit.
printf 'alpha\n' > "$fixture/scripts/a.sh"
rm "$fixture/docs/readme.md"
printf 'new\n' > "$fixture/docs/new.md"
python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$fixture" --json-output "$tmp/diff.json" || true
python3 - "$tmp/diff.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status']=='DIRTY'
assert x['missing_files']==['docs/readme.md']
assert x['unexpected_files']==['docs/new.md']
PY

# --- temp/ directory semantics regression tests ---

# Restore fixture to canonical state for temp tests.
printf 'alpha\n' > "$fixture/scripts/a.sh"
printf 'docs\n' > "$fixture/docs/readme.md"
rm -f "$fixture/docs/new.md"
python3 "$PROJECT_DIR/scripts/source-integrity.py" manifest \
  --root "$fixture" --output "$fixture/SOURCE-MANIFEST.json"

# Case A: root-level temp/ must be ignored (not part of canonical source).
mkdir -p "$fixture/temp"
printf 'runtime\n' > "$fixture/temp/runtime-output.txt"
python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$fixture" --json-output "$tmp/root-temp.json" --require-clean
python3 - "$tmp/root-temp.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status']=='CLEAN', f"root temp/ should be ignored, got {x['integrity_status']}"
assert x['unexpected_files']==[], f"root temp/ file unexpectedly visible: {x['unexpected_files']}"
PY
rm -rf "$fixture/temp"

# Case B: nested temp/ is canonical source and must be tracked.
mkdir -p "$fixture/docs/temp"
printf 'nested source\n' > "$fixture/docs/temp/spec.md"
python3 "$PROJECT_DIR/scripts/source-integrity.py" manifest \
  --root "$fixture" --output "$fixture/SOURCE-MANIFEST.json"
python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$fixture" --json-output "$tmp/nested-temp-manifest.json" --require-clean
python3 - "$tmp/nested-temp-manifest.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status']=='CLEAN'
assert 'docs/temp/spec.md' in [f['path'] for f in x.get('files', [])] or x['working_file_count'] >= 4
PY
# Modify the nested temp source; check must report it as modified.
printf 'modified\n' > "$fixture/docs/temp/spec.md"
if python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$fixture" --json-output "$tmp/nested-temp-dirty.json" --require-clean; then
  echo 'FAIL: modified nested temp/ source was not detected' >&2
  exit 1
fi
python3 - "$tmp/nested-temp-dirty.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status']=='DIRTY'
assert 'docs/temp/spec.md' in x['modified_files'], f"expected docs/temp/spec.md in modified_files, got {x['modified_files']}"
PY
# Restore and remove fixture nested temp.
printf 'nested source\n' > "$fixture/docs/temp/spec.md"
rm -rf "$fixture/docs/temp"

# Case C: unexpected nested temp source must dirty tree.
python3 "$PROJECT_DIR/scripts/source-integrity.py" manifest \
  --root "$fixture" --output "$fixture/SOURCE-MANIFEST.json"
mkdir -p "$fixture/scripts/temp"
printf 'new helper\n' > "$fixture/scripts/temp/helper.py"
if python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$fixture" --json-output "$tmp/unexpected-nested-temp.json" --require-clean; then
  echo 'FAIL: unexpected nested temp/ source was not detected' >&2
  exit 1
fi
python3 - "$tmp/unexpected-nested-temp.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status']=='DIRTY'
assert 'scripts/temp/helper.py' in x['unexpected_files'], f"expected scripts/temp/helper.py in unexpected_files, got {x['unexpected_files']}"
PY
rm -rf "$fixture/scripts/temp"

echo 'source fingerprint tests passed'

# A private-revision overlay containing only known stale source paths must be
# classifiable but repair must be REFUSED when SHA256 hashes are unknown.
overlay="$tmp/overlay"
cp -a "$fixture" "$overlay"
# Restore fixture to canonical content before overlay test.
printf 'docs\n' > "$overlay/docs/readme.md"
rm -f "$overlay/docs/new.md"
printf 'alpha\n' > "$overlay/scripts/a.sh"
mkdir -p "$overlay/docs" "$overlay/scripts"
for rel in \
  docs/PROFILE-BENCHMARKS.md \
  docs/PROFILE-BENCHMARKS.vi.md \
  docs/SOURCE-INTEGRITY.md \
  docs/SOURCE-INTEGRITY.vi.md \
  scripts/resource-monitor.py \
  scripts/source-fingerprint.py; do
    printf 'stale\n' > "$overlay/$rel"
done
if python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$overlay" --manifest "$overlay/SOURCE-MANIFEST.json" \
  --json-output "$tmp/overlay-check.json" --require-clean; then
  echo 'FAIL: repairable overlay incorrectly passed strict clean check' >&2
  exit 1
fi
python3 - "$tmp/overlay-check.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
expected=[
    'docs/PROFILE-BENCHMARKS.md',
    'docs/PROFILE-BENCHMARKS.vi.md',
    'docs/SOURCE-INTEGRITY.md',
    'docs/SOURCE-INTEGRITY.vi.md',
    'scripts/resource-monitor.py',
    'scripts/source-fingerprint.py',
]
assert x['integrity_status']=='DIRTY'
assert x['modified_files']==[]
assert x['missing_files']==[]
assert x['repairable_overlay_files']==expected
assert x['unknown_unexpected_files']==[]
PY
# repair-overlay must REFUSE when SHA256 hashes are unknown (fail-closed).
python3 "$PROJECT_DIR/scripts/source-integrity.py" repair-overlay \
  --root "$overlay" --manifest "$overlay/SOURCE-MANIFEST.json" \
  --json-output "$tmp/overlay-refused.json" || true
python3 - "$tmp/overlay-refused.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['repair_status']=='REFUSED'
assert 'SHA256 hash unknown' in x['reason']
assert x['repaired_files']==[]
PY
# Dry-run must also refuse when hashes are unknown.
python3 "$PROJECT_DIR/scripts/source-integrity.py" repair-overlay \
  --root "$overlay" --manifest "$overlay/SOURCE-MANIFEST.json" \
  --json-output "$tmp/overlay-dry.json" || true
python3 - "$tmp/overlay-dry.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['repair_status']=='REFUSED'
PY
for rel in \
  docs/PROFILE-BENCHMARKS.md \
  docs/PROFILE-BENCHMARKS.vi.md \
  docs/SOURCE-INTEGRITY.md \
  docs/SOURCE-INTEGRITY.vi.md \
  scripts/resource-monitor.py \
  scripts/source-fingerprint.py; do
    [[ -f "$overlay/$rel" ]] || { echo "FAIL: refused repair removed $rel" >&2; exit 1; }
done

# Unknown additions must never be auto-deleted by repair-overlay.
printf 'keep me\n' > "$overlay/my-custom-script.sh"
if python3 "$PROJECT_DIR/scripts/source-integrity.py" repair-overlay \
  --root "$overlay" --manifest "$overlay/SOURCE-MANIFEST.json" \
  --apply --json-output "$tmp/overlay-refused.json"; then
  echo 'FAIL: repair-overlay accepted an unknown unexpected file' >&2
  exit 1
fi
[[ -f "$overlay/my-custom-script.sh" ]] || { echo 'FAIL: unknown file was deleted' >&2; exit 1; }
python3 - "$tmp/overlay-refused.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['repair_status']=='REFUSED'
assert x['unknown_unexpected_files']==['my-custom-script.sh']
assert x['repaired_files']==[]
PY

# If a known stale overlay and an unknown file coexist, repair must be atomic:
# refuse before deleting even the allowlisted stale file.
mixed="$tmp/mixed-overlay"
cp -a "$fixture" "$mixed"
printf 'docs\n' > "$mixed/docs/readme.md"
printf 'alpha\n' > "$mixed/scripts/a.sh"
printf 'stale again\n' > "$mixed/scripts/resource-monitor.py"
printf 'unknown\n' > "$mixed/custom-local-source.sh"
if python3 "$PROJECT_DIR/scripts/source-integrity.py" repair-overlay \
  --root "$mixed" --manifest "$mixed/SOURCE-MANIFEST.json" \
  --apply --json-output "$tmp/mixed-refused.json"; then
  echo 'FAIL: mixed known+unknown overlay was incorrectly repaired' >&2
  exit 1
fi
[[ -f "$mixed/scripts/resource-monitor.py" ]] || { echo 'FAIL: repair was not atomic' >&2; exit 1; }
[[ -f "$mixed/custom-local-source.sh" ]] || { echo 'FAIL: unknown source was deleted' >&2; exit 1; }

# --- Manifest schema validation tests ---
# These tests prove that source-integrity rejects malformed/inconsistent manifests
# rather than silently accepting or repairing them.

schema_fixture="$tmp/schema-fixture"
mkdir -p "$schema_fixture/scripts" "$schema_fixture/docs"
printf '1.0.0\n' > "$schema_fixture/VERSION"
printf 'alpha\n' > "$schema_fixture/scripts/a.sh"
printf 'docs\n' > "$schema_fixture/docs/readme.md"
python3 "$PROJECT_DIR/scripts/source-integrity.py" manifest \
  --root "$schema_fixture" --output "$schema_fixture/SOURCE-MANIFEST.json"
base_manifest="$(cat "$schema_fixture/SOURCE-MANIFEST.json")"

# --- Symlink regression tests ---

# Symlink-to-directory must be detected as unexpected source.
symlink_dir_fixture="$tmp/symlink-dir-fixture"
cp -a "$schema_fixture" "$symlink_dir_fixture"

mkdir -p "$tmp/external-dir-target"
printf 'external\n' > "$tmp/external-dir-target/value.txt"
ln -s "$tmp/external-dir-target" "$symlink_dir_fixture/unexpected-dir-link"

if python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$symlink_dir_fixture" \
  --manifest "$symlink_dir_fixture/SOURCE-MANIFEST.json" \
  --json-output "$tmp/symlink-dir.json" \
  --require-clean; then
    echo 'FAIL: unexpected symlink-to-directory was ignored' >&2
    exit 1
fi
python3 - "$tmp/symlink-dir.json" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
assert x["integrity_status"] == "DIRTY", x
assert "unexpected-dir-link" in x["unexpected_files"], x
PY

# Symlink-to-file must also be detected as unexpected source.
symlink_file_fixture="$tmp/symlink-file-fixture"
cp -a "$schema_fixture" "$symlink_file_fixture"

printf 'target\n' > "$tmp/external-file-target"
ln -s "$tmp/external-file-target" "$symlink_file_fixture/unexpected-file-link"

if python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$symlink_file_fixture" \
  --manifest "$symlink_file_fixture/SOURCE-MANIFEST.json" \
  --json-output "$tmp/symlink-file.json" \
  --require-clean; then
    echo 'FAIL: unexpected symlink-to-file was ignored' >&2
    exit 1
fi
python3 - "$tmp/symlink-file.json" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
assert x["integrity_status"] == "DIRTY", x
assert "unexpected-file-link" in x["unexpected_files"], x
PY

# Helper: write a custom manifest and run check --require-clean, expect INVALID_MANIFEST + exit 4.
run_bad_manifest() {
    local desc="$1" manifest_json="$2"
    local bad_dir
    bad_dir="$tmp/bad-$(date +%s%N)-$$"
    mkdir -p "$bad_dir"
    cp -a "$schema_fixture/." "$bad_dir/"
    printf '%s\n' "$manifest_json" > "$bad_dir/SOURCE-MANIFEST.json"
    set +e
    python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
      --root "$bad_dir" --manifest "$bad_dir/SOURCE-MANIFEST.json" \
      --json-output "$tmp/bad-schema.json" --require-clean
    rc=$?
    set -e
    if [[ "$rc" -ne 4 ]]; then
        echo "FAIL: $desc returned exit $rc, expected 4" >&2
        rm -rf "$bad_dir"
        return 1
    fi
    python3 - "$tmp/bad-schema.json" <<'PY' || { rm -rf "$bad_dir"; return 1; }
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status'] == 'INVALID_MANIFEST', f"expected INVALID_MANIFEST, got {x['integrity_status']}"
assert x.get('manifest_errors'), f"expected manifest_errors, got {x}"
PY
    rm -rf "$bad_dir"
    return 0
}

# 1. Wrong schema_version.
bad_sv="$(echo "$base_manifest" | python3 -c "import json,sys; m=json.load(sys.stdin); m['schema_version']=99; print(json.dumps(m))")"
run_bad_manifest "wrong schema_version" "$bad_sv"

# 2. Wrong scope.
bad_scope="$(echo "$base_manifest" | python3 -c "import json,sys; m=json.load(sys.stdin); m['scope']='wrong-scope'; print(json.dumps(m))")"
run_bad_manifest "wrong scope" "$bad_scope"

# 3. canonical_file_count mismatch.
bad_count="$(echo "$base_manifest" | python3 -c "import json,sys; m=json.load(sys.stdin); m['canonical_file_count']=999; print(json.dumps(m))")"
run_bad_manifest "canonical_file_count mismatch" "$bad_count"

# 4. Duplicate path entries.
bad_dup="$(echo "$base_manifest" | python3 -c "
import json,sys
m=json.load(sys.stdin)
dup=m['files'][0].copy()
m['files'].append(dup)
m['canonical_file_count']=len(m['files'])
print(json.dumps(m))
")"
run_bad_manifest "duplicate path" "$bad_dup"

# 5. Missing canonical_sha256.
bad_hash="$(echo "$base_manifest" | python3 -c "import json,sys; m=json.load(sys.stdin); del m['canonical_sha256']; print(json.dumps(m))")"
run_bad_manifest "missing canonical_sha256" "$bad_hash"

# 6. Malformed record SHA256 (not hex / wrong length).
bad_record_hash="$(echo "$base_manifest" | python3 -c "
import json,sys
m=json.load(sys.stdin)
m['files'][0]['sha256']='not-a-valid-sha256'
print(json.dumps(m))
")"
run_bad_manifest "malformed record sha256" "$bad_record_hash"

# 7. Negative size.
bad_size="$(echo "$base_manifest" | python3 -c "
import json,sys
m=json.load(sys.stdin)
m['files'][0]['size']=-1
print(json.dumps(m))
")"
run_bad_manifest "negative size" "$bad_size"

# 8. Unsupported kind.
bad_kind="$(echo "$base_manifest" | python3 -c "
import json,sys
m=json.load(sys.stdin)
m['files'][0]['kind']='device'
print(json.dumps(m))
")"
run_bad_manifest "unsupported kind" "$bad_kind"

# 9. Unsafe path (.. traversal).
bad_path="$(echo "$base_manifest" | python3 -c "
import json,sys
m=json.load(sys.stdin)
m['files'][0]['path']='../../etc/passwd'
print(json.dumps(m))
")"
run_bad_manifest "unsafe path with .." "$bad_path"

# 10. Mismatched canonical_sha256 vs actual fingerprint.
bad_digest="$(echo "$base_manifest" | python3 -c "
import json,sys
m=json.load(sys.stdin)
m['canonical_sha256']='a'*64
print(json.dumps(m))
")"
run_bad_manifest "mismatched canonical_sha256" "$bad_digest"

# 11. Malformed JSON.
bad_json_dir="$tmp/bad-json-$$"
mkdir -p "$bad_json_dir"
cp -a "$schema_fixture/." "$bad_json_dir/"
printf '{not valid json' > "$bad_json_dir/SOURCE-MANIFEST.json"
set +e
python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
  --root "$bad_json_dir" --manifest "$bad_json_dir/SOURCE-MANIFEST.json" \
  --json-output "$tmp/bad-json-out.json" --require-clean
bad_json_rc=$?
set -e
if [[ "$bad_json_rc" -ne 4 ]]; then
    echo "FAIL: malformed JSON exit=$bad_json_rc, expected 4" >&2
    rm -rf "$bad_json_dir"
    exit 1
fi
python3 - "$tmp/bad-json-out.json" <<'PY' || { rm -rf "$bad_json_dir"; exit 1; }
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status'] == 'INVALID_MANIFEST', f"expected INVALID_MANIFEST, got {x['integrity_status']}"
assert x['manifest_errors'], f"expected manifest_errors, got {x}"
assert 'valid JSON' in x['manifest_errors'][0], f"expected 'valid JSON' in error, got {x['manifest_errors'][0]}"
PY
rm -rf "$bad_json_dir"

# 12. repair-overlay must refuse invalid manifest with exit 4.
repair_bad_dir="$tmp/bad-$(date +%s%N)-$$"
mkdir -p "$repair_bad_dir"
cp -a "$schema_fixture/." "$repair_bad_dir/"
printf '%s\n' "$bad_sv" > "$repair_bad_dir/SOURCE-MANIFEST.json"
set +e
python3 "$PROJECT_DIR/scripts/source-integrity.py" repair-overlay \
  --root "$repair_bad_dir" \
  --manifest "$repair_bad_dir/SOURCE-MANIFEST.json" \
  --apply \
  --json-output "$tmp/repair-invalid.json"
repair_rc=$?
set -e
if [[ "$repair_rc" -ne 4 ]]; then
    echo "FAIL: repair-overlay invalid manifest exit=$repair_rc, expected 4" >&2
    rm -rf "$repair_bad_dir"
    exit 1
fi
python3 - "$tmp/repair-invalid.json" <<'PY' || { rm -rf "$repair_bad_dir"; exit 1; }
import json, sys
x=json.load(open(sys.argv[1]))
assert x['repair_status'] == 'REFUSED', f"expected REFUSED, got {x['repair_status']}"
assert 'canonical manifest is invalid' in x['reason'], f"expected 'canonical manifest is invalid' in reason, got {x['reason']}"
assert x['repaired_files'] == [], f"expected empty repaired_files, got {x['repaired_files']}"
PY
rm -rf "$repair_bad_dir"

# 12. files not a list.
bad_files="$(echo "$base_manifest" | python3 -c "
import json,sys
m=json.load(sys.stdin)
m['files']='not-a-list'
print(json.dumps(m))
")"
run_bad_manifest "files not a list" "$bad_files"

echo 'manifest schema validation tests passed'
