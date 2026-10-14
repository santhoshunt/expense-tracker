package com.fabletest.expense_tracker

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * The app's colours for every home-screen widget and the budget widget's
 * setup screen, as buildWidgetTheme (budget_widget_service.dart) writes
 * them. Each key has a dark-kit default: a widget drawn before the app has
 * synced, or from a snapshot an older build wrote, still draws.
 */
class WidgetTheme(private val json: JSONObject?) {
    private fun c(key: String, fallback: Long) =
        (json?.optLong(key, fallback) ?: fallback).toInt()

    val surface = c("surface", 0xFF252836)

    /** The card fill: the surface with a trace of the accent. */
    val cardFill = if (json?.has("cardFill") == true) c("cardFill", 0) else surface

    /** The card's hairline, or null where the app draws none. */
    val border: Int? = if (json?.has("border") == true) c("border", 0) else null
    val bg = c("bg", 0xFF1B1927)
    val text = c("text", 0xFFFFFFFF)
    val textSecondary = c("textSecondary", 0xFFB4C0C8)
    val track = c("track", 0xFF3B3F4F)

    /** Money in, and a budget well inside its limit. */
    val safe = c("safe", 0xFF50D1AA)
    val warn = c("warn", 0xFFFFB572)

    /** Money out, and a budget at or past its limit. */
    val over = c("over", 0xFFFF7CA3)
    val accent = c("accent", 0xFF4A90E2)

    /** The accent as small text on the card: the app's accentTextColor
     * (darkened to read on the light theme). */
    val accentText = if (json?.has("accentText") == true) c("accentText", 0) else accent

    /** The label on an accent fill, by the app's onAccent rule. */
    val onAccent = c("onAccent", 0xFFFFFFFF)

    /** Green below 80% used, orange from 80% to 95%, red above: the app's
     * budgetColor ladder. */
    fun ringColor(pct: Int) = when {
        pct > 95 -> over
        pct >= 80 -> warn
        else -> safe
    }

    /** An amount's colour by the snapshot's kind: "in" green, "out" red,
     * "neutral" (a transfer, or a row left out of the totals) plain. */
    fun moneyColor(kind: String?) = when (kind) {
        "in" -> safe
        "out" -> over
        else -> text
    }

    companion object {
        fun read(context: Context) =
            WidgetTheme(WidgetKit.readObject(context, WidgetKit.THEME_KEY))
    }
}

/** Drawing helpers the widget providers share. */
object WidgetKit {
    const val FLUTTER_PREFS = "FlutterSharedPreferences"
    const val THEME_KEY = "flutter.budget_widget_theme_v1"

    private fun raw(context: Context, key: String): String? =
        context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
            .getString(key, null)

    /** [key]'s JSON object, or null when missing or malformed: a bad
     * snapshot shows the empty state instead of crashing the launcher. */
    fun readObject(context: Context, key: String): JSONObject? = try {
        raw(context, key)?.let { JSONObject(it) }
    } catch (_: Exception) {
        null
    }

    fun readArray(context: Context, key: String): org.json.JSONArray? = try {
        raw(context, key)?.let { org.json.JSONArray(it) }
    } catch (_: Exception) {
        null
    }

    /** Paints the card: the fill, and the hairline where the app has one.
     * Every widget layout carries `hw_bg` and `hw_border`. */
    fun applyCard(views: RemoteViews, theme: WidgetTheme) {
        views.setInt(R.id.hw_bg, "setColorFilter", theme.cardFill)
        val border = theme.border
        if (border == null) {
            views.setViewVisibility(R.id.hw_border, View.GONE)
        } else {
            views.setViewVisibility(R.id.hw_border, View.VISIBLE)
            views.setInt(R.id.hw_border, "setColorFilter", border)
        }
    }

