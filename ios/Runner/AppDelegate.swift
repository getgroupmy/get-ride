import AVFoundation
import CallKit
import CoreBluetooth
import CoreLocation
import CoreTelephony
import Flutter
import MapKit
import Network
import PushKit
import UIKit
import UserNotifications
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
    // "Always on": a relaunch for a significant location change needs the
    // monitoring started again to be handed the fix.
    BackgroundLocationReporter.shared.resumeIfArmed()
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MapAppearancePlugin") {
      MapAppearancePlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NetworkInfoPlugin") {
      NetworkInfoPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackgroundLocationPlugin") {
      BackgroundLocationPlugin.register(with: registrar)
    }
    // The trip card's Live Activity (TripCardActivities.swift); below iOS
    // 16.2 every call answers false and the app carries on without a card.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TripCardPlugin") {
      TripCardPlugin.register(with: registrar)
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

  // MARK: Silent pushes

  /// "Still there?" (migration 0276): a `location_ping` background push asks
  /// an "Always on" phone for one fix, sent through the same report as the
  /// significant location changes, with no Flutter engine needed. Every
  /// other push is firebase_messaging's: with an implementation here,
  /// GoogleUtilities' app delegate proxy hands it to the plugin first and
  /// calls iOS's completion once both have answered, so this one only says
  /// it had nothing to do (calling super would hand it to the plugin twice).
  /// A `location_live` push (God View's "Live now", 0282) starts the stream
  /// and is answered as a ping too.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    let type = userInfo["type"] as? String
    guard type == "location_ping" || type == "location_live" else {
      completionHandler(.noData)
      return
    }
    if type == "location_live" { _ = BackgroundLocationReporter.shared.startLive(until: nil) }
    BackgroundLocationReporter.shared.answerPing { sent in completionHandler(sent ? .newData : .noData) }
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

