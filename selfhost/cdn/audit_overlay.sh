#!/usr/bin/env bash
# cspell:words pcell pathtpl SBDIR
# audit_overlay.sh — does our overlay actually own what we claim it owns?
#
# Answers the one question that "is it in the mirror?" cannot: for a given
# custom engine hash, which artifacts did WE produce, which are stock bytes we
# merely serve, which are stock bytes for a platform we do not build, and which
# are missing entirely.
#
#   selfhost/cdn/audit_overlay.sh --hash 760e3fab... --cell linux-android
#   selfhost/cdn/audit_overlay.sh --hash 70974f81... --cell macos-ios --emit-manifest
#
# Cross-checks THREE sources that can drift apart independently:
#   1. artifact_policy.conf  — what we say we own
#   2. the overlay on disk   — what is actually there
#   3. the Caddyfile         — what @must_be_local route-protects
#
# Drift between 1 and 2 is a missing artifact. Drift between 1 and 3 is worse:
# an artifact we believe we own but which is NOT route-protected falls through
# to the pinned hash and serves STOCK BYTES silently. That is the failure this
# script exists to make impossible to miss, and it cannot be seen by looking at
# the overlay alone — the bytes are absent from our disk and present in the
# response.
#
# Exit codes:  0 clean · 1 audit findings · 2 usage/environment error
#
# Deliberately pure bash + awk (no python, no PyYAML): this has to run on the
# Mac and on the Linux build box, and adding a dependency to the tool that
# verifies independence would be its own small joke.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
POLICY="$HERE/artifact_policy.conf"
OVERLAY="$HERE/overlay"
CADDYFILE="$HERE/Caddyfile"
HASH=""
CELL=""
EMIT_MANIFEST=0

usage() { sed -n '3,29p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hash) HASH="${2:?}"; shift 2 ;;
    --cell) CELL="${2:?}"; shift 2 ;;
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    --policy) POLICY="${2:?}"; shift 2 ;;
    --caddyfile) CADDYFILE="${2:?}"; shift 2 ;;
    --emit-manifest) EMIT_MANIFEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$HASH" ]] || { echo "ERROR: --hash is required" >&2; exit 2; }
[[ -n "$CELL" ]] || { echo "ERROR: --cell is required (macos-ios | linux-android)" >&2; exit 2; }
[[ "$CELL" == "macos-ios" || "$CELL" == "linux-android" ]] || {
  echo "ERROR: unknown cell '$CELL' (expected macos-ios or linux-android)" >&2; exit 2; }
[[ -r "$POLICY" ]] || { echo "ERROR: cannot read policy $POLICY" >&2; exit 2; }
[[ -d "$OVERLAY" ]] || { echo "ERROR: no overlay directory at $OVERLAY" >&2; exit 2; }

# The cell is NOT inferred from which artifacts happen to exist. Inferring it
# would make a half-published hash look like a different cell and quietly pass.
# It is an input on purpose.

# --- The route-protection regex, read from the Caddyfile itself --------------
# Extracted rather than duplicated: a copy here would drift the first time the
# Caddyfile changed, and a stale copy in the checker is worse than no checker.
ROUTE_RE="$(awk '/^[[:space:]]*path_regexp \^\/\(flutter_infra_release/ {
                   sub(/^[[:space:]]*path_regexp[[:space:]]+/, ""); print; exit }' "$CADDYFILE")"
if [[ -z "$ROUTE_RE" ]]; then
  echo "ERROR: could not find the @must_be_local path_regexp in $CADDYFILE." >&2
  echo "       If the matcher was renamed or reformatted, fix the awk above —" >&2
  echo "       do NOT paste a copy of the regex into this script." >&2
  exit 2
fi

