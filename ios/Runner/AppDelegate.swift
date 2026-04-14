import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    
    // ── V2Ray Method Channel ──
    let vpnChannel = FlutterMethodChannel(name: "com.example.flux/v2ray", binaryMessenger: controller.binaryMessenger)
    vpnChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
        switch call.method {
        case "connect":
            if let args = call.arguments as? [String: Any],
               let config = args["config"] as? String {
                VPNManager.shared.connect(config: config, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing config", details: nil))
            }
        case "disconnect":
            VPNManager.shared.disconnect(result: result)
        case "isConnected":
            result(VPNManager.shared.isConnected())
        default:
            result(FlutterMethodNotImplemented)
        }
    })
      
    // V2Ray Event Channel
    let statusChannel = FlutterEventChannel(name: "com.example.flux/v2ray_status", binaryMessenger: controller.binaryMessenger)
    statusChannel.setStreamHandler(VPNStatusStreamHandler())

    // ── sing-box Method Channel (for AnyTLS and other sing-box protocols) ──
    let singboxChannel = FlutterMethodChannel(name: "com.example.flux/singbox", binaryMessenger: controller.binaryMessenger)
    singboxChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
        switch call.method {
        case "connect":
            if let args = call.arguments as? [String: Any],
               let config = args["config"] as? String {
                SingboxManager.shared.connect(config: config, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing config", details: nil))
            }
        case "disconnect":
            SingboxManager.shared.disconnect(result: result)
        case "isConnected":
            result(SingboxManager.shared.isConnected())
        default:
            result(FlutterMethodNotImplemented)
        }
    })

    // sing-box Event Channel
    let singboxStatusChannel = FlutterEventChannel(name: "com.example.flux/singbox_status", binaryMessenger: controller.binaryMessenger)
    singboxStatusChannel.setStreamHandler(SingboxStatusStreamHandler())

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
