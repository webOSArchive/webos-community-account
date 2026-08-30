# Splitting OOBE from post-OOBE account management

**Status:** the account app (`com.palm.app.webosaccount`) is built, tested, and
fixed against real 3.1.0 activation behavior — see the 2026-08-30 entry below.
Landed on `main` directly (commit `8e4aa41`), not on the
`split-oobe-and-account-app` branch these notes were originally written on.
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
  — **2026-08-30:** the current Preware/ipkgservice + rootfs-patch delivery was
  tested and works on both 3.0.5 and 3.1.0 as-is (3.1.0's own baked-in service
  patch gets overwritten by ours on install, no conflict observed). Whether a
  simpler cryptofs-only install is worth pursuing on a CE image is still open.
- **Identity.** `com.palm.app.webosaccount` (what `app/appinfo.json` already
  says, and what 1.1.3 shipped). Keep it.
- **Scope.** Sign in / out, change name / email / password, pick a public
  username, list devices on the account. Explicitly *not* language selection,
  Start Over, device naming as part of a wipe, or anything that touches the
  Wi-Fi profile.
  — **2026-08-30:** `com.palm.app.webosaccount` was still shipping the live,
  unpatched Start Over button until this session — fixed, see below.
- **Sharing with OOBE.** The two apps share most cards today. Decide between a
  common source tree with two build targets and two genuinely separate trees.
  A shared tree keeps fixes in one place but reintroduces the risk that an
  OOBE-only card is reachable in the account app — the exact thing the split is
  meant to make structurally impossible.
- **Entry point.** With OOBE hidden, a user who skips setup needs a route to the
  account app: catalog install, plus wherever Settings > Accounts should link.

## 2026-08-30 — six-scenario test pass, three bugs found and fixed

Real-hardware pass covering the three post-OOBE cases that matter for the
account app: proven 3.0.5, and two 3.1.0 shapes (RC's own built-in OOBE now
owns activation there — this repo doesn't touch it).

**Scenarios run, all pass on `1.1.15`:**

1. Fresh 3.1.0 → skip OOBE → restore a 3.0.5 backup → install → sign in to an
   existing account. Originally **broken** — this is where the duplicate-account
   bug (below) was found. Fixed and re-verified.
2. Fresh 3.1.0 → skip OOBE → install → sign in, no restore. Isolates that the
   duplicate only shows up with a restore in the picture (see below).
3. Fresh 3.1.0 → sign in during OOBE → install/open the app. Confirms the app
   leaves an already-correct account untouched (no stray `createLocalAccount`
   call at all when nothing needs changing).
4. Fresh 3.1.0 → skip OOBE → install → create a *new* account.
5. Fresh 3.1.0 → skip OOBE → install → sign in → sign out → sign in to a
   *different* account. Run twice (once on 1.1.14, once on a from-scratch
   1.1.15 flash) — clean both times.
6. Fresh 3.0.5 (community-OTA curl applied) → sign in → the original
   proven-in-prod path, re-verified against the current fixed build to confirm
   nothing regressed.

**Bug 1 — duplicate `com.palm.palmprofile` accounts on 3.1.0.**
`createLocalAccount` (`palm_profile_util.js`) and `SignOutCommandAssistant`
both found "the" palmprofile account by taking the *first*
`templateId === "com.palm.palmprofile"` match from `listAccounts` and stopping.
That was safe on 3.0.5, where our own OOBE patch was the only thing that could
leave a pre-existing row (the `"Dr. Skipped Firstuse"` bypass). On 3.1.0,
activation is the RC's own and out of our control — its OOBE-skip leaves its
own placeholder row (seen as `"webOS User"`), and a profile restore can drop
in a second, real one. First-match-wins then silently orphans whichever row it
doesn't touch: confirmed via `listAccounts` showing two rows (`"codepoet"` and
`"webOS User"`) after a sign-in that logged "no rename needed" against the
wrong one. Fix: both places now walk *every* match and rename each into
agreement, rather than stopping at the first. Deliberately does not delete the
extras — that runs the accounts-service teardown cascade, untested territory.

**Bug 2 — reachable "Start Over" button, exactly the class this doc already
called out.** `StartOver.js` (deletes the connected Wi-Fi profile) shipped
completely unpatched in `com.palm.app.webosaccount` — reachable from the terms
and sign-in cards, live-tested by accident (wiped a device's Wi-Fi, palm
profile untouched only because `Language.js` isn't in this app's `config.js`
card list). Fixed: `{kind: "StartOver"}` removed from both `Palm.js` and
`Signin.js`. `FirstUse.js`'s *other* route to the same behavior
(`StartOverFU` / `wifiPopupCancelDialogStartOver`, off the WiFiPopup cancel
dialog) is still there, unconfirmed whether it's reachable in this app's flow
— open item below.

**Bug 3 — `.stock` backup corruption, found on two separate test devices.**
`postinst`'s `[ ! -f "$SVC/$f.stock" ] && cp "$SVC/$f" "$SVC/$f.stock"`
snapshots whatever is *currently live* as "pristine." On any device that
already carries a prior install (true of both 3.1.0 test devices this
session), that's already-patched content — `prerm`'s restore-to-stock is
silently broken from that point on. Also, `GetAccountInfoAggregateAssistant.js`
was patched live with no backup entry in the loop at all, on any device, ever.
Fixed: genuine HP stock for all 8 files now lives in `service-stock/` (checked
into the repo — HP open-sourced webOS in 2012, so this isn't the same
copyright concern the diffs-not-source convention was guarding against),
`package.sh` stages it into the ipk, and `postinst` seeds `.stock` from that
instead of from live. Verified byte-exact against genuine stock (pulled fresh
from a webOS Doctor jar) on both a 3.1.0 and a 3.0.5 device after install.

**Also new this session:** the reference ipk build path no longer requires a
live device at all — `patches/*.patch` apply with real `patch` straight
against stock extracted from a webOS Doctor jar's
`nova-cust-image-topaz.rootfs.tar.gz`, which is how `1.1.13`–`1.1.15` were
actually built and how the createLocalAccount fix got its first real
apply-against-genuine-stock verification (as opposed to hand-editing an
already-patched device file, which is how the *first* attempt at this fix
went and is worth avoiding next time — see the ipk/postinst-style approach
instead).

**Open items, not yet acted on:**
- `FirstUse.js`'s WiFiPopup-cancel path to the same wifi-delete behavior
  (Bug 2, second path) — reachability in this app unconfirmed.
- Self-update (`Updater-Helper.js`) path from an old buggy version to a fixed
  one is untested — only fresh Preware installs were exercised.
- `prerm`/uninstall itself was never actually run this session, only reasoned
  about; not a priority per current scope, but worth knowing if it ever
  becomes one.
- `com.palm.app.accounts` (separate repo, the actual settings-app UI) wasn't
  independently exercised — coverage here is via `listAccounts`/`luna-send`
  plus on-screen confirmation, not that app's own code paths.

## Related

- `webos-doctor-ce` `build/community-firstuse/` — the OOBE swap and its deltas.
- `webos-doctor-ce` `build/full-ce/bake.py` tier 19c (f) — the nofork fix.
- The 1.1.3 catalog ipk is the reference for the account-app half.
