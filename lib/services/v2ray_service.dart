import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:process_run/shell.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_node.dart';
import 'doh_resolver.dart';
import 'remote_config_service.dart';
import 'singbox_service.dart';

enum ProxyRoutingMode { global, rule }

/// Tracks which VPN engine is currently active
enum ActiveEngine { none, v2ray, singbox }

/// V2ray服务 - 全平台统一入口
class V2rayService {
  static const MethodChannel _channel = MethodChannel('com.example.flux/v2ray');
  static const EventChannel _statusChannel = EventChannel(
    'com.example.flux/v2ray_status',
  );
  static Stream<bool>? _statusStream;

  // 桌面端专用
  Process? _xrayProcess;

  // 桌面端连接状态 (因为桌面端主要靠本类管理状态)
  bool _desktopConnected = false;
  final _desktopStatusController = StreamController<bool>.broadcast();

  // 当前活跃的 VPN 引擎（用于 disconnect 路由）
  ActiveEngine _activeEngine = ActiveEngine.none;

  // 单例模式 (确保全局状态一致)
  static final V2rayService _instance = V2rayService._internal();
  factory V2rayService() => _instance;
  V2rayService._internal();

  Stream<bool> get statusStream {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return _desktopStatusController.stream;
    }
    _statusStream ??= _statusChannel.receiveBroadcastStream().map((event) {
      if (event is bool) return event;
      return event == true;
    });
    return _statusStream!;
  }

  // 动态端口
  int _socksPort = 10808;
  int _httpPort = 10809;

  // ...

  /// 查找可用端口
  Future<int> _findAvailablePort(int startPort) async {
    int port = startPort;
    while (port < 65535) {
      try {
        final socket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await socket.close();
        return port;
      } catch (_) {
        port++;
      }
    }
    return startPort; // Fallback
  }

  /// 连接到指定节点
  Future<bool> connect(ServerNode node) async {
    // 保存当前节点以便自动重连时使用
    _currentNode = node;

    // 1. 桌面端处理 (Win / Mac / Linux)
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        await disconnect(); // 确保先断开当前管理的进程

        // 分配端口
        _socksPort = await _findAvailablePort(10808);
        _httpPort = await _findAvailablePort(_socksPort + 1);
        print(
          '[V2rayService] Selected ports - SOCKS: $_socksPort, HTTP: $_httpPort',
        );

        bool success;

        // 根据 Tun 模式选择内核 (对齐 v2rayN 多内核架构)
        // Windows TUN 模式现在通过 UAC 提升权限运行 sing-box
        if (_enableTun) {
          // Tun 模式: 使用 sing-box (稳定的 Tun 支持)
          print('[V2rayService] Tun mode enabled - using sing-box core');
          await SingboxService().ensureAssets();
          success = await SingboxService().connectWithTun(
            node,
            socksPort: _socksPort,
            httpPort: _httpPort,
            isGlobal: _routingMode == ProxyRoutingMode.global,
          );
        } else {
          // 普通模式: 使用 Xray + 系统代理
          print('[V2rayService] System proxy mode - using Xray core');
          success = await _startDesktopXray(node);
        }


        if (success) {
          _updateDesktopStatus(true);
        }
        return success;
      } catch (e) {
        print('[V2rayService] Desktop Connect Error: $e');
        await disconnect();
        return false;
      }
    }

    // 2. 移动端处理 (Android / iOS)
    if (Platform.isFuchsia) return false;

    // Route protocols that require sing-box engine (e.g., AnyTLS)
    if (node.requiresSingbox) {
      _log('Mobile: Routing ${node.protocol} to sing-box engine');
      // Disconnect any existing V2Ray connection first
      if (_activeEngine == ActiveEngine.v2ray) {
        try { await _channel.invokeMethod<bool>('disconnect'); } catch (_) {}
      }
      final success = await SingboxService().connectMobile(
        node,
        socksPort: _socksPort,
        httpPort: _httpPort,
        isGlobal: _routingMode == ProxyRoutingMode.global,
      );
      if (success) _activeEngine = ActiveEngine.singbox;
      return success;
    }

    await _ensureMobileAssets();
    try {
      // Disconnect any existing sing-box connection first
      if (_activeEngine == ActiveEngine.singbox) {
        await SingboxService().disconnectMobile();
      }

      final resolvedNode = await _resolveServerAddress(node);
      final outboundConfig = resolvedNode.toV2rayConfig();

      // 构建完整配置包 (包含 Outbound 和 路由规则)
      final fullConfig = <String, dynamic>{
        'outbound': outboundConfig,
        'routingMode': _routingMode.name, // "global" or "rule"
      };

      if (_routingMode == ProxyRoutingMode.rule) {
        // ALWAYS add critical API domains to direct rules to prevent proxy loops/timeouts
        final apiDirectRule = {
          "type": "field",
          "domain": ["domain:your-api-domain.com"], // TODO: Replace with your API domain
          "outboundTag": "direct",
        };

        try {
          final remoteRules = await RemoteConfigService().fetchRoutingRules();
          if (remoteRules != null && remoteRules['rules'] is List) {
            final rules = (remoteRules['rules'] as List);
            rules.insert(0, apiDirectRule); // Priority 1
            fullConfig['routingRules'] = rules;
            _log('Mobile: Attached ${rules.length} remote rules');
          } else {
            fullConfig['routingRules'] = [apiDirectRule];
          }
        } catch (e) {
          _log('Mobile: Failed to fetch remote rules: $e');
          fullConfig['routingRules'] = [apiDirectRule];
        }
      }

      print('[V2rayService] Mobile Connecting. Mode: $_routingMode');
      final result = await _channel.invokeMethod<bool>('connect', {
        'config': jsonEncode(fullConfig),
      });
      final success = result ?? false;
      if (success) _activeEngine = ActiveEngine.v2ray;
      return success;
    } on PlatformException catch (_) {
      return false;
    }
  }

  void _updateDesktopStatus(bool isConnected) {
    _desktopConnected = isConnected;
    _desktopStatusController.add(isConnected);
  }

  // 代理模式状态
  ProxyRoutingMode _routingMode = ProxyRoutingMode.rule;
  bool _enableTun = false;
  ServerNode? _currentNode;

  /// 获取当前路由模式
  ProxyRoutingMode get routingMode => _routingMode;

  /// 获取 Tun 模式状态
  bool get tunEnabled => _enableTun;

  /// 设置路由模式
  Future<void> setRoutingMode(ProxyRoutingMode mode) async {
    if (_routingMode == mode) return;
    _routingMode = mode;
    _log('Routing mode set to: $mode');
    
    // 如果已连接，触发重连以应用新模式
    if (_isDesktopActive() && _currentNode != null) {
      _log('Auto-reconnecting to apply routing mode change...');
      await connect(_currentNode!);
    }
  }

  /// 设置是否开启 Tun 模式 (仅桌面端有效，需管理员权限)
  Future<void> setTunEnabled(bool enable) async {
    if (_enableTun == enable) return;
    _enableTun = enable;
    _log('Tun mode set to: $enable');
    
    // 持久化保存
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tun_mode_enabled', enable);
    
    // 如果已连接，触发重连以切换模式
    if (_isDesktopActive() && _currentNode != null) {
      _log('Auto-reconnecting to apply Tun mode change...');
      await connect(_currentNode!);
    }
  }

  /// 加载保存的 Tun 模式状态
  Future<void> loadTunState() async {
    final prefs = await SharedPreferences.getInstance();
    _enableTun = prefs.getBool('tun_mode_enabled') ?? false;
    _log('Loaded Tun mode state: $_enableTun');
  }

  bool _isDesktopActive() {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return false;
    }
    if (_desktopConnected) return true;
    if (_xrayProcess != null) return true;
    if (SingboxService().isConnected) return true;
    return false;
  }



  /// 桌面端 Xray 启动逻辑 (Win / Mac / Linux)
  Future<bool> _startDesktopXray(ServerNode node) async {
    // Ensure any previous instances are killed to release file locks
    if (Platform.isWindows) {
      try {
        // Force kill any existing xray.exe
        await Process.run('taskkill', ['/F', '/IM', 'xray.exe'], runInShell: true);
        // Wait for file handle release
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        // Ignore if process not found
        if (kDebugMode) print('[V2rayService] Kill xray error: $e');
      }
    }

    await _ensureDesktopAssets();

    // 桌面端：尝试挑选一个可达的 IP，避免本地 DNS 只返回不可达的单一 A 记录
    String? reachableIp;
    if (!_isIpAddress(node.address)) {
      reachableIp = await _pickReachableIp(node);
      if (reachableIp != null) {
        _log('Selected reachable IP for ${node.address}: $reachableIp');
      }
    }

    final (xrayPath, workingDir) = await _getDesktopXrayPath();
    if (xrayPath == null) {
      print('[V2rayService] Xray executable not found');
      return false;
    }

    final dir = await getApplicationSupportDirectory();
    final binDir = Platform.isWindows
        ? Directory(path.join(dir.path, 'bin'))
        : dir;
    if (!await binDir.exists()) await binDir.create(recursive: true);

    final configPath = path.join(binDir.path, 'config.json');

    // 构建 Inbounds - 非 TUN 模式不使用 fakedns
    final sniffingForProxy = _enableTun
        ? {
            "enabled": true,
            "destOverride": ["http", "tls", "fakedns"],
            "routeOnly": false,
          }
        : {
            "enabled": true,
            "destOverride": ["http", "tls"],
            "routeOnly": false,
          };

    final inbounds = [
      {
        "tag": "socks",
        "port": _socksPort,
        "listen": "127.0.0.1",
        "protocol": "socks",
        "settings": {"auth": "noauth", "udp": true},
        "sniffing": sniffingForProxy,
      },
      {
        "tag": "http",
        "port": _httpPort,
        "listen": "127.0.0.1",
        "protocol": "http",
        "sniffing": sniffingForProxy,
      },
    ];

    // Tun 模式支持
    if (_enableTun) {
      inbounds.add({
        "tag": "tun-in",
        "protocol": "tun",
        "settings": {"mtu": 1280},
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "fakedns"],
        },
      });
    }

    // 构建 Routing Rules
    List<Map<String, dynamic>> rules = [];

    // Tun 模式专用：排除本地链路地址 (NetBIOS/mDNS 广播会导致缓冲区耗尽)
    if (_enableTun) {
      rules.add({
        "type": "field",
        "outboundTag": "direct",
        "ip": ["169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32"],
      });
      rules.add({
        "type": "field",
        "outboundTag": "direct",
        "port": "137-139,5353", // NetBIOS and mDNS ports
      });
    }

    if (_routingMode == ProxyRoutingMode.global) {
      // 全局模式：所有流量走代理 (除了 localhost 和 private)
      rules.add({
        "type": "field",
        "outboundTag": "direct",
        "ip": ["geoip:private"],
      });
      rules.add({"type": "field", "outboundTag": "proxy", "port": "0-65535"});
    } else {
      // 规则模式：优先使用云端规则
      try {
        final remoteRules = await RemoteConfigService().fetchRoutingRules();
        if (remoteRules != null && remoteRules['rules'] is List) {
          rules.addAll(
            (remoteRules['rules'] as List).cast<Map<String, dynamic>>(),
          );
          print('[V2rayService] Loaded ${rules.length} remote rules');
        }
      } catch (e) {
        print('[V2rayService] Failed to load remote rules: $e');
      }

      // 如果没有远程规则，使用默认规则
      if (rules.isEmpty) {
        rules.addAll([
          {
            "type": "field",
            "ip": ["geoip:private", "geoip:cn"],
            "outboundTag": "direct",
          },
          {
            "type": "field",
            "domain": ["geosite:private", "geosite:cn"],
            "outboundTag": "direct",
          },
        ]);
      }
    }

    // 生成 Xray 配置 - 根据是否启用 TUN 模式决定 DNS 配置
    final dnsServers = _enableTun
        ? [
            "fakedns",
            {
              "address": "223.5.5.5",
              "port": 53,
              "domains": ["geosite:cn", "geosite:private", "domain:cn"],
            },
            "8.8.8.8",
          ]
        : [
            {
              "address": "223.5.5.5",
              "port": 53,
              "domains": ["geosite:cn", "geosite:private", "domain:cn"],
            },
            "8.8.8.8",
            "1.1.1.1",
          ];

    final fullConfig = {
      "log": {"loglevel": "info"},
      "dns": {"servers": dnsServers},
      if (_enableTun)
        "fakedns": [
          {"ipPool": "198.18.0.0/15", "poolSize": 65535},
        ],
      "inbounds": inbounds,
      "outbounds": [
        // 如果探测到可达 IP 则优先使用，否则保持域名
        _buildProxyOutbound(node, overrideAddress: reachableIp),
        {
          "protocol": "freedom",
          "tag": "direct",
          "settings": {"domainStrategy": "UseIP"},
        },
        {"protocol": "blackhole", "tag": "block"},
      ],
      "routing": {"domainStrategy": "IPOnDemand", "rules": rules},
    };

    await File(configPath).writeAsString(jsonEncode(fullConfig));

    print('[V2rayService] Starting Xray: $xrayPath -c $configPath');

    _xrayProcess = await Process.start(
      xrayPath,
      ['run', '-c', configPath],
      workingDirectory: workingDir ?? binDir.path,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );

    _xrayProcess!.stdout.transform(utf8.decoder).listen((line) {
      print('[Xray] $line');
    });
    _xrayProcess!.stderr.transform(utf8.decoder).listen((line) {
      print('[Xray Error] $line');
    });

    _xrayProcess?.exitCode.then((code) {
      print('Xray exited with code $code');
      if (_desktopConnected) {
        disconnect();
      }
    });

    // 只有在非 Tun 模式下才设置系统代理
    // 如果是 Tun 模式，通常由 Tun 接口接管，或者需要手动设置路由 (这里暂不自动设置系统代理，避免冲突)
    if (!_enableTun) {
      await _setDesktopProxy(true);
    }
    return true;
  }

  void _log(String msg) {
    if (kDebugMode) print('[V2rayService] $msg');
  }

  /// 检查字符串是否是 IP 地址
  bool _isIpAddress(String address) {
    // 简单检查：IPv4 或 IPv6
    return RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(address) ||
        address.contains(':');
  }

  /// 多源解析并快速探测可达 IP，避免命中被拦截/未开放的 A 记录
  Future<String?> _pickReachableIp(ServerNode node) async {
    final addresses = <String>{};
    try {
      final lookup = await InternetAddress.lookup(node.address);
      for (final a in lookup) {
        addresses.add(a.address);
      }
    } catch (_) {}

    try {
      final doh = await DohResolver.resolve(node.address);
      if (doh != null && doh.isNotEmpty) addresses.add(doh);
    } catch (_) {}

    if (addresses.isEmpty) return null;

    // 最多探测 4 个，避免连接过程阻塞过长
    for (final ip in addresses.take(4)) {
      try {
        final socket = await Socket.connect(
          ip,
          node.port,
          timeout: const Duration(milliseconds: 800),
        );
        await socket.close();
        return ip;
      } catch (_) {
        _log('Probe failed for $ip:${node.port}');
      }
    }
    return null;
  }

  /// 构建代理出站配置，允许覆盖地址用于可达性优先
  Map<String, dynamic> _buildProxyOutbound(
    ServerNode node, {
    String? overrideAddress,
  }) {
    final config = node.toV2rayConfig();
    config['tag'] = 'proxy';
    final targetAddress = overrideAddress ?? node.address;

    // 覆盖 vnext/servers 的地址，但保持 SNI/Host 使用原始域名
    if (config['settings'] != null && config['settings']['vnext'] != null) {
      for (var vnext in config['settings']['vnext']) {
        vnext['address'] = targetAddress;
      }
    }
    if (config['settings'] != null && config['settings']['servers'] != null) {
      for (var server in config['settings']['servers']) {
        server['address'] = targetAddress;
      }
    }

    // Linux/Desktop Compatibility Fix:
    if (Platform.isLinux) {
      // Disable flow (xtls-rprx-vision) as it might be unstable or causing EOF on this specific setup
      // UPDATE: Since we replaced the binary with official Xray 1.8.4, we should TRY ENABLE flow.
      // Commenting out the disable logic.
      /*
       if (config['settings'] != null && 
           config['settings']['vnext'] != null) {
           for (var vnext in config['settings']['vnext']) {
               if (vnext['users'] != null) {
                   for (var user in vnext['users']) {
                       if (user['flow'] == 'xtls-rprx-vision') {
                           user['flow'] = ''; // Disable flow
                       }
                   }
               }
           }
       }
       */
    }

    return config;
  }

  /// 确保桌面端资源存在 (主要是 Windows 需要复制)
  Future<void> _ensureDesktopAssets() async {
    if (!Platform.isWindows) return;

    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;

    // 新的安装目录结构：{app}/bin/ (由 Inno Setup 创建)
    final installBinDir = Directory(path.join(exeDir, 'bin'));

    // 检查是否是通过安装程序安装的 (bin 目录存在于 exe 旁边)
    if (await installBinDir.exists()) {
      print(
        '[V2rayService] Using installed binaries from: ${installBinDir.path}',
      );
      return; // 已安装，无需复制
    }

    // 开发环境或旧版本：需要从 assets 复制到 AppSupport
    final appSupportDir = await getApplicationSupportDirectory();
    final binDir = Directory(path.join(appSupportDir.path, 'bin'));
    if (!await binDir.exists()) await binDir.create(recursive: true);

    // Simplified naming: xray.exe for all Windows
    final xrayName = 'xray.exe';

    // 平台特定的二进制文件目录
    final platformDir = 'windows';
    var binSourceDir = path.join(
      exeDir,
      'data',
      'flutter_assets',
      'assets',
      'bin',
      platformDir,
    );
    var dataSourceDir = path.join(
      exeDir,
      'data',
      'flutter_assets',
      'assets',
      'bin',
    ); // geoip/geosite 在根目录

    if (!await Directory(binSourceDir).exists()) {
      print(
        '[V2rayService] Source dir not found at $binSourceDir, trying dev fallback...',
      );
      binSourceDir = path.join('assets', 'bin', platformDir);
      dataSourceDir = path.join('assets', 'bin');
    }

    print('[V2rayService] Binary source dir: $binSourceDir');

    // 复制 Xray 可执行文件
    // 复制 Xray 可执行文件 (始终覆盖以确保内核更新)
    final xrayTarget = File(path.join(binDir.path, xrayName));
    final xraySource = File(path.join(binSourceDir, xrayName));
    if (await xraySource.exists()) {
      print('[V2rayService] Updating/Copying $xrayName...');
      try {
        // 先尝试删除旧文件防止 text file busy
        if (await xrayTarget.exists()) await xrayTarget.delete();
      } catch (e) {
        print('[V2rayService] Delete old binary error: $e');
      }

      await xraySource.copy(xrayTarget.path);
    } else {
      print(
        '[V2rayService] Warning: $xrayName not found at ${xraySource.path}',
      );
    }

    // copy wintun.dll if exists
    final wintunName = 'wintun.dll';
    final wintunTarget = File(path.join(binDir.path, wintunName));
    final wintunSource = File(path.join(binSourceDir, wintunName));
    if (await wintunSource.exists()) {
      print('[V2rayService] Copying $wintunName...');
      try {
        if (await wintunTarget.exists()) await wintunTarget.delete();
      } catch (_) {}
      await wintunSource.copy(wintunTarget.path);
    } else {
      print(
        '[V2rayService] Warning: $wintunName not found at ${wintunSource.path}',
      );
    }

    // 复制通用数据文件
    for (final asset in ['geoip.dat', 'geosite.dat']) {
      final targetFile = File(path.join(binDir.path, asset));
      if (!await targetFile.exists()) {
        final sourceFile = File(path.join(dataSourceDir, asset));
        if (await sourceFile.exists()) {
          print('[V2rayService] Copying $asset');
          await sourceFile.copy(targetFile.path);
        }
      }
    }
  }

  /// 获取桌面端 Xray 路径
  Future<(String?, String?)> _getDesktopXrayPath() async {
    if (Platform.isWindows) {
      // Simplified naming: xray.exe for all Windows
      final name = 'xray.exe';

      // 优先检查安装目录 ({app}/bin)
      final exePath = Platform.resolvedExecutable;
      final exeDir = File(exePath).parent.path;
      final installBinDir = path.join(exeDir, 'bin');
      final installFile = File(path.join(installBinDir, name));

      print('[V2rayService] Checking installed Xray at: ${installFile.path}');
      if (await installFile.exists()) {
        return (installFile.path, installBinDir);
      }

      // 回退到 AppSupport (开发环境)
      final appSupportDir = await getApplicationSupportDirectory();
      final binDir = path.join(appSupportDir.path, 'bin');
      final file = File(path.join(binDir, name));

      print('[V2rayService] Checking AppSupport Xray at: ${file.path}');
      if (await file.exists()) return (file.path, binDir);
      return (null, null);
    }

    // Mac / Linux: simplified naming (xray)
    String archName = 'xray';
    if (Platform.isMacOS) {
      archName = 'xray'; // Single binary for macOS
    } else if (Platform.isLinux) {
      archName = 'xray'; // Single binary for Linux
    }

    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;

    final possiblePaths = [
      // 1. Packaged: data/xray-bin/xray (relative to executable)
      path.join(exeDir, 'data', 'xray-bin', archName),

      // 2. Dev Source (Linux): assets/bin/linux/xray
      if (Platform.isLinux) 'assets/bin/linux/$archName',

      // 3. Dev Source (Mac): assets/bin/macos/xray
      if (Platform.isMacOS) 'assets/bin/macos/$archName',

      // 4. Old Dev fallback
      'assets/bin/$archName',

      // 5. System install
      '/usr/local/bin/xray',
    ];
    // 还可以添加打包后的路径检查

    for (final p in possiblePaths) {
      if (await File(p).exists()) {
        if (!Platform.isWindows)
          try {
            await Process.run('chmod', ['+x', p]);
          } catch (_) {}
        return (p, File(p).parent.path);
      }
    }
    return (null, null);
  }

  /// 确保移动端资源 (Android)
  Future<void> _ensureMobileAssets() async {
    if (!Platform.isAndroid) return;
    try {
      final dir = await getApplicationSupportDirectory();
      for (final file in ['geoip.dat', 'geosite.dat']) {
        final f = File('${dir.path}/$file');
        if (!await f.exists()) {
          final data = await rootBundle.load('assets/bin/$file');
          await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
        }
      }
    } catch (_) {}
  }

  Future<ServerNode> _resolveServerAddress(ServerNode node) async {
    final address = node.address;
    if (_isIpAddress(address)) return node;

    String? ip;
    try {
      final addresses = await InternetAddress.lookup(
        address,
      ).timeout(const Duration(seconds: 3));
      if (addresses.isNotEmpty) {
        // Filter out bogon IPs (e.g. 198.18.x.x used for fakedns)
        final validAddresses = addresses.where((a) {
          if (a.type != InternetAddressType.IPv4) return false;
          final ipStr = a.address;
          return !ipStr.startsWith('198.18.');
        }).toList();

        if (validAddresses.isNotEmpty) {
          ip = validAddresses.first.address;
        }
      }
    } catch (_) {}

    if (ip == null) {
      try {
        final dohIp = await DohResolver.resolve(address);
        if (dohIp != null && !dohIp.startsWith('198.18.')) {
          ip = dohIp;
        }
      } catch (_) {}
    }

    if (ip != null) {
      final newRawConfig = Map<String, dynamic>.from(node.rawConfig ?? {});
      if ((newRawConfig['sni'] as String?)?.isEmpty ?? true)
        newRawConfig['sni'] = address;
      newRawConfig['server'] = ip;

      return ServerNode(
        name: node.name,
        address: ip,
        port: node.port,
        protocol: node.protocol,
        uuid: node.uuid,
        alterId: node.alterId,
        network: node.network,
        security: node.security,
        rawConfig: newRawConfig,
        latency: node.latency,
        isSelected: node.isSelected,
      );
    }
    return node;
  }

  /// 断开连接
  Future<bool> disconnect() async {
    // 桌面端处理
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        // 停止 Xray 进程
        if (_xrayProcess != null) {
          _xrayProcess!.kill();
          _xrayProcess = null;
        }
        // 停止 sing-box 进程 (如果正在运行)
        await SingboxService().disconnect();

        await _setDesktopProxy(false);
        _updateDesktopStatus(false);
        return true;
      } catch (e) {
        return false;
      }
    }

    // 移动端处理
    try {
      if (_activeEngine == ActiveEngine.singbox) {
        // Disconnect sing-box engine (used by anytls etc.)
        final result = await SingboxService().disconnectMobile();
        _activeEngine = ActiveEngine.none;
        return result;
      }
      final result = await _channel.invokeMethod<bool>('disconnect');
      _activeEngine = ActiveEngine.none;
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// 获取连接状态
  Future<bool> isConnected() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return _desktopConnected;
    }
    try {
      if (_activeEngine == ActiveEngine.singbox) {
        return SingboxService().isConnected;
      }
      final result = await _channel.invokeMethod<bool>('isConnected');
      return result ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// 桌面系统代理设置
  Future<void> _setDesktopProxy(bool enable) async {
    try {
      if (Platform.isWindows) {
        await _setWindowsProxy(enable);
      } else if (Platform.isMacOS) {
        await _setMacProxy(enable);
      } else if (Platform.isLinux) {
        await _setLinuxProxy(enable);
      }
    } catch (e) {
      print('Set Proxy Error: $e');
    }
  }

  // Windows Proxy
  Future<void> _setWindowsProxy(bool enable) async {
    final shell = Shell();
    if (enable) {
      await shell.run(
        'reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" /v ProxyServer /t REG_SZ /d "127.0.0.1:$_httpPort" /f',
      );
      await shell.run(
        'reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" /v ProxyEnable /t REG_DWORD /d 1 /f',
      );
    } else {
      await shell.run(
        'reg add "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f',
      );
    }
  }

  // Mac Proxy
  Future<void> _setMacProxy(bool enable) async {
    final result = await Process.run('networksetup', [
      '-listallnetworkservices',
    ]);
    final services = result.stdout
        .toString()
        .split('\n')
        .where((s) => s.isNotEmpty && !s.startsWith('*'))
        .toList();
    for (final service in services) {
      if (enable) {
        await Process.run('networksetup', [
          '-setwebproxy',
          service,
          '127.0.0.1',
          '$_httpPort',
        ]);
        await Process.run('networksetup', [
          '-setsecurewebproxy',
          service,
          '127.0.0.1',
          '$_httpPort',
        ]);
        await Process.run('networksetup', [
          '-setsocksfirewallproxy',
          service,
          '127.0.0.1',
          '$_socksPort',
        ]);
      } else {
        await Process.run('networksetup', [
          '-setwebproxystate',
          service,
          'off',
        ]);
        await Process.run('networksetup', [
          '-setsecurewebproxystate',
          service,
          'off',
        ]);
        await Process.run('networksetup', [
          '-setsocksfirewallproxystate',
          service,
          'off',
        ]);
      }
    }
  }

  // Linux Proxy (Gnome)
  Future<void> _setLinuxProxy(bool enable) async {
    if (enable) {
      await Process.run('gsettings', [
        'set',
        'org.gnome.system.proxy',
        'mode',
        'manual',
      ]);
      // Use the dynamic ports we actually bound to, otherwise proxy settings
      // can point to the wrong port on Linux when 10808/10809 are occupied.
      await Process.run('gsettings', [
        'set',
        'org.gnome.system.proxy.http',
        'host',
        '127.0.0.1',
      ]);
      await Process.run('gsettings', [
        'set',
        'org.gnome.system.proxy.http',
        'port',
        '$_httpPort',
      ]);
      await Process.run('gsettings', [
        'set',
        'org.gnome.system.proxy.https',
        'host',
        '127.0.0.1',
      ]);
      await Process.run('gsettings', [
        'set',
        'org.gnome.system.proxy.https',
        'port',
        '$_httpPort',
      ]);
      await Process.run('gsettings', [
        'set',
        'org.gnome.system.proxy.socks',
        'host',
        '127.0.0.1',
      ]);
      await Process.run('gsettings', [
        'set',
        'org.gnome.system.proxy.socks',
        'port',
        '$_socksPort',
      ]);
    } else {
      await Process.run('gsettings', [
        'set',
        'org.gnome.system.proxy',
        'mode',
        'none',
      ]);
    }
  }
}
