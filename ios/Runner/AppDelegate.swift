import AVFoundation
import CallKit
import Flutter
import PushKit
import UIKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate {
  /// PushKit: a ride call to a closed app arrives as a VoIP push and rings
  /// CallKit (lib/src/data/call_ringer.dart, migration 0134).
  private var voipRegistry: PKPushRegistry?

  /// An engine started only when a VoIP push wakes the app before any
  /// scene, and so before the implicit engine and its plugins, exists.
  private var voipEngine: FlutterEngine?

  /// Where flutter_callkit_incoming keeps the VoIP token (read by
  /// getDevicePushTokenVoIP), for a token that arrives before the plugin.
  private static let voipTokenKey = "DevicePushTokenVoIP"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let registry = PKPushRegistry(queue: DispatchQueue.main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MicStatusPlugin") {
      MicStatusPlugin.register(with: registrar)
    }
  }

  // MARK: PushKit

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    if let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance {
      plugin.setDevicePushTokenVoIP(token)
    } else {
      UserDefaults.standard.set(token, forKey: Self.voipTokenKey)
    }
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    if let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance {
      plugin.setDevicePushTokenVoIP("")
    } else {
      UserDefaults.standard.set("", forKey: Self.voipTokenKey)
    }
  }

  /// iOS requires every VoIP push to be reported to CallKit at once, or it
  /// stops waking the app: the call rings through the plugin, and if the
  /// plugin can't be reached it is still reported (and ended) here.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    if SwiftFlutterCallkitIncomingPlugin.sharedInstance == nil {
      startVoipEngine()
    }
    let args = payload.dictionaryPayload as NSDictionary
    guard let plugin = SwiftFlutterCallkitIncomingPlugin.sharedInstance else {
      FallbackCallReporter.shared.reportAndEnd(args, completion: completion)
      return
    }
    plugin.showCallkitIncoming(flutter_callkit_incoming.Data(args: args), fromPushKit: true) {
      completion()
    }
  }

  private func startVoipEngine() {
    guard voipEngine == nil else { return }
    let engine = FlutterEngine(name: "voip", project: nil, allowHeadlessExecution: true)
    guard engine.run() else { return }
    GeneratedPluginRegistrant.register(with: engine)
    voipEngine = engine
  }
}

/// The microphone permission as iOS keeps it (lib/src/features/support/call/
/// mic_gate.dart): `status` answers granted / denied / undetermined, and
/// `request` shows the system's question. iOS lists Microphone in the app's
/// Settings only once it has been asked, so "never asked" must be told apart
/// from "refused". Kept in this file so it needs no change to the Xcode
/// project.
final class MicStatusPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "get_ride/mic", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MicStatusPlugin(), channel: channel)
  }

  private func status() -> String {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return "granted"
      case .denied: return "denied"
      case .undetermined: return "undetermined"
      @unknown default: return "unknown"
      }
    }
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted: return "granted"
    case .denied: return "denied"
    case .undetermined: return "undetermined"
    @unknown default: return "unknown"
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(status())
    case "request":
      let done: (Bool) -> Void = { granted in DispatchQueue.main.async { result(granted) } }
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission(completionHandler: done)
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission(done)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// The last resort for a VoIP push the plugin couldn't take: report it so
/// iOS keeps delivering them, then end it straight away.
final class FallbackCallReporter: NSObject, CXProviderDelegate {
  static let shared = FallbackCallReporter()
  private let provider: CXProvider

  private override init() {
    let config = CXProviderConfiguration()
    config.supportsVideo = false
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  func reportAndEnd(_ args: NSDictionary, completion: @escaping () -> Void) {
    let uuid = UUID(uuidString: args["id"] as? String ?? "") ?? UUID()
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: args["nameCaller"] as? String ?? "GET.ride")
    update.hasVideo = false
    provider.reportNewIncomingCall(with: uuid, update: update) { _ in
      self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
      completion()
    }
  }

  func providerDidReset(_ provider: CXProvider) {}
}
