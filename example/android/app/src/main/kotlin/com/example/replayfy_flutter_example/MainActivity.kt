package com.example.replayfy_flutter_example

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.os.Build
import android.util.Log
import android.view.Gravity
import android.view.View
import android.webkit.WebView
import android.widget.TextView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * The example's activity. For the privacy end-to-end fixture
 * (lib/privacy_e2e_android.dart) it also registers two native platform views
 * and, once that screen asks for it, relays commands broadcast with
 * `adb shell am broadcast -a <package>.E2E -p <package> --es cmd "..."` to
 * Dart. The fixture's state lines go to logcat under the ReplayE2E tag. The
 * regular example (lib/main.dart) uses none of this.
 */
class MainActivity : FlutterActivity() {
  private var e2eReceiver: BroadcastReceiver? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    val views = flutterEngine.platformViewsController.registry
    views.registerViewFactory("e2e-native-box", NativeBoxFactory())
    views.registerViewFactory("e2e-webview", WebViewFactory())

    val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "replayfy_example/e2e")
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "listen" -> { listen(channel); result.success(null) }
        "log" -> { Log.i("ReplayE2E", call.arguments as? String ?: ""); result.success(null) }
        else -> result.notImplemented()
      }
    }
  }

  override fun onDestroy() {
    e2eReceiver?.let { unregisterReceiver(it) }
    e2eReceiver = null
    super.onDestroy()
  }

  // A broadcast, unlike `am start`, doesn't pause and resume the activity, so
  // driving the screen doesn't move the recording through its lifecycle.
  @SuppressLint("UnspecifiedRegisterReceiverFlag")
  private fun listen(channel: MethodChannel) {
    if (e2eReceiver != null) return
    val receiver = object : BroadcastReceiver() {
      override fun onReceive(context: Context, intent: Intent) {
        channel.invokeMethod("cmd", intent.getStringExtra("cmd") ?: "")
      }
    }
    val filter = IntentFilter("$packageName.E2E")
    if (Build.VERSION.SDK_INT >= 33) {
      registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
    } else {
      registerReceiver(receiver, filter)
    }
    e2eReceiver = receiver
  }

  /** A magenta native view with card-number text: must never reach a replay. */
  private class NativeBoxFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
      val text = TextView(context).apply {
        setBackgroundColor(Color.MAGENTA)
        setTextColor(Color.WHITE)
        textSize = 20f
        gravity = Gravity.CENTER
        setText("NATIVE 4111 1111 1111 1111")
      }
      return object : PlatformView {
        override fun getView(): View = text
        override fun dispose() {}
      }
    }
  }

  /** A WebView showing a magenta page with a secret on it. */
  private class WebViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
      val web = WebView(context).apply {
        setBackgroundColor(Color.MAGENTA)
        loadDataWithBaseURL(
          null,
          "<html><body style=\"margin:0;background:#ff00ff;color:#fff;" +
            "font:bold 24px sans-serif\">WEBVIEW SECRET 4111</body></html>",
          "text/html",
          "utf-8",
          null,
        )
      }
      return object : PlatformView {
        override fun getView(): View = web
        override fun dispose() { web.destroy() }
      }
    }
  }
}
