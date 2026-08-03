#!/bin/sh
# deploy.sh — deploy the webOS Archive account stack to an UNLOCKED, booted TouchPad.
# Prereqs: device dev-unlocked (see unlock.sh) + booted to home; host has `novacom` + `patch`.
# Run from anywhere; paths resolve relative to this script.
#
# What it does:
#   1. Patches the on-device palmprofile SERVICE -> our catalog backend (redirect + skip-LCN login).
#   2. Builds our optional account app com.palm.app.webosaccount from a neutered firstuse clone.
#   3. Registers it (rescan). Then launch it to sign in.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"      # webos/
PATCHES="$HERE/patches"; APP="$HERE/app"

SVC=/usr/palm/services/com.palm.service.palmprofile
FU=/usr/palm/applications/com.palm.app.firstuse
APPID=com.palm.app.webosaccount
APPDIR=/usr/palm/applications/$APPID

# dev '<shell>' : run a command on the device (pushed script — novacom `sh -c` is unreliable)
dev() { printf '%s\n' "$1" > /tmp/_dev.sh; novacom put file:///tmp/_dev.sh < /tmp/_dev.sh >/dev/null; novacom run file:///bin/sh -- /tmp/_dev.sh; }
# apply <device-path> <patch> : patch on host from a preserved stock copy, push back.
# Idempotent: the first touch saves <file>.stock on-device; every deploy re-patches from
# that pristine base (never from the live file — patch would auto-reverse an applied diff).
# -f makes a mismatched patch fail loudly (set -e aborts) instead of guessing.
apply() {
  dev "[ -f $1.stock ] || cp $1 $1.stock" >/dev/null
  novacom run file:///bin/cat -- "$1.stock" > /tmp/_patched 2>/dev/null
  patch -s -f /tmp/_patched "$2"
  novacom put "file://$1" < /tmp/_patched
  echo "  patched $1"
}

echo ">> 0) remount rootfs rw"
dev 'mount -o remount,rw / 2>/dev/null; echo ok'

echo ">> 1) patch palmprofile service (redirect + skip-LCN login + email precheck)"
apply "$SVC/utils/palm_profile_util.js"                   "$PATCHES/palm_profile_util.js.patch"
apply "$SVC/handlers/LoginProfileCommandAssistant.js"     "$PATCHES/LoginProfileCommandAssistant.js.patch"
apply "$SVC/handlers/IsEmailAvailableCommandAssistant.js" "$PATCHES/IsEmailAvailableCommandAssistant.js.patch"
apply "$SVC/handlers/GetTermsAndConditionsCommandAssistant.js" "$PATCHES/GetTermsAndConditionsCommandAssistant.js.patch"

echo ">> 2) build app: clone firstuse -> $APPID"
dev "rm -rf $APPDIR && cp -r $FU $APPDIR && echo cloned"
apply "$APPDIR/FirstUse.js"             "$PATCHES/FirstUse.js.patch"
apply "$APPDIR/source/signin/Signin.js" "$PATCHES/Signin.js.patch"
apply "$APPDIR/source/tnc/Palm.js"      "$PATCHES/Palm.js.patch"
novacom put "file://$APPDIR/appinfo.json" < "$APP/appinfo.json"
novacom put "file://$APPDIR/config.js"    < "$APP/config.js"
# (icon: the clone keeps firstuse's own images/icon.png — we are "cloning", not re-skinning)
# self-updater (vendored from webos-common); add it to the enyo.depends list
novacom put "file://$APPDIR/Updater-Helper.js" < "$APP/Updater-Helper.js"
dev "sed -i 's|\"config.js\",|\"config.js\",\\n\t\"Updater-Helper.js\",|' $APPDIR/depends.js && grep -c Updater-Helper $APPDIR/depends.js"
# CRITICAL: localized resources/<locale>/appinfo.json each carry the id and OVERRIDE the base.
# The id MUST start with com.palm. (webOS grants privileged calls by prefix) — set it everywhere.
# They also carry visible:false (firstuse is hidden) — flip it so the app gets a Launcher icon.
dev "for f in \$(find $APPDIR/resources -name appinfo.json); do sed -i 's/com\\.palm\\.app\\.firstuse/$APPID/g; s/HP webOS/webOS Account/g; s/\"visible\": false/\"visible\": true/g; s/\"vendor\": \"HP\"/\"vendor\": \"webOS Archive\"/g; s/\"version\": \"3.0.0\"/\"version\": \"1.0.0\"/g' \"\$f\"; done; echo reid-done"

echo ">> 3) register (rescan)"
dev 'luna-send -n 1 palm://com.palm.applicationManager/rescan "{}"'

echo ">> done. Launch it:"
echo "   printf 'luna-send -n 1 palm://com.palm.applicationManager/launch '\\''{\"id\":\"$APPID\"}'\\''\\n' > /tmp/l.sh; novacom put file:///tmp/l.sh < /tmp/l.sh; novacom run file:///bin/sh -- /tmp/l.sh"
