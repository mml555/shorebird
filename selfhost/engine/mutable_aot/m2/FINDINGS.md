<!-- cspell:words MAOT precompiler dartaotruntime untagged patchability -->

# MAOT-2 (#66) — measured findings so far

Fork `maot/build` = `38b31d7cd2e44ee188df324bd878dc736bccd1dd`.

## The architectural boundary is crossed

A #65 declaration id travels: Kernel → `vm.maot-declaration-id` metadata →
`KernelLoader` → `ObjectStore` root → AOT snapshot → `dartaotruntime`. The
runtime dump reports `runtime_mode: precompiled`, the release namespace
survives, and an entry is present. **No reconstruction step anywhere.**

## Two placement facts, both found by measurement

**ObjectStore roots must sit before `slow_tts_stub`.** `to_snapshot(kFullAOT)`
stops there; fields after it are never written. Appended at the end of the
field list, the registry was populated during the build and was *absent* from
the runtime — the exact "do not infer snapshot survival" failure. They must
*also* sit after the last field in `runtime_offsets_extracted.h`, or every
later offset shifts and `CheckOffsets` aborts `gen_snapshot`.

**The metadata cursor already adds `data_program_offset_`.** The in-loader
convention is the raw reader offset (`procedure_offset + correction_offset_`),
matching `ReadInferredType`.

## Two defects still open

1. **Only 1 of 6 declarations registers, bound to the wrong `Function`.**
   Measured at the source: `Register()` receives `…::fn:notMutable` paired with
   `Function 'get:offsetInBytes'`. This is the F06 mismatch the gate must
   refuse, currently occurring for real.

2. **The Dart side is correct** — 6 mapped, 2 selected, 0 refusals, right ids
   and flags. So the defect is entirely on the VM read side.

### The decisive clue

`mutableTopLevel`, `main`, `compute` and `untouched` appear as **neither hits
nor misses** in the load trace. `KernelLoader::LoadProcedure` is never called
for the app's own procedures in this AOT flow, so the hook sits in a seam the
app's members do not pass through. The next step is a different join point, not
a different offset formula.

## What is NOT yet claimed

No body replacement, no call-site redirection, no execution of `PATCH_CODE`.
The 14 required behaviours, the 12 falsification arms, the measurements and the
derived verdict are not done. `RUNTIME_IMPLEMENTATION_REGISTRY_ESTABLISHED` is
**not** claimed.
