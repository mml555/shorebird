# D-SUPER-2C.1 · Gate 4 — compiler 39ad75dd QUALIFIED

    archive   39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74
    analyzer  18862acd7de2af6381205064a7290b5fb67a6b9c707eabad8d645cff04c4eccb

No analyzer rebuilt during Gate 4. No Gate 2 result cited as evidence for these
bytes. No cell minted. H2 unchanged and CLEAN; releases 139 and 140 untouched.

## Three identities, kept separate

    engine source SHA         dfa2b24ac38477f3705ff0357530f33fe09474b8
    producer engine identity  a5a8be5854c529268378ce16762a16d6e31763e9
    compiler archive SHA256   39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74

`a5a8be58…` is the PRODUCER ENGINE recorded inside the archive. It is NOT a v2
cell address; cell membership is carried by the descriptor, separately.

## 4A — byte identity, checked before executing anything

    archive sha256   39ad75dd…   MATCH
    archive size     19,254,004  MATCH
    fresh extraction 9/9 members match the Gate 3 bank,
                     including PROVENANCE.txt 2202b0a6…687a

## 4B — four-arm matrix, frozen analyzer

    import  -> import        exit 0
    release -> release       exit 0
    import  -> prepass       exit 0
    import  -> release_app   exit 0

Run with the binary extracted from the frozen archive. No unit-test substitute.

## 4C — linked-base equivalence, BYTE-FOR-BYTE

    base release_app.dill -> patched prepass.dill

    broken v11 analyzer  799a0796…   output 8da8dbad8d4b79ed6a66e99a0e0708d8add6c241d211621bcc4d39d01d542d28
    frozen    analyzer   18862acd…   output 8da8dbad8d4b79ed6a66e99a0e0708d8add6c241d211621bcc4d39d01d542d28

    BYTE-IDENTICAL

Whole-document equality, so it covers every lowering key, `superInvocations`,
`releaseSuperTargets`, source span, signature, verdict and rejection. Nothing
was normalized; no delta had to be classified because there is none.

This is a FRESH proof against the frozen bytes. Gate 2's identical-looking
result was against sibling build `b5fb302a…` and is NOT carried forward.

## 4D — both release-time predicates agree

Computed the way `agreesWith()` computes them — non-accessor entries in `added`
are the disagreement set:

    EARLY  early_import -> prepass       changed 7288  added 248  non-accessor 0
           agreesWith -> TRUE
    LATE   early_import -> release_app   changed 7018  added 250  non-accessor 0
           agreesWith -> TRUE

    => release_import.dill would be RETAINED
    => retention evidence FULL, not the narrower fallback

Both predicates now answer, where v11 crashed before reaching either.

## 4E — measurement states, end to end on real documents

Emitted by the frozen analyzer on real kernels:

    unlinked base (import -> release_app)   6358 lowering,
                                            6358 ABSENT, 0 empty, 0 populated
    linked base   (release_app -> prepass)   761 lowering,
                                            0 absent, 417 EMPTY, 344 POPULATED

Parsed by the PRODUCTION `RouteBCoverage.fromJson`:

    6358 absent(null) / 0 / 0        and        0 / 417 / 344

Identical — so absence survives the boundary as null on real documents, not just
in fixtures, and empty and populated stay distinct.

Refusal half, still green:

    absent   -> REFUSE "did not measure … missing measurement, not a negative
                result"
    empty    -> REFUSE "never direct-called", and asserted NOT to contain the
                absent wording
    match    -> narrow-v1 admission unchanged

## 4F — archive identity after all execution

    archive sha256   39ad75dd…   unchanged
    archive size     19,254,004  unchanged
    analyzer sha256  18862acd…   unchanged
    archive mode     -r--r--r--  still read-only

No repackaging, no timestamp-normalized successor, no "equivalent archive".

## VERDICT

    compiler 39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74
    QUALIFIED

The successor cell may now be minted from this exact archive plus H2's other
fifteen unchanged members, via the qualified PUBLISH-V2 transaction. No host
toolchain rebuild is indicated by this defect.
