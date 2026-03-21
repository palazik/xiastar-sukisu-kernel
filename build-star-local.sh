#!/usr/bin/env bash
# ============================================================
#  Build script — Mi 11 Ultra (star, SM8350/lahaina)
#  SukiSU Ultra + SuSFS | non-permissive SELinux
# ============================================================
set -euo pipefail

# ── CONFIG — edit these as needed ───────────────────────────
KERNEL_REPO="https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git"
KERNEL_BRANCH="star-r-oss"
SUKISU_TAG="main"                     # empty = latest main
SUSFS_BRANCH="kernel-5.4"            # match your kernel version
USE_KPROBES=false                     # true = kprobes, false = manual hook
DISABLE_REAR_DISPLAY=true            # true = disable rear/secondary display in DTS
DEFCONFIG="star_user_defconfig"
ARCH="arm64"

# ── PATHS ───────────────────────────────────────────────────
ROOT_DIR="$(pwd)/build_star"
KERNEL_DIR="$ROOT_DIR/kernel"
TC_DIR="$ROOT_DIR/toolchain"
ANYKERNEL_DIR="$ROOT_DIR/anykernel"
OUT_DIR="$ROOT_DIR/out"
LOG_DIR="$ROOT_DIR/logs"

# ── COLORS ──────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${BLU}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GRN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YLW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 0. Prep dirs ─────────────────────────────────────────────
log_info "Creating build directories..."
mkdir -p "$KERNEL_DIR" "$TC_DIR" "$ANYKERNEL_DIR" "$OUT_DIR" "$LOG_DIR"

# ── 1. Install deps (Debian/Ubuntu) ─────────────────────────
log_info "Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    bc bison build-essential ca-certificates curl flex git \
    libelf-dev libssl-dev lld llvm make python3 \
    unzip wget zip zlib1g-dev aarch64-linux-gnu-gcc \
    gcc-arm-linux-gnueabi 2>&1 | tee "$LOG_DIR/deps.log"

