package com.replayfy.flutter

import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The bridge's stopApplicationAndUploadData. Robolectric runs the test on the
 *  main Looper's thread, the platform thread every method-channel handler runs
 *  on in an app, with that Looper paused: what is posted to it runs only when
 *  the test idles it, and its clock moves only when the test advances it. */
@RunWith(RobolectricTestRunner::class)
// Robolectric runs SDK 35 only on JDK 21; the toolchain here is JDK 17.
@Config(sdk = [34])
class ReplayfyFlutterPluginTest {

  /** Records the replies a handler sends and the thread each came from. A
   *  second reply throws, as Flutter's own reply object does. */
  private class Reply : MethodChannel.Result {
    @Volatile var successes = 0
    @Volatile var errors = 0
    @Volatile var thread: Thread? = null

    override fun success(result: Any?) { record(); successes++ }
    override fun error(code: String, message: String?, details: Any?) { record(); errors++ }
    override fun notImplemented() = throw AssertionError("not implemented")

    private fun record() {
      if (count > 0) throw IllegalStateException("Reply already submitted")
      thread = Thread.currentThread()
    }

    val count get() = successes + errors
  }

  private val mainThread: Thread = Looper.getMainLooper().thread
  private val mainLooper get() = shadowOf(Looper.getMainLooper())

  private fun plugin(stop: (onSettled: () -> Unit) -> Unit, waitMs: Long = 5_000) =
    ReplayfyFlutterPlugin(stopThenAwaitUploads = stop, uploadWaitMs = waitMs)

  private fun ReplayfyFlutterPlugin.stopApplicationAndUploadData(reply: Reply) =
    onMethodCall(MethodCall("stopApplicationAndUploadData", null), reply)

  /** Run what other threads post to the main Looper until [reply] arrives,
   *  without moving its clock (so no timeout fires). */
  private fun awaitReply(reply: Reply) {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
    while (reply.count == 0 && System.nanoTime() < deadline) {
      mainLooper.idle()
      Thread.sleep(10)
    }
  }

  @Test
  fun stopsOnTheMainThreadBeforeTheNextCallIsHandled() {
    // Method-channel calls are handled one after another on the main thread,
    // in the order Dart sent them. A `start` or `startNewSession` sent right
    // behind this call must find the session already stopped: otherwise
    // ReplayCore.start ignores it (still started), and the stop, landing
    // late, ends the session it was meant to begin.
    assertSame("the test runs on the main thread", mainThread, Thread.currentThread())
    val stoppedOn = AtomicReference<Thread>()
    val plugin = plugin(stop = { stoppedOn.set(Thread.currentThread()) })

    plugin.stopApplicationAndUploadData(Reply())

    assertSame("stopped, on the main thread, by the time the handler returned",
      mainThread, stoppedOn.get())
  }

  @Test
  fun repliesOnTheMainThreadOnceTheUploadsSettle_withoutHoldingIt() {
    val onSettled = AtomicReference<() -> Unit>()
    val plugin = plugin(stop = { onSettled.set(it) })
    val reply = Reply()

    plugin.stopApplicationAndUploadData(reply)

    // The handler returned with the uploads still in flight.
    mainLooper.idle()
    assertEquals("no reply before the uploads settle", 0, reply.count)

    // The engine reports the uploads settled from one of its own threads.
    Thread { onSettled.get().invoke() }.apply { start(); join() }
    awaitReply(reply)
    assertEquals(1, reply.successes)
    assertSame("channel replies belong on the main thread", mainThread, reply.thread)

    // The timeout that was armed doesn't reply a second time.
    mainLooper.idleFor(Duration.ofSeconds(6))
    assertEquals(1, reply.count)
  }

  @Test
  fun repliesWhenNothingWasRecording() {
    // ReplayCore.stop settles at once, on the calling thread, with no session.
    val plugin = plugin(stop = { onSettled -> onSettled() })
    val reply = Reply()

    plugin.stopApplicationAndUploadData(reply)

    awaitReply(reply)
    assertEquals(1, reply.successes)
    mainLooper.idleFor(Duration.ofSeconds(6))
    assertEquals(1, reply.count)
  }

  @Test
  fun theRegistrantsPluginRepliesThroughTheEngine() {
    // The no-argument constructor Flutter's registrant uses, wired to the
    // real ReplayCore.stop: with no session it settles at once.
    val reply = Reply()

    ReplayfyFlutterPlugin().stopApplicationAndUploadData(reply)

    awaitReply(reply)
    assertEquals(1, reply.successes)
    assertSame(mainThread, reply.thread)
  }

  @Test
  fun repliesAtTheTimeoutWhenTheUploadsDontSettle() {
    val onSettled = AtomicReference<() -> Unit>()
    val plugin = plugin(stop = { onSettled.set(it) }, waitMs = 5_000)
    val reply = Reply()

    plugin.stopApplicationAndUploadData(reply)

    mainLooper.idleFor(Duration.ofMillis(4_999))
    assertEquals("still waiting for the uploads", 0, reply.count)
    mainLooper.idleFor(Duration.ofMillis(1))
    assertEquals(1, reply.successes)
    assertSame(mainThread, reply.thread)

    // The uploads settling later doesn't reply again (that would throw).
    onSettled.get().invoke()
    mainLooper.idle()
    assertEquals(1, reply.count)
  }

  @Test
  fun reportsAFailedStopAsOneError() {
    // A stop that settles (nothing recording) and then throws: one reply, the
    // error, never a success after it.
    val plugin = plugin(stop = { onSettled -> onSettled(); throw IllegalStateException("boom") })
    val reply = Reply()

    plugin.stopApplicationAndUploadData(reply)

    awaitReply(reply)
    assertEquals(1, reply.errors)
    assertSame(mainThread, reply.thread)
    mainLooper.idleFor(Duration.ofSeconds(6))
    assertEquals(0, reply.successes)
  }

  @Test
  fun overlappingCallsStopInOrderAndEachGetsOneReply() {
    val stops = mutableListOf<String>()
    val pending = mutableListOf<() -> Unit>()
    val plugin = plugin(stop = { onSettled -> stops.add("stop"); pending.add(onSettled) })
    val first = Reply()
    val second = Reply()

    plugin.stopApplicationAndUploadData(first)
    plugin.stopApplicationAndUploadData(second)

    assertEquals("each stop ran in its own call, in turn", listOf("stop", "stop"), stops)
    pending.forEach { it() }
    awaitReply(first)
    awaitReply(second)
    assertEquals(1, first.successes)
    assertEquals(1, second.successes)
  }
}
