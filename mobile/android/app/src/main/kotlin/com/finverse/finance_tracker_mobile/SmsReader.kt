package com.finverse.finance_tracker_mobile

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Reads bank and payment SMS from the phone's inbox for Finverse.
 *
 * Privacy: only messages from alphanumeric sender IDs (like "AX-HDFCBK") are
 * returned. Messages from personal phone numbers never leave this class.
 * Nothing is sent anywhere: results go only to the app's own Dart code.
 *
 * Channel "finverse/sms":
 *   readInbox({sinceMillis: Long, limit: Int}) -> List<Map> of
 *   {id, address, body, date} ordered oldest first.
 */
class SmsReader(private val context: Context) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "readInbox" -> {
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_SMS) != PackageManager.PERMISSION_GRANTED) {
                    result.error("NO_PERMISSION", "SMS permission not granted", null)
                    return
                }
                val since = (call.argument<Number>("sinceMillis") ?: 0).toLong()
                val limit = (call.argument<Number>("limit") ?: 5000).toInt()
                worker.execute {
                    try {
                        val messages = readInbox(since, limit)
                        main.post { result.success(messages) }
                    } catch (e: Exception) {
                        main.post { result.error("READ_FAILED", e.message, null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun readInbox(sinceMillis: Long, limit: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val projection = arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE)
        context.contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            projection,
            "${Telephony.Sms.DATE} > ?",
            arrayOf(sinceMillis.toString()),
            "${Telephony.Sms.DATE} ASC",
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addressCol = cursor.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyCol = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateCol = cursor.getColumnIndexOrThrow(Telephony.Sms.DATE)
            while (cursor.moveToNext() && out.size < limit) {
                val address = cursor.getString(addressCol) ?: continue
                // Banks and payment apps use letter sender IDs; people use numbers.
                if (!address.any { it.isLetter() }) continue
                out.add(
                    mapOf(
                        "id" to cursor.getLong(idCol),
                        "address" to address,
                        "body" to (cursor.getString(bodyCol) ?: ""),
                        "date" to cursor.getLong(dateCol),
                    ),
                )
            }
        }
        return out
    }
}
