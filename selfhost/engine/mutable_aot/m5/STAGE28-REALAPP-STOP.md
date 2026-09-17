# STAGE28 — real-application scale: STOP CONDITION (snapshot crash)

Fork `94f5e3035b0` (clean), stamped.
Subject: `shorebird_cli` — 208 files, ~36.6k lines, 45 direct dependencies; a
real Dart application that can be both snapshotted and run on the host.

**Returning per the stop-condition rule: snapshot crash.** No diagnosis was
attempted beyond bounded localisation.

## 1. Result

| arm | selection | install | snapshot |
|---|---|---|---|
| A (control) | normal | OFF | **ok**, 7.6 MB, 22.7s (kernel 16.8s) |
| B | `MAOT_SELECT_ALL_NON_SDK=1` | ON | **CRASH rc=-6**, 65s |

```
si_signo=Bus error: 10(10), si_code=BUS_ADRALN(1), si_addr=0x72413a6d756e653a
```

## 2. What the fault address is

`0x72413a6d756e653a` read as 8 little-endian bytes is **ASCII**:

```
3a 65 6e 75 6d 3a 41 72   ->   ":enum:Ar"
```

An alignment fault (`BUS_ADRALN`) on an address whose bytes are printable text
resembling a #65 declaration-id fragment. Stated as measured: the faulting
address decodes to that string. The inference that a String is being used where
a pointer is expected is **not** claimed as established.

## 3. Phase

```
[maot] BIND_PASS codes=16459 entries=60638 skipped_kind=1998 null_fn=44112 left_empty=0 bound=14528
[maot] POST-DEDUP trampolines: installed=5098 distinct=5098
[maot] >>> entering PruneDictionaries
[maot] <<< PruneDictionaries returned
si_signo=Bus error ...
```

PruneDictionaries **entered and returned**, so the fault is after it, in
serialization.

## 4. The #69 mechanisms are healthy at this scale

This is the important separation — none of the established work is implicated:

```
PINNED_TRAVERSAL bodies=4473 visited_once=4473 never_visited=0
                 multiply_visited=0 unbound_entries=0
                 non_leaf_bodies=4134 verdict=PASS
```

* 4473 pinned bodies, every one visited exactly once, none unbound — **not**
  the STAGE20 class.
* `installed=5098 distinct=5098` — no trampoline identity collapse.
* `BIND_PASS left_empty=0` — every static-call entry bound.

So mass selection did not break root enumeration, trampoline distinctness, or
static-call binding. The crash is a different, previously unseen defect that
only appears at this population.

**A discrepancy recorded rather than smoothed:** the traversal line reports
4473 pinned bodies while POST-DEDUP reports 5098 installed trampolines. The two
numbers come from runs with different flag sets and count different things
(pins exclude trampolines). They are not reconciled here and should not be
treated as the same population.

## 5. Two limits on this run

* **Arm A selected nothing.** `shorebird_cli` carries no `maot:mutable`
  pragmas, so normal selection selects zero declarations — correct behaviour,
  but it means arm A is a build-shape control only, not a population control.
* **Arm A's runtime check is inconclusive**, for a reason unrelated to MAOT:
  the CLI needs its Shorebird install tree and exits with
  `Could not read .../flutter.version`. Reported rather than presented as a
  pass or a failure.

## 6. Not done

No diagnosis, no fix, no flag change, no default-on movement. #69 remains
ESTABLISHED on its instance-member dispatch scope; this is population
readiness, which was already NOT ESTABLISHED and remains so.
