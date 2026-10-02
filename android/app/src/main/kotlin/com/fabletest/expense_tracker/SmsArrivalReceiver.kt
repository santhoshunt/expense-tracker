package com.fabletest.expense_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/**
 * Wakes the background import when an SMS arrives. Disabled in the
 * manifest and switched on only while Auto-import is Every SMS
 * ([BackgroundImport.configure]). The message itself is not read here: the
 * import reads the inbox like every other run, so parsing, rules and
 * duplicate checks stay in one place.
 */
class SmsArrivalReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        // Kept alive until the work is enqueued: that reads WorkManager's
        // state off the main thread.
        val pending = goAsync()
        BackgroundImport.enqueueNow(
            context.applicationContext,
            BackgroundImport.TRIGGER_SMS
        ) { pending.finish() }
    }
}
