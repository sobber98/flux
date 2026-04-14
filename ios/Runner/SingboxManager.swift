import Foundation
import NetworkExtension
import Flutter

/// sing-box 管理器 — 专用于 AnyTLS 等需要 sing-box 内核的协议。
/// 通过 NETunnelProviderManager 传递 sing-box JSON 配置到 Network Extension，
/// 在 providerConfiguration 中标记 engine = "singbox" 来区分 V2Ray 流程。
class SingboxManager: NSObject {
    static let shared = SingboxManager()

    let extensionBundleId = Bundle.main.bundleIdentifier! + ".PacketTunnel"

    var manager: NETunnelProviderManager?
    var statusSink: FlutterEventSink?

    override init() {
        super.init()
        loadManager()
    }

    private func loadManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] (managers, error) in
            guard let self = self else { return }
            if let error = error {
                NSLog("[SingboxManager] Error loading managers: \(error)")
                return
            }

            if let managers = managers, !managers.isEmpty {
                self.manager = managers.first
            } else {
                self.manager = NETunnelProviderManager()
                self.manager?.localizedDescription = "Flux sing-box"
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = self.extensionBundleId
                proto.serverAddress = "Flux"
                self.manager?.protocolConfiguration = proto
                self.manager?.saveToPreferences { error in
                    if let error = error {
                        NSLog("[SingboxManager] Error saving manager: \(error)")
                    }
                }
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.statusDidChange(_:)),
                name: .NEVPNStatusDidChange,
                object: nil
            )
        }
    }

    /// Connect using sing-box engine with the given JSON config.
    func connect(config: String, result: @escaping FlutterResult) {
        guard let manager = self.manager else {
            loadManager()
            result(FlutterError(code: "MANAGER_NOT_READY", message: "Singbox manager not loaded", details: nil))
            return
        }

        // Stop any existing V2Ray VPN first (only one tunnel can be active)
        if VPNManager.shared.isConnected() {
            VPNManager.shared.manager?.connection.stopVPNTunnel()
            // Brief delay to ensure clean shutdown
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.startTunnel(manager: manager, config: config, result: result)
            }
        } else {
            startTunnel(manager: manager, config: config, result: result)
        }
    }

    private func startTunnel(manager: NETunnelProviderManager, config: String, result: @escaping FlutterResult) {
        manager.loadFromPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                result(FlutterError(code: "LOAD_ERROR", message: error.localizedDescription, details: nil))
                return
            }

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.extensionBundleId
            proto.serverAddress = "Flux sing-box"
            // Mark engine as singbox so PacketTunnelProvider knows which core to start
            proto.providerConfiguration = [
                "engine": "singbox",
                "config": config
            ]

            manager.protocolConfiguration = proto
            manager.isEnabled = true

            manager.saveToPreferences { error in
                if let error = error {
                    result(FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil))
                    return
                }

                do {
                    try manager.connection.startVPNTunnel(options: [:])
                    result(true)
                } catch {
                    result(FlutterError(code: "START_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    func disconnect(result: @escaping FlutterResult) {
        manager?.connection.stopVPNTunnel()
        result(true)
    }

    func isConnected() -> Bool {
        return manager?.connection.status == .connected
    }

    @objc func statusDidChange(_ notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }
        let isConnected = (connection.status == .connected)
        statusSink?(isConnected)
    }
}

// MARK: - EventChannel stream handler for sing-box status

class SingboxStatusStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        SingboxManager.shared.statusSink = events
        events(SingboxManager.shared.isConnected())
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        SingboxManager.shared.statusSink = nil
        return nil
    }
}
