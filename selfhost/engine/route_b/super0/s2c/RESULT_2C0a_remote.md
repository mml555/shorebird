# 2C.0a — candidate engine source is now independently durable.

    remote  mml555/shorebird-flutter
    branch  route-b-2c-candidate
    tip     dfa2b24ac38477f3705ff0357530f33fe09474b8   (the marker commit)
    parent  b456dc0dd88ff45575b364bd994a45892f2515f3   (docs-only declaration)

Verified by `git ls-remote` against the remote, and by fetching it back — not by
trusting the push's own output. Not merged into `route-b`.

So the chain is now complete enough to consume the hash:

    remote dfa2b24a  →  built iOS device slice  →  sha1 a5a8be58…

## Two things the push surfaced

**1. Pre-push formatting drift is real, and I added two lines to it.**

The engine's pre-push hook refuses on formatting. It reported 1 GN file and 2
C++/ObjC files — the same drift `NEXT_LANES.md` §3 already records as
outstanding, and the same reason a previous push in this programme used
`--no-verify`.

But two of MY comment lines exceed 80 columns, in a file that already carries
265 clang-format replacements. That is debt I introduced, and it is recorded
rather than quietly left:

    // engine revision, and our engine publishes under sha1 of the built device-slice
    // candidate engine artifact whose hash differs from the certified one — and the

**It was not fixed, deliberately.** Rewrapping a comment changes the commit SHA,
which would un-freeze `H = a5a8be58…` — the identity the ruling just froze and
which the built artifact is bound to. Comments do not affect codegen, so a fix
would almost certainly rebuild to the same hash, but "almost certainly" is not
the standard this lane has been held to. **Fix it only when the candidate is
rebuilt for some other reason**, and re-measure the hash then.

**2. `vpython3` is needed for git operations too**, not just the build — the
pre-push hook invokes it. Supplied per-command via PATH, as with the build.

## A sequencing correction for 2C.0b

The ruling's step order puts the candidate Flutter revision (step 1) before the
isolated CLI (step 5). Those are the wrong way round here:

**The only Flutter checkout on this rig lives inside `~/.shorebird`**
(`bin/cache/flutter/a4a3c0d1…`), and `~/.shorebird` is explicitly not to be
touched. So the candidate Flutter revision cannot be created until the isolated
CLI copy exists to hold it.

Revised order for 2C.0b:

    5  isolated candidate CLI copy      (~9.0 GB, brings its own Flutter cache)
    1  candidate Flutter revision       inside that copy, pinning engine.version = H
    2  candidate engine overlay under H
    3  candidate v11+0017 cell under H, after qualification
    4  experimental_hashes.map entry, last

The ruling's own constraint — publish artifacts before mapping them — is
unaffected; only the CLI/Flutter pair moves ahead of it.
