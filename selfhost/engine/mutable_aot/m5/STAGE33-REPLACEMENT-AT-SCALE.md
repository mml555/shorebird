# STAGE33 — replacement at scale through the production path

Fork `2822c0c3cb5` (clean), stamped.
No new dispatch mechanism, no cache invalidation, no direct cell mutation.

## 1. The two dimensions, separated

| dimension | value |
|---|---|
| resident mutable population | **2,616 selected**, all with trampolines and cells |
| replacement transaction | **400 declarations per transaction**, twice |
| probe composition | 300 unique-body + 100 shared-body + 100 never-replaced controls |

Shared-body probes are included deliberately: the 625/3,624 shared-body
accounting established that declarations can share one body Code, and that is
the cross-wiring risk.

```
selected=2616  eligible=2616  refused=0
installed=2616 distinct=2616
BODY_PARTITION unique_body=1020 shared_body=1596 no_body=0
               body_is_trampoline=0 sum=2616 remainder=0
PINNED_TRAVERSAL bodies=1020 visited_once=1020 never_visited=0
                 multiply_visited=0 unbound_entries=0
                 non_leaf_bodies=1019  verdict=PASS
```

## 2. The transaction

```
baseline   unique OLD 300/300   shared OLDS 100/100   control CTL 100/100
           sample  OLD0:20 | OLDS:20 | CTL0:50
           version.P0 = 1

V2         install.ok = 400/400
           unique NEW 300/300   shared NEWS 100/100   control CTL 100/100
           sample  NEW0:30 | NEWS:30 | CTL0:50
           version.P0 = -102  (PATCH_CODE v2)

V3         install.ok = 400/400
           unique NEW2 300/300  shared NEW2S 100/100  control CTL 100/100
           sample  NEW20:40 | NEW2S:40 | CTL0:50
           version.P0 = -103  (PATCH_CODE v3)
```

Every one of the 400 replaced declarations reports its new behaviour at both
stages, and all 100 controls are untouched throughout.

## 3. Identity stability, compared as addresses

| representative | frozen identities | implementation identities | self-cycle |
|---|---|---|---|
| unique P0 | unmoved | advanced twice | none |
| unique P299 | unmoved | advanced twice | none |
| shared S0 | unmoved | advanced twice | none |
| shared S99 | unmoved | advanced twice | none |
| control C0 | unmoved | **unchanged** | none |

Frozen = declaration Function, declaration CurrentCode, trampoline Code,
trampoline entrypoint, dispatch cell.

```
unique P0   before  implFunction=4391962705 implCode=4391419265 pinnedBody=4391419265
            v2      implFunction=4392024945 implCode=4391564545 pinnedBody=4391564545
            v3      implFunction=4391902801 implCode=4391304065 pinnedBody=4391304065
```

Shared-body declarations did **not** cross-wire: S0 and S99 advance
independently, and the controls are unmoved on every identity.

No cache flush, rebind or table mutation was performed or required.

## 4. A false stop condition I nearly reported

The first run printed `install.v2.ok=400` alongside `v2.unique.NEW=189` —
which reads exactly as the programme's highest-priority defect: *replacement
succeeds, execution stays OLD*.

It was **my counting**, not the product. Probe *i*'s replacement renders as
`NEW<i>:`, so for i = 2, 20-29 and 200-299 the string `NEW<i>` also begins
with `NEW2`, and the metric subtracted them as if they were V3 values. That is
1 + 10 + 100 = **111**, and 300 − 111 = **189** — the exact number observed.

The arithmetic matching precisely is what identified it as an artifact rather
than a defect. The fixture now compares **exact expected strings** per probe
and reports stale probes by index, so the ambiguity cannot recur.

Worth stating plainly: a prefix-based metric over generated names is the same
class of mistake as a diagnostic that runs when disabled — the measurement
looked reasonable and was wrong in a way only arithmetic caught.

## 5. Status

```
Replacement at scale (400 per transaction, x2, 2616 resident)  ESTABLISHED
Shared-body cross-wiring                                        NONE OBSERVED
Default-on readiness                                            NOT ESTABLISHED
```

Default-on remains a **selection-policy** question, not a correctness one:
select-all is ~4.2x the normal snapshot before trampolines. Nothing here
addresses whether select-all is the intended production policy.
