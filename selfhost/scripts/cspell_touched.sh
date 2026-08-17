#!/usr/bin/env bash
# cspell:words selftest speling rong deliberatly unoverridden unmatch RSTART RLENGTH setfile getline
#
# cspell_touched.sh -- the per-change spelling gate: YOUR CHANGE ADDS NO NEW
# FINDINGS.
#
# WHY THIS SHAPE, AND NOT "TOUCHED FILES MUST BE CLEAN". The stricter rule is the
# obvious one and it is unusable here, which is worth stating rather than
# discovering: PARITY.md carries 123 inherited findings and HANDOFF.md 6, and
# every lane edits PARITY.md in nearly every commit. A gate that goes red on
# arrival for the two most-edited files in the repo is a gate people learn to
# skip -- the same fate as the tree-wide command this replaces. So the rule is
# scoped to the LINES YOU ADDED OR CHANGED, which is exactly the boundary between
# a regression and the inherited floor.
#
# For a NEW file every line is added, so new files must be fully clean. The
# strong guarantee holds where it is achievable, and `--whole-file` asks for it
# anywhere.
#
# HOW THIS RELATES TO CI, NOW MEASURED. .github/workflows/main.yaml:30 calls
# VeryGoodOpenSource's spell_check.yml@v1, which forwards to
# streetsidesoftware/cspell-action@v8 with
# `incremental_files_only: ${{ inputs.modified_files_only }}` -- and that input
# DEFAULTS TO TRUE, unoverridden. So CI's job is incremental.
#
# THE OPEN QUESTION IS CLOSED, AND NOT IN THIS SCRIPT'S FAVOUR. This header used
# to say the per-file/per-line semantics could not be verified. The fork PR run
# (mml555/shorebird run 31986647895) settled it: the job reported
# `cspell.config.yaml:36 sendemail`, a PRE-EXISTING line this lane never touched,
# in a file it did touch. So:
#
#   CI's incremental job checks ENTIRE CHANGED FILES.
#   This script checks ADDED LINES.
#   Therefore a green here does NOT imply a green there -- this is the WEAKER
#   check, and it is a local regression pre-flight, not a CI predictor.
#
# That is still the right scope for a pre-flight, for the reason below: whole-file
# on PARITY.md would be red on arrival. But nobody should read a green from this
# script as CI clearance.
#
# (The other cspell job, shorebird_ci.yaml:235, does pass
# `incremental_files_only: false` -- but that workflow is DISABLED in this fork,
# per its own header. It does not run.)
#
# WHY NOT THE TREE-WIDE COMMAND. HANDOFF.md carried
# `npx cspell --no-progress --no-summary selfhost packages/code_push_server/lib`
# as if it were CI's. It never was. Tree-wide it reports ~1,770 findings across
# 153 files (baseline: evidence/cspell/), so it cannot separate a regression from
# the floor, and a check that is red before your change is not a gate.
#
# THE SILENT-SKIP HAZARD. cspell 10.0.1 prints "Files checked: 0, Issues found: 0"
# for a path it cannot resolve -- which a caller reading only the issue count sees
# as CLEAN. A file that was never examined must never read as one that passed, so
# every requested path is accounted for as CHECKED or IGNORED-BY-CONFIG, by name.
#
#   cspell_touched.sh                  # added/changed lines vs HEAD (default)
#   cspell_touched.sh --whole-file     # every line of every touched file
#   cspell_touched.sh --base <ref>     # changed since <ref>
#   cspell_touched.sh <path>...        # explicit paths, whole-file
#   cspell_touched.sh --self-test      # negative control: prove this gate can FAIL
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
CONFIG="$REPO/cspell.config.yaml"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# cspell 10 only resolves paths under its cwd, so everything runs from the repo
# root with repo-relative paths.
cd "$REPO"
[[ -f "$CONFIG" ]] || die "no cspell config at $CONFIG"

CHECKED=0
run_cspell() { # <file>... -> prints findings, sets CHECKED
  local out rc=0
  out=$(npx cspell --no-progress --config "$CONFIG" "$@" 2>&1) || rc=$?
  CHECKED=$(sed -n 's/.*Files checked: \([0-9]*\).*/\1/p' <<<"$out" | head -1)
  CHECKED=${CHECKED:-0}
  grep -v 'CSpell: Files checked:' <<<"$out" | grep -v '^[[:space:]]*$' || true
  return "$rc"
}

added_lines() { # <file> -> line numbers this change introduced, one per line
  if git ls-files --error-unmatch "$1" >/dev/null 2>&1; then
    git diff -U0 HEAD -- "$1" | awk '
      /^@@/ {
        match($0, /\+[0-9]+(,[0-9]+)?/)
        spec = substr($0, RSTART + 1, RLENGTH - 1)
        split(spec, a, ",")
        start = a[1] + 0; cnt = (a[2] == "" ? 1 : a[2] + 0)
        for (i = 0; i < cnt; i++) print start + i
      }'
  else
    awk '{ print NR }' "$1"   # untracked: the whole file is new
  fi
}

filter_to_lines() { # <findingsFile> <path> <lineSetFile> -> findings on those lines
  awk -v want="$2" -v setfile="$3" '
    BEGIN { while ((getline l < setfile) > 0) keep[l + 0] = 1 }
    {
      # "<path>:<line>:<col> - ..."
      n = index($0, ":"); if (n == 0) next
      p = substr($0, 1, n - 1); if (p != want) next
      rest = substr($0, n + 1)
      m = index(rest, ":"); if (m == 0) next
      ln = substr(rest, 1, m - 1) + 0
      if (ln in keep) print
    }' "$1"
}