route_owns() {  # route_owns <overlay-relative-path>
  # Paths are request URIs minus the leading slash, so put it back.
  printf '/%s' "$1" | grep -qE "$ROUTE_RE"
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FINDINGS="$WORK/findings"; : > "$FINDINGS"
ROWS="$WORK/rows"; : > "$ROWS"

n_built=0; n_mirrored=0; n_compat=0; n_denied=0
n_missing_required=0; n_missing_deferred=0; n_unprotected=0; n_overprotected=0; n_leaked=0

# --- Walk the policy ---------------------------------------------------------
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  pcell="$(printf '%s' "$line" | awk '{print $1}')"
  prov="$(printf '%s' "$line"  | awk '{print $2}')"
  req="$(printf '%s' "$line"   | awk '{print $3}')"
  pathtpl="$(printf '%s' "$line" | awk '{print $4}')"
  note="$(printf '%s' "$line" | awk '{ $1=$2=$3=$4=""; sub(/^[[:space:]]+/, ""); print }')"

  [[ "$pcell" == "both" || "$pcell" == "$CELL" ]] || continue

  # Two %H per Maven path, so substitute globally.
  path="$(printf '%s' "$pathtpl" | sed "s/%H/$HASH/g")"
  present=0; [[ -e "$OVERLAY/$path" ]] && present=1
  protected=0; route_owns "$path" && protected=1

  case "$prov" in
    owned-built)    n_built=$((n_built+1)) ;;
    owned-mirrored) n_mirrored=$((n_mirrored+1)) ;;
    compat-mirrored) n_compat=$((n_compat+1)) ;;
    none)           : ;;
    *) echo "ERROR: unknown provenance '$prov' for $path" >&2; exit 2 ;;
  esac
  [[ "$req" == "denied" ]] && n_denied=$((n_denied+1))

  # --- presence vs requirement ---
  case "$req:$present" in
    required:0)
      n_missing_required=$((n_missing_required+1))
      printf 'MISSING-REQUIRED  %s\n                  %s\n' "$path" "$note" >> "$FINDINGS" ;;
    deferred:0)
      n_missing_deferred=$((n_missing_deferred+1))
      printf 'deferred          %s\n                  %s\n' "$path" "$note" >> "$FINDINGS" ;;
    denied:1)
      # Something published bytes we promised never to serve. Worse than a
      # missing file: it is the silent toolchain mix the policy exists to stop.
      n_leaked=$((n_leaked+1))
      printf 'DENIED-BUT-PRESENT %s\n                  %s\n' "$path" "$note" >> "$FINDINGS" ;;
  esac

  # --- ownership vs routing ---
  # An owned artifact that is not route-protected is served from STOCK on a
  # miss instead of failing. This is the check that cannot be done by eye.
  case "$prov" in
    owned-built|owned-mirrored)
      # A `deferred` artifact is exempt: it is not built yet, and
      # route-protecting it NOW would 404 a fetch that currently falls through
      # to stock CORRECTLY. Protection has to arrive with the bytes, not before.
      if [[ $protected -eq 0 && "$req" != "deferred" ]]; then
        n_unprotected=$((n_unprotected+1))
        printf 'UNPROTECTED       %s\n                  owned by policy but @must_be_local does not match it: a miss serves STOCK bytes from the pinned hash instead of 404ing\n' "$path" >> "$FINDINGS"
        if [[ $present -eq 0 ]]; then
          printf '                  FIX ORDER: publish the bytes FIRST, then add the path to @must_be_local. Protecting an absent artifact 404s every build against this hash.\n' >> "$FINDINGS"
        fi
      fi ;;
    compat-mirrored)
      if [[ $protected -eq 1 ]]; then
        n_overprotected=$((n_overprotected+1))
        printf 'over-protected    %s\n                  policy says fall through to stock, but @must_be_local owns it, so a request 404s instead\n' "$path" >> "$FINDINGS"
      fi ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$prov" "$req" "$present" "$protected" "$note" >> "$ROWS"
done < "$POLICY"

# --- Report ------------------------------------------------------------------
echo "engine hash: $HASH"
echo "cell:        $CELL"
echo "overlay:     $OVERLAY"
echo
printf 'owned-built:       %d\n' "$n_built"
printf 'owned-mirrored:    %d\n' "$n_mirrored"
printf 'compat-mirrored:   %d\n' "$n_compat"
printf 'denied:            %d\n' "$n_denied"
printf 'missing-required:  %d\n' "$n_missing_required"

extra=""
[[ $n_missing_deferred -gt 0 ]] && extra="$extra deferred=$n_missing_deferred"
[[ $n_unprotected -gt 0 ]]      && extra="$extra unprotected=$n_unprotected"
[[ $n_overprotected -gt 0 ]]    && extra="$extra over-protected=$n_overprotected"
[[ $n_leaked -gt 0 ]]           && extra="$extra denied-but-present=$n_leaked"
[[ -n "$extra" ]] && printf 'also:             %s\n' "$extra"

if [[ -s "$FINDINGS" ]]; then
  echo
  echo "findings:"
  sed 's/^/  /' "$FINDINGS"
fi

# --- Optional: emit the provenance manifest (independence item 9) ------------
# This is what makes the manifest OURS rather than an upstream description of
# our hash. It is generated from the policy so the two cannot drift.
if [[ $EMIT_MANIFEST -eq 1 ]]; then
  SBDIR="$OVERLAY/download.shorebird.dev/shorebird/$HASH"
  mkdir -p "$SBDIR"
  OUT="$SBDIR/provenance.yaml"
  {
    echo "# GENERATED by selfhost/cdn/audit_overlay.sh — do not hand-edit."
    echo "# Provenance of every artifact served under this engine hash."
    echo "#"
    echo "# 'present: false' with 'provenance: compat-mirrored' is not a gap: it means"
    echo "# the request falls through to the pinned hash on purpose, for a platform we"
    echo "# do not build. Such an artifact NEVER supports a claim that the platform is"
    echo "# self-built. Check verified_for_custom_engine before believing anything."
    echo "engine_hash: $HASH"
    echo "cell: $CELL"
    echo "artifacts:"
    while IFS=$'\t' read -r path prov req present protected note; do
      [[ -n "$path" ]] || continue
      verified=false
      [[ "$prov" == "owned-built" && "$present" == "1" ]] && verified=true
      echo "  - path: $path"
      echo "    provenance: $prov"
      echo "    requirement: $req"
      echo "    present: $([[ "$present" == "1" ]] && echo true || echo false)"
      echo "    route_protected: $([[ "$protected" == "1" ]] && echo true || echo false)"
      echo "    verified_for_custom_engine: $verified"
      [[ -n "$note" ]] && echo "    reason: \"$(printf '%s' "$note" | sed 's/"/\\"/g')\""
    done < "$ROWS"
  } > "$OUT"
  echo
  echo "wrote $OUT"
fi

# missing-required and unprotected both break the independence claim; deferred
# and over-protected are tracked but do not fail, because something else is
# compensating and the note says what.
if [[ $n_missing_required -gt 0 || $n_unprotected -gt 0 || $n_leaked -gt 0 ]]; then
  echo
  echo "AUDIT FAILED for $HASH ($CELL)"
  exit 1
fi
echo
echo "AUDIT CLEAN for $HASH ($CELL)"
exit 0
