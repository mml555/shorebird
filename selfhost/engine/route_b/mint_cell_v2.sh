#!/usr/bin/env bash
# cspell:words dartaotruntime repack repacked mintcellv infolist getinfo outf cffaedfe notelf
#
# mint_cell_v2.sh -- mint a successor v2 cell (macos-ios-android) whose only
# difference from a DONOR v2 cell is some Route B compiler-cell files, such as a
# rebuilt coverage analyzer. mint_route_b_cell.sh is the OLDER macos-ios scheme
# (8 files plus a few digests) and cannot produce or reproduce a v2 address.
#
#   mint_cell_v2.sh --donor <address> --donor-overlay <dir> --out <overlay> \
#       [--replace route_b_analyze.aot=<file>]... --note <text> [--evidence <dir>]
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
#                  This script accepts only route_b_analyze.aot, route_b_gen_kernel.aot
#                  and dartaotruntime (each has a capability check below); the other
#                  files are refused until one exists.
# --note           REQUIRED with a real mint: one line, no control characters, what
#                  the replacement is and where it came from. It goes into the
#                  archive's PROVENANCE.txt, with the source sha256 and, for the
#                  analyzer, the analysisVersion the carried runtime reports.
# --out            an overlay dir to write the new cell into. It must not hold the
#                  new cell already. This script refuses any path at or under the
#                  selfhost/cdn/overlay of THIS checkout or of any other registered
#                  worktree of the same repository (a separate clone of it is NOT
#                  covered), after resolving symlinks and for
#                  directories that do not exist yet. It must be on the same
#                  volume as --evidence.
# --evidence       where the descriptor (<address>.v2), the address provenance,
#                  the toolchain record and the delta report go (default:
#                  <out>.evidence). The same overlay refusal applies.
#
# WHAT IT DOES
#   1. Authenticates the donor: the descriptor hashes to the donor address, and
#      every donor member, in canonical form, matches the descriptor.
#   2. Stages the 30 members as templates (the seven that carry the address are
#      canonicalized to %H by lib/v2_canonicalize.py, as stage_android_cell.sh does).
#   3. Gates the replacements: non-empty, the right executable format, and the
#      combination that would ship (runtime + gen_kernel + analyzer) is RUN, 60 s
#      each, output kept in <evidence>/gate.log: gen_kernel --help is gen_kernel,
#      the analyzer --help names the "Route B coverage analyzer" and
#      --patched-dill, and it reports an analysisVersion on a tiny AOT dill. This
#      is an IDENTITY check, not a trust boundary: it EXECUTES the files with your
#      privileges, anything that prints those strings passes, and the version in
#      PROVENANCE is the file's self-report. The inputs are your own build.
#   4. Rebuilds the compiler archive with the replacements (lib/v2_repack_compiler.py),
#      and refuses unless the ONLY archive entries that change are the replaced
#      ones plus PROVENANCE.txt, and the ONLY member that changes is the archive.
#      PROVENANCE.txt then SAYS the replaced file is not from the build its header
#      names (its "one logical artifact" and "never substitute" wording described
#      the original build; the repacked lines say what was substituted).
#   5. Runs the repo's own v2_transaction (address, render, verify, publish) into
#      --out, then rebuilds the manifest from what is in --out and requires it to
#      equal the one that was addressed.
#
# DETERMINISM, AND ITS LIMIT. Same donor, same replacement bytes, same --note and
# the same Python/zlib give the same archive and so the same address. The archive
# is repacked with fixed entry order, timestamps and modes carried over from the
# donor, but zlib's deflate output is allowed to differ between zlib versions, so
# a different machine may mint a different archive and a different address. The
# address is therefore not meant to be re-derived elsewhere: mint ONCE, verify,
# and publish that output. The evidence records the Python and zlib versions and
# the sha256 of the repacked archive. With NO replacement the donor's archive
# bytes are reused as they are: Info-ZIP's output is not reproducible from
# Python, so the mint never re-zips what it does not change.
#
# --check (the acceptance test; writes only to a temp dir)
#   a. mints the donor from itself with no replacement and requires the donor's
#      own address, and every output member byte-identical to the donor overlay.
#      This does NOT exercise the repack (nothing is replaced);
#   b. repacks the donor archive with a changed analyzer and requires: unzip -t
#      clean, every entry's content identical except the replaced one and
#      PROVENANCE.txt, Info-ZIP extracted modes identical to the donor's
#      (dartaotruntime still executable), every PROVENANCE digest line equal to
#      its entry, and two repacks byte-identical;
#   c. mints with a fixed changed analyzer (the gate that runs the analyzer is
#      bypassed here: the bytes are not a real analyzer) and requires the address
#      to move, and to be the same on every run;
#   d. the gate refuses an empty file, a non-ELF file, an ELF that is not the
#      analyzer (the donor's gen_kernel) and the runtime named as the analyzer, and
#      accepts the donor's own analyzer.
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
    -h|--help) awk 'NR>=3 { if ($0 ~ /^#/) print; else exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
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
MC_FINAL_DIR=""
trap 'rm -rf "$MC_TMP"; [[ -z "$MC_FINAL_DIR" ]] || rm -rf "$MC_FINAL_DIR"' EXIT

