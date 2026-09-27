package com.fabletest.expense_tracker

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.work.BackoffPolicy
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

/**
 * SMS import with the app closed. The Auto-import setting drives it
 * ([configure]): Every SMS switches on [SmsArrivalReceiver], Daily and
 * Weekly book a 6-hour periodic check, and each run is a [SmsImportWorker].
 *
 * The Dart ledger (FinanceProvider) rewrites the whole store from memory,
 * so only one engine may hold it at a time. A run therefore goes to the
 * app's own engine when it is alive ([liveChannel]) and starts a headless
 * one only when it is not; the app's `main()` calls awaitIdle first, so an
 * app opened mid-run waits for the headless engine to finish.
 *
 * Every field is touched on the main thread only.
 */
object BackgroundImport {
    const val CHANNEL = "expense_tracker/background"
    const val KEY_TRIGGER = "trigger"
    private const val PERIODIC_WORK = "sms_import_periodic"
    private const val NOW_WORK = "sms_import_now"

    /** Waits for the SMS app to write the message into the inbox. */
    private const val SMS_DELAY_SECONDS = 30L

    /** An app kept waiting on a stuck headless run opens anyway. */
    private const val IDLE_WAIT_MILLIS = 60_000L

    private val main = Handler(Looper.getMainLooper())

    /** Background channels of the app's live engines, newest last. Usually
     * one; a second MainActivity instance can briefly add another. */
    private val liveChannels = mutableListOf<MethodChannel>()

    /** The engine that owns the ledger now, if the app is running. */
    val liveChannel: MethodChannel?
        get() = liveChannels.lastOrNull()

    fun addLive(channel: MethodChannel) {
        liveChannels.remove(channel)
        liveChannels += channel
    }

    fun removeLive(channel: MethodChannel) {
        liveChannels.remove(channel)
    }

    /** The headless engine of the run in progress, if any. */
    var headless: FlutterEngine? = null
        private set
    private val idleWaiters = mutableListOf<MethodChannel.Result>()

    fun configure(context: Context, mode: String?) {
        val wm = WorkManager.getInstance(context)
        if (mode == "daily" || mode == "weekly") {
            wm.enqueueUniquePeriodicWork(
                PERIODIC_WORK,
                ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequest.Builder(SmsImportWorker::class.java, 6, TimeUnit.HOURS)
                    .setInputData(trigger("periodic"))
                    .build()
            )
        } else {
            wm.cancelUniqueWork(PERIODIC_WORK)
        }
        val everySms = mode == "everySms"
        if (!everySms) wm.cancelUniqueWork(NOW_WORK)
        context.packageManager.setComponentEnabledSetting(
            ComponentName(context, SmsArrivalReceiver::class.java),
            if (everySms) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
    }

    /** True while Auto-import is Every SMS (its receiver is switched on). */
    fun everySmsOn(context: Context): Boolean =
        context.packageManager.getComponentEnabledSetting(
            ComponentName(context, SmsArrivalReceiver::class.java)
        ) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED

    /** A new SMS: import it once the SMS app has stored it. Appended, so
     * a message arriving during a run gets a run of its own. */
    fun enqueueNow(context: Context) {
        WorkManager.getInstance(context).enqueueUniqueWork(
            NOW_WORK,
            ExistingWorkPolicy.APPEND_OR_REPLACE,
            OneTimeWorkRequest.Builder(SmsImportWorker::class.java)
                .setInitialDelay(SMS_DELAY_SECONDS, TimeUnit.SECONDS)
                .setBackoffCriteria(BackoffPolicy.LINEAR, 30, TimeUnit.SECONDS)
                .setInputData(trigger("sms"))
                .build()
        )
    }

    private fun trigger(name: String) = Data.Builder().putString(KEY_TRIGGER, name).build()

    /** Answers once no headless engine holds the ledger, or after a minute. */
    fun awaitIdle(result: MethodChannel.Result) {
        if (headless == null) {
            result.success(null)
            return
        }
        idleWaiters += result
        main.postDelayed({
            // Still running after a minute: stop it rather than let the app
            // load the ledger beside it. Its unsaved work is read again next
            // run (the SMS marker and the notification ack only move after a
            // save).
            if (result in idleWaiters) headless?.let { stopHeadless(it) }
        }, IDLE_WAIT_MILLIS)
    }

    fun startedHeadless(engine: FlutterEngine) {
        headless = engine
    }

    /** Destroys [engine] if it is still the running one and releases every
     * app waiting to load. */
    fun stopHeadless(engine: FlutterEngine) {
        if (headless !== engine) return
        headless = null
        try {
            engine.destroy()
        } catch (_: Exception) {
            // Already torn down.
        }
        val waiting = idleWaiters.toList()
        idleWaiters.clear()
        for (w in waiting) w.success(null)
    }
}
