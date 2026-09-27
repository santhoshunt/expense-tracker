package com.fabletest.expense_tracker

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.text.NumberFormat
import java.time.LocalDate
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * The Month pace, Upcoming bills and Today and Add widgets. Pure display,
 * like [BudgetWidgetProvider]: the Dart side writes one snapshot
 * (`flutter.home_widget_data_v1`, home_widgets_service.dart) and this draws
 * it. The snapshot carries dates rather than "today" labels, so a redraw
 * after midnight (every 30 minutes, see the *_info.xml files) shows the new
 * day without the app running.
 */
object HomeWidgets {
    private const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val DATA_KEY = "flutter.home_widget_data_v1"
    private const val THEME_KEY = "flutter.budget_widget_theme_v1"

    /** PendingIntent request codes: one per purpose and instance, so two
     * widgets' taps never overwrite each other's intent. */
    private const val REQUEST_OPEN = 4000
    private const val REQUEST_ADD = 3000

    private val providers = listOf(
        MonthPaceWidgetProvider::class.java,
        UpcomingWidgetProvider::class.java,
        TodayAddWidgetProvider::class.java,
    )

    /** The app's colours, as buildWidgetTheme writes them; dark-kit
     * defaults until the app has synced once. */
    private class Theme(private val json: JSONObject?) {
        private fun c(key: String, fallback: Long) =
            (json?.optLong(key, fallback) ?: fallback).toInt()

        val surface = c("surface", 0xFF252836)
        val text = c("text", 0xFFFFFFFF)
        val textSecondary = c("textSecondary", 0xFFB4C0C8)
        val track = c("track", 0xFF3B3F4F)
        val over = c("over", 0xFFFF7CA3)
        val accent = c("accent", 0xFF4A90E2)
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)

    private fun readJson(context: Context, key: String): JSONObject? = try {
        prefs(context).getString(key, null)?.let { JSONObject(it) }
    } catch (_: Exception) {
        // A malformed snapshot shows the empty state instead of crashing
        // the launcher that hosts the widget.
        null
    }

    private fun today(): Long = LocalDate.now().toEpochDay()

