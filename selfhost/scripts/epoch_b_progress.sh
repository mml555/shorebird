#!/usr/bin/env bash
# cspell:words fetchall fetchone revb
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
# Comma-separated. B pools two updater behaviours since the owner extended it
# on 2026-11-07 (see PolicyEpoch.b in repository.dart); this list must match it.
EPOCH_B_REV=${EPOCH_B_REV:-af6e842ccf87,87c198d30f87}
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
revs_b = [r for r in revb.split(",") if r]
IN_B = "updater_revision in (%s)" % ",".join("?" * len(revs_b))

def one(q, *a):
    r = cur.execute(q, a).fetchone()
    return r[0] if r else 0

def one_b(q):
    """`one` over every Epoch B revision: q says updater_revision=? once."""
    return one(q.replace("updater_revision=?", IN_B), *revs_b)

print("Epoch B progress")
print(f"  eligible revision   {revb}")
print(f"  threshold           {thresh} distinct clients with a FIRST ambiguity")
print()
transport = one_b("select count(distinct client_id) from events where updater_revision=?")
print(f"  transport clients seen on {revb}: {transport}")
print("    (download/install events only -- this INCLUDES our own rig and probe")
print("     clients, so it is not fleet adoption. They can never enter the")
print("     estimator: every transport row has outcome NULL and the estimator")
print("     filters outcome IS NOT NULL.)")

first = one_b("select count(distinct client_id) from events where updater_revision=? "
            "and outcome='ambiguous_boot_retry' and ambiguous_attempt_count=1")
second = one_b("select count(distinct client_id) from events where updater_revision=? "
             "and outcome='ambiguous_boot_retry' and ambiguous_attempt_count>=2")
rec = one_b("select count(distinct client_id) from events where updater_revision=? "
          "and outcome='recovered_after_ambiguity'")
ret = one_b("select count(distinct client_id) from events where updater_revision=? "
          "and outcome='retired_after_ambiguity'")

print(f"  first ambiguity     {first} / {thresh}")
if len(revs_b) > 1:
    # B pools behaviours, so the split is part of reading it.
    for r in revs_b:
        n = one("select count(distinct client_id) from events where updater_revision=? "
                "and outcome='ambiguous_boot_retry' and ambiguous_attempt_count=1", r)
        print(f"    of which {r}: {n}")
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
    .replace("is not in_list", "not in (%s)" % ",".join(f"'{r}'" for r in revs_b + [reva])) + " group by 1").fetchall()
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
