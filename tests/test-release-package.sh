#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- Create isolated Git fixture for all Git-mode tests ---
# The fixture contains committed project source with a valid canonical manifest
# so all Git-mode tests can exercise the packaging pipeline without touching the
# real working tree.

git_fixture="$tmp/git-fixture"
mkdir -p "$git_fixture"
tar -cf - -C "$PROJECT_DIR" --exclude='.git' . | tar -xf - -C "$git_fixture"

if [[ -f "$PROJECT_DIR/SOURCE-MANIFEST.json" ]]; then
    cmp \
      "$PROJECT_DIR/SOURCE-MANIFEST.json" \
      "$git_fixture/SOURCE-MANIFEST.json" || {
        echo 'FAIL: copied Git fixture did not preserve distributed canonical manifest' >&2
        exit 1
    }
else
    python3 "$git_fixture/scripts/source-integrity.py" manifest \
      --root "$git_fixture" \
      --output "$git_fixture/SOURCE-MANIFEST.json" >/dev/null
fi

(
  cd "$git_fixture"
  git init -q
  git add -A
  git -c user.name='QNP Test' \
      -c user.email='qnp-test@example.invalid' \
      commit -q -m 'initial'
)

# --- Git-mode packaging hygiene test (clean committed fixture must succeed) ---

out="$tmp/release.zip"
bash "$git_fixture/scripts/package-release.sh" "$out" >/dev/null
[[ -s "$out" ]]
[[ -s "$out.sha256" ]]
(cd "$tmp" && sha256sum -c "$(basename "$out").sha256" >/dev/null)
unsafe_archive_mode="$(zipinfo -l "$out" | awk '$1 ~ /^[-d]/ && ($1 ~ /[sStT]/ || substr($1,6,1)=="w" || substr($1,9,1)=="w") {print $1 " " $NF; exit}')"
if [[ -n "$unsafe_archive_mode" ]]; then
    echo "FAIL: unsafe permission metadata in ZIP: $unsafe_archive_mode" >&2
    exit 1
fi
unzip -q "$out" -d "$tmp/unpacked"
root="$tmp/unpacked/qdrant-native-portable-v$(cat "$git_fixture/VERSION")"
[[ -f "$root/VERSION" ]]
[[ "$(cat "$root/VERSION")" == "1.0.0" ]]
[[ -x "$root/run-smart-qdrant-benchmarks.sh" ]]
[[ -x "$root/run-fresh-qdrant-benchmarks.sh" ]]
[[ -x "$root/scripts/purge-all-test.sh" ]]
[[ -x "$root/scripts/profile-advisor.sh" ]]
[[ -f "$root/docs/PROFILE-ADVISOR.md" ]]
[[ -f "$root/docs/PROFILE-ADVISOR.vi.md" ]]
[[ -f "$root/docs/PRODUCTION.md" ]]
[[ -f "$root/docs/PRODUCTION.vi.md" ]]
[[ -f "$root/Dockerfile" ]]
[[ -f "$root/docker/Dockerfile" ]]
[[ -f "$root/.dockerignore" ]]
[[ -f "$root/docker/persistence.sh" ]]
[[ -f "$root/deploy/huggingface-spaces/README.template.md" ]]
[[ -f "$root/deploy/modal/app.py" ]]
[[ -f "$root/deploy/beam/app.py" ]]
if [[ -e "$root/docs/superpowers" ]]; then echo 'FAIL: packaged internal design/plan docs' >&2; exit 1; fi
[[ -f "$root/SOURCE-MANIFEST.json" ]]
# Release packager must explicitly reject benchmark result archives if they are
# ever staged (for example because a user force-added one to Git).
grep -Fq "qdrant-benchmarks-*.zip" "$git_fixture/scripts/package-release.sh"
grep -Fq "profile-ab-*.zip" "$git_fixture/scripts/package-release.sh"
python3 "$root/scripts/source-integrity.py" check --root "$root" --require-clean --json-output "$tmp/source-integrity.json" >/dev/null
python3 - "$tmp/source-integrity.json" <<'PYJSON'
import json, sys
x=json.load(open(sys.argv[1]))
assert x['integrity_status']=='CLEAN', x
assert x['canonical_file_count'] > 0
assert x['modified_files']==[] and x['missing_files']==[] and x['unexpected_files']==[]
PYJSON

