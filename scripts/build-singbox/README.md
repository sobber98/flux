# sing-box 移动端库编译指南

本指南将帮助您编译 sing-box 1.13.7 的 Android 和 iOS 库，用于 Flux VPN 项目的移动端集成。

---

## 📋 前置要求

### 所有平台

- **Go 1.21+**
  - 下载：https://go.dev/dl/
  - 验证：`go version`

- **gomobile**
  ```bash
  go install golang.org/x/mobile/cmd/gomobile@latest
  gomobile init
  ```

- **Git**
  - 验证：`git --version`

- **磁盘空间**：至少 5GB

### Android 编译

- **Android NDK r26+**
  - 通过 Android Studio SDK Manager 安装
  - 或访问：https://developer.android.com/ndk/downloads
  - 设置环境变量：
    ```bash
    export ANDROID_NDK_HOME=/path/to/ndk
    # 添加到 ~/.bashrc 或 ~/.zshrc 使其永久生效
    ```

### iOS 编译（仅 macOS）

- **Xcode 15+**
  - 从 App Store 安装
  - 验证：`xcodebuild -version`

---

## 🚀 快速开始

### 步骤 1：环境检查

```bash
cd /opt/flux_app/flux
./scripts/build-singbox/check-env.sh
```

**预期输出**：
```
==========================================
sing-box 移动端编译环境检查
==========================================

1. 检查 Go 环境
----------------------------------------
✓ Go: /usr/local/go/bin/go
  版本: go version go1.21.5 linux/amd64

2. 检查 gomobile
----------------------------------------
✓ gomobile: /home/user/go/bin/gomobile

...

==========================================
检查结果汇总
==========================================
通过: 6
失败: 0

✓ 环境检查通过！可以开始编译。
```

如果有失败项，请按照提示安装缺失的工具。

---

### 步骤 2：编译库文件

#### 方式 A：一键编译（推荐）

```bash
./scripts/build-singbox/build-all.sh
```

交互式选择编译目标：
- `1` - 仅 Android
- `2` - 仅 iOS（需要 macOS）
- `3` - Android + iOS（需要 macOS）

#### 方式 B：单独编译

**编译 Android 库**：
```bash
./scripts/build-singbox/build-android.sh
```

**编译 iOS 库**（仅 macOS）：
```bash
./scripts/build-singbox/build-ios.sh
```

---

### 步骤 3：验证产物

**Android**：
```bash
ls -lh android/app/libs/libbox.aar
unzip -l android/app/libs/libbox.aar | grep .so
```

应该看到：
```
jni/arm64-v8a/libgojni.so
jni/armeabi-v7a/libgojni.so
jni/x86/libgojni.so
jni/x86_64/libgojni.so
classes.jar
```

**iOS**（macOS）：
```bash
ls -lh ios/Frameworks/Libbox.xcframework/
```

应该看到：
```
ios-arm64/Libbox.framework
ios-arm64_x86_64-simulator/Libbox.framework
```

---

## ⏱️ 编译时间估算

| 平台 | 首次编译 | 增量编译 |
|------|----------|----------|
| Android | 10-15 分钟 | 3-5 分钟 |
| iOS | 8-12 分钟 | 2-4 分钟 |

*时间取决于您的硬件配置和网络速度*

---

## 🔧 常见问题

### Q1: gomobile init 失败

**错误**：
```
gomobile: no Android NDK found in $ANDROID_NDK_HOME
```

**解决**：
```bash
# 找到 NDK 路径（通常在 Android SDK 目录下）
export ANDROID_NDK_HOME=~/Android/Sdk/ndk/26.1.10909125

# 添加到 shell 配置文件
echo 'export ANDROID_NDK_HOME=~/Android/Sdk/ndk/26.1.10909125' >> ~/.bashrc
source ~/.bashrc
```

### Q2: 编译时内存不足

**错误**：
```
signal: killed
```

**解决**：
- 关闭其他应用释放内存
- 或使用云服务器编译（推荐 4GB+ RAM）

### Q3: iOS 编译失败 - 找不到 Xcode

**错误**：
```
xcrun: error: SDK "iphoneos" cannot be located
```

**解决**：
```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

### Q4: 网络问题导致依赖下载失败

**解决**：
```bash
# 使用 Go 代理
export GOPROXY=https://goproxy.cn,direct

# 或使用其他代理
export GOPROXY=https://proxy.golang.org,direct
```

### Q5: 编译产物体积过大

**当前配置**：
- Android AAR: ~40-50MB
- iOS XCFramework: ~80-100MB

**优化**（已应用）：
- 使用 `-ldflags="-s -w"` 去除调试信息
- 仅启用必要的 tags

---

## 📦 编译产物说明

### Android: libbox.aar

**结构**：
```
libbox.aar
├── AndroidManifest.xml
├── classes.jar          # Java 绑定层
├── jni/
│   ├── arm64-v8a/
│   │   └── libgojni.so  # 64位 ARM (主流设备)
│   ├── armeabi-v7a/
│   │   └── libgojni.so  # 32位 ARM (旧设备)
│   ├── x86/
│   │   └── libgojni.so  # 32位 x86 (模拟器)
│   └── x86_64/
│       └── libgojni.so  # 64位 x86 (模拟器)
└── R.txt
```

**使用**：
```kotlin
// android/app/build.gradle.kts
dependencies {
    implementation(files("libs/libbox.aar"))
}
```

### iOS: Libbox.xcframework

**结构**：
```
Libbox.xcframework/
├── Info.plist
├── ios-arm64/
│   └── Libbox.framework  # 真机 (iPhone/iPad)
└── ios-arm64_x86_64-simulator/
    └── Libbox.framework  # 模拟器
```

**使用**：
1. 在 Xcode 中拖入 `Libbox.xcframework`
2. Target → General → Frameworks, Libraries, and Embedded Content
3. 设置为 `Embed & Sign`

---

## 🔄 更新 sing-box 版本

如需升级到新版本（如 v1.14.0）：

1. 修改脚本中的版本号：
   ```bash
   # 编辑 build-android.sh 和 build-ios.sh
   SINGBOX_VERSION="v1.14.0"
   ```

2. 清理旧的构建：
   ```bash
   rm -rf build/singbox
   ```

3. 重新编译：
   ```bash
   ./scripts/build-singbox/build-all.sh
   ```

---

## 📚 参考资料

- [sing-box 官方文档](https://sing-box.sagernet.org/)
- [sing-box libbox API](https://sing-box.sagernet.org/developer/libbox/)
- [gomobile 文档](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)
- [Android NDK 指南](https://developer.android.com/ndk/guides)
- [SagerNet/sing-box-for-android](https://github.com/SagerNet/sing-box-for-android)
- [SagerNet/sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple)

---

## ✅ 下一步

编译完成后，继续进行：

1. **阶段 2**：Android 原生层集成
   - 创建 `SingboxService.kt`
   - 修改 `FluxVpnService.kt`
   - 添加 MethodChannel 接口

2. **阶段 3**：iOS 原生层集成
   - 创建 `SingboxManager.swift`
   - 修改 `PacketTunnelProvider.swift`
   - 添加 MethodChannel 接口

3. **阶段 4**：Flutter 层适配
   - 修改 `v2ray_service.dart`
   - 添加协议路由逻辑

---

**编译脚本版本**：1.0
**最后更新**：2026-04-11