# ── 2. Toolchain (ZyCromerZ Clang 15) ───────────────────────
if [ ! -f "$TC_DIR/bin/clang" ]; then
    log_info "Downloading Clang 15 toolchain..."
    CLANG_URL=$(curl -s https://raw.githubusercontent.com/ZyCromerZ/Clang/main/Clang-15-link.txt)
    wget -q --show-progress "$CLANG_URL" -O "$TC_DIR/clang.tar.gz"
    tar -xf "$TC_DIR/clang.tar.gz" -C "$TC_DIR"
    rm "$TC_DIR/clang.tar.gz"
    log_ok "Clang ready: $($TC_DIR/bin/clang --version | head -1)"
else
    log_ok "Clang already present, skipping download."
fi
export PATH="$TC_DIR/bin:$PATH"

# ── 3. Clone kernel ──────────────────────────────────────────
if [ ! -d "$KERNEL_DIR/.git" ]; then
    log_info "Cloning kernel source ($KERNEL_BRANCH)..."
    git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR" \
        2>&1 | tee "$LOG_DIR/clone_kernel.log"
else
    log_ok "Kernel source already cloned."
fi
KVER=$(make -C "$KERNEL_DIR" ARCH=$ARCH kernelversion 2>/dev/null | head -1)
log_ok "Kernel version: $KVER"

# ── 4. Integrate SukiSU Ultra ────────────────────────────────
log_info "Integrating SukiSU Ultra..."
cd "$KERNEL_DIR"
if [ -n "$SUKISU_TAG" ]; then
    curl -LSs \
        "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/${SUKISU_TAG}/kernel/setup.sh" \
        | bash -s "$SUKISU_TAG"
else
    curl -LSs \
        "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" \
        | bash -s main
fi
log_ok "SukiSU integrated."

# ── 4b. Compatibility fixes ──────────────────────────────────
log_info "Applying compatibility fixes..."
cd "$KERNEL_DIR"

# Fix techpack implicit-int (Clang compat)
for f in \
    "techpack/display/msm/sde/sde_hw_dsc_1_2.c:_dsc_subblk_offset" \
    "techpack/display/msm/sde/sde_hw_vdc.c:_vdc_subblk_offset"; do
    file="${f%%:*}"; func="${f##*:}"
    [ -f "$file" ] && sed -i "s/static inline ${func}(/static inline int ${func}(/" "$file" && log_ok "Patched: $file"
done

# Fix SukiSU for kernel-5.4
if [ -f drivers/kernelsu/allowlist.c ]; then
    sed -i 's/TWA_RESUME/0/g' drivers/kernelsu/allowlist.c
    grep -q 'linux/sched/task.h' drivers/kernelsu/allowlist.c || \
        sed -i '1s|^|#include <linux/sched/task.h>\n|' drivers/kernelsu/allowlist.c
fi
[ -f drivers/kernelsu/app_profile.c ] && \
    sed -i '/seccomp\.filter_count/d' drivers/kernelsu/app_profile.c
if [ -f drivers/kernelsu/sucompat.c ]; then
    sed -i 's|<linux/pgtable.h>|<asm/pgtable.h>|g' drivers/kernelsu/sucompat.c
    sed -i 's/strncpy_from_user_nofault/strncpy_from_user/g' drivers/kernelsu/sucompat.c
fi
# Fix setuid_hook.c seccomp cache error
[ -f drivers/kernelsu/setuid_hook.c ] && \
    sed -i 's/ksu_seccomp_allow_cache/\/\/ ksu_seccomp_allow_cache/g' drivers/kernelsu/setuid_hook.c
# pkg_observer.c: fsnotify API incompatible with 5.4 (replace with empty stub)
if [ -f drivers/kernelsu/pkg_observer.c ]; then
    cat > drivers/kernelsu/pkg_observer.c << 'EOF'
// pkg_observer stubbed for kernel-5.4
#include <linux/kernel.h>
void ksu_pkg_observer_init(void) {}
void ksu_pkg_observer_exit(void) {}
EOF
    log_ok "Stubbed: drivers/kernelsu/pkg_observer.c"
fi
log_ok "Compatibility fixes applied."

# ── 5. Apply SuSFS ──────────────────────────────────────────
log_info "Applying SuSFS patches ($SUSFS_BRANCH)..."
git clone --depth=1 -b "$SUSFS_BRANCH" \
    https://gitlab.com/simonpunk/susfs4ksu.git /tmp/susfs4ksu

cd "$KERNEL_DIR"
# Copy patch files
cp /tmp/susfs4ksu/kernel_patches/add_susfs_in_kernel-*.patch . 2>/dev/null || \
cp /tmp/susfs4ksu/kernel_patches/*.patch . 2>/dev/null

# Apply patches with fuzz tolerance
for patch_file in *.patch; do
    log_info "Applying: $patch_file"
    patch -p1 --no-backup-if-mismatch --fuzz=3 --forward --batch < "$patch_file" || {
        log_error "Patch failed: $patch_file"
        exit 1
    }
done

# Copy susfs source files
cp /tmp/susfs4ksu/kernel_patches/fs/susfs.c   fs/
cp /tmp/susfs4ksu/kernel_patches/include/linux/susfs.h include/linux/
cp /tmp/susfs4ksu/kernel_patches/fs/sus_su.c  fs/  2>/dev/null || true
cp /tmp/susfs4ksu/kernel_patches/include/linux/sus_su.h include/linux/ 2>/dev/null || true
log_ok "SuSFS source files copied."

# ── 6. Configure defconfig ───────────────────────────────────
log_info "Configuring defconfig..."
DEFCONFIG_PATH="arch/arm64/configs/$DEFCONFIG"

# Hook method
if $USE_KPROBES; then
    echo "CONFIG_KSU_WITH_KPROBES=y" >> "$DEFCONFIG_PATH"
    log_info "Hook: KProbes"
else
    echo "# CONFIG_KSU_WITH_KPROBES is not set" >> "$DEFCONFIG_PATH"
    log_info "Hook: manual (non-kprobes)"
fi

# Non-permissive SELinux
sed -i 's/CONFIG_SECURITY_SELINUX_BOOTPARAM=y/# CONFIG_SECURITY_SELINUX_BOOTPARAM is not set/g' \
    "$DEFCONFIG_PATH" 2>/dev/null || true
sed -i '/CONFIG_SECURITY_SELINUX_DEVELOP/d' "$DEFCONFIG_PATH" 2>/dev/null || true
sed -i 's/androidboot\.selinux=permissive//g' "$DEFCONFIG_PATH" 2>/dev/null || true

# KSU + SuSFS Kconfig
cat >> "$DEFCONFIG_PATH" << 'EOF'

# SukiSU Ultra + SuSFS
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_SU=y
# Fix: pin LTO to None — prevents interactive kconfig prompt (CI has no stdin)
CONFIG_RTC_LIB=y
CONFIG_LTO_NONE=y
# CONFIG_LTO_CLANG is not set
EOF
log_ok "Defconfig prepared."

# ── 7b. Disable rear/secondary display in DTS ───────────────
if $DISABLE_REAR_DISPLAY; then
    log_info "Disabling rear (secondary) display in DTS..."

    # ── Strategy 1: remove qcom,dsi-display-active from secondary display node
    # The secondary (rear) display node in lahaina star DTS is typically named
    # something like dsi_display1 / sde_dsi_display1 / sub_display.
    # We search all DTS files and strip the active marker from non-primary nodes.

    DTS_SEARCH_DIR="$KERNEL_DIR/arch/arm64/boot/dts/qcom"

    # Find the secondary display node file (star-specific SDE display dtsi)
    # MiCode star-r-oss puts the secondary display in lahaina-sde-display.dtsi
    # or star-sde-display.dtsi — handle both
    for dtsi_file in \
        "$DTS_SEARCH_DIR/lahaina-sde-display.dtsi" \
        "$DTS_SEARCH_DIR/star-sde-display.dtsi" \
        "$DTS_SEARCH_DIR/lahaina-star-sde-display.dtsi"; do
        if [ -f "$dtsi_file" ]; then
            log_info "Found display dtsi: $dtsi_file"

            # Count how many display nodes have qcom,dsi-display-active
            ACTIVE_COUNT=$(grep -c "qcom,dsi-display-active" "$dtsi_file" || true)
            log_info "Found $ACTIVE_COUNT active display nodes"

            if [ "$ACTIVE_COUNT" -gt 1 ]; then
                # Keep only the FIRST occurrence (primary), remove all others
                # Mark secondary nodes by removing their active flag
                python3 - "$dtsi_file" << 'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find all blocks that contain qcom,dsi-display-active
# Remove the property from all blocks where qcom,display-type = "secondary"
# Pattern: within a node block containing display-type = "secondary",
#          delete the qcom,dsi-display-active line
modified = re.sub(
    r'(qcom,display-type\s*=\s*"secondary"[^}]*?)(^\s*qcom,dsi-display-active;\n)',
    r'\1',
    content,
    flags=re.MULTILINE | re.DOTALL
)

if modified != content:
    with open(path, 'w') as f:
        f.write(modified)
    print(f"[OK] Removed qcom,dsi-display-active from secondary display node")
else:
    print("[WARN] Pattern not matched — trying fallback line-based approach")
    # Fallback: comment out second occurrence of qcom,dsi-display-active
    lines = content.split('\n')
    found = 0
    out = []
    for line in lines:
        if 'qcom,dsi-display-active' in line:
            found += 1
            if found > 1:
                out.append('\t\t/* DISABLED: rear display */ //' + line.lstrip())
                continue
        out.append(line)
    with open(path, 'w') as f:
        f.write('\n'.join(out))
    print(f"[OK] Commented out secondary qcom,dsi-display-active (fallback)")
PYEOF
            else
                log_warn "Only one active display found in $dtsi_file — nothing to disable"
            fi
        fi
    done

    # ── Strategy 2: in the board-level DTS, add /delete-property/ or status = "disabled"
    # for the secondary display node overlay
    for board_dts in \
        "$DTS_SEARCH_DIR/lahaina-star.dts" \
        "$DTS_SEARCH_DIR/lahaina-star-v2.dts" \
        "$DTS_SEARCH_DIR/lahaina-star-v2-overlay.dts"; do
        if [ -f "$board_dts" ]; then
            log_info "Patching board DTS: $board_dts"
            # Inject override at end of file before closing brace
            # to disable the secondary/rear SDE display node
            cat >> "$board_dts" << 'DTSEOF'

/* ── Rear display disabled by build script ── */
&sde_dsi1 {
	status = "disabled";
};
&dsi_display1 {
	/delete-property/ qcom,dsi-display-active;
};
DTSEOF
            log_ok "Rear display disabled in $board_dts"
        fi
    done

    # ── Strategy 3: defconfig — remove secondary display framebuffer support
    # (belt-and-suspenders: even if DTS still references it, driver won't init it)
    echo "# CONFIG_DRM_MSM_DSI_PLL is not set" >> \
        "$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG" 2>/dev/null || true

    log_ok "Rear display DTS patching complete."
else
    log_info "Rear display: keeping enabled (DISABLE_REAR_DISPLAY=false)"
fi


# ── 7. Build ─────────────────────────────────────────────────
log_info "Starting kernel build ($(nproc) threads)..."

export CC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# Step 1: generate base .config from defconfig
make O="$OUT_DIR" ARCH=$ARCH CC=$CC CLANG_TRIPLE=$CLANG_TRIPLE \
     CROSS_COMPILE=$CROSS_COMPILE $DEFCONFIG

# Step 2: resolve any new/unset symbols non-interactively
# Prevents LTO_CLANG "NEW symbol" interactive prompt
yes "" | make O="$OUT_DIR" ARCH=$ARCH CC=$CC CLANG_TRIPLE=$CLANG_TRIPLE \
     CROSS_COMPILE=$CROSS_COMPILE olddefconfig

# Step 3: build kernel image
# Note: dtbo.img is NOT a valid standalone target in MiCode star-r-oss (5.4)
make -j"$(nproc --all)" \
     O="$OUT_DIR" ARCH=$ARCH CC=$CC LD=$LD AR=$AR NM=$NM \
     OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP STRIP=$STRIP \
     CLANG_TRIPLE=$CLANG_TRIPLE \
     CROSS_COMPILE=$CROSS_COMPILE \
     CROSS_COMPILE_ARM32=$CROSS_COMPILE_ARM32 \
     Image 2>&1 | tee "$LOG_DIR/build.log"

log_ok "Build complete."
ls -lh "$OUT_DIR/arch/arm64/boot/"

# ── 8. Package AnyKernel3 zip ────────────────────────────────
log_info "Packaging AnyKernel3 zip..."

if [ ! -d "$ANYKERNEL_DIR/.git" ]; then
    git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "$ANYKERNEL_DIR"
fi

# Copy kernel image (try multiple variants)
cp "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" "$ANYKERNEL_DIR/Image" 2>/dev/null || \
cp "$OUT_DIR/arch/arm64/boot/Image.gz"     "$ANYKERNEL_DIR/Image" 2>/dev/null || \
cp "$OUT_DIR/arch/arm64/boot/Image"        "$ANYKERNEL_DIR/Image"

# dtbo: copy if present (not a guaranteed output in this kernel tree)
cp "$OUT_DIR/arch/arm64/boot/dtbo.img" "$ANYKERNEL_DIR/" 2>/dev/null || true
cp "$OUT_DIR/arch/arm64/boot/dtbo"     "$ANYKERNEL_DIR/dtbo.img" 2>/dev/null || true

# Write anykernel.sh
cat > "$ANYKERNEL_DIR/anykernel.sh" << 'AKEOF'
# AnyKernel3 — Mi 11 Ultra (star)
properties() { '
kernel.string=SukiSU-Ultra + SuSFS | star (Mi 11 Ultra)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=star
device.name2=mars
device.name3=M2102K1G
device.name4=M2102K1AC
device.name5=M2102K1C
supported.versions=11-14
supported.patchlevels=
'; }

block=/dev/block/bootdevice/by-name/boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto

. tools/ak3-core.sh

dump_boot;
write_boot;
AKEOF

BUILD_DATE=$(date +%Y%m%d-%H%M)
ZIP_NAME="AnyKernel3_SukiSU-Ultra_SuSFS_star_${BUILD_DATE}.zip"
cd "$ANYKERNEL_DIR"
zip -r9 "$ROOT_DIR/$ZIP_NAME" . -x "*.git*" "*.github*"

log_ok "Done! Flashable zip: $ROOT_DIR/$ZIP_NAME"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Device      : Xiaomi Mi 11 Ultra (star)"
echo " Kernel      : $KVER"
echo " Root        : SukiSU Ultra"
echo " SuSFS       : susfs4ksu @ $SUSFS_BRANCH"
echo " SELinux     : Enforcing (non-permissive)"
echo " Rear screen : $($DISABLE_REAR_DISPLAY && echo 'DISABLED (DTS patched)' || echo 'Enabled')"
echo " Hook        : $($USE_KPROBES && echo 'KProbes' || echo 'Manual (non-kprobes)')"
echo " Output      : $ROOT_DIR/$ZIP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
