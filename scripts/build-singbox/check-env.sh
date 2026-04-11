#!/bin/bash
# sing-box 移动端编译脚本 - 环境检查
# 用途：检查编译 sing-box 所需的环境是否就绪

set -e

echo "=========================================="
echo "sing-box 移动端编译环境检查"
echo "=========================================="
echo ""

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查结果统计
PASS=0
FAIL=0

check_command() {
    local cmd=$1
    local name=$2
    local install_hint=$3

    if command -v "$cmd" &> /dev/null; then
        echo -e "${GREEN}✓${NC} $name: $(command -v $cmd)"
        local version=$($cmd version 2>&1 | head -1 || echo "unknown")
        echo "  版本: $version"
        ((PASS++))
        return 0
    else
        echo -e "${RED}✗${NC} $name: 未安装"
        echo -e "  ${YELLOW}安装提示: $install_hint${NC}"
        ((FAIL++))
        return 1
    fi
}

echo "1. 检查 Go 环境"
echo "----------------------------------------"
check_command "go" "Go" "访问 https://go.dev/dl/ 下载安装"
echo ""

echo "2. 检查 gomobile"
echo "----------------------------------------"
if command -v gomobile &> /dev/null; then
    echo -e "${GREEN}✓${NC} gomobile: $(command -v gomobile)"
    ((PASS++))
else
    echo -e "${RED}✗${NC} gomobile: 未安装"
    echo -e "  ${YELLOW}安装命令:${NC}"
    echo "    go install golang.org/x/mobile/cmd/gomobile@latest"
    echo "    gomobile init"
    ((FAIL++))
fi
echo ""

echo "3. 检查 Android NDK"
echo "----------------------------------------"
if [ -n "$ANDROID_NDK_HOME" ] && [ -d "$ANDROID_NDK_HOME" ]; then
    echo -e "${GREEN}✓${NC} Android NDK: $ANDROID_NDK_HOME"
    if [ -f "$ANDROID_NDK_HOME/source.properties" ]; then
        echo "  版本: $(grep 'Pkg.Revision' $ANDROID_NDK_HOME/source.properties | cut -d'=' -f2)"
    fi
    ((PASS++))
else
    echo -e "${RED}✗${NC} Android NDK: 未配置"
    echo -e "  ${YELLOW}安装提示:${NC}"
    echo "    1. 通过 Android Studio SDK Manager 安装 NDK"
    echo "    2. 或访问 https://developer.android.com/ndk/downloads"
    echo "    3. 设置环境变量: export ANDROID_NDK_HOME=/path/to/ndk"
    ((FAIL++))
fi
echo ""

echo "4. 检查 Xcode (macOS only)"
echo "----------------------------------------"
if [[ "$OSTYPE" == "darwin"* ]]; then
    if command -v xcodebuild &> /dev/null; then
        echo -e "${GREEN}✓${NC} Xcode: $(xcodebuild -version | head -1)"
        ((PASS++))
    else
        echo -e "${RED}✗${NC} Xcode: 未安装"
        echo -e "  ${YELLOW}安装提示: 从 App Store 安装 Xcode${NC}"
        ((FAIL++))
    fi
else
    echo -e "${YELLOW}⊘${NC} Xcode: 非 macOS 系统，跳过检查"
fi
echo ""

echo "5. 检查 Git"
echo "----------------------------------------"
check_command "git" "Git" "访问 https://git-scm.com/downloads"
echo ""

echo "6. 检查磁盘空间"
echo "----------------------------------------"
if command -v df &> /dev/null; then
    AVAILABLE=$(df -h . | tail -1 | awk '{print $4}')
    echo -e "${GREEN}✓${NC} 当前目录可用空间: $AVAILABLE"
    echo "  建议: 至少需要 5GB 空间用于编译"
    ((PASS++))
else
    echo -e "${YELLOW}⊘${NC} 无法检查磁盘空间"
fi
echo ""

echo "=========================================="
echo "检查结果汇总"
echo "=========================================="
echo -e "通过: ${GREEN}$PASS${NC}"
echo -e "失败: ${RED}$FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}✓ 环境检查通过！可以开始编译。${NC}"
    exit 0
else
    echo -e "${RED}✗ 环境检查失败，请先安装缺失的工具。${NC}"
    exit 1
fi
