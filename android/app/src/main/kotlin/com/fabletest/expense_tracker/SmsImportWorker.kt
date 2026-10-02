package com.fabletest.expense_tracker

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * One background import (see [BackgroundImport]). The app's live engine
 * runs it when there is one; otherwise a headless engine starts on the
 * Dart entry point `backgroundImportMain` (lib/main.dart), imports, writes
 * the widget snapshots, and reports `finished`.
 */
class SmsImportWorker(context: Context, params: WorkerParameters) :
    Worker(context, params) {

    companion object {
        /** A run that has not finished by then is stopped and retried. */
        private const val TIMEOUT_SECONDS = 120L
    }

    private val main = Handler(Looper.getMainLooper())

    override fun doWork(): Result {
        val trigger = inputData.getString(BackgroundImport.KEY_TRIGGER) ?: "periodic"
        val enqueuedAt = inputData.getLong(BackgroundImport.KEY_ENQUEUED_AT, 0L)
        // This run reads every SMS so far: a new one starts a fresh wait.
        BackgroundImport.runStarted(applicationContext)
        // An earlier run in the chain already read this alert.
        if (BackgroundImport.isCovered(applicationContext, trigger, enqueuedAt)) {
            return Result.success()
        }
        val startedAt = System.currentTimeMillis()
        val latch = CountDownLatch(1)
        var outcome: Result = Result.retry()
        // Whether the import actually ran to the end: a run that failed
        // still succeeds for WorkManager (no retry loop) but must not mark
        // the alerts behind it as covered.
        var ranOk = false
        var engine: FlutterEngine? = null
        val done = { r: Result, ok: Boolean ->
            outcome = r
            ranOk = ok
            latch.countDown()
        }
        main.post {
            try {
                engine = run(trigger, done)
            } catch (e: Exception) {
                done(Result.retry(), false)
            }
        }
        if (!latch.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
            main.post { engine?.let { BackgroundImport.stopHeadless(it) } }
            return Result.retry()
        }
        if (ranOk) BackgroundImport.recordSuccess(applicationContext, trigger, startedAt)
        return outcome
    }

    /** On the main thread. Returns the headless engine it started, if any. */
    private fun run(trigger: String, done: (Result, Boolean) -> Unit): FlutterEngine? {
        val live = BackgroundImport.liveChannel
        if (live != null) {
            live.invokeMethod("runImport", trigger, object : MethodChannel.Result {
                override fun success(result: Any?) = when (result) {
                    "busy" -> done(Result.retry(), false)
                    "failed" -> done(Result.success(), false)
                    else -> done(Result.success(), true)
                }

                override fun error(code: String, message: String?, details: Any?) =
                    done(Result.retry(), false)

                override fun notImplemented() = done(Result.retry(), false)
            })
            return null
        }
        // Another headless run is still going: it reads the same inbox.
        if (BackgroundImport.headless != null) {
            done(Result.retry(), false)
            return null
        }

        val context = applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)
        val engine = FlutterEngine(context)
        BackgroundImport.startedHeadless(engine)
        try {
            return startHeadless(engine, trigger, done)
        } catch (e: Exception) {
            // Never leave the process marked busy with a dead engine.
            BackgroundImport.stopHeadless(engine)
            throw e
        }
    }

    private fun startHeadless(
        engine: FlutterEngine,
        trigger: String,
        done: (Result, Boolean) -> Unit,
    ): FlutterEngine {
        val context = applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        var finished = false
        val finish = { r: Result, ok: Boolean ->
            if (!finished) {
                finished = true
                BackgroundImport.stopHeadless(engine)
                done(r, ok)
            }
        }

        val sms = SmsBridge(context)
        MethodChannel(engine.dartExecutor.binaryMessenger, "expense_tracker/sms")
            .setMethodCallHandler { call, result ->
                when {
                    // No Activity, so no dialog: answer from what is granted.
                    call.method == "requestPermission" -> result.success(
                        if (SmsBridge.hasSmsPermission(context)) "granted" else "denied"
                    )
                    sms.handle(call, result) -> Unit
                    else -> result.notImplemented()
                }
            }
        MethodChannel(engine.dartExecutor.binaryMessenger, BackgroundImport.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeTrigger" -> result.success(trigger)
                    "awaitIdle", "configure" -> result.success(null)
                    "finished" -> {
                        val ok = call.argument<Boolean>("ok") ?: false
                        result.success(null)
                        // After the reply is sent: destroying the engine
                        // inside its own call would drop the answer.
                        main.post { finish(Result.success(), ok) }
                    }
                    else -> result.notImplemented()
                }
            }
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundImportMain")
        )
        return engine
    }
}
