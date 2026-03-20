#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# build-rpm.sh
# Runs INSIDE the RPM Docker container.
# Compiles the Linux kernel and produces .rpm packages.
#
# Required env vars (set by GitHub Actions):
#   KERNEL_VERSION  — e.g. 6.6.30
#   ARCH            — kernel arch: x86 | arm64
#   CROSS_COMPILE   — cross prefix: '' | aarch64-linux-gnu-
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
KERNEL_VERSION="${KERNEL_VERSION:?KERNEL_VERSION is required}"
ARCH="${ARCH:?ARCH is required}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
WORKSPACE="/workspace"
KERNEL_SOURCE="/kernel-source/linux-${KERNEL_VERSION}.tar.xz"
BUILD_DIR="/tmp/kernel-build"
OUTPUT_DIR="${WORKSPACE}/output"
JOBS=$(nproc)

# ── Validate environment ──────────────────────────────────────
echo "════════════════════════════════════════════"
echo " Kernel RPM Build"
echo " Version:       ${KERNEL_VERSION}"
echo " Arch:          ${ARCH}"
echo " Cross-compile: ${CROSS_COMPILE:-'(native)'}"
echo " CPUs:          ${JOBS}"
echo "════════════════════════════════════════════"

if [[ ! -f "$KERNEL_SOURCE" ]]; then
    echo "ERROR: Kernel source not found at $KERNEL_SOURCE"
    exit 1
fi

# Validate cross compiler if set
if [[ -n "$CROSS_COMPILE" ]]; then
    if ! command -v "${CROSS_COMPILE}gcc" &>/dev/null; then
        echo "ERROR: Cross compiler '${CROSS_COMPILE}gcc' not found in PATH"
        exit 1
    fi
    echo "Cross compiler: $(${CROSS_COMPILE}gcc --version | head -1)"
fi

# ── Prepare build directory ───────────────────────────────────
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo ""
echo "==> [1/5] Extracting kernel source..."
tar -xf "$KERNEL_SOURCE" -C "$BUILD_DIR"
KERNEL_DIR="${BUILD_DIR}/linux-${KERNEL_VERSION}"

if [[ ! -d "$KERNEL_DIR" ]]; then
    echo "ERROR: Expected kernel dir not found: $KERNEL_DIR"
    exit 1
fi

# ── Apply kernel configuration ────────────────────────────────
echo ""
echo "==> [2/5] Applying kernel config..."

# Map kernel arch to config file name
case "$ARCH" in
    x86|x86_64) CONFIG_ARCH="x86_64" ;;
    arm64)      CONFIG_ARCH="arm64" ;;
    *)          CONFIG_ARCH="$ARCH" ;;
esac

CONFIG_FILE="${WORKSPACE}/kernel/configs/${CONFIG_ARCH}_defconfig"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Using custom config: $CONFIG_FILE"
    cp "$CONFIG_FILE" "${KERNEL_DIR}/.config"
    # Update config to fill in any new options with defaults
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        olddefconfig
else
    echo "WARNING: No custom config found at $CONFIG_FILE"
    echo "Falling back to distribution defconfig..."
    make -C "$KERNEL_DIR" \
        ARCH="$ARCH" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        defconfig
fi

# ── Apply any patches ─────────────────────────────────────────
PATCH_DIR="${WORKSPACE}/kernel/patches"
if [[ -d "$PATCH_DIR" ]] && compgen -G "${PATCH_DIR}/*.patch" > /dev/null 2>&1; then
    echo ""
    echo "==> [2b] Applying patches..."
    for patch in "${PATCH_DIR}"/*.patch; do
        echo "Applying: $(basename "$patch")"
        patch -p1 -d "$KERNEL_DIR" < "$patch"
    done
fi

# ── Build the kernel ──────────────────────────────────────────
echo ""
echo "==> [3/5] Building kernel with ${JOBS} jobs (this takes 30–120 min)..."

# Set RPM build dir
export RPM_BUILD_ROOT=/root/rpmbuild
rpmdev-setuptree

make -C "$KERNEL_DIR" \
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    -j"$JOBS" \
    binrpm-pkg \
    RPMBUILD_FLAGS="--define '_topdir /root/rpmbuild'"

# ── Collect output packages ───────────────────────────────────
echo ""
echo "==> [4/5] Collecting RPM packages..."

find /root/rpmbuild/RPMS -name "*.rpm" -exec cp -v {} "$OUTPUT_DIR/" \;
find /root/rpmbuild/SRPMS -name "*.src.rpm" -exec cp -v {} "$OUTPUT_DIR/" \;

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "==> [5/5] Build complete!"
echo ""
echo "Packages produced:"
ls -lh "$OUTPUT_DIR/"*.rpm 2>/dev/null || echo "(no .rpm files found)"

PACKAGE_COUNT=$(find "$OUTPUT_DIR" -name "*.rpm" | wc -l)
if [[ "$PACKAGE_COUNT" -eq 0 ]]; then
    echo "ERROR: Build completed but no RPMs found!"
    exit 1
fi

echo ""
echo "✅ Successfully built ${PACKAGE_COUNT} RPM package(s)"
