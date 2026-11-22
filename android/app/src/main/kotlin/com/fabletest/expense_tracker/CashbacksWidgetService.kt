package com.fabletest.expense_tracker

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONObject

/**
 * The rows of the Cashbacks widget's list. A widget's list cannot be filled
 * by the update that draws the rest of it: the launcher binds to this
 * service and asks [CashbacksRows] for one row at a time as the list
 * scrolls. Only the system may bind (BIND_REMOTEVIEWS in the manifest).
 */
class CashbacksWidgetService : RemoteViewsService() {
    /** The widget's id is the last part of the intent's data
     * ("cashbacks://widget/7", set by the Cashbacks builder in
     * [HomeWidgets]); the rows need it for the widget's width. */
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        CashbacksRows(applicationContext, intent.data?.lastPathSegment?.toIntOrNull())
}

/** One row per credit card that earned rewards in a cycle still running,
 * from the shared snapshot, in the order the app wrote them
 * ([HomeWidgets.cashbackRows]). [HomeWidgets.render] says when the snapshot or
 * the widget's size changed; the rows, the theme and the width are read
 * again then. No exception may leave a callback: the system hands it to
 * the app's crash handler, which ends the app's process. */
private class CashbacksRows(private val context: Context, private val widgetId: Int?) :
    RemoteViewsService.RemoteViewsFactory {
    private var rows: List<JSONObject> = emptyList()
    private var theme = WidgetTheme(null)

    /** How wide a row is, in dp; null while the widget's width is unknown. */
    private var rowDp: Int? = null

    /** Nothing: the system calls [onDataSetChanged] before it first asks
     * for the count, and off the main thread, which this runs on. */
    override fun onCreate() {}

    override fun onDataSetChanged() {
        try {
            val read = HomeWidgets.cashbackRows(
                WidgetKit.readObject(context, HomeWidgets.DATA_KEY)
            ).orEmpty()
            val readTheme = WidgetTheme.read(context)
            val readRowDp = rowWidthDp()
            rows = read
            theme = readTheme
            rowDp = readRowDp
        } catch (_: Exception) {
            // The rows from before stay until the next change.
        }
    }

    /** The widget's width in portrait, the narrower of its two, inside the
     * list's 16dp at each side in home_widget_cashbacks (start padding, and
     * end margin plus padding, the scrollbar drawn over the latter); null
     * without the widget's id or before the launcher has reported a width. */
    private fun rowWidthDp(): Int? {
        val id = widgetId ?: return null
        val width = AppWidgetManager.getInstance(context).getAppWidgetOptions(id)
            ?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0) ?: 0
        return if (width > 0) width - 2 * 16 else null
    }

    override fun onDestroy() {
        rows = emptyList()
    }

    override fun getCount(): Int = rows.size

    /** The card's name, the day its cycle ends and what it earned.
     * [HomeWidgets.cashbackRows] leaves out a row past that day; one that
     * passes it after the rows were read (midnight) keeps its figure
     * without the "till" part until the next read. Null for a row the list
     * asked for just as the snapshot dropped it: the list keeps its blank
     * row. A row that fails to build is blank. */
    override fun getViewAt(position: Int): RemoteViews? = try {
        rows.getOrNull(position)?.let { filled(it) }
    } catch (_: Exception) {
        blank()
    }

    private fun filled(row: JSONObject): RemoteViews {
        val till = HomeWidgets.cashbackTill(row)
        val figure = row.optString("figure")
        // Only the name gives way, so the "till" part goes where the name
        // would keep under 48dp beside it and the figure (8dp from it), as
        // the Subscriptions pill does. All three are 13sp, the figure bold.
        // It stays while the width is unknown.
        val width = rowDp
        val showTill = till != null && (
            width == null ||
                width - 8 - WidgetKit.textWidthDp(context, figure, 13f, bold = true) -
                WidgetKit.textWidthDp(context, till, 13f) >= 48
            )
        return blank().apply {
            setTextViewText(R.id.hw_name, row.optString("name"))
            setTextColor(R.id.hw_name, theme.text)
            // Set both ways: the list hands a used row back to be refilled.
            setViewVisibility(R.id.hw_till, if (showTill) View.VISIBLE else View.GONE)
            setTextViewText(R.id.hw_till, till?.takeIf { showTill } ?: "")
            setTextColor(R.id.hw_till, theme.textSecondary)
            setTextViewText(R.id.hw_figure, figure)
            setTextColor(R.id.hw_figure, theme.text)
            // Empty: the list's template already holds the whole intent.
            setOnClickFillInIntent(R.id.hw_row, Intent())
        }
    }

    /** A row with no text, as tall as a filled one, in place of the
     * system's "Loading…" line while a row is fetched. */
    override fun getLoadingView(): RemoteViews = blank()

    private fun blank() = RemoteViews(context.packageName, R.layout.home_widget_cashbacks_row)

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = false
}
