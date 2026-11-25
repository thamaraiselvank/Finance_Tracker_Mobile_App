package com.finverse.finance_tracker_mobile

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
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

    /**
     * Decodes the shared image here and saves it as a plain JPEG, so ML Kit
     * always gets a file it can open. (Copying the raw bytes failed for some
     * apps' shares: ML Kit could not decode them and crashed with a null
     * bitmap.) Very large images are scaled down to keep memory in check.
     */
    private fun copyToCache(uri: Uri): String {
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        // Keep only the latest few shared images.
        dir.listFiles()?.sortedBy { it.lastModified() }?.dropLast(4)?.forEach { it.delete() }
        val bitmap = decode(uri) ?: throw IllegalStateException("Cannot decode shared image")
        val file = File(dir, "share_${System.currentTimeMillis()}.jpg")
        try {
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        } finally {
            bitmap.recycle()
        }
        return file.absolutePath
    }

    private fun decode(uri: Uri): Bitmap? {
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                val source = ImageDecoder.createSource(contentResolver, uri)
                return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    // Software bitmap so it can be compressed to JPEG.
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    val longest = maxOf(info.size.width, info.size.height)
                    if (longest > MAX_SIDE) {
                        val scale = MAX_SIDE.toFloat() / longest
                        decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1), (info.size.height * scale).toInt().coerceAtLeast(1))
                    }
                }
            } catch (e: Exception) {
                // Fall back to BitmapFactory below.
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) } ?: return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_SIDE) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
    }

    private companion object {
        /** Longest side kept for OCR; plenty for a payment screenshot. */
        const val MAX_SIDE = 2400
    }
}
