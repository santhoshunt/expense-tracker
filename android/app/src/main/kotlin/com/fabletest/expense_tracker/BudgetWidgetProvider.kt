package com.fabletest.expense_tracker

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject

/**
 * Home-screen budget widget. Pure display: the Flutter side computes every
 * figure and writes a per-budget snapshot into FlutterSharedPreferences
 * (`flutter.budget_widget_data_v1`, see budget_widget_service.dart); this
 * provider only picks the entry the widget instance was configured for and
 * renders it. Figures refresh whenever the app runs (there is no background
 * service — same model as budget alerts), so the widget states its month
 * and last-updated date, and tapping it opens the app.
 */
open class BudgetWidgetProvider : AppWidgetProvider() {
    companion object {
        /** Native-only state: which budget each widget instance shows. */
        private const val PREFS = "budget_widget_prefs"
        private const val KEY_PREFIX = "budget_"

        /** Snapshot written by the Dart side (shared_preferences adds the
         * `flutter.` prefix and stores everything in this one file). */
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val DATA_KEY = "flutter.budget_widget_data_v1"
        private const val THEME_KEY = "flutter.budget_widget_theme_v1"

        /** The app theme's colours for the widget, written by the Dart side
         * next to the snapshot (buildWidgetTheme). Defaults are the dark kit,
         * for a widget rendered before the app has synced a theme. */
        private class WidgetTheme(private val json: JSONObject?) {
            private fun c(key: String, fallback: Long) =
                (json?.optLong(key, fallback) ?: fallback).toInt()

            val surface = c("surface", 0xFF252836)
            val text = c("text", 0xFFFFFFFF)
            val textSecondary = c("textSecondary", 0xFFB4C0C8)
            val track = c("track", 0xFF3B3F4F)
            val safe = c("safe", 0xFF50D1AA)
            val warn = c("warn", 0xFFFFB572)
            val over = c("over", 0xFFFF7CA3)

            /** Green below 80% used, orange from 80% to 95%, red above. */
            fun barColor(pct: Int) = when {
                pct > 95 -> over
                pct >= 80 -> warn
                else -> safe
            }
        }

        private fun readTheme(context: Context) = WidgetTheme(
            try {
                context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
                    .getString(THEME_KEY, null)?.let { JSONObject(it) }
            } catch (_: Exception) {
                null
            }
        )

        private fun applyTheme(views: RemoteViews, theme: WidgetTheme, detailed: Boolean) {
            views.setInt(R.id.widget_bg, "setColorFilter", theme.surface)
            views.setTextColor(R.id.widget_name, theme.text)
            views.setTextColor(R.id.widget_amounts, theme.text)
            views.setTextColor(R.id.widget_empty, theme.textSecondary)
            if (detailed) views.setTextColor(R.id.widget_meta, theme.textSecondary)
            // Tint lists are settable through RemoteViews from Android 12;
            // older launchers keep the drawables' default kit colours.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                views.setColorStateList(
                    R.id.widget_bg, "setImageTintList",
                    ColorStateList.valueOf(theme.surface)
                )
                views.setColorStateList(
                    R.id.widget_progress, "setProgressBackgroundTintList",
                    ColorStateList.valueOf(theme.track)
                )
            }
        }

        fun saveSelection(context: Context, appWidgetId: Int, budgetId: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putString("$KEY_PREFIX$appWidgetId", budgetId).apply()
        }

        /** Whichever launcher entry is currently enabled — MainActivity or
         * one of the icon aliases. */
        fun launchIntent(context: Context): Intent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)

        private fun selectionOf(context: Context, appWidgetId: Int): String? =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString("$KEY_PREFIX$appWidgetId", null)

        /** Re-renders every widget instance of BOTH variants — called from
         * MainActivity when the Dart side has written a fresh snapshot. */
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
        }

        fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int) {
            // Which picker entry this instance came from decides the layout:
            // compact (4×1) stops at the bar — a one-cell slot clipped the
            // text below it — while detailed (4×2) carries the status and
            // month lines.
            val detailed = manager.getAppWidgetInfo(appWidgetId)
                ?.provider?.className ==
                BudgetWidgetDetailedProvider::class.java.name
            val views = RemoteViews(
                context.packageName,
                if (detailed) R.layout.budget_widget_detailed
                else R.layout.budget_widget
            )

            // Whole widget opens the app — also the refresh gesture. The
            // LAUNCH intent, not an explicit MainActivity intent: the
            // alternate-icon feature disables .MainActivity and enables an
            // activity-alias instead, and starting a disabled component
            // silently does nothing.
            val open = PendingIntent.getActivity(
                context,
                0,
                launchIntent(context),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, open)
            val theme = readTheme(context)
            applyTheme(views, theme, detailed)

            val entry = findEntry(context, selectionOf(context, appWidgetId))
            if (entry == null) {
                // Never configured, budget deleted, or the app hasn't written
                // a snapshot yet.
                views.setViewVisibility(R.id.widget_body, View.GONE)
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
                manager.updateAppWidget(appWidgetId, views)
                return
            }

            val spent = entry.optDouble("spent", 0.0)
            val limit = entry.optDouble("limit", 0.0)
            val over = spent > limit
            // The text keeps counting past 100 ("110% used"); only the bar
            // stops full, like the in-app budget ring.
            val pct =
                if (limit <= 0) 0 else ((spent / limit) * 100).toInt().coerceAtLeast(0)

            views.setViewVisibility(R.id.widget_body, View.VISIBLE)
            views.setViewVisibility(R.id.widget_empty, View.GONE)
            views.setTextViewText(R.id.widget_name, entry.optString("name"))
            views.setTextViewText(
                R.id.widget_amounts,
                "${entry.optString("spentLabel")} of ${entry.optString("limitLabel")}"
            )
            views.setProgressBar(R.id.widget_progress, 100, pct.coerceAtMost(100), false)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                views.setColorStateList(
                    R.id.widget_progress, "setProgressTintList",
                    ColorStateList.valueOf(theme.barColor(pct))
                )
            }
            if (detailed) {
                // These views exist only in the detailed layout — RemoteViews
                // fails to apply when told to fill ids the layout lacks.
                views.setTextViewText(
                    R.id.widget_status,
                    "$pct% used · ${entry.optString("statusLabel")}"
                )
                views.setTextColor(
                    R.id.widget_status,
                    if (over) theme.over else theme.text
                )
                views.setTextViewText(
                    R.id.widget_meta,
                    "${entry.optString("monthLabel")} · updated ${entry.optString("updatedLabel")}"
                )
            }
            manager.updateAppWidget(appWidgetId, views)
        }

        private fun findEntry(context: Context, budgetId: String?) =
            if (budgetId == null) null
            else try {
                val raw = context
                    .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
                    .getString(DATA_KEY, null)
                if (raw == null) null
                else {
                    val list = JSONArray(raw)
                    (0 until list.length())
                        .map { list.getJSONObject(it) }
                        .firstOrNull { it.optString("id") == budgetId }
                }
            } catch (_: Exception) {
                // A malformed snapshot must render the empty state, not
                // crash the launcher process hosting this widget.
                null
            }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (id in appWidgetIds) render(context, appWidgetManager, id)
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        for (id in appWidgetIds) prefs.remove("$KEY_PREFIX$id")
        prefs.apply()
    }
}
