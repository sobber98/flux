import NetworkExtension
import Libbox

// MARK: - ⚠️ IMPORTANT SETUP INSTRUCTIONS
// 1. Open project in Xcode (`ios/Runner.xcworkspace`)
// 2. File -> New -> Target -> Network Extension
// 3. Product Name: "PacketTunnel" (Language: Swift)
// 4. Finish. If asked to activate scheme, say "Cancel" or "Activate" (doesn't matter much).
// 5. Replace the content of the generated `PacketTunnelProvider.swift` (in the PacketTunnel folder) with this code.
// 6. ⚠️ Link BOTH LibXray.xcframework AND Libbox.xcframework to the PacketTunnel Target in "Frameworks and Libraries".
// 7. Enable "App Groups" capability for both Runner and PacketTunnel targets if you need to share files.

class PacketTunnelProvider: NEPacketTunnelProvider {

    // sing-box state
    private var boxService: LibboxBoxService?
    private var commandServer: LibboxCommandServer?
    private var platformInterface: FluxPlatformInterface?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let conf = self.protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = conf.providerConfiguration,
              let configStr = providerConfig["config"] as? String else {
            NSLog("[Flux] Missing VPN configuration")
            completionHandler(NSError(domain: "com.example.flux", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Missing config"]))
            return
        }

        let engine = providerConfig["engine"] as? String ?? "v2ray"
        NSLog("[Flux] Starting tunnel with engine: \(engine), config length: \(configStr.count)")

        if engine == "singbox" {
            startSingboxEngine(config: configStr, completionHandler: completionHandler)
        } else {
            startV2RayEngine(config: configStr, completionHandler: completionHandler)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        NSLog("[Flux] Stopping Tunnel, reason: \(reason)")

        // Stop sing-box if running
        if let service = boxService {
            do { try service.close() } catch {
                NSLog("[Flux] Error closing sing-box: \(error)")
            }
            boxService = nil
            commandServer?.setService(nil)
        }
        if let server = commandServer {
            do { try server.close() } catch {
                NSLog("[Flux] Error closing command server: \(error)")
            }
            commandServer = nil
        }
        platformInterface?.reset()
        platformInterface = nil

        // Stop V2Ray if running
        /*
         LibXray.shared.stop()
         */

        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(nil)
    }

    // MARK: - V2Ray Engine (existing stub)

    private func startV2RayEngine(config: String, completionHandler: @escaping (Error?) -> Void) {
        // Note: You need to import your V2Ray core library here (e.g. LibXray)
        /*
         LibXray.shared.start(config: configStr)
         */
        NSLog("[Flux] Starting V2Ray engine")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4Settings = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        settings.mtu = 1500

        self.setTunnelNetworkSettings(settings) { error in
            if let error = error {
                NSLog("[Flux] Failed to set V2Ray settings: \(error)")
                completionHandler(error)
            } else {
                NSLog("[Flux] V2Ray tunnel settings applied successfully")
                completionHandler(nil)
            }
        }
    }

    // MARK: - sing-box Engine

    private func startSingboxEngine(config: String, completionHandler: @escaping (Error?) -> Void) {
        NSLog("[Flux] Starting sing-box engine")

        // 1. Setup libbox paths
        let baseDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Bundle.main.bundleIdentifier! + ".group"
        )?.appendingPathComponent("singbox").path ?? NSTemporaryDirectory()

        let workDir = baseDir
        let tempDir = NSTemporaryDirectory().appending("/singbox")

        try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = baseDir
        setupOptions.workingPath = workDir
        setupOptions.tempPath = tempDir

        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let error = setupError {
            NSLog("[Flux] Libbox setup error: \(error)")
            completionHandler(error)
            return
        }

        // Limit memory usage in Network Extension (~15MB limit)
        LibboxSetMemoryLimit(true)

        // 2. Create platform interface
        let pi = FluxPlatformInterface(tunnel: self)
        platformInterface = pi

        // 3. Create and start command server
        let server = LibboxNewCommandServer(pi, 300)
        do {
            try server.start()
        } catch {
            NSLog("[Flux] Command server start error: \(error)")
            completionHandler(error)
            return
        }
        commandServer = server

        // 4. Create and start box service
        var serviceError: NSError?
        let service = LibboxNewService(config, pi, &serviceError)
        if let error = serviceError {
            NSLog("[Flux] Create service error: \(error)")
            completionHandler(error)
            return
        }
        guard let service = service else {
            completionHandler(NSError(domain: "com.example.flux", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "LibboxNewService returned nil"]))
            return
        }

        do {
            try service.start()
        } catch {
            NSLog("[Flux] Start service error: \(error)")
            completionHandler(error)
            return
        }

        server.setService(service)
        boxService = service
        NSLog("[Flux] sing-box started successfully")
        completionHandler(nil)
    }
}

// MARK: - Platform Interface for sing-box

class FluxPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private weak var tunnel: PacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?

    init(tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func reset() {
        networkSettings = nil
    }

    // MARK: - TUN

    public func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options = options, let ret0_ = ret0_, let tunnel = tunnel else {
            throw NSError(domain: "nil parameters", code: 0)
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            let dnsServer = try options.getDNSServerAddress()
            let dns = NEDNSSettings(servers: [dnsServer.value])
            dns.matchDomains = [""]
            dns.matchDomainsNoSearch = true
            settings.dnsSettings = dns

            // IPv4
            var ipv4Addrs: [String] = [], ipv4Masks: [String] = []
            let inet4Iter = options.getInet4Address()!
            while inet4Iter.hasNext() {
                let p = inet4Iter.next()!
                ipv4Addrs.append(p.address())
                ipv4Masks.append(p.mask())
            }
            let ipv4 = NEIPv4Settings(addresses: ipv4Addrs, subnetMasks: ipv4Masks)

            var routes: [NEIPv4Route] = []
            let routeIter = options.getInet4RouteAddress()!
            if routeIter.hasNext() {
                while routeIter.hasNext() {
                    let r = routeIter.next()!
                    routes.append(NEIPv4Route(destinationAddress: r.address(), subnetMask: r.mask()))
                }
            } else {
                routes.append(NEIPv4Route.default())
            }
            ipv4.includedRoutes = routes
            settings.ipv4Settings = ipv4

            // IPv6
            var ipv6Addrs: [String] = [], ipv6Prefixes: [NSNumber] = []
            let inet6Iter = options.getInet6Address()!
            while inet6Iter.hasNext() {
                let p = inet6Iter.next()!
                ipv6Addrs.append(p.address())
                ipv6Prefixes.append(NSNumber(value: p.prefix()))
            }
            if !ipv6Addrs.isEmpty {
                let ipv6 = NEIPv6Settings(addresses: ipv6Addrs, networkPrefixLengths: ipv6Prefixes)
                var ipv6Routes: [NEIPv6Route] = []
                let inet6RouteIter = options.getInet6RouteAddress()!
                if inet6RouteIter.hasNext() {
                    while inet6RouteIter.hasNext() {
                        let r = inet6RouteIter.next()!
                        ipv6Routes.append(NEIPv6Route(destinationAddress: r.address(),
                                                       networkPrefixLength: NSNumber(value: r.prefix())))
                    }
                } else {
                    ipv6Routes.append(NEIPv6Route.default())
                }
                ipv6.includedRoutes = ipv6Routes
                settings.ipv6Settings = ipv6
            }
        }

        networkSettings = settings

        // Apply settings synchronously using semaphore
        let semaphore = DispatchSemaphore(value: 0)
        var tunnelError: Error?
        tunnel.setTunnelNetworkSettings(settings) { error in
            tunnelError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let error = tunnelError {
            throw error
        }

        // Get TUN file descriptor
        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }

        let tunFd = LibboxGetTunnelFileDescriptor()
        if tunFd != -1 {
            ret0_.pointee = tunFd
        } else {
            throw NSError(domain: "missing TUN file descriptor", code: 0)
        }
    }

    // MARK: - Stubs

    public func usePlatformAutoDetectControl() -> Bool { false }
    public func autoDetectControl(_ fd: Int32) throws {}

    public func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?,
                                     sourcePort: Int32, destinationAddress: String?,
                                     destinationPort: Int32, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "not implemented", code: 0)
    }

    public func packageName(byUid uid: Int32, error: NSErrorPointer) -> String { "" }
    public func uid(byPackageName name: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "not implemented", code: 0)
    }

    public func useProcFS() -> Bool { false }

    public func writeLog(_ message: String?) {
        guard let message = message else { return }
        NSLog("[sing-box] \(message)")
    }

    public func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}
    public func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}
    public func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        // Return empty iterator
        return EmptyNetworkInterfaceIterator()
    }

    public func underNetworkExtension() -> Bool { true }
    public func includeAllNetworks() -> Bool { false }

    public func clearDNSCache() {
        guard let settings = networkSettings, let tunnel = tunnel else { return }
        tunnel.reasserting = true
        tunnel.setTunnelNetworkSettings(nil) { _ in }
        tunnel.setTunnelNetworkSettings(settings) { _ in }
        tunnel.reasserting = false
    }

    public func readWIFIState() -> LibboxWIFIState? { nil }

    // MARK: - CommandServerHandler

    public func serviceReload() throws {
        // Not needed for our simple use case
    }

    public func postServiceClose() {
        reset()
    }

    public func getSystemProxyStatus() -> LibboxSystemProxyStatus? {
        let status = LibboxSystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    public func setSystemProxyEnabled(_ isEnabled: Bool) throws {}

    public func send(_ notification: LibboxNotification?) throws {
        guard let n = notification else { return }
        NSLog("[sing-box] Notification: \(n.title) - \(n.body)")
    }
}

// MARK: - Helper: Empty network interface iterator

private class EmptyNetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    func hasNext() -> Bool { false }
    func next() -> LibboxNetworkInterface? { nil }
}