self_test() {
  local d=".cspell-selftest"
  local rc arms_pass=0 arms_fail=0
  trap 'rm -rf "$REPO/$d"' RETURN
  rm -rf "$d"; mkdir -p "$d"

  arm() { # <label> <got> <want>
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1 -> $2"; arms_pass=$((arms_pass+1))
    else echo "  FAIL  $1 -> got [$2] want [$3]"; arms_fail=$((arms_fail+1)); fi
  }

  echo "this speling is rong deliberatly" > "$d/dirty.md"
  echo "the release cut cleanly and the patch applied" > "$d/clean.md"

  rc=0; run_cspell "$d/dirty.md" >/dev/null 2>&1 || rc=$?
  arm "a misspelling makes the gate RED" "$([[ $rc -ne 0 ]] && echo red || echo green)" "red"
  arm "...and the file was actually examined" "$CHECKED" "1"

  rc=0; run_cspell "$d/clean.md" >/dev/null 2>&1 || rc=$?
  arm "clean prose stays GREEN" "$([[ $rc -eq 0 ]] && echo green || echo red)" "green"

  rc=0; run_cspell "$d/does-not-exist.md" >/dev/null 2>&1 || rc=$?
  arm "an unresolvable path is NOT counted as checked" "$CHECKED" "0"

  # The line filter is what separates a regression from the inherited floor, so
  # it gets both directions. A filter that kept everything would make this gate
  # the unusable whole-file one; a filter that kept nothing would make it vacuous.
  printf 'f.md:10:1 - Unknown word (aaa)\nf.md:20:1 - Unknown word (bbb)\n' > "$d/findings"
  printf '10\n' > "$d/lines"
  arm "filter KEEPS a finding on an added line" \
    "$(filter_to_lines "$d/findings" f.md "$d/lines" | wc -l | tr -d ' ')" "1"
  printf '99\n' > "$d/lines"
  arm "filter DROPS a finding on an untouched line" \
    "$(filter_to_lines "$d/findings" f.md "$d/lines" | wc -l | tr -d ' ')" "0"

  echo
  echo "SELF-TEST PASS=$arms_pass FAIL=$arms_fail"
  [[ "$arms_fail" -eq 0 ]]
}

MODE=tree
SCOPE=added
BASE=""
declare -a EXPLICIT=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) MODE=selftest; shift ;;
    --whole-file) SCOPE=whole; shift ;;
    --base) BASE="${2:?}"; MODE=base; shift 2 ;;
    -h|--help) sed -n '3,52p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) EXPLICIT+=("$1"); MODE=explicit; SCOPE=whole; shift ;;
  esac
done

if [[ "$MODE" == selftest ]]; then
  note "self-test: does this gate discriminate?"
  self_test
  exit $?
fi

declare -a FILES=()
case "$MODE" in
  explicit) FILES=("${EXPLICIT[@]}") ;;
  base)
    while IFS= read -r f; do [[ -n "$f" ]] && FILES+=("$f"); done \
      < <(git diff --name-only "$BASE"...HEAD; git diff --name-only; git diff --cached --name-only)
    ;;
  tree)
    while IFS= read -r f; do [[ -n "$f" ]] && FILES+=("$f"); done \
      < <(git diff --name-only HEAD; git diff --cached --name-only; \
          git ls-files --others --exclude-standard)
    ;;
esac

declare -a WANT=()
if (( ${#FILES[@]} )); then
  while IFS= read -r f; do
    [[ -f "$f" ]] && WANT+=("$f")
  done < <(printf '%s\n' "${FILES[@]}" | sort -u)
fi

if (( ${#WANT[@]} == 0 )); then
  note "no touched files to check"
  exit 0
fi

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
note "checking ${#WANT[@]} touched file(s), scope=$SCOPE, against $CONFIG"

run_cspell "${WANT[@]}" > "$SCRATCH/all" 2>&1 || true

if [[ "$SCOPE" == whole ]]; then
  cp "$SCRATCH/all" "$SCRATCH/relevant"
else
  : > "$SCRATCH/relevant"
  for f in "${WANT[@]}"; do
    added_lines "$f" > "$SCRATCH/lines"
    filter_to_lines "$SCRATCH/all" "$f" "$SCRATCH/lines" >> "$SCRATCH/relevant"
  done
fi

INHERITED=$(( $(wc -l < "$SCRATCH/all") - $(wc -l < "$SCRATCH/relevant") ))
NEW=$(wc -l < "$SCRATCH/relevant" | tr -d ' ')

if (( NEW > 0 )); then cat "$SCRATCH/relevant"; fi

# ACCOUNTING: every requested path is CHECKED or IGNORED-BY-CONFIG, by name.
if (( CHECKED != ${#WANT[@]} )); then
  echo
  note "$CHECKED of ${#WANT[@]} requested file(s) examined; accounting for the rest"
  for f in "${WANT[@]}"; do
    run_cspell "$f" >/dev/null 2>&1 || true
    (( CHECKED == 0 )) && echo "    IGNORED BY CONFIG  $f"
  done
fi

echo
if [[ "$SCOPE" != whole ]] && (( INHERITED > 0 )); then
  note "$INHERITED pre-existing finding(s) on lines this change did not touch — not this change's debt (see evidence/cspell/)"
fi
if (( NEW == 0 )); then
  echo "PER-CHANGE SPELLING: GREEN — this change adds no new findings"
  exit 0
fi
echo "PER-CHANGE SPELLING: RED — $NEW new finding(s) on lines this change added"
echo "  fix the words, or add them per CLAUDE.md: inline 'cspell:words' for one"
echo "  or two files, cspell.config.yaml beyond that"
exit 1
