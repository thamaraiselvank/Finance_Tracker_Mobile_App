package com.finverse.finance_tracker_mobile

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

// FlutterFragmentActivity is required by local_auth (fingerprint / PIN app lock).
class MainActivity : FlutterFragmentActivity() {
    private var capture: MethodChannel? = null
    private var pendingShare: Map<String, Any?>? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "finverse/sms").setMethodCallHandler(SmsReader(applicationContext))

        capture = MethodChannel(messenger, "finverse/capture").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "notificationAccessGranted" ->
                        result.success(NotificationManagerCompat.getEnabledListenerPackages(this@MainActivity).contains(packageName))
                    "openNotificationAccess" -> {
                        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(null)
                    }
                    "drainNotifications" -> result.success(PaymentNotificationListener.drain(applicationContext))
                    "takeShared" -> {
                        result.success(pendingShare)
                        pendingShare = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handleShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
    }

    /**
     * "Share to Finverse": text (an SMS, a payment message) or an image (a
     * payment screenshot). Images are copied into the app's private cache so
     * Dart can read them with on-phone OCR; nothing leaves the phone.
     */
    private fun handleShare(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val type = intent.type ?: return
        if (type.startsWith("image/")) {
            val uri = streamUri(intent) ?: return
            worker.execute {
                val path = try {
                    copyToCache(uri)
                } catch (e: Exception) {
                    null
                }
                main.post { deliver(if (path == null) mapOf("type" to "error") else mapOf("type" to "image", "path" to path)) }
            }
        } else if (type.startsWith("text/")) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
            deliver(mapOf("type" to "text", "text" to text))
        }
        // Don't handle the same share again (e.g. when the activity is recreated).
        setIntent(Intent(Intent.ACTION_MAIN))
    }

    private fun deliver(item: Map<String, Any?>) {
        pendingShare = item
        // If Flutter is already running, tell it now; otherwise it asks at start-up.
        capture?.invokeMethod("shared", null)
    }

    @Suppress("DEPRECATION")
    private fun streamUri(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri

    private fun copyToCache(uri: Uri): String {
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        // Keep only the latest few shared images.
        dir.listFiles()?.sortedBy { it.lastModified() }?.dropLast(4)?.forEach { it.delete() }
        val file = File(dir, "share_${System.currentTimeMillis()}.img")
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "Cannot open shared image" }
            file.outputStream().use { input.copyTo(it) }
        }
        return file.absolutePath
    }
}
