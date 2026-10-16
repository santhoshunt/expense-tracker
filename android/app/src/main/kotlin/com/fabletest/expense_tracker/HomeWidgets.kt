package com.fabletest.expense_tracker

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.time.LocalDate
import java.util.Locale
import kotlin.math.abs

/**
 * The Month pace, Upcoming, Today and Add, Spending split, Budgets
 * list, Recent, Quick actions, Big bills and This week widgets (the last
 * two in a 4x2 and a compact 4x1 size). Pure display, like
 * [BudgetWidgetProvider]: the Dart side writes the snapshots
 * (`flutter.home_widget_data_v1`, home_widgets_service.dart, and the budget
 * one for Budgets list) and this draws them. The snapshot carries dates
 * rather than "today" labels, so a redraw after midnight (every 30 minutes,
 * see the *_info.xml files) shows the new day without the app running.
 */
object HomeWidgets {
    private const val DATA_KEY = "flutter.home_widget_data_v1"

    /** The card padding every 4x2 layout uses, in dp: 16 at the sides and
     * 10 above and below. The fit sums below count on these. */
    private const val PAD_H = 16
    private const val PAD_V = 10

    /** The gap above each list row (Upcoming, Budgets list, Recent). */
    private const val ROW_GAP = 4f

    /** What a widget's PendingIntent is for; see [requestCode]. */
    const val PURPOSE_OPEN = 1
    const val PURPOSE_ADD = 2
    const val PURPOSE_BUDGET = 3
    const val PURPOSE_INCOME = 4
    const val PURPOSE_IMPORT = 5

    /** One request code per widget and purpose. Every tap is an ACTION_RUN
     * intent on the same activity, and intents differing only in extras are
     * the same PendingIntent: a shared code would let one widget's tap
     * overwrite another's. Widget ids are unique and purposes stay below 8,
     * so id and purpose never collide. */
    fun requestCode(id: Int, purpose: Int): Int = id * 8 + purpose

    private val providers = listOf(
        MonthPaceWidgetProvider::class.java,
        UpcomingWidgetProvider::class.java,
        TodayAddWidgetProvider::class.java,
        SpendingSplitWidgetProvider::class.java,
        BudgetsListWidgetProvider::class.java,
        RecentWidgetProvider::class.java,
        QuickActionsWidgetProvider::class.java,
        BigBillsWidgetProvider::class.java,
        BigBillsCompactWidgetProvider::class.java,
        ThisWeekWidgetProvider::class.java,
        ThisWeekCompactWidgetProvider::class.java,
    )

    private fun today(): Long = LocalDate.now().toEpochDay()

    fun refreshAll(context: Context) {
        for (cls in providers) refresh(context, cls)
    }

    /** Redraws every instance of one widget. */
    fun refresh(context: Context, cls: Class<out AppWidgetProvider>) {
        val manager = AppWidgetManager.getInstance(context)
        for (id in manager.getAppWidgetIds(ComponentName(context, cls))) {
            render(context, manager, id)
        }
    }

    fun render(context: Context, manager: AppWidgetManager, id: Int) {
        // The system calls this from the widget broadcast, where an escaping
        // exception kills the whole app process: a widget that cannot draw
        // keeps its last picture instead.
        try {
            val provider = manager.getAppWidgetInfo(id)?.provider?.className ?: return
            val data = WidgetKit.readObject(context, DATA_KEY)
            val theme = WidgetTheme.read(context)
            // Each builder gets the width and height it is drawn at, in dp,
            // and keeps to it: rows drop out and lines hide rather than clip.
            val build: (Int, Int, WidgetKit.Bitmaps) -> RemoteViews = when (provider) {
                MonthPaceWidgetProvider::class.java.name ->
                    ({ w, h, b -> pace(context, w, h, b, id, data, theme) })
                UpcomingWidgetProvider::class.java.name ->
                    ({ _, h, _ -> upcoming(context, h, id, data, theme) })
                TodayAddWidgetProvider::class.java.name ->
                    ({ w, h, _ -> todayAdd(context, w, h, id, data, theme) })
                SpendingSplitWidgetProvider::class.java.name ->
                    ({ w, h, b -> split(context, w, h, b, id, data, theme) })
                BudgetsListWidgetProvider::class.java.name ->
                    ({ _, h, b -> budgets(context, h, b, id, theme) })
                RecentWidgetProvider::class.java.name ->
                    ({ _, h, _ -> recent(context, h, id, data, theme) })
                QuickActionsWidgetProvider::class.java.name ->
                    ({ w, _, _ -> actions(context, w, id, theme) })
                BigBillsWidgetProvider::class.java.name ->
                    ({ w, h, b -> bigBills(context, w, h, b, id, data, theme) })
                BigBillsCompactWidgetProvider::class.java.name ->
                    ({ _, h, _ -> bigBillsCompact(context, h, id, data, theme) })
                ThisWeekWidgetProvider::class.java.name ->
                    ({ w, h, b -> thisWeek(context, w, h, b, id, data, theme) })
                ThisWeekCompactWidgetProvider::class.java.name ->
                    ({ w, h, b -> thisWeekCompact(context, w, h, b, id, data, theme) })
                else -> return
            }
            // The fallbacks are the smallest a launcher gives: 4 columns of
            // about 62dp, and one row of 48dp or two of 110dp.
            val oneRow = provider == TodayAddWidgetProvider::class.java.name ||
                provider == QuickActionsWidgetProvider::class.java.name ||
                provider == BigBillsCompactWidgetProvider::class.java.name ||
                provider == ThisWeekCompactWidgetProvider::class.java.name
            WidgetKit.update(context, manager, id, 250, if (oneRow) 48 else 110, build)
        } catch (_: Exception) {
            // Drawn again on the next data change or 30-minute redraw.
        }
    }

