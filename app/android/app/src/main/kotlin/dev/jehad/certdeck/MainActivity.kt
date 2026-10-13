package dev.jehad.certdeck

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Self-update (lib/update.dart): installs a downloaded APK of this app through PackageInstaller. */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "certdeck/update").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "versionCode" -> result.success(
                        if (Build.VERSION.SDK_INT >= 28) packageManager.getPackageInfo(packageName, 0).longVersionCode
                        else @Suppress("DEPRECATION") packageManager.getPackageInfo(packageName, 0).versionCode.toLong())
                    "canInstall" -> result.success(Build.VERSION.SDK_INT < 26 || packageManager.canRequestPackageInstalls())
                    "openInstallSettings" -> {
                        startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                        result.success(null)
                    }
                    "install" -> try {
                        install(File(call.arguments as String))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("install", e.toString(), null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun install(apk: File) {
        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setSize(apk.length())
        // Android 12+: an app may update itself without a prompt (see UPDATE_PACKAGES_WITHOUT_USER_ACTION).
        if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("certdeck.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val status = PendingIntent.getActivity(this, id, Intent(this, MainActivity::class.java).setAction(STATUS), flags)
            session.commit(status.intentSender)
        }
    }

    // The install result comes back here (singleTop). On success the system replaces and stops the app.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action != STATUS) return
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION") val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                confirm?.let { startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            }
            PackageInstaller.STATUS_SUCCESS -> {}
            else -> channel?.invokeMethod("failed", intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "status $status")
        }
    }

    private companion object {
        const val STATUS = "dev.jehad.certdeck.INSTALL_STATUS"
    }
}
