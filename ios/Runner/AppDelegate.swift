import AVFoundation
import CallKit
import CoreBluetooth
import CoreLocation
import CoreTelephony
import Flutter
import Network
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
    provideGoogleMapsKey()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Google's own map (Admin → Settings → Maps, "Google Maps (native)"): the
  /// Maps SDK for iOS key the release build put in Info.plist (GMSApiKey,
  /// from the GOOGLE_MAPS_IOS_API_KEY secret). Handed over by name so the
  /// app builds the same with or without the SDK linked; without a key the
  /// app never shows Google's map (GOOGLE_MAPS_NATIVE is not set).
  private func provideGoogleMapsKey() {
    guard let key = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String,
      !key.isEmpty, !key.hasPrefix("$("),
      let services = NSClassFromString("GMSServices") as? NSObject.Type
    else { return }
    _ = services.perform(NSSelectorFromString("provideAPIKey:"), with: key)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MicStatusPlugin") {
      MicStatusPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PermissionsPlugin") {
      PermissionsPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppIconPlugin") {
      AppIconPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NetworkInfoPlugin") {
      NetworkInfoPlugin.register(with: registrar)
    }
  }

  // MARK: PushKit

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    // Kept where getDevicePushTokenVoIP reads it whether or not the plugin
    // is up yet; the plugin also tells the app, which stores it at once.
    UserDefaults.standard.set(token, forKey: Self.voipTokenKey)
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
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

/// The home-screen icon (lib/src/core/app_icons.dart): `current` names it,
/// `set` changes it. Each icon but the standard one is an AppIcon-<id> icon
/// set (scripts/seasonal_icons.py), listed as the target's alternate icons.
/// iOS says the icon changed in an alert of its own, and only changes it
/// while the app is on screen.
final class AppIconPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "get_ride/app_icon", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(AppIconPlugin(), channel: channel)
  }

  private static let prefix = "AppIcon-"

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let app = UIApplication.shared
    switch call.method {
    case "current":
      result(app.alternateIconName.map { String($0.dropFirst(AppIconPlugin.prefix.count)) } ?? "standard")
    case "set":
      guard let id = (call.arguments as? [String: Any])?["id"] as? String else {
        result(FlutterError(code: "bad_args", message: "No icon id", details: nil))
        return
      }
      let name: String? = id == "standard" ? nil : AppIconPlugin.prefix + id
      guard app.supportsAlternateIcons else {
        result(FlutterError(code: "unsupported", message: "No alternate icons", details: nil))
        return
      }
      if app.alternateIconName == name {
        result(nil)
        return
      }
      guard app.applicationState == .active else {
        result(FlutterError(code: "not_active", message: "The app is not on screen", details: nil))
        return
      }
      app.setAlternateIconName(name) { error in
        DispatchQueue.main.async {
          if let error = error {
            result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Where the app's permissions stand, for Settings → Permissions and the
/// driver's go-online check (lib/src/data/permission_probe.dart):
/// `statuses` answers camera, Bluetooth and location without asking, and
/// `requestLocationAlways` asks iOS to change "While Using" to "Always"
/// (which it shows at most once; after that only Settings can).
final class PermissionsPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  private let location = CLLocationManager()
  private var pending: FlutterResult?
  private var asked = CLAuthorizationStatus.notDetermined
  private var prompted = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "get_ride/permissions", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PermissionsPlugin(), channel: channel)
  }

  private static func camera() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return "granted"
    case .denied, .restricted: return "denied"
    case .notDetermined: return "undetermined"
    @unknown default: return "unknown"
    }
  }

  private static func bluetooth() -> String {
    switch CBManager.authorization {
    case .allowedAlways: return "granted"
    case .denied, .restricted: return "denied"
    case .notDetermined: return "undetermined"
    @unknown default: return "unknown"
    }
  }

  private func locationStatus() -> String {
    switch location.authorizationStatus {
    case .authorizedAlways: return "always"
    case .authorizedWhenInUse: return "whileInUse"
    case .denied, .restricted: return "denied"
    case .notDetermined: return "undetermined"
    @unknown default: return "unknown"
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "statuses":
      result(["camera": Self.camera(), "bluetooth": Self.bluetooth(), "location": locationStatus()])
    case "requestLocationAlways":
      requestAlways(result)
    case "openNotificationSettings":
      // The app's Notifications page where iOS has one (16+), else its page.
      var link = UIApplication.openSettingsURLString
      if #available(iOS 16.0, *) { link = UIApplication.openNotificationSettingsURLString }
      guard let url = URL(string: link) else {
        result(false)
        return
      }
      UIApplication.shared.open(url) { opened in result(opened) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Answers once iOS has: the status changed, or the prompt was shown and
  /// the app is back, or (no prompt at all) after a moment.
  private func requestAlways(_ result: @escaping FlutterResult) {
    if pending != nil {
      result(locationStatus())
      return
    }
    pending = result
    asked = location.authorizationStatus
    prompted = false
    location.delegate = self
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(resigned), name: UIApplication.willResignActiveNotification, object: nil)
    center.addObserver(self, selector: #selector(returned), name: UIApplication.didBecomeActiveNotification, object: nil)
    location.requestAlwaysAuthorization()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      if self?.prompted == false { self?.finish() }
    }
  }

  @objc private func resigned() { prompted = true }

  @objc private func returned() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.finish() }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if pending != nil && manager.authorizationStatus != asked { finish() }
  }

  private func finish() {
    guard let result = pending else { return }
    pending = nil
    NotificationCenter.default.removeObserver(self)
    result(locationStatus())
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

/// The connection and SIM for the session rows Admin → Session History shows
/// (lib/src/data/device_details.dart): the path type from NWPathMonitor and
/// the radio technology from CoreTelephony. Nothing here needs a permission
/// or asks the user anything; iOS 16+ answers placeholders for the carrier,
/// which the app leaves out.
final class NetworkInfoPlugin: NSObject, FlutterPlugin {
  private let monitor = NWPathMonitor()
  private var path: NWPath?

  override init() {
    super.init()
    monitor.pathUpdateHandler = { [weak self] p in self?.path = p }
    monitor.start(queue: DispatchQueue(label: "get_ride.network"))
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "get_ride/network", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(NetworkInfoPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "info" else {
      result(FlutterMethodNotImplemented)
      return
    }
    var out: [String: Any] = [:]
    let p = path ?? monitor.currentPath
    let up = p.status == .satisfied
    out["connected"] = up
    out["internet"] = up
    out["type"] = !up ? "none"
      : p.usesInterfaceType(.wifi) ? "wifi"
      : p.usesInterfaceType(.cellular) ? "cellular"
      : p.usesInterfaceType(.wiredEthernet) ? "ethernet"
      : "other"
    out["metered"] = p.isExpensive
    let info = CTTelephonyNetworkInfo()
    if let radio = info.serviceCurrentRadioAccessTechnology?.values.first {
      out["radio"] = radio
    }
    if let carriers = info.serviceSubscriberCellularProviders {
      out["simSlots"] = carriers.count
      if let c = carriers.values.first(where: { $0.mobileCountryCode != nil }) ?? carriers.values.first {
        out["carrierName"] = c.carrierName
        out["mcc"] = c.mobileCountryCode
        out["mnc"] = c.mobileNetworkCode
        out["simCountry"] = c.isoCountryCode
      }
    }
    result(out)
  }
}
