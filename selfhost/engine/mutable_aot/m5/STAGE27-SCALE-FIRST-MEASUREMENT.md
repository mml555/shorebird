# STAGE27 — Task C first measurement: population is not the variable

Fork `1a20e5b12a2` (clean), stamped.
**Measurement only. No disposition, no default-on change, nothing enabled.**

## 1. Why this was run now

`--maot_install_trampolines` is OFF by default, and its own help text gives the
reason: *"the mechanism does not yet serialize above a small population."* That
sentence is the stated scale blocker, so the first thing Task C needs is to
find where serialization actually stops working.

## 2. The ladder

One program, 512 mutable declarations, **every body non-leaf** (each
interpolates, so each carries real static calls). One kernel, built once; only
`--maot_limit_selected` varies, so population size is the single independent
variable — editing the fixture per point would have varied the program and the
population at once.

| N | snapshot | installed/distinct | pinned bodies / non-leaf | secs | traversal |
|---|---|---|---|---|---|
| 1 | ok | 1/1 | 512/512 | 1.4 | PASS |
| 8 | ok | 8/8 | 512/512 | 1.5 | PASS |
| 64 | ok | 64/64 | 512/512 | 1.6 | PASS |
| 256 | ok | 256/256 | 512/512 | 1.7 | PASS |
| **512** | **ok** | **512/512** | 512/512 | 1.5 | PASS |

All distinct — no dedup collapse. Snapshot time is flat. The N=512 snapshot
also **runs**: `scale.count=512`, `scale.acc=3474`.

A first attempt at this ladder reported a flat pass with an **empty** installed
column, because that line is gated behind a flag I had not passed. A flat PASS
with no population count is not evidence about population; it is evidence the
population was never measured. Rerun with the counters exposed.

## 3. The negative control changes the question

`--maot_disable_pinned_body_roots` restores the pre-fix root-enumeration
behaviour:

| N | roots ON | roots OFF |
|---|---|---|
| 1 | ok | **FAIL rc=-6** |
| 2, 4, 8, 64, 512 | ok | **FAIL rc=-6** |

It fails at **N=1**. So for this fixture the failure is governed by whether a
selected body makes a static call, **not by how many declarations are
selected**. A larger population is merely likelier to contain a non-leaf body.

## 4. What is and is not claimed

**Measured:** on this build, 512 selected declarations with 512 distinct
trampolines serialize and run, with the traversal regression passing at every
point; and with the root-enumeration defect restored, the same program fails at
every N including 1.

**Not claimed:**

* That the original caveat is fully explained. It was written from observations
  I have not reproduced. What is shown is that the failure mode available here
  is body-shape governed, which is *consistent with* the caveat having been the
  STAGE20 defect seen through a population-sized lens — not proof of it.
* That this is production scale. 512 synthetic declarations in one library is
  not a Flutter application. Real scale means the framework and SDK surface
  selected together (`MAOT_SELECT_ALL_NON_SDK=1`), which is a materially
  larger and different test, and is the actual remaining Task C work.
* Anything about **default-on**. That is explicitly gated behind the #69
  disposition and the completion of scale work, and nothing here changes it.
  The flag remains off by default and its help text is left alone pending a
  ruling on what it should now say.

## 5. Remaining Task C work

1. Scale against a real application surface, not synthetic declarations.
2. Decide what the flag's help text should say, once (1) gives a defensible
   statement.
