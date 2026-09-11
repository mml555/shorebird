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

## Binding is CORRECT — and the earlier diagnosis is retracted

The claim that app procedures bypass `LoadProcedure` was **wrong**, and the
correction matters. `FinishTopLevelClassLoading` does loop top-level procedures
into `LoadProcedure`; it is merely *deferred* for a normal registered library
rather than called from `LoadLibrary`. The app's procedures were misses that a
`head` truncation hid, not absences.

The real cause was two constructors with two offset conventions that agree only
on the eager path:

| loader | `correction_offset_` | `library_kernel_offset_` | reader sees |
|---|---|---|---|
| eager (whole program) | library start | library start | whole component |
| **deferred (per library)** | **0** | **library start** | **library slice** |

Top-level procedures of a registered library take the deferred path, so
`+ correction_offset_` yielded slice-relative offsets (71, 119, 182, 225, 261)
matching no mapping — and once *collided* with a mapping belonging to another
declaration, which is how a correct id came to be bound to
`Function 'get:offsetInBytes'`. `ReadInferredType`, the working precedent in the
same file, already used `+ library_kernel_offset_`.

Measured (`rel`/`corr`/`libstart`/`abs` side by side, per the four-fact rule):

    HIT rel=71  corr=0 libstart=19 abs=90  name=compute
    HIT rel=182 corr=0 libstart=19 abs=201 name=mutableTopLevel

All five procedures now pair with their own Function and carry the right
selection flag. Evidence: `evidence/binding_four_facts.txt`.

## Two defects still open

1. **The registry pins pre-precompilation `Function` objects.** With the
   binding fixed, `gen_snapshot` now refuses:

       Unexpected object (Class with illegal cid, full-aot):
         Library:'package:m2app/app.dart' Class: Widget

   Only statics were registered before, so this never surfaced; class-owned
   Functions trip it. The association must still be established at load, but
   materialising the final registry may have to wait until the precompiler has
   settled which Functions survive. **Not fixed, and not guessed at** — this is
   the retention question, arriving early.

2. **The constructor is not registered.** The Dart side maps 6 declarations;
   the VM registers 5. `::cls:Widget::ctor:` is created by `LoadClass`, not
   `LoadProcedure`, so it needs its own join point. Recorded rather than
   papered over: a selected constructor would silently have no slot.

## What is NOT yet claimed

No body replacement, no call-site redirection, no execution of `PATCH_CODE`.
The 14 required behaviours, the 12 falsification arms, the measurements and the
derived verdict are not done. `RUNTIME_IMPLEMENTATION_REGISTRY_ESTABLISHED` is
**not** claimed.
