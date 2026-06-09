import Flutter
import Replay
import UIKit

/// Flutter bridge for Replayfy on iOS. Thin forwarder onto the native
/// `Replay` SDK (which drives the live recording engine). The engine handles
/// screenshots, taps, performance, and crashes itself; this plugin forwards
/// the public API and drives the **pull-based masking**:
///
///  1. The Dart side keeps a warm cache of `<ReplayMask>` rects.
///  2. Here, a lightweight timer pulls that cache over the occlusion channel
///     at roughly capture rate and stores it (window points — Flutter's
///     logical pixels equal UIKit points on iOS, so no scaling).
///  3. We compose the engine's `privacyRectsProvider` so each screenshot
///     reads the freshest pulled rects synchronously, with zero IPC on the
///     capture path.
public final class ReplayfyFlutterPlugin: NSObject, FlutterPlugin {
  private var occlusionChannel: FlutterMethodChannel?
  private var pullTimer: Timer?

  // Latest rects pulled from Dart, in window points, each carrying its own
  // render style (blur / overlay). Read on the main thread by the engine's
  // capture loop; written on the main thread by the pull callback — so no
  // locking is required.
  private var cachedRects: [MaskRect] = []

  // ~5 Hz keeps the cache comfortably ahead of the engine's ~3 fps capture
  // while staying far below Flutter's 60–120 fps render rate. Pull (not push)
  // is the whole point: IPC scales with capture, not with rebuilds.
  private static let pullInterval: TimeInterval = 0.2

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ReplayfyFlutterPlugin()
    let command = FlutterMethodChannel(
      name: "replayfy_flutter", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: command)
    instance.occlusionChannel = FlutterMethodChannel(
      name: "replayfy_flutter/occlusion",
      binaryMessenger: registrar.messenger())
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      start(args)
      result(nil)
    case "stop":
      Replay.stop()
      stopPull()
      result(nil)
    case "isRecording":
      result(Replay.isRecording)
    case "currentSessionId":
      result(ReplayBridge.currentSessionId())
    case "startNewSession":
      Replay.startNewSession(); result(nil)
    case "pauseRecording":
      Replay.pauseRecording(); result(nil)
    case "resumeRecording":
      Replay.resumeRecording(); result(nil)
    case "cancelSession":
      Replay.cancelSession(); result(nil)
    case "stopApplicationAndUploadData":
      Replay.stopApplicationAndUploadData(); result(nil)
    case "identify":
      Replay.identify(args["distinctId"] as? String ?? "",
                      properties: args["properties"] as? [String: Any])
      result(nil)
    case "track":
      Replay.track(args["name"] as? String ?? "",
                   properties: args["properties"] as? [String: Any])
      result(nil)
    case "tagScreenName":
      Replay.tagScreenName(args["name"] as? String ?? ""); result(nil)
    case "addTagWithProperties":
      Replay.addTagWithProperties(args["name"] as? String ?? "",
                                  properties: args["properties"] as? [String: Any])
      result(nil)
    case "setUserProperty":
      Replay.setUserProperty(args["key"] as? String ?? "", value: args["value"])
      result(nil)
    case "setSessionProperty":
      Replay.setSessionProperty(args["key"] as? String ?? "", value: args["value"])
      result(nil)
    case "setMetadata":
      ReplayBridge.recordMetadata(args["key"] as? String ?? "",
                                  value: args["value"] as? String ?? "")
      result(nil)
    case "recordNetwork":
      // Dart HTTP captured by the Dart-side HttpClient proxy.
      ReplayBridge.recordNetwork(
        url: args["url"] as? String ?? "",
        method: args["method"] as? String ?? "GET",
        request: args["request"] as? String ?? "{}",
        response: args["response"] as? String ?? "{}",
        status: args["status"] as? Int ?? 0,
        duration: args["durationMs"] as? Int ?? 0)
      result(nil)
    case "markSessionAsFavorite":
      Replay.markSessionAsFavorite(); result(nil)
    case "reportBugEvent":
      Replay.reportBugEvent(args["name"] as? String ?? "",
                            description: args["description"] as? String)
      result(nil)
    case "optOut":
      Replay.optOutOverall(args["optOut"] as? Bool ?? false); result(nil)
    case "isOptedOut":
      result(Replay.isOptedOutOverall)
    case "occludeAllTextFields":
      ReplayBridge.occludeAllTextFields(args["occlude"] as? Bool ?? false)
      result(nil)
    case "occludeSensitiveScreen":
      Replay.occludeSensitiveScreen(args["occlude"] as? Bool ?? false); result(nil)
    case "setMaskStyle":
      // Global default style for bulk/whole-screen occlusion + any ReplayMask
      // that doesn't carry its own style. Per-region styles still override via
      // the pulled rects above.
      let style = ReplayMaskStyle(rawValue: args["style"] as? Int ?? 0) ?? .blur
      Replay.setMaskStyle(style)
      result(nil)
    case "setAutomaticScreenNameTagging":
      Replay.setAutomaticScreenNameTagging(args["enabled"] as? Bool ?? true)
      result(nil)
    case "setPushNotificationToken":
      Replay.setPushNotificationToken(args["token"] as? String ?? "",
                                      platform: args["platform"] as? String ?? "fcm")
      result(nil)
    case "setAppVersion":
      Replay.setAppVersion(args["version"] as? String, build: args["build"] as? String)
      result(nil)
    case "urlForCurrentSession":
      result(Replay.urlForCurrentSession())
    case "urlForCurrentUser":
      result(Replay.urlForCurrentUser())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // ── Boot ───────────────────────────────────────────────────────────────

