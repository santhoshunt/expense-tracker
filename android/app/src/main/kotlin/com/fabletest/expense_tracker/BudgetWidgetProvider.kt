package com.fabletest.expense_tracker

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home-screen budget widget. Pure display: the Flutter side computes every
 * figure and writes a per-budget snapshot into FlutterSharedPreferences
 * (`flutter.budget_widget_data_v1`, see budget_widget_service.dart); this
 * provider only picks the entry the widget instance was configured for and
 * renders it. Figures refresh whenever the app runs (there is no background
 * service, the same model as budget alerts), so the widget states its month
 * and last-updated date, and tapping it opens the app.
 */
open class BudgetWidgetProvider : AppWidgetProvider() {
    companion object {
        /** Native-only state: which budget each widget instance shows. */
        private const val PREFS = "budget_widget_prefs"
        private const val KEY_PREFIX = "budget_"

        /** Snapshot written by the Dart side (shared_preferences adds the
         * `flutter.` prefix and stores everything in this one file). */
        const val DATA_KEY = "flutter.budget_widget_data_v1"

        /** The overall monthly cap's snapshot id (kOverallBudgetWidgetId). */
        private const val OVERALL_ID = "_overall"

        fun saveSelection(context: Context, appWidgetId: Int, budgetId: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString("$KEY_PREFIX$appWidgetId", budgetId).apply()
        }

        /** Whichever launcher entry is currently enabled: MainActivity or
         * one of the icon aliases. */
        fun launchIntent(context: Context): Intent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)

        fun selectionOf(context: Context, appWidgetId: Int): String? =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString("$KEY_PREFIX$appWidgetId", null)

