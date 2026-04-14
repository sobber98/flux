import 'dart:io';
import 'remote_config_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/server_node.dart';

/// Sing-box service for stable Tun mode support
/// Uses sing-box core instead of Xray for Tun functionality
class SingboxService {
  static final SingboxService _instance = SingboxService._internal();
  factory SingboxService() => _instance;
  SingboxService._internal();

  Process? _singboxProcess;
  bool _isConnected = false;
  final _statusController = StreamController<bool>.broadcast();

  // Mobile platform MethodChannel for sing-box engine
  static const MethodChannel _singboxChannel =
      MethodChannel('com.example.flux/singbox');
  static const EventChannel _singboxStatusChannel =
      EventChannel('com.example.flux/singbox_status');
  static Stream<bool>? _mobileStatusStream;

  Stream<bool> get statusStream => _statusController.stream;
  bool get isConnected => _isConnected;

  /// Mobile status stream (from native sing-box VPN service)
  Stream<bool> get mobileStatusStream {
    _mobileStatusStream ??= _singboxStatusChannel
        .receiveBroadcastStream()
        .map((event) => event == true || event == 1)
        .handleError((e) {
      debugPrint('[SingboxService] Mobile status stream error: $e');
    });
    return _mobileStatusStream!;
  }

  /// Connect via sing-box on mobile (Android/iOS)
  /// Used for protocols not supported by V2Ray, such as AnyTLS
  Future<bool> connectMobile(ServerNode node, {
    int socksPort = 10808,
    int httpPort = 10809,
    bool isGlobal = false,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      // Desktop: fall back to the existing TUN-based method
      return connectWithTun(node, socksPort: socksPort, httpPort: httpPort, isGlobal: isGlobal);
    }

    try {
      debugPrint('[SingboxService] Connecting via sing-box mobile (protocol: ${node.protocol})');

      final customRules = isGlobal
          ? {'dns': <Map<String, dynamic>>[], 'route': <Map<String, dynamic>>[]}
          : await _loadCustomRules();

      final tunName = 'flux_tun_${Random().nextInt(9000) + 1000}';

      final config = _buildSingboxConfig(
        node,
        socksPort: socksPort,
        httpPort: httpPort,
        customDnsRules: customRules['dns'],
        customRouteRules: customRules['route'],
        isGlobal: isGlobal,
        tunInterfaceName: tunName,
      );

      final configJson = jsonEncode(config);

      final result = await _singboxChannel.invokeMethod('connect', {
        'config': configJson,
      });

      final success = result == true;
      _isConnected = success;
      _statusController.add(success);
      debugPrint('[SingboxService] Mobile connect result: $success');
      return success;
    } catch (e) {
      debugPrint('[SingboxService] Mobile connect failed: $e');
      _isConnected = false;
      _statusController.add(false);
      return false;
    }
  }