# resolve_path <p>: absolute, with every symlink resolved as far as the path
# exists, then the not-yet-existing tail appended. A tail with . or .. is refused.
resolve_path() {
  local p=$1 tail="" b real
  [[ "$p" == /* ]] || p="$PWD/$p"
  while [[ ! -e "$p" ]]; do
    [[ ! -L "$p" ]] || die "dangling symlink in path: $p"
    b=$(basename "$p")
    [[ "$b" != "." && "$b" != ".." ]] || die "path with . or .. in a part that does not exist yet: $1"
    tail="/$b$tail"; p=$(dirname "$p")
  done
  [[ -d "$p" ]] || die "not a directory: $p"
  real=$(cd -P "$p" && pwd -P) || die "cannot resolve $p"
  [[ "$real" != "/" ]] || real=""
  printf '%s%s\n' "$real" "$tail"
}

# not_live_overlay <flag> <path>: refuse at or under the selfhost/cdn/overlay of
# this checkout or of any worktree of this repository (the shared checkout too).
not_live_overlay() {
  local flag=$1 r root ov lr
  r=$(resolve_path "$2") || exit 1
  lr=$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    ov=$(resolve_path "$root/selfhost/cdn/overlay") || exit 1
    ov=$(printf '%s' "$ov" | tr '[:upper:]' '[:lower:]')
    if [[ "$lr" == "$ov" || "$lr" == "$ov"/* ]]; then
      die "$flag $2 is (under) a live overlay, $root/selfhost/cdn/overlay; mint into a scratch dir"
    fi
  done < <({ git -C "$SELFHOST" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'; echo "$SELFHOST/.."; })
  printf '%s\n' "$r"
}

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
    mkdir -p "$stage/$(dirname "$m")" || die "cannot create $stage/$(dirname "$m")"
    case "$(basename "$m")" in
      engine_stamp.json|artifacts_manifest.yaml|*.pom)
        v2_canonicalize "$src" "$MC_DONOR" > "$stage/$m" || die "canonicalization refused $m" ;;
      *) cp "$src" "$stage/$m" || die "cannot copy $src" ;;
    esac
    want=$(awk -v k="$m" '$1==k{print $2}' "$MC_DESC")
    got=$(shasum -a 256 "$stage/$m" | cut -d' ' -f1)
    [[ "$want" == "$got" ]] || die "donor member does not match its descriptor digest: $m"
  done < <(v2_members "$POLICY" "$cell")
}

# gate_replacements <note-out-file> <log-file> <name=file>...: what a replaced
# file must be. It is an IDENTITY check, not a trust boundary: it EXECUTES the
# replacement (an AOT snapshot is arbitrary code with the operator's privileges,
# bounded to 60 s each) and passes anything that prints the right strings. The
# inputs are the operator's own build. stderr and stdout of every run go to
# <log-file>. Writes the PROVENANCE note text (the self-reported analysisVersion)
# to <note-out-file>.
MC_REPLACEABLE="route_b_analyze.aot route_b_gen_kernel.aot dartaotruntime"
mc_run() { perl -e 'alarm shift; exec @ARGV or exit 127' 60 "$@"; }
gate_replacements() {
  local outf=$1 log=$2; shift 2
  local pair name file g="$MC_TMP/gate.$RANDOM" magic help ver
  : > "$outf"; : > "$log"
  mkdir -p "$g" || die "cannot create $g"
  unzip -q -o "$MC_DONOR_OVERLAY/${MC_ZIP//%H/$MC_DONOR}" -d "$g" || die "cannot unzip the donor archive"
  for pair in "$@"; do
    name=${pair%%=*}; file=${pair#*=}
    [[ " $MC_REPLACEABLE " == *" $name "* ]] \
      || die "$name cannot be replaced by this script: no capability check exists for it (replaceable: $MC_REPLACEABLE)"
    [[ -s "$file" ]] || die "replacement $name is empty: $file"
    magic=$(head -c 4 "$file" | od -An -tx1 | tr -d ' \n')
    if [[ "$name" == dartaotruntime ]]; then
      [[ "$magic" == cffaedfe ]] || die "$name is not a 64-bit little-endian Mach-O executable: $file"
    else
      [[ "$magic" == 7f454c46 ]] || die "$name is not an ELF AOT snapshot: $file"
    fi
    cp "$file" "$g/$name" || die "cannot copy $file"
  done
  chmod +x "$g/dartaotruntime"
  # The combination that will ship must work: the (possibly new) runtime has to
  # run the (possibly new) gen_kernel and analyzer, which are version-locked.
  help=$(mc_run "$g/dartaotruntime" "$g/route_b_gen_kernel.aot" --help 2>>"$log") || true
  [[ "$help" == *"Compiles Dart sources to a kernel binary"* && "$help" == *"--platform"* ]] \
    || die "route_b_gen_kernel.aot run with the archive's dartaotruntime is not gen_kernel (see $log)"
  help=$(mc_run "$g/dartaotruntime" "$g/route_b_analyze.aot" --help 2>>"$log") || true
  [[ "$help" == *"Route B coverage analyzer"* && "$help" == *"--patched-dill"* ]] \
    || die "route_b_analyze.aot run with the archive's dartaotruntime is not the Route B coverage analyzer (--help lacks its name or --patched-dill; see $log)"
  printf 'void main() {}\n' > "$g/tiny.dart"
  mc_run "$g/dartaotruntime" "$g/route_b_gen_kernel.aot" --aot --platform "$g/vm_platform.dill" -o "$g/tiny.dill" "$g/tiny.dart" >>"$log" 2>&1 \
    || die "route_b_gen_kernel.aot could not compile a tiny AOT dill (see $log)"
  ver=$(mc_run "$g/dartaotruntime" "$g/route_b_analyze.aot" --base-dill "$g/tiny.dill" --patched-dill "$g/tiny.dill" 2>>"$log" \
    | python3 -I -c 'import json,sys; print(int(json.load(sys.stdin)["analysisVersion"]))') \
    || die "route_b_analyze.aot did not report an analysisVersion on a tiny dill (see $log)"
  printf '; analysisVersion %s as reported by the file when run with the carried dartaotruntime (self-report, not verified)' "$ver" >> "$outf"
  echo "gate: runtime, gen_kernel and analyzer run together; analyzer reports analysisVersion $ver (self-report)" >&2
  rm -rf "$g"
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
    [[ -n "$MC_NOTE" ]] || die "--note is required with a replacement"
    local extra="$MC_TMP/gate.note"
    mkdir -p "$ev" || die "cannot create $ev"
    # Gate bypass exists for --check's address-sensitivity probe only.
    if [[ "$MC_CHECK" == 1 && "${MC_GATE:-1}" == 0 ]]; then
      : > "$extra"
    else
      gate_replacements "$extra" "$ev/gate.log" "${args[@]}" || exit 1
    fi
    python3 -I "$HERE/lib/v2_repack_compiler.py" "$MC_DONOR_OVERLAY/${MC_ZIP//%H/$MC_DONOR}" \
      "$stage/$MC_ZIP.new" "${args[@]}" --note "$MC_NOTE$(cat "$extra")" || die "repack refused"
    mv "$stage/$MC_ZIP.new" "$stage/$MC_ZIP" || die "cannot move the repacked archive into the stage"
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
  mkdir -p "$ev" || die "cannot create $ev"
  v2_transaction "$stage" "$POLICY" "$MC_CELL" "$MC_FB" "$out" "$ev" || die "transaction failed"
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
  A=$(mint "$MC_TMP/out-a" "$MC_TMP/ev-a") || { bad "mint failed"; A=""; rm -rf "$MC_TMP/ev-a/final"; }
  if [[ "$A" == "$MC_DONOR" ]]; then ok "address $A equals the donor"; else bad "address '$A' != donor $MC_DONOR"; fi
  n=0; diffs=0
  while IFS= read -r m; do
    n=$((n+1)); rel=${m//%H/$MC_DONOR}
    cmp -s "$MC_TMP/out-a/$rel" "$MC_DONOR_OVERLAY/$rel" || { diffs=$((diffs+1)); echo "    DIFFERS $rel"; }
  done < <(v2_members "$POLICY" "$MC_CELL")
  if [[ "$n" -gt 0 && "$diffs" == 0 ]]; then ok "$n of $n members byte-identical to the donor overlay"; else bad "$diffs of $n members differ"; fi
  note "check b: a repack is sound, keeps every other entry, and is deterministic"
  Z="$MC_DONOR_OVERLAY/${MC_ZIP//%H/$MC_DONOR}"
  mkdir -p "$MC_TMP/zx" "$MC_TMP/zb"
  unzip -q -o "$Z" -d "$MC_TMP/zx" || bad "cannot unzip the donor archive"
  if python3 -I - "$Z" "$MC_TMP/zx/route_b_analyze.aot" "$HERE/lib/v2_repack_compiler.py" "$MC_TMP/b1.zip" "$MC_TMP/b2.zip" <<'PY'
import hashlib, subprocess, sys, zipfile
donor, an, tool, b1, b2 = sys.argv[1:6]
sha = lambda b: hashlib.sha256(b).hexdigest()
d = zipfile.ZipFile(donor)
open(b1 + '.an', 'wb').write(d.read('route_b_analyze.aot') + b'\0')
for out in (b1, b2):
    subprocess.run([sys.executable, '-I', tool, donor, out, f'route_b_analyze.aot={b1}.an', '--note', 'check b'], check=True)
x = zipfile.ZipFile(b1)
assert open(b1, 'rb').read() == open(b2, 'rb').read(), 'repack is not deterministic'
assert [i.filename for i in d.infolist()] == [i.filename for i in x.infolist()], 'entry list changed'
for i in d.infolist():
    if i.filename in ('route_b_analyze.aot', 'PROVENANCE.txt'):
        continue
    assert d.read(i) == x.read(i.filename), i.filename
    j = x.getinfo(i.filename)
    assert (i.date_time, i.external_attr, i.compress_type, i.internal_attr) == (j.date_time, j.external_attr, j.compress_type, j.internal_attr), i.filename
# Every PROVENANCE digest line equals its entry, in the donor and in the repack.
for z in (d, x):
    lines = z.read('PROVENANCE.txt').decode().split('\n')
    for i in z.infolist():
        if i.filename == 'PROVENANCE.txt':
            continue
        hits = [l for l in lines if l.split(':')[0].strip() == i.filename]
        assert len(hits) == 1 and hits[0].split(':', 1)[1].strip() == sha(z.read(i)), 'PROVENANCE digest line: ' + i.filename
PY
  then ok "contents, attributes, PROVENANCE digests (all entries) and determinism"; else bad "repack check (python)"; fi
  if unzip -tq "$MC_TMP/b1.zip" >/dev/null && unzip -q -o "$MC_TMP/b1.zip" -d "$MC_TMP/zb"; then
    modes=0
    for f in $(cd "$MC_TMP/zx" && ls); do
      [[ "$(stat -f %Lp "$MC_TMP/zx/$f")" == "$(stat -f %Lp "$MC_TMP/zb/$f")" ]] || { modes=1; echo "    MODE DIFFERS $f"; }
    done
    if [[ "$modes" == 0 && -x "$MC_TMP/zb/dartaotruntime" ]]; then ok "unzip -t clean; Info-ZIP extracted modes equal the donor's; dartaotruntime executable"; else bad "extracted modes"; fi
  else bad "unzip -t / extraction of the repacked archive"; fi
  note "check c: a changed analyzer must change the address, the same way every time"
  { cat "$MC_TMP/zx/route_b_analyze.aot"; printf 'mint_cell_v2 check c\n'; } > "$MC_TMP/an2"
  C2=$(MC_GATE=0 MC_NOTE="check c (not a real analyzer; gate bypassed)" mint "$MC_TMP/out-c" "$MC_TMP/ev-c" "route_b_analyze.aot=$MC_TMP/an2") || { bad "mint with a replacement failed"; C2=""; }
  C3=$(MC_GATE=0 MC_NOTE="check c (not a real analyzer; gate bypassed)" mint "$MC_TMP/out-c2" "$MC_TMP/ev-c2" "route_b_analyze.aot=$MC_TMP/an2") || C3=""
  if [[ -n "$C2" && "$C2" != "$MC_DONOR" && "$C2" == "$C3" ]]; then ok "replacement mint gives $C2 (twice), not the donor"; else bad "replacement mint: '$C2' '$C3'"; fi
  note "check d: the gate refuses what is not the analyzer"
  : > "$MC_TMP/empty"; printf 'x' > "$MC_TMP/notelf"
  for neg in "empty=$MC_TMP/empty" "non-ELF=$MC_TMP/notelf" "gen_kernel-as-analyzer=$MC_TMP/zx/route_b_gen_kernel.aot" "runtime-as-analyzer=$MC_TMP/zx/dartaotruntime"; do
    if ( gate_replacements "$MC_TMP/d.note" "$MC_TMP/d.log" "route_b_analyze.aot=${neg#*=}" ) >/dev/null 2>"$MC_TMP/d.err"; then
      bad "gate accepted ${neg%%=*}"
    else ok "gate refused ${neg%%=*}: $(tail -1 "$MC_TMP/d.err" | cut -c1-110)"; fi
  done
  if ( gate_replacements "$MC_TMP/d.note" "$MC_TMP/d.log" "route_b_analyze.aot=$MC_TMP/zx/route_b_analyze.aot" ) >/dev/null 2>&1; then
    ok "gate accepted the donor's own analyzer ($(cat "$MC_TMP/d.note" | cut -c3-30))"; else bad "gate refused the donor's own analyzer"; fi
  if ( gate_replacements "$MC_TMP/d.note" "$MC_TMP/d.log" "route_b_release_probe.aot=$MC_TMP/zx/route_b_release_probe.aot" ) >/dev/null 2>&1; then
    bad "gate accepted a file without a capability check"; else ok "gate refused a file without a capability check"; fi
  [[ "$fails" == 0 ]] && { echo "CHECK PASSED"; exit 0; }
  echo "CHECK FAILED ($fails)"; exit 1
fi

[[ -n "$MC_OUT" ]] || die "--out <overlay dir> is required"
[[ ${#MC_REPL[@]} -gt 0 ]] || die "no --replace given: nothing to mint (use --check to re-mint the donor)"
[[ -n "$MC_NOTE" ]] || die "--note is required: say what the replacement is and where it came from"
python3 -I -c 'import sys; sys.exit(any(ord(c) < 32 or 0x7f <= ord(c) <= 0x9f or ord(c) in (0x2028, 0x2029) for c in sys.argv[1]))' "$MC_NOTE" \
  || die "--note must be one line without control or line-separator characters"
MC_EV=${MC_EV:-$MC_OUT.evidence}
MC_OUT=$(not_live_overlay --out "$MC_OUT") || exit 1
MC_EV=$(not_live_overlay --evidence "$MC_EV") || exit 1
[[ "$MC_OUT" != "$MC_EV" && "$MC_OUT" != "$MC_EV"/* && "$MC_EV" != "$MC_OUT"/* ]] || die "--out and --evidence must be separate directories"
MC_DO=$(resolve_path "$MC_DONOR_OVERLAY") || exit 1
[[ "$MC_OUT" != "$MC_DO" && "$MC_OUT" != "$MC_DO"/* && "$MC_DO" != "$MC_OUT"/* ]] || die "--out and --donor-overlay must be separate directories"
# The rendered working copy is moved into --out: same volume, or it would be a copy.
MC_OUT_NEW=0; [[ -e "$MC_OUT" ]] || MC_OUT_NEW=1
mkdir -p "$MC_OUT" "$MC_EV" || die "cannot create --out / --evidence"
MC_FINAL_DIR="$MC_EV/final"   # set here, in the parent, so the EXIT trap (also on SIGINT/SIGTERM) removes it
trap 'rm -rf "$MC_TMP" "$MC_FINAL_DIR"; exit 130' INT TERM
# Remove what this run put in --out (the address-named roots), and the directories it created.
cleanup_out() {
  [[ -z "${NEW:-}" ]] || find "$MC_OUT" -depth -type d -name "*$NEW*" -prune -exec rm -rf {} + 2>/dev/null
  [[ "$MC_OUT_NEW" == 0 ]] || find "$MC_OUT" -depth -type d -empty -delete 2>/dev/null
  return 0
}
[[ "$(stat -f %d "$MC_OUT")" == "$(stat -f %d "$MC_EV")" ]] || die "--out and --evidence are on different volumes; the move into --out would not be atomic"
NEW=$(mint "$MC_OUT" "$MC_EV" "${MC_REPL[@]}") || { rm -rf "$MC_EV/final"; NEW=""; cleanup_out; die "mint failed (see above)"; }
rm -rf "$MC_EV/final"
[[ "$NEW" =~ ^[0-9a-f]{40}$ ]] || die "mint returned no address"
cp "$MC_EV/cell_manifest.v2" "$MC_EV/$NEW.v2" || die "cannot write the descriptor"
[[ "$(shasum -a 256 "$MC_EV/$NEW.v2" | cut -c1-40)" == "$NEW" ]] || die "descriptor does not authenticate its own name"

verify_out() (
# Verify what is IN --out, not what was rendered: rebuild the manifest from it.
VS="$MC_TMP/verify"; mkdir -p "$VS" || die "cannot create $VS"
while IFS= read -r m; do
  f="$MC_OUT/${m//%H/$NEW}"
  [[ -f "$f" ]] || die "after the move, --out lacks $m"
  mkdir -p "$VS/$(dirname "$m")" || die "mkdir"
  case "$(basename "$m")" in
    engine_stamp.json|artifacts_manifest.yaml|*.pom) v2_canonicalize "$f" "$NEW" > "$VS/$m" || die "canonicalization refused $m in --out" ;;
    *) ln -s "$f" "$VS/$m" || die "ln" ;;
  esac
done < <(v2_members "$POLICY" "$MC_CELL")
v2_manifest "$VS" "$POLICY" "$MC_CELL" "$MC_FB" > "$MC_TMP/out.manifest" || die "manifest from --out refused"
cmp -s "$MC_TMP/out.manifest" "$MC_EV/cell_manifest.v2" || die "--out does not hold the cell that was addressed (manifest rebuilt from --out differs); the cell was removed from --out"
)
verify_out || { cleanup_out; die "verification of --out failed; the new cell was removed from --out so a re-run is not blocked"; }
ZIPOUT="$MC_OUT/${MC_ZIP//%H/$NEW}"
{
  echo "repacked archive sha256  $(shasum -a 256 "$ZIPOUT" | cut -d' ' -f1)"
  echo "python                   $(python3 -I -c 'import sys; print(sys.version.split()[0])')"
  echo "zlib                     $(python3 -I -c 'import zlib; print(zlib.ZLIB_RUNTIME_VERSION)')"
  echo "note                     $MC_NOTE"
  echo "donor                    $MC_DONOR"
  echo "address                  $NEW"
  echo "Archive bytes depend on this python/zlib: publish THIS output, do not re-mint elsewhere."
} > "$MC_EV/repack_toolchain.txt"
echo
echo "donor     $MC_DONOR"
echo "address   $NEW   (verified: the manifest rebuilt from --out equals the addressed one)"
echo "overlay   $MC_OUT"
echo "descriptor $MC_EV/$NEW.v2"
echo "toolchain  $MC_EV/repack_toolchain.txt"
echo "delta vs donor descriptor:"
diff <(sed "s/^/  /" "$MC_DESC") <(sed "s/^/  /" "$MC_EV/$NEW.v2") | grep '^[<>]' | sed 's/^/  /' || true
