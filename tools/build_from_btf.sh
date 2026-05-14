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

# 2. 定义核心构建函数
run_build_for_device() {
    local device_name=$1
    local device_btf_dir="$ROOT/btf/$device_name"
    local btf_path="$device_btf_dir/vmlinux.btf"

    echo "========================================"
    echo "正在为设备 [$device_name] 开始构建..."
    echo "========================================"

    if [[ ! -f "$btf_path" ]]; then
        echo "跳过: 在 $btf_path 未找到 BTF 文件。"
        return 1
    fi

    # 验证 BTF Magic Number
    local btf_magic
    btf_magic="$(xxd -p -l 4 "$btf_path")"
    if [[ "$btf_magic" != "9feb0100" ]]; then
        echo "错误: $btf_path 的 BTF magic 不匹配 ($btf_magic)" >&2
        return 1
    fi

    # 生成头文件
    echo "==> 生成 src/vmlinux.h"
    "$BPFTOOL" btf dump file "$btf_path" format c > "$ROOT/src/vmlinux.h"

    # 执行构建流程
    echo "==> 编译 Android arm64 依赖"
    export ANDROID_NDK ANDROID_API DEPS_DIR PREFIX
    bash "$ROOT/build_deps_android.sh"

    echo "==> 编译 hideport 模块二进制"
    export LIBBPF_SRC="$PREFIX" LIBBPF_HEADERS="$PREFIX/include" LIBBPF_LIBDIR="$PREFIX/lib" BPFTOOL
    bash "$ROOT/build.sh"

    echo "==> 打包 KernelSU 模块"
    # 注意：如果 package.sh 生成的文件名是固定的，建议在该脚本里根据设备名重命名输出包
    bash "$ROOT/package.sh"

    # 建议的操作：重命名输出包以免被下一个设备覆盖
    if [[ -f "$ROOT/../hideSceneport_module.zip" ]]; then
        mv "$ROOT/../hideSceneport_module.zip" "$ROOT/../hideSceneport_module_${device_name}.zip"
        echo "完成！输出文件: $ROOT/../hideSceneport_module_${device_name}.zip"
    fi
}

# 3. 执行逻辑
if [[ "$TARGET_DEVICE" == "all" ]]; then
    # 遍历 btf 目录下的所有子目录
    for d in "$ROOT/btf"/*/; do
        if [[ -d "$d" ]]; then
            device=$(basename "$d")
            run_build_for_device "$device"
        fi
    done
else
    # 跑单个指定设备
    if [[ -d "$ROOT/btf/$TARGET_DEVICE" ]]; then
        run_build_for_device "$TARGET_DEVICE"
    else
        echo "错误: 目录 $ROOT/btf/$TARGET_DEVICE 不存在。" >&2
        exit 1
    fi
fi