/// Apple's map light or dark as Admin → Settings → Maps → Map appearance says
/// (lib/src/widgets/map_brightness.dart): `set` with a style of "light",
/// "dark" or "unspecified" (the phone's) overrides every MapKit view on
/// screen. Only the maps: the rest of the app keeps the phone's style.
final class MapAppearancePlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "get_ride/map_appearance", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MapAppearancePlugin(), channel: channel)
  }

  private static func apply(_ style: UIUserInterfaceStyle, to view: UIView) {
    if let map = view as? MKMapView {
      map.overrideUserInterfaceStyle = style
    }
    for sub in view.subviews {
      apply(style, to: sub)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "set" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let name = (call.arguments as? [String: Any])?["style"] as? String
    let style: UIUserInterfaceStyle = name == "dark" ? .dark : (name == "light" ? .light : .unspecified)
    MapAppearancePlugin.applyEverywhere(style)
    // A map just created may join the window a moment later: once more then.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MapAppearancePlugin.applyEverywhere(style) }
    result(nil)
  }

  private static func applyEverywhere(_ style: UIUserInterfaceStyle) {
    for scene in UIApplication.shared.connectedScenes {
      guard let windows = (scene as? UIWindowScene)?.windows else { continue }
      for window in windows {
        apply(style, to: window)
      }
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

/// "Always on" (migration 0272, lib/src/data/background_location.dart): a
/// phone whose location is already "Always" keeps telling the server where
/// it is while the app is in the background or closed. Never asks for the
/// permission; without it, it does nothing. Fixes come from:
///   * significant location changes (about 500 m; iOS relaunches the app in
///     the background for them, and needs no extra background mode);
///   * a 200 m geofence (region monitoring, on exit) around where the phone
///     last reported, moved there after every report (0276), and visits
///     (arriving at and leaving a place), both sent at once;
///   * a "Still there?" ping, a silent push (answerPing, 0276): one fix,
///     then the phone's details (sendDetails, 0282);
///   * God View's "Live now" (startLive, 0282): continuous updates, one sent
///     every 5 s to push_live_location until the share ends or the server
///     says it is over; in the background too (allowsBackgroundLocationUpdates,
///     the blue indicator showing), with Always.
/// A change is sent when due, about every 15 minutes or after a move of
/// 200 m (backgroundReportDue in lib/src/core/push_logic.dart); a geofence
/// exit, a visit and a ping are sent whatever the rule says (the server
/// still takes one background report a minute, and the open app's check-in
/// first). Each goes to push_background_location with the install's random
/// key: no session and no Flutter engine. Kept in this file so it needs no
/// change to the Xcode project.
final class BackgroundLocationReporter: NSObject, CLLocationManagerDelegate {
  static let shared = BackgroundLocationReporter()

  private let manager = CLLocationManager()
  private let defaults = UserDefaults.standard

  // As backgroundReportDue (lib/src/core/push_logic.dart).
  private static let every: TimeInterval = 15 * 60
  private static let moveMetres: CLLocationDistance = 200

  /// The geofence around the last report.
  private static let fenceMetres: CLLocationDistance = 200
  private static let fenceId = "get_ride.background_location.here"

  /// How long a ping or a geofence exit waits for its fix, and how long a
  /// ping may take in all (iOS allows a silent push 30 seconds).
  private static let fixWait: TimeInterval = 15
  private static let pingDeadline: TimeInterval = 27

  /// The fix asked for (requestLocation) is sent whatever the rule says.
  private var forceNext = false
  /// Who waits for that fix: told whether it was sent.
  private var waiting: [(Bool) -> Void] = []
  private var waitTimer: DispatchWorkItem?
  private var waitTask = UIBackgroundTaskIdentifier.invalid

  private static func k(_ name: String) -> String { "get_ride.background_location.\(name)" }

  override init() {
    super.init()
    manager.delegate = self
    // One fix for a ping or a geofence exit: a street is enough, and quicker
    // than the GPS's best. Significant changes and visits ignore it.
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  private var allowedAlways: Bool { manager.authorizationStatus == .authorizedAlways }
  private var armed: Bool { defaults.bool(forKey: Self.k("armed")) }

  func arm(url: String, anonKey: String, key: String) -> Bool {
    guard !url.isEmpty, !anonKey.isEmpty, key.count >= 32 else { return false }
    defaults.set(url, forKey: Self.k("url"))
    defaults.set(anonKey, forKey: Self.k("anonKey"))
    defaults.set(key, forKey: Self.k("key"))
    defaults.set(true, forKey: Self.k("armed"))
    return start()
  }

  func disarm() {
    stopLive()
    manager.stopMonitoringSignificantLocationChanges()
    manager.stopMonitoringVisits()
    unfence()
    for name in ["url", "anonKey", "key", "armed", "lastAt", "lastLat", "lastLng"] {
      defaults.removeObject(forKey: Self.k(name))
    }
    finishWaiting(false)
  }

  func resumeIfArmed() {
    if armed { _ = start() }
  }

  private func start() -> Bool {
    guard allowedAlways, CLLocationManager.significantLocationChangeMonitoringAvailable() else { return false }
    manager.startMonitoringSignificantLocationChanges()
    manager.startMonitoringVisits()
    // A relaunch for a geofence exit keeps that region until its event is in.
    if !manager.monitoredRegions.contains(where: { $0.identifier == Self.fenceId }),
      let here = lastReported() ?? manager.location?.coordinate
    {
      fence(at: here)
    }
    return true
  }

  private func lastReported() -> CLLocationCoordinate2D? {
    guard defaults.object(forKey: Self.k("lastLat")) != nil, defaults.object(forKey: Self.k("lastLng")) != nil else {
      return nil
    }
    return CLLocationCoordinate2D(
      latitude: defaults.double(forKey: Self.k("lastLat")), longitude: defaults.double(forKey: Self.k("lastLng")))
  }

  // MARK: The geofence

  /// The 200 m geofence, centred on [center]; one region, replaced each time
  /// (same identifier).
  private func fence(at center: CLLocationCoordinate2D) {
    guard CLLocationCoordinate2DIsValid(center), CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    else { return }
    let most = manager.maximumRegionMonitoringDistance
    let radius = most > 0 ? min(Self.fenceMetres, most) : Self.fenceMetres
    let region = CLCircularRegion(center: center, radius: radius, identifier: Self.fenceId)
    region.notifyOnEntry = false
    region.notifyOnExit = true
    manager.startMonitoring(for: region)
  }

  private func unfence() {
    for region in manager.monitoredRegions where region.identifier == Self.fenceId {
      manager.stopMonitoring(for: region)
    }
  }

  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard region.identifier == Self.fenceId, armed else { return }
    askForFix { _ in }
  }

  func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {}

  // MARK: Visits

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    guard armed, CLLocationCoordinate2DIsValid(visit.coordinate) else { return }
    let fix = CLLocation(
      coordinate: visit.coordinate, altitude: 0, horizontalAccuracy: visit.horizontalAccuracy,
      verticalAccuracy: -1, timestamp: Date())
    report(fix, force: true) { _ in }
  }

  // MARK: "Still there?"

  /// A `location_ping` push (AppDelegate): one fix, sent. [done] exactly
  /// once, within iOS's 30 seconds, with whether a report went out. On
  /// screen the app checks in itself.
  func answerPing(_ done: @escaping (Bool) -> Void) {
    var answered = false
    let once: (Bool) -> Void = { sent in
      if answered { return }
      answered = true
      done(sent)
    }
    guard armed, allowedAlways else {
      once(false)
      return
    }
    if UIApplication.shared.applicationState == .active {
      once(true)
      return
    }
    // Started now, so the network is known by the time the details go.
    _ = NetworkInfoPlugin.background
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pingDeadline) { once(false) }
    askForFix { [weak self] sent in
      guard let self = self else { return once(sent) }
      self.sendDetails { once(sent) }
    }
  }

  // MARK: The phone's details (0282)

  /// Admin's Phone card keys (lib/src/core/phone_details.dart): battery,
  /// network, storage, app version and permissions, read without asking,
  /// sent with the install's key to push_background_details. [done] once.
  func sendDetails(_ done: @escaping () -> Void) {
    guard armed, let url = defaults.string(forKey: Self.k("url")),
      let anonKey = defaults.string(forKey: Self.k("anonKey")), let key = defaults.string(forKey: Self.k("key"))
    else {
      done()
      return
    }
    let net = NetworkInfoPlugin.info(path: NetworkInfoPlugin.background.currentPath)
    var out: [String: Any] = [:]
    for (to, from) in [
      ("network_type", "type"), ("network_is_connected", "connected"), ("network_is_internet_reachable", "internet"),
      ("battery_pct", "batteryPct"), ("battery_charging", "batteryCharging"),
      ("storage_free_bytes", "storageFree"), ("storage_total_bytes", "storageTotal"),
    ] {
      if let v = net[from] { out[to] = v }
    }
    if let carrier = net["carrierName"] as? String, !["", "--", "unknown"].contains(carrier) {
      out["network_operator"] = carrier
      out["mobile_operator_name"] = carrier
    }
    if let radio = net["radio"] as? String, let g = Self.generation(radio) { out["cellular_generation"] = g }
    out["os_version"] = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { out["app_version"] = v }
    if let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String { out["app_build_version"] = b }
    // Only sent with location Always.
    out["perm_location"] = "always"
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let s = settings.authorizationStatus
      out["perm_notifications"] = s == .authorized || s == .provisional || s == .ephemeral
      out["location_service_on"] = CLLocationManager.locationServicesEnabled()
      self.rpc(url: url, anonKey: anonKey, fn: "push_background_details", body: ["p_key": key, "p_details": out]) { _ in
        DispatchQueue.main.async { done() }
      }
    }
  }

  /// "5G", "4G"… from CoreTelephony's radio, as cellularGenerationOf (lib/src/core/session_telemetry.dart).
  private static func generation(_ radio: String) -> String? {
    let r = radio.replacingOccurrences(of: "CTRadioAccessTechnology", with: "")
    if r.hasPrefix("NR") { return "5G" }
    if r == "LTE" { return "4G" }
    if ["WCDMA", "HSDPA", "HSUPA", "eHRPD", "CDMAEVDORev0", "CDMAEVDORevA", "CDMAEVDORevB"].contains(r) { return "3G" }
    if ["GPRS", "Edge", "CDMA1x"].contains(r) { return "2G" }
    return nil
  }

  // MARK: Live now (0282)

  /// When the share ends; nil while not live.
  private var liveUntil: Date?
  private var liveTimer: Timer?
  private var livePosting = false
  private var liveLastSent = Date.distantPast
  private static let liveEvery: TimeInterval = 5
  private static let liveMost: TimeInterval = 61 * 60

  /// Streams until [until] (nil: not known yet, an hour at most until the
  /// server says). Already streaming: only the end may change. False
  /// without Always or the reporter armed.
  func startLive(until: Date?) -> Bool {
    guard armed, allowedAlways else { return false }
    let most = Date().addingTimeInterval(Self.liveMost)
    if let u = until, u > Date() {
      liveUntil = min(u, most)
    } else if liveUntil == nil {
      liveUntil = most
    }
    if liveTimer != nil { return true }
    manager.allowsBackgroundLocationUpdates = true
    manager.pausesLocationUpdatesAutomatically = false
    manager.showsBackgroundLocationIndicator = true
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.distanceFilter = kCLDistanceFilterNone
    manager.startUpdatingLocation()
    liveTimer = Timer.scheduledTimer(withTimeInterval: Self.liveEvery, repeats: true) { [weak self] _ in self?.liveTick() }
    if UIApplication.shared.applicationState == .active { sendDetails {} }
    return true
  }

  func stopLive() {
    liveTimer?.invalidate()
    liveTimer = nil
    liveUntil = nil
    manager.stopUpdatingLocation()
    manager.allowsBackgroundLocationUpdates = false
    manager.showsBackgroundLocationIndicator = false
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  /// The end, or the last fix again for a phone standing still.
  private func liveTick() {
    guard let until = liveUntil, Date() < until, armed, allowedAlways else {
      stopLive()
      return
    }
    if let fix = manager.location, Date().timeIntervalSince(liveLastSent) >= Self.liveEvery + 2 { postLive(fix) }
  }

  private func postLive(_ fix: CLLocation) {
    guard !livePosting, let url = defaults.string(forKey: Self.k("url")),
      let anonKey = defaults.string(forKey: Self.k("anonKey")), let key = defaults.string(forKey: Self.k("key"))
    else { return }
    livePosting = true
    var body: [String: Any] = ["p_key": key, "p_lat": fix.coordinate.latitude, "p_lng": fix.coordinate.longitude]
    if fix.speed >= 0 { body["p_speed"] = fix.speed }
    if fix.horizontalAccuracy >= 0 { body["p_accuracy"] = fix.horizontalAccuracy }
    rpc(url: url, anonKey: anonKey, fn: "push_live_location", body: body) { data in
      let answer = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      DispatchQueue.main.async {
        self.livePosting = false
        self.liveLastSent = Date()
        // No answer (no signal): keep trying until the end.
        guard let answer = answer else { return }
        if answer["live"] as? Bool != true {
          self.stopLive()
          return
        }
        if let left = answer["ends_in"] as? Double ?? (answer["ends_in"] as? Int).map(Double.init) {
          self.liveUntil = Date().addingTimeInterval(left)
        }
      }
    }
  }

  /// POSTs [body] to the database function [fn]; the answer's body, or nil.
  private func rpc(url: String, anonKey: String, fn: String, body: [String: Any], done: @escaping (Foundation.Data?) -> Void) {
    let base = url.hasSuffix("/") ? String(url.dropLast()) : url
    guard let endpoint = URL(string: base + "/rest/v1/rpc/" + fn),
      let payload = try? JSONSerialization.data(withJSONObject: body)
    else {
      done(nil)
      return
    }
    var request = URLRequest(url: endpoint, timeoutInterval: 10)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(anonKey, forHTTPHeaderField: "apikey")
    if anonKey.hasPrefix("eyJ") { request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization") }
    request.httpBody = payload
    URLSession.shared.dataTask(with: request) { data, response, error in
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      done(error == nil && (200..<300).contains(code) ? data : nil)
    }.resume()
  }

  /// One fix now (requestLocation), sent whatever the rule says; [done]
  /// with whether it was. Without one in [fixWait], the last fix iOS has if
  /// it is under 5 minutes old, else nothing.
  private func askForFix(_ done: @escaping (Bool) -> Void) {
    guard armed, allowedAlways else {
      done(false)
      return
    }
    waiting.append(done)
    forceNext = true
    if waitTask == .invalid {
      waitTask = UIApplication.shared.beginBackgroundTask(withName: "location-ping") { [weak self] in
        self?.finishWaiting(false)
      }
    }
    guard waitTimer == nil else { return }
    let timer = DispatchWorkItem { [weak self] in self?.giveUp() }
    waitTimer = timer
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fixWait, execute: timer)
    manager.requestLocation()
  }

  private func giveUp() {
    waitTimer?.cancel()
    waitTimer = nil
    guard forceNext else { return }
    forceNext = false
    if let fix = manager.location, -fix.timestamp.timeIntervalSinceNow < 5 * 60 {
      report(fix, force: true) { [weak self] sent in self?.finishWaiting(sent) }
    } else {
      finishWaiting(false)
    }
  }

  private func finishWaiting(_ sent: Bool) {
    let callbacks = waiting
    waiting = []
    forceNext = false
    waitTimer?.cancel()
    waitTimer = nil
    for callback in callbacks { callback(sent) }
    if waitTask != .invalid {
      UIApplication.shared.endBackgroundTask(waitTask)
      waitTask = .invalid
    }
  }

  // MARK: Fixes

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let fix = locations.last else { return }
    if liveTimer != nil, Date().timeIntervalSince(liveLastSent) >= Self.liveEvery - 0.5 { postLive(fix) }
    let force = forceNext
    if force {
      forceNext = false
      waitTimer?.cancel()
      waitTimer = nil
    }
    report(fix, force: force) { [weak self] sent in
      if force { self?.finishWaiting(sent) }
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // The fix asked for did not come: what iOS last had, or nothing.
    if forceNext { giveUp() }
  }

  /// Sends [fix] when due (or [force]d), then moves the geofence there;
  /// [done] with whether it was sent.
  private func report(_ fix: CLLocation, force: Bool, done: @escaping (Bool) -> Void) {
    guard armed else {
      done(false)
      return
    }
    guard allowedAlways else {
      // No longer Always: stop until the app sees it again.
      disarm()
      done(false)
      return
    }
    // On screen, the app checks in itself.
    if UIApplication.shared.applicationState == .active {
      done(true)
      return
    }
    let now = Date().timeIntervalSince1970
    let lastAt = defaults.double(forKey: Self.k("lastAt"))
    var moved: CLLocationDistance = 0
    if let last = lastReported() {
      moved = fix.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
    }
    let due = force || lastAt == 0 || now - lastAt >= Self.every || moved >= Self.moveMetres
    guard due,
      let url = defaults.string(forKey: Self.k("url")),
      let anonKey = defaults.string(forKey: Self.k("anonKey")),
      let key = defaults.string(forKey: Self.k("key"))
    else {
      done(false)
      return
    }
    var task = UIBackgroundTaskIdentifier.invalid
    task = UIApplication.shared.beginBackgroundTask(withName: "background-location") {
      UIApplication.shared.endBackgroundTask(task)
      task = .invalid
    }
    let lat = fix.coordinate.latitude, lng = fix.coordinate.longitude
    post(url: url, anonKey: anonKey, key: key, lat: lat, lng: lng) { ok in
      DispatchQueue.main.async {
        if ok {
          self.defaults.set(now, forKey: Self.k("lastAt"))
          self.defaults.set(lat, forKey: Self.k("lastLat"))
          self.defaults.set(lng, forKey: Self.k("lastLng"))
          self.fence(at: fix.coordinate)
        }
        done(ok)
        if task != .invalid {
          UIApplication.shared.endBackgroundTask(task)
          task = .invalid
        }
      }
    }
  }

  private func post(
    url: String, anonKey: String, key: String, lat: Double, lng: Double, done: @escaping (Bool) -> Void
  ) {
    let base = url.hasSuffix("/") ? String(url.dropLast()) : url
    guard let endpoint = URL(string: base + "/rest/v1/rpc/push_background_location"),
      let body = try? JSONSerialization.data(withJSONObject: ["p_key": key, "p_lat": lat, "p_lng": lng])
    else {
      done(false)
      return
    }
    var request = URLRequest(url: endpoint, timeoutInterval: 10)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(anonKey, forHTTPHeaderField: "apikey")
    // A legacy anon key is a JWT and goes as the bearer too; a publishable
    // key goes as apikey only.
    if anonKey.hasPrefix("eyJ") { request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization") }
    request.httpBody = body
    URLSession.shared.dataTask(with: request) { _, response, error in
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      done(error == nil && (200..<300).contains(code))
    }.resume()
  }
}

/// The app's side of [BackgroundLocationReporter]: `arm` with the project
/// and the key, `disarm` at sign-out or once location is no longer Always.
final class BackgroundLocationPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "get_ride/background_location", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BackgroundLocationPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "arm":
      let args = call.arguments as? [String: Any] ?? [:]
      result(
        BackgroundLocationReporter.shared.arm(
          url: args["url"] as? String ?? "", anonKey: args["anonKey"] as? String ?? "",
          key: args["key"] as? String ?? ""))
    case "disarm":
      BackgroundLocationReporter.shared.disarm()
      result(nil)
    case "live":
      // "Live now" (0282), from the open app that found a share on.
      let ms = ((call.arguments as? [String: Any])?["until"] as? NSNumber)?.doubleValue ?? 0
      result(BackgroundLocationReporter.shared.startLive(until: ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil))
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

  /// A monitor of its own for the closed app (a ping's details, 0282).
  static let background: NWPathMonitor = {
    let m = NWPathMonitor()
    m.start(queue: DispatchQueue(label: "get_ride.network.background"))
    return m
  }()

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "info" else {
      result(FlutterMethodNotImplemented)
      return
    }
    result(Self.info(path: path ?? monitor.currentPath))
  }

  static func info(path p: NWPath) -> [String: Any] {
    var out: [String: Any] = [:]
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
    // The battery (-1 until monitoring has a reading) and the free space
    // the system would make for the app, for Admin's Phone card.
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    if device.batteryLevel >= 0 {
      out["batteryPct"] = Int((device.batteryLevel * 100).rounded())
    }
    if device.batteryState != .unknown {
      out["batteryCharging"] = device.batteryState == .charging || device.batteryState == .full
    }
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
    if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys) {
      if let free = v.volumeAvailableCapacityForImportantUsage {
        out["storageFree"] = NSNumber(value: free)
      }
      if let total = v.volumeTotalCapacity {
        out["storageTotal"] = NSNumber(value: total)
      }
    }
    return out
  }
}
