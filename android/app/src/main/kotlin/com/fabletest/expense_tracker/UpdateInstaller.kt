package com.fabletest.expense_tracker

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.content.IntentCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Installs an update the Dart side downloaded into cache/updates.
 *
 * "Install unknown apps" lets this app install ANY package, so nothing is
 * handed to the system unless it is this app, signed with the installed
 * app's own certificate, and a newer version. Only a bare file name inside
 * the app's private cache is accepted; there is no FileProvider and no
 * exported component, and this is reached only from a tap in the update
 * sheet, never from a launch action or notification.
 */
class UpdateInstaller(
    private val activity: Activity,
    private val channel: MethodChannel,
) {
    companion object {
        private const val STATUS_ACTION =
            "com.fabletest.expense_tracker.UPDATE_INSTALL_STATUS"
        private val FILE_NAME = Regex("^v[0-9.]+\\.apk$")
    }

    private var receiver: BroadcastReceiver? = null

    /** Verifying and copying a 65 MB APK must not block the UI thread. */
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** The session this app committed; status for any other is ignored.
     * Set on the worker thread, read by the receiver on the main one. */
    @Volatile
    private var sessionId: Int? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canInstall" -> result.success(canInstall())
            "openInstallSettings" -> result.success(openInstallSettings())
            "install" -> install(call.argument<String>("fileName"), result)
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        receiver?.let {
            try {
                activity.unregisterReceiver(it)
            } catch (_: Exception) {
                // Already gone with the activity.
            }
        }
        receiver = null
        worker.shutdown()
    }

    private fun canInstall(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.packageManager.canRequestPackageInstalls()
        } else {
            // Android 7: the global Unknown sources switch, enforced by the
            // system installer itself.
            true
        }

    private fun openInstallSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}")
                )
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun install(name: String?, result: MethodChannel.Result) {
        worker.execute {
            // (code, message): null code means the install was committed.
            val outcome: Pair<String?, String?> = try {
                val file = resolve(name)
                if (file == null) {
                    "BAD_FILE" to "That isn't an update this app downloaded."
                } else {
                    val problem = verify(file)
                    if (problem != null) {
                        "REFUSED" to problem
                    } else {
                        commit(file)
                        null to null
                    }
                }
            } catch (e: Exception) {
                "FAILED" to "Install failed: ${e.message}"
            }
            main.post {
                val (code, message) = outcome
                if (code == null) result.success(null) else result.error(code, message, null)
            }
        }
    }

    /** [name] as a file directly inside cache/updates, or null. */
    private fun resolve(name: String?): File? {
        if (name == null || !FILE_NAME.matches(name)) return null
        val dir = File(activity.cacheDir, "updates").canonicalFile
        val file = File(dir, name).canonicalFile
        if (file.parentFile != dir || !file.isFile) return null
        return file
    }

    /** Why [file] must not be installed, or null when it may. */
    private fun verify(file: File): String? {
        val pm = activity.packageManager
        val archive = archiveInfo(pm, file) ?: return "This file isn't an app update."
        if (archive.packageName != activity.packageName) {
            return "This update is for a different app."
        }
        val installed = installedInfo(pm)
        val theirs = signers(archive)
        val ours = signers(installed)
        if (theirs.isEmpty() || ours.isEmpty()) {
            return "Couldn't verify who signed this update."
        }
        if (theirs != ours) return "This update is not signed with this app's key."
        if (versionCode(archive) <= versionCode(installed)) {
            return "This update is not newer than the installed version."
        }
        return null
    }

    @Suppress("DEPRECATION")
    private val signatureFlag: Int
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }

    /** Android 9 fills an archive's signingInfo only when GET_SIGNATURES is
     * asked for as well; later versions accept either. */
    @Suppress("DEPRECATION")
    private fun archiveInfo(pm: PackageManager, file: File): PackageInfo? =
        pm.getPackageArchiveInfo(file.path, signatureFlag or PackageManager.GET_SIGNATURES)

    @Suppress("DEPRECATION")
    private fun installedInfo(pm: PackageManager): PackageInfo =
        pm.getPackageInfo(activity.packageName, signatureFlag)

    /** SHA-256 of each certificate currently signing [info]. */
    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val certs: Array<Signature>? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val s = info.signingInfo ?: return emptySet()
                if (s.hasMultipleSigners()) {
                    s.apkContentsSigners
                } else {
                    // Oldest first; the last entry is the current signer.
                    s.signingCertificateHistory?.lastOrNull()?.let { arrayOf(it) }
                }
            } else {
                info.signatures
            }
        if (certs.isNullOrEmpty()) return emptySet()
        val digest = MessageDigest.getInstance("SHA-256")
        return certs.map { cert ->
            digest.digest(cert.toByteArray()).joinToString("") { "%02x".format(it) }
        }.toSet()
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            info.versionCode.toLong()
        }

    private fun commit(file: File) {
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL
        ).apply {
            setAppPackageName(activity.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+: an app updating itself, holding
                // UPDATE_PACKAGES_WITHOUT_USER_ACTION, may skip the system
                // confirm; otherwise STATUS_PENDING_USER_ACTION shows it.
                setRequireUserAction(
                    PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED
                )
            }
        }
        val id = installer.createSession(params)
        try {
            installer.openSession(id).use { session ->
                file.inputStream().use { input ->
                    session.openWrite("base.apk", 0, file.length()).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }
                sessionId = id
                main.post { listen() }
                // Explicit (package set), so no other app receives it; the
                // installer fills in the status extras, hence mutable.
                val intent = Intent(STATUS_ACTION).setPackage(activity.packageName)
                var flags = PendingIntent.FLAG_UPDATE_CURRENT
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    flags = flags or PendingIntent.FLAG_MUTABLE
                }
                val pending = PendingIntent.getBroadcast(activity, id, intent, flags)
                session.commit(pending.intentSender)
            }
        } catch (e: Exception) {
            sessionId = null
            try {
                installer.abandonSession(id)
            } catch (_: Exception) {
                // Already committed or gone.
            }
            throw e
        }
    }

    /** The install status receiver: registered at runtime, not exported. */
    private fun listen() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val id = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
                if (id != sessionId) return
                when (intent.getIntExtra(
                    PackageInstaller.EXTRA_STATUS,
                    PackageInstaller.STATUS_FAILURE
                )) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> confirm(intent)
                    PackageInstaller.STATUS_SUCCESS -> sessionId = null
                    else -> {
                        sessionId = null
                        failed(
                            intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                                ?: "Install failed."
                        )
                    }
                }
            }
        }
        ContextCompat.registerReceiver(
            activity,
            r,
            IntentFilter(STATUS_ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        receiver = r
    }

    /** Shows the system's own "Update this app?" screen. */
    private fun confirm(status: Intent) {
        val screen = IntentCompat.getParcelableExtra(
            status,
            Intent.EXTRA_INTENT,
            Intent::class.java
        )
        // Only ever another package's screen (the system installer), never
        // one of this app's own activities, and with no URI grants riding
        // along. resolveActivity is not used: package visibility on
        // Android 11 can hide the installer from this app.
        val target = screen?.component?.packageName ?: screen?.`package`
        if (screen == null || target == null || target == activity.packageName) {
            sessionId = null
            failed("Android didn't show the install screen.")
            return
        }
        screen.flags = screen.flags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            ).inv()
        screen.selector = null
        screen.clipData = null
        try {
            activity.startActivity(screen)
        } catch (e: Exception) {
            sessionId = null
            failed("Android didn't show the install screen.")
        }
    }

    private fun failed(message: String) {
        channel.invokeMethod("installFailed", message)
    }
}
