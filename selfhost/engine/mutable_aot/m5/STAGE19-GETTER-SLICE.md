# STAGE 19 — getter vertical slice

Status: **passing on the established mechanism. No new runtime representation.**
Reported for disposition.

## 1. A first-gate failure that was mine, not the system's

The first run returned `-1` from every registry call:

```
tramp.identity=-1  version.0=-1  install.v2=-1  install.v3=-1
alpha.v2=OLD-ALPHA   <- correct: nothing was installed
```

That reads exactly like "getters are unsupported" and is nothing of the kind.
`-1` is *unknown declaration id*, and I had guessed one: a getter's #65 id is
`cls:X::get:v`, not `cls:X::getter:v` and not `cls:X::method:v`. The correct id
was read back out of the registry dump rather than guessed a second time, and
the trap is now recorded in the fixture header so the setter/operator subjects
do not repeat it.

Worth stating plainly because the failure mode is seductive: the install
returned an error AND the value stayed OLD, which together look like "install
succeeded but execution did not move" -- the most serious defect class in this
programme. It was the opposite: nothing was installed, so nothing moved.

## 2. The slice

```
tramp.identity = 1                    a getter declaration does get a trampoline
version.0  = 1 (AOT)                  alpha.0  = OLD-ALPHA
install.v2 = 0                        alpha.v2 = NEW-ALPHA    version -102 = PATCH_CODE v2
install.v3 = 0                        alpha.v3 = NEW2-ALPHA   version -103 = PATCH_CODE v3
beta.0 = BETA                         beta.after = BETA
```

## 3. Which mechanism a getter actually uses

```
states = [UnlinkedCall 2, MonomorphicSmiableCall 1, monomorphic 1,
          SingleTargetCache 0, ICData 1, MegamorphicCache 2]
```

Every state entered is one of the nine already modeled. Nothing new appeared,
so nothing is inherited by analogy -- the forms were observed, not assumed.

The site settles in MegamorphicCache, and the entry is stable across both
installs:

```
afterWarm / after v2 / after v3:
  cid=235  cached_fn=Function 'get:v' owner=Alpha  addr=0x1060e7141
  CurrentCode_IS_trampoline=YES  trampoline_entry=0x1016aa784
```

Byte-identical cached Function address throughout; `states.before ==
states.after`, so no new resolution or miss.

## 4. The renamed diagnostic, exercised for the first time

```
              fn_matches_current_impl  code_matches_pinned_body  raw_equals_CurrentCode
before        True                     True                      False
after v2      True                     True                      False
after v3      True                     True                      False
```

Both real invariants hold at every stage. The raw comparison is False
throughout and that is correct -- it is the value the old
`dispatch_cell_halves_agree` would have reported as a failure.

## 5. Not claimed

This is the getter subject only. Setter, operator and callable-class call are
untouched, and tear-offs remain a separate evidence track.
