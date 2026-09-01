# D-SUPER-2C.1 · PUBLISH-V2 — v2 transaction QUALIFIED

    29 PASS / 0 FAIL      selfhost/engine/route_b/qualify_publish_v2.sh

No host rebuild, no live mint, no map mutation. The live overlay was never
written — asserted as a control, not assumed.

## The transaction

    stage -> address -> render -> verify -> publish

`v2_transaction()` owns the order so no caller can reorder it. The address is
taken from a stage that is ALREADY complete; installing any member afterwards is
the v1 defect in a new costume, so the manifest generator refuses an incomplete
stage before an address exists.

Inputs are explicit (`v2_member_for_flag` maps each named input to its canonical
`%H` path) rather than rediscovered from whatever `out/` happens to contain.

Publication is directory-atomic: both hash roots move into place only after the
whole transaction verifies, an existing destination refuses the ENTIRE
transaction, and a failure on the second root rolls the first back.

## Self-reference, without a fixed point

Stage carries `%H` templates -> address -> render `%H` -> H2 only where the
schema permits -> canonicalize the rendered tree back -> regenerate the manifest
-> require byte equality with the manifest that was addressed.

That last step is the integration control that matters: it proves the bytes
about to be served ARE the cell that was addressed, rather than trusting that
rendering was harmless because the unit tests passed.

## Controls

    stage            16 members staged, exactly 16 files            2 PASS
    1 address        computed from the completed stage; recomputes
                     independently from the banked manifest; 16
                     members; schema marker present                 4 PASS
    2 publish        address matches dry-run; all 16 final paths
                     present; compiler present; no residual %H in
                     metadata; engine_stamp rendered; manifest keeps
                     the UPSTREAM flutter_engine_revision           6 PASS
    2b audit         missing-required 0, denied-present none, every
                     remaining finding UNPROTECTED                  3 PASS
    3 reconstruct    published tree regenerates the addressed
                     manifest byte-identically, and the address     2 PASS
    4 idempotence    second publish refuses; existing cell unmutated 2 PASS
    5 collision      pre-existing DIFFERENT bytes refuse the whole
                     transaction; no partial second root; existing
                     bytes untouched                                3 PASS
    6 incomplete     refuses, and banks NO address                  2 PASS
    7 policy freeze  digest recorded in the address provenance      2 PASS
    8 v1             publish refuses                                1 PASS
    9 live overlay   scratch successor absent from it; H untouched  2 PASS

The scratch successor is `f98951cdde2b79e93ce10bd21c5e138cfcab3f26`, assembled
from H's real published bytes. It is deliberately NOT the eventual coherent H2 —
this arm qualifies the transaction, not the host repair.

## Two corrections made while qualifying, both worth recording

**The `%H` residual check fired on every cell.** `%H` is two bytes, and it occurs
by chance inside ~100 MB of compressed archive members, so a tree-wide grep is
guaranteed to match. Scoped to the two rendered metadata files. Had it been left
tree-wide it would have been permanent noise that a future reader would delete
rather than fix.

**Member counting included the preamble.** `address_schema`, `cell` and
`fallback_engine_revision` are also two-field lines, so a bare `NF==2` counted 19
members instead of 16 — and the same expression guarded the duplicate-member
check. Both now exclude the preamble keys explicitly.

## One deliberate deviation from the ruling's wording

The ruling asked for `audit_overlay … = CLEAN` on the scratch successor. That is
unreachable BY DESIGN and demanding it would be harmful:

`@must_be_local_pkgs` is per-hash and is added AFTER publication — the order the
Caddyfile itself prescribes, and the order this lane has already followed twice.
The scratch successor is a throwaway that must never be mapped, so adding it to
the live Caddyfile to make an audit go green would be exactly the live mutation
control 9 exists to forbid.

So control 2b requires instead: `missing-required: 0`, no denied-present, and
EVERY remaining finding attributable to not-yet-protected paths. That is the
strongest true statement about what a publish transaction can guarantee;
protection remains step 8's job.

## Not done

No cell minted live. H remains RETIRED and byte-identical. The host rebuild has
not started.
