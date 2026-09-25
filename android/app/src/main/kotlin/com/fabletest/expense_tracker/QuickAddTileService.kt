package com.fabletest.expense_tracker

import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings tile that opens Add expense. The app's own lock still
 * applies: the sheet opens once the app is unlocked. */
class QuickAddTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        // Inactive, not unavailable: an action tile has no on/off state, and
        // STATE_UNAVAILABLE would grey it out.
        qsTile?.let {
            it.state = Tile.STATE_INACTIVE
            it.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        // On the lock screen, the device unlock comes first.
        if (isLocked) unlockAndRun { launch() } else launch()
    }

    private fun launch() {
        val intent = QuickActions.intent(this, QuickActions.ADD_EXPENSE) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // API 34+ refuses the Intent overload.
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this,
                    0,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
