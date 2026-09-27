package com.fabletest.expense_tracker

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity): local_auth's BiometricPrompt
// needs an androidx FragmentActivity to attach its fragment to.
class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val CHANNEL = "expense_tracker/sms"

        /** Native to Dart: shortcut and tile actions (see QuickActions). */
        private const val LAUNCH_CHANNEL = "expense_tracker/launch"

        /** Dart to native: verify and install a downloaded update. */
        private const val UPDATE_CHANNEL = "expense_tracker/update"
        private const val PERMISSION_REQUEST = 7301

        /** Every SMS: Receive SMS, asked together with Read SMS. */
        private const val RECEIVE_REQUEST = 7302
    }

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingReceiveResult: MethodChannel.Result? = null
    private var backgroundChannel: MethodChannel? = null

    /** The cold-start action, held until Dart asks for it once. */
    private var pendingLaunchAction: String? = null
    private var launchChannel: MethodChannel? = null
    private var updateInstaller: UpdateInstaller? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Read before super: the engine may ask for it as soon as it starts.
        // A recreated activity (savedInstanceState set) already handled the
        // intent it was started with.
        if (savedInstanceState == null) {
            pendingLaunchAction = QuickActions.actionOf(intent)
        }
        super.onCreate(savedInstanceState)
    }

    /** singleTop: a shortcut or tile tap on a running app lands here. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = QuickActions.actionOf(intent) ?: return
        val channel = launchChannel
        if (channel != null) {
            // The newer tap wins: an unclaimed cold-start action must not
            // reach Dart after it and override it.
            pendingLaunchAction = null
            channel.invokeMethod("launchAction", action)
        } else {
            pendingLaunchAction = action
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        launchChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LAUNCH_CHANNEL
        ).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeLaunchAction" -> {
                        result.success(pendingLaunchAction)
                        pendingLaunchAction = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        QuickActions.publishShortcuts(applicationContext)
        val updateChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UPDATE_CHANNEL
        )
        updateInstaller?.dispose()
        updateInstaller = UpdateInstaller(this, updateChannel).also { installer ->
            updateChannel.setMethodCallHandler(installer::handle)
        }
        backgroundChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BackgroundImport.CHANNEL
        ).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "configure" -> {
                        BackgroundImport.configure(
                            applicationContext,
                            call.argument<String>("mode")
                        )
                        result.success(null)
                    }
                    "awaitIdle" -> BackgroundImport.awaitIdle(result)
                    "requestReceiveSms" -> requestReceiveSms(result)
                    else -> result.notImplemented()
                }
            }
            // The worker hands its runs to this engine while it lives.
            BackgroundImport.addLive(it)
        }
        val smsBridge = SmsBridge(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                // Inbox, notification buffer and widgets: shared with the
                // headless background-import engine.
                if (smsBridge.handle(call, result)) return@setMethodCallHandler
                when (call.method) {
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
                    // Notification capture (RCS alerts): access is a special
                    // system permission granted via its own settings page,
                    // not a runtime dialog.
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        backgroundChannel?.let { BackgroundImport.removeLive(it) }
        backgroundChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
    override fun onDestroy() {
        updateInstaller?.dispose()
        updateInstaller = null
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        // Cheap, and heals a publish that failed during an icon switch.
        QuickActions.publishShortcuts(applicationContext)
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

    private fun hasSmsPermission(): Boolean = SmsBridge.hasSmsPermission(this)

    private fun hasNotificationAccess(): Boolean = SmsBridge.hasNotificationAccess(this)


    // --- Alternate launcher icons -------------------------------------------

    /** Icon key → activity-alias class suffix. "default" is MainActivity. */
    private val iconAliases = mapOf(
        "swoosh" to "IconSwoosh",
        "classic" to "IconClassic",
        "midnight" to "IconMidnight",
        "aurora" to "IconAurora",
        "sunset" to "IconSunset",
        "wallet" to "IconWallet",
        "piggy" to "IconPiggy",
        "pie" to "IconPie",
        "forest" to "IconForest",
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
        // The shortcuts pointed at the entry just disabled.
        QuickActions.publishShortcuts(applicationContext)
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
        } else if (requestCode == RECEIVE_REQUEST) {
            pendingReceiveResult?.success(
                grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            )
            pendingReceiveResult = null
        }
    }

    /** Every SMS needs Receive SMS on top of Read SMS. Both sit in the SMS
     * group, so once Read SMS is granted Android usually grants this one
     * without a dialog. Answers true when both are granted. */
    private fun requestReceiveSms(result: MethodChannel.Result) {
        val perms = arrayOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS)
        if (perms.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) {
            result.success(true)
            return
        }
        if (pendingReceiveResult != null) {
            result.error("IN_PROGRESS", "Permission request already in progress", null)
            return
        }
        pendingReceiveResult = result
        requestPermissions(perms, RECEIVE_REQUEST)
    }
}
