#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_API="${ANDROID_API:-26}"
ANDROID_NDK="${ANDROID_NDK:-$HOME/android-ndk-r25c}"
NDK_ZIP="${NDK_ZIP:-$HOME/android-ndk-r25c-linux.zip}"
NDK_URL="${NDK_URL:-https://dl.google.com/android/repository/android-ndk-r25c-linux.zip}"
DEPS_DIR="${DEPS_DIR:-$HOME/hideport-deps}"
PREFIX="${PREFIX:-$DEPS_DIR/android-arm64}"
BPFTOOL="${BPFTOOL:-}"

# 获取传入的设备名参数
TARGET_DEVICE="${1:-}"

if [[ -z "$TARGET_DEVICE" ]]; then
    echo "错误: 请提供设备名称 (例如: device1, device2) 或输入 'all' 跑全部设备。" >&2
    exit 1
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || return 1
}

if [[ -z "$BPFTOOL" ]]; then
    if [[ -x /usr/local/sbin/bpftool ]]; then
        BPFTOOL=/usr/local/sbin/bpftool
    elif need_cmd bpftool; then
        BPFTOOL=bpftool
    else
        echo "Missing bpftool. Install it or set BPFTOOL=/path/to/bpftool." >&2
        exit 1
    fi
fi

if [[ ! -x "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${ANDROID_API}-clang" ]]; then
    echo "Android NDK not found at $ANDROID_NDK"
    echo "Downloading $NDK_URL"
    curl -fL --retry 3 "$NDK_URL" -o "$NDK_ZIP"
    unzip -q "$NDK_ZIP" -d "$HOME"
fi

run_build_for_device() {
    local device_name=$1
    echo "========================================"
    echo "Building for device: $device_name"
    echo "========================================"

    # 1. 使用 make clean 进行清理（最推荐）
    # 假设你的根目录或 src 目录下有 Makefile
    echo "==> Cleaning previous build artifacts..."
    make clean || true

    # 如果没有 Makefile，则手动清理关键产物
     rm -f "$ROOT/system/bin/hideport_loader" "$ROOT/system/bin/hideport.bpf.o"
     rm -f "$ROOT/src/vmlinux.h" "$ROOT/vmlinux.btf" "$ROOT/kernel_btf.sha256"

    # 2. BTF 定位逻辑 (恢复并增强 candidate 判断)
    local btf_file=""
    # 优先级：设备专用文件夹 -> 根目录 btf 文件夹 -> 根目录
    for candidate in \
        "$ROOT/btf/$device_name/vmlinux.btf" \
        "$ROOT/btf/vmlinux.btf" ; do
        if [[ -f "$candidate" ]]; then
            btf_file="$candidate"
            break
        fi
    done

    if [[ -z "$btf_file" ]]; then
        echo "Error: No BTF file found for $device_name" >&2
        return 1
    fi

    # 把设备 BTF 拷贝到 package.sh 认得的路径
    cp "$btf_file" "$ROOT/vmlinux.btf"

    # 3. BTF 校验
    local btf_magic
    btf_magic="$(xxd -p -l 4 "$btf_file")"
    if [[ "$btf_magic" != "9feb0100" ]]; then
        echo "Error: Invalid BTF magic in $btf_file" >&2
        return 1
    fi

    # 4. 生成 & 编译
    echo "==> Using BTF: $btf_file"
    "$BPFTOOL" btf dump file "$btf_file" format c > "$ROOT/src/vmlinux.h"

    # 执行编译逻辑 (保持导出变量)
    export ANDROID_NDK ANDROID_API DEPS_DIR PREFIX
    bash "$ROOT/build_deps_android.sh"

    export LIBBPF_SRC="$PREFIX" LIBBPF_HEADERS="$PREFIX/include" LIBBPF_LIBDIR="$PREFIX/lib" BPFTOOL
    bash "$ROOT/build.sh"

    # 5. 打包并重命名输出
    bash "$ROOT/package.sh"

    local output_zip="$ROOT/../hideSceneport_module.zip"
    if [[ -f "$output_zip" ]]; then
        mv "$output_zip" "$ROOT/../hideSceneport_module_${device_name}.zip"
        echo "Success: Created hideSceneport_module_${device_name}.zip"
    else
        echo "Error: Build failed, zip not found." >&2
        return 1
    fi

     rm -f "$ROOT/src/vmlinux.h"
     rm -f "$ROOT/kernel_btf.sha256"
}

# 执行逻辑
if [[ "$TARGET_DEVICE" == "all" ]]; then
    # 确保 btf 目录存在
    if [[ ! -d "$ROOT/btf" ]]; then
        echo "Error: btf/ directory not found." >&2
        exit 1
    fi

    # 遍历子目录进行构建
    for d in "$ROOT/btf"/*/; do
        if [[ -d "$d" ]]; then
            dev=$(basename "$d")
            run_build_for_device "$dev"
        fi
    done
else
    run_build_for_device "$TARGET_DEVICE"
fi