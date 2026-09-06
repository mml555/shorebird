<!-- cspell:words dartaotruntime dill semantic linker devirtualization -->
# SL1-G6B — substrate, interface, module and execution costs

**Gate:** [#44](https://github.com/mml555/shorebird/issues/44) · **Run:** 2026-09-06
**Verdict: four families reported independently. No production threshold imposed.**

Transcript: [`evidence/costs.txt`](evidence/costs.txt).
Raw per-rep samples retained: [`evidence/raw_samples.txt`](evidence/raw_samples.txt).
Reproduce: `run_costs.sh` (`ITERS`, `REPS` overridable).

## Family A — runtime substrate (Dynamic Modules OFF vs ON, before any load)

What every build pays, whether or not a module is ever loaded.

| artifact | OFF | ON | delta |
|---|---:|---:|---:|
| `dartaotruntime` | 6,297,392 | 6,471,040 | **+2.76%** |
| `gen_snapshot` | 6,875,632 | 7,007,248 | +1.91% |
| `dart-sdk/bin/dart` | 5,364,224 | 5,537,856 | +3.24% |
| `vm_platform.dill` | 8,270,936 | 8,270,936 | **0.00%** |

The number that matters for a shipped app is `dartaotruntime`: **+2.76%**, about
174 KB. The platform dill is byte-identical, so the substrate costs nothing in
the kernel.

**Normal AOT performance: no measurable difference.** A never-inline call loop
(20M iterations, no boundary touched), 15 reps per arm **interleaved** rather
than arm-by-arm so machine drift cannot masquerade as an arm difference:

    dm_off  median 24.2 ms   min 20.0   max 51.0   stdev 9.1
    dm_on   median 22.0 ms   min 20.3   max 60.6   stdev 12.2

The medians differ by ~9% in ON's favour, which is **not a real result** — the
per-arm standard deviation (9–12 ms) is several times the difference between the
medians. The honest statement is that this rig cannot resolve a difference of
this size. An earlier arm-by-arm run showed an apparent 2x gap in the same
direction; it was noise, and it is recorded here rather than dropped.

RSS before any load is ~14.9 MB on both arms, within the same noise.

## Family B — dynamic-interface / patchability cost

The same host compiled with and without the required contract (G4's solo pair,
so the only difference is `can-be-overridden` on the member):

    host AOT, contract absent   890,296 bytes
    host AOT, contract present  907,000 bytes
    cost of declaring one member patchable   +16,704 bytes (+1.88%)

That is the price of the dispatch point staying open. G4 measured the same
difference as *code shape* — dispatch-table calls at all five call sites instead
of devirtualized direct calls, and one field receiver not inlined; here it is
measured in bytes. The kernel is essentially unchanged (+128 bytes), so the cost
is entirely retained/less-optimized machine code, as expected.

**This is a per-declared-member cost, not a per-build one.** A release that
declares many members patchable pays proportionally, and that number cannot be
extrapolated from this single-member measurement.

## Family C — loaded module

    module (KBC)        1,190 bytes
    load latency        median 99 us   (min 96, max 121)
    RSS delta at load   median 114,688 bytes  (min 98,304, max 114,688)
    steady-state RSS    ~15.4 MB after load, vs ~14.9 MB before

Load is sub-millisecond and the resident cost is ~112 KB for this module. Both
scale with module content and neither is extrapolable to a real patch from this
one measurement.

## Family D — execution, 10,000,000 calls per mode, 3 reps

| mode | ns/call (median) | min | max | vs direct |
|---|---:|---:|---:|---:|
| AOT → AOT direct | 2.40 | 2.36 | 2.53 | 1.0x |
| AOT → AOT virtual | 2.65 | 2.56 | 2.70 | 1.1x |
| AOT → bytecode | 24.62 | 21.33 | 32.54 | **10.3x** |
| bytecode → AOT | 28.55 | 28.53 | 32.30 | **11.9x** |
| bytecode → bytecode | 28.51 | 28.32 | 35.26 | **11.9x** |

**Order of magnitude: crossing into or running as bytecode costs ~10-12x a
direct AOT call**, and virtual dispatch within AOT is essentially free (1.1x).
The three interpreted modes are within noise of each other, which says the cost
is *being interpreted*, not *crossing the boundary* — an AOT→bytecode call is no
more expensive than a bytecode→bytecode one.

That distinction matters for the architecture: it means the cost follows how
much code is patched, not how often the boundary is crossed.

### The benchmark cannot fold the boundary away

- Every callee is `vm:never-inline`; the operand comes from an environment-read
  seed the compiler cannot see.
- Every result accumulates into a sink that is printed, and the **sink changes
  with the seed** across reps — a folded loop would print a constant.
- 2.40 ns/call at ~3 GHz is roughly 7 cycles, which is a real call, not an
  elided one. A folded loop would report ~0.

## What is deliberately NOT concluded

- No production threshold. This lane reports magnitudes; whether 10-12x on
  patched code is acceptable is a product decision made against a real
  application's hot-path profile, which this gate does not have.
- Allocation throughput and GC behaviour under mixed execution are **not**
  measured here. G3 proved GC correctness across the mixed graph; its *cost*
  needs an allocation-heavy benchmark that is a separate piece of work, and
  claiming a number without it would be inventing one.
- Host macOS/arm64, one module, one machine, no iOS and no real application.
