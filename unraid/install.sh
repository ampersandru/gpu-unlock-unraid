#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Stage persistent files only. Never load the module in this running session.
set -euo pipefail
[[ $EUID -eq 0 && $# -eq 2 ]] || { echo "Usage (as root): bash $0 /absolute/payload-directory 0000:01:00.0|all|PCI,PCI" >&2; exit 1; }
PAYLOAD=$(cd -- "$1" && pwd)
TARGET=${2,,}
KREL=$(uname -r)
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE=/boot/config/gpu-unlock-unraid
CONF=/boot/config/modprobe.d/gpu-unlock-unraid.conf
if [[ "$TARGET" != all ]]; then
    [[ "$TARGET" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7](,[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])*$ ]]
    IFS=, read -ra DEVICES <<< "$TARGET"
    declare -A SEEN=()
    for DEVICE in "${DEVICES[@]}"; do
        if [[ -v SEEN[$DEVICE] ]]; then
            echo "STOP: duplicate PCI target: $DEVICE" >&2
            exit 1
        fi
        SEEN[$DEVICE]=1
        DEVICE_PATH="/sys/bus/pci/devices/$DEVICE"
        test -d "$DEVICE_PATH"
        test "$(cat "$DEVICE_PATH/vendor")" = 0x10de
        CLASS=$(cat "$DEVICE_PATH/class")
        [[ "$CLASS" == 0x03* ]]
    done
fi
test -s "$PAYLOAD/gpu_unlock.ko"
test -d "$PAYLOAD/firmware/gpu-unlock/610.43.03"
(cd "$PAYLOAD" && sha256sum -c SHA256SUMS)
test "$(modinfo -F vermagic "$PAYLOAD/gpu_unlock.ko" | cut -d ' ' -f1)" = "$KREL"
if modinfo nvidia >/dev/null 2>&1; then
    test "$(modinfo -F vermagic "$PAYLOAD/gpu_unlock.ko")" = "$(modinfo -F vermagic nvidia)"
fi
test -x /usr/bin/flock
sh -n "$ROOT/pre-nvidia.sh"
# Exclude our own configuration on repeat installs; stop for other install hooks.
CONFLICT=$(grep -RHnE '^[[:space:]]*install[[:space:]]+nvidia[[:space:]]' \
    /etc/modprobe.d /run/modprobe.d /usr/local/lib/modprobe.d /lib/modprobe.d \
    /boot/config/modprobe.d 2>/dev/null | grep -v '/gpu-unlock-unraid.conf:' || true)
if [ -n "$CONFLICT" ]; then
    printf 'STOP: another NVIDIA install hook exists. Review it first:\n%s\n' "$CONFLICT" >&2
    exit 1
fi
if [ -r "$BASE/target" ] && [ "$(cat "$BASE/target")" != "$TARGET" ]; then
    echo 'STOP: existing installation targets another GPU.' >&2; exit 1
fi
mkdir -p "$BASE/kernels" /boot/config/modprobe.d
test ! -e "$BASE/kernels/$KREL" || { echo "Payload already installed for $KREL; preserve or move it before replacing." >&2; exit 1; }
STAGE=$(mktemp -d "$BASE/kernels/.staging.XXXXXX")
cp -R "$PAYLOAD/." "$STAGE/"
mv "$STAGE" "$BASE/kernels/$KREL"
cp "$ROOT/pre-nvidia.sh" "$BASE/pre-nvidia.sh.new"
mv "$BASE/pre-nvidia.sh.new" "$BASE/pre-nvidia.sh"
printf '%s\n' "$TARGET" > "$BASE/target"
cat > "$CONF.new" <<'CONF'
install nvidia /bin/sh /boot/config/gpu-unlock-unraid/pre-nvidia.sh; /sbin/modprobe --ignore-install nvidia $CMDLINE_OPTS
CONF
mv "$CONF.new" "$CONF"
printf '\nStaged only. Add this parameter to your normal Unraid boot entry and Apply:\ngpu_unlock.targets=%s\n' "$TARGET"
echo 'Leave a recovery/Safe Mode entry unchanged. Reboot cleanly, then run unraid/status.sh.'
echo 'No running module, driver, or GPU state was changed.'
