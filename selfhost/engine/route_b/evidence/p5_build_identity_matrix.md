# P5 — the differential matrix, before designing anything

`probes/p5_build_identity_matrix.sh`, 2026-08-25. The question:

> Can a patch ever be produced against build semantics different from the exact
> release it targets, while the existing P4 bindings still accept it?

One variable per row. `cross-patch` is what the **real producer** did with
release A's artifacts and a patch kernel built under B, with every P4 gate live.
`config-agrees` is what `RouteBBuildConfig.agreesWith` says — the G4.1 check that
lives in the **patcher**, which this harness does not drive, so it is reported as
the product's answer rather than as something this run observed happen.

| row | cross-patch (producer) | config-agrees (G4.1) | who would refuse |
|---|---|---|---|
| identical control | **PUBLISHED** | true | nobody, correctly |
| dart define `A`→`B` | **PUBLISHED** | **false** | G4.1, in the patcher |
| target, separate entry | PATCH_BUILD_FAILED | **true** | nobody — see below |
| target, shared library | COVERAGE_REJECTED | **true** | coverage, incidentally |
| body calls an uncalled member | **PUBLISHED** | true | nobody — and correctly |
| flavor `foo`→`bar` | **PUBLISHED** | **false** | G4.1, in the patcher |
| obfuscation off→on | **PUBLISHED** | **false** | G4.1, in the patcher |

## What this answers

**No P4 binding catches any build-semantics mismatch, and that is not a defect.**
P4 binds release identity, artifact digest, cell, capability manifest and member
signature. A patch compiled with different defines targets the *same* release
artifact, so every P4 binding holds — correctly. P5 is a different question and
P4 was never going to answer it.

**The three semantic dimensions are already covered — by G4.1, in the patcher.**
Defines, flavor and obfuscation all produce `agrees=false`, and
`_verifyBuildConfigAgrees` refuses on that with a named difference. The flavor
case has a product-level test (`ios_patcher_test.dart`, "refuses a patch built
with a DIFFERENT flavor"). So for these three, P5 is **not** a missing gate.

**Flavor is semantic in this toolchain, measured rather than assumed.** With an
app that never reads `FLUTTER_APP_FLAVOR`, kernels for `foo` and `bar` are still
DIFFERENT. So flavor does not need a separate hashed field — it already reaches
the compiler as an ordinary define and is in the canonical form — but it is not
mere provenance either.

**Obfuscation changes the artifact**, plain `caba6652c47b` vs obfuscated
`fa346066f3e2`, so the release/patch distinction is real.

## The two residual items

**1. `--target` is absent from the canonical identity.** Two different targets
produce `agrees=true` and the same fingerprint `494a8de866b142b6`. No exploit was
demonstrated, and the reason is worth stating exactly, because both catches are
INCIDENTAL rather than designed:

- a separate entry file makes the patch fail to compile against the release's
  interface, which says nothing about whether a mismatch would be caught;
- a shared-library entry is rejected by coverage — but as an **added member**
  (`main_b.dart#main`), because the entry file itself is new;
- and the substantive hazard, a replacement body calling a member the release's
  program never calls, **publishes** — correctly, because Route B retains app
  libraries WHOLE. Asked of the release probe rather than assumed:
  `helperOnlyB → ZERO_QUALIFYING_CALLSITES, Function nodes = 1`. The member is in
  the release; it simply has no call sites, which is exactly what P4.1 already
  distinguishes.

So `target` is currently guarded by two accidents and one policy. That is a
provenance gap, not a demonstrated hole — and it should be recorded as such
rather than closed with a gate whose necessity has not been shown.

**2. A release with no build configuration is WARNED about and permitted.**
`_verifyBuildConfigAgrees` returns early when `provenance.buildConfig == null`,
logging that the defines "cannot be checked". That contradicts the precedent P4
set — *missing required evidence is not compatibility* — and it is the one place
in this area where absence reads as agreement. Note the P4.4 contract-revision
gate now refuses a release recording no revision, which covers the legacy case;
what remains is a release that HAS a revision and no fingerprintable config.

## What this rules out

P5 does **not** need a new `build_identity_v1` for defines, flavor or
obfuscation. Those are already canonicalised on measured rules (last-wins,
order-insensitive, empty ≠ absent) and already compared. Adding a second identity
over the same inputs would be two sources of truth for one compiler fact.

## Harness defects found while measuring, all of which faked a result

1. `gen_kernel` takes `-D`, not Flutter's `--dart-define`; passing both aborted
   three builds.
2. `${arr[@]}` on an empty array is unbound under `set -u`, killing the first
   non-obfuscated build.
3. **The projectRoot was the release OUTPUT directory, not the app source.** The
   bytecode compiler then failed with a bare `exit 254` and no stderr, and rows 3
   and 4 reported REFUSED — indistinguishable in the log from a semantic
   refusal. Rows 0 and 1 passed only because those two paths happened to be the
   same directory. The run now flags a bare `exit 254` with no compiler stderr as
   "suspect the harness, not a gate".
4. `gen_dynamic_interface`'s stderr was sent to `/dev/null`, so a failed
   interface generation surfaced three steps later as a missing `base.dill`.
5. The two entry files called `shared.main()` while `main` takes `List<String>`.

Numbers 3 and 5 are the ones worth remembering: both produced a plausible
verdict for the wrong reason, which is the failure mode this whole project keeps
finding.


---

# What was done with this measurement, 2026-08-25

**P5.1, the one demonstrated defect: fixed.** A release with no comparable build
configuration now refuses with `BUILD_IDENTITY_EVIDENCE_ABSENT` instead of
warning and continuing. Mutation-checked: the same patch proceeds when the
release records a comparable configuration instead of none.

Updating the fixtures for it exposed that **every existing patcher test had been
running the null-config path**. The `produce` stubs omitted `buildConfig`, which
matched only because that argument was always null; once the fixtures recorded a
configuration, six stubs stopped matching. The hole was load-bearing in the test
suite as well as in the product.

**No second identity was built.** `RouteBBuildConfig` is now formally the P5
authority, with `BUILD_CONFIG_MISMATCH`,
`BUILD_IDENTITY_EVIDENCE_ABSENT` and `BUILD_IDENTITY_PATCH_UNFINGERPRINTABLE` as
its stable codes, following P4.3's rule that the code is the contract and the
prose stays free.

**The three semantic classes joined the permanent publication matrix**, sharing
one load-bearing comparison. Each class has a negative arm and a mutation that
equalises only that dimension and shows the same pair then agrees — which is
what makes the negative arm evidence about the dimension rather than about the
comparison. Two more rows guard the boundary: `--split-debug-info` must NOT
create a disagreement, and `--target` must not either, asserted deliberately so
that adding it becomes a decision.

**The gate matrix learned to point at a gate it cannot run.** P5's refusal lives
in the patcher, which that harness does not drive. Declaring that is honest;
declaring it without saying where would be a silent skip — so the pointer names
the file and test, the completeness rule READS the file, and breaking the name
fails the suite. Verified by breaking it.

**The harness rule is now shared, not local.** `probes/harness_guard.sh` carries
`classify_tool_failure` and `require_tool_ok`: a tool that fails with no
diagnostic output is `HARNESS_FAILURE`, never a refusal. It exists because of
defect 3 above, and it is written broadly on purpose — a narrow pattern would
misfile a novel real failure as a harness bug, which errs toward discarding
product evidence.
