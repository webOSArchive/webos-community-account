# webOS device integration — account setup + unlock

On-device pieces that connect a physical webOS TouchPad (`topaz`) to the App Museum
account system. Companion to [`../DEVICE_ACCOUNT_PLAN.md`](../DEVICE_ACCOUNT_PLAN.md)
(the full plan, status, and polish list).

**Status:** verified working on hardware — sign in on-device with a catalog account,
it becomes the device profile, **without wiping the device**.

> These are **patches/diffs** against HP's stock webOS 3.0.5 (`Nova-HP-Topaz` build 86),
> not copies of HP's source. Apply them to the files already on the device. The installer
> `.uImage` is **not** included — extract it from your own `devicetoolAIO.jar` (below).

## Layout

```
webos/
├── patches/                         # unified diffs against stock webOS 3.0.5 (topaz, build 86)
│   ├── palm_profile_util.js.patch           # palmprofile SERVICE: base -> our backend (HTTPS via curlPost); upsert account
│   ├── LoginProfileCommandAssistant.js.patch# login: skip dead LCN precheck; create local profile
│   ├── IsEmailAvailableCommandAssistant.js.patch # create: email precheck -> our backend (was dead LCN)
│   ├── GetTermsAndConditionsCommandAssistant.js.patch # terms POST -> curlPost (HTTPS)
│   ├── FirstUse.js.patch                    # app: neuter erase/OTA/shutdown/powerdown; confirm page + Done
│   ├── Signin.js.patch                      # app: skip hanging PostSignIn OTA/backup checks
│   └── Palm.js.patch                        # app: terms card -> our TOS endpoint (skip dead LCN lookup)
├── app/
│   ├── appinfo.json                 # our app id com.palm.app.webosaccount (com.palm.* = privileged)
│   ├── config.js                    # FirstUse.config = [palm (terms), signin]
│   └── Updater-Helper.js            # vendored from webosarchive/webos-common (Enyo) — self-update
│                                    # via the Museum entry "webOS Community Account Manager"
│                                    # (Launcher icon = firstuse's own icon; the clone keeps it)
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

## Gotchas we hit (so you don't)

- **App id must start with `com.palm.`** — webOS grants privileged service/db8 access by id
  prefix; a `com.webosarchive.*` id gets permission-denied on carrier/wifi/db8 and hangs sign-in.
- **Localized `resources/<locale>/appinfo.json` override the base `appinfo.json`** — they each
  carry the id/title, so set the id in ALL of them (deploy.sh does).
- **App code is cached** — services hot-reload per call, but apps only re-read after a Luna
  restart / rescan. `killall LunaSysMgr` re-registers but is slow; `rescan` usually suffices.
- **NEVER let stock firstuse run to completion** — its completion path resets the device and
  wipes `/media/cryptofs/apps` (most 1P apps live there, not in ROM). Our app removes that path.
