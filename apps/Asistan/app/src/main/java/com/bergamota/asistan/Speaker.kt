package com.bergamota.asistan

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Turkish text-to-speech with the engine, voice, speed and pitch chosen in the app.
 * [onBusy] lets the listener pause the microphone while we talk.
 */
class Speaker(
    ctx: Context,
    private val onBusy: (Boolean) -> Unit,
    private val onReady: (() -> Unit)? = null
) {
    private val app = ctx.applicationContext
    private val prefs = Prefs(app)
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var generation = 0
    private var ready = false
    private val pending = mutableListOf<Pair<String, (() -> Unit)?>>()
    private val callbacks = ConcurrentHashMap<String, () -> Unit>()
    private val ids = AtomicInteger()

    init {
        create()
    }

    private fun create() {
        ready = false
        val gen = ++generation
        val engine = prefs.ttsEngine.ifBlank { null }
        tts = TextToSpeech(app, { status -> if (gen == generation) onInit(status) }, engine)
    }

    private fun onInit(status: Int) {
        val t = tts ?: return
        if (status != TextToSpeech.SUCCESS) {
            Bus.log("Sesli yanıt (TTS) başlatılamadı")
            pending.forEach { it.second?.invoke() }
            pending.clear()
            onReady?.invoke()
            return
        }
        val r = t.setLanguage(Tr.LOCALE)
        if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED) {
            Bus.log("Bu ses motorunda Türkçe yok: uygulamadan \"Türkçe ses verisini indir\"e basın")
        }
        t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String) { main.post { onBusy(true) } }
            override fun onDone(id: String) = finished(id)
            @Deprecated("Deprecated in Java")
            override fun onError(id: String) = finished(id)
            override fun onError(id: String, errorCode: Int) = finished(id)
        })
        ready = true
        applyTuning()
        pending.forEach { say(it.first, it.second) }
        pending.clear()
        onReady?.invoke()
    }

    /** Re-reads voice, speed and pitch from the settings. */
    fun applyTuning() {
        val t = tts ?: return
        if (!ready) return
        val name = prefs.ttsVoice
        if (name.isNotEmpty()) voices().firstOrNull { it.name == name }?.let { t.voice = it }
        else t.setLanguage(Tr.LOCALE)
        t.setSpeechRate(prefs.ttsRate)
        t.setPitch(prefs.ttsPitch)
    }

    /** Switches to the engine chosen in the settings. */
    fun reload() {
        tts?.stop()
        tts?.shutdown()
        create()
    }

    fun engines(): List<TextToSpeech.EngineInfo> = try { tts?.engines } catch (e: Exception) { null } ?: emptyList()

    fun voices(): List<Voice> = try {
        tts?.voices?.filter { it.locale.language == "tr" }?.sortedBy { it.name }
    } catch (e: Exception) {
        null
    } ?: emptyList()

    private fun finished(id: String) {
        main.post {
            if (tts?.isSpeaking != true) onBusy(false)
            callbacks.remove(id)?.invoke()
        }
    }

    fun say(text: String, then: (() -> Unit)? = null) {
        Bus.log("Asistan: $text")
        val t = tts
        if (!ready || t == null) { pending += text to then; return }
        val id = "u" + ids.incrementAndGet()
        if (then != null) callbacks[id] = then
        if (t.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) != TextToSpeech.SUCCESS) {
            callbacks.remove(id)?.invoke()
        }
    }

    fun stop() {
        tts?.stop()
        onBusy(false)
    }

    fun shutdown() {
        generation++
        tts?.stop()
        tts?.shutdown()
        tts = null
    }
}
