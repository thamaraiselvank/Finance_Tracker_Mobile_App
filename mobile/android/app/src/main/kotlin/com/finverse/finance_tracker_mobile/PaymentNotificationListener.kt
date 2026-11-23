package com.finverse.finance_tracker_mobile

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/**
 * Catches payment notifications from UPI apps (Google Pay, PhonePe, Paytm…)
 * so payments are recorded even when no bank SMS arrives.
 *
 * Privacy: Android shows every notification to a listener, but this one
 * immediately drops anything that is not (a) from the payment apps below and
 * (b) about an amount of money. Kept notifications are stored only in the
 * app's private storage until Finverse next opens and moves them into the
 * review inbox. Nothing is uploaded.
 *
 * The user turns this on once in Android Settings > Notification access.
 */
class PaymentNotificationListener : NotificationListenerService() {

    companion object {
        /** Package name -> sender code understood by the Dart parser. */
        val PAYMENT_APPS = mapOf(
            "com.google.android.apps.nbu.paisa.user" to "GPAY",
            "com.phonepe.app" to "PHONEPE",
            "net.one97.paytm" to "PAYTM",
            "in.org.npci.upiapp" to "BHIM",
            "com.dreamplug.androidapp" to "CRED",
            "in.amazon.mShop.android.shopping" to "AMAZON",
            "com.mobikwik_new" to "MOBKWK",
        )

        private const val PREFS = "finverse_capture"
        private const val KEY = "notifications"
        private const val MAX_QUEUED = 300
        private val MONEY = Regex("(₹|\\brs\\.?|\\binr)\\s*[0-9]", RegexOption.IGNORE_CASE)

        /** Returns the queued payment notifications and empties the queue. */
        @Synchronized
        fun drain(context: Context): List<Map<String, Any>> {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val queue = JSONArray(prefs.getString(KEY, "[]"))
            prefs.edit().remove(KEY).apply()
            return (0 until queue.length()).map { i ->
                val o = queue.getJSONObject(i)
                mapOf("sender" to o.getString("sender"), "body" to o.getString("body"), "date" to o.getLong("date"))
            }
        }

        @Synchronized
        private fun enqueue(context: Context, sender: String, body: String, date: Long) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val queue = JSONArray(prefs.getString(KEY, "[]"))
            // Apps often re-post the same notification; keep one copy.
            for (i in 0 until queue.length()) {
                val o = queue.getJSONObject(i)
                if (o.getString("sender") == sender && o.getString("body") == body) return
            }
            queue.put(JSONObject().put("sender", sender).put("body", body).put("date", date))
            while (queue.length() > MAX_QUEUED) queue.remove(0)
            prefs.edit().putString(KEY, queue.toString()).apply()
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val sender = PAYMENT_APPS[sbn.packageName] ?: return
        val notification = sbn.notification ?: return
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty().trim()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: extras.getCharSequence(Notification.EXTRA_TEXT))
            ?.toString().orEmpty().trim()
        val body = listOf(title, text).filter { it.isNotEmpty() }.joinToString(". ")
        if (!MONEY.containsMatchIn(body)) return
        enqueue(applicationContext, sender, body, sbn.postTime)
    }
}
