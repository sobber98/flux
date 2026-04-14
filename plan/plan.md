# Flux 移动端 AnyTLS 协议适配 — 实施计划

## 问题陈述

Flux VPN 当前移动端（Android / iOS）通过 V2Ray (Xray) 内核处理所有代理协议，但 Xray 不支持 AnyTLS 协议。AnyTLS 是一种基于 TLS 的抗指纹代理协议，sing-box ≥1.12.0 原生支持。

**目标**: 在 Android 和 iOS 移动端增加 AnyTLS 协议支持，当检测到 anytls 节点时自动切换到 sing-box 内核执行，其他协议仍走 V2Ray。

## 整体方案

```
用户选择 anytls 节点 → UnifiedVpnService 检测协议类型
    ├─ 非 anytls → 走原有 V2Ray 通道 (MethodChannel → 原生 Xray)
    └─ anytls    → 走新增 sing-box 通道 (MethodChannel → 原生 sing-box/libbox)
```

**核心策略**: 最小侵入式修改，不改动现有 V2Ray 流程，仅新增 anytls 分支。

---

## 当前进度总览

上一轮 session 已完成全部 6 个阶段的代码编写和 18 个单元测试。代码变更大部分**未提交**到 Git（仅提交了 2 个构建脚本相关 commit）。

| 阶段 | 状态 | 说明 |
|------|------|------|
| 1. sing-box 编译升级 | ✅ 已完成 | build tags 已更新，已提交 |
| 2. Flutter 数据层 | ✅ 已完成 | ServerNode 模型扩展，未提交 |
| 3. Flutter 服务层 | ✅ 已完成 | SingboxService/V2rayService/UnifiedVpnService，未提交 |
| 4. Android 原生层 | ✅ 已完成 | SingboxVpnService + MainActivity，未提交 |
| 5. iOS 原生层 | ✅ 已完成 | SingboxManager + PacketTunnelProvider + AppDelegate，未提交 |
| 6. 单元测试 | ✅ 已完成 | 18 个 anytls 解析测试通过，未提交 |
| 7. Git 提交 | ❌ 未完成 | 大量改动仍在工作区 |
| 8. 构建验证 | ❌ 未完成 | 未运行 flutter build |
| 9. 真机测试 | ❌ 未完成 | 需要设备+服务器 |

---

## 阶段详情

### 阶段 1: sing-box 编译脚本升级 ✅

**已完成** — 2 个 commit 已提交

- `scripts/build-singbox/build-android.sh` — 添加 `with_reality_server,with_ech` tags
- `scripts/build-singbox/build-ios.sh` — 同上
- sing-box v1.12.0+ 默认包含 anytls，无需 `with_anytls` tag

### 阶段 2: Flutter 数据层 — ServerNode 模型扩展 ✅

**已完成** — 未提交

**文件**: `lib/models/server_node.dart`

| 改动 | 说明 |
|------|------|
| `requiresSingbox` getter | `protocol == 'anytls'` 时返回 true |
| `fromAnytls()` 静态工厂 | 解析 `anytls://password@host:port/?sni=xxx&insecure=0#name` |
| `fromClashConfig()` | 新增 `case 'anytls':` 分支处理 Clash YAML |
| `parseFromContent()` | 添加 `anytls://` 协议识别 |
| `_isUrl()` | 添加 `anytls://` scheme |
| `toV2rayConfig()` | anytls 返回空 dict（由 sing-box 处理） |

### 阶段 3: Flutter 服务层 — 引擎路由与 sing-box 移动端适配 ✅

**已完成** — 未提交

#### 3.1 SingboxService (`lib/services/singbox_service.dart`)
- 新增 MethodChannel `com.example.flux/singbox`
- 新增 EventChannel `com.example.flux/singbox_status`
- `connectMobile()` — 构建 sing-box 配置并通过 MethodChannel 发送
- `disconnectMobile()` — 通过 MethodChannel 断开
- `mobileStatusStream` — 接收原生层状态事件
- `_buildOutbound()` 新增 `case 'anytls':` 生成 sing-box outbound 配置

