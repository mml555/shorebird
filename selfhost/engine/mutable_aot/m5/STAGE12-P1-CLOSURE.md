# STAGE 12 — P1 is the production default; #68 closure evidence

Status: **P1 ON by default, P3 OFF and retained as fallback.** m4 closure gate
green under the default configuration. Reported for re-closure; the disposition
is the PM's.

Fork `4c637705c880fb87a82d3fa87b3bb6bf963a26d6` (clean).

## 1. The four changes the ruling ordered

| # | change | where |
|---|---|---|
| 1 | P1 ON by default | `maotP1ClearMutableConstants` is `!= '0'` |
| 2 | P3 OFF by default, retained | `--maot_constant_escape_block`, default false |
| 3 | H04/H17 injection also disables P1 | shared `_FOLDING_OFF` in `gate_m4.py` |
| 4 | scale evidence regenerated under the new default | `m4/evidence/m4_scale.json` |

On (2): the flag was restated **positively** rather than left as a `disable_`
flag whose default became true. A double negative on a safety switch is how a
posture gets misread later — "disable_constant_escape_block = true" reads like
protection is on. `maot_constant_escape_block = false` says what is true.

## 2. Closure gate, default configuration

```
fork          4c637705c880fb87a82d3fa87b3bb6bf963a26d6
rules         10 optimizer classes
variants      tiny OLD-TINY -> NEW-TINY -> NEW-CONST | chain NEW-A
arms          19 (0 failed)
blocking      0
conditions    24 (0 failed)
PHASE A       arm64_aot_optimizer_invariants = ESTABLISHED
CLOSURE       issue_68_closure = READY
```

No `MAOT_EXTRA_SNAPSHOT_FLAGS`, no kernel env overrides: this is the shipped
posture measuring itself.

## 3. The regression passes through OBSERVATION, not refusal

```
folded.0        OLD-FOLDED
install.folded  0
folded.1        NEW-FOLDED
```

and no `constant-folding` decision is recorded anywhere in the default run, so
P3 is genuinely off rather than quietly still refusing.

The same at the m5 fixture, default configuration, nothing altering posture:

| arm | install | before | after |
|---|---|---|---|
| **CW** (the defect) | `0` | `OLD-CONTROL` | **`NEW-CONTROL`** |
| CD | `0` | `OLD` | `NEW` |
| ND | `0` | `OLD-ND` | `NEW-ND` |
| NW | `0` | `OLD-NW` | `NEW-NW` |
| CX | `0` | `OLD-XA/OLD-XB` | `NEW-XA/OLD-XB` |

## 4. The falsification arms are discriminating again

This is the part that mattered, because both arms were green-adjacent while
testing nothing. Before the repair they removed the two layers they knew about
and P1 silently removed the constant anyway:

| arm | before the repair (vacuous) | after |
|---|---|---|
| H04 | `0 escapes, install 0, call NEW-TINY` | `13 escapes, install -3, call OLD-TINY` |
| H17 all layers off | `install 0, caller NEW-CONST` | `install 0 SUCCEEDS, caller OLD-CONST` |

H17 now separates the layers exactly as it was built to:

```
baseline:            5 call sites, 0 constant-folding decisions, caller NEW-CONST
front end removed:  26 decisions, install -3            <- the VM backstop refusing
all layers removed:  0 decisions, install 0 SUCCEEDS and the caller
                     still returns OLD-CONST from 5 emitted call sites
```

The last line is the dangerous behaviour, mechanically produced. An arm that
cannot inject its defect cannot prove the gate detects it.

## 5. Ordinary constant propagation is untouched

Structural, in `_main`'s own final code, default configuration:

```
"PLAIN-CONST" @ pool #6512  (ordinary, NOT selected)  _main loads it: YES
"OLD-CONTROL" @ pool #624   (mutable, selected)       _main loads it: NO
```

Both halves of that control are `vm:never-inline`, so only constant
PROPAGATION — not inlining — can put a literal at the caller.

## 6. A size number that changed, and why

The scale lane under the shipped configuration:

```
selected 7,425   aot_elf_bytes 42,593,824
```

Earlier figures were measured with P3 also enabled, because it was the default
at the time:

| configuration | AOT bytes |
|---|---|
| P1 off, P3 on (old default) | 43,519,248 |
| P1 on, P3 on | 43,707,936 |
| **P1 on, P3 off (shipped)** | **42,593,824** |

The **+0.43%** P1 delta stands — both arms of that comparison had P3 on, so it
is a clean P1-vs-no-P1 measurement. What the third row adds is that the shipped
configuration is **925,424 bytes smaller than the previous default**, because
P3's `kForbidden` decision records were being serialised into the snapshot and
are now absent.

That is an observation about removing P3, not a benefit of P1, and it is not
claimed as one. A true P1-only production cost would need a (P1 off, P3 off)
baseline, which was not measured — the ruling accepted the scale result and
directed no further performance work.

## 7. Not claimed

- `super/unproven` stays blocking. The evidence indicates the earlier super
  failure was this constant-fold hole rather than super routing, but super has
  no clean production evidence yet.
- `MonomorphicSmiableCall` stays paused. Serializer parked. No #64 promotion.
- #69 trampoline work is untouched by this.
