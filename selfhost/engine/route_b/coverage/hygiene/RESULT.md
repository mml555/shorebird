# D0.1 RESULT — UNSAFE. The escalation clause fires.

Run 2026-08-31 on the host. Engine tree `619fdad176ff4573…`, cell
`4792f0eca461f3761001a1adbe131b4b115e3684` (its `route_b_analyze.aot`
`14538a67…` and `route_b_gen_kernel.aot` `81e1d8f4…` match this host tree's
build outputs byte for byte — checked, not assumed). Producer driven through
`producer/cli_produce.dart`, i.e. `RouteBCoverageAnalyzer` + `RouteBProducer`,
the code `shorebird patch` runs.

    A  local `self` in the method body        UNSAFE
    B  closure PARAMETER named `self`         UNSAFE
    C  closure parameter `self`, also used    UNSAFE
    D  target's own parameter named `self`    LOUD
    E  local `self` inside a nested closure   UNSAFE

**Four of five are accepted, compile, and execute with different semantics than
the source they stand in for.** Per `PRECOMMIT.md` this displaces D0.2: the lane
is now `D-HYGIENE — correctness defect`.

## The defect

`RouteBProducer` inserts a receiver parameter hardcoded as `self`
(`route_b_producer.dart:640`) and rewrites each receiver access the analyzer
reported by inserting `self.` at that access's source offset (`:726`). Neither
the producer nor the analyzer models lexical scope: `_ReceiverUses`
(`analyze_coverage.dart:654`) is a plain `RecursiveVisitor`.

So when the user's own source already binds `self` in a scope enclosing a
receiver access, the inserted `self.` resolves to **the user's binding**, not to
the receiver. The edit is textual; the resolution is lexical; nothing checks
that they agree.

## Case E, the sharpest one

    ACTION      patch `Shadow.value`, whose body is

                  String value() {
                    final f = () {
                      final self = Shadow.other;
                      return self.label.isEmpty ? 'X' : label;
                    };
                    return f();
                  }

    OBSERVABLE  the producer ACCEPTED and emitted

                  String value(Shadow self) {
                    final f = () {
                      final self = Shadow.other;
                      return self.label.isEmpty ? 'X' : self.label;
                    };
                    return f();
                  }

                dart2bytecode compiled it, and a container was written:
                  89c77de17679b07c08dcc4f1f10bcaa71d860517541ad312da67a1836908ae60
                  package:corpus/main.dart#Shadow.value, 795 bytes of bytecode

                executed on the host VM:  WRONG-OTHER
                the source it replaces:   RIGHT-RECEIVER

    FAIL-CLOSED did NOT hold. Nothing refused. The receiver access `label` was
                rewritten into `self.label` inside a scope where `self` is the
                author's local, and the closure returns the impostor's value.

`A`, `B` and `C` fail the same way; the containers are `71768893…`, `4024520f…`
and `d85c2488…`. **Every accepted case reached a publishable SBRBPTCH container
with compiled bytecode in it.** The refusal boundary is not merely thin here —
it is absent.

## D is the harmless shape, and it is the only one

`String tagged(String self)` lowers to
`String tagged(Shadow self, String self)`. Two parameters of one name in one
scope: dart2bytecode refuses (exit 254) and the CLI exits non-zero with
`the bytecode compiler refused its replacement body`. That is `LOUD` — a name
collision in the SAME scope as the inserted parameter. It is recorded, and it is
not the finding.

The distinction that matters: A/B/C/E each open a **new** scope (a body block, a
closure parameter list, a closure body) where shadowing is legal Dart, so there
is no collision to detect and the wrong binding is silent.

## Two harness faults found on the way, both of which flattered the system

Recorded because either would have been reported as a result.

1. **Vacuous refusal.** The first controls were refused by the analyzer for
   `2 member(s) are new`. The `--aot` prepass had tree-shaken `Shadow.label` and
   `Other.label` out of the base kernel — the base body never called them — so
   they arrived in the patched kernel looking like ADDED members. Five clean
   `SAFE` verdicts, none of which had anything to do with `self`. Fixed by
   holding both labels live from a dead branch in `keepAlive`, present
   identically in both kernels.

2. **Un-scorable driver fault scored anyway.** The execution driver imported the
   replacement by absolute path; Dart resolves that RELATIVE to the importing
   file, so every case failed to compile and every case scored `LOUD` — the
   flattering direction again. The driver now refuses to score anything that is
   not recognisably a name collision, and reports `HARNESS FAULT` instead.

Both are the same shape: **a check that cannot fail certifies the work as done.**

## What this does and does not establish

* It **does** establish that an accepted, compiling, publishable Route B patch
  can carry different semantics than its source, through a mechanism present in
  the shipping producer today.
* It is a **host** result. Nothing ran on a device. The execution is of the
  emitted replacement source on the host VM, which is the same source
  dart2bytecode compiled — but interpreter binding on hardware is not claimed.
* It says **nothing about frequency**. How often real Dart names a variable
  `self` is not measured here and is not what makes this a defect. D0.2 would
  not answer it either.

## Reproduce

    WORK=/tmp/hyg bash selfhost/engine/route_b/coverage/hygiene/run_hygiene.sh