    /** The widget's size in dp as it is drawn now: the launcher reports
     * the portrait cell as min width by max height and the landscape one
     * as max width by min height. */
    fun sizeDp(context: Context, options: Bundle?, fallbackW: Int, fallbackH: Int): Pair<Int, Int> {
        val portrait = context.resources.configuration.orientation !=
            Configuration.ORIENTATION_LANDSCAPE
        fun opt(key: String, fallback: Int) =
            options?.getInt(key, 0)?.takeIf { it > 0 } ?: fallback
        return if (portrait) {
            opt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, fallbackW) to
                opt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, fallbackH)
        } else {
            opt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, fallbackW) to
                opt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, fallbackH)
        }
    }

    /** The sizes, width by height in dp, the widget is drawn at: the
     * landscape cell (max width by min height), then the portrait one (min
     * width by max height). One size when they match or the launcher has
     * not reported any. */
    fun orientationSizes(
        context: Context,
        options: Bundle?,
        fallbackW: Int,
        fallbackH: Int,
    ): List<Pair<Int, Int>> {
        fun opt(key: String) = options?.getInt(key, 0) ?: 0
        val minW = opt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
        val maxW = opt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH)
        val minH = opt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
        val maxH = opt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
        if (minW <= 0 || maxW <= 0 || minH <= 0 || maxH <= 0) {
            return listOf(sizeDp(context, options, fallbackW, fallbackH))
        }
        if (minW == maxW && minH == maxH) return listOf(minW to maxH)
        return listOf(maxW to minH, minW to maxH)
    }

    /** The bitmaps of one update, each drawn once: where both orientations
     * ask for the same [key] they get the same instance, and RemoteViews
     * sends a shared instance once. [sizes] are the orientation sizes being
     * drawn, so a bitmap shared across them can be drawn at the larger.
     * With [enabled] false it draws none: the fallback update. */
    class Bitmaps(val sizes: List<Pair<Int, Int>>, val enabled: Boolean = true) {
        private val drawn = HashMap<String, Bitmap>()

        fun get(key: String, draw: () -> Bitmap): Bitmap? =
            if (enabled) drawn.getOrPut(key, draw) else null
    }

    /** Sends the widget drawn once per orientation: the launcher shows the
     * one for its orientation, so rows and bitmaps sized for one never clip
     * in the other. [build] gets the width and height in dp and the update's
     * [Bitmaps]. Where the system refuses the update (bitmaps can pass the
     * binder's size limit), it sends the same views without bitmaps, so the
     * widget never stays frozen on an old picture. */
    fun update(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        fallbackW: Int,
        fallbackH: Int,
        build: (Int, Int, Bitmaps) -> RemoteViews,
    ) {
        val sizes = orientationSizes(
            context, manager.getAppWidgetOptions(id), fallbackW, fallbackH
        )
        fun views(bitmaps: Bitmaps): RemoteViews {
            val drawn = sizes.map { (w, h) -> build(w, h, bitmaps) }
            return if (drawn.size == 1) drawn[0] else RemoteViews(drawn[0], drawn[1])
        }
        try {
            manager.updateAppWidget(id, views(Bitmaps(sizes)))
        } catch (_: RuntimeException) {
            // TransactionTooLargeException reaches here wrapped in a
            // RuntimeException by AppWidgetManager.
            manager.updateAppWidget(id, views(Bitmaps(sizes, enabled = false)))
        }
    }

    /** How tall one line of [sp] text draws in a TextView, in dp: the
     * font's top to bottom (TextView keeps that padding by default), at the
     * user's font size. applyDimension follows Android 14's nonlinear
     * scaling, and the paint measures the phone's own system font. */
    fun lineDp(context: Context, sp: Float): Float {
        val dm = context.resources.displayMetrics
        val paint = Paint().apply {
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, dm)
        }
        val fm = paint.fontMetricsInt
        return (fm.bottom - fm.top) / dm.density
    }

    /** How wide [text] draws at [sp], in dp, at the user's font size. */
    fun textWidthDp(context: Context, text: String, sp: Float, bold: Boolean = false): Float {
        val dm = context.resources.displayMetrics
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, dm)
            typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        }
        return paint.measureText(text) / dm.density
    }

    /** How many rows of [rowDp] fit in [roomDp], from [min] to [max]. */
    fun rowsThatFit(roomDp: Float, rowDp: Float, min: Int, max: Int): Int =
        if (rowDp <= 0f) max else (roomDp / rowDp).toInt().coerceIn(min, max)

    /** A budget ring [sizeDp] across: the track, then [pct] of it (full
     * from 100%) in [color]. A bitmap, so the colour shows on every
     * Android version. */
    fun ring(
        context: Context,
        sizeDp: Int,
        strokeDp: Float,
        pct: Int,
        color: Int,
        track: Int,
    ): Bitmap {
        val density = context.resources.displayMetrics.density
        val size = (sizeDp * density).toInt().coerceAtLeast(8)
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val stroke = strokeDp * density
        val inset = stroke / 2 + density / 2
        val oval = RectF(inset, inset, size - inset, size - inset)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
        }
        paint.color = track
        canvas.drawArc(oval, 0f, 360f, false, paint)
        val sweep = pct.coerceIn(0, 100) * 3.6f
        if (sweep > 0f) {
            paint.color = color
            paint.strokeCap = if (sweep >= 360f) Paint.Cap.BUTT else Paint.Cap.ROUND
            canvas.drawArc(oval, -90f, sweep, false, paint)
        }
        return bmp
    }

    /** The drawable for an app category icon key (kCategoryIconChoices in
     * transaction.dart). A fixed `when`, never getIdentifier: the release
     * shrinker drops resources that are only named in strings. */
    fun icon(key: String?): Int = when (key) {
        "food", "cafe" -> R.drawable.widget_ic_food
        "groceries" -> R.drawable.widget_ic_cart
        "bill", "water", "wifi" -> R.drawable.widget_ic_bill
        "power" -> R.drawable.widget_ic_bolt
        "phone" -> R.drawable.widget_ic_phone
        "home", "rent" -> R.drawable.widget_ic_home
        "car", "fuel", "travel" -> R.drawable.widget_ic_car
        "bag", "shop", "gift" -> R.drawable.widget_ic_bag
        "card", "cardOk" -> R.drawable.widget_ic_card
        "movie", "music", "game" -> R.drawable.widget_ic_movie
        "cash", "money", "savings", "invest", "work" -> R.drawable.widget_ic_income
        "transfer" -> R.drawable.widget_ic_transfer
        "wallet" -> R.drawable.widget_ic_wallet
        else -> R.drawable.widget_ic_category
    }

    /** Whole rupees with Indian grouping, as the app's fmtMoney prints
     * them: ₹1,42,500. Hand-grouped, so no device locale changes it. */
    fun rupees(v: Double): String {
        val digits = abs(v).roundToLong().toString()
        if (digits.length <= 3) return "₹$digits"
        val head = digits.dropLast(3)
        val tail = digits.takeLast(3)
        val groups = mutableListOf<String>()
        var rest = head
        while (rest.length > 2) {
            groups.add(0, rest.takeLast(2))
            rest = rest.dropLast(2)
        }
        if (rest.isNotEmpty()) groups.add(0, rest)
        return "₹" + groups.joinToString(",") + "," + tail
    }

    /** One line in several colours: each part's text in its colour, bold
     * where asked. RemoteViews carries these spans to the launcher. */
    class Line {
        private val sb = SpannableStringBuilder()

        fun add(text: String, color: Int, bold: Boolean = false): Line {
            if (text.isEmpty()) return this
            val start = sb.length
            sb.append(text)
            sb.setSpan(
                ForegroundColorSpan(color), start, sb.length,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            )
            if (bold) {
                sb.setSpan(
                    StyleSpan(Typeface.BOLD), start, sb.length,
                    Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
                )
            }
            return this
        }

        fun build(): CharSequence = sb
    }
}
