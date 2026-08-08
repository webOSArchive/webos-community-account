#!/bin/sh
# package.sh — build the distributable IPK for the webOS Account app.
#
# The app is BUILT ON A DEVICE (deploy.sh clones stock firstuse + applies our
# patches — we don't keep HP's source in the repo), so packaging PULLS the built
# artifacts from a device that deploy.sh has been run against:
#   1. /usr/palm/applications/com.palm.app.webosaccount  (the patched app)
#   2. the patched palmprofile service files (+ our updateUsername assistant)
#
# (The Accounts settings app is NOT packaged here — it now lives as source in the
# webOS-ports core-apps repo; see the note in deploy.sh.)
#
# and assembles a Preware-installable IPK whose postinst replays the deploy on
# the target device (app -> rootfs, service files patched with .stock backups).
#
# IMPORTANT: install via Preware / org.webosinternals.ipkgservice (this is what
# the on-device Museum app uses) — the stock appinstaller does not run postinst.
#
# Usage: deploy.sh first (and ideally verify sign-in), then: scripts/package.sh
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"      # webos/
PKG=org.webosarchive.webosaccount
VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$HERE/app/appinfo.json" | head -1)
APPID=com.palm.app.webosaccount
SVC=/usr/palm/services/com.palm.service.palmprofile
BUILD="$HERE/dist/build"
IPK="$HERE/dist/${PKG}_${VERSION}_all.ipk"

STAGE_REL=usr/palm/webosarchive/webosaccount   # under /media/cryptofs/apps on device
rm -rf "$BUILD"
mkdir -p "$BUILD/data/$STAGE_REL/service"

echo ">> 1) pull built app from device"
novacom run file:///bin/tar -- czf - -C /usr/palm/applications "$APPID" > "$BUILD/app.tgz"
mkdir -p "$BUILD/apptmp"
tar xzf "$BUILD/app.tgz" -C "$BUILD/apptmp"
mv "$BUILD/apptmp/$APPID" "$BUILD/data/$STAGE_REL/app"
find "$BUILD/data" -name '*.stock' -delete   # deploy.sh leaves pristine copies next to patched files

echo ">> 2) pull patched service files from device"
novacom run file:///bin/cat -- "$SVC/utils/palm_profile_util.js"                   > "$BUILD/data/$STAGE_REL/service/palm_profile_util.js"
novacom run file:///bin/cat -- "$SVC/handlers/LoginProfileCommandAssistant.js"     > "$BUILD/data/$STAGE_REL/service/LoginProfileCommandAssistant.js"
novacom run file:///bin/cat -- "$SVC/handlers/IsEmailAvailableCommandAssistant.js" > "$BUILD/data/$STAGE_REL/service/IsEmailAvailableCommandAssistant.js"
novacom run file:///bin/cat -- "$SVC/handlers/GetTermsAndConditionsCommandAssistant.js" > "$BUILD/data/$STAGE_REL/service/GetTermsAndConditionsCommandAssistant.js"
# username surface: getAccountToken publishes it, updateUsername sets it, and the
# two manifests are what make the new method exist on the bus at all.
novacom run file:///bin/cat -- "$SVC/handlers/GetTokenCommandAssistant.js"         > "$BUILD/data/$STAGE_REL/service/GetTokenCommandAssistant.js"
novacom run file:///bin/cat -- "$SVC/handlers/GetAccountInfoAggregateAssistant.js" > "$BUILD/data/$STAGE_REL/service/GetAccountInfoAggregateAssistant.js"
novacom run file:///bin/cat -- "$SVC/handlers/UpdateUsernameCommandAssistant.js"   > "$BUILD/data/$STAGE_REL/service/UpdateUsernameCommandAssistant.js"
novacom run file:///bin/cat -- "$SVC/handlers/SyncDeviceNameCommandAssistant.js"   > "$BUILD/data/$STAGE_REL/service/SyncDeviceNameCommandAssistant.js"
novacom run file:///bin/cat -- "$SVC/handlers/SignOutCommandAssistant.js"         > "$BUILD/data/$STAGE_REL/service/SignOutCommandAssistant.js"
novacom run file:///bin/cat -- "$SVC/services.json"                                > "$BUILD/data/$STAGE_REL/service/services.json"
novacom run file:///bin/cat -- "$SVC/sources.json"                                 > "$BUILD/data/$STAGE_REL/service/sources.json"

