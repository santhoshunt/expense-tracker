package com.fabletest.expense_tracker

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.content.res.ColorStateList
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject

/**
 * Per-instance widget setup: shown by the launcher when a budget widget is
 * added. Lists the budgets from the Dart-written snapshot (overall cap
 * first, then customs — see budget_widget_service.dart); a tap stores the
 * mapping for this appWidgetId, renders the widget once, and finishes.
 * Built programmatically in the app's dark palette: charcoal cards, white
 * text, coral accents — light text on dark, never dark-on-dark.
 */
class BudgetWidgetConfigActivity : Activity() {
    private companion object {
        const val BG = 0xFF1B1927.toInt() // app background
        const val CARD = 0xFF252836.toInt() // card surface
        const val ACCENT = 0xFFEA7C69.toInt() // coral
        const val TEXT_SECONDARY = 0xFFB4C0C8.toInt()
        const val RIPPLE = 0x33FFFFFF
    }

    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        appWidgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

        // Android contract: cancelled until a choice is made, so backing out
        // aborts the widget add instead of leaving an unconfigured shell.
        setResult(RESULT_CANCELED)
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(28))
        }
        list.addView(
            TextView(this).apply {
                text = "Budget widget"
                setTextColor(ACCENT)
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
                setTextColor(Color.WHITE)
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
                    setTextColor(TEXT_SECONDARY)
                }
            )
            list.addView(
                card().apply {
                    text = "Open Expense Tracker"
                    gravity = Gravity.CENTER
                    setTextColor(Color.WHITE)
                    setTypeface(typeface, Typeface.BOLD)
                    background = ripple(ACCENT)
                    setOnClickListener {
                        // The LAUNCH intent, not MainActivity directly — the
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
                list.addView(
                    card().apply {
                        text = "${b.optString("name")}\n" +
                            "${b.optString("limitLabel")} · " +
                            b.optString("monthLabel")
                        setTextColor(Color.WHITE)
                        background = ripple(CARD)
                        setOnClickListener { select(b.optString("id")) }
                    }
                )
            }
        }

        setContentView(
            ScrollView(this).apply {
                setBackgroundColor(BG)
                // Keeps the header out from under the status bar — Android
                // 15 draws edge-to-edge by default.
                fitsSystemWindows = true
                addView(list)
            }
        )
    }

    private fun card(): TextView = TextView(this).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        setLineSpacing(0f, 1.2f)
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(16), dp(15), dp(16), dp(15))
        background = GradientDrawable().apply {
            cornerRadius = dp(14).toFloat()
            setColor(CARD)
        }
        val lp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        )
        lp.bottomMargin = dp(10)
        layoutParams = lp
    }

    private fun ripple(base: Int) = RippleDrawable(
        ColorStateList.valueOf(RIPPLE),
        GradientDrawable().apply {
            cornerRadius = dp(14).toFloat()
            setColor(base)
        },
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

    private fun readSnapshot(): List<JSONObject> = try {
        val raw = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.budget_widget_data_v1", null)
        if (raw == null) {
            emptyList()
        } else {
            val arr = JSONArray(raw)
            (0 until arr.length()).map { arr.getJSONObject(it) }
        }
    } catch (_: Exception) {
        emptyList()
    }

    private fun dp(v: Int): Int =
        (v * resources.displayMetrics.density).toInt()
}
