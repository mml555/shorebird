#!/usr/bin/env bash
# cspell:words semantic linker falsifiability
# falsify.sh -- SEMANTIC-LINKER-1 / G6C. Prove the harness REFUSES when mandatory
# evidence is missing or mutated.
#
# THE MATRIX IS DERIVED, NEVER MAINTAINED. Both this script and reproduce.sh read
# the same file -- mandatory_evidence.json -- and neither carries a list or a
# count of its own. The first version of this script kept its own eight cases
# against the twelve items reproduce.sh enforced, and still printed
#
#     FALSIFIABILITY PASS -- every mandatory-evidence mutation is refused
#
# which was broader than what it had tested. Omitted then: the G4 unfenced
# transcript, both cost transcripts, and the G2 and G3 experiment patches. A
# claim that outruns its evidence is the defect this lane exists to refuse, so
# the equality is now asserted at run time:
#
#     inventory_count == falsified_count == caught_count
#
# Every item is additionally mutated a SECOND way (its `complementary` mutation)
# as a supplementary matrix beyond that equality; a supplementary miss also fails.
#
# Afterwards every original file must hash exactly as it did before, and the
# reporting path must return REPRODUCTION: PASS again -- otherwise this script
# has damaged the evidence set it was meant to test.
#
#   falsify.sh
#
# Exit: 0 every mutation refused and the evidence set restored · 1 otherwise
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RF="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
INV="$HERE/mandatory_evidence.json"
EVID="$HERE/evidence"; mkdir -p "$EVID"
LOG="$EVID/falsify.txt"
JSON="$EVID/falsification.json"
BK=$(mktemp -d); trap 'rm -rf "$BK"' EXIT

[[ -f "$INV" ]] || { echo "no mandatory-evidence inventory at $INV" >&2; exit 2; }
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
: > "$LOG"
say "SL1-G6C falsifiability -- mandatory evidence must not be optional"
say "date      : $(date -u +%FT%TZ)"
say "inventory : $(basename "$INV")"
say ""

# macOS ships bash 3.2: no mapfile and no associative arrays. Parallel indexed
# arrays instead, so the harness runs on the machine it is meant to run on.
ROWS=()
while IFS= read -r line; do ROWS+=("$line"); done < <(python3 -c "
import json,sys
for i in json.load(open(sys.argv[1]))['items']:
    print('%s|%s|%s|%s' % (i['id'], i['path'], i['mutation'], i['complementary']))" "$INV")
N=${#ROWS[@]}
say "inventory_count = $N"
say ""

# Hash every item BEFORE anything is touched, so restoration is verified against
# bytes rather than assumed from a successful cp.
BEFORE=()
for row in "${ROWS[@]}"; do
  IFS='|' read -r id path _ _ <<<"$row"
  f="$RF/$path"
  [[ -f "$f" ]] || { say "ABORT: inventory names a file that does not exist: $path"; exit 1; }
  BEFORE+=("$(shasum -a 256 "$f" | cut -d' ' -f1)")
done

mutate() { # <file> <kind>
  case "$2" in
    delete)   rm -f "$1" ;;
    corrupt)  printf 'THIS IS NOT VALID CONTENT\n' > "$1" ;;
    truncate) head -c 8 "$1" > "$1.t" && mv "$1.t" "$1" ;;
    *) return 1 ;;
  esac
}

