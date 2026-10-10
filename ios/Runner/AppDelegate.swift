import CallKit
import ExternalAccessory
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MfiObdPlugin") {
      MfiObdPlugin.register(with: registrar)
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

/// Bluetooth MFi OBD-II readers (OBDLink MX+ &co.) through Apple's External
/// Accessory framework: the native half of lib/src/data/obd/obd_mfi_transport.dart.
/// Kept in this file so it needs no change to the Xcode project.
///
/// Methods on `get_ride/mfi`: `list` (the paired accessories speaking a
/// protocol declared in Info.plist), `connect` {id: connectionID},
/// `write` {text}, `disconnect`. Replies stream as text on `get_ride/mfi/data`.
final class MfiObdPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, StreamDelegate {
  private static let protocols =
    Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols") as? [String] ?? []

  private var session: EASession?
  private var sink: FlutterEventSink?
  private var pending = Foundation.Data()

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MfiObdPlugin()
    let methods = FlutterMethodChannel(name: "get_ride/mfi", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(name: "get_ride/mfi/data", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  private static func readerProtocol(_ accessory: EAAccessory) -> String? {
    accessory.protocolStrings.first { protocols.contains($0) }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "list":
      let list: [[String: Any]] = EAAccessoryManager.shared().connectedAccessories.compactMap { accessory in
        guard let proto = Self.readerProtocol(accessory) else { return nil }
        return [
          "id": String(accessory.connectionID),
          "name": accessory.name,
          "serial": accessory.serialNumber,
          "protocol": proto,
        ]
      }
      result(list)
    case "connect":
      close()
      guard
        let id = args?["id"] as? String,
        let accessory = EAAccessoryManager.shared().connectedAccessories.first(where: { String($0.connectionID) == id }),
        let proto = Self.readerProtocol(accessory),
        let opened = EASession(accessory: accessory, forProtocol: proto)
      else {
        result(FlutterError(
          code: "unavailable",
          message: "The reader is not connected to this iPhone. Pair it in Settings → Bluetooth and turn the ignition on.",
          details: nil))
        return
      }
      session = opened
      for stream in [opened.inputStream as Stream?, opened.outputStream as Stream?].compactMap({ $0 }) {
        stream.delegate = self
        stream.schedule(in: .main, forMode: .default)
        stream.open()
      }
      result(accessory.name)
    case "write":
      guard let text = args?["text"] as? String, let output = session?.outputStream else {
        result(FlutterError(code: "closed", message: "Not connected to the reader.", details: nil))
        return
      }
      pending.append(Foundation.Data(text.utf8))
      flush(output)
      result(nil)
    case "disconnect":
      close()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func flush(_ output: OutputStream) {
    while !pending.isEmpty && output.hasSpaceAvailable {
      let written = pending.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return output.write(base, maxLength: raw.count)
      }
      if written <= 0 { break }
      pending.removeFirst(written)
    }
  }

  func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    switch eventCode {
    case .hasBytesAvailable:
      guard let input = aStream as? InputStream else { return }
      var buffer = [UInt8](repeating: 0, count: 512)
      while input.hasBytesAvailable {
        let read = input.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        sink?(String(decoding: buffer[0..<read], as: UTF8.self))
      }
    case .hasSpaceAvailable:
      if let output = aStream as? OutputStream { flush(output) }
    case .errorOccurred, .endEncountered:
      close()
    default:
      break
    }
  }

  private func close() {
    for stream in [session?.inputStream as Stream?, session?.outputStream as Stream?].compactMap({ $0 }) {
      stream.delegate = nil
      stream.close()
      stream.remove(from: .main, forMode: .default)
    }
    session = nil
    pending.removeAll()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
