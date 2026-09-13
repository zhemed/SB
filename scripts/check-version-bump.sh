#!/usr/bin/env bash
# A push to main publishes a release: `sb.sh` is served straight from main, and
# installed hosts re-read it through the shortcut fallback. Any change under
# src/ therefore ships a new build and must carry a new VERSION, otherwise two
# different builds advertise the same version number and users cannot tell them
# apart. This guard fails a change that breaks that rule.
set -Eeuo pipefail

export LC_ALL=C

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly ROOT_DIR
readonly SOURCE_PATHS=(src sb.sh)
readonly VERSION_FILE=VERSION

fail(){
  printf 'check-version-bump: %s\n' "$1" >&2
  exit 1
}

usage(){
  printf 'Usage: %s [base-ref]\n' "${0##*/}"
  printf '  base-ref defaults to origin/main, then to HEAD^.\n'
  printf '  The base is compared against the working tree, so this also runs before commit.\n'
}

case ${1-} in
  -h|--help) usage; exit 0 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

for command_name in git sort tr; do
  command -v "$command_name" >/dev/null 2>&1 || fail "missing command: $command_name"
done

cd -- "$ROOT_DIR"

# Deliberately not part of tests/verify.sh: the gate must still run from a
# tarball or a shallow copy, where there is no history to compare against.
[[ -d .git ]] ||
  fail "not a git checkout; run this from a clone (it is not part of tests/verify.sh)"

resolve_base(){
  local candidate
  for candidate in "${1-}" origin/main HEAD^; do
    [[ -n $candidate ]] || continue
    if git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

base=$(resolve_base "${1-}") || fail "cannot resolve a base revision to compare against"
base_commit=$(git rev-parse --short "$base")

mapfile -t source_changes < <(git diff --name-only "$base" -- "${SOURCE_PATHS[@]}")
mapfile -t version_changes < <(git diff --name-only "$base" -- "$VERSION_FILE")

if [[ ${#source_changes[@]} -eq 0 ]]; then
  printf 'check-version-bump: no source change against %s; nothing to verify\n' "$base_commit"
  exit 0
fi

if [[ ${#version_changes[@]} -eq 0 ]]; then
  printf 'check-version-bump: source changed without a version bump\n' >&2
  printf '  base: %s\n' "$base_commit" >&2
  printf '  changed sources:\n' >&2
  printf '    %s\n' "${source_changes[@]}" >&2
  printf '  %s is still %s\n' "$VERSION_FILE" "$(tr -d '\r\n' < "$VERSION_FILE")" >&2
  printf 'Push to main publishes a release, so %s must change in the same commit.\n' \
    "$VERSION_FILE" >&2
  printf 'See .trellis/spec/build/version-pins.md section 1.\n' >&2
  exit 1
fi

before=$(git show "$base:$VERSION_FILE" 2>/dev/null | tr -d '\r\n' || true)
after=$(tr -d '\r\n' < "$VERSION_FILE")
if [[ -n $before && $before != "$after" ]]; then
  lowest=$(printf '%s\n%s\n' "$before" "$after" | sort -V | head -1)
  if [[ $lowest == "$after" ]]; then
    fail "$VERSION_FILE went backwards: $before -> $after"
  fi
fi

printf 'check-version-bump: %s -> %s covers %s source change(s) against %s\n' \
  "${before:-none}" "$after" "${#source_changes[@]}" "$base_commit"
