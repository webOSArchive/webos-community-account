#!/bin/sh
# unlock.sh — dev-unlock + OOBE-bypass a webOS-Doctored TouchPad WITHOUT deviceTool.
# Reverse-engineered from devicetoolAIO.jar (com.palm.webos.devicetool.DeviceTool):
# memboot a per-device installer ramdisk, then touch two flag files, then reboot.
#
# The persistent "developer unlock" is a single file: /var/gadget/novacom_enabled
# (novacomd checks it every boot). OOBE bypass is /var/luna/preferences/ran-first-use.
#
# PREREQ 1: extract the installer image for your device codename (topaz = TouchPad):
#   unzip -p devicetoolAIO.jar \
#     com/palm/webos/devicetool/images/nova-installer-image-topaz.uImage > topaz.uImage
# PREREQ 2: put the device in RECOVERY (bootie) mode:
#   remove battery + unplug USB -> hold Volume-Up -> plug USB in ->
#   keep holding Volume-Up -> insert battery -> a big USB symbol appears.
#   Confirm: `novacom -l` shows "... topaz-bootie".
#
# Usage: ./unlock.sh [topaz.uImage]
set -e
IMG="${1:-topaz.uImage}"
[ -f "$IMG" ] || { echo "installer image '$IMG' not found (see PREREQ 1)"; exit 1; }

echo ">> memboot installer ramdisk ($IMG)"
novacom -d topaz-bootie boot mem:// < "$IMG"
echo ">> waiting for installer env..."
sleep 20

cat > /tmp/wosa-unlock-dev.sh <<'DEV'
set -e
/usr/sbin/lvm.static vgscan
/usr/sbin/lvm.static vgchange -ay
/bin/mkdir -p /tmp/var
/bin/mount /dev/store/var /tmp/var
/bin/mkdir -p /tmp/var/gadget           ; /bin/touch /tmp/var/gadget/novacom_enabled          # dev-unlock
/bin/mkdir -p /tmp/var/luna/preferences ; /bin/touch /tmp/var/luna/preferences/ran-first-use  # OOBE skip
/bin/sync ; /bin/sync ; /bin/sync
/bin/umount /tmp/var
/usr/sbin/lvm.static vgchange -an
/bin/sleep 2
echo "flags written; rebooting"
/sbin/tellbootie reboot
DEV
novacom put file:///tmp/wosa-unlock-dev.sh < /tmp/wosa-unlock-dev.sh
novacom run file:///bin/sh -- /tmp/wosa-unlock-dev.sh || true   # tellbootie drops the connection

echo ">> done. Device is rebooting into the real OS."
echo ">> After boot, 'novacom -l' should still show the device = unlock persisted."
echo ">> (Skipping OOBE also auto-creates the bypass 'Dr. Skipped Firstuse' profile"
echo ">>  via /etc/event.d/firstuse-createDefaultAccount — device lands activated.)"
