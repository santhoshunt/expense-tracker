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
import androidx.work.WorkInfo
import androidx.work.WorkManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
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
 * Every field is touched on the main thread only. Enqueueing ([enqueueNow])
 * runs on its own executor and keeps its state in SharedPreferences, which
 * the worker thread also clears.
 */
object BackgroundImport {
    const val CHANNEL = "expense_tracker/background"
    const val KEY_TRIGGER = "trigger"
    const val KEY_ENQUEUED_AT = "enqueued_at"

    /** Triggers: a new SMS, and an alert captured from a notification. */
    const val TRIGGER_SMS = "sms"
    const val TRIGGER_NOTIF = "notif"

    /** Start time of the last SMS or notification run that finished. */
    private const val PREFS = "background_import"
    private const val KEY_LAST_OK_START = "last_ok_start"
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
        if (!everySms) {
            wm.cancelUniqueWork(NOW_WORK)
            clearWaiting(context)
        }
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

    /** Reads WorkManager's state and enqueues off the main thread, one call
     * at a time. A run can still start between the read and the enqueue
     * and be replaced mid-import; nothing is lost, since the SMS marker and
     * the notification ack only move after a save, so the replacing run
     * reads the same alerts again. */
    private val enqueuer = Executors.newSingleThreadExecutor()

    /** Prefs key: when the SMS run now waiting was first put off; absent
     * while none is. Stored, not held in memory: the app is often killed
     * between two SMS, and a reset cap would let a trickle wait forever.
     * Cleared when a run starts ([runStarted]) or the run is cancelled
     * ([configure]). */
    private const val KEY_WAITING_SINCE = "waiting_since"

    /** Longest a steady trickle of SMS (OTPs, promos) may keep putting off
     * the import by replacing the waiting run. */
    private const val MAX_DEBOUNCE_MILLIS = 120_000L

    /** A new SMS ([TRIGGER_SMS], run once the SMS app has stored it) or a
     * captured notification ([TRIGGER_NOTIF], already buffered, so no delay
     * of its own; queued behind a pending SMS run, it then usually finds
     * itself covered).
     *
     * An SMS with no run in progress replaces the run still waiting, so a
     * burst of alerts makes one run, 30 s after the last of them. During a
     * run it is appended, so an alert arriving mid-run gets a run of its
     * own; [isCovered] then skips the runs an earlier one did. [done] is
     * called once the work is enqueued, on the enqueue thread. */
    fun enqueueNow(context: Context, trigger: String, done: () -> Unit = {}) {
        val app = context.applicationContext
        enqueuer.execute {
            try {
                enqueue(app, trigger)
            } finally {
                done()
            }
        }
    }

    private fun enqueue(context: Context, trigger: String) {
        val request = OneTimeWorkRequest.Builder(SmsImportWorker::class.java)
            .setBackoffCriteria(BackoffPolicy.LINEAR, 30, TimeUnit.SECONDS)
            .setInputData(
                Data.Builder()
                    .putString(KEY_TRIGGER, trigger)
                    .putLong(KEY_ENQUEUED_AT, System.currentTimeMillis())
                    .build()
            )
        if (trigger == TRIGGER_SMS) request.setInitialDelay(SMS_DELAY_SECONDS, TimeUnit.SECONDS)
        val wm = WorkManager.getInstance(context)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val since = prefs.getLong(KEY_WAITING_SINCE, 0L)
        // Replaced only for a while: past the cap the waiting run keeps its
        // time and this one queues behind it.
        val replace = trigger == TRIGGER_SMS &&
            (since == 0L || now - since in 0 until MAX_DEBOUNCE_MILLIS) &&
            !runInProgress(wm)
        if (replace && since == 0L) prefs.edit().putLong(KEY_WAITING_SINCE, now).apply()
        val policy = if (replace) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.APPEND_OR_REPLACE
        wm.enqueueUniqueWork(NOW_WORK, policy, request.build())
    }

    /** A run began: the next SMS starts a fresh wait. */
    fun runStarted(context: Context) = clearWaiting(context)

    private fun clearWaiting(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(KEY_WAITING_SINCE).apply()
    }

    /** Whether a run of [NOW_WORK] is executing now. Unknown counts as yes:
     * appending, as before, never cancels a run. */
    private fun runInProgress(wm: WorkManager): Boolean = try {
        wm.getWorkInfosForUniqueWork(NOW_WORK).get()
            .any { it.state == WorkInfo.State.RUNNING }
    } catch (_: Exception) {
        true
    }

    /** True when a run that started after this alert was readable has
     * already finished: an SMS 30 s after it arrived (the inbox write), a
     * notification capture as soon as it was buffered. One bank alert
     * usually arrives both ways a second apart; this makes it one run. */
    fun isCovered(context: Context, trigger: String?, enqueuedAt: Long): Boolean {
        if (enqueuedAt <= 0) return false
        val readableAt = when (trigger) {
            TRIGGER_SMS -> enqueuedAt + SMS_DELAY_SECONDS * 1000
            TRIGGER_NOTIF -> enqueuedAt
            else -> return false
        }
        val lastOk = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(KEY_LAST_OK_START, 0L)
        // A value from the future (the clock ran ahead, then was corrected)
        // would otherwise skip every alert until real time caught up.
        return lastOk >= readableAt && lastOk <= System.currentTimeMillis()
    }

    /** Records a finished SMS or notification run that began at [startedAt]. */
    fun recordSuccess(context: Context, trigger: String?, startedAt: Long) {
        if (trigger != TRIGGER_SMS && trigger != TRIGGER_NOTIF) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getLong(KEY_LAST_OK_START, 0L)
        if (startedAt > stored || stored > System.currentTimeMillis()) {
            prefs.edit().putLong(KEY_LAST_OK_START, startedAt).apply()
        }
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
