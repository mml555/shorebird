#!/usr/bin/env bash
# cspell:words dbsnap
#
# epoch_b_progress.sh -- how far Epoch B is toward its precommitted threshold.
#
# THE ONE THING THIS MUST NOT DO IS SHOW A RATE EARLY. The decision Epoch B exists
# to inform is whether allowing one retry after a first ambiguous boot reduces
# expected user harm. With 2 or 5 clients a recovery ratio looks like an answer and
# is noise; someone would read "4/5 recovered" off a dashboard and act on it.
# `MEASUREMENT_MODE.md` sets the minimum at 100 DISTINCT clients with a first
# ambiguity, so the ratio stays suppressed until then. Counts are always shown --
# it is only the derived rate that is withheld.
#
# Reads a snapshot of the control plane's SQLite store; never writes.
set -uo pipefail

THRESHOLD=${THRESHOLD:-100}
CONTAINER=${CONTAINER:-cps-ios}
EPOCH_B_REV=${EPOCH_B_REV:-af6e842ccf87}
EPOCH_A_REV=${EPOCH_A_REV:-f729f958e9be}
SNAP=$(mktemp -d); trap 'rm -rf "$SNAP"' EXIT

for f in code_push.db code_push.db-shm code_push.db-wal; do
  docker cp "$CONTAINER:/data/$f" "$SNAP/$f" 2>/dev/null
done
[[ -f "$SNAP/code_push.db" ]] || { echo "cannot snapshot $CONTAINER:/data/code_push.db" >&2; exit 2; }

python3 - "$SNAP/code_push.db" "$THRESHOLD" "$EPOCH_B_REV" "$EPOCH_A_REV" <<'PY'
import sqlite3, sys
db, thresh, revb, reva = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
cur = sqlite3.connect(f"file:{db}?mode=ro", uri=True).cursor()

def one(q, *a):
    r = cur.execute(q, a).fetchone()
    return r[0] if r else 0

print("Epoch B progress")
print(f"  eligible revision   {revb}")
print(f"  threshold           {thresh} distinct clients with a FIRST ambiguity")
print()
transport = one("select count(distinct client_id) from events where updater_revision=?", revb)
print(f"  transport clients seen on {revb}: {transport}")
print("    (download/install events only -- this INCLUDES our own rig and probe")
print("     clients, so it is not fleet adoption. They can never enter the")
print("     estimator: every transport row has outcome NULL and the estimator")
print("     filters outcome IS NOT NULL.)")

first = one("select count(distinct client_id) from events where updater_revision=? "
            "and outcome='ambiguous_boot_retry' and ambiguous_attempt_count=1", revb)
second = one("select count(distinct client_id) from events where updater_revision=? "
             "and outcome='ambiguous_boot_retry' and ambiguous_attempt_count>=2", revb)
rec = one("select count(distinct client_id) from events where updater_revision=? "
          "and outcome='recovered_after_ambiguity'", revb)
ret = one("select count(distinct client_id) from events where updater_revision=? "
          "and outcome='retired_after_ambiguity'", revb)

print(f"  first ambiguity     {first} / {thresh}")
print(f"  second ambiguity    {second}")
print(f"  recovered           {rec}")
print(f"  retired             {ret}")
print()
if first < thresh:
    print(f"  RATE SUPPRESSED -- {thresh - first} more first-ambiguity clients needed.")
    print("  A recovery ratio computed now would be noise, and is exactly the number")
    print("  someone would act on. Counts above are safe to read; the ratio is not.")
else:
    print(f"  THRESHOLD REACHED. P(recovery | first ambiguity) = {rec}/{first}")
    print("  Ratification is still a deliberate decision, not an automatic one.")

# Contamination checks: anything that would quietly corrupt the sample.
print()
unknown = cur.execute(
    "select coalesce(updater_revision,'NULL'), count(distinct client_id) from events "
    "where outcome is not null and updater_revision is not in_list "
    .replace("is not in_list", f"not in ('{revb}','{reva}')") + " group by 1").fetchall()
if unknown:
    print("  UNEXPECTED revisions carrying lifecycle outcomes:")
    for rev, n in unknown:
        print(f"    {rev}  {n} distinct client(s)  <- neither epoch; investigate before ratifying")
else:
    print("  no lifecycle outcomes from unexpected revisions")

a_first = one("select count(distinct client_id) from events where updater_revision=? "
              "and outcome='ambiguous_boot_retry' and ambiguous_attempt_count=1", reva)
print(f"  Epoch A (closed, {reva}) first-ambiguity clients: {a_first}  -- never pooled")
PY