AnyTLS outbound 配置结构:
```json
{
  "type": "anytls",
  "tag": "proxy",
  "server": "<address>",
  "server_port": "<port>",
  "password": "<password>",
  "idle_session_check_interval": "30s",
  "idle_session_timeout": "30s",
  "min_idle_session": 5,
  "tls": {
    "enabled": true,
    "server_name": "<sni>",
    "insecure": false
  }
}
```

#### 3.2 V2rayService (`lib/services/v2ray_service.dart`)
- 新增 `ActiveEngine` 枚举 (`none / v2ray / singbox`)
- `connect()` 中检测 `node.requiresSingbox`，自动路由到 `SingboxService.connectMobile()`
- `disconnect()` 根据 `_activeEngine` 调用正确引擎的断开方法
- `isConnected()` 同理

#### 3.3 UnifiedVpnService (`lib/services/unified_vpn_service.dart`)
- `_mergedStatusController` 合并两个引擎的 statusStream
- UI 层无感知切换引擎

### 阶段 4: Android 原生层集成 ✅

**已完成** — 未提交

#### 4.1 SingboxVpnService (新建)
**文件**: `android/app/src/main/kotlin/com/example/flux/SingboxVpnService.kt` (~310 行)

- 继承 `VpnService()`，实现 `PlatformInterface` + `CommandServerHandler`
- 使用 libbox API: `Libbox.setup()` → `CommandServer` → `BoxService`
- TUN 接口: IPv4 10.0.0.2/30, MTU 1450
- 自身应用豁免防回环
- 通过 broadcast 上报连接状态

#### 4.2 MainActivity 扩展
**文件**: `android/app/src/main/kotlin/com/example/flux/MainActivity.kt`

- 注册 MethodChannel `com.example.flux/singbox`
- 注册 EventChannel `com.example.flux/singbox_status`
- `connectSingbox()` / `disconnectSingbox()` 方法
- VPN 权限请求: `REQUEST_SINGBOX_VPN_PERMISSION = 2`（与 V2Ray 的 `1` 分开）
- `pendingSingboxConfig` 缓存等待权限的配置

#### 4.3 AndroidManifest.xml
- 注册 `SingboxVpnService`，声明 `BIND_VPN_SERVICE` 权限

### 阶段 5: iOS 原生层集成 ✅

**已完成** — 未提交

#### 5.1 SingboxManager (新建)
**文件**: `ios/Runner/SingboxManager.swift` (~130 行)

- 管理 `NETunnelProviderManager`
- 通过 `providerConfiguration["engine"] = "singbox"` 标记引擎类型
- 连接前先停止 V2Ray 隧道
- `SingboxStatusStreamHandler` 监听 `NEVPNStatusDidChange`

#### 5.2 PacketTunnelProvider 双引擎支持
**文件**: `ios/Runner/PacketTunnelProvider.swift` (完全重写)

```swift
func startTunnel(...) {
    let engine = providerConfig["engine"] ?? "v2ray"
    if engine == "singbox" {
        startSingboxEngine(config:, completionHandler:)  // libbox
    } else {
        startV2RayEngine(config:, completionHandler:)     // 原有逻辑
    }
}
```

- `FluxPlatformInterface` 实现 `LibboxPlatformInterfaceProtocol`
- `LibboxSetMemoryLimit(true)` 适配 iOS Network Extension ~15MB 内存限制
- TUN fd 通过 `packetFlow.value(forKeyPath: "socket.fileDescriptor")` 获取

#### 5.3 AppDelegate 扩展
**文件**: `ios/Runner/AppDelegate.swift`

- 注册 sing-box MethodChannel + EventChannel

### 阶段 6: 测试 ✅ (单元测试) / ❌ (集成+真机)

#### 单元测试 ✅
**文件**: `test/anytls_test.dart` — 18 个测试全部通过

覆盖:
- `fromAnytls()` URI 解析（标准格式、默认端口、insecure 标志、无 fragment）
- `requiresSingbox` 属性验证
- `parseFromContent()` 混合协议订阅解析
- `fromClashConfig()` Clash YAML 格式解析
- 边界情况（IP 地址节点、缺省参数）

