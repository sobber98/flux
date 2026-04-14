package com.example.flux

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.BufferedReader
import java.io.InputStreamReader
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.flux/v2ray"
    private val STATUS_CHANNEL = "com.example.flux/v2ray_status"
    private val SINGBOX_CHANNEL = "com.example.flux/singbox"
    private val SINGBOX_STATUS_CHANNEL = "com.example.flux/singbox_status"
    private var isV2rayRunning = false
    private var xrayProcess: Process? = null
    private var currentProtocol: String = ""
    private var isInitialized = false
    private var isGeoDataReady = false

    // Pending sing-box config while waiting for VPN permission
    private var pendingSingboxConfig: String? = null
    
    companion object {
        private const val TAG = "Flux"
        private const val REQUEST_VPN_PERMISSION = 1
        private const val REQUEST_SINGBOX_VPN_PERMISSION = 2
        @Volatile
        private var vpnStatusSink: EventChannel.EventSink? = null
        @Volatile
        private var singboxStatusSink: EventChannel.EventSink? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        @JvmStatic
        fun emitVpnStatus(isConnected: Boolean) {
            mainHandler.post {
                vpnStatusSink?.success(isConnected)
            }
        }

        @JvmStatic
        fun emitSingboxStatus(isConnected: Boolean) {
            mainHandler.post {
                singboxStatusSink?.success(isConnected)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "connect" -> {
                    val configJson = call.argument<String>("config")
                    if (configJson == null) {
                        result.error("INVALID_ARGUMENT", "Config is null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val success = connectV2ray(configJson)
                            mainHandler.post { result.success(success) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("CONNECTION_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                "disconnect" -> {
                    Thread {
                        try {
                            disconnectV2ray()
                            mainHandler.post { result.success(true) }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("DISCONNECT_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                "isConnected" -> {
                    result.success(FluxVpnService.isVpnRunning)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STATUS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    vpnStatusSink = events
                    events?.success(FluxVpnService.isVpnRunning)
                }

                override fun onCancel(arguments: Any?) {
                    vpnStatusSink = null
                }
            })

        // ── sing-box MethodChannel (for AnyTLS and other sing-box protocols) ──
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SINGBOX_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connect" -> {
                        val configJson = call.argument<String>("config")
                        if (configJson == null) {
                            result.error("INVALID_ARGUMENT", "Config is null", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val success = connectSingbox(configJson)
                                mainHandler.post { result.success(success) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("SINGBOX_ERROR", e.message, null)
                                }
                            }
                        }.start()
                    }
                    "disconnect" -> {
                        Thread {
                            try {
                                disconnectSingbox()
                                mainHandler.post { result.success(true) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("SINGBOX_ERROR", e.message, null)
                                }
                            }
                        }.start()
                    }
                    "isConnected" -> {
                        result.success(SingboxVpnService.isRunning)
                    }
                    else -> result.notImplemented()
                }
            }

        // sing-box status EventChannel
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SINGBOX_STATUS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    singboxStatusSink = events
                    events?.success(SingboxVpnService.isRunning)
                }

                override fun onCancel(arguments: Any?) {
                    singboxStatusSink = null
                }
            })
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        splashScreen.setKeepOnScreenCondition { false }
        window.setBackgroundDrawableResource(android.R.color.black)
        
        super.onCreate(savedInstanceState)

        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_FULLSCREEN
        )
        
        window.statusBarColor = android.graphics.Color.BLACK
        window.navigationBarColor = android.graphics.Color.BLACK
    }

    override fun onDestroy() {
        super.onDestroy()
        disconnectV2ray()
        disconnectSingbox()
    }

    /**
     * 获取 Xray 可执行文件路径
     * 1. 尝试从 nativeLibraryDir 获取 (libxray.so)
     * 2. 如果失败，尝试从 Assets 复制到 filesDir 并赋予执行权限
     */
    private fun getXrayExecutable(): String? {
        // 1. 尝试从 nativeLibraryDir 查找
        val libDir = applicationInfo.nativeLibraryDir
        val libFile = File(libDir, "libxray.so")
        if (libFile.exists()) {
            Log.d(TAG, "Found Xray in nativeLibraryDir: ${libFile.absolutePath}")
            return libFile.absolutePath
        }

        // 2. 尝试查找含有 xray 的文件 (针对 weird naming)
        val dir = File(libDir)
        val files = dir.listFiles { _, name -> name.contains("xray") }
        if (files != null && files.isNotEmpty()) {
            Log.d(TAG, "Found Xray (fuzzy) in nativeLibraryDir: ${files[0].absolutePath}")
            return files[0].absolutePath
        }

        // 3. 都没有，尝试从 Assets 复制到 filesDir
        Log.w(TAG, "Xray not found in nativeLibraryDir, trying to copy from assets...")
        val internalBin = File(filesDir, "libxray.so")
        
        // 尝试从 assets 复制 "libxray.so" (Flutter assets mapping needed? No, binary stays in Android assets/libs)
        // 注意：这里需要确保 binary 确实在 android assets 里。
        // 由于用户说 assets/bin 是 Flutter assets，所以 binary 必须通过 nativeLibraryDir 找到最稳。
        // 这里保留 fallback 逻辑，假设用户手动放了 assets
        if (copyBinaryFromAssets("libxray.so", internalBin)) {
             return internalBin.absolutePath
        }
        
        if (copyBinaryFromAssets("xray-android-arm64-v8a", internalBin)) {
             return internalBin.absolutePath
        }

        Log.e(TAG, "Xray binary not found in libs or assets!")
        return null
    }

    private fun copyBinaryFromAssets(assetName: String, targetFile: File): Boolean {
        try {
            assets.open(assetName).use { input ->
                FileOutputStream(targetFile).use { output ->
                    input.copyTo(output)
                }
            }
            if (!targetFile.setExecutable(true, true)) {
                Runtime.getRuntime().exec("chmod 700 ${targetFile.absolutePath}").waitFor()
            }
            return true
        } catch (e: Exception) {
            return false
        }
    }

    private fun connectV2ray(configJson: String): Boolean {
        return try {
            if (isV2rayRunning) {
                disconnectV2ray()
                Thread.sleep(500)
            }

            val fullConfigObj = JSONObject(configJson)
            
            // 兼容旧逻辑：如果直接传的是 Outbound Config (没有 inbound/outbound 包装)，则当作 old style
            val outboundConfig = if (fullConfigObj.has("outbound")) {
                fullConfigObj.getJSONObject("outbound")
            } else {
                fullConfigObj
            }
            
            val routingMode = fullConfigObj.optString("routingMode", "rule")
            val routingRules = fullConfigObj.optJSONArray("routingRules")

            val protocol = outboundConfig.optString("protocol", "")
            currentProtocol = protocol
            
            Log.d(TAG, "Connecting protocol: $protocol, Mode: $routingMode")
            
            return connectXray(outboundConfig, routingMode, routingRules)

        } catch (e: Exception) {
            Log.e(TAG, "Error connecting: ${e.message}")
            e.printStackTrace()
            false
        }
    }
    
    // Old Hysteria2 methods removed (unified into Xray)
    
    /**
     * 使用 Xray 连接（非 Hysteria2 协议）
     */
    private fun connectXray(outboundConfig: JSONObject, routingMode: String, customRules: org.json.JSONArray?): Boolean {
        // 1. 获取可执行文件
        val executablePath = getXrayExecutable()
        if (executablePath == null) {
            Log.e(TAG, "Xray binary not found!")
            return false
        }

        // 2. 生成配置文件
        val configDir = filesDir.absolutePath
        val configFile = File(configDir, "config.json")
        val fullConfig = buildV2rayConfig(outboundConfig, routingMode, customRules)
        
        // 写入配置文件
        FileOutputStream(configFile).use { 
            it.write(fullConfig.toByteArray()) 
        }

        // 3. 启动进程
        Log.d(TAG, "Starting Xray process: $executablePath -c ${configFile.absolutePath}")
        val pb = ProcessBuilder(executablePath, "-c", configFile.absolutePath)
        pb.directory(filesDir)
        // 设置环境变量指向 dat 目录
        val env = pb.environment()
        env["xray.location.asset"] = configDir
        
        xrayProcess = pb.start()
        
        // 4. 读取日志（可选，防止 buffer 满）
        Thread {
            try {
                val reader = BufferedReader(InputStreamReader(xrayProcess!!.inputStream))
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    Log.d("XrayCore", line ?: "")
                }
            } catch (e: Exception) {
                // Ignore exceptions when process is destroyed
                Log.d("XrayCore", "Process output stream closed")
            }
        }.start()
        
        Thread {
            try {
                val reader = BufferedReader(InputStreamReader(xrayProcess!!.errorStream))
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    Log.e("XrayCore", line ?: "")
                }
            } catch (e: Exception) {
                // Ignore exceptions when process is destroyed
                 Log.d("XrayCore", "Process error stream closed")
            }
        }.start()

        // 等待启动
        Thread.sleep(500)
        
        if (xrayProcess!!.isAlive) {
            isV2rayRunning = true
            requestVpnPermission()
            return true
        } else {
            Log.e(TAG, "Xray process died immediately")
            return false
        }
    }

    private fun disconnectV2ray() {
        try {
            stopVpnService()
            
            // 停止 Xray 进程
            if (xrayProcess != null) {
                xrayProcess!!.destroy()
                xrayProcess = null
            }
            

            
            isV2rayRunning = false
            currentProtocol = ""
        } catch (e: Exception) {
            Log.e(TAG, "Error disconnecting: ${e.message}")
        }
    }

    private fun requestVpnPermission() {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            startActivityForResult(intent, REQUEST_VPN_PERMISSION)
        } else {
            startVpnService()
        }
    }
    
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == RESULT_OK) {
            when (requestCode) {
                REQUEST_VPN_PERMISSION -> startVpnService()
                REQUEST_SINGBOX_VPN_PERMISSION -> {
                    val config = pendingSingboxConfig
                    pendingSingboxConfig = null
                    if (config != null) {
                        startSingboxVpnService(config)
                    }
                }
            }
        }
    }
    
    private fun startVpnService() {
        try {
            val intent = Intent(this, FluxVpnService::class.java).apply {
                action = FluxVpnService.ACTION_START
            }
            startService(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Error starting VPN service: ${e.message}")
        }
    }
    
    private fun stopVpnService() {
        try {
            val intent = Intent(this, FluxVpnService::class.java).apply {
                action = FluxVpnService.ACTION_STOP
            }
            startService(intent)
            stopService(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping VPN service: ${e.message}")
        }
    }

    // ── sing-box engine methods ──────────────────────────────────────────

    private fun connectSingbox(configJson: String): Boolean {
        // Stop any running V2Ray connection first (only one VPN can be active)
        if (isV2rayRunning) {
            Log.d(TAG, "Stopping V2Ray before starting sing-box")
            disconnectV2ray()
            Thread.sleep(500)
        }
        // Also stop any existing sing-box connection
        if (SingboxVpnService.isRunning) {
            disconnectSingbox()
            Thread.sleep(300)
        }

        // Request VPN permission if needed
        val vpnIntent = VpnService.prepare(this)
        if (vpnIntent != null) {
            pendingSingboxConfig = configJson
            startActivityForResult(vpnIntent, REQUEST_SINGBOX_VPN_PERMISSION)
            return true // Permission will be granted asynchronously
        }

        startSingboxVpnService(configJson)
        return true
    }

    private fun startSingboxVpnService(configJson: String) {
        try {
            val intent = Intent(this, SingboxVpnService::class.java).apply {
                action = SingboxVpnService.ACTION_START
                putExtra(SingboxVpnService.EXTRA_CONFIG, configJson)
            }
            startService(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Error starting sing-box VPN service: ${e.message}")
        }
    }

    private fun disconnectSingbox() {
        try {
            val intent = Intent(this, SingboxVpnService::class.java).apply {
                action = SingboxVpnService.ACTION_STOP
            }
            startService(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping sing-box: ${e.message}")
        }
    }

    private fun buildV2rayConfig(outbound: JSONObject, routingMode: String, customRules: org.json.JSONArray?): String {
        val config = JSONObject()
        ensureStreamSettings(outbound)
        
        // 1. Log
        val log = JSONObject().put("loglevel", "warning")
        config.put("log", log)
        
        // 2. Stats
        config.put("stats", JSONObject())
        
        // 3. Policy
        val policy = JSONObject()
        val levels = JSONObject().put("0", JSONObject()
            .put("handshake", 4)
            .put("connIdle", 300)
            .put("uplinkOnly", 2)
            .put("downlinkOnly", 5)
            .put("statsUserUplink", true)
            .put("statsUserDownlink", true)
            .put("bufferSize", 4)
        )
        val system = JSONObject()
            .put("statsInboundUplink", true)
            .put("statsInboundDownlink", true)
            .put("statsOutboundUplink", true)
            .put("statsOutboundDownlink", true)
        policy.put("levels", levels)
        policy.put("system", system)
        config.put("policy", policy)
        
        // 4. DNS
        val dns = JSONObject()
        dns.put("queryStrategy", "UseIPv4")
        val dnsServers = org.json.JSONArray()
        
        // Domestic DNS
        val domesticDns = JSONObject()
        domesticDns.put("address", "223.5.5.5")
        
        val domesticDomains = org.json.JSONArray()
        domesticDomains.put("geosite:cn")
        
        // Add Server Address to Domestic DNS
        val settings = outbound.optJSONObject("settings")
        if (settings != null && settings.has("address")) {
            val serverAddress = settings.getString("address")
            if (serverAddress.isNotEmpty()) {
                domesticDomains.put(serverAddress)
            }
        }
        
        domesticDns.put("domains", domesticDomains)
        domesticDns.put("expectIPs", org.json.JSONArray().put("geoip:cn"))
        dnsServers.put(domesticDns)

        // Foreign DNS
        dnsServers.put("8.8.8.8")
        dnsServers.put("1.1.1.1")
        dnsServers.put("localhost")
        
        dns.put("servers", dnsServers)
        config.put("dns", dns)
        
        // 5. Inbounds
        val inbounds = org.json.JSONArray()
        val socksInbound = JSONObject()
        socksInbound.put("tag", "socks")
        socksInbound.put("port", 10808)
        socksInbound.put("listen", "127.0.0.1")
        socksInbound.put("protocol", "socks")
        socksInbound.put("settings", JSONObject().put("auth", "noauth").put("udp", true))
        socksInbound.put("sniffing", JSONObject().put("enabled", true)
            .put("destOverride", org.json.JSONArray().put("http").put("tls").put("quic")))
        inbounds.put(socksInbound)
        
        val httpInbound = JSONObject()
        httpInbound.put("tag", "http")
        httpInbound.put("port", 10809)
        httpInbound.put("listen", "127.0.0.1")
        httpInbound.put("protocol", "http")
        httpInbound.put("sniffing", JSONObject().put("enabled", true)
            .put("destOverride", org.json.JSONArray().put("http").put("tls").put("quic")))
        inbounds.put(httpInbound)
        
        config.put("inbounds", inbounds)
        
        // 6. Routing
        val routing = JSONObject()
        routing.put("domainStrategy", "IPIfNonMatch")
        val rules = org.json.JSONArray()
        
        // 6.1 Bootstrap Direct
        if (settings != null && settings.has("address")) {
            val serverAddress = settings.getString("address")
            if (serverAddress.isNotEmpty()) {
                rules.put(JSONObject().put("type", "field").put("outboundTag", "direct").put("domain", org.json.JSONArray().put(serverAddress)))
            }
        }
        
        // 6.2 DNS Loop Break
        rules.put(JSONObject().put("type", "field").put("outboundTag", "direct").put("ip", org.json.JSONArray().put("8.8.8.8").put("1.1.1.1")))
        
        // 6.3 Mode Handling
        if (routingMode == "global") {
            // Global Mode: Only bypass private/LAN
             rules.put(JSONObject().put("type", "field").put("outboundTag", "direct").put("ip", org.json.JSONArray().put("geoip:private")))
             rules.put(JSONObject().put("type", "field").put("outboundTag", "direct").put("domain", org.json.JSONArray().put("geosite:private")))
        } else {
            // Rule Mode
            var hasCustomRules = false
            if (customRules != null && customRules.length() > 0) {
                 Log.d(TAG, "Applying ${customRules.length()} custom routing rules")
                 for (i in 0 until customRules.length()) {
                     rules.put(customRules.getJSONObject(i))
                 }
                 hasCustomRules = true
            }
            
            // Fallback default rules if no custom rules provided
            if (!hasCustomRules) {
                Log.d(TAG, "Applying default routing rules")
                 rules.put(JSONObject().put("type", "field").put("outboundTag", "direct").put("ip", org.json.JSONArray().put("geoip:private")))
                 rules.put(JSONObject().put("type", "field").put("outboundTag", "direct").put("domain", org.json.JSONArray().put("geosite:private")))
                 
                val geoip = File(filesDir, "geoip.dat")
                if (geoip.exists()) {
                    rules.put(JSONObject().put("type", "field").put("outboundTag", "direct").put("domain", org.json.JSONArray().put("geosite:cn")))
                    rules.put(JSONObject().put("type", "field").put("outboundTag", "direct").put("ip", org.json.JSONArray().put("geoip:cn")))
                }
            }
        }

        // Final Catch-all Proxy
        rules.put(JSONObject().put("type", "field").put("outboundTag", "proxy").put("network", "tcp,udp"))
        
        routing.put("rules", rules)
        config.put("routing", routing)
        
        // 7. Outbounds
        val outbounds = org.json.JSONArray()
        if (!outbound.has("tag")) outbound.put("tag", "proxy")
        outbounds.put(outbound)
        
        outbounds.put(JSONObject().put("protocol", "freedom").put("tag", "direct").put("settings", JSONObject().put("domainStrategy", "UseIP")))
        outbounds.put(JSONObject().put("protocol", "blackhole").put("tag", "block"))
        
        config.put("outbounds", outbounds)
        
        return config.toString()
    }
    
    private fun ensureStreamSettings(outbound: JSONObject) {
        val protocol = outbound.optString("protocol", "")
        if (protocol == "trojan") {
            var streamSettings = outbound.optJSONObject("streamSettings")
            if (streamSettings == null) {
                streamSettings = JSONObject()
                outbound.put("streamSettings", streamSettings)
            }
            if (!streamSettings.has("security")) streamSettings.put("security", "tls")
            if (!streamSettings.has("network")) streamSettings.put("network", "tcp")
            if (!streamSettings.has("tlsSettings")) streamSettings.put("tlsSettings", JSONObject())
        }
    }
}
