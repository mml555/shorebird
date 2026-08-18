# G15 Q2 — the success policy: PRECOMMIT

Written **before** the seven startup shapes are measured and before any seam code
exists, 2026-08-15. The table is not edited afterwards; results go in a separate
verdict file.

Q2 is the only architectural choice left in gate 4. Everything else about the
seam is settled (below), which is exactly why the choice must be made in the
open rather than emerge from whatever the instrumentation happens to do.

## The settled implementation contract — NOT under test here

1. Wrap the exact `userMainFunction` invocation (`hooks.dart:410/412`).
2. Capture its existing `Object?` return value — no signature change needed.
3. Catch synchronous failures at that lexical boundary.
4. If the return is a `Future`, observe its completion/failure there.
5. Preserve existing error semantics: report/forward and **rethrow**, never
   consume.
6. Do **not** move the seam upward — the returned-Future signal is discarded
   above `_runMain` (`isolate_patch.dart:292-299`).

**Qualification on Q4, carried forward so it cannot be over-read:** "ACHIEVABLE"
means completion can be *observed when it occurs*. It does not solve a
deliberately non-returning or indefinitely pending `main`. That case is not an
implementation gap; it is part of what Q2 must define.

## The naming rule, precommitted

If a return/completion condition is adopted, it will be named a
**return/completion policy**, and its earlier-than-first-frame semantics stated
explicitly in the patch, in `PARITY.md`, and in any verdict that cites it.
**"`main` returned successfully" will not be written, said, or implied to mean
"the app booted successfully."** `runApp` schedules the first frame; it does not
draw it. Describing a seam as proving more than it proves is precisely how
`Engine::Run`'s seam came to be believed, and that error is not to be repeated
one seam later.

## Candidate policies

| id | banks when |
|---|---|
| **A** | `main` returns a non-`Future`, **or** its returned `Future` completes with a value. (The user's options 1+2 — a pure return/completion policy.) |
| **B** | a later observable startup event — first frame rasterized. (Option 3.) |
| **C** | **earliest-of** A or B: whichever of "main completed" and "first frame drawn" happens first. (Option 4.) |
| **D** | A, plus a second banking condition for mains that have neither completed nor failed after some liveness signal. (Option 4, other shape.) |

## The seven startup shapes

| # | shape |
|---|---|
| S1 | `void main() { runApp(...); }` — returns synchronously, frame comes later |
| S2 | `Future<void> main() async { await x; runApp(...); }` — Future completes |
| S3 | `Future<void> main() async { await x; throw ...; }` — Future completes with error |
| S4 | `void main() { throw ...; }` before `runApp` — synchronous throw |
| S5 | `main` installs its own `runZonedGuarded` and handles its own error |
| S6 | `main` sets `PlatformDispatcher.onError` and returns `true` from it |
| S7 | `Future<void> main() async { runApp(...); await neverCompletes; }` — usable, never completes |

## PRECOMMITTED PREDICTIONS

`bank` = launch success recorded. `fail` = positive failure reported and patch
backed out. `never` = neither, so `0010`'s counter decides — which after two
boots means a **false backout**.

| shape | A | B | C | D |
|---|---|---|---|---|
| S1 good patch | bank (before any frame) | bank at frame | bank (A first) | bank |
| S2 good patch | bank | bank at frame | bank (whichever first) | bank |
| S3 bad patch | **fail** | never → false-ish | **fail** | **fail** |
| S4 bad patch | **fail** | never → false-ish | **fail** | **fail** |
| S5 good patch, error handled by app | bank | bank | bank | bank |
| S6 good patch, `onError` returns true | bank | bank | bank | bank |
| S7 good patch, never completes | **never → FALSE BACKOUT** | bank at frame | bank at frame | bank on liveness |
| headless good patch, no frame ever | bank | **never → FALSE BACKOUT** | bank (A first) | bank |

**Each policy's fatal cell is precommitted:** A dies on S7. B dies on headless
*and* is weak on S3/S4 (a Dart-phase failure that still somehow draws would bank).
C and D both survive the table on paper.

## What would disqualify each, stated before measuring

* **A** is disqualified if S7 is a shape real apps use. It is: `runApp` followed
  by awaiting a long-lived Future is legitimate and idiomatic.
* **B** is disqualified if any legitimate configuration never rasterizes — headless
  engines, add-to-app engines that never attach a view, `twoengine_app`'s second
  engine. G15 already has a two-engine gate, so this is not hypothetical.
* **C** is disqualified if "first frame" cannot be observed from a place the seam
  can reach without widening the false-backout window that `0010` was built to
  close, or if the two conditions can race such that a failure is banked as a
  success.
* **D** is disqualified if the liveness signal is a timer. **A timeout is not
  admissible**: it converts a slow-but-good boot into a tombstoned patch, which
  is the exact class of false backout this whole goal exists to prevent.

## Expected outcome, stated so a different result cannot be retrofitted

**C is expected to win**, because it is the only candidate that survives both S7
and the headless case without introducing a timer. **A is expected to be
sufficient for every shape except S7.**

If measurement shows A also fails S1, S2, S5 or S6 — i.e. the return/completion
signal is not observable in an ordinary shape — then the settled implementation
contract above is wrong and gate 4 reopens, not just Q2.

If C wins, the second banking condition it needs is *first frame*, which is the
candidate an earlier G15 sitting rejected for widening the false-backout window.
**That rejection was made before `0010` existed** and is explicitly reconsidered
here, not silently reversed: `0010`'s counter is what makes a wider window
survivable, and the two-engine gate already proved the counter works on device.

## What the host measurement may and may not settle

**MAY, with no engine change:** which of {sync return, Future success, Future
error, no completion} each of S1-S7 produces at the `userMainFunction(args)`
boundary. That is ordinary Dart semantics and needs no seam, no engine build and
no device.

**MAY NOT:** whether `PlatformDispatcher.onError` fires before or after the seam
would observe. That needs an instrumented engine, i.e. the seam itself. The
source argument in `runmain_seam_matrix.txt` stands on its own — `onError` fires
only for *unhandled* errors and a lexical `catch` preempts that classification —
and it is **not** to be reported as measured until an instrumented engine says so.

**Nothing here is a device result.** No arm of the three-arm hardware gate is
affected by this document.
