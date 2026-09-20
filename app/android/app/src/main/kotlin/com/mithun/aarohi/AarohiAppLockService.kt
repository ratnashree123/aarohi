package com.mithun.aarohi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.Voice
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Locale

/**
 * AarohiAppLockService – Aarohi locks distracting apps until Mithun finishes his task.
 *
 * Key behaviors:
 * 1. Uses Aarohi's identical feminine, warm voice (en-US, pitch 1.15f, speechRate 0.88f)
 *    and affectionate girlfriend scolding tone calling Mithun "baby".
 * 2. Does NOT duplicate speech on LOCK/UNLOCK (conversational acknowledgments are spoken by Flutter).
 * 3. Accurate, real-time foreground detection via UsageEvents + INTERVAL_BEST fallback.
 * 4. Debounced kick-to-home (1.5s) to eliminate rapid intent flickering.
 * 5. Aura-themed dark/amber overlay with Back-key interception and auto-dismiss when Aarohi is opened.
 * 6. Persistent state across service restarts via SharedPreferences.
 */
class AarohiAppLockService : Service(), TextToSpeech.OnInitListener {

    companion object {
        var lockedPackages: MutableSet<String> = mutableSetOf()
        var currentTask: String = "your current task"
        var isLockActive: Boolean = false
        private const val LOCK_CHANNEL_ID = "aarohi_focus_mode"
        private const val LOCK_NOTIF_ID = 7777
        private const val PREFS_NATIVE = "aarohi_applock_native"

        val KNOWN_APPS = mapOf(
            "instagram" to "com.instagram.android",
            "insta" to "com.instagram.android",
            "ig" to "com.instagram.android",
            "youtube" to "com.google.android.youtube",
            "yt" to "com.google.android.youtube",
            "twitter" to "com.twitter.android",
            "x" to "com.twitter.android",
            "snapchat" to "com.snapchat.android",
            "snap" to "com.snapchat.android",
            "facebook" to "com.facebook.katana",
            "fb" to "com.facebook.katana",
            "tiktok" to "com.zhiliaoapp.musically",
            "reddit" to "com.reddit.frontpage",
            "whatsapp" to "com.whatsapp",
            "telegram" to "org.telegram.messenger",
            "netflix" to "com.netflix.mediaclient",
            "chrome" to "com.android.chrome",
            "browser" to "com.android.chrome",
            "discord" to "com.discord",
            "pinterest" to "com.pinterest",
            "linkedin" to "com.linkedin.android",
            "amazon" to "com.amazon.mShop.android.shopping",
            "prime video" to "com.amazon.avod.thirdpartyclient",
            "hotstar" to "in.startv.hotstar",
            "twitch" to "tv.twitch.android.app"
        )

        fun resolvePackage(appName: String): String {
            val lower = appName.lowercase().trim()
            return KNOWN_APPS[lower] ?: lower
        }

        fun resolveAppName(pkg: String): String {
            val entry = KNOWN_APPS.entries.firstOrNull { it.value == pkg }
            return if (entry != null) {
                entry.key.replaceFirstChar { it.uppercase() }
            } else {
                pkg.substringAfterLast('.').replaceFirstChar { it.uppercase() }
            }
        }
    }

    private var windowManager: WindowManager? = null
    private var overlayView: LinearLayout? = null
    private var tts: TextToSpeech? = null
    private var isTtsReady = false
    private var pendingSpeechText: String? = null
    private var handler: Handler? = null
    private var checkRunnable: Runnable? = null
    private var isOverlayShowing = false
    private var lastSpokenTime: Long = 0
    private var lastKickedTime: Long = 0

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        handler = Handler(Looper.getMainLooper())
        tts = TextToSpeech(applicationContext, this)

