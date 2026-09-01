package com.fabletest.expense_tracker

/**
 * The 4×2 picker entry. All behaviour lives in [BudgetWidgetProvider] —
 * `render()` picks the detailed layout by recognising this provider class
 * on the widget instance; a distinct receiver class is what gives the
 * launcher a second entry with its own size and preview.
 */
class BudgetWidgetDetailedProvider : BudgetWidgetProvider()