    /** Whole rupees the way the app's fmtMoney groups them. */
    private fun rupees(v: Double): String =
        "₹" + NumberFormat.getIntegerInstance(Locale.US).format(abs(v).roundToLong())

    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        for (cls in providers) {
            for (id in manager.getAppWidgetIds(ComponentName(context, cls))) {
                render(context, manager, id)
            }
        }
    }

    fun render(context: Context, manager: AppWidgetManager, id: Int) {
        val provider = manager.getAppWidgetInfo(id)?.provider?.className ?: return
        val data = readJson(context, DATA_KEY)
        val theme = Theme(readJson(context, THEME_KEY))
        val views = when (provider) {
            MonthPaceWidgetProvider::class.java.name ->
                pace(context, manager, id, data, theme)
            UpcomingWidgetProvider::class.java.name -> upcoming(context, data, theme)
            TodayAddWidgetProvider::class.java.name -> todayAdd(context, id, data, theme)
            else -> return
        }
        manager.updateAppWidget(id, views)
    }

    private fun openApp(context: Context, id: Int): PendingIntent =
        PendingIntent.getActivity(
            context,
            REQUEST_OPEN + id,
            BudgetWidgetProvider.launchIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun base(context: Context, layout: Int, theme: Theme, id: Int): RemoteViews =
        RemoteViews(context.packageName, layout).apply {
            setInt(R.id.hw_bg, "setColorFilter", theme.surface)
            setOnClickPendingIntent(R.id.hw_root, openApp(context, id))
        }

    // --- Month pace ---------------------------------------------------------

    private fun pace(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        data: JSONObject?,
        theme: Theme,
    ): RemoteViews {
        val views = base(context, R.layout.home_widget_pace, theme, id)
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        views.setTextColor(R.id.hw_amount, theme.text)
        views.setTextColor(R.id.hw_sub, theme.text)
        views.setTextColor(R.id.hw_marker_label, theme.textSecondary)
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        val pace = data?.optJSONObject("pace")
        if (pace == null) {
            views.setViewVisibility(R.id.hw_body, View.GONE)
            views.setViewVisibility(R.id.hw_empty, View.VISIBLE)
            return views
        }
        views.setViewVisibility(R.id.hw_body, View.VISIBLE)
        views.setViewVisibility(R.id.hw_empty, View.GONE)

        val now = LocalDate.now()
        // A plain number, not a formatted string: a device language with
        // its own digits would never match the snapshot's.
        val sameMonth = data.optInt("monthKey", -1) == now.year * 12 + now.monthValue
        // A new month the app has not seen yet: nothing is spent in it.
        val spent = if (sameMonth) pace.optDouble("spent", 0.0) else 0.0
        val cap = pace.optDouble("cap", 0.0)
        val usualArr = pace.optJSONArray("usualByDay")
        val usual = usualArr?.let { a -> DoubleArray(a.length()) { a.optDouble(it, 0.0) } }
        // On a month's last day the app compares whole months (entry 30 is
        // each month's total), not the same day number.
        val usualIndex =
            if (now.dayOfMonth == now.lengthOfMonth()) 30 else now.dayOfMonth - 1
        val usualToday = usual?.getOrNull(usualIndex)
        val usualFull = usual?.lastOrNull()

        val monthName = if (sameMonth) data.optString("monthLabel")
        else now.month.getDisplayName(java.time.format.TextStyle.FULL, Locale.ENGLISH)
        views.setTextViewText(R.id.hw_title, "$monthName so far · day ${now.dayOfMonth}")
        views.setTextViewText(
            R.id.hw_amount,
            if (sameMonth) pace.optString("spentLabel") else "₹0"
        )
        val sub = when {
            cap > 0 -> "${(spent / cap * 100).toInt()}% of ${pace.optString("capLabel")} cap"
            usualToday == null -> "Spent this month"
            abs(spent - usualToday) < 1 -> "Same as usual by today"
            spent < usualToday -> "${rupees(usualToday - spent)} under usual by today"
            else -> "${rupees(spent - usualToday)} over usual by today"
        }
        views.setTextViewText(R.id.hw_sub, sub)
        views.setTextColor(R.id.hw_sub, if (cap > 0 && spent > cap) theme.over else theme.text)

        // The bar's scale: the cap when there is one, else a usual month.
        val scale = if (cap > 0) cap else usualFull ?: 0.0
        views.setViewVisibility(
            R.id.hw_marker_label,
            if (usualToday != null && scale > 0) View.VISIBLE else View.GONE
        )
        val fill = if (scale > 0) (spent / scale).coerceIn(0.0, 1.0) else 0.0
        val marker = if (usualToday != null && scale > 0) {
            (usualToday / scale).coerceIn(0.0, 1.0)
        } else null
        val barColor = if (cap > 0 && spent > cap) theme.over else theme.accent
        views.setImageViewBitmap(
            R.id.hw_bar,
            paceBar(context, manager.getAppWidgetOptions(id), fill, marker, barColor, theme)
        )
        return views
    }

    /** Track, fill and the usual-by-today tick, sized to the widget. */
    private fun paceBar(
        context: Context,
        options: Bundle?,
        fill: Double,
        marker: Double?,
        barColor: Int,
        theme: Theme,
    ): Bitmap {
        val density = context.resources.displayMetrics.density
        // The widest the launcher draws it (landscape), minus the layout's
        // 16dp side padding; fitXY only ever shrinks it. 250dp is the
        // declared minimum.
        val widthDp = (options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 250)
            ?.takeIf { it > 0 } ?: 250) - 32
        val w = (widthDp * density).toInt().coerceIn(64, 1600)
        val h = (14 * density).toInt().coerceAtLeast(8)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val barH = 8 * density
        val top = (h - barH) / 2
        val r = 4 * density
        paint.color = theme.track
        canvas.drawRoundRect(RectF(0f, top, w.toFloat(), top + barH), r, r, paint)
        if (fill > 0) {
            paint.color = barColor
            canvas.drawRoundRect(
                RectF(0f, top, (w * fill).toFloat().coerceAtLeast(barH), top + barH),
                r, r, paint
            )
        }
        if (marker != null) {
            val tick = 2 * density
            val x = (w * marker).toFloat().coerceIn(0f, w - tick)
            paint.color = theme.textSecondary
            canvas.drawRect(x, 0f, x + tick, h.toFloat(), paint)
        }
        return bmp
    }

    // --- Upcoming bills -----------------------------------------------------

    private val rowIds = listOf(
        Triple(R.id.hw_row1, R.id.hw_name1, R.id.hw_meta1),
        Triple(R.id.hw_row2, R.id.hw_name2, R.id.hw_meta2),
        Triple(R.id.hw_row3, R.id.hw_name3, R.id.hw_meta3),
    )

    private fun upcoming(context: Context, data: JSONObject?, theme: Theme): RemoteViews {
        // Every row opens the app, so the whole card shares one intent.
        val views = base(context, R.layout.home_widget_upcoming, theme, 0)
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        val today = today()
        val items = data?.optJSONArray("upcoming")
        val rows = mutableListOf<Pair<String, String>>()
        if (items != null) {
            for (i in 0 until items.length()) {
                val o = items.optJSONObject(i) ?: continue
                val days = o.optLong("dueDay", today) - today
                // Same grace as the app: a week overdue, then it drops off.
                if (days < -7) continue
                val due = when {
                    days < 0 -> "Overdue"
                    days == 0L -> "Today"
                    days == 1L -> "Tomorrow"
                    else -> o.optString("dueLabel")
                }
                val amount = o.optString("amountLabel").takeIf { !o.isNull("amountLabel") }
                rows += o.optString("label") to (if (amount == null) due else "$due · $amount")
                if (rows.size == rowIds.size) break
            }
        }
        rowIds.forEachIndexed { i, (row, name, meta) ->
            val r = rows.getOrNull(i)
            views.setViewVisibility(row, if (r == null) View.GONE else View.VISIBLE)
            if (r != null) {
                views.setTextViewText(name, r.first)
                views.setTextViewText(meta, r.second)
                views.setTextColor(name, theme.text)
                views.setTextColor(meta, theme.textSecondary)
            }
        }
        views.setViewVisibility(R.id.hw_empty, if (rows.isEmpty()) View.VISIBLE else View.GONE)
        views.setTextViewText(
            R.id.hw_empty,
            if (data == null) context.getString(R.string.home_widget_empty)
            else "Nothing due soon."
        )
        return views
    }

    // --- Today and Add ------------------------------------------------------

    private fun todayAdd(context: Context, id: Int, data: JSONObject?, theme: Theme): RemoteViews {
        val views = base(context, R.layout.home_widget_today, theme, id)
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        views.setTextColor(R.id.hw_amount, theme.text)
        views.setOnClickPendingIntent(R.id.hw_open, openApp(context, id))

        val t = data?.optJSONObject("today")
        val count = t?.optInt("count", 0) ?: 0
        views.setTextViewText(
            R.id.hw_amount,
            when {
                t == null -> "Open the app once to start"
                // Written on an earlier day: nothing is recorded for today.
                t.optLong("day", -1) != today() -> "₹0 · no payments yet"
                count == 0 -> "₹0 · no payments yet"
                else -> "${t.optString("spentLabel")} · $count payment${if (count == 1) "" else "s"}"
            }
        )

        // Dark or white label on the accent, whichever reads better.
        views.setInt(R.id.hw_add_bg, "setColorFilter", theme.accent)
        views.setTextColor(R.id.hw_add_label, onColor(theme.accent))
        QuickActions.intent(context, QuickActions.ADD_EXPENSE)?.let { add ->
            views.setOnClickPendingIntent(
                R.id.hw_add,
                PendingIntent.getActivity(
                    context,
                    REQUEST_ADD + id,
                    add,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        }
        return views
    }

    private fun luminance(c: Int): Double {
        fun ch(v: Int): Double {
            val s = v / 255.0
            return if (s <= 0.03928) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(Color.red(c)) + 0.7152 * ch(Color.green(c)) + 0.0722 * ch(Color.blue(c))
    }

    private fun onColor(bg: Int): Int {
        val dark = 0xFF1B1927.toInt()
        val l = luminance(bg)
        val vsWhite = 1.05 / (l + 0.05)
        val vsDark = (l + 0.05) / (luminance(dark) + 0.05)
        return if (vsDark >= vsWhite) dark else Color.WHITE
    }
}

/** Month pace (4×2): spent so far against the cap or a usual month. */
class MonthPaceWidgetProvider : HomeWidgetProviderBase()

/** Upcoming bills (4×2): the next three due. */
class UpcomingWidgetProvider : HomeWidgetProviderBase()

/** Today and Add (4×1): today's spend and an Add expense button. */
class TodayAddWidgetProvider : HomeWidgetProviderBase()

/** One picker entry per subclass; [HomeWidgets.render] picks the layout. */
abstract class HomeWidgetProviderBase : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) HomeWidgets.render(context, manager, id)
    }

    /** A resize changes the pace bar's width. */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        newOptions: Bundle,
    ) {
        HomeWidgets.render(context, manager, id)
    }
}