  private func start(_ args: [String: Any]) {
    let projectKey = args["projectKey"] as? String ?? ""
    let ingestUrl = args["ingestUrl"] as? String ?? ""
    let cfg = Self.dict(args["config"]) ?? [:]

    // Tag the session as Flutter-captured (dashboard shows "Captured by …";
    // platform stays ios). Must precede start() — it's read in /start.
    ReplayBridge.setFramework("flutter")

    Replay.start(with: ReplayConfig(
      apiKey: projectKey,
      apiHost: ingestUrl,
      distinctId: cfg["distinctId"] as? String,
      // The Dart layer owns console + network capture (Dart logs/HTTP are
      // invisible to the native interceptors), so leave the native ones off
      // to avoid double-recording.
      captureConsole: false,
      captureNetwork: false,
      captureErrors: cfg["recordErrors"] as? Bool ?? true,
      captureSnapshotPixels: cfg["recordScreen"] as? Bool ?? true,
      autoScreenName: cfg["autoScreenName"] as? Bool ?? true,
      useRemoteConfig: cfg["useRemoteConfig"] as? Bool ?? true
    ))

    if cfg["maskAllInputs"] as? Bool == true {
      ReplayBridge.occludeAllTextFields(true)
    }

    installOcclusionPull()
  }

  // ── Pull-based masking ───────────────────────────────────────────────────

  private func installOcclusionPull() {
    // Feed the engine's host-owned hook — composed into privacyRectsProvider
    // by start() and never overwritten, so it survives the async /start
    // response that assigns the registry-backed provider.
    ReplayCore.shared.externalPrivacyRectsProvider = { [weak self] in
      self?.cachedRects ?? []
    }

    pullTimer?.invalidate()
    pullTimer = Timer.scheduledTimer(
      withTimeInterval: Self.pullInterval, repeats: true
    ) { [weak self] _ in
      self?.pullRects()
    }
  }

  private func stopPull() {
    pullTimer?.invalidate(); pullTimer = nil
    cachedRects = []
  }

  private func pullRects() {
    occlusionChannel?.invokeMethod("requestOcclusionRects", arguments: nil) {
      [weak self] response in
      guard let self = self else { return }
      guard let list = response as? [[String: Any]] else {
        self.cachedRects = []
        return
      }
      // Flutter logical pixels == UIKit points on iOS, so the bounds map
      // straight to a CGRect in window points (the engine masks in points).
      // Each rect carries its own style index (blur = 0, overlay = 1); the
      // engine renders per-rect, so a screen can mix blurred + overlaid masks.
      self.cachedRects = list.compactMap { item in
        guard
          let left = (item["left"] as? NSNumber)?.doubleValue,
          let top = (item["top"] as? NSNumber)?.doubleValue,
          let right = (item["right"] as? NSNumber)?.doubleValue,
          let bottom = (item["bottom"] as? NSNumber)?.doubleValue,
          right > left, bottom > top
        else { return nil }
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let style = ReplayMaskStyle(rawValue: (item["style"] as? NSNumber)?.intValue ?? 0) ?? .blur
        return MaskRect(rect: rect, style: style)
      }
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  private static func dict(_ value: Any?) -> [String: Any]? {
    guard
      let json = value as? String,
      let data = json.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
  }
}
