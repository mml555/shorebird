# D-SUPER-2C.1 · ANALYZER-255.1 — Gates 1 and 2 PASS

    127/127 Route B suite, 0 errors, 0 warnings

No cell minted. H2 unchanged and AUDIT CLEAN, compiler still `9d4ace27…`,
releases 139 and 140 untouched. The fixed analyzer remains built to scratch.

## GATE 2 — exact linked-base equivalence

The ruling was right that counts are not proof. The comparison is stronger than
the canonical-JSON equality asked for:

    linked base: release_app.dill -> prepass.dill

    broken v11 output   8da8dbad8d4b79ed6a66e99a0e0708d8add6c241d211621bcc4d39d01d542d28
    fixed      output   8da8dbad8d4b79ed6a66e99a0e0708d8add6c241d211621bcc4d39d01d542d28
    BYTE-IDENTICAL

    canonical sha256    f9e939a53e50af479de8a3e6cabc1260126ef73ef8c0f03500efe27ea5c05bc9  both

Byte equality subsumes every field the ruling enumerated — every lowering key,
`superInvocations` target tuple, `releaseSuperTargets` tuple, source span,
signature, verdict and rejection. Not counts.

### Four-arm matrix, fixed analyzer

    import  -> import        exit 0
    release -> release       exit 0
    import  -> prepass       exit 0
    import  -> release_app   exit 0

    arm C  added(non-accessor) 0  -> agreesWith TRUE   early predicate
    arm D  added(non-accessor) 0  -> agreesWith TRUE   late predicate

Both release-time predicates return true, so `release_import.dill` would have
been RETAINED. The kernels did agree; v11 never got far enough to find out.

## GATE 1 — the measurement-state contract, end to end

`absent says we did not look` is now true across the boundary, not just in the
analyzer.

    RouteBLowering.releaseSuperTargets : List<RouteBProvenance>?

    null    measurement UNAVAILABLE — the analyzer could not build a hierarchy
            over the release kernel, so it did not look
    []      measurement TAKEN — the release direct-called nothing
    [...]   measurement taken, targets observed

Parsing preserves absence with a `switch` on the raw value; the previous
`?? const []` erased the distinction at exactly the boundary where it has to
survive.

### Producer refusals now say different things

    absent  "the analyzer did not measure what the release version of `X`
             direct-called … This is a missing measurement, not a negative
             result"      -> sends the reader at the RELEASE pipeline

    empty   "resolves to a target this release never direct-called"
                          -> sends the reader at the PATCH

Both refuse, so this is not a safety change — it is the difference between a
refusal naming a missing measurement and one asserting a measured fact.

### Controls

    A  field absent          -> parsed null                       PASS
    B  field []              -> parsed empty                      PASS
    C  field [target]        -> exact provenance tuple            PASS
       absent != empty       -> asserted directly                 PASS
    D  super + absent        -> REFUSE, "did not measure"         PASS
    E  super + []            -> REFUSE, "never direct-called",
                                and NOT "did not measure"          PASS
    F  super + matching      -> narrow-v1 admission unchanged      PASS
                                (existing suite, 91 -> 127 green)

Control E asserts the ABSENCE of the other message, so the two refusals cannot
silently converge on one wording later.

Analyzer version NOT bumped: v11's on-wire contract already permits the optional
key. An older v11 CLI still folds absence into empty and refuses, so backward
behaviour stays safe.

## Not done

    Gate 3  rebuild the compiler archive from the accepted fix, package once,
            record the new ZIP digest. `9d4ace27…` must NOT be reused as the
            successor's qualification claim.
    Gate 4  rerun the FULL compiler qualification against the successor bundle.
    then    successor cell H3 via the qualified PUBLISH-V2 transaction.
