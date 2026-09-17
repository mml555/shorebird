# STAGE25 — PINNED_BODY_PROGRAM_TRAVERSAL_REGRESSION

Fork `1a20e5b12a2`, built and stamped by `m2/build_maot.sh`.

## 1. The guard is at the root-enumeration boundary, not per pass

The STAGE20 defect was not "a bug in `ReplaceFunctionStaticCallEntries`". A
declaration's implementation body **stopped being a `ProgramVisitor` root** the
moment its trampoline became `CurrentCode`, which blinded every `CodeVisitor`
scheduled after installation at once. Only the static-call binder crashed; the
other passes failed quietly, which is worse.

Per the ruling, one structural regression sits at that boundary instead of
twelve tests encoding today's list of affected passes.

`Precompiler::VerifyPinnedBodyTraversal()` runs **after every rewriting and
dedup pass**, and for each registry-pinned implementation body checks:

* it is reached by the program walk,
* exactly once,
* its static calls are still bound (no pc-relative entry left holding only a
  Function),
* and at least one such body is a **non-leaf** — it actually contains calls.

## 2. Falsified

`--maot_disable_pinned_body_roots` removes the fix. A check that cannot fail
proves nothing.

```
roots present   rc=0   bodies=4 visited_once=4 never_visited=0
                       unbound_entries=0 non_leaf_bodies=4  verdict=PASS

roots removed   rc=-6  bodies=4 visited_once=0 never_visited=4
                       unbound_entries=4 non_leaf_bodies=4  verdict=FAIL
                       si_addr=0x4d50003f1b9
```

The negative arm reproduces the original STAGE20 crash at the identical
address, and the counters state the defect exactly: the bodies exist, none is
visited, and every one of their entries is unbound.

**A flaw in the first negative control, found and fixed.** It initially reported
`FAIL(no pinned bodies)` — the verifier enumerated pins through the same
function the disable flag suppressed, so it failed for the wrong reason and
would have hidden a later regression that really did empty the registry.
`AddPinnedCodeRoots` (flag-honouring) now feeds the walk; `ForEachPinnedCode`
stays a pure enumeration the verifier uses.

## 3. What asserting it across the suite immediately caught

Turning the verdict into a per-row assertion **blocked the method and getter
rows**. Their subject bodies are constant-string returns, so no body has a
static call and the anti-vacuity condition cannot be met.

That is not those programs being wrong; it is those programs being unable to
carry the binding claim. Failing them would mislead as much as passing them
silently, so the check reports three outcomes:

| verdict | meaning |
|---|---|
| `PASS` | structurally sound **and** a non-leaf body exercised the binding claim |
| `PASS_LEAF_ONLY` | structurally sound, but no body in this program makes a call |
| `FAIL` | a pinned body is missing from the walk, or has unbound entries |

The suite then requires at least one non-leaf row, so a matrix made entirely of
leaf bodies cannot certify anything:

```
method    PASS_LEAF_ONLY     setter    PASS
getter    PASS_LEAF_ONLY     operator  PASS
                             callable  PASS
                             tearoff   PASS
non-leaf rows: setter, operator, callable, tearoff
```

This is also a standing note on the two established slices: neither
`ARM64_AOT_INSTANCE_STAGE_REPLACEMENT_VERTICAL_SLICE` nor
`ARM64_AOT_INSTANCE_GETTER_VERTICAL_SLICE` exercises static-call binding at all.

## 4. Status

`PINNED_BODY_PROGRAM_TRAVERSAL_REGRESSION` — evidence complete, asserted on
every matrix row, falsified in both directions. Six rows still PASS at 53
checks each.

Next: `ARM64_AOT_INSTANCE_DISPATCH_MATRIX` (Task A).
