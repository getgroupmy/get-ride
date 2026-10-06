import ExternalAccessory
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MfiObdPlugin") {
      MfiObdPlugin.register(with: registrar)
    }
  }
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
  private var pending = Data()

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
      pending.append(Data(text.utf8))
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
