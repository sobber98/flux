#!/bin/bash
# sing-box Android 库编译脚本
# 产物: libbox.aar (包含所有架构的 .so 文件)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/singbox"
SINGBOX_VERSION="v1.13.7"

echo "=========================================="
echo "编译 sing-box Android 库"
echo "=========================================="
echo "版本: $SINGBOX_VERSION"
echo "构建目录: $BUILD_DIR"
echo ""

# 创建构建目录
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# 1. 克隆 sing-box 源码
if [ ! -d "sing-box" ]; then
    echo "→ 克隆 sing-box 源码..."
    git clone --depth 1 --branch "$SINGBOX_VERSION" https://github.com/SagerNet/sing-box.git
else
    echo "→ sing-box 源码已存在，跳过克隆"
fi

cd sing-box

# 2. 安装 Go 依赖
echo ""
echo "→ 安装 Go 依赖..."
go get -d ./...

# 3. 编译 Android AAR
echo ""
echo "→ 开始编译 Android AAR..."
echo "  目标架构: arm64-v8a, armeabi-v7a, x86, x86_64"
echo "  最低 API: 21 (Android 5.0)"
echo ""

gomobile bind -v \
  -target=android \
  -androidapi=21 \
  -ldflags="-s -w -buildid=" \
  -tags="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api" \
  -o "$BUILD_DIR/libbox.aar" \
  github.com/sagernet/sing-box/experimental/libbox

# 4. 验证产物
echo ""
echo "→ 验证编译产物..."
if [ -f "$BUILD_DIR/libbox.aar" ]; then
    echo "✓ libbox.aar 生成成功"
    echo ""
    echo "文件信息:"
    ls -lh "$BUILD_DIR/libbox.aar"
    echo ""
    echo "AAR 内容:"
    unzip -l "$BUILD_DIR/libbox.aar" | grep -E "(\.so|classes\.jar)"
    echo ""

    # 5. 复制到项目目录
    TARGET_DIR="$PROJECT_ROOT/android/app/libs"
    mkdir -p "$TARGET_DIR"
    cp "$BUILD_DIR/libbox.aar" "$TARGET_DIR/"
    echo "✓ 已复制到: $TARGET_DIR/libbox.aar"
    echo ""
    echo "=========================================="
    echo "✓ Android 库编译完成！"
    echo "=========================================="
    echo ""
    echo "下一步:"
    echo "1. 在 android/app/build.gradle.kts 中添加依赖:"
    echo "   implementation(files(\"libs/libbox.aar\"))"
    echo ""
    echo "2. 同步 Gradle 依赖"
    echo ""
else
    echo "✗ 编译失败：libbox.aar 未生成"
    exit 1
fi
