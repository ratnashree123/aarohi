package com.mithun.aarohi

import android.app.AlarmManager
import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Process
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val TELEPHONY_CHANNEL = "com.mithun.aarohi/telephony"
    private val SMS_CHANNEL = "com.mithun.aarohi/sms"
    private val NOTIFICATION_CHANNEL = "com.mithun.aarohi/notifications"
    private val AAROHI_NOTIF_CHANNEL_ID = "aarohi_reminders"
    private val BATTERY_CHANNEL = "com.mithun.aarohi/battery"
    private val WHATSAPP_CHANNEL = "com.mithun.aarohi/whatsapp"
    private val DISPLAY_CHANNEL = "com.mithun.aarohi/display"
    private val APPLOCK_CHANNEL = "com.mithun.aarohi/applock"
    private val batteryReceiver = AarohiBatteryReceiver()

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register Battery Receiver
        val filter = android.content.IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        try {
            registerReceiver(batteryReceiver, filter)
        } catch (_: Exception) {}

        // Initialize Native TTS for immediate speech
        AarohiBatteryReceiver.initTts(applicationContext)

        // WhatsApp Channel
        val whatsappChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WHATSAPP_CHANNEL)
        AarohiNotificationListener.onMessageCaptured = { msg ->
            runOnUiThread {
                whatsappChannel.invokeMethod("onWhatsAppMessage", msg)
            }
        }

        // Create Android Notification Channel for Android 8.0+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            val audioAttr = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .build()

            val channel = NotificationChannel(
                AAROHI_NOTIF_CHANNEL_ID,
                "Aarohi Reminders & Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Status bar alerts for Aarohi reminders, alarms, and tasks"
                enableLights(true)
                enableVibration(true)
                setSound(soundUri, audioAttr)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }

        // Telephony Channel (Dialer, Direct Call, SMS Send, Default Dialer)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TELEPHONY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "dial" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    try {
                        val clean = phone.replace(Regex("[^0-9+]"), "")
                        val uri = if (clean.isEmpty()) Uri.parse("tel:") else Uri.fromParts("tel", clean, null)
                        val intent = Intent(Intent.ACTION_DIAL, uri).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("DIAL_ERROR", e.localizedMessage, null)
                    }
                }
                "call" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    try {
                        val clean = phone.replace(Regex("[^0-9+]"), "")
                        if (clean.isEmpty()) {
                            result.error("EMPTY_PHONE", "Phone number is empty", null)
                            return@setMethodCallHandler
                        }
                        val uri = Uri.fromParts("tel", clean, null)
                        val intent = Intent(Intent.ACTION_CALL, uri).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        // Fallback to dial if ACTION_CALL is restricted
                        try {
                            val clean = phone.replace(Regex("[^0-9+]"), "")
                            val uri = Uri.fromParts("tel", clean, null)
                            val intent = Intent(Intent.ACTION_DIAL, uri).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("CALL_ERROR", e2.localizedMessage, null)
                        }
                    }
                }
                "sendSms" -> {
                    val phone = call.argument<String>("phone") ?: ""
                    val message = call.argument<String>("message") ?: ""
                    try {
                        val clean = phone.replace(Regex("[^0-9+]"), "")
                        if (clean.isEmpty() || message.isEmpty()) {
                            result.error("INVALID_ARGS", "Valid phone and message required", null)
                            return@setMethodCallHandler
                        }

                        val smsManager = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                            context.getSystemService(android.telephony.SmsManager::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            android.telephony.SmsManager.getDefault()
                        }

                        val parts = smsManager.divideMessage(message)
                        if (parts.size > 1) {
                            smsManager.sendMultipartTextMessage(clean, null, parts, null, null)
                        } else {
                            smsManager.sendTextMessage(clean, null, message, null, null)
                        }

                        // Write to sent SMS provider so it appears in messaging app history
                        try {
                            val values = android.content.ContentValues().apply {
                                put("address", clean)
                                put("body", message)
                                put("date", System.currentTimeMillis())
                                put("read", 1)
                                put("type", 2) // 2 = SENT
                            }
                            contentResolver.insert(Uri.parse("content://sms/sent"), values)
                        } catch (_: Exception) {}

                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SEND_SMS_ERROR", e.localizedMessage, null)
                    }
                }
                "requestDefaultDialer" -> {
                    try {
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                            val roleManager = getSystemService(android.app.role.RoleManager::class.java)
                            if (roleManager.isRoleAvailable(android.app.role.RoleManager.ROLE_DIALER) &&
                                !roleManager.isRoleHeld(android.app.role.RoleManager.ROLE_DIALER)) {
                                val intent = roleManager.createRequestRoleIntent(android.app.role.RoleManager.ROLE_DIALER)
                                startActivity(intent)
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        } else {
                            val intent = Intent(android.telecom.TelecomManager.ACTION_CHANGE_DEFAULT_DIALER).apply {
                                putExtra(android.telecom.TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME, packageName)
                            }
                            startActivity(intent)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        result.error("ROLE_ERROR", e.localizedMessage, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // SMS Channel (Read SMS Inbox)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getSmsInbox" -> {
                    try {
                        val smsList = mutableListOf<Map<String, String>>()
                        val cursor = contentResolver.query(
                            Uri.parse("content://sms/inbox"),
                            arrayOf("_id", "address", "body", "date", "read"),
                            null,
                            null,
                            "date DESC LIMIT 50"
                        )

                        cursor?.use {
                            val addressIdx = it.getColumnIndex("address")
                            val bodyIdx = it.getColumnIndex("body")
                            val dateIdx = it.getColumnIndex("date")
                            val sdf = SimpleDateFormat("MMM dd, hh:mm a", Locale.getDefault())

                            while (it.moveToNext()) {
                                val address = if (addressIdx != -1) it.getString(addressIdx) ?: "Unknown" else "Unknown"
                                val body = if (bodyIdx != -1) it.getString(bodyIdx) ?: "" else ""
                                val timestamp = if (dateIdx != -1) it.getLong(dateIdx) else 0L
                                val dateStr = if (timestamp > 0) sdf.format(Date(timestamp)) else ""

                                smsList.add(mapOf(
                                    "sender" to address,
                                    "phone" to address,
                                    "body" to body,
                                    "time" to dateStr,
                                    "type" to "sms"
                                ))
                            }
                        }

                        result.success(smsList)
                    } catch (e: Exception) {
                        result.success(emptyList<Map<String, String>>())
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Notification Channel (Status Bar Notifications & Alerts)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIFICATION_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "showNotification" -> {
                    val title = call.argument<String>("title") ?: "Aarohi Reminder"
                    val body = call.argument<String>("body") ?: ""
                    try {
                        val intent = Intent(this, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                        }
                        val pendingIntent = PendingIntent.getActivity(
                            this,
                            0,
                            intent,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        )

                        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Notification.Builder(this, AAROHI_NOTIF_CHANNEL_ID)
                        } else {
                            @Suppress("DEPRECATION")
                            Notification.Builder(this)
                        }

                        val notif = builder
                            .setContentTitle(title)
                            .setContentText(body)
                            .setSmallIcon(R.mipmap.ic_launcher)
                            .setAutoCancel(true)
                            .setContentIntent(pendingIntent)
                            .setPriority(Notification.PRIORITY_HIGH)
                            .setDefaults(Notification.DEFAULT_ALL)
                            .build()

                        val manager = getSystemService(NotificationManager::class.java)
                        val notifId = (System.currentTimeMillis() % 10000).toInt()
                        manager.notify(notifId, notif)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("NOTIF_ERROR", e.localizedMessage, null)
                    }
                }
                "scheduleAlarm" -> {
                    val id = call.argument<Int>("id") ?: (System.currentTimeMillis() % 100000).toInt()
                    val title = call.argument<String>("title") ?: "Aarohi Routine Reminder"
                    val body = call.argument<String>("body") ?: ""
                    val triggerAtMillis = call.argument<Long>("triggerAtMillis") ?: (System.currentTimeMillis() + 60000L)
                    val isDaily = call.argument<Boolean>("isDaily") ?: false
                    val hour = call.argument<Int>("hour") ?: -1
                    val minute = call.argument<Int>("minute") ?: -1
                    val spokenReminder = call.argument<String>("spokenReminder") ?: ""

                    try {
                        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        val intent = Intent(this, RoutineAlarmReceiver::class.java).apply {
                            action = "com.mithun.aarohi.ACTION_ROUTINE_ALARM"
                            putExtra("id", id)
                            putExtra("title", title)
                            putExtra("body", body)
                            putExtra("spoken_reminder", spokenReminder)
                            putExtra("isDaily", isDaily)
                            putExtra("hour", hour)
                            putExtra("minute", minute)
                        }
                        val pendingIntent = PendingIntent.getBroadcast(
                            this,
                            id,
                            intent,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        )

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
                        } else {
                            alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("ALARM_ERROR", e.localizedMessage, null)
                    }
                }
                "cancelAlarm" -> {
                    val id = call.argument<Int>("id") ?: 0
                    try {
                        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        val intent = Intent(this, RoutineAlarmReceiver::class.java).apply {
                            action = "com.mithun.aarohi.ACTION_ROUTINE_ALARM"
                        }
                        val pendingIntent = PendingIntent.getBroadcast(
                            this,
                            id,
                            intent,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        )
                        alarmManager.cancel(pendingIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CANCEL_ERROR", e.localizedMessage, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Battery Channel Handler
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BATTERY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBatteryStatus" -> {
                    try {
                        val ifilter = android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED)
                        val bStatus: Intent? = registerReceiver(null, ifilter)
                        val level = bStatus?.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1) ?: -1
                        val scale = bStatus?.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, -1) ?: -1
                        val status = bStatus?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
                        val temp = bStatus?.getIntExtra(android.os.BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
                        val isCharging = status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
                                status == android.os.BatteryManager.BATTERY_STATUS_FULL
                        val pct = if (level >= 0 && scale > 0) (level * 100) / scale else 50
                        val tempC = if (temp > 0) temp / 10.0 else 30.0

                        result.success(mapOf(
                            "level" to pct,
                            "isCharging" to isCharging,
                            "temperature" to tempC,
                            "health" to "Good"
                        ))
                    } catch (e: Exception) {
                        result.error("BATTERY_ERROR", e.localizedMessage, null)
                    }
                }
                "setDramaticEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    val prefs = getSharedPreferences("aarohi_battery_prefs", Context.MODE_PRIVATE)
                    prefs.edit().putBoolean("dramatic_battery_alerts_enabled", enabled).apply()
                    result.success(true)
                }
                "isDramaticEnabled" -> {
                    val prefs = getSharedPreferences("aarohi_battery_prefs", Context.MODE_PRIVATE)
                    val enabled = prefs.getBoolean("dramatic_battery_alerts_enabled", true)
                    result.success(enabled)
                }
                "speakDramaticAlert" -> {
                    val pct = call.argument<Int>("percent") ?: 15
                    val text = "Baby! I'm at $pct%! I am going to die, save me! Plug the charger in right now!"
                    AarohiBatteryReceiver.speak(applicationContext, text, "🚨 Aarohi is Dying! ($pct%)", text)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // WhatsApp Notification Watcher Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WHATSAPP_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getMessages" -> {
                    val list = AarohiNotificationListener.getSavedMessages(applicationContext)
                    result.success(list)
                }
                "isAccessGranted" -> {
                    val enabledListeners = android.provider.Settings.Secure.getString(
                        contentResolver,
                        "enabled_notification_listeners"
                    ) ?: ""
                    val isGranted = enabledListeners.contains(packageName)
                    result.success(isGranted)
                }
                "requestAccess" -> {
                    try {
                        val intent = Intent(android.provider.Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERROR", e.localizedMessage, null)
                    }
                }
                "setVoiceAlertEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val prefs = getSharedPreferences(AarohiNotificationListener.PREFS_NAME, Context.MODE_PRIVATE)
                    prefs.edit().putBoolean(AarohiNotificationListener.KEY_VOICE_ALERT_ENABLED, enabled).apply()
                    result.success(true)
                }
                "isVoiceAlertEnabled" -> {
                    val prefs = getSharedPreferences(AarohiNotificationListener.PREFS_NAME, Context.MODE_PRIVATE)
                    val enabled = prefs.getBoolean(AarohiNotificationListener.KEY_VOICE_ALERT_ENABLED, false)
                    result.success(enabled)
                }
                "clearMessages" -> {
                    val prefs = getSharedPreferences(AarohiNotificationListener.PREFS_NAME, Context.MODE_PRIVATE)
                    prefs.edit().remove(AarohiNotificationListener.KEY_MESSAGES_JSON).apply()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Display & Volume Emotional Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DISPLAY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setBrightness" -> {
                    try {
                        val raw = call.argument<Any>("brightness")
                        val brightness = when (raw) {
                            is Number -> raw.toFloat()
                            is String -> raw.toFloatOrNull() ?: 1.0f
                            else -> 1.0f
                        }.coerceIn(0.01f, 1.0f)

                        // 1. Set window brightness (immediate visual effect on active screen)
                        runOnUiThread {
                            try {
                                val lp = window.attributes
                                lp.screenBrightness = brightness
                                window.attributes = lp
                            } catch (e: Exception) {
                                android.util.Log.e("AarohiDisplay", "Window brightness error: ${e.message}")
                            }
                        }

                        // 2. Set system-wide brightness & notify system server
                        try {
                            if (Settings.System.canWrite(applicationContext)) {
                                Settings.System.putInt(
                                    contentResolver,
                                    Settings.System.SCREEN_BRIGHTNESS_MODE,
                                    Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL
                                )
                                val target255 = (brightness * 255).toInt().coerceIn(1, 255)
                                Settings.System.putInt(
                                    contentResolver,
                                    Settings.System.SCREEN_BRIGHTNESS,
                                    target255
                                )
                                contentResolver.notifyChange(
                                    Settings.System.getUriFor(Settings.System.SCREEN_BRIGHTNESS), null
                                )
                                contentResolver.notifyChange(
                                    Settings.System.getUriFor(Settings.System.SCREEN_BRIGHTNESS_MODE), null
                                )
                            }
                        } catch (e: Exception) {
                            android.util.Log.e("AarohiDisplay", "System brightness error: ${e.message}")
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BRIGHTNESS_ERROR", e.localizedMessage, null)
                    }
                }
                "getBrightness" -> {
                    val cur = window.attributes.screenBrightness
                    if (cur >= 0) {
                        result.success(cur.toDouble())
                    } else {
                        // Read system brightness
                        try {
                            val sysBright = Settings.System.getInt(
                                contentResolver,
                                Settings.System.SCREEN_BRIGHTNESS, 128
                            )
                            result.success(sysBright.toDouble() / 255.0)
                        } catch (_: Exception) {
                            result.success(0.65)
                        }
                    }
                }
                "canWriteSettings" -> {
                    result.success(Settings.System.canWrite(applicationContext))
                }
                "requestWriteSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS,
                            android.net.Uri.parse("package:$packageName")
                        ).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
                        startActivity(intent)
                    } catch (_: Exception) {}
                    result.success(true)
                }
                "setVolume" -> {
                    try {
                        val raw = call.argument<Any>("volume")
                        val vol = when (raw) {
                            is Number -> raw.toDouble()
                            is String -> raw.toDoubleOrNull() ?: 1.0
                            else -> 1.0
                        }.coerceIn(0.0, 1.0)

                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? android.media.AudioManager
                        if (audioManager != null) {
                            val maxMusic = audioManager.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                            val target = (vol * maxMusic).toInt().coerceIn(0, maxMusic)
                            audioManager.setStreamVolume(android.media.AudioManager.STREAM_MUSIC, target, 0)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("VOLUME_ERROR", e.localizedMessage, null)
                    }
                }
                "getVolume" -> {
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as? android.media.AudioManager
                    if (audioManager != null) {
                        val max = audioManager.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                        val cur = audioManager.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                        result.success(if (max > 0) cur.toDouble() / max.toDouble() else 1.0)
                    } else {
                        result.success(1.0)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // App Lock Channel — Aarohi locks distracting apps
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APPLOCK_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "lockApps" -> {
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    val task = call.argument<String>("task") ?: "your current task"
                    try {
                        val intent = Intent(this, AarohiAppLockService::class.java).apply {
                            action = "LOCK"
                            putStringArrayListExtra("packages", ArrayList(packages))
                            putExtra("task", task)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        // Fallback: start as regular service
                        try {
                            val intent = Intent(this, AarohiAppLockService::class.java).apply {
                                action = "LOCK"
                                putStringArrayListExtra("packages", ArrayList(packages))
                                putExtra("task", task)
                            }
                            startService(intent)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("LOCK_ERROR", e2.localizedMessage, null)
                        }
                    }
                }
                "unlockApps" -> {
                    try {
                        val intent = Intent(this, AarohiAppLockService::class.java).apply {
                            action = "UNLOCK"
                        }
                        startService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("UNLOCK_ERROR", e.localizedMessage, null)
                    }
                }
                "hasOverlayPermission" -> {
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(this)
                    } else {
                        true
                    }
                    result.success(granted)
                }
                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        ).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                    }
                    result.success(true)
                }
                "hasUsagePermission" -> {
                    try {
                        val appOps = getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
                        val mode = if (appOps != null) {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                appOps.unsafeCheckOpNoThrow(
                                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                                    Process.myUid(),
                                    packageName
                                )
                            } else {
                                @Suppress("DEPRECATION")
                                appOps.checkOpNoThrow(
                                    AppOpsManager.OPSTR_GET_USAGE_STATS,
                                    Process.myUid(),
                                    packageName
                                )
                            }
                        } else {
                            AppOpsManager.MODE_DEFAULT
                        }
                        val granted = (mode == AppOpsManager.MODE_ALLOWED)
                        result.success(granted)
                    } catch (e: Exception) {
                        // Fallback check
                        val usageManager = getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                        val endTime = System.currentTimeMillis()
                        val stats = usageManager?.queryUsageStats(
                            UsageStatsManager.INTERVAL_DAILY,
                            endTime - 1000 * 3600, endTime
                        )
                        result.success(!stats.isNullOrEmpty())
                    }
                }
                "requestUsagePermission" -> {
                    val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    startActivity(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(batteryReceiver)
        } catch (_: Exception) {}
    }
}