        /** Re-renders every widget drawn from the budget snapshot: both
         * budget variants and Budgets list. Called when the Dart side has
         * written a fresh snapshot (SmsBridge's updateBudgetWidgets). */
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val providers = listOf(
                BudgetWidgetProvider::class.java,
                BudgetWidgetDetailedProvider::class.java,
            )
            for (cls in providers) {
                val ids = manager.getAppWidgetIds(ComponentName(context, cls))
                for (id in ids) render(context, manager, id)
            }
            HomeWidgets.refresh(context, BudgetsListWidgetProvider::class.java)
        }

        fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
            // The system calls this from the widget broadcast, where an
            // escaping exception kills the whole app process: a widget that
            // cannot draw keeps its last picture instead.
            try {
                val detailed = manager.getAppWidgetInfo(appWidgetId)
                    ?.provider?.className ==
                    BudgetWidgetDetailedProvider::class.java.name
                WidgetKit.update(
                    context, manager, appWidgetId, 250, if (detailed) 110 else 48
                ) { _, h, bitmaps -> build(context, appWidgetId, detailed, h, bitmaps) }
            } catch (_: Exception) {
                // Drawn again on the next snapshot.
            }
        }

        /** [detailed]: which picker entry this instance came from decides
         * the layout. Compact (4x1) is the ring and two lines; detailed
         * (4x2) adds a larger ring and the updated line. [heightDp] is the
         * height it is drawn at: a line that does not fit hides. */
        private fun build(
            context: Context,
            appWidgetId: Int,
            detailed: Boolean,
            heightDp: Int,
            bitmaps: WidgetKit.Bitmaps,
        ): RemoteViews {
            val views = RemoteViews(
                context.packageName,
                if (detailed) R.layout.budget_widget_detailed
                else R.layout.budget_widget
            )
            val theme = WidgetTheme.read(context)
            WidgetKit.applyCard(views, theme)
            views.setTextColor(R.id.widget_empty, theme.textSecondary)

            val selected = selectionOf(context, appWidgetId)
            val entry = findEntry(context, selected)
            // Opens the budget it shows: the overall cap's card, or the
            // Budgets list for one of the user's own. The LAUNCH intent, not
            // an explicit MainActivity one: the alternate-icon feature
            // disables .MainActivity in favour of an alias, and starting a
            // disabled component silently does nothing. One request code per
            // widget, so two widgets never share an intent.
            val action = if (selected == null || selected == OVERALL_ID) {
                QuickActions.OPEN_BUDGET
            } else {
                QuickActions.OPEN_BUDGETS
            }
            val open = PendingIntent.getActivity(
                context,
                HomeWidgets.requestCode(appWidgetId, HomeWidgets.PURPOSE_BUDGET),
                QuickActions.intent(context, action) ?: launchIntent(context),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.hw_root, open)
            if (entry == null) {
                // Never configured, budget deleted, or the app hasn't written
                // a snapshot yet.
                views.setViewVisibility(R.id.widget_body, View.GONE)
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
                return views
            }

            val spent = entry.optDouble("spent", 0.0)
            val limit = entry.optDouble("limit", 0.0)
            // The text keeps counting past 100 ("110%"); only the ring stops
            // full, like the in-app budget ring.
            val pct =
                if (limit <= 0) 0 else ((spent / limit) * 100).toInt().coerceAtLeast(0)
            val over = entry.optBoolean("over", spent > limit)
            val color = theme.ringColor(pct)

            views.setViewVisibility(R.id.widget_body, View.VISIBLE)
            views.setViewVisibility(R.id.widget_empty, View.GONE)
            // The same ring in both orientations: drawn and sent once.
            bitmaps.get("ring") {
                if (detailed) WidgetKit.ring(context, 64, 6f, pct, color, theme.track)
                else WidgetKit.ring(context, 36, 4f, pct, color, theme.track)
            }?.let { views.setImageViewBitmap(R.id.widget_ring, it) }
            views.setImageViewResource(
                R.id.widget_icon,
                WidgetKit.icon(entry.optString("icon", "wallet"))
            )
            views.setInt(R.id.widget_icon, "setColorFilter", theme.textSecondary)

            views.setTextViewText(R.id.widget_name, entry.optString("name"))
            views.setTextColor(
                R.id.widget_name,
                if (detailed) theme.textSecondary else theme.text
            )
            // Older snapshots carry statusLabel only.
            val left = entry.optString("leftLabel").ifEmpty {
                entry.optString("statusLabel")
            }
            views.setTextViewText(R.id.widget_left, left)
            views.setTextColor(R.id.widget_left, if (over) theme.over else theme.text)

            val month = entry.optString("monthName").ifEmpty {
                entry.optString("monthLabel")
            }
            views.setTextViewText(
                R.id.widget_amounts,
                "${entry.optString("spentLabel")} of ${entry.optString("limitLabel")}" +
                    " · $pct% · $month"
            )
            views.setTextColor(R.id.widget_amounts, theme.textSecondary)
            // The lines under the name hide, last first, where the height
            // (less the card's padding: 4dp above and below in compact, 10dp
            // in detailed) cannot hold them, so large text never clips.
            if (detailed) {
                val room = heightDp - 20f
                val core = WidgetKit.lineDp(context, 13f) + WidgetKit.lineDp(context, 20f)
                val amounts = 2 + WidgetKit.lineDp(context, 12f)
                val meta = WidgetKit.lineDp(context, 11f)
                views.setViewVisibility(
                    R.id.widget_amounts,
                    if (core + amounts <= room) View.VISIBLE else View.GONE
                )
                views.setViewVisibility(
                    R.id.widget_meta,
                    if (core + amounts + meta <= room) View.VISIBLE else View.GONE
                )
            } else {
                val room = heightDp - 8f
                val two = WidgetKit.lineDp(context, 14f) + WidgetKit.lineDp(context, 12f)
                views.setViewVisibility(
                    R.id.widget_amounts,
                    if (two <= room) View.VISIBLE else View.GONE
                )
            }
            if (detailed) {
                // This view exists only in the detailed layout: RemoteViews
                // fails to apply when told to fill an id the layout lacks.
                val updated = entry.optString("updatedShort").ifEmpty {
                    entry.optString("updatedLabel")
                }
                views.setTextViewText(R.id.widget_meta, "updated $updated")
                views.setTextColor(R.id.widget_meta, theme.textSecondary)
            }
            return views
        }

        private fun findEntry(context: Context, budgetId: String?): JSONObject? {
            if (budgetId == null) return null
            val list = WidgetKit.readArray(context, DATA_KEY) ?: return null
            return (0 until list.length())
                .mapNotNull { list.optJSONObject(it) }
                .firstOrNull { it.optString("id") == budgetId }
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (id in appWidgetIds) render(context, appWidgetManager, id)
    }

    /** A resize changes which lines fit. */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        render(context, appWidgetManager, appWidgetId)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        for (id in appWidgetIds) prefs.remove("$KEY_PREFIX$id")
        prefs.apply()
    }
}
