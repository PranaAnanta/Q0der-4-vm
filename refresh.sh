#!/bin/bash
# refresh.sh — One-click device identity refresh (run directly on the guest side)
# Usage: sudo bash refresh.sh
#
# Dependencies: fake_ioctl.c and fake_module.c must be in the same directory as this script
#               (auto-compiled and installed on first run)
#               runtime-info-final is in /opt/vm-fix/ (already deployed during deploy)
# Effect: each run outputs a brand-new machineToken + isVm=false + brand=None + pct=0
set -eu

BIN=/opt/vm-fix
FK=/tmp/fk
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===== 0. Environment check: compile and install .so (if not present) =====
echo "=== 0. Environment check ==="
mkdir -p $BIN

for name in fake_ioctl fake_module; do
    SRC="$SCRIPT_DIR/${name}.c"
    SO="$BIN/${name}.so"
    if [ ! -f "$SO" ] || [ "$SRC" -nt "$SO" ]; then
        if [ ! -f "$SRC" ]; then
            echo "  ✗ Cannot find $SRC"
            continue
        fi
        if ! command -v gcc >/dev/null 2>&1; then
            echo "  ✗ gcc is not installed, please run: sudo apt-get install -y gcc libc6-dev"
            continue
        fi
        # Show errors directly on the terminal, never swallow gcc's stderr
        if gcc -shared -fPIC -O2 -o "$SO" "$SRC" -ldl; then
            chmod 755 "$SO"
            echo "  ✓ Compiled and installed $name.so"
        else
            rm -f "$SO"   # Remove leftovers so a half-built .so is not loaded by the system
            echo "  ✗ $name.so compilation failed (gcc's specific errors are above)"
        fi
    else
        echo "  ✓ $name.so already exists"
    fi
done

# ld.so.preload self-heal: first strip entries pointing to missing files, then add the newly compiled .so
# (If preload contains a stale path, every process on the system reports object cannot be loaded)
PRELOAD=/etc/ld.so.preload
if [ -f "$PRELOAD" ]; then
    TMPP=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ""|\#*) continue ;; esac
        if [ -f "$line" ]; then
            printf '%s\n' "$line" >> "$TMPP"
        else
            echo "  ⚠ Removed stale entry from ld.so.preload: $line"
        fi
    done < "$PRELOAD"
    cat "$TMPP" > "$PRELOAD"
    rm -f "$TMPP"
fi
for name in fake_ioctl fake_module; do
    SO="$BIN/${name}.so"
    if [ -f "$SO" ] && ! grep -q "^$SO$" "$PRELOAD" 2>/dev/null; then
        echo "$SO" >> "$PRELOAD"
        echo "  ✓ Registered $name.so in ld.so.preload"
    fi
done
# Final check: if the dynamic linker still reports errors, expose it immediately instead of
# letting it blow up later in the SSH session
LDWARN=$(/bin/true 2>&1 || true)
case "$LDWARN" in
    *ld.so*|*cannot*be*loaded*) echo "  ✗ ld.so.preload is broken: $LDWARN" ;;
    *) echo "  ✓ /etc/ld.so.preload is configured and healthy" ;;
esac

# ===== 1. Clear token cache (force sgsdk to recompute) =====
echo "=== 1. Clear cache ==="
HAD_CACHE=0
[ -f ~/.config/.locale_cfg ] && HAD_CACHE=1
rm -f ~/.config/.locale_cfg /root/.config/.locale_cfg 2>/dev/null
rm -f ~/.config/.randomuuid_Lock /root/.config/.randomuuid_Lock 2>/dev/null
[ "$HAD_CACHE" = "1" ] && echo "  Deleted ~/.config/.locale_cfg (token cache)" || echo "  Cache does not exist (already a fresh state)"

# ===== 2. Clear VM traces =====
echo "=== 2. Clear VM traces ==="
rm -f /dev/vmci 2>/dev/null && echo "  Deleted /dev/vmci" || echo "  /dev/vmci does not exist"
pkill -x vmtoolsd 2>/dev/null && echo "  Stopped vmtoolsd" || echo "  vmtoolsd is not running"

