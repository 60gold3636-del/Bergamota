package com.bergamota.asistan

import android.os.Handler
import android.os.Looper
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Status and log lines from the service to whatever screen is open. */
object Bus {
    interface Listener {
        fun onStatus(status: String)
        fun onLog(text: String)
    }

    private val main = Handler(Looper.getMainLooper())
    private val lines = ArrayDeque<String>()
    private val clock = SimpleDateFormat("HH:mm:ss", Locale.US)

    var listener: Listener? = null

    @Volatile
    var status = "Kapalı"
        private set

    fun status(s: String) {
        status = s
        main.post { listener?.onStatus(s) }
    }

    fun log(s: String) {
        synchronized(lines) {
            lines.addFirst(clock.format(Date()) + "  " + s)
            while (lines.size > 60) lines.removeLast()
        }
        main.post { listener?.onLog(logText()) }
    }

    fun logText(): String = synchronized(lines) { lines.joinToString("\n") }
}
