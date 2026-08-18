# Splitting OOBE from post-OOBE account management

**Status:** design notes only — no code changes on this branch yet.
**Date:** 2026-08-18. **Branch:** `split-oobe-and-account-app`.

## The decision

Stop shipping one app that does both jobs. Go back to the two-app model that
worked for 3.0.5:

| | app id | how it ships | job |
|---|---|---|---|
| **OOBE** | `com.palm.app.firstuse` | baked into the CE Doctor image, `visible:false` | first-boot setup only |
| **Account manager** | `com.palm.app.webosaccount` | App Catalog / Preware install | everything after OOBE |

As of 2026-08-18 the CE image bakes the OOBE app hidden again
(`webos-doctor-ce`, `build/community-firstuse/make-overlay.sh`). There is
currently **no** post-OOBE account UI on a fresh CE device — that gap is what
this branch's eventual work fills.

## Why HP's single-app design does not survive being made optional

HP forced account creation at first run, so their `com.palm.app.firstuse` only
ever ran once, in a known state: no profile yet, minimal UI, whole screen, no
launcher. Making account setup **skippable** means the same screens must be
reachable later, from a launcher, on a configured device — a context the app
was never built for. Every card carries first-run assumptions:

- `Language.js` — its constructor **deletes the device's palm profile**. Fine as
  step 1 of a wipe-and-setup flow; catastrophic from a launcher tap.
- `StartOver.js` — deletes the **connected Wi-Fi profile**. Reachable from the
  terms and sign-in cards.
- Power-key handling — OOBE owns the screen and hosts its own power dialog whose
  "Turn Off" calls `machineOff()`. As a normal app card, "Done" could power the
  device off.
- `closeApp()` — under OOBE it must call `markFirstUseDone()`; standalone it must
  just close.
- The 5-minute inactivity auto-powerdown.

We patched around all of it with a runtime `wosaIsOobe` flag derived from
`PalmSystem.isMinimal` (600009–600014). It works, but every card needs its own
guard, every guard is a chance to get it wrong, and getting it wrong on a
launcher tap wipes a real user's profile or Wi-Fi. Two apps delete the entire
bug class instead of guarding it: the OOBE app never needs a launch-mode check
because it only ever has one launch mode, and the account app never contains
the destructive cards at all.

## What the split does NOT fix (read this before assuming it does)

The black-screen / hang / freeze reports against the current app were **not**
caused by the single-app design. Diagnosed live on flash 600014 on 2026-08-18:

> The backend service (`com.palm.service.palmprofile`, bus name
> `com.palm.accountservices`) is hub-launched through `/usr/bin/run-js-service`,
> which routes it via the **node fork server**. That fork can wedge:
> `node_spawner` sits poll-waiting forever, the fork server never runs, and
> `ls-hubd` — believing a launch is in flight — queues *every* call to the
> service forever and answers nothing. All app symptoms follow from "the
> backend never answers". Signature: `keymanager` logging
> `com.palm.accountservices is not running` every 5 min for a whole boot.
> Live recovery: `kill` the stuck `node_spawner`.

The fix is in the image, not in this repo: the CE Doctor now bakes
`/usr/bin/run-js-service-nofork` and points **only** this service's dbus
launcher at it (`webos-doctor-ce`, `build/full-ce/bake.py`, tier 19c (f)).
Verified on hardware from a cold boot: zero fork-server launches of palmprofile,
other node services unaffected.

**Both apps talk to the same service over the same bus name**, so the account
app inherits this behaviour either way. Two things follow:

1. Splitting the apps buys correctness, not reliability. Do not close the
   reliability item because the split landed.
2. Whatever the account app ships as, `com.palm.accountservices` stays the bus
   name — Phone/Messaging/Contacts resolve the account by that id (they log
   "Promoting icons for com.palm.palmprofile"). Do not rename it to get a jail.

Also worth knowing: the 1.1.3 catalog ipk (the build that ran for a month with
no freeze reports) patched the **same** ROM service at the same path via its
postinst. It was never jailed either — it simply respawned rarely, instead of
racing a first-boot storm of concurrent node service launches. The fork-server
flakiness is latent in stock webOS, not something CE introduced.

## Open questions for the account app

- **Delivery.** 1.1.3 installed via Preware/ipkgservice with a root postinst that
  copied the app into `/usr/palm/applications` and patched the ROM service in
  place, keeping `.stock` backups restored by `prerm`. On a CE image the service
  patches are already baked, so the postinst's job shrinks to installing the app
  — possibly making a plain cryptofs app install viable. Decide which.
- **Identity.** `com.palm.app.webosaccount` (what `app/appinfo.json` already
  says, and what 1.1.3 shipped). Keep it.
- **Scope.** Sign in / out, change name / email / password, pick a public
  username, list devices on the account. Explicitly *not* language selection,
  Start Over, device naming as part of a wipe, or anything that touches the
  Wi-Fi profile.
- **Sharing with OOBE.** The two apps share most cards today. Decide between a
  common source tree with two build targets and two genuinely separate trees.
  A shared tree keeps fixes in one place but reintroduces the risk that an
  OOBE-only card is reachable in the account app — the exact thing the split is
  meant to make structurally impossible.
- **Entry point.** With OOBE hidden, a user who skips setup needs a route to the
  account app: catalog install, plus wherever Settings > Accounts should link.

## Related

- `webos-doctor-ce` `build/community-firstuse/` — the OOBE swap and its deltas.
- `webos-doctor-ce` `build/full-ce/bake.py` tier 19c (f) — the nofork fix.
- The 1.1.3 catalog ipk is the reference for the account-app half.
