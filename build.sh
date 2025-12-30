#!/bin/bash

# 1. 严格错误控制
set -euo pipefail

# --- 1. 基础环境配置 ---
TOOLCHAIN_PATH="$HOME/proton-clang/proton-clang-20210522/bin"
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD || echo "unknown")
TARGET_DEVICE="pipa" 
DEFCONFIG="pipa_stock-defconfig"

echo "==== 正在初始化编译环境 ===="
if [ ! -d "$TOOLCHAIN_PATH" ]; then
    echo "错误：未找到工具链目录: $TOOLCHAIN_PATH"
    exit 1
fi

# 设置环境变量
export PATH="$TOOLCHAIN_PATH:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="Gemini"
export KBUILD_BUILD_HOST="Android-Build"

# ccache 配置
export CCACHE_DIR="$HOME/.cache/ccache_pipa"
export PATH="/usr/lib/ccache:$PATH"

# 定义交叉编译参数 (针对 Proton Clang 优化)
MAKE_ARGS="O=out \
    ARCH=arm64 \
    CC=clang \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    STRIP=llvm-strip \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    CLANG_TRIPLE=aarch64-linux-gnu-"

# --- 2. 处理 KernelSU (SukiSU) ---
KSU_ZIP_STR="NoKernelSU"
if [ "${1:-}" == "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR="SukiSU-SUSFS"
    echo ">>>> 正在集成 KernelSU (SukiSU) 与 SUSFS <<<<"
    # 使用 -s 确保 setup.sh 能够正确运行
    curl -LSs "https://raw.githubusercontent.com/ApartTUSITU/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-1.5.7
else
    KSU_ENABLE=0
fi

# --- 3. 准备打包环境 ---
echo ">>>> 清理旧文件并下载 AnyKernel3 <<<<"
rm -rf out anykernel
# 使用针对 kona 平台适配的 AnyKernel3 分支
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

# --- 4. 配置内核与 MIUI 特性 ---
echo ">>>> 正在配置 $DEFCONFIG <<<<"
make $MAKE_ARGS "$DEFCONFIG"

echo ">>>> 正在注入 MIUI 优化参数与必要修正 <<<<"
# 修正：必须禁用 LTO_CLANG 以防止初次编译内存溢出错误
# 修正：注入 MIUI 核心进程路径及必要特性
./scripts/config --file out/.config \
    --set-str STATIC_USERMODEHELPER_PATH "/system/bin/micd" \
    -e PERF_CRITICAL_RT_TASK \
    -e OVERLAY_FS \
    -e XIAOMI_MIUI \
    -e MI_THERMAL_INTERFACE \
    -d DEBUG_FS \
    -d LTO_CLANG \
    -d LOCALVERSION_AUTO

# 针对 KSU 的配置项
if [ $KSU_ENABLE -eq 1 ]; then
    ./scripts/config --file out/.config \
        -e KSU \
        -e KSU_TRACEPOINT_HOOK \
        -e KSU_SUSFS_HAS_MAGIC_MOUNT
else
    ./scripts/config --file out/.config -d KSU
fi

# 关键：应用上述配置并自动补全依赖
make $MAKE_ARGS olddefconfig

# --- 5. 执行正式编译 ---
echo ">>>> 开始编译 (使用 $(nproc) 核心) <<<<"
make $MAKE_ARGS -j$(nproc)

# --- 6. 产物校验与打包 ---
if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "!! 编译失败：未检测到 Image 产物 !!"
    exit 1
fi

echo ">>>> 正在合并 DTB (针对 kona 平台) <<<<"
# pipa 的 dtb 位于 vendor/qcom 目录下
find out/arch/arm64/boot/dts/vendor/qcom -name "*.dtb" -exec cat {} + > out/arch/arm64/boot/dtb

# 如果是 KSU 版本，执行 KPM 补丁
if [ $KSU_ENABLE -eq 1 ]; then
    echo ">>>> 应用 SukiSU KPM 补丁 <<<<"
    (
        cd out/arch/arm64/boot/
        wget -q https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
        chmod +x patch_linux
        ./patch_linux || echo "补丁脚本执行异常"
        [ -f oImage ] && mv oImage Image
    )
fi

echo ">>>> 准备 AnyKernel3 打包目录 <<<<"
# 移动产物到打包根目录
cp out/arch/arm64/boot/Image anykernel/
cp out/arch/arm64/boot/dtb anykernel/

# 创建 flashable zip
echo ">>>> 正在生成最终 Zip 包 <<<<"
cd anykernel
ZIP_NAME="Kernel_MIUI_pipa_${KSU_ZIP_STR}_$(date +%Y%m%d_%H%M).zip"
zip -r9 "$ZIP_NAME" ./* -x ".git/*" ".gitignore" "*.zip"
mv "$ZIP_NAME" ../
cd ..

echo "======================================="
echo "编译成功！"
echo "产物名称: $ZIP_NAME"
echo "======================================="
