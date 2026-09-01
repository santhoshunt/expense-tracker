package com.fabletest.expense_tracker

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity): local_auth's BiometricPrompt
// needs an androidx FragmentActivity to attach its fragment to.
class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val CHANNEL = "expense_tracker/sms"
        private const val PERMISSION_REQUEST = 7301

        /** Rows read per provider query; pages continue until the window is
         * exhausted so long scan ranges are not silently truncated. */
        private const val PAGE_SIZE = 2000

        /** Sanity ceiling across all pages. */
        private const val MAX_MESSAGES = 50_000
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(hasSmsPermission())
                    "requestPermission" -> requestSmsPermission(result)
                    "openAppSettings" -> {
                        // Some ROMs lack these settings activities — a bare
                        // startActivity then throws and the tap does nothing
                        // with a stack trace nobody sees.
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.fromParts("package", packageName, null)
                                )
                            )
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "querySms" -> {
                        if (!hasSmsPermission()) {
                            result.error("NO_PERMISSION", "READ_SMS not granted", null)
                        } else {
                            val since = call.argument<Number>("sinceMillis")?.toLong() ?: 0L
                            val until = call.argument<Number>("untilMillis")?.toLong()
                            result.success(queryInbox(since, until))
                        }
                    }
                    // Notification capture (RCS alerts): access is a special
                    // system permission granted via its own settings page,
                    // not a runtime dialog.
                    "notifHasAccess" -> result.success(hasNotificationAccess())
                    "notifOpenSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                            )
                            result.success(true)
                        } catch (_: Exception) {
                            result.success(false)
                        }
                    }
                    "notifDrain" -> result.success(
                        TxnNotificationListener.drain(applicationContext)
                    )
                    "notifLastCapture" -> result.success(
                        TxnNotificationListener.lastCaptureMillis(applicationContext)
                    )
                    "notifDiagnostics" -> result.success(
                        TxnNotificationListener.diagnostics(applicationContext)
                    )
                    // Home-screen budget widgets: the Dart side has written a
                    // fresh snapshot to prefs — re-render every instance.
                    "updateBudgetWidgets" -> {
                        BudgetWidgetProvider.refreshAll(applicationContext)
                        result.success(null)
                    }
                    // Alternate launcher icons via activity-alias switching.
                    "getAppIcon" -> result.success(currentAppIcon())
                    "setAppIcon" -> {
                        setAppIcon(call.argument<String>("icon") ?: "default")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        // After an APK update the granted notification listener frequently
        // stays UNBOUND until the device reboots or access is toggled off/on:
        // hasNotificationAccess() still reports true, but the service never
        // receives a callback, so RCS capture silently dies. requestRebind is
        // the documented remedy and is a cheap no-op when already connected.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && hasNotificationAccess()) {
            try {
                NotificationListenerService.requestRebind(
                    ComponentName(this, TxnNotificationListener::class.java)
                )
            } catch (_: Exception) {
                // Best-effort: never let a rebind hiccup break app startup.
            }
        }
    }

    private fun hasSmsPermission(): Boolean =
        checkSelfPermission(Manifest.permission.READ_SMS) ==
            PackageManager.PERMISSION_GRANTED

    /** Entries are flattened "pkg/cls" component strings — parse and compare
     * the package exactly. A startsWith check matched any package with this
     * one as a prefix, reporting "capture on" while the buffer stayed empty. */
    private fun hasNotificationAccess(): Boolean =
        Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
            ?.split(":")
            ?.any {
                ComponentName.unflattenFromString(it)?.packageName == packageName
            } == true

    // --- Alternate launcher icons -------------------------------------------

    /** Icon key → activity-alias class suffix. "default" is MainActivity. */
    private val iconAliases = mapOf(
        "swoosh" to "IconSwoosh",
        "classic" to "IconClassic",
        "midnight" to "IconMidnight",
    )

    private fun component(cls: String) =
        ComponentName(packageName, "$packageName.$cls")

    private fun currentAppIcon(): String {
        for ((key, cls) in iconAliases) {
            if (packageManager.getComponentEnabledSetting(component(cls)) ==
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            ) {
                return key
            }
        }
        return "default"
    }

    /** Enables the chosen launcher entry first, then disables the rest, so a
     * launcher icon exists at every point in between. DONT_KILL_APP keeps the
     * running process alive (most launchers still re-pin the shortcut). */
    private fun setAppIcon(key: String) {
        val pm = packageManager
        val main = component("MainActivity")
        val target = iconAliases[key]?.let(::component) ?: main

        pm.setComponentEnabledSetting(
            target,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )
        for ((_, cls) in iconAliases) {
            val c = component(cls)
            if (c != target) {
                pm.setComponentEnabledSetting(
                    c,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP
                )
            }
        }
        if (target != main) {
            pm.setComponentEnabledSetting(
                main,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
        } else {
            // Back to the manifest default (enabled).
            pm.setComponentEnabledSetting(
                main,
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,
                PackageManager.DONT_KILL_APP
            )
        }
    }

    /// Resolves to "granted", "denied", or "blocked". "blocked" means the OS
    /// refused without showing a dialog — READ_SMS is a hard-restricted
    /// permission, so sideloaded installs need it enabled manually in app
    /// settings (Android 13+: "Allow restricted settings" first).
    private fun requestSmsPermission(result: MethodChannel.Result) {
        if (hasSmsPermission()) {
            result.success("granted")
            return
        }
        if (pendingPermissionResult != null) {
            result.error("IN_PROGRESS", "Permission request already in progress", null)
            return
        }
        pendingPermissionResult = result
        requestPermissions(arrayOf(Manifest.permission.READ_SMS), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST) {
            val granted =
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            val status = when {
                granted -> "granted"
                // Denied and the OS won't show a rationale → the dialog was
                // never shown (restricted permission or "don't ask again").
                !shouldShowRequestPermissionRationale(Manifest.permission.READ_SMS) -> "blocked"
                else -> "denied"
            }
            pendingPermissionResult?.success(status)
            pendingPermissionResult = null
        }
    }

    /** Reads the whole (since, until) window newest-first, paging with a
     * moving upper-bound date cursor so large windows are not truncated.
     *
     * Returns {"messages": [...], "complete": bool}. `complete=false` means
     * the window was NOT fully read (hit [MAX_MESSAGES], or the provider
     * threw mid-scan, e.g. READ_SMS revoked) — the Dart side must then keep
     * its incremental-scan marker where it was, otherwise the unread tail is
     * skipped forever.
     *
     * Pages after the first use an inclusive upper bound with _ID-based
     * dedup: the old strict `<` silently and permanently dropped any message
     * sharing the boundary row's exact millisecond. The page loop also
     * checks capacity BEFORE consuming a row — `moveToNext()` first meant
     * row PAGE_SIZE+1 was consumed and discarded every page. */
    private fun queryInbox(sinceMillis: Long, untilMillis: Long?): Map<String, Any?> {
        val messages = mutableListOf<Map<String, Any?>>()
        val seenIds = HashSet<Long>()
        var upperBound = untilMillis ?: Long.MAX_VALUE
        var inclusiveUpper = false
        var complete = true
        try {
            while (true) {
                if (messages.size >= MAX_MESSAGES) {
                    complete = false
                    break
                }
                var pageRows = 0
                var newRows = 0
                var oldestInPage = upperBound
                contentResolver.query(
                    Telephony.Sms.Inbox.CONTENT_URI,
                    arrayOf(
                        Telephony.Sms._ID,
                        Telephony.Sms.ADDRESS,
                        Telephony.Sms.BODY,
                        Telephony.Sms.DATE
                    ),
                    "${Telephony.Sms.DATE} > ? AND " +
                        "${Telephony.Sms.DATE} ${if (inclusiveUpper) "<=" else "<"} ?",
                    arrayOf(sinceMillis.toString(), upperBound.toString()),
                    "${Telephony.Sms.DATE} DESC"
                )?.use { cursor ->
                    val idIdx = cursor.getColumnIndex(Telephony.Sms._ID)
                    val addressIdx = cursor.getColumnIndex(Telephony.Sms.ADDRESS)
                    val bodyIdx = cursor.getColumnIndex(Telephony.Sms.BODY)
                    val dateIdx = cursor.getColumnIndex(Telephony.Sms.DATE)
                    if (idIdx < 0 || dateIdx < 0) {
                        complete = false
                        return@use
                    }
                    while (pageRows < PAGE_SIZE &&
                        messages.size < MAX_MESSAGES && cursor.moveToNext()
                    ) {
                        pageRows++
                        val date = cursor.getLong(dateIdx)
                        oldestInPage = date
                        if (!seenIds.add(cursor.getLong(idIdx))) continue
                        newRows++
                        messages.add(
                            mapOf(
                                "address" to
                                    (if (addressIdx >= 0) cursor.getString(addressIdx) else null),
                                "body" to
                                    (if (bodyIdx >= 0) cursor.getString(bodyIdx) else null),
                                "date" to date
                            )
                        )
                    }
                }
                // Short page → window exhausted. Zero NEW rows on a full
                // page can only mean >PAGE_SIZE messages share one
                // millisecond — bail rather than loop forever.
                if (pageRows < PAGE_SIZE) break
                if (newRows == 0) {
                    complete = false
                    break
                }
                upperBound = oldestInPage
                inclusiveUpper = true
            }
        } catch (_: Exception) {
            // SecurityException (permission revoked mid-scan) or an OEM
            // provider quirk: return what was read, flagged incomplete.
            complete = false
        }
        return mapOf("messages" to messages, "complete" to complete)
    }
}
