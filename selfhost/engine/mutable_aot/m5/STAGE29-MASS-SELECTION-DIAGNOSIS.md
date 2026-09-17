# STAGE29 — mass-selection serialization crash: diagnosis in progress

Fork `f75071133cf` (clean), stamped.
`REALAPP_MASS_SELECTION_SERIALIZATION = BLOCKED`. Root cause **not yet
reached**; this records what is established and what was refuted.

## 1. One coherent population (step 1/2 of the execution order)

Single run, all counters together, `shorebird_cli` +
`MAOT_SELECT_ALL_NON_SDK=1` + install ON:

```
selected  = 5098        installed = 5098      pinned bodies = 4473
eligible  = 4771        distinct  = 5098      non-leaf      = 4134
refused   =  327
selected-order sha256[:16] = 33324bf3becee1c9
```

Refusal reasons, reported separately rather than folded into a denominator:

| count | reason |
|---|---|
| 323 | the dispatch cell has no seeded global-pool entry, so the call site cannot name the same cell as the trampoline |
| 4 | a constant result was inferred for a mutable call |

`installed` (5098) exceeding `eligible` (4771) is not a contradiction: every
selected declaration receives a trampoline, while *eligible* counts those that
can additionally accept a replacement. The 625 gap between installed (5098) and
pinned bodies (4473) is **not yet explained** and is recorded as open.

## 2. The trigger is SELECTION, not #69 installation

`--maot_limit_selected` caps installed trampolines while selection stays at all
5098, so the ladder varied installation only:

| N | 1 | 64 | 512 | 1024 | 2048 | 4096 | full |
|---|---|---|---|---|---|---|---|
| result | CRASH | CRASH | CRASH | CRASH | CRASH | CRASH | CRASH |

**It crashes at N=1**, so this is not a population threshold in installed
trampolines. Separating the two variables:

| configuration | result |
|---|---|
| select-all + install ON (full) | CRASH |
| select-all + install ON, N=0 trampolines | CRASH |
| **select-all + install OFF** | **CRASH** |
| normal selection + install OFF | ok |

The crash reproduces with trampoline installation entirely disabled. **The #69
mechanism is not the trigger.** This is consistent with the PM's position that
#69 is not reopened.

## 3. Where it is not

```
VM snapshot: 5 clusters, all filled and completed
PREP END RelocateCodeObjects commands=11300
PREP END stackmap_scan total=11300 maps=5927
PREP STACKMAP_AUDIT maps=5927 null=0 wrong_cid=0 discarded_code=0
PREP END stackmap_sort
PREP bd.1 header_written      bytes=16
PREP bd.2 bsearch_reserved    bytes=90416
PREP bd.3 maps_written        bytes=288636
PREP bd.4 canonical_done      bytes=350053
PREP bd.5 bsearch_filled
PREP bd.6 stolen length=350053
PREP bd.7 added_to_data offset=64
PREP bd.8 instructions_table_done
```

The entire prepare phase — relocation, stackmap scan, sort, and the whole
instructions-table build — **completes**. The fault is downstream of it and
before the first program-snapshot cluster fill.

`si_addr` is stable for a given kernel: `0x617a696c61697265`, whose bytes are
ASCII `"erializa"`.

## 4. Two of my own readings, refuted

**"The fault is inside the stackmap scan."** Wrong. `PREP BEGIN stackmap_scan`
had **no matching END**, so a trace ending on it showed only that execution
reached the BEGIN. Adding the END showed the scan completes.

**"A collected stack map is invalid."** Refuted mechanically: 5927 maps, 0 null,
0 of the wrong class id, 0 discarded Code among 11300 commands.

The pattern worth naming: three successive marker rounds each moved the fault
later rather than landing on it, because a trace's last line reports where
**instrumentation** stops, not where **execution** stops. Every claim of
location here rests on a BEGIN/END pair, not on a final line.

## 5. Bracketing completed: the prepare phase runs to the end

Marker counts settle which pass dies:

```
POST BEGIN PrepareInstructions  2      (both passes)
POST END   PrepareInstructions  1      (pass 1 only)
PREP bd.8 / bd.9                2 each (both passes reach scope exit)
PASS END TraceLoop              2      (trace completes in both)
```

Pass 2 reaches `bd.9 scope_exited` — so the block's destructors
(`pc_mapping`, `writer_commands`, `stack_maps`, `stack_maps_info`) all ran —
and never reaches `POST END` in the caller. Between those two points there are
no statements left: `#endif`, a closing brace, and the return.

`MallocWriteStream::Steal` nulls `buffer_` and the destructor is
`free(nullptr)`, so the double-free theory is dead too.

**Marker bisection is therefore exhausted**: the interval no longer contains
code.

## 6. The crash class is different from what bisection assumed

The macOS crash report:

```
type:    EXC_BAD_ACCESS
subtype: EXC_ARM_DA_ALIGN at 0x617a696c61697265 -> 0x0000696c61697265
         (possible pointer authentication failure)
faulting frame:  ?   <no symbol>  +115914211684965
```

The program counter is unsymbolized at a nonsense offset. That is not a
statement dereferencing a bad value — it is **control transferred through a
bogus pointer**. Dart's own handler prints no stack; the frames above the
fault are only `segv_handler` → `abort`.

This reframes everything above: with a corrupted PC, "the last marker printed"
bounds when the corruption became fatal, **not where it was created**. The
value is deterministic for a given kernel (identical `si_addr` across every
run), so it is reproducible rather than random.

The remaining work is a memory-corruption / lifetime investigation, not a
declaration bisect — the Case B branch of the ruling. Chasing it further with
markers would keep producing intervals that contain no code.
