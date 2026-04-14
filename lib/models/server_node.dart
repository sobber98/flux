import 'dart:convert';

/// 服务器节点模型
class ServerNode {
  final String name;
  final String address;
  final int port;
  final String protocol; // vmess, vless, trojan, ss等
  final String? uuid;
  final String? alterId;
  final String? network; // tcp, ws, kcp等
  final String? security; // none, auto, aes-128-gcm等
  final Map<String, dynamic>? rawConfig; // 原始配置
  int? latency; // 延迟（毫秒）
  bool isSelected;

  /// 判断节点是否需要 sing-box 内核（V2Ray/Xray 不支持的协议）
  bool get requiresSingbox => protocol.toLowerCase() == 'anytls';

  ServerNode({
    required this.name,
    required this.address,
    required this.port,
    required this.protocol,
    this.uuid,
    this.alterId,
    this.network,
    this.security,
    this.rawConfig,
    this.latency,
    this.isSelected = false,
  });

  /// 从 Clash 配置解析节点
  factory ServerNode.fromClashConfig(Map<String, dynamic> config) {
    final type = config['type'] as String? ?? '';
    final name = config['name'] as String? ?? 'Unknown';
    final server = config['server'] as String? ?? '';
    final port = int.tryParse(config['port']?.toString() ?? '0') ?? 0;

    switch (type) {
      case 'vmess':
        // 获取 network 类型
        String networkType = 'tcp';
        if (config['network'] != null) {
          networkType = config['network'] as String;
        } else if (config['ws-opts'] != null) {
          networkType = 'ws';
        }
        
        // 获取 security/cipher
        String securityType = config['cipher'] as String? ?? 
                             config['security'] as String? ?? 
                             'auto';
        
        return ServerNode(
          name: name,
          address: server,
          port: port,
          protocol: 'vmess',
          uuid: config['uuid'] as String?,
          alterId: config['alterId']?.toString() ?? '0',
          network: networkType,
          security: securityType,
          rawConfig: {
            ...config,
            // 处理 Clash 格式的 WebSocket 配置
            if (config['ws-opts'] != null) 
              'path': (config['ws-opts'] as Map?)?['path'] ?? '/',
            if (config['ws-opts'] != null)
              'host': (config['ws-opts'] as Map?)?['headers']?['Host'],
            // 处理 TLS
            if (config['tls'] == true) 'tls': 'tls',
            if (config['servername'] != null) 'sni': config['servername'],
          },
        );
      case 'trojan':
        return ServerNode(
          name: name,
          address: server,
          port: port,
          protocol: 'trojan',
          uuid: config['password'] as String?, // trojan 使用 password 作为标识
          network: config['network'] as String? ?? 'tcp',
          rawConfig: {
            ...config,
            // 统一处理 sni 字段（Clash 可能使用 servername）
            'sni': config['sni'] ?? config['servername'],
          },
        );
      case 'vless':
        return ServerNode(
          name: name,
          address: server,
          port: port,
          protocol: 'vless',
          uuid: config['uuid'] as String?,
          network: config['network'] as String? ?? 'tcp',
          rawConfig: config,
        );
      case 'anytls':
        return ServerNode(
          name: name,
          address: server,
          port: port,
          protocol: 'anytls',
          uuid: config['password'] as String?,
          rawConfig: {
            ...config,
            'password': config['password'],
            if (config['sni'] != null) 'sni': config['sni'],
            if (config['server-name'] != null) 'sni': config['server-name'],
            if (config['skip-cert-verify'] != null) 'insecure': config['skip-cert-verify'],
          },
        );
      default:
        // 不支持的协议类型
        return ServerNode(
          name: name,
          address: server,
          port: port,
          protocol: type,
          rawConfig: config,
        );
    }
  }

