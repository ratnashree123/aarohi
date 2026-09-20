package com.mithun.aarohi

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.speech.tts.TextToSpeech
import java.util.Calendar
import java.util.Locale

class RoutineAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra("id", 1001)
        val title = intent.getStringExtra("title") ?: "Aarohi Reminder"
        val body = intent.getStringExtra("body") ?: "Time for your scheduled routine!"
        val spokenReminder = intent.getStringExtra("spoken_reminder")
            ?: (if (title.contains("drink", ignoreCase = true) || title.contains("water", ignoreCase = true)) {
                "Baby, drink water! You said to remind you."
            } else {
                "Baby, $title! You said to remind you."
            })
        val isDaily = intent.getBooleanExtra("isDaily", false)
        val hour = intent.getIntExtra("hour", -1)
        val minute = intent.getIntExtra("minute", -1)

        // Check if DND mode is active in Aarohi
        try {
            val flutterPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            if (flutterPrefs.getBoolean("flutter.aarohi_dnd_active", false)) {
                // In DND mode: reschedule daily alarm silently without speaking or ringing
                if (isDaily && hour != -1 && minute != -1) {
                    val cal = Calendar.getInstance().apply {
                        add(Calendar.DAY_OF_YEAR, 1)
                        set(Calendar.HOUR_OF_DAY, hour)
                        set(Calendar.MINUTE, minute)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }
                    val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                    val nextIntent = Intent(context, RoutineAlarmReceiver::class.java).apply {
                        action = "com.mithun.aarohi.ACTION_ROUTINE_ALARM"
                        putExtra("id", id)
                        putExtra("title", title)
                        putExtra("body", body)
                        putExtra("spoken_reminder", spokenReminder)
                        putExtra("isDaily", true)
                        putExtra("hour", hour)
                        putExtra("minute", minute)
                    }
                    val nextPendingIntent = PendingIntent.getBroadcast(
                        context, id, nextIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cal.timeInMillis, nextPendingIntent)
                    } else {
                        alarmManager.setExact(AlarmManager.RTC_WAKEUP, cal.timeInMillis, nextPendingIntent)
                    }
                }
                return
            }
        } catch (_: Exception) {}

        val channelId = "aarohi_reminders"
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val soundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)

        val audioAttr = AudioAttributes.Builder()
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .build()

        // Ensure high-priority notification channel exists with loud sound and vibration
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Aarohi Reminders & Voice Alarms",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Speaks Aarohi's voice reminders aloud and plays loud notification sound"
                enableLights(true)
                enableVibration(true)
                setSound(soundUri, audioAttr)
            }
            manager.createNotificationChannel(channel)
        }

        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            id,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
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

        manager.notify(id, notif)

        // Wake lock to keep CPU awake to speak her voice reminder
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            @Suppress("DEPRECATION")
            val wakeLock = powerManager.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "Aarohi:VoiceReminderWakeLock"
            )
            wakeLock.acquire(10000L)
        } catch (_: Exception) {}

        // Speak Aarohi's voice reminder aloud via Android TextToSpeech on STREAM_ALARM
        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (audioManager != null) {
                val maxVol = audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
                val curVol = audioManager.getStreamVolume(AudioManager.STREAM_ALARM)
                if (curVol < (maxVol * 0.4).toInt()) {
                    audioManager.setStreamVolume(AudioManager.STREAM_ALARM, (maxVol * 0.75).toInt().coerceAtLeast(1), 0)
                }
            }

            var ttsEngine: TextToSpeech? = null
            ttsEngine = TextToSpeech(context.applicationContext) { status ->
                if (status == TextToSpeech.SUCCESS) {
                    ttsEngine?.language = Locale.ENGLISH
                    ttsEngine?.setSpeechRate(0.9f)
                    ttsEngine?.setPitch(1.15f) // Warm feminine pitch
                    val params = Bundle().apply {
                        putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_ALARM)
                    }
                    ttsEngine?.speak(spokenReminder, TextToSpeech.QUEUE_FLUSH, params, "aarohi_voice_$id")
                }
            }
        } catch (_: Exception) {}

        // If daily recurring routine, schedule for tomorrow at the same hour & minute
        if (isDaily && hour >= 0 && minute >= 0) {
            val cal = Calendar.getInstance().apply {
                add(Calendar.DAY_OF_YEAR, 1)
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }

            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val nextIntent = Intent(context, RoutineAlarmReceiver::class.java).apply {
                action = "com.mithun.aarohi.ACTION_ROUTINE_ALARM"
                putExtra("id", id)
                putExtra("title", title)
                putExtra("body", body)
                putExtra("spoken_reminder", spokenReminder)
                putExtra("isDaily", true)
                putExtra("hour", hour)
                putExtra("minute", minute)
            }
            val nextPendingIntent = PendingIntent.getBroadcast(
                context,
                id,
                nextIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, cal.timeInMillis, nextPendingIntent)
            } else {
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, cal.timeInMillis, nextPendingIntent)
            }
        }
    }
}
