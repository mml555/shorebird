# Gate 6A/6B — frozen candidate bytes, and what they actually do

## 6A — the frozen candidate

Built ONCE and frozen. `route_b_analyze.aot` has already proven
non-byte-reproducible in this project, so qualification must exercise these
exact bytes rather than a rebuild justified by source equality.

    compiler archive   route-b-compiler-darwin-arm64.zip
      sha256           7975b27c724240e720f77d338c80fcace5296148bd78c17588cee1b089e3fb22
      size             19,256,864 bytes
    producer engine    dfa2b24ac38477f3705ff0357530f33fe09474b8
    dart revision      9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c
    repo revision      7f8f6a18a0b2143a4040eefa2dc8f784b59a3958
    platform           darwin-arm64

Functional members, as the archive's own PROVENANCE records them:

    dart2bytecode.aot                  81b9a5fc7369c1e3d0fa26ac80c18da1420414c7e0966aa27cef2c86a88c9fce
    dartaotruntime                     075ccbb2858f299db06c2ef56b1b60c7ab07abdbc7ff413f33d4bb956e09f292
    vm_platform.dill                   015ef32c6cb988d8ec160e97da5ec62fb4d4798ac9e03815294c982b298c75d2
    route_b_analyze.aot                67741a082fcde5a9e2067fdfad1deb7ad69cb89b8d23aba78ed31b5afb6c2f5d
    route_b_gen_kernel.aot             81e1d8f4dc72bf2bb62ca3e157155568070327b4ea127e8dd6a8fe116d3e49d6
    route_b_gen_dynamic_interface.aot  c226800242a85028f85cbc8ff570a4650eb65beb78c278168711fdcc81cf2155
    route_b_release_probe.aot          37dffac8de643591aa095749e16cb97b9b6be3912c209fa7c2ed670f609e72d0
    flutter_platform_strong.dill       099b03133aea39273dcebf85ed8c5762ee22834e63d2ffba786be6ad7428d61c

The analyzer inside the archive is byte-identical to the v13 build
(`67741a08…`), and the tree's CERTIFIED analyzer is untouched at `18862acd…` —
the candidate was staged by overriding the archive's inputs rather than by
writing into the build tree. That override is a new, small change to
`publish_route_b_compiler.sh`, made precisely so one build can be frozen and
then used everywhere.

## 6B — the frozen bytes' behaviour

Every document below was produced by the analyzer EXTRACTED FROM THE FROZEN
ARCHIVE (`67741a08…`, re-hashed after extraction), and consumed by the shipping
`RouteBCoverage.fromJson` + `RouteBProducer.produce` with a real cell and the
project's own `package_config`.

| # | arm | result |
| --- | --- | --- |
| 1 | v11 document | REFUSED via the old source scan — "names `_CustomFocusBuilder`, a private identifier" |
| 2 | v12 document | REFUSED — "did not measure what the RELEASE version of this method constructed" |
| 3 | v13, release evidence ABSENT | REFUSED — same "did not measure" |
| 4 | v13, release evidence EMPTY | REFUSED — `_HomeMenuState._buildIconGrid`, "which the RELEASE version of this same method never constructed" |
| 5 | v13 POPULATED + exact grant | **ADMITTED** |
| 6 | v13 POPULATED, no grant | REFUSED — "whose constructor … this release did not retain" |
| 7 | manifest grant, no same-method evidence | REFUSED — `AppBtn.build`, "never constructed" |

Arm 3's absence is real, not simulated: the frozen analyzer OMITS
`releasePrivateConstructions` when handed an unlinked base (the
`--no-link-platform` import kernel), which was shown directly. The consumer's
handling of that absence was then isolated to a single target, because a
whole-document run reported a different target's compiler failure first and
would have proved nothing about the absent key.

Arms 4 and 7 are the real-history leakage control, run together against a
manifest deliberately widened to grant `_ButtonHoverEffect.new` and
`_GridBtn.new`: both real historical changes were refused by the same-method
condition WHILE the manifest granted them.

## What remains

6C mint one v2 cell (stage → address → render → publish → fetch-back → protect →
AUDIT CLEAN, recording this archive as the changed member, H3 untouched);
6D a normal `shorebird release ios` that derives the grants itself;
6E the negative control, run BEFORE publication;
6F the positive patch;
6G the physical device.
