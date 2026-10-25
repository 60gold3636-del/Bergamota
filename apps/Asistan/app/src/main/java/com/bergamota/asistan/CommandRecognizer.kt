package com.bergamota.asistan

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/**
 * One command through the phone's own recognizer (Google's on-device Turkish model when installed).
 * It knows far more words than the small Vosk model and is told every contact name in advance.
 * Must be used on the main thread.
 */
class CommandRecognizer(
    private val ctx: Context,
    private val onResult: (List<String>) -> Unit,
    private val onEnd: () -> Unit
) {
    private var sr: SpeechRecognizer? = null

    private fun onDevice() = Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)

    fun available(): Boolean = onDevice() || SpeechRecognizer.isRecognitionAvailable(ctx)

    val busy: Boolean get() = sr != null

    private fun intent(bias: List<String>): Intent {
        val i = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "tr-TR")
            .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
            .putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, ctx.packageName)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 700L)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 500L)
        if (Build.VERSION.SDK_INT >= 33 && bias.isNotEmpty()) {
            i.putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(bias.take(1000)))
        }
        return i
    }

    fun start(bias: List<String>) {
        cancel()
        val r = if (onDevice()) SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
        else SpeechRecognizer.createSpeechRecognizer(ctx)
        sr = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
                finish()
                if (list.isNotEmpty()) onResult(list)
            }

            override fun onError(error: Int) {
                if (error != SpeechRecognizer.ERROR_NO_MATCH && error != SpeechRecognizer.ERROR_SPEECH_TIMEOUT) {
                    Bus.log("Tanıyıcı hatası $error" + if (error == 13) " (Türkçe çevrimdışı paket yok?)" else "")
                }
                finish()
            }

            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        r.startListening(intent(bias))
    }

    private fun finish() {
        val r = sr ?: return
        sr = null
        r.destroy()
        onEnd()
    }

    fun cancel() {
        sr?.destroy()
        sr = null
    }

    /** Asks Google's on-device recognizer to download the Turkish model (Android 13+). */
    fun downloadTurkish(): Boolean {
        if (Build.VERSION.SDK_INT < 33 || !onDevice()) return false
        val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
        // Kept alive: destroying it right away can cancel the request.
        r.triggerModelDownload(intent(emptyList()))
        return true
    }
}