  /// 从VMess链接解析
  factory ServerNode.fromVmess(String vmessLink) {
    try {
      // vmess://base64编码的JSON
      if (!vmessLink.startsWith('vmess://')) {
        throw Exception('Invalid VMess link');
      }

      final base64Str = vmessLink.substring(8);
      final decoded = String.fromCharCodes(
        base64Decode(base64Str),
      );
      final json = jsonDecode(decoded) as Map<String, dynamic>;

      return ServerNode(
        name: json['ps'] as String? ?? 'Unknown',
        address: json['add'] as String? ?? '',
        port: int.tryParse(json['port']?.toString() ?? '0') ?? 0,
        protocol: 'vmess',
        uuid: json['id'] as String?,
        alterId: json['aid']?.toString(),
        network: json['net'] as String? ?? 'tcp',
        security: json['scy'] as String? ?? 'auto',
        rawConfig: json,
      );
    } catch (e) {
      throw Exception('Failed to parse VMess link: $e');
    }
  }

  /// 从Trojan链接解析
  static ServerNode? fromTrojan(String trojanLink) {
    try {
      // trojan://password@server:port?params
      if (!trojanLink.startsWith('trojan://')) {
        return null;
      }

      final uri = Uri.parse(trojanLink);
      final query = uri.queryParameters;
      final password = uri.userInfo;
      final server = uri.host;

      final network = query['type'] ?? query['network'] ?? 'tcp';
      final security = query['security'];
      final sni = query['sni'] ?? query['peer'] ?? query['host'];
      final allowInsecure = _parseBool(query['allowInsecure'] ?? query['allowinsecure']);
      final headerType = query['headerType'] ?? query['header_type'] ?? query['header'];

      String address = server;
      int finalPort = uri.port;
      
      if (address.isEmpty) {
         try {
            final noScheme = trojanLink.substring(trojanLink.indexOf('://') + 3);
            final atIndex = noScheme.lastIndexOf('@');
            if (atIndex != -1) {
              final hostPortPart = noScheme.substring(atIndex + 1).split('/')[0].split('?')[0].split('#')[0];
              final hostPort = hostPortPart.split(':');
              address = hostPort[0];
              if (hostPort.length > 1) {
                finalPort = int.tryParse(hostPort[1]) ?? finalPort;
              }
            }
         } catch (_) {}
      }

      return ServerNode(
        name: uri.fragment.isNotEmpty ? uri.fragment : 'Trojan',
        address: address,
        port: finalPort,
        protocol: 'trojan',
        uuid: password, // trojan 使用 password
        network: network,
        rawConfig: {
          'password': password,
          'server': address, // Use resolved address
          'port': finalPort,
          if (security != null) 'security': security,
          if (sni != null) 'sni': sni,
          if (allowInsecure == true) 'allowInsecure': true,
          if (headerType != null) 'headerType': headerType,
        },
      );
    } catch (e) {
      return null;
    }
  }

  /// 从VLESS链接解析
  static ServerNode? fromVless(String vlessLink) {
    try {
      if (!vlessLink.startsWith('vless://')) {
        return null;
      }

      final uri = Uri.parse(vlessLink);
      final query = uri.queryParameters;
      final uuid = uri.userInfo;
      final network = query['type'] ?? query['network'] ?? 'tcp';
      final security = query['security'];
      final headerType = query['headerType'] ?? query['header_type'] ?? query['header'];
      final host = query['host'];
      final path = query['path'];
      final alpn = query['alpn'];
      final allowInsecure = _parseBool(
        query['insecure'] ?? query['allowInsecure'] ?? query['allow_insecure'],
      );

      String address = uri.host;
      int finalPort = uri.port;

      if (address.isEmpty) {
         try {
            final noScheme = vlessLink.substring(vlessLink.indexOf('://') + 3);
            final atIndex = noScheme.lastIndexOf('@');
            if (atIndex != -1) {
               // vless://uuid@host:port...
              final hostPortPart = noScheme.substring(atIndex + 1).split('/')[0].split('?')[0].split('#')[0];
              final hostPort = hostPortPart.split(':');
              address = hostPort[0];
              if (hostPort.length > 1) {
                finalPort = int.tryParse(hostPort[1]) ?? finalPort;
              }
            }
         } catch (_) {}
      }

      return ServerNode(
        name: _decodeNodeName(uri.fragment, fallback: 'VLESS'),
        address: address, // uri.host might be empty
        port: finalPort,
        protocol: 'vless',
        uuid: uuid,
        network: network,
        rawConfig: {
          'uuid': uuid,
          'server': address, // Use resolved address
          'port': finalPort,
          if (query['encryption'] != null) 'encryption': query['encryption'],
          if (query['flow'] != null) 'flow': query['flow'],
          if (security != null) 'security': security,
          if (query['sni'] != null) 'sni': query['sni'],
          if (query['fp'] != null) 'fp': query['fp'],
          if (query['pbk'] != null) 'pbk': query['pbk'],
          if (query['sid'] != null) 'sid': query['sid'],
          if (query['spx'] != null) 'spx': query['spx'],
          if (allowInsecure != null) 'allowInsecure': allowInsecure,
          if (headerType != null && headerType.isNotEmpty) 'headerType': headerType,
          if (host != null && host.isNotEmpty) 'host': host,
          if (path != null && path.isNotEmpty) 'path': path,
          if (alpn != null && alpn.isNotEmpty) 'alpn': alpn,
        },
      );
    } catch (e) {
      return null;
    }
  }