echo ">> 3) sanity-check the payload actually carries our patches"
grep -q "updateCompletePage" "$BUILD/data/$STAGE_REL/app/FirstUse.js"
grep -q "WOSA" "$BUILD/data/$STAGE_REL/app/source/tnc/Palm.js"
grep -q "WOSA_BASE" "$BUILD/data/$STAGE_REL/service/palm_profile_util.js"
grep -q "WOSA" "$BUILD/data/$STAGE_REL/service/IsEmailAvailableCommandAssistant.js"
grep -q "\"visible\": true" "$BUILD/data/$STAGE_REL/app/resources/en/appinfo.json"
grep -q "accountUsername" "$BUILD/data/$STAGE_REL/service/GetTokenCommandAssistant.js"
grep -q "updateUsername" "$BUILD/data/$STAGE_REL/service/services.json"
grep -q "UpdateUsernameCommandAssistant" "$BUILD/data/$STAGE_REL/service/sources.json"
# saveUsername's db8 write is async (Future), so a bare try/catch around it can
# never see a merge failure — without this chained .then() a stale local cache
# fails 100% silently (root cause of the getAccountToken-vs-Accounts-app mismatch).
grep -q "dbFuture.exception" "$BUILD/data/$STAGE_REL/service/UpdateUsernameCommandAssistant.js" || {
    echo "!! UpdateUsernameCommandAssistant.js on-device is missing the async cache-failure fix — redeploy first" >&2; exit 1; }
grep -q "syncDeviceName" "$BUILD/data/$STAGE_REL/service/services.json"
grep -q "signOut" "$BUILD/data/$STAGE_REL/service/services.json"
# The localized appinfo files OVERRIDE the base, so a version that only got bumped
# in the base ships an app that reports the OLD version while the ipk claims the new
# one — and the self-updater compares exactly those two. Fail the build instead.
for f in "$BUILD/data/$STAGE_REL/app/resources"/*/appinfo.json "$BUILD/data/$STAGE_REL/app/resources"/*/*/appinfo.json; do
    [ -f "$f" ] || continue
    grep -q "\"version\": \"$VERSION\"" "$f" || {
        echo "!! $f does not carry version $VERSION — locale override would win" >&2; exit 1; }
done
echo "   ok (version $VERSION consistent across base + $(ls -d "$BUILD/data/$STAGE_REL/app/resources"/*/ 2>/dev/null | wc -l | tr -d ' ') locale dirs)"

echo ">> 4) assemble ipk"
mkdir -p "$BUILD/control"
cat > "$BUILD/control/control" <<EOF
Package: $PKG
Version: $VERSION
Section: misc
Priority: optional
Architecture: all
Maintainer: webOS Archive <webmaster@webosarchive.org>
Description: webOS Community Account Manager
Source: {"Type": "Application", "Title": "webOS Account", "FullDescription": "Optional community account setup. Sign in with your webOS Archive account and it becomes this device's profile, unlocking App Catalog features and cloud app storage. Manage the account afterwards from Settings > Accounts: change your name, email, password, pick a public username, see which devices are on the account, and sign out. Installs a small patch redirecting the long-dead HP account service to the community backend (original files are preserved and restored on uninstall), over-writing the Dr. Skipped First Use with a more useful account."}
webOS-Package-Format-Version: 2
EOF
cp "$HERE/ipk/postinst" "$HERE/ipk/prerm" "$BUILD/control/"
chmod 755 "$BUILD/control/postinst" "$BUILD/control/prerm"

printf '2.0\n' > "$BUILD/debian-binary"
# BusyBox/ipkg-friendly tarballs: ustar format, root ownership, no macOS xattr
# turds, and the "./" member prefix ipkg's extractor REQUIRES (rc 22 without it)
( cd "$BUILD/control" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --numeric-owner -czf ../control.tar.gz ./control ./postinst ./prerm )
( cd "$BUILD/data"    && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --numeric-owner -czf ../data.tar.gz ./usr )
rm -f "$IPK"
( cd "$BUILD" && ar rc "$IPK" debian-binary control.tar.gz data.tar.gz )

echo ">> built: $IPK"
ls -la "$IPK"
