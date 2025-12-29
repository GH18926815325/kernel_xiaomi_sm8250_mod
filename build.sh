#!/bin/bash

# 确保脚本遇到错误立即退出
set -e

# --- 1. 基础环境配置 ---
# 注意：请确保工具链路径正确
TOOLCHAIN_PATH=$HOME/proton-clang/proton-clang-20210522/bin
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE="pipa" # 直接固定为 pipa

# 检查工具链
if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "错误：未找到工具链 $TOOLCHAIN_PATH"
    exit 1
fi

export PATH="$TOOLCHAIN_PATH:$PATH"
export ARCH=arm64
export SUBARCH=arm64

# 使用 ccache 加速编译
export CCACHE_DIR="$HOME/.cache/ccache_pipa"
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:$PATH"

# 定义交叉编译参数
MAKE_ARGS="O=out CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"

# --- 2. 处理 KernelSU (根据输入参数) ---
KSU_ZIP_STR=NoKernelSU
if [ "$1" == "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR=SukiSU-SUSFS
    echo "正在集成 KernelSU/SUSFS..."
    curl -LSs "https://raw.githubusercontent.com/ApartTUSITU/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-1.5.7
else
    KSU_ENABLE=0
fi

# --- 3. 准备打包环境 ---
rm -rf out/ anykernel/
echo "克隆 AnyKernel3 模板..."
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

# --- 4. 配置与 MIUI 特性启用 ---
echo "正在载入 ${TARGET_DEVICE}_defconfig..."
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

# 启用 MIUI 专用内核功能和优化
echo "正在注入 MIUI 特性开关..."
scripts/config --file out/.config \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
    -e PERF_CRITICAL_RT_TASK \
    -e OVERLAY_FS \
    -e MIGT \
    -e MIGT_ENERGY_MODEL \
    -e MIHW \
    -e PACKAGE_RUNTIME_INFO \
    -e MILLET \
    -e XIAOMI_MIUI \
    -e RTMM \
    -d DEBUG_FS \
    -d LTO_CLANG \
    -d LOCALVERSION_AUTO

# 处理 KSU 开关
if [ $KSU_ENABLE -eq 1 ]; then
    scripts/config --file out/.config -e KSU -e KSU_TRACEPOINT_HOOK -e KSU_SUSFS_HAS_MAGIC_MOUNT
else
    scripts/config --file out/.config -d KSU
fi

# --- 5. 执行正式编译 ---
echo "开始编译 MIUI 版内核..."
make $MAKE_ARGS -j$(nproc)

# --- 6. 打包产物 ---
if [ ! -f "out/arch/arm64/boot/Image" ]; then
    echo "编译失败：未找到 Image 文件"
    exit 1
fi

echo "生成 DTB 设备树..."
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

# 如果是 KSU，运行特殊的补丁程序处理 Image
if [ $KSU_ENABLE -eq 1 ]; then
    cd out/arch/arm64/boot/
    wget -q https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
    chmod +x patch_linux
    ./patch_linux
    mv oImage Image
    cd -
fi

# 移动到打包目录
cp out/arch/arm64/boot/Image anykernel/kernels/
cp out/arch/arm64/boot/dtb anykernel/kernels/

# 创建 flashable zip
cd anykernel
ZIP_NAME="Kernel_MIUI_pipa_${KSU_ZIP_STR}_$(date +%Y%m%d_%H%M).zip"
zip -r9 ../$ZIP_NAME ./* -x .git .gitignore out/ ./*.zip
cd ..

echo "---------------------------------------"
echo "编译完成！刷机包已生成：$ZIP_NAME"
