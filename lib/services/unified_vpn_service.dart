import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/server_node.dart';
import 'singbox_service.dart';
import 'v2ray_service.dart';

/// 统一 VPN 服务 - 根据平台自动选择合适的实现
class UnifiedVpnService {
  static UnifiedVpnService? _instance;
  static UnifiedVpnService get instance => _instance ??= UnifiedVpnService._();
  
  UnifiedVpnService._();
  
  final _vpnService = V2rayService();
  
  // Merged status stream controller for both V2Ray and sing-box engines
  StreamController<bool>? _mergedStatusController;
  StreamSubscription<bool>? _v2rayStatusSub;
  StreamSubscription<bool>? _singboxStatusSub;

  /// 连接状态流 (merges V2Ray and sing-box status updates)
  Stream<bool> get statusStream {
    if (kIsWeb) {
      return Stream.value(false);
    }
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // Desktop: V2rayService handles everything (including desktop sing-box)
      return _vpnService.statusStream;
    }
    // Mobile: merge V2Ray native status + sing-box mobile status
    if (_mergedStatusController == null) {
      _mergedStatusController = StreamController<bool>.broadcast();
      _v2rayStatusSub = _vpnService.statusStream.listen(
        (status) => _mergedStatusController?.add(status),
        onError: (e) => debugPrint('[UnifiedVPN] V2Ray status error: $e'),
      );
      _singboxStatusSub = SingboxService().mobileStatusStream.listen(
        (status) => _mergedStatusController?.add(status),
        onError: (e) => debugPrint('[UnifiedVPN] Singbox status error: $e'),
      );
    }
    return _mergedStatusController!.stream;
  }
  
  /// 连接到指定节点
  Future<bool> connect(ServerNode node) async {
    if (kIsWeb) {
      debugPrint('[VPN] Web platform does not support VPN');
      return false;
    }
    
    return _vpnService.connect(node);
  }
  
  /// 断开连接
  Future<bool> disconnect() async {
    if (kIsWeb) return false;
    return _vpnService.disconnect();
  }
  
  /// 获取连接状态
  Future<bool> isConnected() async {
    if (kIsWeb) return false;
    return _vpnService.isConnected();
  }
  
  /// 释放资源
  void dispose() {
    _v2rayStatusSub?.cancel();
    _singboxStatusSub?.cancel();
    _mergedStatusController?.close();
    _mergedStatusController = null;
  }
}