  static String _decodeNodeName(String fragment, {required String fallback}) {
    if (fragment.isEmpty) return fallback;
    try {
      return Uri.decodeComponent(fragment);
    } catch (e) {
      return fragment;
    }
  }

  /// 转换为V2ray配置JSON（返回outbound配置）
  Map<String, dynamic> toV2rayConfig() {
    if (protocol == 'vmess') {
      final security = rawConfig?['security'] as String?;
      final outbound = <String, dynamic>{
        'protocol': 'vmess',
        'settings': {
          'vnext': [
            {
              'address': address,
              'port': port,
              'users': [
                {
                  'id': uuid ?? '',
                  'alterId': int.tryParse(alterId ?? '0') ?? 0,
                  'security': security ?? 'auto',
                }
              ]
            }
          ]
        },
        'mux': {'enabled': false},
      };

      // 添加streamSettings
      final streamSettings = <String, dynamic>{
        'network': network ?? 'tcp',
      };

      // WebSocket配置
      if (network == 'ws') {
        streamSettings['wsSettings'] = {
          'path': rawConfig?['path'] ?? '/',
          if (rawConfig?['host'] != null && rawConfig!['host'].isNotEmpty)
            'headers': {
              'Host': rawConfig!['host'],
            },
        };
      }

      // gRPC 配置
      if (network == 'grpc') {
        streamSettings['grpcSettings'] = {
          'serviceName': rawConfig?['serviceName'] ?? rawConfig?['path'] ?? '',
          'multiMode': rawConfig?['multiMode'] == true,
        };
      }

      // TLS配置
      if (rawConfig?['tls'] == true || rawConfig?['tls'] == 'tls' || security == 'tls') {
        final sni = (rawConfig?['sni'] as String?)?.isNotEmpty == true
            ? rawConfig!['sni'] as String
            : (rawConfig?['host'] as String? ?? address.trim());
        final allowInsecure = rawConfig?['allowInsecure'] == true || rawConfig?['insecure'] == true;

        streamSettings['security'] = 'tls';
        streamSettings['tlsSettings'] = {
          if (sni.isNotEmpty) 'serverName': sni,
          'allowInsecure': allowInsecure,
          if (rawConfig?['alpn'] != null)
            'alpn': (rawConfig!['alpn'] as String)
                .split(',')
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toList(),
        };
      }

      outbound['streamSettings'] = streamSettings;
      return outbound;
    } else if (protocol == 'trojan') {
      // Trojan 协议配置
      final outbound = <String, dynamic>{
        'protocol': 'trojan',
        'settings': {
          'servers': [
            {
              'address': address.trim(),
              'port': port,
              'password': uuid ?? '',
            }
          ]
        },
      };

      // 添加 streamSettings
      final streamSettings = <String, dynamic>{
        'network': network ?? 'tcp',
      };

      // TLS 配置（Trojan 默认使用 TLS）
      streamSettings['security'] = 'tls';
      final sni = rawConfig?['sni'] as String?;
      final skipCertVerify = rawConfig?['skip-cert-verify'] == true ||
          rawConfig?['allowInsecure'] == true;
      
      if (sni != null || skipCertVerify) {
        streamSettings['tlsSettings'] = <String, dynamic>{
          if (sni != null) 'serverName': sni,
          if (skipCertVerify) 'allowInsecure': true,
        };
      }

      final headerType = rawConfig?['headerType'] as String?;
      if ((network ?? 'tcp') == 'tcp' && headerType != null) {
        streamSettings['tcpSettings'] = <String, dynamic>{
          'header': <String, dynamic>{
            'type': headerType,
          },
        };
      }

      outbound['streamSettings'] = streamSettings;
      return outbound;
    } else if (protocol == 'vless') {
      // VLESS 协议配置
      final outbound = <String, dynamic>{
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': address.trim(),
              'port': port,
              'users': [
                {
                  'id': uuid ?? '',
                  'encryption': rawConfig?['encryption'] ?? 'none',
                  'flow': rawConfig?['flow'] ?? 
                      ((rawConfig?['security'] == 'reality') ? 'xtls-rprx-vision' : ''),
                }
              ]
            }
          ]
        },
      };

      // 添加 streamSettings
      final streamSettings = <String, dynamic>{
        'network': network ?? 'tcp',
      };

      final security = rawConfig?['security'] as String?;
      final headerType = rawConfig?['headerType'] as String?;
      final host = rawConfig?['host'] as String?;
      final path = rawConfig?['path'] as String?;

      if ((network ?? 'tcp') == 'tcp') {
        if (headerType == 'http') {
          streamSettings['tcpSettings'] = <String, dynamic>{
            'header': <String, dynamic>{
              'type': 'http',
              'request': <String, dynamic>{
                if (host != null && host.isNotEmpty)
                  'headers': <String, dynamic>{
                    'Host': host.split(',').map((value) => value.trim()).where((value) => value.isNotEmpty).toList(),
                  },
                if (path != null && path.isNotEmpty)
                  'path': path.split(',').map((value) => value.trim()).where((value) => value.isNotEmpty).toList(),
              },
            },
          };
        } else {
          streamSettings['tcpSettings'] = <String, dynamic>{
            'header': <String, dynamic>{
              'type': 'none',
            },
          };
        }
      }

      // WebSocket 配置
      if (network == 'ws') {
        streamSettings['wsSettings'] = {
          'path': rawConfig?['path'] ?? '/',
          if (host != null && host.isNotEmpty)
            'headers': {
              'Host': host,
            },
        };
      }

      // gRPC 配置
      if (network == 'grpc') {
        streamSettings['grpcSettings'] = {
          'serviceName': rawConfig?['serviceName'] ?? rawConfig?['path'] ?? '',
          'multiMode': rawConfig?['multiMode'] == true,
        };
      }

      // TLS / REALITY 配置
      if (security == 'reality') {
        final sni = (rawConfig?['sni'] as String?)?.isNotEmpty == true
            ? rawConfig!['sni'] as String
            : (host ?? address.trim());
        streamSettings['security'] = 'reality';
        streamSettings['realitySettings'] = <String, dynamic>{
          if (sni.isNotEmpty) 'serverName': sni,
          'fingerprint': rawConfig?['fp'] ?? 'chrome', // Default to chrome to mimic browser
          if (rawConfig?['pbk'] != null) 'publicKey': rawConfig!['pbk'],
          if (rawConfig?['sid'] != null) 'shortId': rawConfig!['sid'],
          if (rawConfig?['spx'] != null) 'spiderX': rawConfig!['spx'],
          // Note: allowInsecure is NOT used in REALITY (per v2rayN implementation)
          'show': false,
          if (rawConfig?['alpn'] != null) 'alpn': (rawConfig?['alpn'] as String).split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
        };
      } else if (rawConfig?['tls'] == true ||
          rawConfig?['tls'] == 'tls' ||
          security == 'tls') {
        streamSettings['security'] = 'tls';
        final sni = (rawConfig?['sni'] as String?)?.isNotEmpty == true 
            ? rawConfig!['sni'] as String 
            : (host ?? address.trim());
        final allowInsecure = rawConfig?['allowInsecure'] == true || rawConfig?['insecure'] == true;
        
        streamSettings['tlsSettings'] = {
          if (sni.isNotEmpty) 'serverName': sni,
          'allowInsecure': allowInsecure,
          'fingerprint': rawConfig?['fp'] ?? 'chrome',
          if (rawConfig?['alpn'] != null) 'alpn': (rawConfig?['alpn'] as String).split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
        };
      }

      outbound['streamSettings'] = streamSettings;
      return outbound;
    } else if (protocol == 'hysteria2') {
      // Hysteria 2 Protocol Config (Xray-core v26+ format from PR #5508)
      // Xray uses protocol "hysteria" with streamSettings.network "hysteria"
      // and hysteriaSettings.version = 2
      final sni = rawConfig?['sni'] as String?;
      final allowInsecure = rawConfig?['allowInsecure'] == true || rawConfig?['insecure'] == true;
      
      final outbound = <String, dynamic>{
        'protocol': 'hysteria',  // NOTE: "hysteria" not "hysteria2"
        'settings': {
          'address': address.trim(),
          'port': port,
        },
        'streamSettings': {
          'network': 'hysteria',  // Hysteria transport
          'hysteriaSettings': {
            'version': 2,  // Hysteria 2
            'auth': uuid ?? '',  // Password
            'up': '100mbps',
            'down': '100mbps',
          },
          'security': 'tls',
          'tlsSettings': {
            'serverName': sni ?? address.trim(),
            'allowInsecure': allowInsecure,
            'alpn': ['h3'],
          },
        },
      };

      return outbound;
    } else if (protocol == 'shadowsocks') {
      // Shadowsocks Protocol Config
      final outbound = <String, dynamic>{
        'protocol': 'shadowsocks',
        'settings': {
          'servers': [
            {
              'address': address,
              'port': port,
              'method': security ?? 'aes-256-gcm',
              'password': uuid ?? '',
            }
          ]
        },
        'streamSettings': {
          'network': 'tcp',
          'security': 'none',
        },

      };
      return outbound;
      } else if (protocol == 'tuic') {
      // TUIC Protocol (Sing-box format)
      // Standard Fields: server, server_port, uuid, password
      final sni = rawConfig?['sni'] as String?;
      final allowInsecure = rawConfig?['allowInsecure'] == true;
      final congestionControl = rawConfig?['congestion_control'] ?? 'bbr';

      final outbound = <String, dynamic>{
        'protocol': 'tuic',
        'settings': {
            'server': address.trim(),
            'server_port': port,
            'uuid': uuid,
            'password': rawConfig?['password'],
            'congestion_control': congestionControl,
        },
        'streamSettings': {
            'security': 'tls',
            'tlsSettings': {
                'serverName': sni ?? address.trim(),
                'allowInsecure': allowInsecure,
            },
        },
      };
      return outbound;
    } else if (protocol == 'wireguard') {
      // WireGuard Protocol
      final outbound = <String, dynamic>{
        'protocol': 'wireguard',
        'settings': {
          'secretKey': rawConfig?['privateKey'] ?? rawConfig?['secretKey'],
          'address': [(rawConfig?['localAddress'] ?? '10.0.0.1/32').toString().trim()], // Interface address
          'peers': [
            {
              'publicKey': rawConfig?['publicKey'] ?? uuid, // Use uuid as pubkey fallback if needed
              'endpoint': '$address:$port',
              'keepAlive': 25,
            }
          ]
        },
      };
      return outbound;
    } else if (protocol == 'anytls') {
      // AnyTLS protocol is handled by sing-box engine, not V2Ray/Xray
      return {};
    }
    // 不支持的协议
    return {};
  }

  /// Parse Hysteria 2 Link (hy2://)
  static ServerNode? fromHysteria2(String link) {
    try {
      if (!link.startsWith('hy2://') && !link.startsWith('hysteria2://')) {
        return null; 
      }
      
      final uri = Uri.parse(link);
      final userInfo = uri.userInfo; 
      String password = userInfo;
      if (userInfo.contains(':')) {
        password = userInfo.split(':')[1];
      }

      final query = uri.queryParameters;
      final sni = query['sni'] ?? query['peer'] ?? uri.host;
      final insecure = _parseBool(query['insecure'] ?? query['allowInsecure']);
      final obfuscation = query['obfuscation'] ?? query['obfs'];
      final obfsType = query['obfs-type'];
      final obfsPassword = query['obfs-password'];

      String name = 'Hysteria2';
      try {
        if (uri.fragment.isNotEmpty) {
          name = Uri.decodeComponent(uri.fragment);
        }
      } catch (_) {
        name = uri.fragment;
      }

      String address = uri.host;
      int port = uri.port;

      // Fallback: If Uri.parse fails to extract host (possible with some custom schemes or formats), try manual
      if (address.isEmpty) {
         try {
            // Remove scheme
            final noScheme = link.substring(link.indexOf('://') + 3);
            // Split by @ to find host part
            final atIndex = noScheme.lastIndexOf('@');
            if (atIndex != -1) {
              final hostPortPart = noScheme.substring(atIndex + 1).split('/')[0].split('?')[0].split('#')[0];
              final hostPort = hostPortPart.split(':');
              address = hostPort[0];
              if (hostPort.length > 1) {
                port = int.tryParse(hostPort[1]) ?? port;
              }
            }
         } catch (_) {}
      }

      return ServerNode(
        name: name,
        address: address, // uri.host
        port: port, // uri.port
        protocol: 'hysteria2',
        uuid: password, // Store password in uuid field
        network: 'udp',
        rawConfig: {
          'password': password,
          'sni': sni,
          if (insecure != null) 'allowInsecure': insecure,
          if (obfuscation != null) 'obfuscation': obfuscation, // Legacy/Simple
          if (obfsType != null) 'obfs-type': obfsType,
          if (obfsPassword != null) 'obfs-password': obfsPassword,
          if (query['up_mbps'] != null) 'up_mbps': int.tryParse(query['up_mbps']!) ?? 100,
          if (query['down_mbps'] != null) 'down_mbps': int.tryParse(query['down_mbps']!) ?? 100,
        },
      );
    } catch (e) {
      return null;
    }
  }

  /// Parse Shadowsocks Link (ss://)
  static ServerNode? fromShadowsocks(String link) {
    try {
      if (!link.startsWith('ss://')) return null;

      Uri uri;
      String base64Part = link.substring(5);
      String? fragment;
      
      // Handle #fragment
      if (base64Part.contains('#')) {
        final parts = base64Part.split('#');
        base64Part = parts[0];
        if (parts.length > 1) fragment = parts[1];
      }

      // Handle old style ss://method:pass@host:port
      if (base64Part.contains('@')) {
        // Not fully base64 encoded
        uri = Uri.parse(link);
      } else {
        // Fully base64'd section
        // Decode base64 
        // Some clients use URL-safe base64, some standard
        String decoded;
        try {
          decoded = utf8.decode(base64Decode(base64Part));
        } catch (_) {
          // Try adding padding
          while (base64Part.length % 4 != 0) {
            base64Part += '=';
          }
          decoded = utf8.decode(base64Decode(base64Part));
        }
        
        // decoded string: method:password@host:port
        // or user info is encoded but host is not, handling various legacy formats is complex.
        // Assuming standard format method:password@server:port
        final parts = decoded.split('@');
        if (parts.length == 2) {
            final userInfo = parts[0];
            final serverInfo = parts[1];
            
            // Construct fake URI to parse
             uri = Uri.parse('ss://$userInfo@$serverInfo');
        } else {
             // Fallback or complex legacy format 
             // Try standard URI parsing on decoded if it looks like a URI component
             uri = Uri.parse('ss://$decoded');
        }
      }

      final userInfo = uri.userInfo;
      String method = 'aes-256-gcm';
      String password = '';
      
      if (userInfo.contains(':')) {
        final parts = userInfo.split(':');
        method = parts[0];
        password = parts.sublist(1).join(':');
      } else {
         // Maybe base64 encoded user info
         try {
             String normalizedUser = userInfo.replaceAll('-', '+').replaceAll('_', '/');
             while (normalizedUser.length % 4 != 0) {
               normalizedUser += '=';
             }
             final decodedUser = utf8.decode(base64Decode(normalizedUser));
             if (decodedUser.contains(':')) {
                 final parts = decodedUser.split(':');
                 method = parts[0];
                 password = parts.sublist(1).join(':');
             }
         } catch (_) {}
      }

      String name = 'Shadowsocks';
      if (fragment != null) {
          name = _decodeNodeName(fragment, fallback: 'Shadowsocks');
      } else if (uri.fragment.isNotEmpty) {
          name = _decodeNodeName(uri.fragment, fallback: 'Shadowsocks');
      }

      return ServerNode(
        name: name,
        address: uri.host,
        port: uri.port,
        protocol: 'shadowsocks',
        uuid: password, // Store password
        security: method, // Store cipher method
        rawConfig: {
          'method': method,
          'password': password,
        },
      );
    } catch (e) {
      return null;
    }
  }

  /// Parse TUIC Link (tuic://)
  static ServerNode? fromTuic(String link) {
     try {
       if (!link.startsWith('tuic://')) return null;
       final uri = Uri.parse(link);
       
       return ServerNode(
         name: _decodeNodeName(uri.fragment, fallback: 'TUIC'),
         address: uri.host,
         port: uri.port,
         protocol: 'tuic',
         uuid: uri.userInfo.contains(':') ? uri.userInfo.split(':')[1] : uri.userInfo, // UUID
         rawConfig: {
            'uuid': uri.userInfo.contains(':') ? uri.userInfo.split(':')[1] : uri.userInfo,
            'password': uri.userInfo.contains(':') ? uri.userInfo.split(':')[1] : uri.userInfo,
            'congestion_control': uri.queryParameters['congestion_control'],
            'sni': uri.queryParameters['sni'],
         },
       );
     } catch (e) { 
         return null; 
     }
  }

  /// Parse WireGuard Link (wg://)
  static ServerNode? fromWireGuard(String link) {
    try {
      if (!link.startsWith('wg://') && !link.startsWith('wireguard://')) return null;
      
      final uri = Uri.parse(link);
      final query = uri.queryParameters;
      
      // wg://privateKey@server:port?publicKey=...&ip=...
      final privateKey = uri.userInfo;
      final server = uri.host;
      final port = uri.port;
      
      final publicKey = query['publicKey'] ?? query['pubkey'];
      final ip = query['ip']; 
      final mtu = int.tryParse(query['mtu'] ?? '');
      final reserved = query['reserved'];
      
      return ServerNode(
        name: _decodeNodeName(uri.fragment, fallback: 'WireGuard'),
        address: server,
        port: port,
        protocol: 'wireguard',
        uuid: privateKey, // Store private key as UUID
        rawConfig: {
          'privateKey': privateKey,
          'publicKey': publicKey,
          'localAddress': ip,
          'mtu': mtu,
          'reserved': reserved,
        },
      );
    } catch (e) {
      return null;
    }
  }

  /// Parse AnyTLS Link (anytls://)
  /// Format: anytls://password@server:port/?sni=example.com&insecure=0#name
  static ServerNode? fromAnytls(String link) {
    try {
      if (!link.startsWith('anytls://')) return null;

      final uri = Uri.parse(link);
      final password = Uri.decodeComponent(uri.userInfo);

      String address = uri.host;
      int port = uri.port > 0 ? uri.port : 443;

      // Fallback manual parsing for edge cases
      if (address.isEmpty) {
        try {
          final noScheme = link.substring('anytls://'.length);
          final atIndex = noScheme.lastIndexOf('@');
          if (atIndex != -1) {
            final hostPortPart = noScheme.substring(atIndex + 1).split('/')[0].split('?')[0].split('#')[0];
            if (hostPortPart.startsWith('[')) {
              // IPv6
              final closeBracket = hostPortPart.indexOf(']');
              address = hostPortPart.substring(1, closeBracket);
              if (closeBracket + 1 < hostPortPart.length && hostPortPart[closeBracket + 1] == ':') {
                port = int.tryParse(hostPortPart.substring(closeBracket + 2)) ?? 443;
              }
            } else {
              final parts = hostPortPart.split(':');
              address = parts[0];
              if (parts.length > 1) port = int.tryParse(parts[1]) ?? 443;
            }
          }
        } catch (_) {}
      }

      final query = uri.queryParameters;
      final sni = query['sni'];
      final insecure = _parseBool(query['insecure']);

      final name = _decodeNodeName(uri.fragment, fallback: 'AnyTLS');

      return ServerNode(
        name: name,
        address: address,
        port: port,
        protocol: 'anytls',
        uuid: password,
        rawConfig: {
          'password': password,
          if (sni != null) 'sni': sni,
          if (insecure != null) 'insecure': insecure,
        },
      );
    } catch (e) {
      return null;
    }
  }

  /// Universal Parser
  static List<ServerNode> parseFromContent(String content) {
    if (content.trim().isEmpty) return [];
    
    final nodes = <ServerNode>[];
    
    // 1. Try to decode Base64 if content looks like a blob
    // Checks if the content has no spaces (except maybe trimmed) and valid chars
    // Or if lines appear base64 encoded.
    // Simplifying: Recursively process decoded content if the whole block is base64
    if (!_isUrl(content.trim())) {
         try {
            // Fix padding
            var pad = '';
            if (content.trim().length % 4 != 0) {
              pad = '=' * (4 - content.trim().length % 4);
            }
            final decoded = utf8.decode(base64Decode(content.trim() + pad));
            if (_isPrintable(decoded)) {
               // Recursively parse the decoded content
               nodes.addAll(parseFromContent(decoded));
            }
         } catch (_) {}
       
         // 如果整体作为 Base64 解码成功并解析出了节点，直接返回，避免下方逐行解析导致重复
         if (nodes.isNotEmpty) {
           return nodes;
         }
    }

    // 2. Process Line by Line
    final lines = content.split(RegExp(r'\r\n|\r|\n'));
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;
      
      // If line itself is Base64 encoded link (e.g. ss://BASE64), existing factories handle it?
      // No, existing factories handle uri-scheme, but the content inside might be base64.
      // But here we are talking about a line being just a base64 string "c3M6..."
      
       if (!_isUrl(line) && line.length > 20) { // arbitrary length check
         try {
             var pad = '';
             if (line.length % 4 != 0) pad = '=' * (4 - line.length % 4);
             final decodedBot = utf8.decode(base64Decode(line + pad));
             if (_isPrintable(decodedBot)) {
                nodes.addAll(parseFromContent(decodedBot));
                continue;
             }
         } catch (_) {}
      }

      ServerNode? node;
      if (line.startsWith('hysteria2://') || line.startsWith('hy2://')) {
        node = fromHysteria2(line);
      } else if (line.startsWith('vless://')) {
        node = fromVless(line);
      } else if (line.startsWith('vmess://')) {
        try {
          node = ServerNode.fromVmess(line);
        } catch (_) {}
      } else if (line.startsWith('ss://')) {
        node = fromShadowsocks(line);
      } else if (line.startsWith('trojan://')) {
        node = fromTrojan(line);
      } else if (line.startsWith('tuic://')) {
        node = fromTuic(line);
      } else if (line.startsWith('wg://') || line.startsWith('wireguard://')) {
        node = fromWireGuard(line);
      } else if (line.startsWith('anytls://')) {
        node = fromAnytls(line);
      }

      if (node != null) {
        nodes.add(node);
      }
    }
    
    return nodes;
  }
  
  static bool _isUrl(String s) {
    return s.startsWith('hysteria2://') || 
           s.startsWith('hy2://') ||
           s.startsWith('vless://') ||
           s.startsWith('vmess://') ||
           s.startsWith('ss://') ||
           s.startsWith('trojan://') || 
           s.startsWith('tuic://') ||
           s.startsWith('wg://') ||
           s.startsWith('wireguard://') ||
           s.startsWith('anytls://');
  }

  static bool _isPrintable(String s) {
      // Basic check if string is readable text (not binary garbage)
      // Allow some common protocol chars
      return !s.runes.any((r) => r < 32 && r != 10 && r != 13);
  }

  @override
  String toString() => '$name ($address:$port)';
}

bool? _parseBool(String? value) {
  if (value == null) return null;
  switch (value.toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
    case 'on':
      return true;
    case '0':
    case 'false':
    case 'no':
    case 'off':
      return false;
    default:
      return null;
  }
}
