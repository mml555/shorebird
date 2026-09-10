<!-- cspell:words patchability MAOT unmodeled devirtualization -->

# MAOT-1 (#65) — stable declaration and type identity

**Status: `stable_identity = ESTABLISHED`.** 15 cases, 14 falsification arms,
0 blocking findings.

```bash
./run_m1.sh        # exits non-zero on any blocking finding, failed case or arm
```

The scheme itself lives in the **Dart fork**, not here:

| file | what it is |
|---|---|
| `pkg/kernel/lib/maot_identity.dart` | the identity scheme (`maot.identity/2`) |
| `pkg/vm/bin/maot_identity_manifest.dart` | the manifest emitter (`maot.identity.manifest/2`) |

Durable at `mml555/dart-sdk-shorebird-lineage`, branch `maot/identity`. This
lane drives those tools, records what they produced, and decides the verdict —
so #64 can consume identity results without reading anything out of the fork.

## What identity is derived from

The program's **name space**, and nothing else. Never machine-code or object
addresses, pool offsets, transient class ids, compilation or declaration order,
source position, absolute paths, or build directories.

```
lib:package:foo/bar.dart::cls:MyClass::get:value
lib:package:foo/bar.dart::cls:C::method:_hidden@package:foo/bar.dart
lib:package:foo/bar.dart::ext:Ext::get:twice
lib:package:foo/bar.dart::enum:E::synthetic:values
```

Ids are canonical strings, not opaque hashes — the point of a stable identity
is that a human can see *why* two ids differ. The fixed-width value is
`namespace_identity`, a digest over the reproducible `identity` block only.

**A `file:` library with no `--app-root` is REFUSED, not path-named.** Falling
back to the absolute path would mint an id reproducible only on the machine
that made it — and it would pass every test written there.

## Two defects the first manifest surfaced

**Lowered forms are not logical identity.** The front end lowers an extension
member to `Ext|get#twice`. Naming the lowering would make a declaration's
identity a function of the *name-mangling scheme*: change the mangling and
every extension member in every release silently becomes a different
declaration, with no source edit and nothing visible in a diff. Extension and
extension-type members are identified through their descriptors — owning
declaration plus source-level name and kind — with the lowered name kept only
as an implementation alias.

**Compiler-generated is not source-declared.** An enum's `values` has a stable
name *today*; that is a property of this compiler, not a contract. Every entity
is classified: source-declared → `nominal`; generated → either a defined
`SyntheticRole` (addressable, derived from the logical declaration) or
explicitly **not addressable**. Nothing gets nominal stability that has not
been defined.

`_enumToString` forced the general rule. It is a plain `Procedure` with
`stubKind=Regular` whose name is private to `dart:core`, injected onto every
enum — so "is it a stub?" does not catch it. The rule that does: **a member
whose name is private to a library other than its enclosing class's library was
placed there by the compiler**, because source cannot spell a name private to
somebody else's library.

## Decisions stated rather than discovered

| edit | identity |
|---|---|
| rename | **new** — no automatic alias; a rename that must carry state is `TS-03` |
| move to another library | **new** — the library is part of the name space |
| reorder / insert declarations | **unchanged** — no ordinal is an input |
| generic arity change | **preserved, deliberately** |
| body edit | **unchanged** |

Arity is the one worth arguing about. If `Box<T>` → `Box<T, U>` minted a new
id, the existing instances would be not addressable by any migration — and
addressing them is the entire point of `TS-10`.

## Cases (15)

`T01` same source, two randomly named build dirs → identical ids *and*
namespace (this is #65 tests 1 and 5 together) · `T02` body-only edit · `T03`
reorder · `T04` add declarations · `T06` rename · `T07` private names ·
`T08` generic parameters survive body edits · `T09` synthesized classification ·
`TX1` extension / extension-type logical identity · `TX2` enum members ·
`TX3` accessors, operators, constructors, factories · `TX4` mixin and synthetic
application · `TX5` private names with an unlinked platform · `TX6` `file:`
refusal · `TX7` app-root mapping records the mapping, never the path.

## Falsification (14, both directions)

`P0` is the positive control — the real manifest raises nothing, without which
every arm below is satisfied by a detector that flags everything.

`F01` address-shaped id · `F02` absolute-path dependence · `F03` wrong release
namespace · **`F04` forced collision → fail closed (this is #65 test 10)** ·
`F05` private-name aliasing · `F06` a surviving declaration whose ids differ ·
`F07` lowered form used as identity · `F08` synthesized claiming persistent
identity · `F09` empty test population · `F10` a required test dropped from the
run · `F11` manifest bound to a branch instead of a commit · `F12` swallowed
refusal · `F13` empty namespace.

### One arm was retracted rather than forced

`F05` originally stripped the `@library` qualification from real ids and
expected a collision. **It never collided.** Three shapes were tried — two
classes in two libraries; two mixins from two libraries applied to one class;
a class declaring `_x` while mixing in another library's `_x` — and in every
one the *owner path* already differs, because Kernel keeps a mixin's members on
the mixin declaration rather than copying them onto the applying class.

So the qualification is **defence in depth here, not the only thing preventing
an alias**, and the arm now says so. It tests the protection the way it can
actually be tested: inject the aliased state a scheme *without* qualification
would produce, and prove the collision detector sees it. Forcing the original
arm would have been manufacturing evidence.

## Manifest binding

`--dart-commit` and `--dart-tree` are required and must be full 40-hex shas; an
unbound manifest names a namespace without saying which compiler produced it,
and a patch could then "agree" with a release built by something else.

The reproducible `identity` block is separated from informational `provenance`,
and `namespace_identity` covers only the former. Prose is excluded from the
digest, so rewording a caveat does not move the namespace. No path, timestamp
or build root appears in it — the app root is recorded as *which libraries it
mapped*, never as its own location.

## Known limitations

1. **Closure identity is positional.** `closureId` is stamped `structural`:
   stable only while the nesting and order of function literals is unchanged.
   Nothing that needs a closure to survive an arbitrary edit may build on it.
   No case exercises it yet, because nothing consumes it yet.
2. **Type parameters are identified by name.** Reordering `<T, U>` to `<U, T>`
   preserves both ids while swapping their meaning. That is a semantic change
   the matrix must catch; identity alone cannot see it.
3. **Identity is not yet carried in Kernel metadata.** It is computed on demand
   and emitted to a manifest. #65 requires the *decision* be recorded, and it
   is: serializing into the dill belongs with the runtime registry that
   consumes it (#66), because the consumer determines the encoding.
4. **The SDK namespace is excluded by default.** `--include-sdk` exists; the
   manifest records which mode produced it.
5. **The scheme runs on the stock SDK against the fork's sources.** Identity is
   pure Dart, so no engine build is involved — but nothing here has been
   exercised through an AOT compilation yet. That starts at #67.
