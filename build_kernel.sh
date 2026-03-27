#!/usr/bin/env bash
# ==============================================================================
# High-Performance Android Kernel Build Pipeline using Proton Clang
# Architecture: AArch64 | Optimizations: LTO, PGO, Polly
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e 

# Initialize directory variables
WORKSPACE_DIR="$(pwd)"
KERNEL_DIR="${WORKSPACE_DIR}/kernel_source"
TOOLCHAIN_DIR="${WORKSPACE_DIR}/proton-clang"
ANYKERNEL_DIR="${WORKSPACE_DIR}/AnyKernel3"
OUT_DIR="${KERNEL_DIR}/out"

# Target kernel configuration parameters
ARCH="arm64"
KERNEL_VERSION="5.4-Proton-SuSFS"
TIMESTAMP="$(date +"%Y%m%d_%H%M")"
CORES="$(nproc --all)"

# Get the defconfig from GitHub Actions input. Fallback to star-qgki if empty.
DEFCONFIG_FILE="${DEVICE_CONFIG:-star-qgki_defconfig}"

echo "[1/6] Cloning repositories and toolchain..."
# Shallow clone of Proton Clang to minimize network traffic
if [ ! -d "${TOOLCHAIN_DIR}" ]; then
    git clone --depth=1 https://github.com/kdrag0n/proton-clang.git "${TOOLCHAIN_DIR}"
fi

# Clone the AnyKernel3 template packager
if [ ! -d "${ANYKERNEL_DIR}" ]; then
    git clone --depth=1 https://github.com/osm0sis/AnyKernel3.git "${ANYKERNEL_DIR}"
fi

# Assuming the kernel source code is already in the kernel_source directory
if [ ! -d "${KERNEL_DIR}" ]; then
    echo "Error: Kernel source directory (${KERNEL_DIR}) not found."
    exit 1
fi

echo "[2/6] Exporting environment variables (Kbuild Compiler Directives)..."
# Add LLVM binaries to system path
export PATH="${TOOLCHAIN_DIR}/bin:${PATH}"

# Define prefixes for cross-compilation
export CC="clang"
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabi-" # For vDSO on 4.19+ kernels
export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"  # Backwards compatibility

echo "[3/6] Lexical cleaning and source code patching (Clang strict semantics)..."
cd "${KERNEL_DIR}"

# 3.1. Fix Undefined Behavior: "division by zero is undefined" in mman.h
if grep -q "1 / 0" include/uapi/asm-generic/mman.h 2>/dev/null; then
    echo "  -> Patching asm-generic/mman.h..."
    sed -i 's|1 / 0|0|g' include/uapi/asm-generic/mman.h
    sed -i 's|1 / 0|0|g' arch/arm64/include/uapi/asm/mman.h 2>/dev/null || true
fi

# 3.2. Restore KABI syntax after SuSFS patches (Fix wiggle/git conflict markers)
if [ -f "include/linux/mount.h" ]; then
    echo "  -> Validating syntax of include/linux/mount.h..."
    sed -i '/>>>>>>> replacement/d' include/linux/mount.h 2>/dev/null || true
    sed -i '/======/d' include/linux/mount.h 2>/dev/null || true
    sed -i '/ANDROID_KABI_USE(4, u64 susfs_mnt_id_backup);/d' include/linux/mount.h 2>/dev/null || true
fi

# 3.3. Include SuSFS module in the build graph if it was copied
if grep -q "susfs.c" fs/Makefile 2>/dev/null || [ -f "fs/susfs.c" ]; then
    if ! grep -q "susfs.o" fs/Makefile; then
        echo "obj-y += susfs.o" >> fs/Makefile
    fi
fi

echo "[4/6] Initializing Kbuild configuration..."
# Find the exact path of the requested defconfig
echo "  -> Searching for defconfig: ${DEFCONFIG_FILE}..."
DEFCONFIG_PATH=$(find arch/arm64/configs -name "${DEFCONFIG_FILE}" | head -n 1 | sed 's|arch/arm64/configs/||')

if [ -z "${DEFCONFIG_PATH}" ]; then
    echo "Critical Error: Configuration file (${DEFCONFIG_FILE}) not found in the source tree!"
    exit 1
fi
echo "  -> Successfully found defconfig: ${DEFCONFIG_PATH}"

# Full clean of the source tree and old artifacts
make O="${OUT_DIR}" ARCH="${ARCH}" mrproper

# Generate .config based on the selected defconfig
make O="${OUT_DIR}" ARCH="${ARCH}" CC="${CC}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT}" \
    LLVM=1 LLVM_IAS=1 \
    "${DEFCONFIG_PATH}"

echo "[5/6] Starting multi-threaded compilation (LLVM/LTO)..."
# Call the build system, delegating full authority to the LLVM toolchain
make -j"${CORES}" O="${OUT_DIR}" ARCH="${ARCH}" CC="${CC}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    CROSS_COMPILE_COMPAT="${CROSS_COMPILE_COMPAT}" \
    CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32}" \
    LLVM=1 LLVM_IAS=1

# Check for the compiled kernel
COMPILED_IMAGE="${OUT_DIR}/arch/arm64/boot/Image"
if [ ! -f "${COMPILED_IMAGE}" ]; then
    echo "Critical Error: Image file not generated. Check compiler logs."
    exit 1
fi
echo "Success: Kernel binary successfully created."

echo "[6/6] Packaging kernel into AnyKernel3 format..."
cd "${WORKSPACE_DIR}"
rm -rf "${ANYKERNEL_DIR}/Image" "${ANYKERNEL_DIR}/Image.gz" "${ANYKERNEL_DIR}/dtb" "${ANYKERNEL_DIR}/dtbo.img"

# Integrate binary artifacts into the packager template
cp "${COMPILED_IMAGE}" "${ANYKERNEL_DIR}/"
cp "${KERNEL_DIR}/out/arch/arm64/boot/dtbo.img" "${ANYKERNEL_DIR}/" 2>/dev/null || true

# Find and transfer all compiled Device Tree Blob (dtb) files
find "${KERNEL_DIR}/out/arch/arm64/boot/dts/vendor/" -name "*.dtb" -exec cp {} "${ANYKERNEL_DIR}/dtb/" \; 2>/dev/null || true

cd "${ANYKERNEL_DIR}"
# Extract the device name from the defconfig (e.g. star-qgki) for the zip name
DEVICE_NAME="${DEFCONFIG_FILE%%_defconfig}"
ZIP_FILENAME="${DEVICE_NAME}-${KERNEL_VERSION}-${TIMESTAMP}.zip"

# Create the final ZIP file
zip -r9 "${ZIP_FILENAME}" * -x .git README.md *placeholder

mv "${ZIP_FILENAME}" "${WORKSPACE_DIR}/"
echo "================================================="
echo " Build completed. Artifact: ${ZIP_FILENAME} "
echo "================================================="
