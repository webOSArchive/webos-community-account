#!/bin/sh
# package-accounts.sh — build the Preware-installable IPK for the webOS Archive
# build of the stock Accounts app (com.palm.app.accounts).
#
# Unlike package.sh, this needs NO device: com.palm.app.accounts is real source in
# the webOS-ports core-apps repo (LG's Apache-2.0 release), so the payload is built
# straight from a checkout.
#
#   scripts/package-accounts.sh [path-to-webos-core-apps]
#
# The app REPLACES a stock rootfs app, so the ipk carries accounts-postinst /
# accounts-prerm, which back the original up and put it back on removal. Install via
# Preware or org.webosinternals.ipkgservice — the stock appinstaller does not run
# these scripts, so the package would stage without ever being applied.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CORE="${1:-$HERE/../AppCatalogIntegration/webos-core-apps}"
APPID=com.palm.app.accounts
SRC="$CORE/$APPID"
PKG=org.webosarchive.accountsapp

[ -d "$SRC" ] || { echo "!! $SRC not found — pass the path to your webos-core-apps checkout" >&2; exit 1; }

# Version comes from the app itself, so the package and the installed app can never
# disagree. Must sort above the stock app's 3.0-40 or ipkg refuses it as a downgrade.
VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC/appinfo.json" | head -1)
BUILD="$HERE/dist/accounts-build"
IPK="$HERE/dist/${PKG}_${VERSION}_all.ipk"
REL=media/cryptofs/webosarchive-accounts-overwrite

echo ">> 1) stage the app payload from $SRC"
rm -rf "$BUILD"; mkdir -p "$BUILD/data/$REL" "$BUILD/control" "$BUILD/payload"
# Only what the device needs. The repo also carries desktop-debugging extras
# (mock/, index-desktop.html, .project) that have no business on a device.
( cd "$SRC" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --numeric-owner \
    --exclude='mock' --exclude='.project' --exclude='index-desktop.html' \
    -cf - . ) | ( cd "$BUILD/payload" && tar xf - )
( cd "$BUILD/payload" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --numeric-owner \
    -czf "$BUILD/data/$REL/payload.tar.gz" . )

echo ">> 2) sanity-check the payload"
tar tzf "$BUILD/data/$REL/payload.tar.gz" | grep -q "./source/palmID/UsernameDialog.js"
tar tzf "$BUILD/data/$REL/payload.tar.gz" | grep -q "./source/RetainedDataView.js"
tar tzf "$BUILD/data/$REL/payload.tar.gz" | grep -q "./LICENSE"
tar tzf "$BUILD/data/$REL/payload.tar.gz" | grep -qv "./mock/" || true
# Locale appinfo files override the base, so a version bumped only in the base ships
# an app reporting the old one. Fail the build rather than ship the mismatch.
for f in "$BUILD/payload/resources"/*/appinfo.json "$BUILD/payload/resources"/*/*/appinfo.json; do
    [ -f "$f" ] || continue
    grep -q "\"version\": \"$VERSION\"" "$f" || {
        echo "!! $f does not carry version $VERSION — the locale override would win" >&2; exit 1; }
done
echo "   ok (version $VERSION, consistent base + locale overrides)"

echo ">> 3) assemble ipk"
cat > "$BUILD/control/control" <<EOF
Package: $PKG
Version: $VERSION
Section: misc
Priority: optional
Architecture: all
Maintainer: webOS Archive <webmaster@webosarchive.org>
Description: Accounts (webOS Archive build)
Source: {"Type": "Application", "Title": "Accounts", "FullDescription": "Replaces the stock Accounts app with the webOS-ports/LG open-source build, plus the webOS Archive profile editor: manage your community account from Settings > Accounts - name, email, password, a public username, the devices on your account, and sign out. Needs the webOS Account app for the account itself; without it the account row simply stays greyed out as before. The stock app is backed up on install and restored on uninstall."}
webOS-Package-Format-Version: 2
EOF
cp "$HERE/ipk/accounts-postinst" "$BUILD/control/postinst"
cp "$HERE/ipk/accounts-prerm"    "$BUILD/control/prerm"
cp "$HERE/ipk/accounts-postinst" "$BUILD/pmPostInstall.script"
cp "$HERE/ipk/accounts-prerm"    "$BUILD/pmPreRemove.script"
chmod 755 "$BUILD/control/postinst" "$BUILD/control/prerm" \
          "$BUILD/pmPostInstall.script" "$BUILD/pmPreRemove.script"
printf '2.0\n' > "$BUILD/debian-binary"

( cd "$BUILD/control" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --numeric-owner -czf ../control.tar.gz ./control ./postinst ./prerm )
( cd "$BUILD/data"    && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --numeric-owner -czf ../data.tar.gz ./media )

# GNU-style long filenames: pmPostInstall.script is 20 chars, and macOS ar defaults to
# the BSD "#1/20" scheme that BusyBox ar does not read. Written by hand to match the
# layout of the packages that are known to install on-device.
rm -f "$IPK"
python3 - "$BUILD" "$IPK" <<'PY'
import os, sys
b, out = sys.argv[1], sys.argv[2]
members = ["debian-binary", "control.tar.gz", "data.tar.gz", "pmPostInstall.script", "pmPreRemove.script"]
longtab, offs = b"", {}
for m in members:
    if len(m) + 1 > 16:
        offs[m] = len(longtab); longtab += m.encode() + b"/\n"
def hdr(name, size, mode=b"644"):
    return (name.ljust(16).encode() + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6)
            + mode.ljust(8) + str(size).encode().ljust(10) + b"`\n")
data = b"!<arch>\n"
if longtab:
    if len(longtab) % 2: longtab += b"\n"
    data += hdr("//", len(longtab), b"") + longtab
for m in members:
    raw = open(os.path.join(b, m), "rb").read()
    nm = "/%d" % offs[m] if m in offs else m + "/"
    data += hdr(nm, len(raw)) + raw + (b"\n" if len(raw) % 2 else b"")
open(out, "wb").write(data)
PY

echo ">> built: $IPK"
ls -la "$IPK"
