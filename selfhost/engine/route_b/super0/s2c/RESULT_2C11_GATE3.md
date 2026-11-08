# D-SUPER-2C.1 · ANALYZER-255.1 Gate 3 — successor compiler archive minted

    NEW CANDIDATE COMPILER IDENTITY

    sha256  39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74
    size    19,254,004 bytes

    9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59
        is the PREVIOUS qualified compiler identity ONLY. It is not evidence
        for this archive and must not be cited as such.

No cell minted. H2 unchanged, its published compiler still `9d4ace27…`, and
H2 audits CLEAN. Releases 139 and 140 untouched.

## The provenance chain

    accepted source revision
        repo HEAD            2abc78613a4ac7f7ae1edade8b49716c0d78528c
        analyze_coverage.dart
          git blob           0a68378189d7d4f78b3dee3bc63cc20daeccc683
          file sha256        a81d2bae86b62e6fd85bbbcd230502d066b26b9d0d3f4a143b224138a1ee943e
          analysisVersion    11  (deliberately not bumped)
          working tree       clean, 0 dirty paths
        ↓
    compiler build
        engine source HEAD   dfa2b24ac38477f3705ff0357530f33fe09474b8
        dart   source HEAD   9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c
        host out             out/host_release_arm64
        route_b_analyze.aot  18862acd7de2af6381205064a7290b5fb67a6b9c707eabad8d645cff04c4eccb
        ↓
    packaged ONCE
        publish_route_b_compiler.sh --rev a5a8be58… --overlay <scratch>
        ↓
    new archive digest
        39ad75dd7342e9e26370d3dab834d3770e612b238103c85cadf03d3a61e93e74

## Frozen, and mechanically so

The archive is copied to a stable path and set read-only (`-r--r--r--`) so Gate
4 cannot repackage in place. Gate 4 must qualify THIS digest.

    /Volumes/build/route-b/h2work/gate3/route-b-compiler-darwin-arm64.zip

## Members — exactly one changed

    same     dart2bytecode.aot                  81b9a5fc…c9fce
    same     dartaotruntime                     075ccbb2…9292
    same     vm_platform.dill                   015ef32c…c75d2
    CHANGED  route_b_analyze.aot                799a0796… -> 18862acd…
    same     route_b_gen_kernel.aot             81e1d8f4…49e36
    same     route_b_gen_dynamic_interface.aot  c2268002…f2155
    same     route_b_release_probe.aot          37dffac8…9e72d
    same     flutter_platform_strong.dill       099b0313…d61c

    PROVENANCE.txt                              2202b0a6…687a

1 of 8. The other seven were not rebuilt and are byte-identical, so the delta is
attributable to the analyzer fix alone.

## The recorded lineage is the ENGINE, not a cell address

    engine revision  : a5a8be5854c529268378ce16762a16d6e31763e9
    dart revision    : 9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c
    platform         : darwin-arm64

Packaged with `--rev <engine>` rather than a cell address ON PURPOSE. That is
what makes the archive address-INDEPENDENT and ends the recursion that killed
option 1: writing a cell address into an addressed member can never converge.
Under cell-binding v2 this field is producer lineage, and the cell descriptor
carries the membership claim.

## A REPRODUCIBILITY FACT that changes what Gate 4 must do

The analyzer AOT is NOT byte-reproducible:

    Gate 2 scratch build   b5fb302ae910bcf27209d12c5f6884c4daf26fcc062646d92e368c4bcb8e3eea
    Gate 3 cell build      18862acd7de2af6381205064a7290b5fb67a6b9c707eabad8d645cff04c4eccb

Same source, same tree, different bytes — the snapshot embeds build-varying
data. So Gate 2's byte-identical linked-base result was proven against a SIBLING
build, not against the archive Gate 3 froze.

Gate 4 must therefore RE-PROVE, against `18862acd…` as extracted from
`39ad75dd…`:

    four-arm matrix              exit 0 x4
    linked-base equivalence      vs the broken v11 analyzer
    both release-time predicates agreement

Carrying Gate 2's evidence forward unexamined would be exactly the
"stamps are not bytes" error this project keeps paying for.
