#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"
require zip sha256sum tar python3

version="$(cat "$PROJECT_DIR/VERSION" 2>/dev/null || echo dev)"
archive_name="qdrant-native-portable-v${version}.zip"
output="${1:-$(cd "$PROJECT_DIR/.." && pwd)/$archive_name}"
output="$(realpath -m "$output")"
root_name="qdrant-native-portable-v${version}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must use semantic versioning (for example 1.0.0)"
[[ "$output" != "$PROJECT_DIR"/* ]] || fail "Write the release archive outside the project directory to avoid self-inclusion."

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$root_name"

canonical_manifest_for_stage=""

manifest_driven_packaging() {
    local manifest_file="$PROJECT_DIR/SOURCE-MANIFEST.json"
    [[ -f "$manifest_file" ]] || fail "Canonical SOURCE-MANIFEST.json not found; cannot package without manifest authority."

    canonical_manifest_for_stage="$manifest_file"

    # Verify the existing canonical manifest is CLEAN before using it as authority.
    python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
        --root "$PROJECT_DIR" --manifest "$manifest_file" --require-clean \
        >/dev/null || fail "Canonical SOURCE-MANIFEST.json is not CLEAN; refusing to package from a tampered manifest."

    # Copy exactly the records from the verified canonical manifest.
    python3 - "$PROJECT_DIR" "$stage/$root_name" "$manifest_file" <<'MANIFEST_PY'
import json, os, pathlib, shutil, sys

root, dest, manifest_path = sys.argv[1], sys.argv[2], sys.argv[3]
root_path = pathlib.Path(root).resolve()
dest_path = pathlib.Path(dest)
stage_root = dest_path

manifest = json.loads(open(manifest_path).read())
for record in manifest["files"]:
    rel = record["path"]

    # Path validation: reject unsafe paths.
    pp = pathlib.PurePosixPath(rel)
    if pp.is_absolute() or ".." in pp.parts or not rel:
        raise SystemExit(f"Rejected unsafe manifest path (absolute/traversal/empty): {rel}")
    if "\x00" in rel:
        raise SystemExit(f"Rejected manifest path with NUL byte: {rel}")

    # Reject symlink records — public v1.0.0 does not support symlinks in release archives.
    if record.get("kind") == "symlink":
        raise SystemExit(f"Rejected symlink record in canonical manifest: {rel}")

    src_path = root_path / rel
    dst_path = stage_root / rel

    # Verify resolved destination stays inside stage root.
    try:
        dst_resolved = dst_path.resolve()
        if not str(dst_resolved).startswith(str(stage_root.resolve())):
            raise SystemExit(f"Rejected manifest path escapes stage root: {rel}")
    except (OSError, ValueError):
        raise SystemExit(f"Rejected unresolvable manifest path: {rel}")

    dir_name = dst_path.parent
    if dir_name:
        os.makedirs(dir_name, exist_ok=True)
    shutil.copy2(str(src_path), str(dst_path))
MANIFEST_PY
    info "Packaged files from verified canonical manifest"
}

if command -v git >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel)"
    if [[ "$repo_root" == "$PROJECT_DIR" ]]; then
        # Defense 1: reject any staged or unstaged tracked divergence from HEAD.
        if ! git -C "$PROJECT_DIR" diff --quiet HEAD --; then
            fail "Git working tree has uncommitted tracked changes; official release packaging requires committed source."
        fi
        # Defense-in-depth: verify canonical manifest when present.
        if [[ -f "$PROJECT_DIR/SOURCE-MANIFEST.json" ]]; then
            canonical_manifest_for_stage="$PROJECT_DIR/SOURCE-MANIFEST.json"
            python3 "$PROJECT_DIR/scripts/source-integrity.py" check \
                --root "$PROJECT_DIR" --manifest "$PROJECT_DIR/SOURCE-MANIFEST.json" --require-clean \
                >/dev/null || fail "Canonical SOURCE-MANIFEST.json is not CLEAN; refusing to package."
        fi
        # Defense 2: package from the committed HEAD object, not mutable working-tree bytes.
        git -C "$PROJECT_DIR" archive --format=tar HEAD | tar -xf - -C "$stage/$root_name"
        info "Packaging committed Git HEAD objects"
    else
        warn "Project is nested inside a larger Git repository; using manifest-driven packaging"
        manifest_driven_packaging
    fi
elif [[ -f "$PROJECT_DIR/SOURCE-MANIFEST.json" ]]; then
    info "No Git checkout detected; using manifest-driven packaging"
    manifest_driven_packaging
else
    fail "No Git checkout or canonical SOURCE-MANIFEST.json; refusing to create an official release."
fi

# Internal implementation design/plan notes are useful in private working trees
# but are not part of the canonical public source artifact.
rm -rf "$stage/$root_name/docs/superpowers"

# Reject symlinks in the release tree — public v1.0.0 does not ship symlinks.
symlink="$(find "$stage/$root_name" -type l -print -quit)"
[[ -z "$symlink" ]] || fail "Release tree contains a symlink: ${symlink#"$stage"/"$root_name"/}"

# Generated interpreter caches may exist even inside an otherwise clean source tree.
find "$stage/$root_name" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$stage/$root_name" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

# Release hygiene is intentionally fail-closed: do not silently package runtime state.
prohibited="$(find "$stage/$root_name" \
    \( -type d \( -name node_modules -o -name .venv -o -name tokens \) \
    -o -type f \( -name '.qdrant-base' -o -name '.qdrant-initialized' -o -name '.qdrant-native-portable-instance' -o -name 'secrets.env' -o -name 'runtime.env' -o -name '*.log' -o -name '*.snapshot' -o -name '*.snapshot.sha256' \
                     -o -name 'qdrant-benchmarks-*.zip' -o -name 'qdrant-benchmarks-*.zip.sha256' \
                     -o -name 'profile-ab-*.zip' -o -name 'profile-ab-*.zip.sha256' \) \) \
    -print -quit)"
[[ -z "$prohibited" ]] || fail "Release contains prohibited runtime artifact: ${prohibited#"$stage"/"$root_name"/}"

if find "$stage/$root_name/benchmarks" -maxdepth 2 -type f -name 'benchmark-*.json' -print -quit 2>/dev/null | grep -q .; then
    fail "Generated benchmark JSON must not be included in a source release"
fi

if grep -RIE 'https://[-a-z0-9]+\.trycloudflare\.com' "$stage/$root_name" >/dev/null 2>&1; then
    fail "Concrete trycloudflare URL detected in release tree"
fi

internal_marker_re='(v1\.1\.[0-9]+|staging[0-9]+|production-candidate-'"real-pass"'|qnp-modal-staging[0-9]+)'
if grep -RIE "$internal_marker_re" "$stage/$root_name" >/dev/null 2>&1; then
    fail "Internal development marker detected in release tree"
fi
if grep -RIE "(QDRANT_API_KEY|apiKey|api-key)[^[:space:]]{0,80}[=:][[:space:]]*['\"]?[a-f0-9]{48,}" "$stage/$root_name" >/dev/null 2>&1; then
    fail "Likely embedded Qdrant API key detected in release tree"
fi

# Normalize archive permissions so a permissive developer checkout cannot leak
# setuid/setgid/sticky bits or group/world-writable source files into a release.
while IFS= read -r -d '' path; do
    if [[ -d "$path" ]]; then
        chmod a-s,a-t,u=rwx,go=rx "$path"
    elif [[ -x "$path" ]]; then
        chmod a-s,a-t,u=rwx,go=rx "$path"
    else
        chmod a-s,a-t,u=rw,go=r "$path"
    fi
done < <(find "$stage/$root_name" \( -type d -o -type f \) -print0)

# Build the canonical manifest from the exact staged public tree. The manifest
# excludes itself from the fingerprint, so an extracted archive can verify that
# every canonical source file is present and byte-for-byte unchanged.
# Before regenerating, verify the staged public source matches the original
# canonical authority to prevent self-blessing from export-ignore / staging drift.
if [[ -n "$canonical_manifest_for_stage" ]]; then
    python3 "$stage/$root_name/scripts/source-integrity.py" check \
        --root "$stage/$root_name" \
        --manifest "$canonical_manifest_for_stage" \
        --require-clean \
        >/dev/null || fail "Staged release tree does not match canonical source authority."
fi
rm -f "$stage/$root_name/SOURCE-MANIFEST.json"
python3 "$stage/$root_name/scripts/source-integrity.py" manifest     --root "$stage/$root_name"     --output "$stage/$root_name/SOURCE-MANIFEST.json" >/dev/null
python3 "$stage/$root_name/scripts/source-integrity.py" check     --root "$stage/$root_name"     --require-clean >/dev/null

rm -f "$output" "$output.sha256"
(
    cd "$stage"
    zip -qr "$output" "$root_name"
)
(
    cd "$(dirname "$output")"
    sha256sum "$(basename "$output")" > "$(basename "$output").sha256"
)
ok "Release archive created: $output"
ok "SHA256: $output.sha256"
