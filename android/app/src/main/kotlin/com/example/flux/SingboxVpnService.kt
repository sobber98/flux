package com.example.flux

import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import io.nekohasekai.libbox.LocalDNSTransport
import java.io.File

/**
 * sing-box VPN 服务 — 专用于 AnyTLS 等需要 sing-box 内核的协议。
 *
 * 工作流程：
 *   Flutter → MethodChannel("com.example.flux/singbox") → MainActivity
 *   → Intent(ACTION_START, config) → SingboxVpnService
 *   → CommandServer + PlatformInterface → TUN VPN
 */
class SingboxVpnService : VpnService(), PlatformInterface, CommandServerHandler {

    companion object {
        private const val TAG = "SingboxVPN"
        const val ACTION_START = "com.example.flux.SINGBOX_START"
        const val ACTION_STOP = "com.example.flux.SINGBOX_STOP"
        const val EXTRA_CONFIG = "config"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var commandServer: CommandServer? = null
    private var fileDescriptor: ParcelFileDescriptor? = null
    private var pendingConfig: String? = null

    private val connectivity by lazy {
        getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private val defaultNetworkRequest by lazy {
        NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
    }
    private val defaultNetworkCallback by lazy {
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                setUnderlyingNetworks(arrayOf(network))
            }
            override fun onCapabilitiesChanged(network: Network, nc: NetworkCapabilities) {
                setUnderlyingNetworks(arrayOf(network))
            }
            override fun onLost(network: Network) {
                setUnderlyingNetworks(null)
            }
        }
    }

