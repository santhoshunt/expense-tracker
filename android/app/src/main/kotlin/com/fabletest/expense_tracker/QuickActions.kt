package com.fabletest.expense_tracker

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Log

/** Launcher shortcuts and the Quick Settings tile: intents that open the app
 * with a "launch action" extra, which Dart turns into a screen. */
object QuickActions {
    const val EXTRA = "launch_action"
    const val ADD_EXPENSE = "add_expense"
    const val IMPORT_SMS = "import_sms"

    /** Opens the enabled launcher entry with [action].
     *
     * The component comes from getLaunchIntentForPackage, never from
     * MainActivity's class: choosing an alternate icon disables .MainActivity,
     * and starting a disabled component does nothing. NEW_TASK + CLEAR_TOP
     * + SINGLE_TOP reuse the running task, where the existing instance gets
     * onNewIntent instead of the app restarting. CLEAR_TOP also closes any
     * system screen stacked above it (a save dialog, Google sign-in). */
    fun intent(context: Context, action: String): Intent? {
        val base = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: return null
        return base
            .setAction(Intent.ACTION_RUN)
            .putExtra(EXTRA, action)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
    }

    /** The action [intent] carries, or null. Reopening from recents replays
     * the original intent, so a history launch carries none. */
    fun actionOf(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        return when (val action = intent.getStringExtra(EXTRA)) {
            ADD_EXPENSE, IMPORT_SMS -> action
            else -> null
        }
    }

    /** Publishes the long-press shortcuts against the launcher entry enabled
     * now. Dynamic (not a static shortcuts.xml) because static ones hang off
     * one manifest component, and the icon switcher moves the launcher entry
     * between ten of them. Call again after every icon switch. */
    fun publishShortcuts(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return
        try {
            val manager = context.getSystemService(ShortcutManager::class.java) ?: return
            val add = intent(context, ADD_EXPENSE) ?: return
            val sms = intent(context, IMPORT_SMS) ?: return
            val activity = add.component ?: return
            fun shortcut(id: String, label: Int, icon: Int, intent: Intent) =
                ShortcutInfo.Builder(context, id)
                    .setShortLabel(context.getString(label))
                    .setIcon(Icon.createWithResource(context, icon))
                    .setActivity(activity)
                    .setIntent(intent)
                    .build()
            manager.dynamicShortcuts = listOf(
                shortcut(ADD_EXPENSE, R.string.shortcut_add_expense, R.drawable.ic_shortcut_add, add),
                shortcut(IMPORT_SMS, R.string.shortcut_import_sms, R.drawable.ic_shortcut_sms, sms),
            )
        } catch (e: Exception) {
            // Best-effort: a launcher without shortcut support, or a target
            // entry the system has not switched yet, must never break startup
            // or an icon switch. MainActivity republishes on every resume.
            Log.w("QuickActions", "Publishing shortcuts failed", e)
        }
    }
}
