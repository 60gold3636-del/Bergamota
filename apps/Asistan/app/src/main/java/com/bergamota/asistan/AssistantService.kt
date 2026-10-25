package com.bergamota.asistan

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import org.vosk.android.StorageService

/**
 * Listens to the microphone all the time with the offline Vosk Turkish model.
 * "asistan <komut>" runs the command; "asistan" alone beeps and waits for one command.
 */
class AssistantService : Service(), RecognitionListener {
    companion object {
        const val ACTION_STOP = "com.bergamota.asistan.STOP"
        const val ACTION_LISTEN = "com.bergamota.asistan.LISTEN"
        const val ACTION_TEXT = "com.bergamota.asistan.TEXT"
        const val EXTRA_TEXT = "text"
        private const val CHANNEL = "asistan"
        private const val NOTIFICATION_ID = 1
        private const val COMMAND_WINDOW_MS = 8000L

        @Volatile
        var running = false
            private set

        fun start(ctx: Context, action: String? = null, text: String? = null) {
            val i = Intent(ctx, AssistantService::class.java).setAction(action)
            if (text != null) i.putExtra(EXTRA_TEXT, text)
            ctx.startForegroundService(i)
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var prefs: Prefs
    private lateinit var speaker: Speaker
    private lateinit var assistant: Assistant
    private var model: Model? = null
    private var recognizer: Recognizer? = null
    private var speech: SpeechService? = null
    private var tone: ToneGenerator? = null
    private var commandUntil = 0L
    private var beepedThisUtterance = false
    private var listenWhenReady = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        speaker = Speaker(this) { busy -> speech?.setPause(busy) }
        assistant = Assistant(this, speaker)
        tone = try { ToneGenerator(AudioManager.STREAM_MUSIC, 70) } catch (e: Exception) { null }
        goForeground("Model yükleniyor…")
        running = true
        loadModel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { stopSelf(); return START_NOT_STICKY }
            ACTION_LISTEN -> if (speech == null) listenWhenReady = true else armCommand()
            ACTION_TEXT -> intent.getStringExtra(EXTRA_TEXT)?.let { assistant.handle(it) }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        main.removeCallbacksAndMessages(null)
        speech?.stop()
        speech?.shutdown()
        recognizer?.close()
        model?.close()
        speaker.shutdown()
        assistant.shutdown()
        tone?.release()
        Bus.status("Kapalı")
        super.onDestroy()
    }

    private fun loadModel() {
        Bus.status("Model yükleniyor…")
        LibVosk.setLogLevel(LogLevel.WARNINGS)
        StorageService.unpack(this, "model-tr", "model", { m ->
            if (!running) { m.close(); return@unpack }
            model = m
            startListening()
        }, { e ->
            Bus.status("Konuşma modeli yüklenemedi")
            Bus.log("Model hatası: ${e.message}")
        })
    }

    private fun startListening() {
        val m = model ?: return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Bus.status("Mikrofon izni yok")
            return
        }
        try {
            speech?.shutdown()
            recognizer?.close()
            val rec = Recognizer(m, 16000f)
            recognizer = rec
            speech = SpeechService(rec, 16000f).also { it.startListening(this) }
            val s = if (prefs.noWakeWord) "Dinliyor (her cümle komut)" else "Dinliyor: \"${prefs.wakeWord} …\""
            Bus.status(s)
            updateNotification(s)
            if (listenWhenReady) { listenWhenReady = false; armCommand() }
        } catch (e: Exception) {
            Bus.status("Mikrofon açılamadı")
            Bus.log("Mikrofon: $e")
            main.postDelayed({ if (running) startListening() }, 3000)
        }
    }

    // --- Vosk callbacks (main thread) ---

    override fun onPartialResult(hypothesis: String) {
        if (beepedThisUtterance || prefs.noWakeWord || SystemClock.elapsedRealtime() < commandUntil) return
        val partial = JSONObject(hypothesis).optString("partial")
        if (partial.isNotBlank() && afterWakeWord(partial) != null) {
            beepedThisUtterance = true
            beep()
        }
    }

    override fun onResult(hypothesis: String) = onUtterance(JSONObject(hypothesis).optString("text"))

    override fun onFinalResult(hypothesis: String) = onUtterance(JSONObject(hypothesis).optString("text"))

    override fun onError(exception: Exception) {
        Bus.log("Tanıma hatası: ${exception.message}")
        main.postDelayed({ if (running) startListening() }, 2000)
    }

    override fun onTimeout() {
        if (running) startListening()
    }

    private fun onUtterance(text: String) {
        val wasBeeped = beepedThisUtterance
        beepedThisUtterance = false
        if (text.isBlank()) return
        Bus.log("Duyulan: $text")
        val now = SystemClock.elapsedRealtime()
        if (now < commandUntil) {
            commandUntil = 0
            restoreStatus()
            assistant.handle(text)
            return
        }
        if (prefs.noWakeWord) {
            assistant.handle(text, quietIfUnknown = true)
            return
        }
        val rest = afterWakeWord(text) ?: return
        if (rest.isBlank()) armCommand(beep = !wasBeeped) else assistant.handle(rest)
    }

    /** Text after the wake word, or null if the wake word was not said. Tolerates small mishearings. */
    private fun afterWakeWord(text: String): String? {
        val words = Tr.tokens(text)
        val wake = Tr.tokens(prefs.wakeWord).map { Tr.ascii(it) }
        if (wake.isEmpty() || words.size < wake.size) return null
        for (i in 0..words.size - wake.size) {
            val ok = wake.indices.all { k ->
                val w = Tr.ascii(words[i + k])
                w == wake[k] || (wake[k].length >= 5 && Tr.similarity(w, wake[k]) >= 0.75)
            }
            if (ok) return words.drop(i + wake.size).joinToString(" ")
        }
        return null
    }

    private fun armCommand(beep: Boolean = true) {
        commandUntil = SystemClock.elapsedRealtime() + COMMAND_WINDOW_MS
        if (beep) beep()
        Bus.status("Komutu söyleyin…")
        main.postDelayed({
            if (commandUntil != 0L && SystemClock.elapsedRealtime() >= commandUntil) {
                commandUntil = 0
                restoreStatus()
            }
        }, COMMAND_WINDOW_MS + 100)
    }

    private fun restoreStatus() {
        Bus.status(if (prefs.noWakeWord) "Dinliyor (her cümle komut)" else "Dinliyor: \"${prefs.wakeWord} …\"")
    }

    private fun beep() {
        tone?.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
    }

    // --- Foreground notification ---

    private fun goForeground(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Asistan", NotificationManager.IMPORTANCE_LOW))
        val n = notification(text)
        if (Build.VERSION.SDK_INT >= 30) {
            var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            }
            startForeground(NOTIFICATION_ID, n, type)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(text))
    }

    private fun notification(text: String): Notification {
        fun action(a: String, code: Int) = PendingIntent.getService(
            this, code, Intent(this, AssistantService::class.java).setAction(a),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val icon = Icon.createWithResource(this, R.drawable.ic_mic)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_mic)
            .setContentTitle("Asistan")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(icon, "Dinle", action(ACTION_LISTEN, 1)).build())
            .addAction(Notification.Action.Builder(icon, "Kapat", action(ACTION_STOP, 2)).build())
            .build()
    }
}