  /// Disconnect sing-box on mobile (Android/iOS)
  Future<bool> disconnectMobile() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return disconnect();
    }

    try {
      debugPrint('[SingboxService] Disconnecting sing-box mobile');
      await _singboxChannel.invokeMethod('disconnect');
      _isConnected = false;
      _statusController.add(false);
      return true;
    } catch (e) {
      debugPrint('[SingboxService] Mobile disconnect failed: $e');
      return false;
    }
  }

  /// Start sing-box with Tun mode for the given node
  Future<bool> connectWithTun(ServerNode node, {
    int socksPort = 10808, 
    int httpPort = 10809,
    bool isGlobal = false,
  }) async {
    try {
      // Determine if we can reload (Windows only, and running)
      bool isReload = false;
      if (Platform.isWindows && await _isSingboxRunning()) {
        isReload = true;
        debugPrint('[SingboxService] Detected running instance, will create reload signal');
      } else {
        await disconnect();
      }
      
      final customRules = isGlobal ? {'dns': <Map<String, dynamic>>[], 'route': <Map<String, dynamic>>[]} : await _loadCustomRules();
      debugPrint('[SingboxService] Loaded ${customRules['dns']?.length ?? 0} DNS rules and ${customRules['route']?.length ?? 0} route rules (Global: $isGlobal)');

      // Generate random interface name
      final tunName = "flux_tun_${Random().nextInt(9000) + 1000}";
      debugPrint('[SingboxService] Using interface name: $tunName');

      // Prepare log path for Windows to fix file locking by PowerShell redirection
      String? logOutput;
      if (Platform.isWindows) {
         final appDir = await getApplicationSupportDirectory();
         logOutput = path.join(appDir.path, 'singbox-output.log');
      }

      final config = _buildSingboxConfig(node, 
          socksPort: socksPort, 
          httpPort: httpPort,
          customDnsRules: customRules['dns'],
          customRouteRules: customRules['route'],
          isGlobal: isGlobal,
          tunInterfaceName: tunName,
          logOutput: logOutput,
      );
      final configPath = await _writeConfig(config);
      final singboxPath = await _getSingboxPath();
      
      if (singboxPath == null) {
        debugPrint('[SingboxService] sing-box executable not found');
        return false;
      }
      
      if (Platform.isWindows) {
        // Windows Logic: Reload or Start Runner
        final appDir = await getApplicationSupportDirectory();
        final logPath = path.join(appDir.path, 'singbox-output.log');
        
        if (isReload) {
           final reloadFlag = File(path.join(appDir.path, 'config.reload'));
           await reloadFlag.create();
           // Runner picks it up, kills old process, starts new one.
           // We just wait for new process to stabilize in the loop below.
        } else {
           final result = await _startWithUAC(singboxPath, configPath, logPath);
           if (!result) {
             debugPrint('[SingboxService] UAC elevation failed or was denied');
             return false;
           }
        }
        
        // Wait for sing-box startup (works for both start and reload)
        final started = await _waitForWindowsSingboxStartup(logPath);
        if (!started) {
          debugPrint('[SingboxService] sing-box process not found after start/reload');
          return false;
        }

      } else {
        // macOS/Linux: Direct start
        debugPrint('[SingboxService] Starting sing-box: $singboxPath run -c $configPath');
        _singboxProcess = await Process.start(
          singboxPath,
          ['run', '-c', configPath],
          runInShell: false,
          mode: ProcessStartMode.normal,
        );
        
        _singboxProcess!.stdout.transform(utf8.decoder).listen((line) {
          debugPrint('[sing-box] $line');
        });
        _singboxProcess!.stderr.transform(utf8.decoder).listen((line) {
          debugPrint('[sing-box Error] $line');
        });
        
        _singboxProcess?.exitCode.then((code) {
          debugPrint('[SingboxService] sing-box exited with code $code');
          if (_isConnected) {
            _updateStatus(false);
          }
        });
        
        await Future.delayed(const Duration(milliseconds: 800));
      }
      
      _updateStatus(true);
      return true;
    } catch (e) {
      debugPrint('[SingboxService] Connect error: $e');
      await disconnect();
      return false;
    }
  }

  /// Start sing-box with UAC elevation on Windows
  /// Uses PowerShell Start-Process -Verb RunAs to trigger UAC prompt
  Future<bool> _startWithUAC(
    String singboxPath,
    String configPath,
    String logPath,
  ) async {
    try {
      // Clean up old flags/logs
      final appDir = await getApplicationSupportDirectory();
      try {
        final f = File(logPath);
        if (await f.exists()) await f.delete();
        final stopFlag = File(path.join(appDir.path, 'config.stop'));
        if (await stopFlag.exists()) await stopFlag.delete();
        final reloadFlag = File(path.join(appDir.path, 'config.reload'));
        if (await reloadFlag.exists()) await reloadFlag.delete();
      } catch (_) {}

      final scriptPath = path.join(appDir.path, 'runner.ps1');
      final scriptContent = '''
\$singbox = "${singboxPath.replaceAll('\\', '\\\\')}"
\$config = "${configPath.replaceAll('\\', '\\\\')}"
\$log = "${logPath.replaceAll('\\', '\\\\')}"
\$flagDir = "${appDir.path.replaceAll('\\', '\\\\')}"
\$stopFlag = Join-Path \$flagDir "config.stop"
\$reloadFlag = Join-Path \$flagDir "config.reload"

# Force cleanup existing instances first
Stop-Process -Name sing-box -Force -ErrorAction SilentlyContinue

while (\$true) {
    if (Test-Path \$stopFlag) { Remove-Item \$stopFlag; exit }

    # Start Sing-box (Hidden)
    # Direct logging via sing-box config (output field), no PS redirection needed
    \$proc = Start-Process -FilePath \$singbox -ArgumentList "run", "-c", \$config -PassThru -WindowStyle Hidden

    # Monitor loop
    while (!\$proc.HasExited) {
        if (Test-Path \$stopFlag) {
            \$proc.Kill()
            Remove-Item \$stopFlag
            exit
        }
        if (Test-Path \$reloadFlag) {
            \$proc.Kill()
            Remove-Item \$reloadFlag
            # Break inner loop to restart sing-box with new config
            break 
        }
        Start-Sleep -Milliseconds 500
    }
    
    # If exited unexpectedly (crash), wait a bit before restart to avoid CPU spin
    if (\$proc.HasExited) {
        if (Test-Path \$stopFlag) { Remove-Item \$stopFlag; exit }
        Start-Sleep -Seconds 2
    }
}
''';

      await File(scriptPath).writeAsString(scriptContent);

      // Launch PowerShell runner as Admin
      // -WindowStyle Hidden to hide the Runner window itself
      // -ExecutionPolicy Bypass to allow script execution
      final psCommand = 'Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass", "-File", "$scriptPath" -Verb RunAs -WindowStyle Hidden';
      
      debugPrint('[SingboxService] Requesting UAC elevation for Runner...');
      
      final result = await Process.run(
        'powershell',
        ['-Command', psCommand],
        runInShell: true,
      );
      
      if (result.exitCode != 0) {
        debugPrint('[SingboxService] PowerShell runner error: ${result.stderr}');
        return false;
      }
      
      debugPrint('[SingboxService] Runner started successfully');
      return true;
    } catch (e) {
      debugPrint('[SingboxService] UAC start error: $e');
      return false;
    }
  }

  Future<bool> _waitForWindowsSingboxStartup(String logPath) async {
    const maxWaitMs = 6000;
    const stepMs = 300;
    int waited = 0;
    while (waited < maxWaitMs) {
      final checkResult = await Process.run(
        'tasklist',
        ['/FI', 'IMAGENAME eq sing-box.exe', '/NH'],
      );
      if (checkResult.stdout.toString().contains('sing-box.exe')) {
        return true;
      }

      final logFile = File(logPath);
      if (await logFile.exists()) {
        try {
          final content = await logFile.readAsString();
          if (content.contains('sing-box started')) {
            return true;
          }
        } catch (_) {}
      }

      await Future.delayed(const Duration(milliseconds: stepMs));
      waited += stepMs;
    }

    final logFile = File(logPath);
    if (await logFile.exists()) {
      try {
        final content = await logFile.readAsString();
        final lines = content.split('\n');
        final tail = lines.skip(lines.length > 40 ? lines.length - 40 : 0);
        debugPrint('[SingboxService] sing-box log tail:');
        for (final line in tail) {
          if (line.trim().isNotEmpty) debugPrint(line);
        }
      } catch (_) {}
    }

    return false;
  }

  /// Disconnect and cleanup
  Future<bool> disconnect() async {
    try {
      if (_singboxProcess != null) {
        _singboxProcess!.kill();
        _singboxProcess = null;
      }
      
      // Force cleanup any zombie processes and remove TUN adapter
      if (Platform.isWindows) {
        await _cleanupWindowsTun();
      } else {
        try {
          await Process.run('pkill', ['-f', 'sing-box']);
        } catch (_) {}
      }
      
      _updateStatus(false);
      return true;
    } catch (e) {
      debugPrint('[SingboxService] Disconnect error: $e');
      return false;
    }
  }

  /// 清理 Windows TUN 进程
  Future<void> _cleanupWindowsTun() async {
    debugPrint('[SingboxService] Cleaning up sing-box process...');
    
    // Check if running first
    if (!await _isSingboxRunning()) {
       debugPrint('[SingboxService] Process not running, skipping cleanup');
       return;
    }

    // 1. Try graceful stop via Runner logic (Signal file)
    try {
      final appDir = await getApplicationSupportDirectory();
      final stopFlag = File(path.join(appDir.path, 'config.stop'));
      await stopFlag.create();
      debugPrint('[SingboxService] Created stop flag');
    } catch (_) {}

    // Wait for Runner to pick up signal (up to 2 seconds)
    for (int i = 0; i < 10; i++) {
       await Future.delayed(const Duration(milliseconds: 200));
       if (!await _isSingboxRunning()) {
         debugPrint('[SingboxService] Stopped via Runner signal');
         return;
       }
    }

    // 2. If still running, try User taskkill
    try {
      await Process.run('taskkill', ['/F', '/IM', 'sing-box.exe']);
    } catch (_) {}

    // 3. Last resort: Admin kill (Will show UAC)
    if (await _isSingboxRunning()) {
      debugPrint('[SingboxService] Runner failed to stop, trying Admin Kill...');
      try {
        final psCommand = 'Start-Process taskkill -ArgumentList "/F /T /IM sing-box.exe" -Verb RunAs -WindowStyle Hidden';
        await Process.run('powershell', ['-Command', psCommand]);
      } catch (e) {
        debugPrint('[SingboxService] Admin kill failed: $e');
      }
    }
    
    await Future.delayed(const Duration(milliseconds: 1000));
    debugPrint('[SingboxService] Cleanup done');
  }

  Future<bool> _isSingboxRunning() async {
    try {
      final result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq sing-box.exe', '/NH']);
      return result.stdout.toString().contains('sing-box.exe');
    } catch (_) {
      return false;
    }
  }

  void _updateStatus(bool connected) {
    _isConnected = connected;
    _statusController.add(connected);
  }

  /// Build sing-box configuration for Tun mode
  Map<String, dynamic> _buildSingboxConfig(
    ServerNode node, {
    required int socksPort, 
    required int httpPort,
    List<Map<String, dynamic>>? customDnsRules,
    List<Map<String, dynamic>>? customRouteRules,
    bool isGlobal = false,
    String tunInterfaceName = "flux_tun",
    String? logOutput,
  }) {
    // Build outbound based on node protocol
    final outbound = _buildOutbound(node);
    
    // DNS Rules Logic
    // If Global: Route everything to remote (except node domain logic below)
    // If Rule: Use custom rules or default CN->Local
    final dnsRules = isGlobal 
        ? <Map<String, dynamic>>[] 
        : (customDnsRules ?? [
          {
            "domain_suffix": [".cn"],
            "server": "local"
          }
    ]);

    // Route Rules Logic
    final routeRules = isGlobal
        ? <Map<String, dynamic>>[
             // Global Mode Defaults (Critical rules only)
             { "protocol": "dns", "outbound": "dns-out" },
             { "ip_is_private": true, "outbound": "direct" },
             // No CN rules here
          ]
        : (customRouteRules ?? [
          {
            "protocol": "dns",
            "outbound": "dns-out"
          },
          {
            "ip_version": 6,
            "outbound": "block"
          },
          {
            "ip_is_private": true,
            "outbound": "direct"
          },
          {
            "domain_suffix": [".cn", ".local"],
            "outbound": "direct"
          },
          {
            "geoip": ["cn", "private"],
            "outbound": "direct"
          }
    ]);

    // 防止 DNS Loopback: 如果节点地址是域名，必须走本地 DNS 和直连
    if (InternetAddress.tryParse(node.address) == null) {
      dnsRules.insert(0, {
        "domain": [node.address],
        "server": "local"
      });
      routeRules.insert(0, {
        "domain": [node.address],
        "outbound": "direct"
      });
    }
    
    // 确保 dns-out 规则存在 (必须在最前)
    if (customRouteRules != null) {
       bool hasDnsOut = false;
       bool hasIpv6Rule = false;
       for (var r in customRouteRules) {
         if (r['protocol'] == 'dns') hasDnsOut = true;
         if (r['ip_version'] == 6) hasIpv6Rule = true;
       }
       if (!hasDnsOut) {
         routeRules.insert(0, {
            "protocol": "dns",
            "outbound": "dns-out"
         });
       }
       if (!hasIpv6Rule) {
         routeRules.insert(1, {
           "ip_version": 6,
           "outbound": "block"
         });
       }
       // Ensure private IP direct (recommended)
       routeRules.insert(1, {
         "ip_is_private": true,
         "outbound": "direct"
       });
    }


    return {
      "log": {
        "level": "info",
        "timestamp": true,
        if (logOutput != null) "output": logOutput,
      },
      "dns": {
        "servers": [
          {
            "tag": "remote",
            "address": "8.8.8.8",
            "detour": "proxy"
          },
          {
            "tag": "local",
            "address": "223.5.5.5",
            "detour": "direct"
          }
        ],
        "rules": dnsRules,
        "final": "remote",
        "strategy": "prefer_ipv4"
      },
      "inbounds": [
        {
          "type": "tun",
          "tag": "tun-in",
          "interface_name": tunInterfaceName,
          "address": ["172.18.0.1/30"],
          "mtu": 1400,
          "auto_route": true,
          "strict_route": false,
          "stack": "gvisor",
          "sniff": true
        },
        {
          "type": "socks",
          "tag": "socks-in",
          "listen": "127.0.0.1",
          "listen_port": socksPort
        },
        {
          "type": "http",
          "tag": "http-in",
          "listen": "127.0.0.1",
          "listen_port": httpPort
        }
      ],
      "outbounds": [
        outbound,
        {
          "type": "direct",
          "tag": "direct"
        },
        {
          "type": "block",
          "tag": "block"
        },
        {
          "type": "dns",
          "tag": "dns-out"
        }
      ],
      "route": {
        "rules": routeRules,
        "auto_detect_interface": true,
        "final": "proxy"
      }
    };
  }

  /// Build outbound configuration based on node protocol
  Map<String, dynamic> _buildOutbound(ServerNode node) {
    final raw = node.rawConfig ?? {};
    
    switch (node.protocol.toLowerCase()) {
      case 'vless':
        final security = raw['security'] ?? raw['tls'] ?? raw['security_type'];
        final tlsEnabled =
            security == 'tls' || security == 'reality' || raw['tls'] == true;
        final flow = raw['flow'];
        final fingerprint = raw['fp'];
        return {
          "type": "vless",
          "tag": "proxy",
          "server": node.address,
          "server_port": node.port,
          "uuid": node.uuid ?? raw['id'] ?? '',
          if (flow != null && flow.toString().isNotEmpty) "flow": flow,
          if (tlsEnabled)
            "tls": {
              "enabled": true,
              "server_name": raw['sni'] ?? node.address,
              "insecure": raw['allowInsecure'] == true ||
                  raw['skip-cert-verify'] == true,
              "utls": {
                "enabled": fingerprint != null && fingerprint != '',
                "fingerprint": fingerprint ?? 'chrome'
              },
              "reality": security == 'reality'
                  ? {
                      "enabled": true,
                      "public_key": raw['pbk'] ?? '',
                      "short_id": raw['sid'] ?? ''
                    }
                  : null
            },
          "transport": _buildTransport(raw),
        };
      
      case 'vmess':
        return {
          "type": "vmess",
          "tag": "proxy",
          "server": node.address,
          "server_port": node.port,
          "uuid": node.uuid ?? raw['id'] ?? '',
          "alter_id": node.alterId ?? raw['aid'] ?? 0,
          "security": raw['scy'] ?? 'auto',
          "tls": (raw['tls'] == 'tls' || raw['security'] == 'tls') ? {
            "enabled": true,
            "server_name": raw['sni'] ?? raw['host'] ?? node.address
          } : null,
          "transport": _buildTransport(raw),
        };
      
      case 'trojan':
        return {
          "type": "trojan",
          "tag": "proxy",
          "server": node.address,
          "server_port": node.port,
          "password": raw['password'] ?? node.uuid ?? '',
          "tls": {
            "enabled": true,
            "server_name": raw['sni'] ?? node.address,
            "insecure": raw['allowInsecure'] == true
          }
        };
      
      case 'shadowsocks':
      case 'ss':
        return {
          "type": "shadowsocks",
          "tag": "proxy",
          "server": node.address,
          "server_port": node.port,
          "method": raw['method'] ?? raw['cipher'] ?? 'aes-256-gcm',
          "password": raw['password'] ?? ''
        };
      
      case 'hysteria2':
      case 'hy2':
        return {
          "type": "hysteria2",
          "tag": "proxy",
          "server": node.address,
          "server_port": node.port,
          "password": raw['password'] ?? raw['auth'] ?? node.uuid ?? '',
          "up_mbps": raw['up'] ?? raw['up_mbps'] ?? 100,
          "down_mbps": raw['down'] ?? raw['down_mbps'] ?? 100,
          "obfs": raw['obfs'] != null && raw['obfs'] != '' ? {
            "type": raw['obfs-type'] ?? 'salamander',
            "password": raw['obfs-password'] ?? raw['obfs'] ?? ''
          } : null,
          "tls": {
            "enabled": true,
            "server_name": raw['sni'] ?? node.address,
            "insecure": raw['insecure'] == true || raw['skip-cert-verify'] == true
          }
        };
      
      case 'tuic':
        return {
          "type": "tuic",
          "tag": "proxy",
          "server": node.address,
          "server_port": node.port,
          "uuid": node.uuid ?? raw['uuid'] ?? '',
          "password": raw['password'] ?? '',
          "congestion_control": raw['congestion-controller'] ?? raw['congestion_control'] ?? 'bbr',
          "udp_relay_mode": raw['udp-relay-mode'] ?? 'native',
          "zero_rtt_handshake": raw['reduce-rtt'] ?? false,
          "tls": {
            "enabled": true,
            "server_name": raw['sni'] ?? node.address,
            "insecure": raw['skip-cert-verify'] == true,
            "alpn": raw['alpn'] != null ? (raw['alpn'] is List ? raw['alpn'] : [raw['alpn']]) : ["h3"]
          }
        };
      
      case 'wireguard':
      case 'wg':
        return {
          "type": "wireguard",
          "tag": "proxy",
          "server": node.address,
          "server_port": node.port,
          "local_address": raw['local-address'] ?? raw['address'] ?? ["10.0.0.2/32"],
          "private_key": raw['private-key'] ?? raw['privateKey'] ?? '',
          "peer_public_key": raw['public-key'] ?? raw['publicKey'] ?? raw['peer-public-key'] ?? '',
          "pre_shared_key": raw['pre-shared-key'] ?? raw['presharedKey'] ?? '',
          "reserved": raw['reserved'],
          "mtu": raw['mtu'] ?? 1280
        };
      
      case 'anytls':
        return {
          "type": "anytls",
          "tag": "proxy",
          "server": node.address,
          "server_port": node.port,
          "password": raw['password'] ?? node.uuid ?? '',
          "idle_session_check_interval": "30s",
          "idle_session_timeout": "30s",
          "min_idle_session": 5,
          "tls": {
            "enabled": true,
            "server_name": raw['sni'] ?? node.address,
            "insecure": raw['insecure'] == true || raw['insecure'] == '1',
          },
        };

      default:
        // Fallback to VLESS
        return {
          "type": "vless",
          "tag": "proxy",
          "server": node.address,
          "server_port": node.port,
          "uuid": node.uuid ?? '',
        };
    }
  }

  /// Build transport configuration
  Map<String, dynamic>? _buildTransport(Map<String, dynamic> raw) {
    final network = raw['net'] ?? raw['network'] ?? raw['type'] ?? 'tcp';
    
    switch (network) {
      case 'ws':
        return {
          "type": "ws",
          "path": raw['path'] ?? '/',
          "headers": raw['host'] != null ? {"Host": raw['host']} : null
        };
      case 'grpc':
        return {
          "type": "grpc",
          "service_name": raw['serviceName'] ?? raw['path'] ?? ''
        };
      case 'h2':
      case 'http':
        return {
          "type": "http",
          "host": raw['host'] != null ? [raw['host']] : null,
          "path": raw['path'] ?? '/'
        };
      default:
        return null;
    }
  }

  /// Write configuration to file
  Future<String> _writeConfig(Map<String, dynamic> config) async {
    final dir = await getApplicationSupportDirectory();
    final configPath = path.join(dir.path, 'singbox-config.json');
    await File(configPath).writeAsString(jsonEncode(config));
    debugPrint('[SingboxService] Config written to: $configPath');
    return configPath;
  }

  /// Get path to sing-box executable
  Future<String?> _getSingboxPath() async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final exeDir = File(exePath).parent.path;
      
      // Check installed location first
      final installPath = path.join(exeDir, 'bin', 'sing-box.exe');
      if (await File(installPath).exists()) return installPath;
      
      // Check AppSupport
      final appSupportDir = await getApplicationSupportDirectory();
      final appSupportPath = path.join(appSupportDir.path, 'bin', 'sing-box.exe');
      if (await File(appSupportPath).exists()) return appSupportPath;
      
      return null;
    }
    
    // macOS/Linux
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    
    final paths = [
      path.join(exeDir, 'data', 'xray-bin', 'sing-box'),
      'assets/bin/${Platform.isMacOS ? 'macos' : 'linux'}/sing-box',
      '/usr/local/bin/sing-box',
    ];
    
    for (final p in paths) {
      if (await File(p).exists()) {
        if (!Platform.isWindows) {
          try { await Process.run('chmod', ['+x', p]); } catch (_) {}
        }
        return p;
      }
    }
    
    return null;
  }

  /// Ensure sing-box binary is available (copy from assets if needed)
  Future<void> ensureAssets() async {
    if (!Platform.isWindows) return;
    
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    
    // Check if installed
    final installBinDir = Directory(path.join(exeDir, 'bin'));
    if (await installBinDir.exists()) {
      final singboxPath = path.join(installBinDir.path, 'sing-box.exe');
      final wintunPath = path.join(installBinDir.path, 'wintun.dll');
      final singboxExists = await File(singboxPath).exists();
      final wintunExists = await File(wintunPath).exists();
      if (singboxExists && wintunExists) return;
      if (singboxExists && !wintunExists) {
        await _copyWintunIfAvailable(installBinDir.path);
        return;
      }
    }
    
    // Copy from assets to AppSupport
    final appSupportDir = await getApplicationSupportDirectory();
    final binDir = Directory(path.join(appSupportDir.path, 'bin'));
    if (!await binDir.exists()) await binDir.create(recursive: true);
    
    final targetPath = path.join(binDir.path, 'sing-box.exe');
    
    // 如果目标文件已存在，跳过复制（避免文件被占用时复制失败）
    if (await File(targetPath).exists()) {
      debugPrint('[SingboxService] sing-box.exe already exists, skipping copy');
      return;
    }
    
    // Source from flutter_assets
    var sourcePath = path.join(
      exeDir,
      'data',
      'flutter_assets',
      'assets',
      'bin',
      'windows',
      'sing-box.exe',
    );
    if (!await File(sourcePath).exists()) {
      sourcePath = path.join('assets', 'bin', 'windows', 'sing-box.exe');
    }
    
    if (await File(sourcePath).exists()) {
      debugPrint('[SingboxService] Copying sing-box.exe to $targetPath');
      try {
        await File(sourcePath).copy(targetPath);
      } catch (e) {
        debugPrint('[SingboxService] Copy failed: $e');
      }
    }

    await _copyWintunIfAvailable(binDir.path);
  }

  Future<void> _copyWintunIfAvailable(String targetDir) async {
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    final targetPath = path.join(targetDir, 'wintun.dll');

    if (await File(targetPath).exists()) return;

    var sourcePath = path.join(
      exeDir,
      'data',
      'flutter_assets',
      'assets',
      'bin',
      'windows',
      'wintun.dll',
    );
    if (!await File(sourcePath).exists()) {
      sourcePath = path.join('assets', 'bin', 'windows', 'wintun.dll');
    }

    if (await File(sourcePath).exists()) {
      debugPrint('[SingboxService] Copying wintun.dll to $targetPath');
      try {
        await File(sourcePath).copy(targetPath);
      } catch (e) {
        debugPrint('[SingboxService] Copy wintun.dll failed: $e');
      }
    }
  }

  /// 加载自定义路由规则 (V2Ray 格式 -> Sing-box 格式)
  Future<Map<String, List<Map<String, dynamic>>>> _loadCustomRules() async {
    final dnsRules = <Map<String, dynamic>>[];
    final routeRules = <Map<String, dynamic>>[];
    
    try {
      // 检查 sing-box 数据库文件是否存在
      final appDir = await getApplicationSupportDirectory();
      final binDir = Directory(path.join(appDir.path, 'bin'));
      // Sing-box 1.9+ 默认寻找 .db 文件
      final hasGeositeDb = await File(path.join(binDir.path, 'geosite.db')).exists();
      final hasGeoipDb = await File(path.join(binDir.path, 'geoip.db')).exists();
      
      final enableGeosite = hasGeositeDb; 
      final enableGeoip = hasGeoipDb;

      debugPrint('[SingboxService] DB Status - Geosite: $hasGeositeDb, GeoIP: $hasGeoipDb');

      // 优先从 RemoteConfigService 获取 (支持缓存和加密)
      final json = await RemoteConfigService().fetchRoutingRules();
      
      if (json != null) {
         final rules = json['rules'] as List?;
         if (rules != null) {
            for (var r in rules) {
              if (r['type'] != 'field') continue;
              
              final domains = r['domain'] as List?;
              final ips = r['ip'] as List?;
              final outboundTag = r['outboundTag']; // direct, proxy, block
              
              final geosite = <String>[];
              final domainList = <String>[];
              final geoip = <String>[];
              final ipCidr = <String>[];
              
              if (domains != null) {
                for (var d in domains) {
                  // 支持 geosite:cn, domain:baidu.com 等格式
                  if (d.toString().startsWith('geosite:')) {
                    if (enableGeosite) geosite.add(d.toString().substring(8));
                  } else if (d.toString().startsWith('domain:')) {
                    domainList.add(d.toString().substring(7));
                  } else {
                    domainList.add(d.toString());
                  }
                }
              }
              
              if (ips != null) {
                for (var ip in ips) {
                  if (ip.toString().startsWith('geoip:')) {
                    if (enableGeoip) geoip.add(ip.toString().substring(6));
                  } else {
                    ipCidr.add(ip.toString());
                  }
                }
              }
              
              // 构建规则对象
              final ruleBase = <String, dynamic>{};
              if (geosite.isNotEmpty) ruleBase['geosite'] = geosite;
              if (domainList.isNotEmpty) ruleBase['domain'] = domainList;
              if (geoip.isNotEmpty) ruleBase['geoip'] = geoip;
              if (ipCidr.isNotEmpty) ruleBase['ip_cidr'] = ipCidr;
              
              if (ruleBase.isEmpty) continue;

              // 1. 生成 DNS 规则 (仅处理 domain 相关)
              if (geosite.isNotEmpty || domainList.isNotEmpty) {
                final dnsRule = Map<String, dynamic>.from(ruleBase);
                if (outboundTag == 'direct') {
                  dnsRule['server'] = 'local';
                  dnsRules.add(dnsRule);
                } else if (outboundTag == 'proxy') {
                  dnsRule['server'] = 'remote';
                  dnsRules.add(dnsRule);
                }
              }
              
              // 2. 生成 Route 规则
              final routeRule = Map<String, dynamic>.from(ruleBase);
              if (outboundTag == 'proxy') {
                 routeRule['outbound'] = 'proxy';
                 routeRules.add(routeRule);
              } else if (outboundTag == 'direct') {
                 routeRule['outbound'] = 'direct';
                 routeRules.add(routeRule);
              } else if (outboundTag == 'block') {
                 routeRule['outbound'] = 'block';
                 routeRules.add(routeRule);
              }
            }
         }
      }
    } catch (e) {
      debugPrint('[SingboxService] Error loading rules: $e');
    }
    
    return {'dns': dnsRules, 'route': routeRules};
  }
}
