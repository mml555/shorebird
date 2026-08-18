# `SHOREBIRD_JWT_ISSUER` — ROOT CAUSE FOUND AND FIXED AT THE DURABLE SOURCE

2026-08-18. Host-side. **The running containers were NOT recreated — see "Not
done" below.**

## The defect, as it was observed

The CLI refused every call with:

    These credentials were issued by http://169.254.189.3:18080, but this
    deployment expects http://10.0.0.7:18080.

`169.254.x.x` is a self-assigned link-local address — what the Mac holds when
normal networking is unavailable. The server was minting JWTs stamped with an
address the deployment then rejected, and **re-logging in could not fix it**: a
fresh token carried the same wrong `iss`. Every session since has worked around it
by exporting `SHOREBIRD_JWT_ISSUER` client-side.

## Root cause — durable, not accidental

    /Users/mendell/shorebird-rig/config/cps-ios.env
      SHOREBIRD_JWT_ISSUER=http://169.254.189.3:18080     <- PINNED

That file is a DURABLE INPUT: `rig_recreate` composes container env from
`config/` + `secrets/` rather than reading the old container back
(`CONTROL_PLANE_DATA.md`). So the stale issuer **survived every recreate** — it was
never a one-off runtime mistake.

Meanwhile `prepare_ios_endpoint.sh` recomputes `PUBLIC_BASE_URL` from the live
interface on each run and passes it to `rig_recreate`. **`PUBLIC_BASE_URL` tracks
the machine; the pinned issuer did not.** They were guaranteed to diverge the first
time the Mac's address changed, and they did.

## The fix — delete the pin, do not re-pin it

The server already derives a correct default (`config.dart:104-107`):

    jwtIssuer = SHOREBIRD_JWT_ISSUER ?? JWT_ISSUER ?? PUBLIC_BASE_URL ?? http://localhost:$port

and the CLI expects (`shorebird_env.dart:287-291`):

    SHOREBIRD_JWT_ISSUER ?? <base_url from shorebird.yaml> ?? https://auth.shorebird.dev

With the pin removed the server issues `PUBLIC_BASE_URL`, which
`prepare_ios_endpoint.sh` keeps current, and the CLI derives the same value from
`base_url`. **They now track each other automatically.**

Setting the pin equal to `PUBLIC_BASE_URL` was rejected deliberately: it fixes
today's instance and re-arms the same drift for the next address change. Removing
it makes the defect class impossible rather than fixing one occurrence.

**Applied to BOTH rigs.** `cps-android` was pinned too
(`SHOREBIRD_JWT_ISSUER=http://localhost:18081`) and merely happened to still match
its `PUBLIC_BASE_URL` — the identical latent defect, one address change from
surfacing. Removing it changes nothing today and prevents the same failure later.

    config/cps-ios.env      SHOREBIRD_JWT_ISSUER line removed
    config/cps-android.env  SHOREBIRD_JWT_ISSUER line removed
    backups                 *.bak-jwtfix-20260818-023513 beside each

## NOT DONE, and why — the containers were not recreated

The fix takes effect on the next `rig_recreate`. **That was deliberately not run.**

* It is a service interruption on a **shared rig**, and another lane committed to
  this repository today (`94c281a0`, `3f141415`). Recreating a control plane
  another session may be mid-publish against is exactly the "guard-and-proceed on
  state another lane holds" failure.
* `CONTROL_PLANE_DATA.md` records a `docker rm -f` + failed `docker run` that
  destroyed credentials once. The premise is now gone — `rig_recreate` validates
  durable inputs BEFORE destroying anything, and `secrets/` is authoritative — but
  it remains an operation to run deliberately, not incidentally at the end of an
  unrelated pass.

**To apply, when the rig is known idle:**

    selfhost/scripts/prepare_ios_endpoint.sh --force     # recomputes PUBLIC_BASE_URL and recreates

Verify afterwards with a client that exports NO issuer override:

    unset SHOREBIRD_JWT_ISSUER
    shorebird releases list --app-id <id>        # must succeed on its own

Until then the documented client-side `export SHOREBIRD_JWT_ISSUER=…` workaround
(`gate2_verdict.txt`) still applies and still works.

## Scope

Nothing about auth REFRESH is changed. User-OAuth refresh being dead
(`44715902`) is a separate defect, which is why `SHOREBIRD_TOKEN` with an
`sb_api_` key remains the documented self-host path. API keys are not JWTs and
were never affected by the issuer mismatch.
