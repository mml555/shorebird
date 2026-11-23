#!/usr/bin/env bash
# cspell:words dartaotruntime repack repacked
#
# mint_cell_v2.sh -- mint a successor v2 cell (macos-ios-android) whose only
# difference from a DONOR v2 cell is some Route B compiler-cell files, such as a
# rebuilt coverage analyzer. mint_route_b_cell.sh is the OLDER macos-ios scheme
# (8 files plus a few digests) and cannot produce or reproduce a v2 address.
#
#   mint_cell_v2.sh --donor <address> --donor-overlay <dir> --out <overlay> \
#       [--replace route_b_analyze.aot=<file>]... [--note <text>] [--evidence <dir>]
#   mint_cell_v2.sh --check --donor <address> --donor-overlay <dir>
#
# --donor          the donor cell's address. Its descriptor is read from
#                  cell_manifests/<address>.v2 (CELL_MANIFESTS overrides the dir).
# --donor-overlay  a directory in overlay layout holding the donor's 30 members,
#                  such as the cell-<hash8> release extracted (cell-<address>.tar).
# --replace        NAME=FILE, for a file of the compiler archive (dart2bytecode.aot,
#                  dartaotruntime, vm_platform.dill, route_b_analyze.aot,
#                  route_b_gen_kernel.aot, route_b_gen_dynamic_interface.aot,
#                  route_b_release_probe.aot, flutter_platform_strong.dill).
#                  Nothing else can be replaced.
# --out            an overlay dir to write the new cell into. It must not hold the
#                  new cell already. Never point it at selfhost/cdn/overlay by
#                  accident: this script refuses that path.
# --evidence       where the descriptor (<address>.v2), the address provenance and
#                  the delta report go (default: <out>.evidence).
#
# WHAT IT DOES
#   1. Authenticates the donor: the descriptor hashes to the donor address, and
#      every donor member, in canonical form, matches the descriptor.
#   2. Stages the 30 members as templates (the seven that carry the address are
#      canonicalized to %H by lib/v2_canonicalize.py, as stage_android_cell.sh does).
#   3. Rebuilds the compiler archive with the replacements (lib/v2_repack_compiler.py),
#      and refuses unless the ONLY archive entries that change are the replaced
#      ones plus PROVENANCE.txt, and the ONLY member that changes is the archive.
#   4. Runs the repo's own v2_transaction (address, render, verify, publish) into
#      --out. The PROVENANCE of the archive keeps naming the producer engine; the
#      address does not enter it.
#
# DETERMINISM. Same donor, same replacement bytes, same --note give the same
# archive and so the same address. The archive is repacked with fixed entry
# order, timestamps and modes carried over from the donor. With NO replacement the
# donor's archive bytes are reused as they are: Info-ZIP's output is not
# reproducible from Python, so the mint never re-zips what it does not change.
#
# --check (the acceptance test; writes only to a temp dir)
#   a. mints the donor from itself with no replacement and requires the donor's
#      own address, and every output member byte-identical to the donor overlay;
#   b. repacks the donor archive with its own members and requires every entry's
#      content identical (the bytes of the archive differ, by design: see above);
#   c. repacks twice with a changed analyzer and requires identical bytes.
#
# What this does NOT do: publish. It writes to --out only. Registering the
# descriptor in cell_manifests/, the CDN map, the Caddyfile, the selector commit
# and the ci-build promotion are separate steps for the owner.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
POLICY=${POLICY:-$SELFHOST/cdn/artifact_policy.conf}
CELL_MANIFESTS=${CELL_MANIFESTS:-$HERE/cell_manifests}

# The mint library declares DONOR, DRY, OVERLAY, MAP and friends and extracts a
# platform dill when FLUTTER_PLATFORM is unset; name nothing here like those
# (MC_ prefix) and give it a value it will not use.
FLUTTER_PLATFORM=unused MINT_CELL_LIB_ONLY=1 . "$HERE/mint_route_b_cell.sh"
set +e
set -u
die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

