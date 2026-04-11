#!/bin/bash
# sing-box 移动端库一键编译脚本
# 自动检测平台并编译对应的库

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "sing-box 移动端库一键编译"
echo "=========================================="
echo ""

# 1. 环境检查
echo "→ 步骤 1: 环境检查"
echo "----------------------------------------"
if ! bash "$SCRIPT_DIR/check-env.sh"; then
    echo ""
    echo "✗ 环境检查失败，请先安装缺失的工具"
    exit 1
fi

echo ""
echo "→ 步骤 2: 选择编译目标"
echo "----------------------------------------"
echo "1) Android (libbox.aar)"
echo "2) iOS (Libbox.xcframework) - 仅 macOS"
echo "3) 全部 (Android + iOS) - 仅 macOS"
echo ""
read -p "请选择 [1-3]: " choice

case $choice in
    1)
        echo ""
        echo "→ 编译 Android 库..."
        bash "$SCRIPT_DIR/build-android.sh"
        ;;
    2)
        if [[ "$OSTYPE" != "darwin"* ]]; then
            echo "✗ 错误: iOS 编译只能在 macOS 上进行"
            exit 1
        fi
        echo ""
        echo "→ 编译 iOS 库..."
        bash "$SCRIPT_DIR/build-ios.sh"
        ;;
    3)
        if [[ "$OSTYPE" != "darwin"* ]]; then
            echo "✗ 错误: iOS 编译只能在 macOS 上进行"
            exit 1
        fi
        echo ""
        echo "→ 编译 Android 库..."
        bash "$SCRIPT_DIR/build-android.sh"
        echo ""
        echo "→ 编译 iOS 库..."
        bash "$SCRIPT_DIR/build-ios.sh"
        ;;
    *)
        echo "✗ 无效选择"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "✓ 编译完成！"
echo "=========================================="
echo ""
echo "编译产物位置:"
echo "  Android: android/app/libs/libbox.aar"
if [[ "$OSTYPE" == "darwin"* ]] && [[ $choice == "2" || $choice == "3" ]]; then
    echo "  iOS: ios/Frameworks/Libbox.xcframework"
fi
echo ""
echo "下一步: 运行集成脚本"
echo "  (待实现: 自动修改 Gradle/Xcode 配置)"
