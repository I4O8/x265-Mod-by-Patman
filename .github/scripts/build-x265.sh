#!/usr/bin/env bash
#
# build-x265.sh — Build x265 (Patman Mod) multilib for Linux
#
# ================ Architecture ================
# x265 的多深度（multilib）构建采用 "8-bit 为主、10/12-bit 为辅" 的架构：
#
#   x265 CLI (单一二进制)
#     └── libx265 (8-bit 编码器 — 导出完整的公共 C API)
#           ├── libx265_main10.a (10-bit 编码内核 — EXPORT_C_API=OFF)
#           └── libx265_main12.a (12-bit 编码内核 — EXPORT_C_API=OFF)
#
# 构建流程（三段式）：
#   1. 先编 12-bit — 静态库，不导出符号，仅含 12-bit 编码逻辑
#   2. 再编 10-bit — 同上，仅含 10-bit 编码逻辑
#   3. 最后编 8-bit — 链接前两步的 .a，导出完整 C API，编译 CLI
#
# 运行时通过 --input-depth 10/12 自动选择对应内核，无需切换二进制。
# 文件夹名叫 8bit 但产物是 8+10+12 三合一。
# ==============================================
#
# Output artifacts (in <build-dir>/8bit/):
#   x265         — CLI 二进制 (multilib: 8+10+12-bit)
#   libx265.a    — 合并后的静态库
#   libx265.so   — 动态库 (仅 --enable-shared 时)
#
# Usage:
#   bash build-x265.sh [options]
#
# Options:
#   --source-dir DIR      x265 源码目录 (default: ./source)
#   --build-dir DIR       构建输出目录 (default: ./build)
#   --prefix DIR          安装目录 (default: ./install)
#   --jobs N              并行编译任务数 (default: nproc)
#   --enable-shared       额外编译动态库 .so (default: off)
#   --enable-numa         启用 NUMA 支持 (default: off, 为了可移植性)
#   --enable-asm          Assembly 优化 (default: on)
#   --extra-cmake-args    额外的 CMake 参数
#   --cross-prefix PREFIX 交叉编译工具链前缀
#   --arch ARCH           目标架构 (用于交叉编译)
#   --static-libstdcxx    静态链接 libstdc++/libgcc (default: on)
#   --help                显示本帮助
# ====================================================================

set -euo pipefail

# ---- defaults ----
SOURCE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${SOURCE_DIR}/build"
PREFIX_DIR="${SOURCE_DIR}/install"
JOBS="$(nproc)"
ENABLE_SHARED="OFF"
ENABLE_NUMA="OFF"
ENABLE_ASM="ON"
EXTRA_CMAKE_ARGS=""
CROSS_PREFIX=""
TARGET_ARCH=""
STATIC_LIBSTDCXX="ON"

# ---- parse args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir)    SOURCE_DIR="$2"; shift 2 ;;
        --build-dir)     BUILD_DIR="$2"; shift 2 ;;
        --prefix)        PREFIX_DIR="$2"; shift 2 ;;
        --jobs)          JOBS="$2"; shift 2 ;;
        --enable-shared) ENABLE_SHARED="$2"; shift 2 ;;
        --enable-numa)   ENABLE_NUMA="$2"; shift 2 ;;
        --enable-asm)    ENABLE_ASM="$2"; shift 2 ;;
        --extra-cmake-args) EXTRA_CMAKE_ARGS="$2"; shift 2 ;;
        --cross-prefix)   CROSS_PREFIX="$2"; shift 2 ;;
        --arch)          TARGET_ARCH="$2"; shift 2 ;;
        --static-libstdcxx) STATIC_LIBSTDCXX="$2"; shift 2 ;;
        --help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //; s/^#//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---- resolve paths ----
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
BUILD_DIR="$(mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR" && pwd)"
PREFIX_DIR="$(mkdir -p "$PREFIX_DIR" && cd "$PREFIX_DIR" && pwd)"