    // ── Lifecycle ────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "SingboxVpnService onCreate")
    }

    override fun onDestroy() {
        stopSingbox()
        super.onDestroy()
        Log.d(TAG, "SingboxVpnService onDestroy")
    }

    override fun onRevoke() {
        stopSingbox()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG)
                if (config.isNullOrEmpty()) {
                    Log.e(TAG, "No config provided")
                    stopSelf()
                    return START_NOT_STICKY
                }
                pendingConfig = config
                startSingbox(config)
            }
            ACTION_STOP -> {
                stopSingbox()
            }
        }
        return START_NOT_STICKY
    }

    // ── Start / Stop ─────────────────────────────────────────────────────

    private fun startSingbox(configJson: String) {
        if (isRunning) {
            Log.d(TAG, "Already running, stopping first")
            stopSingbox()
            Thread.sleep(300)
        }

        try {
            // Setup libbox working directory
            val baseDir = filesDir.absolutePath + "/singbox"
            val workDir = baseDir
            val tempDir = cacheDir.absolutePath + "/singbox"
            File(baseDir).mkdirs()
            File(tempDir).mkdirs()
            Libbox.setup(baseDir, workDir, tempDir, false)

            // Create and start command server
            val server = CommandServer(this, this)
            server.start()
            commandServer = server

            // Start the sing-box service with config
            server.startOrReloadService(configJson, OverrideOptions())

            isRunning = true
            MainActivity.emitSingboxStatus(true)
            Log.d(TAG, "sing-box started successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start sing-box", e)
            isRunning = false
            MainActivity.emitSingboxStatus(false)
            cleanupResources()
            stopSelf()
        }
    }

    private fun stopSingbox() {
        if (!isRunning && commandServer == null) return
        Log.d(TAG, "Stopping sing-box")

        try {
            isRunning = false
            MainActivity.emitSingboxStatus(false)

            // Unregister network callback
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                try {
                    connectivity.unregisterNetworkCallback(defaultNetworkCallback)
                } catch (_: Exception) {}
            }
            setUnderlyingNetworks(null)

            cleanupResources()
            stopSelf()
            Log.d(TAG, "sing-box stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping sing-box", e)
        }
    }

    private fun cleanupResources() {
        try {
            commandServer?.closeService()
        } catch (e: Exception) {
            Log.w(TAG, "closeService error: ${e.message}")
        }
        try {
            commandServer?.close()
        } catch (e: Exception) {
            Log.w(TAG, "close commandServer error: ${e.message}")
        }
        commandServer = null

        try {
            fileDescriptor?.close()
        } catch (_: Exception) {}
        fileDescriptor = null
    }

    // ── PlatformInterface ────────────────────────────────────────────────

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) {
            throw SecurityException("android: missing VPN permission")
        }

        val builder = Builder()
            .setSession("Flux sing-box")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        // IPv4 addresses from sing-box config
        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val addr = inet4Address.next()
            builder.addAddress(addr.address(), addr.prefix())
        }

        // IPv6 addresses
        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val addr = inet6Address.next()
            builder.addAddress(addr.address(), addr.prefix())
        }

        if (options.autoRoute) {
            builder.addDnsServer(options.dnsServerAddress.value)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4Route = options.inet4RouteAddress
                if (inet4Route.hasNext()) {
                    while (inet4Route.hasNext()) {
                        val r = inet4Route.next()
                        builder.addRoute(r.address(), r.prefix())
                    }
                } else if (options.inet4Address.hasNext()) {
                    builder.addRoute("0.0.0.0", 0)
                }

                val inet6Route = options.inet6RouteAddress
                if (inet6Route.hasNext()) {
                    while (inet6Route.hasNext()) {
                        val r = inet6Route.next()
                        builder.addRoute(r.address(), r.prefix())
                    }
                } else if (options.inet6Address.hasNext()) {
                    builder.addRoute("::", 0)
                }
            } else {
                val inet4Route = options.inet4RouteRange
                if (inet4Route.hasNext()) {
                    while (inet4Route.hasNext()) {
                        val r = inet4Route.next()
                        builder.addRoute(r.address(), r.prefix())
                    }
                }
                val inet6Route = options.inet6RouteRange
                if (inet6Route.hasNext()) {
                    while (inet6Route.hasNext()) {
                        val r = inet6Route.next()
                        builder.addRoute(r.address(), r.prefix())
                    }
                }
            }

            // Include/exclude apps from sing-box config
            val includePackage = options.includePackage
            if (includePackage.hasNext()) {
                while (includePackage.hasNext()) {
                    try {
                        builder.addAllowedApplication(includePackage.next())
                    } catch (_: NameNotFoundException) {}
                }
            }
            val excludePackage = options.excludePackage
            if (excludePackage.hasNext()) {
                while (excludePackage.hasNext()) {
                    try {
                        builder.addDisallowedApplication(excludePackage.next())
                    } catch (_: NameNotFoundException) {}
                }
            }
        }

        // Exclude self to prevent traffic loop
        try {
            builder.addDisallowedApplication(packageName)
        } catch (_: NameNotFoundException) {}

        // Bind to default network (Android P+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                connectivity.requestNetwork(defaultNetworkRequest, defaultNetworkCallback)
            } catch (e: Exception) {
                Log.w(TAG, "requestNetwork failed: ${e.message}")
            }
        }

        val pfd = builder.establish()
            ?: throw IllegalStateException("android: failed to establish VPN interface")

        fileDescriptor = pfd
        return pfd.fd
    }

    override fun writeLog(message: String) {
        Log.d(TAG, message)
    }

    override fun sendNotification(notification: Notification) {
        // Minimal notification handling — not needed for our use case
        Log.d(TAG, "Notification: ${notification.title} - ${notification.body}")
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun useProcFS(): Boolean = false

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int
    ): Int = -1

    override fun packageNameByUid(uid: Int): String {
        return packageManager.getNameForUid(uid) ?: ""
    }

    override fun uidByPackageName(packageName: String): Int {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                packageManager.getApplicationInfo(packageName, 0).uid
            } else {
                @Suppress("DEPRECATION")
                packageManager.getApplicationInfo(packageName, 0).uid
            }
        } catch (_: NameNotFoundException) {
            -1
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        // Simplified: no-op for now
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        // Simplified: no-op for now
    }

    override fun getInterfaces(): NetworkInterfaceIterator? = null

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {}

    override fun readWIFIState(): WIFIState? = null

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun systemCertificates(): StringIterator? = null

    // ── CommandServerHandler ─────────────────────────────────────────────

    override fun serviceStop() {
        stopSingbox()
    }

    override fun serviceReload() {
        val config = pendingConfig ?: return
        try {
            commandServer?.startOrReloadService(config, OverrideOptions())
        } catch (e: Exception) {
            Log.e(TAG, "serviceReload failed: ${e.message}")
        }
    }

    override fun getSystemProxyStatus(): SystemProxyStatus? {
        val status = SystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    override fun setSystemProxyEnabled(isEnabled: Boolean) {}

    override fun triggerNativeCrash() {
        throw RuntimeException("debug native crash")
    }

    override fun writeDebugMessage(message: String?) {
        Log.d(TAG, message ?: "")
    }
}
