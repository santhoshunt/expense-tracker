package com.fabletest.expense_tracker

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject

/**
 * Per-instance widget setup: shown by the launcher when a budget widget is
 * added, and again from the widget's long-press menu (reconfigurable, from
 * Android 12). Lists the budgets from the Dart-written snapshot (overall cap
 * first, then customs, see budget_widget_service.dart); a tap stores the
 * mapping for this appWidgetId, renders the widget once, and finishes.
 * Built programmatically in the app's own colours (the theme the Dart side
 * writes for the widgets): its background, card fill and hairline, text
 * and accent.
 */
class BudgetWidgetConfigActivity : Activity() {
    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    /** The app's colours (not Activity.getTheme, the window theme). */
    private lateinit var colors: WidgetTheme

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        appWidgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

        // Android contract: cancelled until a choice is made, so backing out
        // aborts the widget add instead of leaving an unconfigured shell. A
        // reconfigure the user backs out of keeps the widget as it was.
        setResult(RESULT_CANCELED)
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        colors = WidgetTheme.read(this)
        val current = BudgetWidgetProvider.selectionOf(this, appWidgetId)

        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(28))
        }
        list.addView(
            TextView(this).apply {
                text = "Budget widget"
                setTextColor(colors.textSecondary)
                setTypeface(typeface, Typeface.BOLD)
                letterSpacing = 0.09f
                isAllCaps = true
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setPadding(dp(2), 0, 0, dp(6))
            }
        )
        list.addView(
            TextView(this).apply {
                text = "Choose a budget for this widget"
                setTextColor(colors.text)
                setTypeface(typeface, Typeface.BOLD)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
                setPadding(0, 0, 0, dp(20))
            }
        )

        val budgets = readSnapshot()
        if (budgets.isEmpty()) {
            list.addView(
                card().apply {
                    text =
                        "No budgets yet.\n\nSet a monthly cap or create a " +
                        "custom budget in the app, come back to the home " +
                        "screen, and add this widget again."
                    setTextColor(colors.textSecondary)
                    background = shape(colors.cardFill, colors.border)
                }
            )
            list.addView(
                card().apply {
                    text = "Open Expense Tracker"
                    gravity = Gravity.CENTER
                    // The app's main button: the accent with its label
                    // colour on it.
                    setTextColor(colors.onAccent)
                    setTypeface(typeface, Typeface.BOLD)
                    background = ripple(colors.accent, null)
                    setOnClickListener {
                        // The LAUNCH intent, not MainActivity directly: the
                        // alternate-icon feature disables .MainActivity in
                        // favour of an alias, and starting a disabled
                        // component silently does nothing.
                        startActivity(BudgetWidgetProvider.launchIntent(this@BudgetWidgetConfigActivity))
                        finish()
                    }
                }
            )
        } else {
            for (b in budgets) {
                val id = b.optString("id")
                val chosen = id == current
                list.addView(
                    card().apply {
                        text = "${b.optString("name")}\n" +
                            "${b.optString("limitLabel")} · " +
                            b.optString("monthLabel") +
                            if (chosen) " · on this widget" else ""
                        setTextColor(colors.text)
                        // The budget the widget shows now is outlined in the
                        // accent; the text stays on the card fill.
                        background = ripple(
                            colors.cardFill,
                            if (chosen) colors.accent else colors.border
                        )
                        setOnClickListener { select(id) }
                    }
                )
            }
        }

        setContentView(
            ScrollView(this).apply {
                setBackgroundColor(colors.bg)
                // Keeps the header out from under the status bar: Android
                // 15 draws edge-to-edge by default.
                fitsSystemWindows = true
                addView(list)
            }
        )
        // Dark status bar icons over a light page, so they stay readable.
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            Color.luminance(colors.bg) > 0.5f
        ) {
            window.decorView.systemUiVisibility =
                window.decorView.systemUiVisibility or
                    View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }
    }

    private fun card(): TextView = TextView(this).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        setLineSpacing(0f, 1.2f)
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(16), dp(15), dp(16), dp(15))
        val lp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        )
        lp.bottomMargin = dp(10)
        layoutParams = lp
    }

    /** The app's card: 16dp corners, the fill, and a 1dp line when given. */
    private fun shape(fill: Int, line: Int?) = GradientDrawable().apply {
        cornerRadius = dp(16).toFloat()
        setColor(fill)
        if (line != null) setStroke(dp(1).coerceAtLeast(1), line)
    }

    private fun ripple(fill: Int, line: Int?) = RippleDrawable(
        // The text colour at 20%: a press shows on light and dark cards.
        ColorStateList.valueOf(
            Color.argb(
                0x33,
                Color.red(colors.text),
                Color.green(colors.text),
                Color.blue(colors.text)
            )
        ),
        shape(fill, line),
        null
    )

    private fun select(budgetId: String) {
        BudgetWidgetProvider.saveSelection(this, appWidgetId, budgetId)
        BudgetWidgetProvider.render(
            this,
            AppWidgetManager.getInstance(this),
            appWidgetId
        )
        setResult(
            RESULT_OK,
            android.content.Intent()
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
        )
        finish()
    }

    private fun readSnapshot(): List<JSONObject> {
        val arr = WidgetKit.readArray(this, BudgetWidgetProvider.DATA_KEY)
            ?: return emptyList()
        return (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
    }

    private fun dp(v: Int): Int =
        (v * resources.displayMetrics.density).toInt()
}
