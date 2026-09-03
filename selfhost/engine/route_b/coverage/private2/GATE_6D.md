# Gate 6D — a normal release that derived its own constructor grants

    release        142, version 1.0.3+4
    app            private-construction-6d  2e628d42-26c8-d4be-e779-67b07edf1fed
    release artifact (App)  bbea5b9c72a6e25b7d20ba41abaafff9b0392da108b26f7ed673bb61489ff8b2
    dynamic_interface.yaml  ec2575d4d30de6991683adc0d69eb00b01892345…
    capability manifest     7672f48ec8b52b047348c4a17c899a49e4048938…

## The lineage, each link committed

    candidate CLI    b68238500de7…  (Gate-1 wiring + v11/12/13 consumer)
    Flutter selector e64eb0af52e1c43c3b21a39556d789538d0df9b3   (F4)
      parent         ab29aee0…  (F3, which pinned H3)
      one file       bin/internal/engine.version -> cd848320…
    cell             cd848320d605ff8af5060cabf9a8d1b35853f752
    compiler archive 7975b27c… (frozen at 6A)
    analyzer CONSUMED 67741a082fcde5a9e2067fdfad1deb7ad69cb89b8d23aba78ed31b5afb6c2f5d
      cached at bin/cache/artifacts/route-b-compiler/cd848320…/route_b_analyze.aot
      byte-identical to the frozen v13 build

The CLI's own output names the chain: `Cloning into …/flutter/e64eb0af52e…`,
`HEAD is now at e64eb0af5 candidate(6d): pin engine.version to the v13 cell
cd848320`, `Shorebird Engine • revision cd848320d605ff8af5060cabf9a8d1b35853f752`.

## The census ran, and it changed the released interface

Not a log line — the artifact it produced and the grants it caused:

    build/route_b/release_constructions.jsonl   (written by the release path)
      3 construction sites, in 3 methods

    build/route_b/route_b_capabilities.json     (what the release published)
      policy p2
      privateClassesConstructible  3
        package:super_fixture/main.dart#_Boxed.new
        package:super_fixture/main.dart#_Other.new
        package:super_fixture/main.dart#_PageState.new
      constructionWithheld         0

The granted set is exactly the census's set. No `--grant-constructor` was passed
by hand and no census was run manually; the release path did both.

## The specimens this release creates

    positive()   constructs _Boxed          -> same-method evidence EXISTS
    negative()   constructs nothing         -> same-method evidence EMPTY
    elsewhere()  constructs _Other          -> _Other.new is GLOBALLY retained

`_Other.new` being in the manifest while `negative()` never constructed it is
precisely the cross-method leakage specimen 6E needs, and it arose from an
ordinary release rather than being manufactured.

## Three blockers hit on the way, all real

1. **Stale JWT issuer.** Credentials were issued by `http://169.254.189.3:18080`,
   a link-local address that no longer exists. Already banked in
   `p6-custom-target`; worked around with the bootstrap API key via
   `SHOREBIRD_TOKEN`, which is not a JWT. The underlying misconfiguration
   remains that lane's open debt.
2. **App ownership.** The bootstrap key's account does not own app 41344620…, so
   a dedicated app was created. That also keeps release 141's app untouched.
3. **`SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR` unset** produced
   `COHERENCE_UNDETERMINABLE`, which is the gate working: stamps alone cannot
   establish that the cached iOS engines are the published ones. Set to the new
   cell's overlay dir.

Also visible and working: `Running flutter precache… Done` before the coherence
gate — the PLATFORM-PRECACHE ordering, in the product.

## Fixture

Rewritten for these specimens; version 1.0.3+4, and `base_url` added so the
shipped app asks this control plane rather than upstream.
