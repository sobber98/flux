#!/bin/bash
# sing-box iOS 库编译脚本
# 产物: Libbox.xcframework (支持 iOS 设备和模拟器)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/singbox"
SINGBOX_VERSION="v1.13.7"

echo "=========================================="
echo "编译 sing-box iOS 库"
echo "=========================================="
echo "版本: $SINGBOX_VERSION"
echo "构建目录: $BUILD_DIR"
echo ""

# 检查是否在 macOS 上运行
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "✗ 错误: iOS 编译只能在 macOS 上进行"
    exit 1
fi

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

# 3. 编译 iOS XCFramework
echo ""
echo "→ 开始编译 iOS XCFramework..."
echo "  目标架构: arm64 (设备), arm64+x86_64 (模拟器)"
echo "  最低版本: iOS 12.0"
echo ""

gomobile bind -v \
  -target=ios \
  -iosversion=12.0 \
  -ldflags="-s -w -buildid=" \
  -tags="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_reality_server,with_ech" \
  -o "$BUILD_DIR/Libbox.xcframework" \
  github.com/sagernet/sing-box/experimental/libbox

# 4. 验证产物
echo ""
echo "→ 验证编译产物..."
if [ -d "$BUILD_DIR/Libbox.xcframework" ]; then
    echo "✓ Libbox.xcframework 生成成功"
    echo ""
    echo "Framework 结构:"
    ls -lh "$BUILD_DIR/Libbox.xcframework/"
    echo ""

    # 5. 复制到项目目录
    TARGET_DIR="$PROJECT_ROOT/ios/Frameworks"
    mkdir -p "$TARGET_DIR"
    rm -rf "$TARGET_DIR/Libbox.xcframework"
    cp -R "$BUILD_DIR/Libbox.xcframework" "$TARGET_DIR/"
    echo "✓ 已复制到: $TARGET_DIR/Libbox.xcframework"
    echo ""
    echo "=========================================="
    echo "✓ iOS 库编译完成！"
    echo "=========================================="
    echo ""
    echo "下一步:"
    echo "1. 在 Xcode 中打开项目"
    echo "2. 将 Libbox.xcframework 拖入 Runner target"
    echo "3. 在 'Frameworks, Libraries, and Embedded Content' 中设置为 'Embed & Sign'"
    echo ""
else
    echo "✗ 编译失败：Libbox.xcframework 未生成"
    exit 1
fi
