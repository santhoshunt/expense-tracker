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
 * Per-instance setup for the Accounts widget: shown by the launcher when the
 * widget is added, and again from its long-press menu (reconfigurable, from
 * Android 12). Lists the open accounts from the shared snapshot
 * (home_widgets_service.dart) in the app's order; a tap ticks or unticks
 * one, and Done stores the ticked ids for this appWidgetId, renders the
 * widget once and finishes. Built programmatically in the app's own colours,
 * as [BudgetWidgetConfigActivity] is.
 */
class AccountsWidgetConfigActivity : Activity() {
    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    /** The app's colours (not Activity.getTheme, the window theme). */
    private lateinit var colors: WidgetTheme

    /** The ticked ids, in the order they were ticked; saved in the
     * snapshot's order. */
    private val picked = LinkedHashSet<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        appWidgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

        // Android contract: cancelled until Done, so backing out aborts the
        // widget add instead of leaving an unconfigured shell. A reconfigure
        // the user backs out of keeps the widget as it was.
        setResult(RESULT_CANCELED)
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        colors = WidgetTheme.read(this)
        picked.addAll(AccountsWidgetProvider.selectionOf(this, appWidgetId))

        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(28))
        }
        list.addView(
            TextView(this).apply {
                text = "Accounts widget"
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
                text = "Choose accounts for this widget"
                setTextColor(colors.text)
                setTypeface(typeface, Typeface.BOLD)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
                setPadding(0, 0, 0, dp(20))
            }
        )

        val accounts = readSnapshot()
        // Ids no longer in the snapshot (closed or deleted since) drop off
        // on the next Done.
        picked.retainAll(accounts.map { it.optString("id") }.toSet())
        if (accounts.isEmpty()) {
            list.addView(
                card().apply {
                    text =
                        "No accounts yet.\n\nOpen the app once so it can list " +
                        "your accounts, come back to the home screen, and add " +
                        "this widget again."
                    setTextColor(colors.textSecondary)
                    background = shape(colors.cardFill, colors.border)
                }
            )
            list.addView(
                button("Open Expense Tracker") {
                    // The LAUNCH intent, not MainActivity directly: the
                    // alternate-icon feature disables .MainActivity in
                    // favour of an alias, and starting a disabled component
                    // silently does nothing.
                    startActivity(BudgetWidgetProvider.launchIntent(this))
                    finish()
                }
            )
        } else {
            for (a in accounts) {
                val id = a.optString("id")
                list.addView(
                    card().apply {
                        setTextColor(colors.text)
                        fun draw() {
                            val on = id in picked
                            text = "${a.optString("name")}\n" +
                                kindLabel(a.optString("kind")) +
                                if (on) " · on this widget" else ""
                            // A ticked account is outlined in the accent; the
                            // text stays on the card fill.
                            background = ripple(
                                colors.cardFill,
                                if (on) colors.accent else colors.border
                            )
                        }
                        draw()
                        setOnClickListener {
                            if (!picked.remove(id)) picked.add(id)
                            draw()
                        }
                    }
                )
            }
            list.addView(
                button("Done") {
                    val order = accounts.map { it.optString("id") }
                    save(order.filter { it in picked })
                }
            )
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

    private fun kindLabel(kind: String): String = when (kind) {
        "card" -> "Credit card"
        "debit" -> "Debit card"
        "savings" -> "Savings"
        "wallet" -> "Wallet"
        else -> "Bank"
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

    /** The app's main button: the accent with its label colour on it. */
    private fun button(label: String, onTap: () -> Unit): TextView = card().apply {
        text = label
        gravity = Gravity.CENTER
        setTextColor(colors.onAccent)
        setTypeface(typeface, Typeface.BOLD)
        background = ripple(colors.accent, null)
        setOnClickListener { onTap() }
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

    /** Stores [ids] for this widget, draws it once and finishes. With none
     * ticked the widget shows how to pick some. */
    private fun save(ids: List<String>) {
        AccountsWidgetProvider.saveSelection(this, appWidgetId, ids)
        HomeWidgets.render(this, AppWidgetManager.getInstance(this), appWidgetId)
        setResult(
            RESULT_OK,
            android.content.Intent()
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
        )
        finish()
    }

    private fun readSnapshot(): List<JSONObject> {
        val arr = WidgetKit.readObject(this, HomeWidgets.DATA_KEY)
            ?.optJSONArray("accounts")
            ?: return emptyList()
        return (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
    }

    private fun dp(v: Int): Int =
        (v * resources.displayMetrics.density).toInt()
}