# ===== 3. Regenerate fake data (fully random each time) =====
echo "=== 3. Generate fake data ==="
mkdir -p $FK $FK/ddddddddd

RS() { python3 -c "import random,string;print(''.join(random.choices(string.ascii_uppercase+string.digits,k=$1)))"; }
RN() { printf '%02x' $((RANDOM%256)); }

MODELS=("OptiPlex 7090" "OptiPlex 7080" "OptiPlex 3090" "Precision 3660" "Vostro 3681" "Inspiron 3891" "Latitude 5540")
BOARDS=("0HW7XV" "0PXXPG" "0K6H8V" "03Y7RV" "0W6H3V" "0Y7WC0")
MODEL=${MODELS[$((RANDOM % ${#MODELS[@]}))]}
BOARD=${BOARDS[$((RANDOM % ${#BOARDS[@]}))]}
SN=$(RS 7)
MAC="f8:bc:12:$(RN):$(RN):$(RN)"
CPUID=$(printf '%02x %02x %02x %02x %02x %02x %02x %02x' $(($RANDOM%256)) $(($RANDOM%256)) $(($RANDOM%256)) $(($RANDOM%256)) $(($RANDOM%256)) $(($RANDOM%256)) $(($RANDOM%256)) $(($RANDOM%256)))

printf 'Dell Inc.\n'                    > $FK/sys_vendor
printf "$MODEL\n"                        > $FK/product_name
printf '01\n'                            > $FK/product_version
printf 'Dell Inc.\n'                    > $FK/bios_vendor
printf "2.$((RANDOM%9+1)).$((RANDOM%9))" > $FK/bios_version
printf "0$((RANDOM%8+1))/1$((RANDOM%9))/202$((RANDOM%4+2))" > $FK/bios_date
printf 'Dell Inc.\n'                    > $FK/board_vendor
printf "$BOARD\n"                        > $FK/board_name
printf 'Dell Inc.\n'                    > $FK/ddddddddd/manufacturer
printf '01\n'                            > $FK/ddddddddd/product_version
printf "$SN\n"                           > $FK/product_serial
echo "  ID: $CPUID"                      > $FK/cpuid
echo "  Serial Number: $(RS 7)"          > $FK/board_sn
echo " SerialNo=$(RS 12)"               > $FK/disk_sn
echo "$MAC"                              > $FK/if_mac
echo "$MAC"                              > $FK/wlan_mac
echo "Linux version 6.8.0-48-generic"   > $FK/ver
echo "Character devices:\n  1 mem\n  4 tty\nBlock devices:\n  8 sd" > $FK/dev
printf 'sysfs /sys sysfs rw 0 0\nproc /proc proc rw 0 0\n/dev/sda2 / ext4 rw 0 0\n' > $FK/mnt

# Dynamic data (copied from the real machine and modified)
sed 's/hypervisor,//g;s/,hypervisor//g;s/ hypervisor / /g' /proc/cpuinfo > $FK/ci
cp /proc/meminfo $FK/mi 2>/dev/null
cat /proc/modules | grep -vE '^vmw_|^vmware|^vmxnet|^vsock|^vmci|^vmmon|^vmblock' > $FK/mod 2>/dev/null

# UUID
python3 -c "import uuid;print(str(uuid.uuid4()).upper())" > $FK/product_uuid 2>/dev/null

echo "  Device: Dell $MODEL"
echo "  Board: $BOARD"
echo "  Serial: $SN"
echo "  MAC: $MAC"

# ===== 4. Run patched ELF for verification =====
if [ -f $BIN/runtime-info-final ] && [ -x $BIN/runtime-info-final ]; then
    echo ""
    echo "=== Verification output ==="
    bash -c "$BIN/runtime-info-final 0 2>/dev/null" || \
    $BIN/runtime-info-final 0 2>/dev/null
fi