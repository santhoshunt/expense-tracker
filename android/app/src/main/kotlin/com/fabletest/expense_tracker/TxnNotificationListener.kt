package com.fabletest.expense_tracker

import android.app.Notification
import android.content.Context
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/**
 * Captures bank-alert notifications from messaging apps and buffers them for
 * the next import run.
 *
 * Why: RCS business messages (e.g. "Yes Bank" verified chats) live in Google
 * Messages' private database — there is no public API to read them, so the
 * SMS content-provider import never sees them. Their *notifications* are
 * observable, though, which is the only supported capture path.
 *
 * The buffer lives in SharedPreferences (same process as the activity) and is
 * drained by the Flutter side during imports. Capture is best-effort: only
 * texts containing a currency token are kept, and a persistent seen-set stops
 * MessagingStyle history reposts from re-adding drained messages.
 */
class TxnNotificationListener : NotificationListenerService() {

    companion object {
        private const val PREFS = "txn_notif_buffer"
        private const val KEY_MESSAGES = "messages"
        private const val KEY_SEEN = "seen_hashes"
        private const val KEY_LAST_CAPTURE = "last_capture_millis"
        private const val MAX_BUFFER = 300
        private const val MAX_SEEN = 800

        // Diagnostics: each stage of the capture chain leaves a trace, so a
        // "nothing imported" report can be pinned to the exact dead stage
        // (never bound / no events delivered / package not watched / text
        // redacted or no money token / dedupe).
        private const val KEY_CONNECTED_AT = "diag_connected_at"
        private const val KEY_DISCONNECTED_AT = "diag_disconnected_at"
        private const val KEY_EVENTS_TOTAL = "diag_events_total"
        private const val KEY_EVENTS_WATCHED = "diag_events_watched"
        private const val KEY_EVENTS_MONEY = "diag_events_money"
        private const val KEY_STORED_TOTAL = "diag_stored_total"
        private const val KEY_LAST_SAMPLE = "diag_last_sample"

        /** Messaging apps whose notifications carry SMS/RCS message bodies. */
        private val WATCHED = setOf(
            "com.google.android.apps.messaging",  // Google Messages (RCS primary)
            "com.samsung.android.messaging",       // Samsung Messages
            "com.android.messaging",               // AOSP stock (Pixel, bare Android)
            "com.android.mms",                     // Pre-Lollipop stock / MIUI
            "com.oneplus.mms",                     // OnePlus
        )

        private val MONEY = Regex("""(?i)(?:rs\.?|inr|₹)\s*[\d,]+""")

        /** Total-events counter kept in memory and folded into prefs with the
         * next real write: a disk write per device notification runs on the
         * listener's main-thread callback and risks the system unbinding the
         * service as unresponsive — which silently kills capture. */
        @Volatile
        private var pendingTotalEvents = 0L

        fun noteEvent() {
            pendingTotalEvents++
        }

        private fun flushTotalEvents(context: Context) {
            val pending = pendingTotalEvents
            if (pending == 0L) return
            pendingTotalEvents = 0L
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.edit()
                .putLong(
                    KEY_EVENTS_TOTAL,
                    prefs.getLong(KEY_EVENTS_TOTAL, 0L) + pending
                )
                .apply()
        }

        private fun hashOf(sender: String, body: String) =
            "${sender}|${body}".hashCode().toString()

        @Synchronized
        fun store(context: Context, sender: String, body: String, timeMillis: Long) {
            flushTotalEvents(context)
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

            // Seen-set survives drains: Google Messages reposts the whole
            // conversation history in each MessagingStyle notification, which
            // would otherwise re-buffer already-imported messages.
            val hash = hashOf(sender, body)
            val seen = LinkedHashSet(prefs.getStringSet(KEY_SEEN, emptySet())!!)
            if (hash in seen) return
            seen.add(hash)
            while (seen.size > MAX_SEEN) seen.remove(seen.first())

            val arr = JSONArray(prefs.getString(KEY_MESSAGES, "[]"))
            arr.put(
                JSONObject()
                    .put("address", sender)
                    .put("body", body)
                    .put("date", timeMillis)
            )
            while (arr.length() > MAX_BUFFER) {
                // The evicted (oldest, never-drained) message must also leave
                // the seen-set, or a repost of it can never be recaptured.
                val evicted = arr.getJSONObject(0)
                seen.remove(
                    hashOf(evicted.getString("address"), evicted.getString("body"))
                )
                arr.remove(0)
            }

            prefs.edit()
                .putString(KEY_MESSAGES, arr.toString())
                .putStringSet(KEY_SEEN, seen)
                .putLong(KEY_LAST_CAPTURE, System.currentTimeMillis())
                .putLong(KEY_STORED_TOTAL, prefs.getLong(KEY_STORED_TOTAL, 0L) + 1)
                .apply()
        }

        @Synchronized
        private fun bump(context: Context, key: String) {
            flushTotalEvents(context)
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.edit().putLong(key, prefs.getLong(key, 0L) + 1).apply()
        }

        @Synchronized
        private fun putDiag(context: Context, key: String, value: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString(key, value).apply()
        }

        @Synchronized
        private fun putDiagTime(context: Context, key: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putLong(key, System.currentTimeMillis()).apply()
        }

        /** Full capture-chain state for the in-app diagnostics dialog. */
        @Synchronized
        fun diagnostics(context: Context): Map<String, Any?> {
            flushTotalEvents(context)
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val buffered = JSONArray(prefs.getString(KEY_MESSAGES, "[]")).length()
            return mapOf(
                "connectedAt" to prefs.getLong(KEY_CONNECTED_AT, 0L),
                "disconnectedAt" to prefs.getLong(KEY_DISCONNECTED_AT, 0L),
                "eventsTotal" to prefs.getLong(KEY_EVENTS_TOTAL, 0L),
                "eventsWatched" to prefs.getLong(KEY_EVENTS_WATCHED, 0L),
                "eventsMoney" to prefs.getLong(KEY_EVENTS_MONEY, 0L),
                "storedTotal" to prefs.getLong(KEY_STORED_TOTAL, 0L),
                "lastCapture" to prefs.getLong(KEY_LAST_CAPTURE, 0L),
                "bufferSize" to buffered,
                "lastSample" to prefs.getString(KEY_LAST_SAMPLE, null),
            )
        }

        /** Millis of the most recent capture ever (survives drains); 0 when
         * nothing has been captured yet. Diagnostic for the settings tile. */
        fun lastCaptureMillis(context: Context): Long =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getLong(KEY_LAST_CAPTURE, 0L)

        /** Returns all buffered messages and clears the buffer. */
        @Synchronized
        fun drain(context: Context): List<Map<String, Any?>> {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val arr = JSONArray(prefs.getString(KEY_MESSAGES, "[]"))
            val out = mutableListOf<Map<String, Any?>>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                out.add(
                    mapOf(
                        "address" to o.getString("address"),
                        "body" to o.getString("body"),
                        "date" to o.getLong("date")
                    )
                )
            }
            prefs.edit().remove(KEY_MESSAGES).apply()
            return out
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        putDiagTime(applicationContext, KEY_CONNECTED_AT)
        // When the service first binds (or rebinds after a restart), Android
        // does NOT replay onNotificationPosted for already-active notifications.
        // Walk them explicitly so messages posted while the service was not
        // running (or before access was granted) are not missed.
        try {
            activeNotifications?.forEach { onNotificationPosted(it) }
        } catch (_: Exception) {
            // SecurityException can occur if the binder is not yet fully ready;
            // safe to ignore — those notifications will arrive via normal callbacks.
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        putDiagTime(applicationContext, KEY_DISCONNECTED_AT)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        // In-memory count only — a prefs write here would run for EVERY
        // notification on the device, on the listener's main thread.
        noteEvent()
        if (sbn.packageName !in WATCHED) return
        val n = sbn.notification ?: return
        // Group summaries duplicate their children's content.
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        bump(applicationContext, KEY_EVENTS_WATCHED)

        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""

        // MessagingStyle (Google Messages): each entry is one message with its
        // own text/time/sender — capture individually so multi-unread threads
        // don't collapse into one blob.
        val parcelables = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (parcelables != null && parcelables.isNotEmpty()) {
            var newestText: String? = null
            for (p in parcelables) {
                val b = p as? Bundle ?: continue
                val text = b.getCharSequence("text")?.toString() ?: continue
                newestText = text
                if (!MONEY.containsMatchIn(text)) continue
                bump(applicationContext, KEY_EVENTS_MONEY)
                val sender = (b.getCharSequence("sender")?.toString() ?: "").ifBlank { title }
                if (sender.isBlank()) continue
                val time = b.getLong("time", 0L)
                store(applicationContext, sender, text, if (time > 0) time else sbn.postTime)
            }
            // Sample the newest message so a "0 captured" report reveals what
            // the listener actually receives — e.g. an Android 15+ "sensitive
            // content hidden" placeholder instead of the real alert text.
            if (newestText != null) recordSample(title, newestText)
            return
        }

        // Plain notification fallback.
        val text = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: return
        recordSample(title, text)
        if (title.isBlank() || !MONEY.containsMatchIn(text)) return
        bump(applicationContext, KEY_EVENTS_MONEY)
        store(applicationContext, title, text, sbn.postTime)
    }

    /** Diagnostics sample. Content is persisted (and later shown in the
     * diagnostics dialog) ONLY for money-shaped text — these are watched
     * messaging apps, so anything else may be a personal conversation or a
     * 2FA code, which must never sit in plaintext prefs (or ride a backup).
     * Non-money messages leave a content-free marker instead, which still
     * answers the diagnostic question ("is the listener receiving at all?"). */
    private fun recordSample(sender: String, text: String) {
        val sample = if (MONEY.containsMatchIn(text)) {
            "$sender: ${text.take(80)}"
        } else {
            "$sender: (message received — no ₹ amount, content not stored)"
        }
        putDiag(applicationContext, KEY_LAST_SAMPLE, sample)
    }
}