MC_DONOR=""; MC_DONOR_OVERLAY=""; MC_OUT=""; MC_EV=""; MC_NOTE=""; MC_CHECK=0
MC_REPL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --donor) MC_DONOR="${2:?}"; shift 2 ;;
    --donor-overlay) MC_DONOR_OVERLAY="${2:?}"; shift 2 ;;
    --out) MC_OUT="${2:?}"; shift 2 ;;
    --evidence) MC_EV="${2:?}"; shift 2 ;;
    --replace) MC_REPL+=("${2:?}"); shift 2 ;;
    --note) MC_NOTE="${2:?}"; shift 2 ;;
    --check) MC_CHECK=1; shift ;;
    -h|--help) sed -n '3,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$MC_DONOR" =~ ^[0-9a-f]{40}$ ]] || die "--donor <40-hex address> is required"
[[ -d "$MC_DONOR_OVERLAY" ]] || die "--donor-overlay <dir> is required (the donor's members in overlay layout)"
MC_DESC="$CELL_MANIFESTS/$MC_DONOR.v2"
[[ -f "$MC_DESC" ]] || die "no descriptor for the donor at $MC_DESC"

[[ "$(shasum -a 256 "$MC_DESC" | cut -c1-40)" == "$MC_DONOR" ]] \
  || die "descriptor $MC_DESC does not hash to $MC_DONOR"
MC_CELL=$(awk '$1=="cell"{print $2}' "$MC_DESC")
MC_FB=$(awk '$1=="fallback_engine_revision"{print $2}' "$MC_DESC")
[[ -n "$MC_CELL" && -n "$MC_FB" ]] || die "descriptor lacks cell or fallback_engine_revision"

MC_FILES="dart2bytecode.aot dartaotruntime vm_platform.dill route_b_analyze.aot route_b_gen_kernel.aot route_b_gen_dynamic_interface.aot route_b_release_probe.aot flutter_platform_strong.dill"
MC_ZIP='download.shorebird.dev/shorebird/%H/route-b-compiler-darwin-arm64.zip'

MC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mintcellv2.XXXXXX")
trap 'rm -rf "$MC_TMP"' EXIT

# stage_donor <stageDir>: the donor's members as templates, authenticated.
stage_donor() {
  local stage=$1 m src cell=$MC_CELL want got
  # Membership must be exactly what the descriptor lists, and what the policy asks.
  diff <(v2_members "$POLICY" "$cell") \
       <(awk 'NF==2 && $1!="address_schema" && $1!="cell" && $1!="fallback_engine_revision"{print $1}' "$MC_DESC" | sort -u) \
    >/dev/null || die "artifact_policy.conf members for $cell differ from the donor descriptor's"
  while IFS= read -r m; do
    src="$MC_DONOR_OVERLAY/${m//%H/$MC_DONOR}"
    [[ -f "$src" ]] || die "donor member missing: $src"
    mkdir -p "$stage/$(dirname "$m")"
    case "$(basename "$m")" in
      engine_stamp.json|artifacts_manifest.yaml|*.pom)
        v2_canonicalize "$src" "$MC_DONOR" > "$stage/$m" || die "canonicalization refused $m" ;;
      *) cp "$src" "$stage/$m" ;;
    esac
    want=$(awk -v k="$m" '$1==k{print $2}' "$MC_DESC")
    got=$(shasum -a 256 "$stage/$m" | cut -d' ' -f1)
    [[ "$want" == "$got" ]] || die "donor member does not match its descriptor digest: $m"
  done < <(v2_members "$POLICY" "$cell")
}

