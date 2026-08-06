# webOS Community Account Manager

On-device pieces that connect a physical webOS TouchPad (`topaz`) to an App Museum catalog
account system. This will be used to enable Developers to manage their apps, users to provide
feedback (reviews, ratings) on apps, and potentially other functionality in the future.

**Status:** verified working on hardware — sign in on-device with a catalog account,
it becomes the device profile, **without wiping the device**.

> These are **patches/diffs** against HP's stock webOS 3.0.5 (`Nova-HP-Topaz` build 86),
> not copies of HP's source. Apply them to the files already on the device. The installer
> `.uImage` is **not** included — extract it from your own `devicetoolAIO.jar` (below).

## Layout

```
webos/
├── patches/                         # unified diffs against stock webOS 3.0.5 (topaz, build 86)
│   ├── palm_profile_util.js.patch           # palmprofile SERVICE: base -> our backend (HTTPS via curlPost); upsert account; cache username
│   ├── LoginProfileCommandAssistant.js.patch# login: skip dead LCN precheck; create local profile
│   ├── IsEmailAvailableCommandAssistant.js.patch # create: email precheck -> our backend (was dead LCN)
│   ├── GetTermsAndConditionsCommandAssistant.js.patch # terms POST -> curlPost (HTTPS)
│   ├── GetTokenCommandAssistant.js.patch    # getAccountToken also returns accountUsername
│   ├── services.json.patch                  # register updateUsername / syncDeviceName / signOut
│   ├── sources.json.patch                   # load the three assistants below
│   ├── FirstUse.js.patch                    # app: neuter erase/OTA/shutdown/powerdown; confirm page + Done
│   ├── Signin.js.patch                      # app: skip hanging PostSignIn OTA/backup checks;
│   │                                        # one completion card for both sign-in and a
│   │                                        # relaunch that finds an account already set up
│   │                                        # (forceSignIn:true skips straight to setup); honest
│   │                                        # wrong-password/-email copy instead of a fallback
│   │                                        # that reads like a server outage; syncDeviceName
│   │                                        # call before finishing
│   ├── Palm.js.patch                        # app: terms card -> our TOS endpoint (skip dead LCN lookup)
│                                            # (the Accounts settings APP is not patched here — see below)
├── service/
│   ├── UpdateUsernameCommandAssistant.js    # ours, not HP's: palm://com.palm.accountservices/updateUsername
│   ├── SyncDeviceNameCommandAssistant.js    # ours: reads the local device name, publishes it to the account
│   └── SignOutCommandAssistant.js           # ours: revokes the token server-side, then clears it locally
├── app/
│   ├── appinfo.json                 # our app id com.palm.app.webosaccount (com.palm.* = privileged)
│   ├── config.js                    # FirstUse.config = [palm (terms), signin]
│   ├── Updater-Helper.js            # vendored from webosarchive/webos-common (Enyo) — self-update
│   │                                # via the Museum entry "webOS Community Account Manager"
│   │                                # (Launcher icon = firstuse's own icon; the clone keeps it)
│                                    # (the Accounts app's Username row lives in webos-core-apps)
├── ipk/
│   ├── postinst                     # run by Preware/ipkgservice as root: app -> rootfs, patch service
│   └── prerm                        # uninstall: restore <file>.stock service files, remove app
├── scripts/
│   ├── unlock.sh                    # reproduce deviceTool's dev-unlock + OOBE-skip (no jar run)
│   ├── deploy.sh                    # apply patches + build the app + register it (dev workflow)
│   └── package.sh                   # pull built app from device -> Preware-installable IPK (dist/)
└── README.md
```

The **server side** lives in the main repo, already deployed:
`WebService/device.php` (the account backend the device talks to) + `AccountRepository`
device-token methods. See `DEVICE_ACCOUNT_PLAN.md` §3.

## 1. Unlock (only after a fresh webOS Doctor)

A stock-Doctored device is locked — **no novacom until it's developer-unlocked**. We
reverse-engineered `devicetoolAIO.jar`: it memboots a per-device installer ramdisk and
sets two flag files. The persistent unlock is a single file, `/var/gadget/novacom_enabled`.

```sh
# extract the topaz installer image from your own copy of the jar:
unzip -p /path/to/devicetoolAIO.jar \
  com/palm/webos/devicetool/images/nova-installer-image-topaz.uImage > topaz.uImage
# put the device in RECOVERY mode (Vol-Up held while inserting battery -> USB symbol), then:
scripts/unlock.sh topaz.uImage
```

