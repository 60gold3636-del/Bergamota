package com.bergamota.asistan

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** Turkish text-to-speech. [onBusy] lets the listener pause the microphone while we talk. */
class Speaker(ctx: Context, private val onBusy: (Boolean) -> Unit) : TextToSpeech.OnInitListener {
    private val main = Handler(Looper.getMainLooper())
    private val tts = TextToSpeech(ctx.applicationContext, this)
    private var ready = false
    private val pending = mutableListOf<Pair<String, (() -> Unit)?>>()
    private val callbacks = ConcurrentHashMap<String, () -> Unit>()
    private val ids = AtomicInteger()

    override fun onInit(status: Int) {
        if (status != TextToSpeech.SUCCESS) {
            Bus.log("Sesli yanıt (TTS) başlatılamadı")
            pending.forEach { it.second?.invoke() }
            pending.clear()
            return
        }
        val r = tts.setLanguage(Tr.LOCALE)
        if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED) {
            Bus.log("Türkçe ses paketi yok: Ayarlar > Metin okuma çıkışı'ndan Türkçe'yi indirin")
        }
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(id: String) { main.post { onBusy(true) } }
            override fun onDone(id: String) = finished(id)
            @Deprecated("Deprecated in Java")
            override fun onError(id: String) = finished(id)
            override fun onError(id: String, errorCode: Int) = finished(id)
        })
        ready = true
        pending.forEach { say(it.first, it.second) }
        pending.clear()
    }

    private fun finished(id: String) {
        main.post {
            if (!tts.isSpeaking) onBusy(false)
            callbacks.remove(id)?.invoke()
        }
    }

    fun say(text: String, then: (() -> Unit)? = null) {
        Bus.log("Asistan: $text")
        if (!ready) { pending += text to then; return }
        val id = "u" + ids.incrementAndGet()
        if (then != null) callbacks[id] = then
        if (tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, id) != TextToSpeech.SUCCESS) {
            callbacks.remove(id)?.invoke()
        }
    }

    fun stop() {
        tts.stop()
        onBusy(false)
    }

    fun shutdown() {
        tts.stop()
        tts.shutdown()
    }
}