# mint <outOverlay> <evidenceDir> <replacement>...: returns the address on stdout.
mint() {
  local out=$1 ev=$2; shift 2
  local stage="$MC_TMP/stage.$$.$RANDOM" pair name file
  rm -rf "$stage"; mkdir -p "$stage"
  stage_donor "$stage" || exit 1
  if [[ $# -gt 0 ]]; then
    local args=() seen=" "
    for pair in "$@"; do
      name=${pair%%=*}; file=${pair#*=}
      [[ " $MC_FILES " == *" $name "* ]] || die "$name is not a compiler-archive file ($MC_FILES)"
      [[ "$seen" != *" $name "* ]] || die "$name replaced twice"
      seen+="$name "
      [[ -f "$file" ]] || die "no such replacement file: $file"
      args+=("$name=$file")
    done
    python3 "$HERE/lib/v2_repack_compiler.py" "$MC_DONOR_OVERLAY/${MC_ZIP//%H/$MC_DONOR}" \
      "$stage/$MC_ZIP.new" "${args[@]}" ${MC_NOTE:+--note "$MC_NOTE"} || die "repack refused"
    mv "$stage/$MC_ZIP.new" "$stage/$MC_ZIP"
    # Only the named entries and PROVENANCE.txt may differ inside the archive.
    python3 -I - "$MC_DONOR_OVERLAY/${MC_ZIP//%H/$MC_DONOR}" "$stage/$MC_ZIP" "${args[@]%%=*}" <<'PY' || die "the archive delta is not exactly the named files"
import sys, zipfile
a, b, names = zipfile.ZipFile(sys.argv[1]), zipfile.ZipFile(sys.argv[2]), set(sys.argv[3:]) | {'PROVENANCE.txt'}
assert [i.filename for i in a.infolist()] == [i.filename for i in b.infolist()], 'entry list changed'
changed = {i.filename for i in a.infolist() if a.read(i) != b.read(i.filename)}
assert changed == names, f'changed {sorted(changed)} expected {sorted(names)}'
PY
  fi
  # Only the archive may differ from the donor, as templates.
  local rel changed=()
  while IFS= read -r rel; do
    cmp -s "$stage/$rel" <(v2_donor_template "$rel") || changed+=("$rel")
  done < <(cd "$stage" && find . -type f | sed 's|^\./||' | sort)
  if [[ $# -eq 0 ]]; then
    [[ ${#changed[@]} -eq 0 ]] || die "no replacement named but members changed: ${changed[*]}"
  else
    [[ "${changed[*]}" == "$MC_ZIP" ]] || die "members changed other than the compiler archive: ${changed[*]}"
  fi
  mkdir -p "$ev"
  v2_transaction "$stage" "$POLICY" "$MC_CELL" "$MC_FB" "$out" "$ev"
}

# v2_donor_template <rel>: the donor's member in template form, for the delta check.
v2_donor_template() {
  local rel=$1 src="$MC_DONOR_OVERLAY/${1//%H/$MC_DONOR}"
  case "$(basename "$rel")" in
    engine_stamp.json|artifacts_manifest.yaml|*.pom) v2_canonicalize "$src" "$MC_DONOR" ;;
    *) cat "$src" ;;
  esac
}

if [[ "$MC_CHECK" == 1 ]]; then
  fails=0
  ok()  { printf '  PASS  %s\n' "$1"; }
  bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails+1)); }
  note "check a: re-mint the donor from itself, no replacement"
  A=$(mint "$MC_TMP/out-a" "$MC_TMP/ev-a") || { bad "mint failed"; A=""; }
  if [[ "$A" == "$MC_DONOR" ]]; then ok "address $A equals the donor"; else bad "address '$A' != donor $MC_DONOR"; fi
  n=0; diffs=0
  while IFS= read -r m; do
    n=$((n+1)); rel=${m//%H/$MC_DONOR}
    cmp -s "$MC_TMP/out-a/$rel" "$MC_DONOR_OVERLAY/$rel" || { diffs=$((diffs+1)); echo "    DIFFERS $rel"; }
  done < <(v2_members "$POLICY" "$MC_CELL")
  [[ "$n" -gt 0 && "$diffs" == 0 ]] && ok "$n of $n members byte-identical to the donor overlay" || bad "$diffs of $n members differ"
  note "check b: repack keeps every other entry, and is deterministic"
  Z="$MC_DONOR_OVERLAY/${MC_ZIP//%H/$MC_DONOR}"
  mkdir -p "$MC_TMP/zx" && unzip -q -o "$Z" -d "$MC_TMP/zx" || bad "cannot unzip the donor archive"
  python3 -I - "$Z" "$MC_TMP/zx/route_b_analyze.aot" "$HERE/lib/v2_repack_compiler.py" "$MC_TMP/b1.zip" "$MC_TMP/b2.zip" "$MC_TMP/b3.zip" <<'PY' && ok "entry contents survive a repack; two repacks of a changed analyzer are byte-identical" || bad "repack check"
import subprocess, sys, zipfile
donor, an, tool, b1, b2, b3 = sys.argv[1:7]
d = zipfile.ZipFile(donor)
# Same bytes in, PROVENANCE unchanged: the repack refuses an identical replacement,
# so exercise the copy path with a changed copy of an unrelated-length analyzer.
open(b1 + '.an', 'wb').write(d.read('route_b_analyze.aot') + b'\0')
for out in (b1, b2):
    subprocess.run([sys.executable, '-I', tool, donor, out, f'route_b_analyze.aot={b1}.an'], check=True)
x, y = zipfile.ZipFile(b1), zipfile.ZipFile(b2)
assert open(b1, 'rb').read() == open(b2, 'rb').read(), 'repack is not deterministic'
for i in d.infolist():
    if i.filename in ('route_b_analyze.aot', 'PROVENANCE.txt'):
        continue
    assert d.read(i) == x.read(i.filename), i.filename
    j = x.getinfo(i.filename)
    assert (i.date_time, i.external_attr, i.compress_type) == (j.date_time, j.external_attr, j.compress_type)
assert [i.filename for i in d.infolist()] == [i.filename for i in x.infolist()]
PY
  note "check c: the donor is not an accident; a changed analyzer must change the address"
  head -c 100 /dev/urandom > "$MC_TMP/fake.an"; cat "$MC_TMP/zx/route_b_analyze.aot" "$MC_TMP/fake.an" > "$MC_TMP/an2"
  C2=$(mint "$MC_TMP/out-c" "$MC_TMP/ev-c" "route_b_analyze.aot=$MC_TMP/an2") || { bad "mint with a replacement failed"; C2=""; }
  if [[ -n "$C2" && "$C2" != "$MC_DONOR" ]]; then ok "replacement mint gives $C2, not the donor"; else bad "replacement mint did not move the address"; fi
  [[ "$fails" == 0 ]] && { echo "CHECK PASSED"; exit 0; }
  echo "CHECK FAILED ($fails)"; exit 1
fi

[[ -n "$MC_OUT" ]] || die "--out <overlay dir> is required"
case "$(cd "$(dirname "$MC_OUT")" 2>/dev/null && pwd)/$(basename "$MC_OUT")" in
  "$SELFHOST/cdn/overlay"|"$SELFHOST/cdn/overlay/"*) die "--out is the repo's live overlay; mint into a scratch dir" ;;
esac
[[ ${#MC_REPL[@]} -gt 0 ]] || die "no --replace given: nothing to mint (use --check to re-mint the donor)"
MC_EV=${MC_EV:-$MC_OUT.evidence}
NEW=$(mint "$MC_OUT" "$MC_EV" "${MC_REPL[@]}") || die "mint failed (see above)"
[[ "$NEW" =~ ^[0-9a-f]{40}$ ]] || die "mint returned no address"
cp "$MC_EV/cell_manifest.v2" "$MC_EV/$NEW.v2"
[[ "$(shasum -a 256 "$MC_EV/$NEW.v2" | cut -c1-40)" == "$NEW" ]] || die "descriptor does not authenticate its own name"
echo
echo "donor     $MC_DONOR"
echo "address   $NEW"
echo "overlay   $MC_OUT"
echo "descriptor $MC_EV/$NEW.v2"
echo "delta vs donor descriptor:"
diff <(sed "s/^/  /" "$MC_DESC") <(sed "s/^/  /" "$MC_EV/$NEW.v2") | grep '^[<>]' | sed 's/^/  /' || true
