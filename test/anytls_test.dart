import 'package:flutter_test/flutter_test.dart';
import 'package:flux/models/server_node.dart';

void main() {
  group('ServerNode.fromAnytls', () {
    test('parses standard anytls URI', () {
      final node = ServerNode.fromAnytls(
        'anytls://mypassword@example.com:443/?sni=example.com&insecure=0#MyNode',
      );
      expect(node, isNotNull);
      expect(node!.protocol, 'anytls');
      expect(node.address, 'example.com');
      expect(node.port, 443);
      expect(node.uuid, 'mypassword');
      expect(node.name, 'MyNode');
      expect(node.rawConfig?['password'], 'mypassword');
      expect(node.rawConfig?['sni'], 'example.com');
      expect(node.rawConfig?['insecure'], false);
    });

    test('defaults port to 443 when not specified', () {
      final node = ServerNode.fromAnytls(
        'anytls://pass@host.example.com/?sni=host.example.com',
      );
      expect(node, isNotNull);
      expect(node!.port, 443);
    });

    test('parses custom port', () {
      final node = ServerNode.fromAnytls(
        'anytls://pass@host.example.com:8443/?sni=host.example.com',
      );
      expect(node, isNotNull);
      expect(node!.port, 8443);
    });

    test('parses insecure=1 as true', () {
      final node = ServerNode.fromAnytls(
        'anytls://pass@1.2.3.4:443/?sni=example.com&insecure=1#TestNode',
      );
      expect(node, isNotNull);
      expect(node!.rawConfig?['insecure'], true);
    });

    test('parses IP address server', () {
      final node = ServerNode.fromAnytls(
        'anytls://secret@192.168.1.100:443/?sni=proxy.example.com#IPNode',
      );
      expect(node, isNotNull);
      expect(node!.address, '192.168.1.100');
      expect(node.rawConfig?['sni'], 'proxy.example.com');
    });

    test('handles URL-encoded password', () {
      final node = ServerNode.fromAnytls(
        'anytls://my%40password@host.com:443/?sni=host.com#Encoded',
      );
      expect(node, isNotNull);
      expect(node!.uuid, 'my@password');
      expect(node.rawConfig?['password'], 'my@password');
    });

    test('handles URL-encoded fragment name', () {
      final node = ServerNode.fromAnytls(
        'anytls://pass@host.com:443/?sni=host.com#%E6%B5%8B%E8%AF%95%E8%8A%82%E7%82%B9',
      );
      expect(node, isNotNull);
      expect(node!.name, '测试节点');
    });

    test('falls back to "AnyTLS" when no fragment', () {
      final node = ServerNode.fromAnytls(
        'anytls://pass@host.com:443/?sni=host.com',
      );
      expect(node, isNotNull);
      expect(node!.name, 'AnyTLS');
    });

    test('returns null for non-anytls URI', () {
      final node = ServerNode.fromAnytls('vmess://somecontent');
      expect(node, isNull);
    });

    test('returns null for empty string', () {
      final node = ServerNode.fromAnytls('');
      expect(node, isNull);
    });

    test('handles missing sni param gracefully', () {
      final node = ServerNode.fromAnytls(
        'anytls://pass@host.com:443/#NoSNI',
      );
      expect(node, isNotNull);
      expect(node!.rawConfig?['sni'], isNull);
    });
  });

  group('ServerNode.requiresSingbox', () {
    test('returns true for anytls protocol', () {
      final node = ServerNode(
        name: 'test',
        address: '1.2.3.4',
        port: 443,
        protocol: 'anytls',
      );
      expect(node.requiresSingbox, true);
    });

    test('returns false for vmess protocol', () {
      final node = ServerNode(
        name: 'test',
        address: '1.2.3.4',
        port: 443,
        protocol: 'vmess',
      );
      expect(node.requiresSingbox, false);
    });

    test('returns false for trojan protocol', () {
      final node = ServerNode(
        name: 'test',
        address: '1.2.3.4',
        port: 443,
        protocol: 'trojan',
      );
      expect(node.requiresSingbox, false);
    });
  });

  group('ServerNode.parseFromContent with anytls', () {
    test('parses single anytls link', () {
      final nodes = ServerNode.parseFromContent(
        'anytls://pass@host.com:443/?sni=host.com#MyAnytls',
      );
      expect(nodes.length, 1);
      expect(nodes[0].protocol, 'anytls');
      expect(nodes[0].name, 'MyAnytls');
    });

    test('parses mixed protocol content', () {
      final content = '''
vmess://eyJhZGQiOiIxLjIuMy40IiwiYWlkIjoiMCIsImhvc3QiOiIiLCJpZCI6InV1aWQtdGVzdCIsIm5ldCI6InRjcCIsInBhdGgiOiIiLCJwb3J0IjoiNDQzIiwicHMiOiJWbWVzc05vZGUiLCJzY3kiOiJhdXRvIiwic25pIjoiIiwidGxzIjoiIiwidHlwZSI6IiIsInYiOiIyIn0=
anytls://pass@anytls.example.com:443/?sni=anytls.example.com#AnyTLSNode
''';
      final nodes = ServerNode.parseFromContent(content);
      // Should have at least the anytls node
      final anytlsNodes = nodes.where((n) => n.protocol == 'anytls').toList();
      expect(anytlsNodes.length, 1);
      expect(anytlsNodes[0].name, 'AnyTLSNode');
      expect(anytlsNodes[0].address, 'anytls.example.com');
    });
  });

  group('ServerNode._isUrl with anytls', () {
    test('recognizes anytls:// as valid URL scheme', () {
      final nodes = ServerNode.parseFromContent(
        'anytls://test@server:443/?sni=sni.test',
      );
      expect(nodes, isNotEmpty);
    });
  });

  group('ServerNode.fromClashConfig with anytls', () {
    test('parses Clash-style anytls proxy config', () {
      final config = {
        'name': 'AnytlsClash',
        'type': 'anytls',
        'server': '10.0.0.1',
        'port': 443,
        'password': 'clashpass',
        'sni': 'clash.example.com',
        'skip-cert-verify': false,
      };
      final node = ServerNode.fromClashConfig(config);
      expect(node.protocol, 'anytls');
      expect(node.name, 'AnytlsClash');
      expect(node.address, '10.0.0.1');
      expect(node.port, 443);
      expect(node.rawConfig?['password'], 'clashpass');
      expect(node.rawConfig?['sni'], 'clash.example.com');
    });
  });
}