Skipping OOBE also auto-creates the bypass "Dr. Skipped Firstuse" profile (via
`/etc/event.d/firstuse-createDefaultAccount`), so the device lands activated.

**Community-OTA implication:** ship `/var/gadget/novacom_enabled` present → every device is
novacom-capable out of the box; deviceTool never needed again.

## 2. Deploy the account stack

Device unlocked + booted to home, then:

```sh
scripts/deploy.sh          # patches the service, builds com.palm.app.webosaccount, registers it
```

Launch the app (or, eventually, a Preferences shortcut), sign in with a catalog account
(username or email + password). On success it writes the device profile + token and closes.

## 3. Package for distribution (Museum / Preware)

The app is built on-device (we ship diffs, not HP source), so packaging pulls the
built artifacts back off a deployed device:

```sh
scripts/deploy.sh          # build + verify on the dev device first
scripts/package.sh         # -> dist/org.webosarchive.webosaccount_<ver>_all.ipk
```

The IPK stages its payload under `/media/cryptofs/apps/usr/palm/webosarchive/` and a
`postinst` (run as **root** by Preware / `org.webosinternals.ipkgservice`) replays the
deploy: app into rootfs `/usr/palm/applications/`, palmprofile service patched with
pristine `<file>.stock` backups. `prerm` restores stock and removes the app.

**Install path matters:** the on-device Museum app installs by handing the IPK URL to
Preware (`org.webosinternals.preware {type:"install"}`), whose ipkgservice runs install
scripts. The **stock** appinstaller does NOT run postinst — the package would stage but
never activate. List it in the catalog so the Museum/Preware path is used.

ipkg format gotcha: members inside `control.tar.gz`/`data.tar.gz` MUST be `./`-prefixed
(`./control`, `./usr/...`) — webOS's ipkg 0.99 rejects the archive (rc 22) otherwise.

## Transport: HTTPS via curl shim (not the service's node TLS)

The account calls originate in the palmprofile JS service, whose HTTP client
(`Foundations.Comms.AjaxCall`) runs on the stock **node 0.4.12 TLS**, which
Cloudflare rejects (`socket hang up`). The community OTA ships a modern
`/usr/bin/curl` (OpenSSL 1.1.1w, TLS 1.3) but the framework never uses it. So
`palm_profile_util.js` adds **`curlPost()`** — shells out to `/usr/bin/curl` via
node `child_process`, returns a Future shaped like `AjaxCall.post`
(`result.responseJSON/responseText/status`). `postRequestInternal` and the terms
assistant route through it; every account/terms POST is real HTTPS. **Requires the
community-OTA curl fix on the device** — which is a hard install prerequisite for
this app anyway.

**HTTPS-readiness gate:** the terms card is the flow's first secure fetch, so it
doubles as an environment check. On success it enables Continue; on failure it
keeps Continue disabled and shows an "Update required" popup telling the user to
install the community update. A device without the modern-TLS curl can't get past
the terms card into sign-in/create.

## The Accounts app (settings) — profile editing and usernames

Signing in is one app; *managing* the account is another. The stock **Accounts**
settings app (`com.palm.app.accounts`) has always had a full profile editor
behind the account row at the top — name, email, password, and the list of
devices on the account (`source/palmID/`). It was dead on arrival for us: its
entry call `getAggregatedAccountInfo` had no backend, so tapping the row showed
*"Error — Must be connected to a network to communicate with HP's Cloud
Services."* That message is a red herring; the network was always fine.

Almost all of the fix is **server-side** — those assistants are stock and already
post through our patched transport, so `device.php` just had to answer them
(`getAccountInfoAggregate`, `isUserValid`, `updateAccountInfo`,
`changeEmailAddress`, `changePassword`, `assignDeviceName`).

