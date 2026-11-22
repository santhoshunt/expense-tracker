package com.fabletest.expense_tracker

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.provider.Telephony
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * The `expense_tracker/sms` methods that need no Activity: reading the SMS
 * inbox, the notification-capture buffer and the widget refreshes. Both the
 * app's engine (through MainActivity) and the headless background-import
 * engine (SmsImportWorker) answer through this, so an import behaves the
 * same with the app open or closed. [engine] is the one whose channel calls
 * this; the bridge closes its inbox reader when that engine is destroyed.
 */
class SmsBridge(private val context: Context, engine: FlutterEngine) {
    /** The inbox query reads up to 50,000 rows. On the main thread that
     * stopped touch input and, with Flutter's UI and platform threads merged,
     * every frame, so it runs here, one query at a time per engine. */
    private val reader = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** Set when the engine is destroyed. Its Dart side is gone then, so a
     * query not yet started is skipped and a finished one is not delivered. */
    @Volatile
    private var disposed = false

    init {
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = Unit

            override fun onEngineWillDestroy() {
                disposed = true
                // shutdown, not shutdownNow: a query already running ends
                // normally and closes its cursor, and the thread then exits.
                reader.shutdown()
            }
        })
    }

    companion object {
        /** Rows read per provider query; pages continue until the window is
         * exhausted so long scan ranges are not silently truncated. */
        private const val PAGE_SIZE = 2000

        /** Sanity ceiling across all pages. */
        private const val MAX_MESSAGES = 50_000

        fun hasSmsPermission(context: Context): Boolean =
            context.checkSelfPermission(Manifest.permission.READ_SMS) ==
                PackageManager.PERMISSION_GRANTED

        /** Entries are flattened "pkg/cls" component strings — parse and
         * compare the package exactly. A startsWith check matched any package
         * with this one as a prefix, reporting "capture on" while the buffer
         * stayed empty. */
        fun hasNotificationAccess(context: Context): Boolean =
            Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners"
            )
                ?.split(":")
                ?.any {
                    ComponentName.unflattenFromString(it)?.packageName ==
                        context.packageName
                } == true
    }

    /** Answers [call] and returns true, or returns false for a method only
     * an Activity can serve (permission dialogs, settings pages, icons). */
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "hasPermission" -> result.success(hasSmsPermission(context))
            "querySms" -> {
                if (!hasSmsPermission(context)) {
                    result.error("NO_PERMISSION", "READ_SMS not granted", null)
                } else {
                    val since = call.argument<Number>("sinceMillis")?.toLong() ?: 0L
                    val until = call.argument<Number>("untilMillis")?.toLong()
                    queryOffMain(since, until, result)
                }
            }
            "notifHasAccess" -> result.success(hasNotificationAccess(context))
            "notifPeek" -> result.success(TxnNotificationListener.peek(context))
            "notifAck" -> {
                val maxSeq = call.argument<Number>("maxSeq")?.toLong() ?: -1L
                TxnNotificationListener.ack(context, maxSeq)
                result.success(null)
            }
            "notifLastCapture" -> result.success(
                TxnNotificationListener.lastCaptureMillis(context)
            )
            "notifDiagnostics" -> result.success(
                TxnNotificationListener.diagnostics(context)
            )
            // Home-screen widgets: the Dart side has written a fresh
            // snapshot to prefs — re-render every instance.
            "updateBudgetWidgets" -> {
                BudgetWidgetProvider.refreshAll(context)
                result.success(null)
            }
            "updateHomeWidgets" -> {
                HomeWidgets.refreshAll(context)
                result.success(null)
            }
            else -> return false
        }
        return true
    }

    /** Runs [queryInbox] on [reader] and answers [result] exactly once, back
     * on the main thread where every other answer on this channel is sent. */
    private fun queryOffMain(since: Long, until: Long?, result: MethodChannel.Result) {
        val task = Runnable {
            if (disposed) return@Runnable
            // queryInbox already turns provider errors into complete=false.
            // This catch is for anything else, such as running out of memory
            // building the list: escaping this thread would end the app and
            // leave the Dart call waiting with no timeout.
            val answer: Any = try {
                queryInbox(since, until)
            } catch (t: Throwable) {
                t
            }
            main.post {
                if (disposed) return@post
                if (answer is Throwable) {
                    result.error("QUERY_FAILED", answer.message, null)
                } else {
                    result.success(answer)
                }
            }
        }
        try {
            reader.execute(task)
        } catch (_: RejectedExecutionException) {
            // The engine was destroyed before this call could start.
            result.error("QUERY_FAILED", "SMS reader closed", null)
        }
    }

    /** Reads the whole (since, until) window newest-first, paging with a
     * moving upper-bound date cursor so large windows are not truncated.
     *
     * Returns {"messages": [...], "complete": bool}. `complete=false` means
     * the window was NOT fully read (hit [MAX_MESSAGES], or the provider
     * threw mid-scan, e.g. READ_SMS revoked) — the Dart side must then keep
     * its incremental-scan marker where it was, otherwise the unread tail is
     * skipped forever.
     *
     * Pages after the first use an inclusive upper bound with _ID-based
     * dedup: the old strict `<` silently and permanently dropped any message
     * sharing the boundary row's exact millisecond. The page loop also
     * checks capacity BEFORE consuming a row — `moveToNext()` first meant
     * row PAGE_SIZE+1 was consumed and discarded every page. */
    private fun queryInbox(sinceMillis: Long, untilMillis: Long?): Map<String, Any?> {
        val messages = mutableListOf<Map<String, Any?>>()
        val seenIds = HashSet<Long>()
        var upperBound = untilMillis ?: Long.MAX_VALUE
        var inclusiveUpper = false
        var complete = true
        try {
            while (true) {
                if (messages.size >= MAX_MESSAGES) {
                    complete = false
                    break
                }
                var pageRows = 0
                var newRows = 0
                var oldestInPage = upperBound
                context.contentResolver.query(
                    Telephony.Sms.Inbox.CONTENT_URI,
                    arrayOf(
                        Telephony.Sms._ID,
                        Telephony.Sms.ADDRESS,
                        Telephony.Sms.BODY,
                        Telephony.Sms.DATE
                    ),
                    "${Telephony.Sms.DATE} > ? AND " +
                        "${Telephony.Sms.DATE} ${if (inclusiveUpper) "<=" else "<"} ?",
                    arrayOf(sinceMillis.toString(), upperBound.toString()),
                    "${Telephony.Sms.DATE} DESC"
                )?.use { cursor ->
                    val idIdx = cursor.getColumnIndex(Telephony.Sms._ID)
                    val addressIdx = cursor.getColumnIndex(Telephony.Sms.ADDRESS)
                    val bodyIdx = cursor.getColumnIndex(Telephony.Sms.BODY)
                    val dateIdx = cursor.getColumnIndex(Telephony.Sms.DATE)
                    if (idIdx < 0 || dateIdx < 0) {
                        complete = false
                        return@use
                    }
                    while (pageRows < PAGE_SIZE &&
                        messages.size < MAX_MESSAGES && cursor.moveToNext()
                    ) {
                        pageRows++
                        val date = cursor.getLong(dateIdx)
                        oldestInPage = date
                        if (!seenIds.add(cursor.getLong(idIdx))) continue
                        newRows++
                        messages.add(
                            mapOf(
                                "address" to
                                    (if (addressIdx >= 0) cursor.getString(addressIdx) else null),
                                "body" to
                                    (if (bodyIdx >= 0) cursor.getString(bodyIdx) else null),
                                "date" to date
                            )
                        )
                    }
                }
                // Short page → window exhausted. Zero NEW rows on a full
                // page can only mean >PAGE_SIZE messages share one
                // millisecond — bail rather than loop forever.
                if (pageRows < PAGE_SIZE) break
                if (newRows == 0) {
                    complete = false
                    break
                }
                upperBound = oldestInPage
                inclusiveUpper = true
            }
        } catch (_: Exception) {
            // SecurityException (permission revoked mid-scan) or an OEM
            // provider quirk: return what was read, flagged incomplete.
            complete = false
        }
        return mapOf("messages" to messages, "complete" to complete)
    }
}