#### 集成测试 ❌ 未完成
- 订阅解析完整流程
- 引擎切换流程（vmess → anytls → vmess）
- 状态同步验证

#### 真机测试 ❌ 未完成
- Android 真机连接 AnyTLS 服务器
- iOS 真机连接 AnyTLS 服务器
- 延迟测试功能
- 长时间稳定性

---

## 待办事项 (Remaining TODOs)

### TODO-7: Git 提交整理
- 将所有未提交的改动整理成有意义的 commit
- 建议拆分为:
  - `feat(model): add AnyTLS protocol parsing support`
  - `feat(service): add sing-box mobile engine routing for AnyTLS`
  - `feat(android): add SingboxVpnService for AnyTLS mobile support`
  - `feat(ios): add SingboxManager and dual-engine PacketTunnelProvider`
  - `test: add AnyTLS protocol parsing unit tests`

### TODO-8: 构建验证
- 运行 `flutter analyze` 检查静态分析
- 运行 `flutter build apk --debug` 验证 Android 编译
- 运行 `flutter build ios --no-codesign` 验证 iOS 编译（需 macOS）
- **前置条件**: 需要先编译 libbox.aar 和 Libbox.xcframework（当前 `android/app/src/main/libs/` 中仅有 `libv2ray.aar`）

### TODO-9: 编译 sing-box 移动端库
- 运行 `scripts/build-singbox/build-android.sh` 生成 `libbox.aar`
- 运行 `scripts/build-singbox/build-ios.sh` 生成 `Libbox.xcframework`
- **前置条件**: 需要 Go 工具链 + gomobile

### TODO-10: 真机端到端测试
- 准备 AnyTLS 测试服务器
- Android 真机测试 VPN 连接
- iOS 真机测试 Network Extension
- 引擎切换测试（V2Ray ↔ sing-box）
- 边界情况: 网络切换、后台恢复、权限拒绝

---

## 文件变更清单

| 状态 | 文件路径 | 说明 |
|------|----------|------|
| ✅ 已提交 | `scripts/build-singbox/build-android.sh` | 添加 build tags |
| ✅ 已提交 | `scripts/build-singbox/build-ios.sh` | 添加 build tags |
| ⏳ 未提交 | `lib/models/server_node.dart` | fromAnytls、requiresSingbox 等 |
| ⏳ 未提交 | `lib/services/singbox_service.dart` | 移动端 MethodChannel + anytls outbound |
| ⏳ 未提交 | `lib/services/v2ray_service.dart` | ActiveEngine + 协议路由 |
| ⏳ 未提交 | `lib/services/unified_vpn_service.dart` | 合并状态流 |
| ⏳ 未提交 | `android/.../SingboxVpnService.kt` | **新建** — Android sing-box VPN 服务 |
| ⏳ 未提交 | `android/.../MainActivity.kt` | 注册 sing-box MethodChannel |
| ⏳ 未提交 | `android/app/src/main/AndroidManifest.xml` | 注册 SingboxVpnService |
| ⏳ 未提交 | `ios/Runner/SingboxManager.swift` | **新建** — iOS sing-box 管理器 |
| ⏳ 未提交 | `ios/Runner/PacketTunnelProvider.swift` | 双引擎支持 |
| ⏳ 未提交 | `ios/Runner/AppDelegate.swift` | 注册 sing-box MethodChannel |
| ⏳ 未提交 | `test/anytls_test.dart` | **新建** — 18 个单元测试 |

---

## 关键风险与注意事项

1. **VPN Service 冲突**: Android 同时只能有一个 VpnService — 切换引擎时必须先停止前一个
2. **iOS Network Extension 内存限制**: ~15MB，已调用 `LibboxSetMemoryLimit(true)`
3. **libbox 库未编译**: `android/app/src/main/libs/` 中当前只有 `libv2ray.aar`，需要编译 `libbox.aar`
4. **状态同步**: 两引擎状态合并到 `_mergedStatusController`，需确保 UI 一致
5. **DNS 回环**: sing-box 配置中已有节点域名直连 DNS 规则防止回环