> **The app-side work is not in this repo.** It lives as source in
> [webOSArchive/webos-core-apps](https://github.com/webOSArchive/webos-core-apps)
> under `com.palm.app.accounts`, which is LG's Apache-2.0 release of the same app
> — shareable as source instead of as diffs against HP's binary, and the base
> Herrie is already building on, so the two efforts converge there rather than
> forking. This repo still owns everything on the **service** side below.

What changed on the app side:

- **Username instead of security question.** We store no security answers, so
  that row now edits the account's **username**. Accounts are created with the
  username set to the member's email address; this is where they pick a real
  handle — shareable, and more private than an email. New `UsernameDialog.js`,
  plus `updateUsername` on the service.
- **Other apps read the username from `getAccountToken`**, which now returns
  `accountUsername` alongside `accountAlias` and `token`. That is the intended
  integration point — apps already call it for the token. It falls back to the
  alias, so callers never need a null check. `UpdateUsernameCommandAssistant`
  writes the new handle straight into the local db8 profile on success, so the
  change is visible to other apps immediately rather than at next sign-in.
- **Device list.** `assignDeviceName` had never been implemented server-side and
  was failing silently, which is why the DEVICES section had nothing readable in
  it. It works now; model and OS are captured from the device block already sent
  at sign-in.
- Two stock bugs fixed while in there: an empty device list rendered one row of
  "undefined" (HP wrapped a lone object by testing `.length`, which also wraps an
  empty array), and the password dialog enforced 6 characters where the server
  requires 8.

**`services.json` and `sources.json` are both patched** — a new bus method needs
an entry in each (method→assistant, and the file to load). Unlike handlers, which
hot-reload per call, these are only read when the service host starts, so
`deploy.sh`/`postinst` kill the palmprofile process to force a respawn. Skip that
and `updateUsername` stays unknown until the next reboot.

## Device name sync and sign-out

Two more service methods behind the profile editor, both called from the
`com.palm.app.accounts` side but implemented here:

- **`syncDeviceName`** — pushes this device's current name up to the account,
  falling back to `"TouchPad"` if the device has none. Read-only on the local
  name: **not** the stock `assignDeviceNameNoAcctInfoArgs`, which looks like it
  does the same job but actually *writes* the local name (composing a possessive
  `"<user>'s TouchPad"`) — calling that on every profile open would rename the
  device each time. The Accounts app calls it before every profile fetch, so a
  rename in Settings shows up immediately rather than one visit later; `Signin.js`
  also calls it once at the end of sign-in, since `assignDeviceName` (the original
  namer) only ever ran on the account-*create* path, never on plain sign-in.
- **`signOut`** — revokes the token server-side (`device.php?m=deauthenticate`)
  and clears it locally *even if the server call fails*, so a member can't get
  stranded signed-in by a bad connection. Also renames the local account record
  to `"Local User"` rather than merely clearing the token: the record is left in
  place (deleting it breaks `com.palm.app.accounts`, which reads
  `palmProfileAccount.username`/`.icon` unguarded), so if the previous member's
  actual name stayed on it, the next person to pick up the device would see it.

## Gotchas we hit (so you don't)

- **App id must start with `com.palm.`** — webOS grants privileged service/db8 access by id
  prefix; a `com.webosarchive.*` id gets permission-denied on carrier/wifi/db8 and hangs sign-in.
- **Localized `resources/<locale>/appinfo.json` override the base `appinfo.json`** — they each
  carry the id/title, so set the id in ALL of them (deploy.sh does).
- **App code is cached** — services hot-reload per call, but apps only re-read after a Luna
  restart / rescan. `killall LunaSysMgr` re-registers but is slow; `rescan` usually suffices.
- **NEVER let stock firstuse run to completion** — its completion path resets the device and
  wipes `/media/cryptofs/apps` (most 1P apps live there, not in ROM). Our app removes that path.
- **Bump the version on every rebuild, even packaging-only changes with no app-code
  difference.** Rebuilding an ipk under the identical filename let Preware/WOSQI serve a
  stale cached copy on a real install — the correct file existed on disk the whole time,
  but the wrong one got installed, and it looked exactly like the postinst fix hadn't
  taken (see 1.1.1). Confirmed by pulling the file Preware had actually fetched and
  finding it timestamped from the earlier build. A same-named rebuild is indistinguishable
  from no rebuild at all to anything caching by filename.
- **A bus method needs its handler file copied in `postinst`, not just declared in
  `sources.json`.** Adding `syncDeviceName`/`signOut` to `services.json`/`sources.json`
  without adding them to postinst's file-copy loop shipped an ipk where the manifest
  named handlers that were never actually placed at `$SVC/handlers/` — the app calls
  worked in every *manual* test (deploy.sh's separate per-file push loop always installed
  all three directly) but silently failed on a real from-scratch install. `sources.json`
  and the copy loop are two lists that have to be kept in sync by hand; there's nothing
  that checks this for you.