FALSIFIED=0; CAUGHT=0; SUPP=0; SUPP_CAUGHT=0
RESULTS=()
for pass in required supplementary; do
  say "--- $pass mutations ---"
  for row in "${ROWS[@]}"; do
    IFS='|' read -r id path mut comp <<<"$row"
    m=$([[ "$pass" == required ]] && echo "$mut" || echo "$comp")
    f="$RF/$path"
    cp "$f" "$BK/bk" || { say "ABORT: cannot back up $path"; exit 1; }
    mutate "$f" "$m" || { say "ABORT: unknown mutation $m"; exit 1; }
    if bash "$HERE/reproduce.sh" --mode report-only >>"$LOG" 2>&1; then
      say "  NOT CAUGHT  $id ($m)"
      caught=false
    else
      say "  caught      $id ($m)"
      caught=true
    fi
    cp "$BK/bk" "$f" || { say "ABORT: cannot restore $path"; exit 1; }
    if [[ "$pass" == required ]]; then
      FALSIFIED=$((FALSIFIED+1)); [[ "$caught" == true ]] && CAUGHT=$((CAUGHT+1))
    else
      SUPP=$((SUPP+1)); [[ "$caught" == true ]] && SUPP_CAUGHT=$((SUPP_CAUGHT+1))
    fi
    RESULTS+=("{\"pass\":\"$pass\",\"id\":\"$id\",\"path\":\"$path\",\"mutation\":\"$m\",\"caught\":$caught}")
  done
  say ""
done

# Restoration, verified byte-for-byte.
RESTORE_BAD=0
i=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r id path _ _ <<<"$row"
  now=$(shasum -a 256 "$RF/$path" 2>/dev/null | cut -d' ' -f1)
  [[ "$now" == "${BEFORE[$i]}" ]] || { say "  RESTORE FAILED $path"; RESTORE_BAD=$((RESTORE_BAD+1)); }
  i=$((i+1))
done
[[ "$RESTORE_BAD" -eq 0 ]] && say "all $N originals restored byte-for-byte" || say "$RESTORE_BAD file(s) NOT restored"

FINAL_OK=false
if bash "$HERE/reproduce.sh" --mode report-only >>"$LOG" 2>&1; then
  R=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["result"]["REPRODUCTION"])' "$EVID/reproduction.json")
  [[ "$R" == PASS ]] && FINAL_OK=true
  say "post-restore report-only: REPRODUCTION=$R"
else
  say "post-restore report-only: FAILED"
fi

say ""
say "inventory_count=$N falsified_count=$FALSIFIED caught_count=$CAUGHT"
say "supplementary=$SUPP supplementary_caught=$SUPP_CAUGHT"
OK=0
[[ "$N" -eq "$FALSIFIED" && "$FALSIFIED" -eq "$CAUGHT" ]] || { say "EQUALITY FAILED: inventory_count == falsified_count == caught_count"; OK=1; }
[[ "$SUPP" -eq "$SUPP_CAUGHT" ]] || { say "SUPPLEMENTARY MISS: a complementary mutation was not refused"; OK=1; }
[[ "$RESTORE_BAD" -eq 0 ]] || OK=1
[[ "$FINAL_OK" == true ]] || { say "POST-RESTORE CHECK FAILED"; OK=1; }

python3 - "$JSON" "$N" "$FALSIFIED" "$CAUGHT" "$SUPP" "$SUPP_CAUGHT" "$RESTORE_BAD" "$FINAL_OK" "${RESULTS[@]}" <<'G6CFALS'
import json,sys
out,n,fals,caught,supp,suppc,restore_bad,final_ok = sys.argv[1:9]
rows=[json.loads(x) for x in sys.argv[9:]]
json.dump({'schema':'semantic-linker-1/g6c-falsification/1','gate':'SL1-G6C','issue':45,
  'inventory':'g6c_harness/mandatory_evidence.json',
  'inventory_count':int(n),'falsified_count':int(fals),'caught_count':int(caught),
  'equality_holds': int(n)==int(fals)==int(caught),
  'supplementary_count':int(supp),'supplementary_caught':int(suppc),
  'originals_restored': int(restore_bad)==0,
  'post_restore_reproduction_pass': final_ok=='true',
  'mutations':rows}, open(out,'w'), indent=2)
G6CFALS

[[ "$OK" -eq 0 ]] && say "FALSIFIABILITY PASS — every inventory item refused, both ways, and the evidence set restored" \
                  || say "FALSIFIABILITY FAIL"
exit "$OK"
