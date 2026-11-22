package com.fabletest.expense_tracker

import android.app.Notification
import android.content.Context
import android.content.SharedPreferences
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
 * The buffer lives in SharedPreferences (same process as the activity). The
 * Flutter side reads it during imports ([peek]) and clears what it saved
 * ([ack]). Capture is best-effort: only
 * texts containing an amount are kept, and a persistent seen-set stops
 * MessagingStyle history reposts from re-adding drained messages.
 */
class TxnNotificationListener : NotificationListenerService() {

    companion object {
        private const val PREFS = "txn_notif_buffer"
        private const val KEY_MESSAGES = "messages"
        /** The seen-set up to v2.3.1: a string set, which SharedPreferences
         * keeps without order. Read once, as the start of [KEY_SEEN_ORDERED],
         * and removed with the first write of that. */
        private const val KEY_SEEN = "seen_hashes"

        /** The seen-set as a JSON array, oldest first, so trimming drops the
         * oldest hashes rather than arbitrary ones. */
        private const val KEY_SEEN_ORDERED = "seen_hashes_ordered"
        private const val KEY_LAST_CAPTURE = "last_capture_millis"

        /** Numbers each buffered message, so an import can clear exactly the
         * ones it saved ([ack]) and keep any that arrived meanwhile. */
        private const val KEY_NEXT_SEQ = "next_seq"
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

        // At least every amount the Dart parser reads: "Rs:354.00",
        // "INR.5000.00", the paise form "Rs..50" and SBI's unprefixed
        // "debited by 150.0". A message dropped here never reaches the import.
        private val MONEY =
            Regex("""(?i)(?:rs[.:]?|inr[.:]?|₹)\s*\.?\d|(?:debited|credited)\s+by\s+\d""")

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

        /** The seen hashes, oldest first. Before the ordered key exists, the
         * old unordered set is the start, so nothing seen is forgotten on
         * the upgrade. A damaged ordered value falls back the same way
         * (the old set is gone after the first write, so in practice it
         * starts empty), since a seen-set that can never be read would fail
         * every later alert. */
        private fun readSeen(prefs: SharedPreferences): LinkedHashSet<String> {
            val ordered = prefs.getString(KEY_SEEN_ORDERED, null)
            if (ordered != null) {
                try {
                    val arr = JSONArray(ordered)
                    return LinkedHashSet((0 until arr.length()).map { arr.optString(it) })
                } catch (_: Exception) {
                    // Falls through to the old set or an empty one.
                }
            }
            return LinkedHashSet(prefs.getStringSet(KEY_SEEN, null) ?: emptySet())
        }

        /** Writes [seen] in order and drops the old unordered key. */
        private fun SharedPreferences.Editor.putSeen(seen: Set<String>) =
            putString(KEY_SEEN_ORDERED, JSONArray(seen.toList()).toString())
                .remove(KEY_SEEN)

        private fun hashOf(sender: String, body: String) =
            "${sender}|${body}".hashCode().toString()

        /** A MessagingStyle entry's own time is the same in every history
         * repost, and differs for a second alert with the same text. */
        private fun hashOf(sender: String, body: String, messageTime: Long) =
            "${sender}|${body}|${messageTime}".hashCode().toString()

        /** [messageTime] is the MessagingStyle entry's own time, or 0 for a
         * plain notification, whose post time changes on every repost. */
        @Synchronized
        fun store(
            context: Context,
            sender: String,
            body: String,
            timeMillis: Long,
            messageTime: Long = 0L,
        ) {
            flushTotalEvents(context)
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

            // Seen-set survives drains: Google Messages reposts the whole
            // conversation history in each MessagingStyle notification, which
            // would otherwise re-buffer already-imported messages.
            val plainHash = hashOf(sender, body)
            val hash = if (messageTime > 0) hashOf(sender, body, messageTime) else plainHash
            val seen = readSeen(prefs)
            if (hash in seen) return
            if (hash != plainHash && plainHash in seen) {
                // Seen under the key without a time: a repost of a message
                // already captured. Keyed by time from here on.
                seen.remove(plainHash)
                seen.add(hash)
                prefs.edit().putSeen(seen).apply()
                return
            }
            seen.add(hash)
            while (seen.size > MAX_SEEN) seen.remove(seen.first())

            // A damaged buffer starts again empty: left as it is, it would
            // fail every later alert. What it held cannot be read anyway.
            val arr = readBuffer(prefs)
            val seq = prefs.getLong(KEY_NEXT_SEQ, 1L)
            arr.put(
                JSONObject()
                    .put("address", sender)
                    .put("body", body)
                    .put("date", timeMillis)
                    .put("seq", seq)
                    .put("key", hash)
            )
            while (arr.length() > MAX_BUFFER) {
                // The evicted (oldest, never-drained) message must also leave
                // the seen-set, or a repost of it can never be recaptured.
                // An entry that is not an object has no key to remove, and
                // must not stop the eviction.
                val evicted = arr.optJSONObject(0)
                if (evicted != null) {
                    seen.remove(
                        evicted.optString("key", "").ifEmpty {
                            hashOf(evicted.optString("address"), evicted.optString("body"))
                        }
                    )
                }
                arr.remove(0)
            }

            prefs.edit()
                .putString(KEY_MESSAGES, arr.toString())
                .putLong(KEY_NEXT_SEQ, seq + 1)
                .putSeen(seen)
                .putLong(KEY_LAST_CAPTURE, System.currentTimeMillis())
                .putLong(KEY_STORED_TOTAL, prefs.getLong(KEY_STORED_TOTAL, 0L) + 1)
                .apply()
            // Every SMS imports captured alerts as they arrive, like SMS.
            if (BackgroundImport.everySmsOn(context)) {
                BackgroundImport.enqueueNow(context, BackgroundImport.TRIGGER_NOTIF)
            }
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
            // What an import would get: a buffer that cannot be read counts
            // 0, as do entries [peek] skips.
            val arr = readBuffer(prefs)
            val buffered = (0 until arr.length()).count { i ->
                arr.optJSONObject(i)?.let { message(it) } != null
            }
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

        /** Every buffered message and the highest sequence number among
         * them. Nothing is removed: the import calls [ack] once its rows are
         * saved, so an import killed half-way reads them again next time. */
        @Synchronized
        fun peek(context: Context): Map<String, Any?> {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val arr = readBuffer(prefs)
            val out = mutableListOf<Map<String, Any?>>()
            var maxSeq = 0L
            for (i in 0 until arr.length()) {
                // An entry that cannot be read is skipped and adds nothing
                // to maxSeq, so the import never acknowledges past what it
                // was handed.
                val o = arr.optJSONObject(i) ?: continue
                val m = message(o) ?: continue
                // Messages buffered before sequence numbers count as 0.
                maxSeq = maxOf(maxSeq, o.optLong("seq", 0L))
                out.add(m)
            }
            return mapOf("messages" to out, "maxSeq" to maxSeq)
        }

        /** Removes the messages [peek] returned up to [maxSeq]; any captured
         * since then stay for the next import. An entry [peek] cannot read
         * is dropped too: it can never be delivered, and kept it would sit
         * in the buffer until evicted. */
        @Synchronized
        fun ack(context: Context, maxSeq: Long) {
            if (maxSeq < 0) return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val arr = readBuffer(prefs)
            val keep = JSONArray()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (message(o) == null) continue
                if (o.optLong("seq", 0L) > maxSeq) keep.put(o)
            }
            prefs.edit().putString(KEY_MESSAGES, keep.toString()).apply()
        }

        /** The stored buffer; empty when it cannot be parsed, since what it
         * held cannot be read anyway and [store] then starts it again. */
        private fun readBuffer(prefs: SharedPreferences): JSONArray = try {
            JSONArray(prefs.getString(KEY_MESSAGES, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }

        /** A buffered entry as [peek] hands it to Dart, or null when [o]
         * lacks a sender, a body or a date. */
        private fun message(o: JSONObject): Map<String, Any?>? =
            try {
                mapOf(
                    "address" to o.getString("address"),
                    "body" to o.getString("body"),
                    "date" to o.getLong("date")
                )
            } catch (_: Exception) {
                null
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

    /** Runs on the app's main thread, where an escaping exception ends the
     * whole process: reading another app's extras (a Parcelable this app
     * cannot unpack) or the stored buffer can throw. One bad notification
     * is skipped instead, and the replay in [onListenerConnected] goes on
     * with the next one. */
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            capture(sbn)
        } catch (_: Exception) {
            // Skipped; the next notification is read as usual.
        }
    }

    private fun capture(sbn: StatusBarNotification) {
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
                store(
                    applicationContext,
                    sender,
                    text,
                    if (time > 0) time else sbn.postTime,
                    time,
                )
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
            "$sender: (message received, no ₹ amount, content not stored)"
        }
        putDiag(applicationContext, KEY_LAST_SAMPLE, sample)
    }
}