        loadState()
        createForegroundNotification()
        startChecking()
    }

    private fun loadState() {
        try {
            val prefs = getSharedPreferences(PREFS_NATIVE, Context.MODE_PRIVATE)
            isLockActive = prefs.getBoolean("is_lock_active", isLockActive)
            currentTask = prefs.getString("current_task", currentTask) ?: currentTask
            val savedPkgs = prefs.getStringSet("locked_packages", null)
            if (!savedPkgs.isNullOrEmpty()) {
                lockedPackages.clear()
                lockedPackages.addAll(savedPkgs)
            }
        } catch (_: Exception) {}
    }

    private fun saveState() {
        try {
            val prefs = getSharedPreferences(PREFS_NATIVE, Context.MODE_PRIVATE)
            prefs.edit()
                .putBoolean("is_lock_active", isLockActive)
                .putString("current_task", currentTask)
                .putStringSet("locked_packages", HashSet(lockedPackages))
                .apply()
        } catch (_: Exception) {}
    }

    private fun createForegroundNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                LOCK_CHANNEL_ID,
                "Aarohi Focus Mode",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Active while Aarohi is blocking distracting apps to protect your focus"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }

        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val taskDesc = if (currentTask.isNotEmpty()) currentTask else "your work"
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, LOCK_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setContentTitle("🔒 Aarohi Focus Mode Active")
            .setContentText("Keeping you disciplined for: $taskDesc")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                LOCK_NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(LOCK_NOTIF_ID, notification)
        }
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            isTtsReady = true
            configureVoice()
            pendingSpeechText?.let { text ->
                pendingSpeechText = null
                speakWarning(text)
            }
        } else {
            isTtsReady = false
        }
    }

    /**
     * Configures the TextToSpeech engine with Aarohi's exact feminine profile:
     * - Checks SharedPreferences for the exact voice name picked by Flutter
     * - Falls back to en-US female voice selection
     * - Uses gentle feminine pitch (1.15f) and relaxed speech rate (0.88f)
     */
    private fun configureVoice() {
        val engine = tts ?: return
        try {
            engine.language = Locale.US

            // 1. Check if Flutter saved the exact voice name
            val flutterPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val savedVoiceName = flutterPrefs.getString("flutter.aarohi_tts_voice_name", null)

            val availableVoices = engine.voices
            var chosenVoice: Voice? = null

            if (!savedVoiceName.isNullOrEmpty() && !availableVoices.isNullOrEmpty()) {
                chosenVoice = availableVoices.firstOrNull { it.name.equals(savedVoiceName, ignoreCase = true) }
            }

            // 2. Fallback: match female en-US voice
            if (chosenVoice == null && !availableVoices.isNullOrEmpty()) {
                chosenVoice = availableVoices.firstOrNull { v ->
                    val name = v.name.lowercase()
                    val loc = v.locale.toString().lowercase()
                    (loc.startsWith("en") || loc.contains("eng")) && (
                        name.contains("female") ||
                        name.contains("f0") ||
                        name.contains("sfg") ||
                        name.contains("ahf") ||
                        name.contains("cxx") ||
                        name.contains("woman") ||
                        name.contains("girl")
                    )
                } ?: availableVoices.firstOrNull { v ->
                    v.locale.language.equals("en", ignoreCase = true) && !v.name.lowercase().contains("male")
                }
            }

            if (chosenVoice != null) {
                engine.voice = chosenVoice
            }

            engine.setPitch(1.15f) // Warm, cute feminine pitch matching Aarohi
            engine.setSpeechRate(0.88f) // Slower, relaxed unhurried girlfriend delivery
        } catch (e: Exception) {
            android.util.Log.e("AarohiAppLock", "Voice configuration error: ${e.message}")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "LOCK" -> {
                val packages = intent.getStringArrayListExtra("packages") ?: arrayListOf()
                val task = intent.getStringExtra("task") ?: "your current task"
                lockedPackages.clear()
                lockedPackages.addAll(packages)
                currentTask = task
                isLockActive = true
                lastSpokenTime = 0
                lastKickedTime = 0

                saveState()
                createForegroundNotification()
                // Conversational acknowledgment is handled in Flutter by chat_screen.dart
                // to prevent double-voice collision.
            }
            "UNLOCK" -> {
                isLockActive = false
                lockedPackages.clear()
                currentTask = ""
                removeOverlay()
                saveState()
                // Conversational unlock is handled in Flutter by chat_screen.dart
                handler?.postDelayed({ stopSelf() }, 1500)
            }
            "ADD_APP" -> {
                val pkg = intent.getStringExtra("package") ?: return START_STICKY
                lockedPackages.add(pkg)
                saveState()
            }
            "REMOVE_APP" -> {
                val pkg = intent.getStringExtra("package") ?: return START_STICKY
                lockedPackages.remove(pkg)
                saveState()
            }
        }
        return START_STICKY
    }

    private fun startChecking() {
        checkRunnable = object : Runnable {
            override fun run() {
                if (isLockActive && lockedPackages.isNotEmpty()) {
                    checkForegroundApp()
                }
                handler?.postDelayed(this, 500)
            }
        }
        handler?.post(checkRunnable!!)
    }

    private fun checkForegroundApp() {
        val foregroundPkg = getForegroundPackage() ?: return

        // 1. If currently inside Aarohi itself, immediately dismiss overlay if showing
        if (foregroundPkg == packageName) {
            if (isOverlayShowing) {
                removeOverlay()
            }
            return
        }

        // 2. If user opened a locked app
        if (lockedPackages.contains(foregroundPkg)) {
            val appName = resolveAppName(foregroundPkg)
            val now = System.currentTimeMillis()

            // Kick user to Home screen with a 1.5s debounce to prevent rapid screen flickering
            if (now - lastKickedTime > 1500) {
                lastKickedTime = now
                kickToHome()
            }

            // Speak Aarohi's girlfriend warning (cooldown 10s so she doesn't repeat every 500ms)
            if (now - lastSpokenTime > 10000) {
                lastSpokenTime = now
                val girlfriendWarnings = listOf(
                    "Baby! Close $appName right now! You promised me you would finish $currentTask! Put the phone down and get to work!",
                    "Nuh-uh baby! No $appName for you! You have to finish $currentTask first! Close it right now, baby!",
                    "Excuse me, baby?! Who gave you permission to open $appName?! Put this phone down and finish $currentTask immediately!",
                    "Baby, what are you doing on $appName?! Close it! Go finish $currentTask right now, or your girl is going to be really upset with you!",
                    "No way baby! I am not letting you waste time on $appName! You promised to complete $currentTask! Back to work, now!"
                )
                speakWarning(girlfriendWarnings.random())
            }

            // Show full-screen blocking overlay if permission granted
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)) {
                showOverlay(appName)
            }
        }
    }

    private fun kickToHome() {
        try {
            val homeIntent = Intent(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
            }
            startActivity(homeIntent)
        } catch (e: Exception) {
            android.util.Log.e("AarohiAppLock", "Failed to navigate home: ${e.message}")
        }
    }

    /**
     * Accurately detects the current foreground application:
     * 1. Uses UsageEvents with a tight 10-second lookback window for real-time events.
     * 2. Falls back to UsageStats with INTERVAL_BEST (fine-grained bucket).
     */
    private fun getForegroundPackage(): String? {
        val usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
            ?: return null
        val endTime = System.currentTimeMillis()
        val beginTime = endTime - 10000

        // 1. Real-time check using UsageEvents (Android 9–15)
        try {
            val usageEvents = usageStatsManager.queryEvents(beginTime, endTime)
            val event = UsageEvents.Event()
            var lastResumedPkg: String? = null
            var lastEventTime: Long = 0

            while (usageEvents.hasNextEvent()) {
                usageEvents.getNextEvent(event)
                // Event 1: ACTIVITY_RESUMED or MOVE_TO_FOREGROUND
                if (event.eventType == UsageEvents.Event.ACTIVITY_RESUMED || event.eventType == 1) {
                    if (event.timeStamp >= lastEventTime) {
                        lastEventTime = event.timeStamp
                        lastResumedPkg = event.packageName
                    }
                }
            }
            if (!lastResumedPkg.isNullOrEmpty()) {
                return lastResumedPkg
            }
        } catch (e: Exception) {
            android.util.Log.e("AarohiAppLock", "queryEvents error: ${e.message}")
        }

        // 2. Fallback using queryUsageStats with INTERVAL_BEST
        try {
            val stats = usageStatsManager.queryUsageStats(
                UsageStatsManager.INTERVAL_BEST,
                endTime - 60000,
                endTime
            )
            if (!stats.isNullOrEmpty()) {
                val mostRecent = stats.maxByOrNull { it.lastTimeUsed }
                if (mostRecent != null && (endTime - mostRecent.lastTimeUsed) < 15000) {
                    return mostRecent.packageName
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("AarohiAppLock", "queryUsageStats error: ${e.message}")
        }

        return null
    }

    /**
     * Displays Aarohi's Aura-themed focus mode blocking overlay.
     * Intercepts Back button to return home safely without trapping the user.
     */
    private fun showOverlay(appName: String) {
        if (isOverlayShowing) return

        val taskText = if (currentTask.isNotEmpty()) currentTask else "your work"

        // Card container drawable with subtle amber border
        val cardBg = GradientDrawable().apply {
            setColor(Color.parseColor("#F5141312")) // Aura surface
            cornerRadius = 48f
            setStroke(3, Color.parseColor("#80FF9500")) // Aura amber border glow
        }

        val btnBackBg = GradientDrawable().apply {
            setColor(Color.parseColor("#FF9500")) // Aura amber
            cornerRadius = 32f
        }

        val btnAarohiBg = GradientDrawable().apply {
            setColor(Color.parseColor("#261B10")) // Hearth dark
            cornerRadius = 32f
            setStroke(2, Color.parseColor("#554334"))
        }

        val btnUnlockBg = GradientDrawable().apply {
            setColor(Color.parseColor("#1C1318"))
            cornerRadius = 24f
        }

        // Root overlay layout that captures physical Back button
        overlayView = object : LinearLayout(this) {
            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                    removeOverlay()
                    kickToHome()
                    return true
                }
                return super.dispatchKeyEvent(event)
            }
        }.apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#E60A0A0A")) // Deep Aura void with 90% opacity
            setPadding(40, 60, 40, 60)

            // Inner Card
            val card = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                background = cardBg
                setPadding(50, 60, 50, 60)

                // Warning Icon
                addView(TextView(context).apply {
                    text = "🔒 😤"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 48f)
                    gravity = Gravity.CENTER
                })

                // Subtitle Header
                addView(TextView(context).apply {
                    text = "AAROHI FOCUS MODE • STRICT LOCKDOWN"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                    setTextColor(Color.parseColor("#FFB874"))
                    typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
                    gravity = Gravity.CENTER
                    setPadding(0, 14, 0, 6)
                    letterSpacing = 0.12f
                })

                // Title
                addView(TextView(context).apply {
                    text = "PUT THE PHONE DOWN, BABY!"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                    setTextColor(Color.parseColor("#FF9500"))
                    typeface = Typeface.create("sans-serif", Typeface.BOLD)
                    gravity = Gravity.CENTER
                    setPadding(0, 4, 0, 16)
                })

                // Message Body
                addView(TextView(context).apply {
                    text = "Baby, you are NOT allowed to use $appName right now!\n\nYour required task is:\n👉 \"$taskText\" 👈\n\nNo slacking off baby! Put the phone down and finish your work! I am watching you! ❤️"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                    setTextColor(Color.parseColor("#E5E2E1"))
                    gravity = Gravity.CENTER
                    setPadding(10, 4, 10, 24)
                    setLineSpacing(6f, 1.25f)
                })

                // Primary Button: "Back to Work Baby"
                addView(Button(context).apply {
                    text = "Back to Work Baby 🫡"
                    background = btnBackBg
                    setTextColor(Color.parseColor("#1F1400"))
                    textSize = 14f
                    typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
                    setPadding(36, 20, 36, 20)
                    setOnClickListener {
                        removeOverlay()
                        kickToHome()
                    }
                })

                // Spacer
                addView(TextView(context).apply { height = 18 })

                // Secondary Button: "Open Aarohi (Say 'Task Done')"
                addView(Button(context).apply {
                    text = "Open Aarohi (Say 'Task Done')"
                    background = btnAarohiBg
                    setTextColor(Color.parseColor("#FFB874"))
                    textSize = 12f
                    setPadding(28, 16, 28, 16)
                    setOnClickListener {
                        removeOverlay()
                        val openApp = Intent(context, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        }
                        startActivity(openApp)
                    }
                })

                // Spacer
                addView(TextView(context).apply { height = 14 })

                // Tertiary Button: "Manual Unlock"
                addView(Button(context).apply {
                    text = "Manual Unlock 🔓"
                    background = btnUnlockBg
                    setTextColor(Color.parseColor("#FFA0BF"))
                    textSize = 11f
                    setPadding(20, 10, 20, 10)
                    setOnClickListener {
                        removeOverlay()
                        lockedPackages.clear()
                        isLockActive = false
                        currentTask = ""
                        saveState()
                        try {
                            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                            prefs.edit()
                                .putBoolean("flutter.applock_active", false)
                                .putString("flutter.applock_task", "")
                                .apply()
                        } catch (_: Exception) {}
                        speakWarning("Apps unlocked baby! Take a well-deserved break! 😘")
                    }
                })
            }

            addView(card)
        }

        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            layoutType,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.CENTER
        }

        try {
            windowManager?.addView(overlayView, params)
            isOverlayShowing = true
        } catch (e: Exception) {
            android.util.Log.e("AarohiAppLock", "Failed to add overlay: ${e.message}")
        }
    }

    private fun removeOverlay() {
        try {
            if (overlayView != null && isOverlayShowing) {
                windowManager?.removeView(overlayView)
            }
        } catch (_: Exception) {}
        overlayView = null
        isOverlayShowing = false
    }

    /**
     * Speaks aloud using Aarohi's configured feminine girlfriend voice on STREAM_MUSIC.
     */
    private fun speakWarning(text: String) {
        try {
            // Respect Do Not Disturb (DND)
            val flutterPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            if (flutterPrefs.getBoolean("flutter.aarohi_dnd_active", false)) {
                return
            }
        } catch (_: Exception) {}

        if (!isTtsReady) {
            pendingSpeechText = text
            return
        }

        try {
            configureVoice()

            // Ensure media stream has sufficient audible volume without harsh distortion
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            audioManager?.let { am ->
                val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                val curVol = am.getStreamVolume(AudioManager.STREAM_MUSIC)
                if (curVol < (maxVol * 0.4).toInt()) {
                    am.setStreamVolume(AudioManager.STREAM_MUSIC, (maxVol * 0.75).toInt().coerceAtLeast(1), 0)
                }
            }

            val params = Bundle().apply {
                putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC)
            }
            tts?.speak(text, TextToSpeech.QUEUE_FLUSH, params, "aarohi_lock_${System.currentTimeMillis()}")
        } catch (e: Exception) {
            android.util.Log.e("AarohiAppLock", "Error speaking warning: ${e.message}")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        handler?.removeCallbacksAndMessages(null)
        removeOverlay()
        tts?.stop()
        tts?.shutdown()
        super.onDestroy()
    }
}
