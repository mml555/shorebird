# STAGE47 — cross-application population gate

Fork clean and stamped. The accepted implementation, unchanged, run over five
real applications. Nothing was tuned per application: the policy is
root-package ownership with `--maot_disable_retention_roots` in every arm.

**Decision rule applied in order.** `analysis_server` unit cost is
`2,389,024 / 8,273 = 288.8 B` per selected declaration, **inside the
273–311 B envelope**, so it was admitted to the fit rather than decomposed.

## 1. Size

```
app              class                     A MB      B MB      C MB      C-A B    C-A %   .text C-A  .rodata C-A
smith            small                    1.130     1.130     1.133       3016   +0.27%       2864         8928
nst              medium                   1.519     1.606     1.642     123192   +8.11%      28112        62160
gen_kernel       large                   13.417    13.691    13.924     506304   +3.77%     124448       271600
dart2wasm        visitor/interface        24.547    24.856    25.094     546336   +2.23%     161296       285408
analysis_server  dependency heavy        25.800    27.181    28.189    2389024   +9.26%     596656      1282512
```

Every workload ran. `installed = distinct = selected` in all five, so no
trampoline was merged anywhere in the population.

## 2. Population and density

```
app               selected  eligible  refused  retained A  sel/retained  sel per MB  B per selected
smith                   51        51        0        2098        0.0243        45.1            59.1
nst                    396       390        6        2757        0.1436       260.7           311.1
gen_kernel            1853      1775       78       22799        0.0813       138.1           273.2
dart2wasm             1906      1813       93       41194        0.0463        77.6           286.6
analysis_server       8273      7984      289       43764        0.1890       320.7           288.8
```

Ordering the five by `selected per MB` — 45.1, 77.6, 138.1, 260.7, 320.7 —
reproduces the ordering of C−A% exactly: +0.27, +2.23, +3.77, +8.11, +9.26.
The spread of 8.99 pp is **selection density**, not instability.

## 3. The model

One parameter, fitted on the four populations with ≥200 selected declarations.
`smith` is shown but excluded: with 51 declarations it is dominated by fixed
and layout effects and would drag the envelope.

```
fitted unit cost = 286.8 B per selected declaration

app               selected     measured B    predicted B    residual B   meas %   pred %  error pp
nst                    396         123192         113589        -9,603   +8.11%   +7.48%     -0.63
gen_kernel            1853         506304         531516       +25,212   +3.77%   +3.96%     +0.19
dart2wasm             1906         546336         546718          +382   +2.23%   +2.23%     +0.00
analysis_server       8273        2389024        2373033       -15,991   +9.26%   +9.20%     -0.06
--- excluded from the fit ---
smith                   51           3016          14629       +11,613   +0.27%   +1.29%     +1.03
```

Worst error among the fitted four is **0.63 pp**. The residuals are
±16 KB with no sign structure against size, density or application class
(−9.6 KB, +25.2 KB, +0.4 KB, −16.0 KB), so nothing here asks for a second
term.

The largest application is also the most expensive in percentage terms and
lands within 0.06 pp of prediction, which is the case that would have exposed
a size-dependent effect if one existed.

## 4. Refusal categories — one is new and is flagged

```
app               refused  rate
smith                   0  0.0%
nst                     6  1.5%
gen_kernel             78  4.2%
dart2wasm              93  4.9%
analysis_server       289  3.5%
```

Three denominators, stated separately because an earlier version of this
section conflated them and printed a refusal total that does not exist:

```
selected_declarations   12,479   the population
refused_declarations       466   selected but not installable
escape_records           1,140   optimizer_escapes summed over selected
                                 declarations; a declaration can carry more
                                 than one
```

**Correction.** This section previously read "12,458 of 12,462 refusals".
Neither number is a refusal count: 12,479 is the *selected* population and
12,462 was a miscount of it. The refused population is 466.

Refused declarations by first recorded reason:

```
462   "the dispatch cell has no seeded global-pool entry, so the call site
       cannot name the same cell the trampoline does"
  4   "a constant result was inferred for a mutable call, so the caller
       would use the release answer without ..."
```

**The constant-inference refusal is new to this population** — 1 in
`dart2wasm`, 3 in `analysis_server`, zero in the three applications measured
before. That is #68's P1 escape firing for the first time outside a fixture,
and it is fail-closed: those four declarations are refused rather than shipped
as installable. Reported here rather than absorbed into the size fit; no
action taken, the policy is frozen.

They are **four distinct declarations**, not four records on fewer
declarations, and their identities are kept here so the set can be watched if
it grows:

```
optimizer_escapes  lowered sites  declaration
                1              3  lib:package:dart2wasm/dynamic_modules.dart::
                                  cls:ConstantCanonicalizer::method:_equalsForValueType@package:dart2wasm/dynamic_modules.dart
                2              4  lib:package:analysis_server/src/protocol_server.dart::fn:getColorHexString
                1              5  lib:package:analysis_server/src/protocol_server.dart::fn:getReturnTypeString
                1              3  lib:package:analysis_server/src/handler/legacy/completion_utils.dart::
                                  fn:_getDeclaringType@package:analysis_server/src/handler/legacy/completion_utils.dart
```

`getColorHexString` carries two escape records; the constant-result one is the
first recorded. The other three carry one each.

The dominant category is the fail-closed pool-entry check, at 1.5–4.9% of
selected declarations. It does not correlate with application class.

## 5. Dispatch profile — descriptive

Per selected declaration, from `indirect_call_sites_emitted`:

```
app               >=1 lowered site   no lowered site   median sites   max sites
smith                           34                17            1.0           6
nst                            288               108            1.0          52
gen_kernel                    1110               743            2.0          57
dart2wasm                     1309               597            2.0         523
analysis_server               5103              3170            1.0         300
```

"No lowered site" means the declaration has no static call site that #67
lowered: it is reached through the trampoline — virtual, interface or dynamic
— or is not called at all. That is 27–40% of selected declarations in every
application, so both routes are exercised everywhere in the population, which
is what #69 built the trampoline for.

The tails are long: one `dart2wasm` declaration carries 523 lowered call sites
and one `analysis_server` declaration 300.

This section is descriptive. It is not a second selection policy and nothing
was optimized against it.

## 6. What this population does and does not establish

Established: artifact overhead is **286.8 B per selected declaration**,
stable within ±0.6 pp across a 23x range of application size and a 7x range of
selection density, with the percentage set by how much of the program the
policy selects.

Not established here: runtime cost, and the two platform smokes. Both remain
open.

## Reproduce

```
selfhost/engine/mutable_aot/m5/lib/stage47_m5.py     runs the population
selfhost/engine/mutable_aot/m5/lib/popreport_m5.py   reads what it left, runs nothing
```
