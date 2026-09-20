package com.mithun.aarohi

import android.app.Notification
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Aarohi's WhatsApp & Notification Watcher Service.
 *
 * Listens for incoming WhatsApp notifications (com.whatsapp, com.whatsapp.w4b),
 * extracts sender and message content, records into Aarohi's memory, and can
 * alert Mithun about what people sent.
 */
class AarohiNotificationListener : NotificationListenerService() {

    companion object {
        const val PREFS_NAME = "aarohi_whatsapp_prefs"
        const val KEY_MESSAGES_JSON = "captured_whatsapp_messages"
        const val KEY_VOICE_ALERT_ENABLED = "whatsapp_voice_alert_enabled"

        // In-memory listener callback if Flutter engine is active
        var onMessageCaptured: ((Map<String, String>) -> Unit)? = null

        fun getSavedMessages(context: Context): List<Map<String, String>> {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val jsonStr = prefs.getString(KEY_MESSAGES_JSON, "[]") ?: "[]"
            val list = mutableListOf<Map<String, String>>()
            try {
                val array = JSONArray(jsonStr)
                for (i in 0 until array.length()) {
                    val obj = array.getJSONObject(i)
                    list.add(
                        mapOf(
                            "sender" to obj.optString("sender", "Unknown"),
                            "message" to obj.optString("message", ""),
                            "time" to obj.optString("time", ""),
                            "timestamp" to obj.optString("timestamp", "0"),
                            "package" to obj.optString("package", "com.whatsapp")
                        )
                    )
                }
            } catch (_: Exception) {}
            return list
        }

        fun saveMessage(context: Context, sender: String, message: String, pkg: String) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val jsonStr = prefs.getString(KEY_MESSAGES_JSON, "[]") ?: "[]"
            try {
                val array = JSONArray(jsonStr)
                val sdf = SimpleDateFormat("hh:mm a, MMM dd", Locale.getDefault())
                val timeStr = sdf.format(Date())

                val newObj = JSONObject().apply {
                    put("sender", sender)
                    put("message", message)
                    put("time", timeStr)
                    put("timestamp", System.currentTimeMillis().toString())
                    put("package", pkg)
                }

                // Insert at beginning
                val newArray = JSONArray()
                newArray.put(newObj)
                // Retain up to 60 recent messages
                for (i in 0 until Math.min(array.length(), 60)) {
                    newArray.put(array.get(i))
                }

                prefs.edit().putString(KEY_MESSAGES_JSON, newArray.toString()).apply()

                val msgMap = mapOf(
                    "sender" to sender,
                    "message" to message,
                    "time" to timeStr,
                    "timestamp" to System.currentTimeMillis().toString(),
                    "package" to pkg
                )
                onMessageCaptured?.invoke(msgMap)
            } catch (_: Exception) {}
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        try {
            AarohiBatteryReceiver.initTts(applicationContext)
        } catch (_: Exception) {}
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        if (sbn == null) return

        val pkg = sbn.packageName ?: return
        // Watch WhatsApp and WhatsApp Business
        if (!pkg.equals("com.whatsapp", ignoreCase = true) && !pkg.equals("com.whatsapp.w4b", ignoreCase = true)) {
            return
        }

        val extras: Bundle = sbn.notification.extras ?: return

        // Extract sender / title
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() ?: ""

        // Extract message text (check big text, standard text, and text lines)
        var message = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim()
        if (message.isNullOrEmpty()) {
            message = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim()
        }
        if (message.isNullOrEmpty()) {
            val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            if (!lines.isNullOrEmpty()) {
                message = lines.lastOrNull()?.toString()?.trim()
            }
        }

        if (title.isEmpty() || message.isNullOrEmpty()) return

        // Filter out system / generic WhatsApp notifications
        if (title.contains("WhatsApp", ignoreCase = true) && message.contains("messages", ignoreCase = true)) {
            return
        }
        if (message.contains("Checking for new messages", ignoreCase = true)) {
            return
        }
        if (message.contains("new messages", ignoreCase = true) && message.contains("chats", ignoreCase = true)) {
            return
        }

        // Clean sender name (remove group prefixes if any)
        val sender = title

        // Save into Aarohi's memory
        saveMessage(applicationContext, sender, message, pkg)

        // Ensure TTS is initialized in background before alert
        AarohiBatteryReceiver.initTts(applicationContext)

        // Check if voice announcement is enabled
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val voiceAlertEnabled = prefs.getBoolean(KEY_VOICE_ALERT_ENABLED, true)

        if (voiceAlertEnabled) {
            val spokenAlert = "Baby, $sender just sent you on WhatsApp: \"$message\""
            AarohiBatteryReceiver.speak(
                applicationContext,
                spokenAlert,
                "💬 WhatsApp from $sender",
                message
            )
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
    }
}