echo "=== x265 Build Configuration ==="
echo "Source:       $SOURCE_DIR"
echo "Build:        $BUILD_DIR"
echo "Prefix:       $PREFIX_DIR"
echo "Jobs:         $JOBS"
echo "Shared lib:   $ENABLE_SHARED"
echo "NUMA support: $ENABLE_NUMA"
echo "Assembly:     $ENABLE_ASM"
echo "Cross prefix: ${CROSS_PREFIX:-none}"
echo "Target arch:  ${TARGET_ARCH:-native}"
echo "================================"

# ---- cross-compilation toolchain ----
TOOLCHAIN_FILE=""
write_toolchain() {
    local arch="$1" file
    file="/tmp/x265-toolchain-${arch}.cmake"
    cat > "$file" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${arch})
set(CMAKE_C_COMPILER ${CROSS_PREFIX}gcc)
set(CMAKE_CXX_COMPILER ${CROSS_PREFIX}g++)
set(CMAKE_ASM_COMPILER ${CROSS_PREFIX}gcc)
set(CMAKE_AR ${CROSS_PREFIX}ar)
set(CMAKE_RANLIB ${CROSS_PREFIX}ranlib)
set(CMAKE_STRIP ${CROSS_PREFIX}strip)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_CROSSCOMPILING TRUE)
EOF
    echo "$file"
}

if [[ -n "$CROSS_PREFIX" ]]; then
    case "$TARGET_ARCH" in
        aarch64|arm64)   TOOLCHAIN_FILE=$(write_toolchain aarch64) ;;
        arm|armv7)       TOOLCHAIN_FILE=$(write_toolchain arm) ;;
        riscv64)         TOOLCHAIN_FILE=$(write_toolchain riscv64) ;;
        loongarch64)     TOOLCHAIN_FILE=$(write_toolchain loongarch64) ;;
    esac
fi

# ---- common cmake flags for all sub-builds ----
COMMON_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DENABLE_ASSEMBLY="$ENABLE_ASM"
)

# 静态链接 libstdc++/libgcc，减少对宿主系统 GCC 版本的依赖
if [[ "$STATIC_LIBSTDCXX" == "ON" ]]; then
    COMMON_FLAGS+=(
        -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++"
        -DCMAKE_SHARED_LINKER_FLAGS="-static-libgcc -static-libstdc++"
    )
fi

# NUMA 支持 (默认关 — 为了保证二进制能在无 libnuma 的系统上运行)
if [[ "$ENABLE_NUMA" == "ON" ]]; then
    COMMON_FLAGS+=(-DENABLE_LIBNUMA=ON)
else
    COMMON_FLAGS+=(-DENABLE_LIBNUMA=OFF)
fi

