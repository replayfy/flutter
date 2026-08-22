import Flutter
import Replay
import UIKit

/// Flutter bridge for Replayfy on iOS. Thin forwarder onto the native
/// `Replay` SDK (which drives the live recording engine for taps, performance,
/// and crashes). The native side can't read Flutter's surface, so the Dart
/// layer captures frames (`RepaintBoundary.toImage`) and ships each one — with
/// its occlusion rects, in the same frame — over the `reportFrame` channel; we
/// mask + enqueue via the engine's `submitFrame`. Native screenshotting stays
/// off, and because the rects arrive with the frame there's no poll/mask-lag.
public final class ReplayfyFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ReplayfyFlutterPlugin()
    let command = FlutterMethodChannel(
      name: "replayfy_flutter", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: command)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      start(args)
      result(nil)
    case "reportTap":
      // Dart-side gesture capture reports the real tapped-widget label here
      // (the native FlutterView hit-test can't see Flutter widgets).
      Replay.reportInteraction(
        kind: args["kind"] as? String ?? "tap",
        label: args["label"] as? String ?? "",
        x: args["x"] as? Int ?? 0,
        y: args["y"] as? Int ?? 0,
        direction: args["direction"] as? String ?? "")
      result(nil)
    case "occludeAllTextView":
      Replay.occludeAllTextView(args["occlude"] as? Bool ?? false); result(nil)
    case "setMultiSessionRecord":
      Replay.setMultiSessionRecord(args["enabled"] as? Bool ?? false); result(nil)
    case "allowShortBreak":
      let ms = (args["breakWindowMs"] as? NSNumber)?.doubleValue ?? 30000
      Replay.allowShortBreakForAnotherApp(args["allow"] as? Bool ?? false, windowSeconds: ms / 1000.0)
      result(nil)
    case "enableAdvancedGestureRecognizer":
      Replay.enableAdvancedGestureRecognizer(args["enabled"] as? Bool ?? false); result(nil)
    case "stop":
      Replay.stop()
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
    case "trackInput":
      Replay.trackInput(label: args["label"] as? String ?? "",
                        value: args["value"] as? String ?? "",
                        masked: args["masked"] as? Bool ?? false)
      result(nil)
    case "tagScreenName":
      Replay.tagScreenName(args["name"] as? String ?? ""); result(nil)
    case "excludeScreen":
      Replay.excludeScreen(args["name"] as? String ?? ""); result(nil)
    case "unexcludeScreen":
      Replay.unexcludeScreen(args["name"] as? String ?? ""); result(nil)
    case "setExcludedScreens":
      Replay.setExcludedScreens(args["names"] as? [String] ?? []); result(nil)
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
    case "reportFrame":
      // Dart captures each frame (RepaintBoundary.toImage) since native can't
      // read Flutter's surface, and ships its occlusion rects in the SAME
      // payload (PNG-pixel coords, each with a style index) — no poll, no lag.
      guard let data = (args["bytes"] as? FlutterStandardTypedData)?.data else { result(nil); return }
      var rects: [CGRect] = []
      var styles: [Int] = []
      for r in (args["rects"] as? [[String: Any]] ?? []) {
        guard
          let left = (r["left"] as? NSNumber)?.doubleValue,
          let top = (r["top"] as? NSNumber)?.doubleValue,
          let right = (r["right"] as? NSNumber)?.doubleValue,
          let bottom = (r["bottom"] as? NSNumber)?.doubleValue,
          right > left, bottom > top
        else { continue }
        rects.append(CGRect(x: left, y: top, width: right - left, height: bottom - top))
        styles.append((r["style"] as? NSNumber)?.intValue ?? 0)
      }
      Replay.reportFrame(data, rects: rects, styles: styles)
      result(nil)
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
      // Native screenshotting OFF — it can't read Flutter's surface. The Dart
      // layer captures frames + rects and pushes them via reportFrame.
      captureSnapshotPixels: false,
      autoScreenName: cfg["autoScreenName"] as? Bool ?? true,
      useRemoteConfig: cfg["useRemoteConfig"] as? Bool ?? true,
      // Dart owns tap capture (it knows the real widget label; the native
      // view-tree only sees the one FlutterView), reported via reportTap.
      captureTouch: false
    ))

    if cfg["maskAllInputs"] as? Bool == true {
      ReplayBridge.occludeAllTextFields(true)
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