for bad in '.qdrant-base' '.qdrant-initialized' '.qdrant-native-portable-instance' 'secrets.env' 'runtime.env'; do
    if find "$root" -name "$bad" -print -quit | grep -q .; then
        echo "FAIL: packaged $bad" >&2; exit 1
    fi
done
if find "$root" -type f -name '*.log' -print -quit | grep -q .; then echo 'FAIL: packaged log' >&2; exit 1; fi
if find "$root" -type d -name '__pycache__' -print -quit | grep -q .; then echo 'FAIL: packaged __pycache__' >&2; exit 1; fi
if find "$root" -type d -name node_modules -print -quit | grep -q .; then echo 'FAIL: packaged node_modules' >&2; exit 1; fi

# Archive permissions must not preserve special bits or group/world writes from
# a developer machine. Executables may be 0755; regular files should be 0644.
while IFS= read -r -d '' path; do
    mode=$(stat -c '%a' "$path")
    perm=$((8#$mode))
    if (( perm & 07000 || perm & 00022 )); then
        echo "FAIL: unsafe packaged permission $mode on ${path#"$root"/}" >&2
        exit 1
    fi
done < <(find "$root" -print0)
[[ "$(stat -c '%a' "$root/tests/test-health-check-exit.sh")" == "755" ]]

# --- Git-mode dirty-tree rejection tests ---
# git_fixture is already created at the top of this file.

# Defense 1: unstaged tracked README modification must be rejected.
git_mod_readme="$tmp/git-mod-readme"
cp -a "$git_fixture" "$git_mod_readme"
printf '\nLOCAL UNCOMMITTED\n' >> "$git_mod_readme/README.md"
if bash "$git_mod_readme/scripts/package-release.sh" "$tmp/git-dirty-readme.zip" >/dev/null 2>&1; then
    echo 'FAIL: package-release accepted unstaged tracked README modification' >&2
    exit 1
fi

# Defense 1: unstaged tracked script modification must be rejected.
git_mod_script="$tmp/git-mod-script"
cp -a "$git_fixture" "$git_mod_script"
printf '\n# local change\n' >> "$git_mod_script/scripts/package-release.sh"
if bash "$git_mod_script/scripts/package-release.sh" "$tmp/git-dirty-script.zip" >/dev/null 2>&1; then
    echo 'FAIL: package-release accepted unstaged tracked script modification' >&2
    exit 1
fi

# Defense 1: staged-but-uncommitted modification must be rejected.
git_staged="$tmp/git-staged"
cp -a "$git_fixture" "$git_staged"
printf '\nSTAGED CHANGE\n' >> "$git_staged/README.md"
(cd "$git_staged" && git add README.md)
if bash "$git_staged/scripts/package-release.sh" "$tmp/git-staged.zip" >/dev/null 2>&1; then
    echo 'FAIL: package-release accepted staged-but-uncommitted modification' >&2
    exit 1
fi

# Defense 2: packaging must use HEAD bytes, not working-tree bytes.
# The clean fixture was already packaged successfully above; verify extracted
# README.md matches the committed HEAD version.
expected_readme="$(git -C "$git_fixture" show HEAD:README.md)"
actual_readme="$(cat "$root/README.md")"
if [[ "$expected_readme" != "$actual_readme" ]]; then
    echo 'FAIL: Git-mode release did not use HEAD bytes for README.md' >&2
    exit 1
fi

# --- export-ignore regression test ---
# If a future .gitattributes adds export-ignore, git archive would silently
# omit the file. The packager must detect the resulting drift.

export_ignore_fixture="$tmp/export-ignore-fixture"
cp -a "$git_fixture" "$export_ignore_fixture"
(
  cd "$export_ignore_fixture"

  printf '\nREADME.md export-ignore\n' >> .gitattributes

  python3 scripts/source-integrity.py manifest \
    --root . \
    --output SOURCE-MANIFEST.json >/dev/null

  git add -- .gitattributes SOURCE-MANIFEST.json
  git -c user.name='QNP Test' \
      -c user.email='qnp-test@example.invalid' \
      commit -q -m 'fixture with export-ignore'
)

if bash "$export_ignore_fixture/scripts/package-release.sh" \
  "$tmp/export-ignore.zip" >"$tmp/export-ignore.out" 2>"$tmp/export-ignore.err"; then
    echo 'FAIL: package-release self-blessed git archive export-ignore drift' >&2
    exit 1
fi
grep -Fq \
  'Staged release tree does not match canonical source authority.' \
  "$tmp/export-ignore.err" || {
    echo 'FAIL: export-ignore fixture failed for the wrong reason' >&2
    cat "$tmp/export-ignore.err" >&2
    exit 1
}

# --- Committed symlink rejection test ---
# A tracked symlink must be rejected by the packager with an explicit message.

symlink_release_fixture="$tmp/symlink-release-fixture"
cp -a "$git_fixture" "$symlink_release_fixture"

(
  cd "$symlink_release_fixture"

  ln -s README.md release-link

  python3 scripts/source-integrity.py manifest \
    --root . \
    --output SOURCE-MANIFEST.json >/dev/null

  git add -- release-link SOURCE-MANIFEST.json
  git -c user.name='QNP Test' \
      -c user.email='qnp-test@example.invalid' \
      commit -q -m 'fixture with symlink'
)

if bash "$symlink_release_fixture/scripts/package-release.sh" \
  "$tmp/symlink-release.zip" \
  >"$tmp/symlink-release.out" \
  2>"$tmp/symlink-release.err"; then
    echo 'FAIL: package-release accepted committed symlink' >&2
    exit 1
fi

grep -Fq \
  'Release tree contains a symlink' \
  "$tmp/symlink-release.err" || {
    echo 'FAIL: symlink fixture failed for the wrong reason' >&2
    cat "$tmp/symlink-release.err" >&2
    exit 1
}

# --- Content-guard negative tests (committed + canonical-clean) ---
# These tests must commit the malicious content so the dirty-tree check does
# not cause a false positive pass/fail.

guard_fixture="$tmp/guard-fixture"
mkdir -p "$guard_fixture"
tar -cf - -C "$PROJECT_DIR" --exclude='.git' . | tar -xf - -C "$guard_fixture"
(cd "$guard_fixture" && git init -q && \
  printf '\nhttps://qnp-release-leak-example.%s\n' 'trycloudflare.com' >> README.md && \
  python3 scripts/source-integrity.py manifest --root . --output SOURCE-MANIFEST.json && \
  git add -A && git -c user.name='QNP Test' -c user.email='qnp-test@example.invalid' commit -q -m 'fixture with trycloudflare URL')
if bash "$guard_fixture/scripts/package-release.sh" \
  "$tmp/guard-url.zip" \
  >"$tmp/guard-url.out" \
  2>"$tmp/guard-url.err"; then
    echo 'FAIL: package-release accepted a concrete trycloudflare URL in committed source' >&2
    exit 1
fi
grep -Fq \
  'Concrete trycloudflare URL detected in release tree' \
  "$tmp/guard-url.err" || {
    echo 'FAIL: trycloudflare fixture failed for the wrong reason' >&2
    cat "$tmp/guard-url.err" >&2
    exit 1
}

guard_fixture2="$tmp/guard-fixture2"
mkdir -p "$guard_fixture2"
tar -cf - -C "$PROJECT_DIR" --exclude='.git' . | tar -xf - -C "$guard_fixture2"
(cd "$guard_fixture2" && git init -q && \
  printf '\nprivate marker: v1.1.%s-modal-%s5\n' '3' 'staging' >> examples/README.md && \
  python3 scripts/source-integrity.py manifest --root . --output SOURCE-MANIFEST.json && \
  git add -A && git -c user.name='QNP Test' -c user.email='qnp-test@example.invalid' commit -q -m 'fixture with internal marker')
if bash "$guard_fixture2/scripts/package-release.sh" \
  "$tmp/guard-marker.zip" \
  >"$tmp/guard-marker.out" \
  2>"$tmp/guard-marker.err"; then
    echo 'FAIL: package-release accepted an internal development marker in committed source' >&2
    exit 1
fi
grep -Fq \
  'Internal development marker detected in release tree' \
  "$tmp/guard-marker.err" || {
    echo 'FAIL: internal marker fixture failed for the wrong reason' >&2
    cat "$tmp/guard-marker.err" >&2
    exit 1
}

# --- Nested-Git regression test ---
# The project sits inside a larger Git repo (nested Git). The packager must
# detect staged canonical drift via the manifest authority, not self-bless.

nested_outer="$tmp/nested-outer"
nested_project="$nested_outer/qnp"

mkdir -p "$nested_project"

tar -cf - -C "$PROJECT_DIR" --exclude='.git' . \
  | tar -xf - -C "$nested_project"

# Include docs/superpowers so the packager's rm -rf creates canonical drift.
mkdir -p "$nested_project/docs/superpowers"
printf 'private plan\n' \
  > "$nested_project/docs/superpowers/nested-git-plan.md"

python3 "$nested_project/scripts/source-integrity.py" manifest \
  --root "$nested_project" \
  --output "$nested_project/SOURCE-MANIFEST.json" \
  >/dev/null

(
  cd "$nested_outer"
  git init -q
  git add qnp
  git -c user.name='QNP Test' \
      -c user.email='qnp-test@example.invalid' \
      commit -q -m 'nested project fixture'
)

if bash "$nested_project/scripts/package-release.sh" \
  "$tmp/nested-git-release.zip" \
  >"$tmp/nested-git.out" \
  2>"$tmp/nested-git.err"; then
    echo 'FAIL: nested-Git packaging self-blessed staged canonical drift' >&2
    exit 1
fi

grep -Fq \
  'Staged release tree does not match canonical source authority.' \
  "$tmp/nested-git.err" || {
    echo 'FAIL: nested-Git fixture failed for the wrong reason' >&2
    cat "$tmp/nested-git.err" >&2
    exit 1
}

# --- No-Git release packaging regression tests ---

nogit="$tmp/no-git-tree"
# Copy from the clean committed fixture (not the real working tree) so the
# canonical manifest is consistent with the source files.
cp -a "$git_fixture" "$nogit"
rm -rf "$nogit/.git"
[[ ! -e "$nogit/.git" ]] || { echo 'FAIL: .git was copied into no-Git tree' >&2; exit 1; }
# Preserve the distributed canonical manifest when present.
if [[ -f "$PROJECT_DIR/SOURCE-MANIFEST.json" ]]; then
    cmp \
      "$PROJECT_DIR/SOURCE-MANIFEST.json" \
      "$nogit/SOURCE-MANIFEST.json" || {
        echo 'FAIL: no-Git tree does not preserve distributed canonical manifest' >&2
        exit 1
    }
fi
# Fallback: generate fixture manifest only for historical revisions without one.
if [[ ! -f "$nogit/SOURCE-MANIFEST.json" ]]; then
    python3 "$nogit/scripts/source-integrity.py" manifest \
        --root "$nogit" --output "$nogit/SOURCE-MANIFEST.json" >/dev/null
fi

# Clean no-Git packaging must succeed.
no_git_out="$tmp/no-git-release.zip"
bash "$nogit/scripts/package-release.sh" "$no_git_out" >/dev/null
[[ -s "$no_git_out" ]] || { echo 'FAIL: no-Git release ZIP not created' >&2; exit 1; }
[[ -s "$no_git_out.sha256" ]] || { echo 'FAIL: no-Git release SHA256 sidecar not created' >&2; exit 1; }
(cd "$(dirname "$no_git_out")" && sha256sum -c "$(basename "$no_git_out").sha256" >/dev/null)

# Extract and verify the release passes source-integrity.
unzip -q "$no_git_out" -d "$tmp/no-git-unpacked"
no_git_root="$tmp/no-git-unpacked/qdrant-native-portable-v$(cat "$PROJECT_DIR/VERSION")"
# The release archive contains a regenerated SOURCE-MANIFEST.json.
[[ -f "$no_git_root/SOURCE-MANIFEST.json" ]] || { echo 'FAIL: no-Git release missing SOURCE-MANIFEST.json' >&2; exit 1; }
python3 "$no_git_root/scripts/source-integrity.py" check \
    --root "$no_git_root" --manifest "$no_git_root/SOURCE-MANIFEST.json" --require-clean \
    >/dev/null || { echo 'FAIL: no-Git release failed source-integrity check' >&2; exit 1; }

# Tampered canonical source must fail packaging.
tampered="$tmp/tampered-tree"
mkdir -p "$tampered"
tar -cf - -C "$nogit" . | tar -xf - -C "$tampered"
printf '\nTAMPERED\n' >> "$tampered/README.md"
if bash "$tampered/scripts/package-release.sh" "$tmp/tampered-release.zip" >/dev/null 2>&1; then
    echo 'FAIL: no-Git packaging accepted tampered source' >&2
    exit 1
fi

# Unexpected source file must fail packaging.
unexpected_tree="$tmp/unexpected-tree"
mkdir -p "$unexpected_tree"
tar -cf - -C "$nogit" . | tar -xf - -C "$unexpected_tree"
printf 'unexpected\n' > "$unexpected_tree/scripts/unexpected-source.sh"
if bash "$unexpected_tree/scripts/package-release.sh" "$tmp/unexpected-release.zip" >/dev/null 2>&1; then
    echo 'FAIL: no-Git packaging accepted unexpected source file' >&2
    exit 1
fi

# --- No-Git / no-manifest fail-closed regression test ---
# Without Git and without a canonical manifest, official release packaging must
# refuse to create authority from an untrusted tree.

no_authority="$tmp/no-authority-tree"
mkdir -p "$no_authority"

tar -cf - -C "$PROJECT_DIR" --exclude='.git' . \
  | tar -xf - -C "$no_authority"

rm -f "$no_authority/SOURCE-MANIFEST.json"
rm -rf "$no_authority/.git"

printf 'untrusted source\n' \
  > "$no_authority/scripts/untrusted-source.sh"

if bash "$no_authority/scripts/package-release.sh" \
  "$tmp/no-authority.zip" \
  >"$tmp/no-authority.out" \
  2>"$tmp/no-authority.err"; then
    echo 'FAIL: no-Git/no-manifest tree was packaged as an official release' >&2
    exit 1
fi

grep -Fq \
  'No Git checkout or canonical SOURCE-MANIFEST.json; refusing to create an official release.' \
  "$tmp/no-authority.err" || {
    echo 'FAIL: no-authority fixture failed for the wrong reason' >&2
    cat "$tmp/no-authority.err" >&2
    exit 1
}

if [[ -e "$tmp/no-authority.zip" ]]; then
    echo 'FAIL: no-authority packaging left an official release ZIP behind' >&2
    exit 1
fi

if [[ -e "$tmp/no-authority.zip.sha256" ]]; then
    echo 'FAIL: no-authority packaging left a SHA256 sidecar behind' >&2
    exit 1
fi

echo 'no-Git release packaging tests passed'
echo 'release package hygiene passed'