# 交叉编译工具链
if [[ -n "$TOOLCHAIN_FILE" && -f "$TOOLCHAIN_FILE" ]]; then
    COMMON_FLAGS+=(-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE")
fi

# 用户自定义 CMake 参数
if [[ -n "$EXTRA_CMAKE_ARGS" ]]; then
    # shellcheck disable=SC2206
    COMMON_FLAGS+=($EXTRA_CMAKE_ARGS)
fi

# ====================================================================
# Stage 1: Build 12-bit static library
# ====================================================================
# 编译 12-bit 编码内核。EXPORT_C_API=OFF 确保不导出符号，
# 避免和后续 8-bit 主库冲突。
echo ""
echo "=== Stage 1/3: Building 12-bit library ==="
mkdir -p "$BUILD_DIR/12bit"
cd "$BUILD_DIR/12bit"
cmake "${SOURCE_DIR}/source" \
    "${COMMON_FLAGS[@]}" \
    -DHIGH_BIT_DEPTH=ON \
    -DMAIN12=ON \
    -DENABLE_SHARED=OFF \
    -DENABLE_CLI=OFF \
    -DEXPORT_C_API=OFF
make -j"$JOBS"
echo "12-bit library built: $(ls -la libx265.a)"

# ====================================================================
# Stage 2: Build 10-bit static library
# ====================================================================
# 同上，仅编译 10-bit 编码内核，不导出符号。
echo ""
echo "=== Stage 2/3: Building 10-bit library ==="
mkdir -p "$BUILD_DIR/10bit"
cd "$BUILD_DIR/10bit"
cmake "${SOURCE_DIR}/source" \
    "${COMMON_FLAGS[@]}" \
    -DHIGH_BIT_DEPTH=ON \
    -DENABLE_SHARED=OFF \
    -DENABLE_CLI=OFF \
    -DEXPORT_C_API=OFF
make -j"$JOBS"
echo "10-bit library built: $(ls -la libx265.a)"

# ====================================================================
# Stage 3: Build 8-bit multilib (主库 + CLI)
# ====================================================================
# 8-bit 构建是"宿主"：链接 10/12-bit 的内核静态库，
# 导出完整的公共 C API，并编译 CLI 二进制。
# 最终 x265 二进制可以在运行时根据 --input-depth 自动切换深度。
echo ""
echo "=== Stage 3/3: Building 8-bit multilib (CLI) ==="
mkdir -p "$BUILD_DIR/8bit"
cd "$BUILD_DIR/8bit"

# 将 10-bit 和 12-bit 的静态库链接到 8-bit 构建目录
ln -sf ../10bit/libx265.a libx265_main10.a
ln -sf ../12bit/libx265.a libx265_main12.a

SHARED_FLAG="$ENABLE_SHARED"

cmake "${SOURCE_DIR}/source" \
    "${COMMON_FLAGS[@]}" \
    -DENABLE_SHARED="$SHARED_FLAG" \
    -DENABLE_CLI=ON \
    -DEXTRA_LIB="x265_main10.a;x265_main12.a" \
    -DEXTRA_LINK_FLAGS="-L." \
    -DLINKED_10BIT=ON \
    -DLINKED_12BIT=ON
make -j"$JOBS"

echo "x265 multilib built successfully"

# ====================================================================
# Combine static libraries into one unified libx265.a
# ====================================================================
# 将三个深度各自的静态库合并为一个 libx265.a，方便第三方链接。
echo ""
echo "=== Combining static libraries ==="
cd "$BUILD_DIR/8bit"
if [[ -f libx265.a ]]; then
    mv libx265.a libx265_main.a
    ar -M <<EOF
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB ../10bit/libx265.a
ADDLIB ../12bit/libx265.a
SAVE
END
EOF
    echo "Combined static library: libx265.a ($(du -h libx265.a | cut -f1))"
    rm -f libx265_main.a
fi

# ====================================================================
# Strip binaries
# ====================================================================
if [[ -f "$BUILD_DIR/8bit/x265" ]]; then
    echo ""
    echo "=== Stripping debug symbols ==="
    strip "$BUILD_DIR/8bit/x265" 2>/dev/null || true
    echo "Final binary: $(ls -la "$BUILD_DIR/8bit/x265")"

    echo ""
    echo "=== Dynamic library dependencies ==="
    if command -v ldd &>/dev/null; then
        ldd "$BUILD_DIR/8bit/x265" 2>&1 || true
    fi
fi

if [[ "$ENABLE_SHARED" == "ON" ]]; then
    find "$BUILD_DIR/8bit" -name 'libx265.so*' -exec strip {} \; 2>/dev/null || true
    ls -la "$BUILD_DIR/8bit"/libx265.so* 2>/dev/null || true
fi

# ====================================================================
# Summary
# ====================================================================
echo ""
echo "============================================"
echo "  x265 Build Complete"
echo "============================================"
echo "Binary:        $BUILD_DIR/8bit/x265"
echo "Static lib:    $BUILD_DIR/8bit/libx265.a"
if [[ "$ENABLE_SHARED" == "ON" ]]; then
    echo "Shared lib:    $BUILD_DIR/8bit/libx265.so"
fi
echo "Features:      Multilib (8-bit + 10-bit + 12-bit)"
echo "Assembly:      $ENABLE_ASM"
echo "Arch:          ${TARGET_ARCH:-native}"
echo "============================================"
echo ""
echo "验证多深度支持:"
echo "  $BUILD_DIR/8bit/x265 --help | grep -E 'input-depth|bit-depth'"