    /** Opens the app on [action]: the part of it this widget shows. */
    private fun openApp(
        context: Context,
        id: Int,
        action: String,
        purpose: Int = PURPOSE_OPEN,
    ): PendingIntent =
        PendingIntent.getActivity(
            context,
            requestCode(id, purpose),
            QuickActions.intent(context, action)
                ?: BudgetWidgetProvider.launchIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun base(
        context: Context,
        layout: Int,
        theme: WidgetTheme,
        id: Int,
        action: String,
    ): RemoteViews =
        RemoteViews(context.packageName, layout).apply {
            WidgetKit.applyCard(this, theme)
            setOnClickPendingIntent(R.id.hw_root, openApp(context, id, action))
        }

    /** "Today", "Yesterday" or the date, for an epoch [day]. */
    private fun dayName(day: Long, dateLabel: String): String = when (today() - day) {
        0L -> "Today"
        1L -> "Yesterday"
        else -> dateLabel
    }

    // --- Month pace ---------------------------------------------------------

    private fun pace(
        context: Context,
        widthDp: Int,
        heightDp: Int,
        bitmaps: WidgetKit.Bitmaps,
        id: Int,
        data: JSONObject?,
        theme: WidgetTheme,
    ): RemoteViews {
        val views = base(context, R.layout.home_widget_pace, theme, id, QuickActions.OPEN_PACE)
        views.setTextColor(R.id.hw_title, theme.textSecondary)
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
        // The amount (2dp under the title), the 14dp bar 6dp under it and
        // the gap line 4dp under that always show; the title only when the
        // height has room for it as well, so large text never clips.
        val core = 2 + WidgetKit.lineDp(context, 22f) + 6 + 14 + 4 +
            maxOf(WidgetKit.lineDp(context, 13f), WidgetKit.lineDp(context, 11f))
        val withTitle = core + WidgetKit.lineDp(context, 12f)
        views.setViewVisibility(
            R.id.hw_title,
            if (withTitle <= heightDp - 2 * PAD_V) View.VISIBLE else View.GONE
        )
        // Money out, as the app prints it: a minus and the expense red.
        // Nothing spent is a plain ₹0.
        if (spent >= 0.5) {
            views.setTextViewText(R.id.hw_amount, "−${pace.optString("spentLabel")}")
            views.setTextColor(R.id.hw_amount, theme.over)
        } else {
            views.setTextViewText(R.id.hw_amount, "₹0")
            views.setTextColor(R.id.hw_amount, theme.text)
        }
        val sub = when {
            cap > 0 -> "${(spent / cap * 100).toInt()}% of ${pace.optString("capLabel")} cap"
            usualToday == null -> "Spent this month"
            abs(spent - usualToday) < 1 -> "About the same as usual by today"
            spent < usualToday -> "${WidgetKit.rupees(usualToday - spent)} under usual by today"
            else -> "${WidgetKit.rupees(spent - usualToday)} over usual by today"
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
        // One bar per width: both orientations share it where the widths
        // match. Without bitmaps (the fallback update) the bar stays empty.
        bitmaps.get("bar:$widthDp") {
            paceBar(context, widthDp, fill, marker, barColor, theme)
        }?.let { views.setImageViewBitmap(R.id.hw_bar, it) }
        return views
    }

    /** Track, fill and the usual-by-today tick, drawn at the width the bar
     * has (the widget's width less the card's side padding), so fitXY
     * keeps its proportions and never squashes the rounded ends or the
     * tick. At most 2 pixels per dp and 1200 pixels wide: flat shapes
     * stay sharp scaled up, and the two orientations' bars stay under
     * about 270 KB together. */
    private fun paceBar(
        context: Context,
        widgetW: Int,
        fill: Double,
        marker: Double?,
        barColor: Int,
        theme: WidgetTheme,
    ): Bitmap {
        val density = minOf(context.resources.displayMetrics.density, 2f)
        val w = ((widgetW - 2 * PAD_H) * density).toInt().coerceIn(64, 1200)
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

    // --- Upcoming -----------------------------------------------------------

    private class UpcomingRow(val row: Int, val icon: Int, val name: Int, val meta: Int)

    private val upcomingRows = listOf(
        UpcomingRow(R.id.hw_row1, R.id.hw_icon1, R.id.hw_name1, R.id.hw_meta1),
        UpcomingRow(R.id.hw_row2, R.id.hw_icon2, R.id.hw_name2, R.id.hw_meta2),
        UpcomingRow(R.id.hw_row3, R.id.hw_icon3, R.id.hw_name3, R.id.hw_meta3),
    )

    private fun upcoming(
        context: Context,
        heightDp: Int,
        id: Int,
        data: JSONObject?,
        theme: WidgetTheme,
    ): RemoteViews {
        // Every row opens the Upcoming card, so the whole widget shares one
        // intent.
        val views = base(
            context, R.layout.home_widget_upcoming, theme, id, QuickActions.OPEN_UPCOMING
        )
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        // As many rows as the height holds under the title: a row is its
        // gap and its tallest part (the 16dp icon or the 14sp name).
        val room = heightDp - 2 * PAD_V - WidgetKit.lineDp(context, 12f)
        val rowDp = ROW_GAP + maxOf(16f, WidgetKit.lineDp(context, 14f))
        val fit = WidgetKit.rowsThatFit(room, rowDp, 1, upcomingRows.size)
        val today = today()
        val items = data?.optJSONArray("upcoming")
        val rows = mutableListOf<JSONObject>()
        if (items != null) {
            for (i in 0 until items.length()) {
                val o = items.optJSONObject(i) ?: continue
                // Same grace as the app: a week overdue, then it drops off.
                if (o.optLong("dueDay", today) - today < -7) continue
                rows += o
                if (rows.size == fit) break
            }
        }
        upcomingRows.forEachIndexed { i, ids ->
            val o = rows.getOrNull(i)
            views.setViewVisibility(ids.row, if (o == null) View.GONE else View.VISIBLE)
            if (o == null) return@forEachIndexed
            val days = o.optLong("dueDay", today) - today
            // Overdue from the dates on the day it draws, so a redraw after
            // midnight is right without the app.
            val line = WidgetKit.Line()
            when {
                days < 0 -> line.add("● Overdue", theme.over, bold = true)
                days == 0L -> line.add("Today", theme.textSecondary)
                days == 1L -> line.add("Tomorrow", theme.textSecondary)
                else -> line.add(o.optString("dueLabel"), theme.textSecondary)
            }
            if (!o.isNull("amountLabel")) {
                val kind = o.optString("kind", "out")
                line.add(" · ", theme.textSecondary)
                // Income due ("in") in green with its plus; bills ("out")
                // and "neutral" transfers plain: nothing has moved yet.
                line.add(
                    o.optString("amountLabel"),
                    if (kind == "in") theme.safe else theme.textSecondary,
                    bold = kind == "in"
                )
            }
            views.setTextViewText(ids.name, o.optString("label"))
            views.setTextColor(ids.name, theme.text)
            views.setTextViewText(ids.meta, line.build())
            views.setImageViewResource(ids.icon, WidgetKit.icon(o.optString("icon")))
            views.setInt(ids.icon, "setColorFilter", theme.textSecondary)
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

    private fun todayAdd(
        context: Context,
        widthDp: Int,
        heightDp: Int,
        id: Int,
        data: JSONObject?,
        theme: WidgetTheme,
    ): RemoteViews {
        val views = base(context, R.layout.home_widget_today, theme, id, QuickActions.OPEN_TODAY)
        views.setOnClickPendingIntent(R.id.hw_open, openApp(context, id, QuickActions.OPEN_TODAY))

        val t = data?.optJSONObject("today")
        // Written on an earlier day: nothing is recorded for today.
        val fresh = t != null && t.optLong("day", -1) == today()
        val count = if (fresh) t?.optInt("count", 0) ?: 0 else 0
        val pending = data?.optInt("pendingCount", 0) ?: 0

        // Line one: "Today · 2 payments · 3 to review". Where that is wider
        // than the text has (the width less the 16dp and 8dp padding, the
        // 8dp gap and the Add button), the payment count goes first, so the
        // review count never ends in an ellipsis.
        val payments = if (count == 0) "no payments yet"
        else "$count payment${if (count == 1) "" else "s"}"
        val titles = if (pending > 0) listOf(
            "Today · $payments · $pending to review",
            "Today · $pending to review",
        ) else listOf("Today · $payments")
        val addDp = 32 + WidgetKit.textWidthDp(
            context, context.getString(R.string.home_widget_add), 14f, bold = true
        )
        val textDp = widthDp - 16 - 8 - 8 - addDp
        val title = titles.firstOrNull { WidgetKit.textWidthDp(context, it, 12f) <= textDp }
            ?: titles.last()
        views.setTextViewText(R.id.hw_title, title)
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        // Both lines inside the 4dp padding, or the day's spend alone: a
        // one-row cell with large text has room for one line.
        val twoLines = WidgetKit.lineDp(context, 12f) + WidgetKit.lineDp(context, 14f)
        val showTitle = twoLines <= heightDp - 8
        views.setViewVisibility(R.id.hw_title, if (showTitle) View.VISIBLE else View.GONE)

        // Line two: the day's spend as money out, then safe to spend.
        val line = WidgetKit.Line()
        if (t == null) {
            line.add("Open the app once to start", theme.textSecondary)
        } else {
            val spent = if (fresh) t.optDouble("spent", 0.0) else 0.0
            if (spent >= 0.5) {
                line.add("−${t.optString("spentLabel")}", theme.over, bold = true)
            } else {
                line.add("₹0", theme.text, bold = true)
            }
            // With the first line hidden, the review count moves here,
            // ahead of safe to spend, so an ellipsis cuts that first.
            if (!showTitle && pending > 0) {
                line.add(" · ", theme.textSecondary)
                line.add("$pending to review", theme.accentText, bold = true)
            }
            val safe = data?.optJSONObject("safe")
            val safeLabel = safeLabel(safe)
            if (safeLabel != null) {
                line.add(" · ", theme.textSecondary)
                // Over the cap every label reads "Over budget" (older
                // snapshots carry no overCap flag).
                if (safe?.optBoolean("overCap", false) == true ||
                    safeLabel == "Over budget"
                ) {
                    line.add("Over budget", theme.over)
                } else {
                    line.add(safeLabel, theme.text, bold = true)
                    line.add(" safe to spend", theme.textSecondary)
                }
            }
        }
        views.setTextViewText(R.id.hw_amount, line.build())

        // The app's onAccent rule: white on the accent unless it is light.
        views.setInt(R.id.hw_add_bg, "setColorFilter", theme.accent)
        views.setTextColor(R.id.hw_add_label, theme.onAccent)
        views.setOnClickPendingIntent(
            R.id.hw_add,
            openApp(context, id, QuickActions.ADD_EXPENSE, PURPOSE_ADD)
        )
        return views
    }

    /** Safe to spend: today's figure, or the one worked out for a later day
     * of the same month. Null without a budget and past the month's end,
     * until the app writes a new snapshot. */
    private fun safeLabel(safe: JSONObject?): String? = safe?.let { s ->
        if (!s.has("day")) return@let null
        val offset = today() - s.optLong("day")
        when {
            offset == 0L -> s.optString("label")
            offset > 0L -> {
                val next = s.optJSONArray("next")
                if (next != null && offset <= next.length()) {
                    next.optString((offset - 1).toInt())
                } else {
                    null
                }
            }
            else -> null
        }?.ifEmpty { null }
    }

    // --- Spending split -----------------------------------------------------

    private val splitRows = listOf(
        Triple(R.id.hw_split_row1, R.id.hw_split_name1, R.id.hw_split_amt1),
        Triple(R.id.hw_split_row2, R.id.hw_split_name2, R.id.hw_split_amt2),
        Triple(R.id.hw_split_row3, R.id.hw_split_name3, R.id.hw_split_amt3),
        Triple(R.id.hw_split_row4, R.id.hw_split_name4, R.id.hw_split_amt4),
    )
    private val splitDots = listOf(
        R.id.hw_split_dot1, R.id.hw_split_dot2, R.id.hw_split_dot3,
        R.id.hw_split_dot4,
    )

    /** This month's spend as a donut, beside the largest categories. */
    private fun split(
        context: Context,
        widthDp: Int,
        heightDp: Int,
        bitmaps: WidgetKit.Bitmaps,
        id: Int,
        data: JSONObject?,
        theme: WidgetTheme,
    ): RemoteViews {
        val views = base(
            context, R.layout.home_widget_split, theme, id, QuickActions.OPEN_BREAKDOWN
        )
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        val now = LocalDate.now()
        // Last month's snapshot is not this month's split.
        val sameMonth = data?.optInt("monthKey", -1) == now.year * 12 + now.monthValue
        val split = if (sameMonth) data?.optJSONObject("split") else null
        val rows = split?.optJSONArray("rows")
        val total = split?.optDouble("total", 0.0) ?: 0.0
        val monthName = if (sameMonth) data?.optString("monthLabel")
        else now.month.getDisplayName(java.time.format.TextStyle.FULL, Locale.ENGLISH)
        views.setTextViewText(R.id.hw_title, "$monthName spending")
        if (rows == null || rows.length() == 0 || total <= 0) {
            views.setViewVisibility(R.id.hw_body, View.GONE)
            views.setViewVisibility(R.id.hw_empty, View.VISIBLE)
            views.setTextViewText(
                R.id.hw_empty,
                if (data == null) context.getString(R.string.home_widget_empty)
                else "Nothing spent yet this month."
            )
            return views
        }
        views.setViewVisibility(R.id.hw_body, View.VISIBLE)
        views.setViewVisibility(R.id.hw_empty, View.GONE)
        // The body is the height under the title (the card's padding, the
        // title and its 4dp gap). The legend shows as many rows as that
        // holds (1dp gap, then the 12sp line or the 8dp dot); a row that
        // does not fit is left out rather than cut, and its slice stays in
        // the donut.
        val bodyDp = splitBodyDp(context, heightDp)
        val rowDp = 1 + maxOf(8f, WidgetKit.lineDp(context, 12f))
        val fit = WidgetKit.rowsThatFit(bodyDp, rowDp, 1, splitRows.size)
        val slices = mutableListOf<Pair<Double, Int>>()
        splitRows.forEachIndexed { i, (row, name, amount) ->
            val o = rows.optJSONObject(i)
            val color = o?.optLong("color", 0xFF888780)?.toInt() ?: 0
            if (o != null) slices += o.optDouble("amount", 0.0) to color
            if (o == null || i >= fit) {
                views.setViewVisibility(row, View.GONE)
                return@forEachIndexed
            }
            views.setViewVisibility(row, View.VISIBLE)
            views.setTextViewText(name, o.optString("label"))
            views.setTextViewText(amount, o.optString("amountLabel"))
            views.setTextColor(name, theme.text)
            views.setTextColor(amount, theme.textSecondary)
            // The colour is on the dot only; the text stays on the surface.
            views.setInt(splitDots[i], "setColorFilter", color)
        }
        // One donut for both orientations, drawn for the larger of the two
        // and at most 300 pixels across (360 KB); fitCenter shows it
        // at each orientation's size, square, with no distortion. Without
        // bitmaps (the fallback update) the rows take the width.
        val drawDp = bitmaps.sizes.maxOf { (w, h) -> donutDp(context, w, h) }
        bitmaps.get("donut") {
            donut(context, drawDp, slices, total, split.optString("totalLabel"), theme)
        }?.let { views.setImageViewBitmap(R.id.hw_donut, it) }
        return views
    }

    /** The height under Spending split's title: the card's padding, the
     * title and its 4dp gap taken off. */
    private fun splitBodyDp(context: Context, heightDp: Int): Float =
        heightDp - 2 * PAD_V - 4 - WidgetKit.lineDp(context, 12f)

    /** The donut's size: as tall as the body, and never more than 40% of
     * the width, so the rows keep their room. */
    private fun donutDp(context: Context, widthDp: Int, heightDp: Int): Int =
        minOf(splitBodyDp(context, heightDp).toInt(), (widthDp * 0.4).toInt())
            .coerceIn(32, 160)

    /** A ring of [slices] (amount, colour) on the track, the total inside,
     * [sizeDp] across; the stroke and the label scale with it. At most 300
     * pixels across (360 KB): a larger donut on a dense screen is drawn at
     * fewer pixels per dp and scaled up by fitCenter. */
    private fun donut(
        context: Context,
        sizeDp: Int,
        slices: List<Pair<Double, Int>>,
        total: Double,
        label: String,
        theme: WidgetTheme,
    ): Bitmap {
        val density = minOf(context.resources.displayMetrics.density, 300f / sizeDp)
        val size = (sizeDp * density).toInt().coerceAtLeast(32)
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        // 10dp of stroke and 13dp of label at the old fixed 68dp.
        val stroke = size * 10f / 68f
        val inset = stroke / 2 + density
        val oval = RectF(inset, inset, size - inset, size - inset)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
        }
        paint.color = theme.track
        canvas.drawArc(oval, 0f, 360f, false, paint)
        var start = -90f
        for ((amount, color) in slices) {
            val sweep = (amount / total * 360).toFloat()
            if (sweep <= 0f) continue
            paint.color = color
            // A hairline gap between slices, so neighbours read apart; one
            // category alone is the whole ring.
            val gap = if (slices.size > 1) 1.5f else 0f
            canvas.drawArc(oval, start, (sweep - gap).coerceAtLeast(0.5f), false, paint)
            start += sweep
        }
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = theme.text
            textAlign = Paint.Align.CENTER
            isFakeBoldText = true
            textSize = size * 13f / 68f
        }
        // Shrinks a long total to fit inside the ring.
        val room = size - 2 * (stroke + 4 * density)
        while (text.measureText(label) > room && text.textSize > 8 * density) {
            text.textSize -= density
        }
        val y = size / 2f - (text.descent() + text.ascent()) / 2
        canvas.drawText(label, size / 2f, y, text)
        return bmp
    }

    // --- Budgets list -------------------------------------------------------

    private class ListRow(val row: Int, val lead: Int, val name: Int, val amount: Int)

    private val budgetRows = listOf(
        ListRow(R.id.hw_row1, R.id.hw_ring1, R.id.hw_name1, R.id.hw_amt1),
        ListRow(R.id.hw_row2, R.id.hw_ring2, R.id.hw_name2, R.id.hw_amt2),
        ListRow(R.id.hw_row3, R.id.hw_ring3, R.id.hw_name3, R.id.hw_amt3),
        ListRow(R.id.hw_row4, R.id.hw_ring4, R.id.hw_name4, R.id.hw_amt4),
    )

    /** Up to four budgets from the budget snapshot, the overall cap first:
     * a small ring each, the name, and what is left or over; past what the
     * height holds, one row fewer and a count of the rest. */
    private fun budgets(
        context: Context,
        heightDp: Int,
        bitmaps: WidgetKit.Bitmaps,
        id: Int,
        theme: WidgetTheme,
    ): RemoteViews {
        val views = base(
            context, R.layout.home_widget_budgets, theme, id, QuickActions.OPEN_BUDGETS
        )
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        views.setTextColor(R.id.hw_side, theme.textSecondary)
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        val list = WidgetKit.readArray(context, BudgetWidgetProvider.DATA_KEY)
        val entries = if (list == null) emptyList()
        else (0 until list.length()).mapNotNull { list.optJSONObject(it) }
        val first = entries.firstOrNull()
        views.setTextViewText(
            R.id.hw_side,
            first?.optString("monthName")?.ifEmpty { first.optString("monthLabel") } ?: ""
        )
        // As many rows as the height holds under the header (a row is its
        // gap and the 16dp ring or the 13sp line, whichever is taller), up
        // to four. With more budgets than that, one row fewer and a
        // "+N more" line, which is shorter than the row it replaces; with
        // room for one row only, that row alone.
        val room = heightDp - 2 * PAD_V - WidgetKit.lineDp(context, 12f)
        val rowDp = ROW_GAP + maxOf(16f, WidgetKit.lineDp(context, 13f))
        val fit = WidgetKit.rowsThatFit(room, rowDp, 1, budgetRows.size)
        val shown = when {
            entries.size <= fit -> entries.size
            fit >= 2 -> fit - 1
            else -> 1
        }
        budgetRows.forEachIndexed { i, ids ->
            val e = if (i < shown) entries.getOrNull(i) else null
            views.setViewVisibility(ids.row, if (e == null) View.GONE else View.VISIBLE)
            if (e == null) return@forEachIndexed
            val spent = e.optDouble("spent", 0.0)
            val limit = e.optDouble("limit", 0.0)
            val pct = if (limit <= 0) 0 else ((spent / limit) * 100).toInt().coerceAtLeast(0)
            val over = e.optBoolean("over", spent > limit)
            // Keyed by row, so both orientations send each ring once.
            bitmaps.get("ring:$i") {
                WidgetKit.ring(context, 16, 3f, pct, theme.ringColor(pct), theme.track)
            }?.let { views.setImageViewBitmap(ids.lead, it) }
            views.setTextViewText(ids.name, e.optString("name"))
            views.setTextColor(ids.name, theme.text)
            views.setTextViewText(
                ids.amount,
                e.optString("leftLabel").ifEmpty { e.optString("statusLabel") }
            )
            views.setTextColor(ids.amount, if (over) theme.over else theme.text)
        }
        // The rest are not dropped silently: a muted count, and the tap
        // opens every budget in the app.
        val more = entries.size - shown
        views.setViewVisibility(
            R.id.hw_more,
            if (more > 0 && fit >= 2) View.VISIBLE else View.GONE
        )
        views.setTextViewText(R.id.hw_more, "+$more more")
        views.setTextColor(R.id.hw_more, theme.textSecondary)
        views.setViewVisibility(R.id.hw_empty, if (entries.isEmpty()) View.VISIBLE else View.GONE)
        views.setTextViewText(
            R.id.hw_empty,
            if (list == null) context.getString(R.string.home_widget_empty)
            else "No budgets yet. Set a monthly cap or a budget in the app."
        )
        return views
    }

    // --- Recent -------------------------------------------------------------

    private class RecentRow(
        val row: Int,
        val dot: Int,
        val icon: Int,
        val name: Int,
        val time: Int,
        val amount: Int,
    )

    private val recentRows = listOf(
        RecentRow(R.id.hw_row1, R.id.hw_dot1, R.id.hw_icon1, R.id.hw_name1, R.id.hw_when1, R.id.hw_amt1),
        RecentRow(R.id.hw_row2, R.id.hw_dot2, R.id.hw_icon2, R.id.hw_name2, R.id.hw_when2, R.id.hw_amt2),
        RecentRow(R.id.hw_row3, R.id.hw_dot3, R.id.hw_icon3, R.id.hw_name3, R.id.hw_when3, R.id.hw_amt3),
        RecentRow(R.id.hw_row4, R.id.hw_dot4, R.id.hw_icon4, R.id.hw_name4, R.id.hw_when4, R.id.hw_amt4),
    )

    /** The newest four confirmed rows, and how many imports wait. */
    private fun recent(
        context: Context,
        heightDp: Int,
        id: Int,
        data: JSONObject?,
        theme: WidgetTheme,
    ): RemoteViews {
        val views = base(
            context, R.layout.home_widget_recent, theme, id, QuickActions.OPEN_TRANSACTIONS
        )
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        val pending = data?.optInt("pendingCount", 0) ?: 0
        views.setViewVisibility(R.id.hw_side, if (pending > 0) View.VISIBLE else View.GONE)
        views.setTextViewText(R.id.hw_side, "$pending to review")
        views.setTextColor(R.id.hw_side, theme.accentText)
        val items = data?.optJSONArray("recent")
        // As many rows as the height holds under the header: a row is its
        // gap and the 13sp name (taller than the 15dp icon and the 11sp
        // time), up to four, the newest first.
        val room = heightDp - 2 * PAD_V - WidgetKit.lineDp(context, 12f)
        val rowDp = ROW_GAP + maxOf(15f, WidgetKit.lineDp(context, 13f))
        val fit = WidgetKit.rowsThatFit(room, rowDp, 1, recentRows.size)
        recentRows.forEachIndexed { i, ids ->
            val o = if (i < fit) items?.optJSONObject(i) else null
            views.setViewVisibility(ids.row, if (o == null) View.GONE else View.VISIBLE)
            if (o == null) return@forEachIndexed
            // The merchant names a row best; the category when there is none.
            val merchant = if (o.isNull("merchant")) "" else o.optString("merchant")
            views.setTextViewText(ids.name, merchant.ifEmpty { o.optString("label") })
            views.setTextColor(ids.name, theme.text)
            val day = dayName(o.optLong("day", -1), o.optString("dateLabel"))
            val time = if (o.isNull("timeLabel")) "" else o.optString("timeLabel")
            views.setTextViewText(
                ids.time,
                if (day == "Today" && time.isNotEmpty()) time else day
            )
            views.setTextColor(ids.time, theme.textSecondary)
            views.setTextViewText(ids.amount, o.optString("amountLabel"))
            views.setTextColor(ids.amount, theme.moneyColor(o.optString("kind")))
            views.setImageViewResource(ids.icon, WidgetKit.icon(o.optString("icon")))
            views.setInt(ids.icon, "setColorFilter", theme.textSecondary)
            // The accent dot marks a row that counted at once and is not
            // opened yet; invisible, not gone, so the icons stay in line.
            views.setViewVisibility(
                ids.dot,
                if (o.optBoolean("unseen", false)) View.VISIBLE else View.INVISIBLE
            )
            views.setInt(ids.dot, "setColorFilter", theme.accent)
        }
        val empty = items == null || items.length() == 0
        views.setViewVisibility(R.id.hw_empty, if (empty) View.VISIBLE else View.GONE)
        views.setTextViewText(
            R.id.hw_empty,
            if (data == null) context.getString(R.string.home_widget_empty)
            else "No transactions yet."
        )
        return views
    }

    // --- Quick actions ------------------------------------------------------

    private fun actions(context: Context, widthDp: Int, id: Int, theme: WidgetTheme): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.home_widget_actions)
        WidgetKit.applyCard(views, theme)
        // Each label has a third of the width less the 6dp card padding,
        // the 3dp button margins and its own 6dp padding. The three share
        // one size: 13sp, or smaller down to 11sp where "Import SMS" would
        // otherwise end in an ellipsis on a narrow widget or with large text.
        val labels = listOf(
            R.id.hw_act_expense_label to R.string.home_widget_action_expense,
            R.id.hw_act_income_label to R.string.home_widget_action_income,
            R.id.hw_act_import_label to R.string.shortcut_import_sms,
        )
        val roomDp = (widthDp - 12 - 18) / 3f - 12
        val sp = listOf(13f, 12f, 11f).firstOrNull { size ->
            labels.all { (_, text) ->
                WidgetKit.textWidthDp(context, context.getString(text), size, bold = true) <= roomDp
            }
        } ?: 11f
        for ((label, _) in labels) {
            views.setTextViewTextSize(label, TypedValue.COMPLEX_UNIT_SP, sp)
        }
        // Expense is the main action: the accent fill with the app's label
        // colour on it. The other two sit on the neutral track colour.
        views.setInt(R.id.hw_act_expense_bg, "setColorFilter", theme.accent)
        views.setTextColor(R.id.hw_act_expense_label, theme.onAccent)
        views.setInt(R.id.hw_act_income_bg, "setColorFilter", theme.track)
        views.setTextColor(R.id.hw_act_income_label, theme.text)
        views.setInt(R.id.hw_act_import_bg, "setColorFilter", theme.track)
        views.setTextColor(R.id.hw_act_import_label, theme.text)
        views.setOnClickPendingIntent(
            R.id.hw_act_expense,
            openApp(context, id, QuickActions.ADD_EXPENSE, PURPOSE_ADD)
        )
        views.setOnClickPendingIntent(
            R.id.hw_act_income,
            openApp(context, id, QuickActions.ADD_INCOME, PURPOSE_INCOME)
        )
        views.setOnClickPendingIntent(
            R.id.hw_act_import,
            openApp(context, id, QuickActions.IMPORT_SMS, PURPOSE_IMPORT)
        )
        return views
    }

    // --- Big bills and This week --------------------------------------------

    /** Days a bill stays listed past its date: the app's grace days
     * (kSubscriptionGraceDays). */
    private const val BILL_GRACE_DAYS = 7L

    /** Monday first, as the app's week runs. */
    private val dayInitials = List(7) {
        java.time.DayOfWeek.of(it + 1)
            .getDisplayName(java.time.format.TextStyle.NARROW, Locale.ENGLISH)
    }

    /** [text] in place of the body. */
    private fun showEmpty(views: RemoteViews, text: String) {
        views.setViewVisibility(R.id.hw_body, View.GONE)
        views.setViewVisibility(R.id.hw_empty, View.VISIBLE)
        views.setTextViewText(R.id.hw_empty, text)
    }

    private fun showBody(views: RemoteViews) {
        views.setViewVisibility(R.id.hw_body, View.VISIBLE)
        views.setViewVisibility(R.id.hw_empty, View.GONE)
    }

    /** "Today", "Tomorrow" or the date, for a bill due on epoch [day]. */
    private fun dueName(day: Long, dateLabel: String): String = when (day - today()) {
        0L -> "Today"
        1L -> "Tomorrow"
        else -> dateLabel
    }

    /** The first of the snapshot's next bills not past its grace days, so
     * a bill paid late drops off on the day the widget draws. */
    private fun nextBill(bills: JSONObject): JSONObject? {
        val next = bills.optJSONArray("next") ?: return null
        val today = today()
        for (i in 0 until next.length()) {
            val o = next.optJSONObject(i) ?: continue
            if (o.optLong("dueDay", today) - today >= -BILL_GRACE_DAYS) return o
        }
        return null
    }

    private fun bigBillsEmpty(context: Context, data: JSONObject?): String =
        if (data == null) context.getString(R.string.home_widget_empty)
        else "No quarterly, half-yearly or yearly bills yet."

    /** The 12 months from this one. A snapshot from an earlier month is
     * shifted along, so the strip moves on with the month; the months past
     * its end are null and draw as stubs. */
    private fun billsByMonth(bills: JSONObject): List<Double?> {
        val now = LocalDate.now()
        val key = now.year * 12 + now.monthValue
        // A plain number, as Month pace compares it.
        val shift = (key - bills.optInt("monthKey", key)).coerceAtLeast(0)
        val months = bills.optJSONArray("months")
        return List(12) { i ->
            val k = i + shift
            if (months != null && k < months.length()) months.optDouble(k, 0.0) else null
        }
    }

    /** The initials of the 12 months from this one, from today's date. */
    private fun monthInitials(): List<String> {
        val now = LocalDate.now()
        return List(12) {
            now.plusMonths(it.toLong()).month
                .getDisplayName(java.time.format.TextStyle.NARROW, Locale.ENGLISH)
        }
    }

    private fun bigBills(
        context: Context,
        widthDp: Int,
        heightDp: Int,
        bitmaps: WidgetKit.Bitmaps,
        id: Int,
        data: JSONObject?,
        theme: WidgetTheme,
    ): RemoteViews {
        val views = base(
            context, R.layout.home_widget_big_bills, theme, id, QuickActions.OPEN_BIG_BILLS
        )
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        views.setTextColor(R.id.hw_side, theme.textSecondary)
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        val bills = data?.optJSONObject("bigBills")
        if (bills == null) {
            showEmpty(views, bigBillsEmpty(context, data))
            return views
        }
        showBody(views)
        views.setTextViewText(R.id.hw_side, "${bills.optString("yearlyLabel")} a year")
        // The figure and the 24dp strip 4dp under it always show; the next
        // bill (2dp under the strip) when the height has room for it, and
        // the title row when it has room for that as well, so large text
        // never clips.
        val room = heightDp - 2 * PAD_V
        val core = WidgetKit.lineDp(context, 18f) + 4 + 24
        val nextDp = 2 + WidgetKit.lineDp(context, 13f)
        val next = nextBill(bills)
        val showNext = next != null && core + nextDp <= room
        val showTitle =
            core + WidgetKit.lineDp(context, 12f) + (if (showNext) nextDp else 0f) <= room
        views.setViewVisibility(R.id.hw_head, if (showTitle) View.VISIBLE else View.GONE)
        // A target, not money spent: plain, as the app's headline prints
        // it. Without the title row the line says what it is for.
        views.setTextViewText(
            R.id.hw_amount,
            WidgetKit.Line()
                .add(bills.optString("monthlyLabel"), theme.text, bold = true)
                .add(
                    if (showTitle) " a month" else " a month for big bills",
                    theme.textSecondary
                )
                .build()
        )
        // One strip per width: both orientations share it where the widths
        // match. Without bitmaps (the fallback update) it stays empty.
        bitmaps.get("strip:$widthDp") {
            strip(context, widthDp, billsByMonth(bills), monthInitials(), 0, theme)
        }?.let { views.setImageViewBitmap(R.id.hw_strip, it) }
        views.setViewVisibility(R.id.hw_next_row, if (showNext) View.VISIBLE else View.GONE)
        if (next != null) {
            views.setTextViewText(
                R.id.hw_next,
                WidgetKit.Line()
                    .add("Next: ", theme.textSecondary)
                    .add(next.optString("label"), theme.text)
                    .add(
                        " · ${dueName(next.optLong("dueDay"), next.optString("dueLabel"))}",
                        theme.textSecondary
                    )
                    .build()
            )
            // The bill's amount in the money-out red, as the app's card has it.
            views.setTextViewText(R.id.hw_next_amt, next.optString("amountLabel"))
            views.setTextColor(R.id.hw_next_amt, theme.over)
        }
        return views
    }

    private fun bigBillsCompact(
        context: Context,
        heightDp: Int,
        id: Int,
        data: JSONObject?,
        theme: WidgetTheme,
    ): RemoteViews {
        val views = base(
            context, R.layout.home_widget_big_bills_compact, theme, id,
            QuickActions.OPEN_BIG_BILLS
        )
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        val bills = data?.optJSONObject("bigBills")
        if (bills == null) {
            showEmpty(views, bigBillsEmpty(context, data))
            return views
        }
        showBody(views)
        views.setTextViewText(
            R.id.hw_title,
            WidgetKit.Line()
                .add(bills.optString("monthlyLabel"), theme.text, bold = true)
                .add(" a month for big bills", theme.textSecondary)
                .build()
        )
        // Both lines inside the 4dp padding, or the figure alone: a one-row
        // cell with large text has room for one line.
        val twoLines = WidgetKit.lineDp(context, 14f) + WidgetKit.lineDp(context, 12f)
        views.setViewVisibility(R.id.hw_sub, if (twoLines <= heightDp - 8) View.VISIBLE else View.GONE)
        val next = nextBill(bills)
        val sub = WidgetKit.Line()
        if (next == null) {
            sub.add("${bills.optString("yearlyLabel")} a year", theme.textSecondary)
        } else {
            sub.add("Next: ", theme.textSecondary)
            sub.add(next.optString("label"), theme.text)
            sub.add(
                " · ${dueName(next.optLong("dueDay"), next.optString("dueLabel"))} · ",
                theme.textSecondary
            )
            sub.add(next.optString("amountLabel"), theme.over, bold = true)
        }
        views.setTextViewText(R.id.hw_sub, sub.build())
        return views
    }

    /** The week block as of today. Once its week is over (a new Monday the
     * app has not seen), nothing is spent and the bars are empty. [usual]
     * is the usual week cut to today, null under 2 weeks of history or once
     * the block's week is over: last week's usual is not this week's. */
    private class WeekView(
        val spent: Double,
        val spentLabel: String,
        val byDay: List<Double>,
        val usual: Double?,
        val toReview: Int,
        val today: Int,
    )

    private fun weekView(week: JSONObject): WeekView {
        val now = LocalDate.now()
        val day = now.dayOfWeek.value - 1
        val monday = now.minusDays(day.toLong()).toEpochDay()
        val fresh = week.optLong("weekStart", -1) == monday
        val byDay = week.optJSONArray("byDay")
        // isNull, not optDouble: no usual week yet is not a usual of ₹0.
        val usual = week.optJSONArray("usualByDay")
        return WeekView(
            spent = if (fresh) week.optDouble("spent", 0.0) else 0.0,
            spentLabel = if (fresh) week.optString("spentLabel") else "₹0",
            byDay = List(7) { i ->
                if (fresh && i <= day && byDay != null) byDay.optDouble(i, 0.0) else 0.0
            },
            usual = if (!fresh || usual == null || day >= usual.length() || usual.isNull(day)) null
            else usual.optDouble(day),
            toReview = if (fresh) week.optInt("toReview", 0) else 0,
            today = day,
        )
    }

    /** The empty line, or null when there is a week to show: nothing spent
     * and no usual week to compare against leaves nothing to draw. */
    private fun weekEmpty(context: Context, w: WeekView?): String? = when {
        w == null -> context.getString(R.string.home_widget_empty)
        w.spent < 0.5 && w.usual == null -> "Nothing spent this week."
        else -> null
    }

    private fun thisWeek(
        context: Context,
        widthDp: Int,
        heightDp: Int,
        bitmaps: WidgetKit.Bitmaps,
        id: Int,
        data: JSONObject?,
        theme: WidgetTheme,
    ): RemoteViews {
        val views = base(
            context, R.layout.home_widget_week, theme, id, QuickActions.OPEN_WEEKLY_DIGEST
        )
        views.setTextColor(R.id.hw_title, theme.textSecondary)
        views.setTextColor(R.id.hw_side, theme.textSecondary)
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        val w = data?.optJSONObject("week")?.let { weekView(it) }
        val empty = weekEmpty(context, w)
        if (w == null || empty != null) {
            showEmpty(views, empty ?: context.getString(R.string.home_widget_empty))
            return views
        }
        showBody(views)
        val usual = w.usual
        views.setViewVisibility(R.id.hw_side, if (usual != null) View.VISIBLE else View.GONE)
        if (usual != null) views.setTextViewText(R.id.hw_side, "usual ${WidgetKit.rupees(usual)}")
        // As Big bills: the figure and the strip always, then the gap line,
        // then the title row, as the height allows.
        val room = heightDp - 2 * PAD_V
        val core = WidgetKit.lineDp(context, 18f) + 4 + 24
        val subDp = 2 + WidgetKit.lineDp(context, 13f)
        val showSub = core + subDp <= room
        val showTitle =
            core + WidgetKit.lineDp(context, 12f) + (if (showSub) subDp else 0f) <= room
        views.setViewVisibility(R.id.hw_head, if (showTitle) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.hw_sub, if (showSub) View.VISIBLE else View.GONE)
        // Money out in the expense red; nothing spent is a plain ₹0.
        val amount = WidgetKit.Line()
        if (w.spent >= 0.5) {
            amount.add(w.spentLabel, theme.over, bold = true)
        } else {
            amount.add("₹0", theme.text, bold = true)
        }
        amount.add(if (showTitle) " spent so far" else " spent this week", theme.textSecondary)
        views.setTextViewText(R.id.hw_amount, amount.build())
        bitmaps.get("week:$widthDp") {
            strip(context, widthDp, w.byDay, dayInitials, w.today, theme)
        }?.let { views.setImageViewBitmap(R.id.hw_strip, it) }
        // The app's ₹1 cut-off for "about the same".
        val sub = WidgetKit.Line()
        when {
            usual == null -> sub.add("No usual week yet", theme.textSecondary)
            abs(w.spent - usual) < 1 -> sub.add("About the same as usual", theme.text)
            w.spent > usual ->
                sub.add("${WidgetKit.rupees(w.spent - usual)} more than usual", theme.text)
            else -> sub.add("${WidgetKit.rupees(usual - w.spent)} less than usual", theme.text)
        }
        if (w.toReview > 0) {
            sub.add(" · ", theme.textSecondary)
            sub.add("${w.toReview} to review", theme.accentText, bold = true)
        }
        views.setTextViewText(R.id.hw_sub, sub.build())
        return views
    }

    private fun thisWeekCompact(
        context: Context,
        widthDp: Int,
        heightDp: Int,
        bitmaps: WidgetKit.Bitmaps,
        id: Int,
        data: JSONObject?,
        theme: WidgetTheme,
    ): RemoteViews {
        val views = base(
            context, R.layout.home_widget_week_compact, theme, id,
            QuickActions.OPEN_WEEKLY_DIGEST
        )
        views.setTextColor(R.id.hw_side, theme.textSecondary)
        views.setTextColor(R.id.hw_empty, theme.textSecondary)
        val w = data?.optJSONObject("week")?.let { weekView(it) }
        val empty = weekEmpty(context, w)
        if (w == null || empty != null) {
            showEmpty(views, empty ?: context.getString(R.string.home_widget_empty))
            return views
        }
        showBody(views)
        val title = WidgetKit.Line().add("This week ", theme.textSecondary)
        if (w.spent >= 0.5) {
            title.add(w.spentLabel, theme.over, bold = true)
        } else {
            title.add("₹0", theme.text, bold = true)
        }
        views.setTextViewText(R.id.hw_title, title.build())
        val usual = w.usual
        views.setViewVisibility(R.id.hw_side, if (usual != null) View.VISIBLE else View.GONE)
        if (usual != null) views.setTextViewText(R.id.hw_side, "usual ${WidgetKit.rupees(usual)}")
        // The bar under the line when both fit inside the 4dp padding: a
        // one-row cell with large text shows the line alone. No usual week,
        // nothing to fill against.
        val fits = WidgetKit.lineDp(context, 14f) + 2 + 14 <= heightDp - 8
        views.setViewVisibility(
            R.id.hw_bar,
            if (usual != null && fits) View.VISIBLE else View.GONE
        )
        if (usual != null && fits) {
            val over = w.spent - usual >= 1
            val fill = when {
                usual > 0 -> (w.spent / usual).coerceIn(0.0, 1.0)
                w.spent >= 0.5 -> 1.0
                else -> 0.0
            }
            // Month pace's bar, without its tick: full and red once past usual.
            bitmaps.get("weekbar:$widthDp") {
                paceBar(context, widthDp, fill, null, if (over) theme.over else theme.accent, theme)
            }?.let { views.setImageViewBitmap(R.id.hw_bar, it) }
        }
        return views
    }

    /** One bar per entry of [values], scaled to the largest, in the
     * money-out red; an entry with nothing (zero or null) is a 2dp stub on
     * the track. [labels] sit under the bars, the one at [bold] in bold.
     * Drawn at the width the strip has, 24dp tall, at most 2 pixels per dp
     * and 1200 pixels wide, as [paceBar] is. */
    private fun strip(
        context: Context,
        widgetW: Int,
        values: List<Double?>,
        labels: List<String>,
        bold: Int,
        theme: WidgetTheme,
    ): Bitmap {
        val density = minOf(context.resources.displayMetrics.density, 2f)
        val w = ((widgetW - 2 * PAD_H) * density).toInt().coerceIn(64, 1200)
        val h = (24 * density).toInt().coerceAtLeast(16)
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = theme.textSecondary
            textAlign = Paint.Align.CENTER
            textSize = 9 * density
        }
        // The labels take the bottom 11dp; the bars stand on the line above.
        val floor = h - 11 * density
        val n = values.size
        val gap = 4 * density
        val barW = (w - gap * (n - 1)) / n
        val largest = values.maxOf { it ?: 0.0 }
        val r = minOf(2 * density, barW / 2)
        for (i in 0 until n) {
            val x = i * (barW + gap)
            val v = values[i] ?: 0.0
            if (v > 0 && largest > 0) {
                // A small amount stays visible beside a big one.
                val barH = (floor * (v / largest).coerceIn(0.06, 1.0)).toFloat()
                paint.color = theme.over
                canvas.drawRoundRect(RectF(x, floor - barH, x + barW, floor), r, r, paint)
            } else {
                paint.color = theme.track
                canvas.drawRect(x, floor - 2 * density, x + barW, floor, paint)
            }
            text.typeface = if (i == bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
            labels.getOrNull(i)?.let {
                canvas.drawText(it, x + barW / 2, h - text.descent(), text)
            }
        }
        return bmp
    }
}

/** Month pace (4x2): spent so far against the cap or a usual month. */
class MonthPaceWidgetProvider : HomeWidgetProviderBase()

/** Upcoming (4x2): the next three bills or income due. */
class UpcomingWidgetProvider : HomeWidgetProviderBase()

/** Today and Add (4x1): today's spend and an Add expense button. */
class TodayAddWidgetProvider : HomeWidgetProviderBase()

/** Spending split (4x2): this month's spend by category, as a donut. */
class SpendingSplitWidgetProvider : HomeWidgetProviderBase()

/** Budgets list (4x2): every budget's left or over, from the budget
 * snapshot. */
class BudgetsListWidgetProvider : HomeWidgetProviderBase()

/** Recent (4x2): the newest four transactions and the review count. */
class RecentWidgetProvider : HomeWidgetProviderBase()

/** Quick actions (4x1): Expense, Income and Import SMS buttons. */
class QuickActionsWidgetProvider : HomeWidgetProviderBase()

/** Big bills (4x2): the monthly figure to set aside for quarterly,
 * half-yearly and yearly bills, a 12-month strip and the next bill. */
class BigBillsWidgetProvider : HomeWidgetProviderBase()

/** Big bills (compact, 4x1): the monthly figure and the next bill. */
class BigBillsCompactWidgetProvider : HomeWidgetProviderBase()

/** This week (4x2): spent so far against the usual week, a bar per day. */
class ThisWeekWidgetProvider : HomeWidgetProviderBase()

/** This week (compact, 4x1): spent so far against usual, as one bar. */
class ThisWeekCompactWidgetProvider : HomeWidgetProviderBase()

/** One picker entry per subclass; [HomeWidgets.render] picks the layout. */
abstract class HomeWidgetProviderBase : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) HomeWidgets.render(context, manager, id)
    }

    /** A resize changes the rows that fit, the pace bar's width and the
     * donut's size. */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        newOptions: Bundle,
    ) {
        HomeWidgets.render(context, manager, id)
    }
}
