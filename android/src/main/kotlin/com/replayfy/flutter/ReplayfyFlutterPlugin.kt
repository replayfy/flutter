package com.replayfy.flutter

import android.app.Application
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import com.replayfy.android.MaskRect
import com.replayfy.android.Replay
import com.replayfy.android.ReplayConfig
import com.replayfy.android.ReplayMaskStyle
import com.replayfy.android.internal.mobile.ReplayCore
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * Flutter bridge for Replayfy on Android. Thin forwarder onto the native
 * `Replay` SDK (which drives the live recording engine). The engine handles
 * screenshots, taps, performance, and crashes itself; this plugin forwards
 * the public API and drives the **pull-based masking**:
 *
 *  1. The Dart side keeps a warm cache of `<ReplayMask>` rects.
 *  2. Here, a lightweight main-thread loop pulls that cache over the
 *     occlusion channel at roughly capture rate and converts it to
 *     decor-view device pixels (logical × devicePixelRatio — what the
 *     screenshotter masks in).
 *  3. We compose the engine's `privacyRectsProvider` so each screenshot reads
 *     the freshest pulled rects synchronously, with zero IPC on the capture
 *     path.
 *
 * Pull (not push) is the point: IPC scales with the ~3 fps capture, not with
 * Flutter's 60–120 fps rebuilds.
 */
class ReplayfyFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var commandChannel: MethodChannel
  private lateinit var occlusionChannel: MethodChannel
  private var application: Application? = null

  private val mainHandler = Handler(Looper.getMainLooper())
  private var pulling = false

  // Latest rects pulled from Dart, in decor-view device pixels, each carrying
  // its own render style (blur / overlay) so a screen can mix mask types.
  @Volatile
  private var cachedRects: List<MaskRect> = emptyList()

  // ~5 Hz — comfortably ahead of the engine's ~3 fps capture, far below the
  // render rate.
  private val pullIntervalMs = 200L

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    application = binding.applicationContext as? Application
    commandChannel = MethodChannel(binding.binaryMessenger, "replayfy_flutter")
    commandChannel.setMethodCallHandler(this)
    occlusionChannel =
      MethodChannel(binding.binaryMessenger, "replayfy_flutter/occlusion")
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    stopPull()
    commandChannel.setMethodCallHandler(null)
    application = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "start" -> { start(call); result.success(null) }
      "reportTap" -> {
        // Dart-side gesture capture reports the real tapped-widget label here
        // (the native FlutterView tracker can't see Flutter widgets).
        Replay.reportInteraction(
          kind = call.argument<String>("kind") ?: "tap",
          label = call.argument<String>("label") ?: "",
          x = call.argument<Int>("x") ?: 0,
          y = call.argument<Int>("y") ?: 0,
          direction = call.argument<String>("direction") ?: "")
        result.success(null)
      }
      "reportFrame" -> {
        // Dart captures frames via a root RepaintBoundary (native PixelCopy
        // can't read Flutter's SurfaceView); feed them into the frames archive.
        val bytes = call.argument<ByteArray>("bytes")
        val ts = call.argument<Number>("ts")?.toLong() ?: System.currentTimeMillis()
        // Occlusion rects (developer ReplayMask bounds) in PNG-pixel coords;
        // the engine's encoder masks them per style (blur/overlay/pixelate).
        val rects = (call.argument<List<Map<String, Any>>>("rects") ?: emptyList()).mapNotNull { m ->
          try {
            com.replayfy.android.MaskRect(
              android.graphics.Rect(
                (m["left"] as Number).toInt(), (m["top"] as Number).toInt(),
                (m["right"] as Number).toInt(), (m["bottom"] as Number).toInt()),
              com.replayfy.android.ReplayMaskStyle.from((m["style"] as? Number)?.toInt() ?: 0))
          } catch (e: Throwable) { null }
        }
        if (bytes != null) Replay.reportFrame(bytes, ts, rects)
        result.success(null)
      }
      "occludeAllTextView" -> { Replay.occludeAllTextView(call.argument<Boolean>("occlude") ?: false); result.success(null) }
      "setMultiSessionRecord" -> { Replay.setMultiSessionRecord(call.argument<Boolean>("enabled") ?: false); result.success(null) }
      "allowShortBreak" -> { Replay.allowShortBreakForAnotherApp(call.argument<Boolean>("allow") ?: false); result.success(null) }
      "stop" -> { Replay.stop(); stopPull(); result.success(null) }
      "isRecording" -> result.success(Replay.isRecording())
      "currentSessionId" -> result.success(Replay.currentSessionId() ?: "")
      "startNewSession" -> { Replay.startNewSession(); result.success(null) }
      "pauseRecording" -> { Replay.pauseRecording(); result.success(null) }
      "resumeRecording" -> { Replay.resumeRecording(); result.success(null) }
      "cancelSession" -> { Replay.cancelSession(); result.success(null) }
      "stopApplicationAndUploadData" -> {
        Replay.stopApplicationAndUploadData(); result.success(null)
      }
      "identify" -> {
        Replay.identify(call.argument("distinctId") ?: "", props(call.argument("properties")))
        result.success(null)
      }
      "track" -> {
        Replay.track(call.argument("name") ?: "", props(call.argument("properties")))
        result.success(null)
      }
      "trackInput" -> {
        Replay.trackInput(
          call.argument("label") ?: "",
          call.argument("value") ?: "",
          call.argument<Boolean>("masked") ?: false,
        )
        result.success(null)
      }
      "tagScreenName" -> { Replay.tagScreenName(call.argument("name") ?: ""); result.success(null) }
      "addTagWithProperties" -> {
        Replay.addTagWithProperties(call.argument("name") ?: "", props(call.argument("properties")))
        result.success(null)
      }
      "setUserProperty" -> {
        Replay.setUserProperty(call.argument("key") ?: "", call.argument<Any?>("value"))
        result.success(null)
      }
      "setSessionProperty" -> {
        Replay.setSessionProperty(call.argument("key") ?: "", call.argument<Any?>("value"))
        result.success(null)
      }
      "setMetadata" -> {
        Replay.recordMetadata(call.argument("key") ?: "", call.argument("value") ?: "")
        result.success(null)
      }
      "recordNetwork" -> {
        // Dart HTTP captured by the Dart-side HttpClient proxy.
        Replay.recordNetwork(
          url = call.argument("url") ?: "",
          method = call.argument("method") ?: "GET",
          request = call.argument("request") ?: "{}",
          response = call.argument("response") ?: "{}",
          status = call.argument("status") ?: 0,
          duration = (call.argument<Number>("durationMs") ?: 0).toLong(),
        )
        result.success(null)
      }
      "markSessionAsFavorite" -> { Replay.markSessionAsFavorite(); result.success(null) }
      "reportBugEvent" -> {
        Replay.reportBugEvent(call.argument("name") ?: "", call.argument("description"))
        result.success(null)
      }
      "optOut" -> { Replay.optOutOverall(call.argument("optOut") ?: false); result.success(null) }
      "isOptedOut" -> result.success(Replay.isOptedOutOverall())
      "occludeAllTextFields" -> {
        Replay.occludeAllTextFields(call.argument("occlude") ?: false); result.success(null)
      }
      "occludeSensitiveScreen" -> {
        Replay.occludeSensitiveScreen(call.argument("occlude") ?: false); result.success(null)
      }
      "setMaskStyle" -> {
        // Global default style for bulk/whole-screen occlusion + any ReplayMask
        // that doesn't carry its own style. Per-region styles still override
        // via the pulled rects.
        Replay.setMaskStyle(ReplayMaskStyle.from(call.argument<Int>("style") ?: 0))
        result.success(null)
      }
      "setAutomaticScreenNameTagging" -> {
        Replay.setAutomaticScreenNameTagging(call.argument("enabled") ?: true); result.success(null)
      }
      "setPushNotificationToken" -> {
        Replay.setPushNotificationToken(
          call.argument("token") ?: "", call.argument("platform") ?: "fcm")
        result.success(null)
      }
      "setAppVersion" -> {
        Replay.setAppVersion(call.argument("version"), call.argument("build")); result.success(null)
      }
      "urlForCurrentSession" -> result.success(Replay.urlForCurrentSession())
      "urlForCurrentUser" -> result.success(Replay.urlForCurrentUser())
      else -> result.notImplemented()
    }
  }

  // ── Boot ───────────────────────────────────────────────────────────────

  private fun start(call: MethodCall) {
    val app = application ?: return
    val projectKey = call.argument<String>("projectKey") ?: ""
    val ingestUrl = call.argument<String>("ingestUrl") ?: ""
    val cfg = parseConfig(call.argument("config"))

    // Tag the session as Flutter-captured (dashboard shows "Captured by …";
    // platform stays android). Must precede init() — it's read in /start.
    Replay.setFramework("flutter")

    Replay.init(
      app,
      ReplayConfig(
        apiKey = projectKey,
        apiHost = ingestUrl,
        distinctId = cfg.optStringOrNull("distinctId"),
        // The Dart layer owns console + network capture (Dart logs/HTTP are
        // invisible to the native interceptors), so leave the native ones off
        // to avoid double-recording.
        captureConsole = false,
        captureNetwork = false,
        captureErrors = cfg.optBoolean("recordErrors", true),
        // Dart owns frame capture on Android (native PixelCopy can't read
        // Flutter's SurfaceView → black frames). Frames arrive via reportFrame.
        captureSnapshotPixels = false,
        autoScreenName = cfg.optBoolean("autoScreenName", true),
        useRemoteConfig = cfg.optBoolean("useRemoteConfig", true),
        // Dart owns tap capture (it knows the real widget label; the native
        // view tree only sees the one FlutterView), reported via reportTap.
        captureTouch = false,
      ),
    )

    if (cfg.optBoolean("maskAllInputs", false)) {
      Replay.occludeAllTextFields(true)
    }

    installOcclusionPull()
  }

  // ── Pull-based masking ───────────────────────────────────────────────────

  private fun installOcclusionPull() {
    // Feed the engine's host-owned hook — composed into privacyRectsProvider
    // by start() and never overwritten, so it survives the async /start
    // response that assigns the registry-backed provider.
    ReplayCore.shared.externalPrivacyRectsProvider = { cachedRects }

    if (pulling) return
    pulling = true
    mainHandler.post(pullLoop)
  }

  private val pullLoop = object : Runnable {
    override fun run() {
      if (!pulling) return
      occlusionChannel.invokeMethod(
        "requestOcclusionRects",
        null,
        object : MethodChannel.Result {
          override fun success(response: Any?) {
            cachedRects = toRects(response)
          }

          override fun error(code: String, message: String?, details: Any?) {
            cachedRects = emptyList()
          }

          override fun notImplemented() {
            cachedRects = emptyList()
          }
        },
      )
      mainHandler.postDelayed(this, pullIntervalMs)
    }
  }

  private fun stopPull() {
    pulling = false
    mainHandler.removeCallbacks(pullLoop)
    cachedRects = emptyList()
  }

  /** Convert Dart's logical-pixel bounds to decor-view device pixels, keeping
   *  each rect's render style (blur = 0, overlay = 1). */
  private fun toRects(response: Any?): List<MaskRect> {
    val list = response as? List<*> ?: return emptyList()
    val out = ArrayList<MaskRect>(list.size)
    for (item in list) {
      val m = item as? Map<*, *> ?: continue
      val dpr = (m["dpr"] as? Number)?.toDouble() ?: 1.0
      val left = (m["left"] as? Number)?.toDouble() ?: continue
      val top = (m["top"] as? Number)?.toDouble() ?: continue
      val right = (m["right"] as? Number)?.toDouble() ?: continue
      val bottom = (m["bottom"] as? Number)?.toDouble() ?: continue
      if (right <= left || bottom <= top) continue
      val style = ReplayMaskStyle.from((m["style"] as? Number)?.toInt() ?: 0)
      out.add(
        MaskRect(
          Rect(
            (left * dpr).toInt(),
            (top * dpr).toInt(),
            (right * dpr).toInt(),
            (bottom * dpr).toInt(),
          ),
          style,
        ),
      )
    }
    return out
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  private fun parseConfig(json: String?): JSONObject =
    try { if (json.isNullOrBlank()) JSONObject() else JSONObject(json) } catch (_: Throwable) { JSONObject() }

  private fun JSONObject.optStringOrNull(key: String): String? =
    if (has(key) && !isNull(key)) optString(key) else null

  private fun props(map: Map<String, Any?>?): Map<String, Any?>? = map
}
