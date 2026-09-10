<!-- cspell:words patchability unmodeled UNMODELED MAOT devirtualization -->

# MAOT-T0 (#64) — the universal patchability corpus and adversarial gate

**Status: the harness is established. `universal_dart_patchability = NOT_PROVEN`,
104 of 104 rows `UNMODELED`.** The Mutable-AOT mechanism does not exist yet —
#65 through #70 build it — so no row can be `PROVEN` and none is.

```bash
./run_t0.sh          # exits non-zero on any blocking finding or failed control
DART_SDK=<path> ./run_t0.sh
```

## It keeps no second list

The row set is read from [`../maot0/matrix.json`](../maot0/matrix.json). The
corpus check fails in **both** directions: an in-scope matrix row with no
fixture, and a fixture directory with no matrix row. There is no place here
where "what must work" is written down a second time.

104 fixtures: **14 executable**, 90 explicit placeholders. A placeholder is a
written `placeholder_reason`, never an absence — it reports `UNMODELED /
FIXTURE_MISSING` and can never report a pass.

## Dispatch forms are modes of a row, not rows

#64's minimum fixture families are finer-grained than #63's rows — virtual
call, interface call, `super` call, tear-off before and after the patch. They
are modelled here as **modes of one row**, and that is deliberate.

If `direct` and `virtual` were separate rows, an implementation that updated
direct calls and left virtual dispatch stale would report **50%** — a number.
As modes of one row it reports what it is: a **bypass** under #62's I2, and the
row does not pass. A row's dispatch correctness is satisfied only when every
applicable mode observes the current implementation.

| dimension | values |
|---|---|
| dispatch | `direct` `virtual` `interface` `super` `dynamic` `tearoff_pre` `tearoff_post` |
| optimizer | `jit`, `aot` (AOT snapshot: inlining, TFA, devirtualization on) |
| heat | `cold` (1 call), `hot` (20 000 calls, so caches are specialised) |

`EB-03` carries all seven dispatch forms against one declaration and runs in
all four optimizer×heat combinations — 28 observations for one row.

## What actually runs today

Real, and already useful before any mechanism exists:

* every executable fixture is **compiled in both optimizer modes and run cold
  and hot**;
* every dispatch mode's observation is checked against the value the fixture
  declares for the release program — a fixture that does not compile, does not
  behave as declared, or drops a declared mode is `INFRA_FAILURE`, never a pass;
* `expected_pre == expected_post` is refused at corpus level, because such a
  fixture could never tell a patched program from an unpatched one;
* `patch.dart` is compiled and run standalone and recorded as
  `patch_source_baseline` — proof the expectation is *achievable*, and never
  usable as a post-patch observation.

Then the `none` backend refuses installation with `NO_MECHANISM`, and the row
reports `UNMODELED`.

## The two backends, and why a double can never prove

`none` is the real backend and the only one whose results may count. `mock` is
a test double used **only** by the adversarial controls; it can be told to lie
in each named way. Both hand observations to the **same** `classify` — a
control that drove a parallel code path would measure that other path.

`classify` stamps any clean result from a non-real backend `MOCK_ONLY`, which
is absent from `RESULTS_COUNTING_AS_PROOF`, and the aggregate independently
refuses any proof-valued result whose `mechanism` is not `none`. Control `P2`
holds it: the *same* clean observations yield `PROVEN` for the real backend and
`MOCK_ONLY` for the mock.

## Controls — 15, in both directions

| id | what it holds |
|---|---|
| `P0` | the mock, told to behave, really does move every mode — else every A control below passes for the wrong reason |
| `P1` | the shared classifier returns `PROVEN` for clean real-backend observations: the verdict is **reachable** |
| `P2` | the same observations from the mock yield `MOCK_ONLY` |
| `A01` | installer reports success, slot unchanged → `FAIL_OPEN` |
| `A02`/`A02b` | direct updates, virtual/interface stale → bypass |
| `A03` | a pre-patch tear-off stays old |
| `A04` | the hot, specialised caller stays old — invisible to a cold-only harness |
| `A05` | a record this run did not stamp is incomplete, not last run's answer |
| `A06` | not running a row is not a way to finish it |
| `A07` | 99.04% proven is `NOT_PROVEN`, while nothing-short **does** reach `PROVEN` |
| `A08` | release/patch identities swapped |
| `A09`/`A09b` | a process restart, and the rebuilt-program baseline substituted for post |
| `A10` | every aggregate value names the decision that consumes it, both directions |

## Evidence is regenerated, never merged

`evidence/rows/` is cleared before every run and each record is stamped with
the run id; a record carrying any other stamp is refused. The driver proves
this destructively: it deletes `EB-01.json`, replaces `EB-03.json` with a
forged `PROVEN` record, re-runs, and asserts both come back correct.

## Known limitations

1. **No path evidence yet.** Answering "did this invocation *reach* the mutable
   mechanism" needs IR or runtime tracing from a mechanism that does not exist.
   `path_evidence.available` is `false` on every row and the field is carried so
   #67 fills it. **Behavioural agreement is not path evidence** — the record
   says so rather than leaving it to be assumed.
2. **90 rows are placeholders.** Every additive, type-shape, runtime-state and
   Flutter row is scaffolded, not executable. They are explicit and gated, but
   the corpus does not yet exercise them.
3. **Pre and post come from one process only in principle.** Today each mode
   combination is one process that observes `pre` and stops. The nonce check is
   written pairwise per `(optimizer, heat, dispatch)` so it stays correct once
   each process does pre → install → post itself.
4. **The toolchain is the stock SDK**, identified by revision
   `d684a576a6aa954ae107a03b2b4e1d61c3bebe93`, not the MAOT fork — which does
   not exist yet either.

## A trap worth carrying forward

`{'a','b'}` inside `$(...)` is **brace-expanded by bash** into separate words,
silently splitting one Python expression into several — each evaluated alone,
each giving a wrong answer. zsh does not do this, so it survives interactive
testing and appears only under the CI shell. Four assertions here were affected.
`run_t0.sh` now greps itself for the pattern and refuses to run, and the fix is
`set([...])`.
