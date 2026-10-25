package com.bergamota.asistan

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.AlarmClock
import android.telecom.TelecomManager
import android.view.KeyEvent
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.concurrent.Executors

/** Executes parsed commands and answers by voice. */
class Assistant(private val ctx: Context, private val speaker: Speaker) {
    private val prefs = Prefs(ctx)
    private val contacts = ContactFinder(ctx, prefs)
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    /** Returns false when the sentence was not understood. */
    fun handle(text: String, quietIfUnknown: Boolean = false): Boolean = handle(listOf(text), quietIfUnknown)

    /**
     * [alternatives] are the recognizer's guesses, best first. The first one that is a command wins;
     * for a call, the first guess whose name is actually in the phone book.
     */
    fun handle(alternatives: List<String>, quietIfUnknown: Boolean = false): Boolean {
        val cmds = alternatives.mapNotNull { CommandParser.parse(it) }
        val known = cmds.filter { it !is Command.Unknown }
        if (known.isEmpty()) {
            if (cmds.isNotEmpty()) {
                Bus.log("Anlaşılmadı: ${alternatives.first()}")
                if (!quietIfUnknown) speaker.say("Anlamadım.")
            }
            return false
        }
        val cmd = known.first()
        Bus.log("Komut: $cmd")
        try {
            if (cmd is Command.Call) {
                val calls = known.filterIsInstance<Command.Call>()
                val hit = calls.firstNotNullOfOrNull { c -> contacts.find(c.who) }
                if (hit != null) {
                    // Dial at once; the confirmation is spoken while the call starts.
                    dial(hit.number)
                    speaker.say("${hit.name} aranıyor.")
                } else {
                    val hint = if (ctx.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED)
                        " Rehber izni verilmemiş." else ""
                    speaker.say("${cmd.who} rehberde bulunamadı.$hint")
                }
            } else {
                run(cmd)
            }
        } catch (e: Exception) {
            Bus.log("Hata: $e")
            speaker.say("Bunu yaparken bir hata oldu.")
        }
        return true
    }

    fun preloadContacts() = contacts.preload()

    fun contactCount() = contacts.count()

    fun contactNames() = contacts.names()

    private fun run(cmd: Command) {
        when (cmd) {
            is Command.Call -> {}
            is Command.Alarm -> alarm(cmd.time)
            is Command.Timer -> timer(cmd.seconds)
            is Command.Weather -> {
                val saved = prefs.city
                io.execute {
                    val r = Weather.report(ctx, cmd.city, cmd.tomorrow, saved)
                    main.post { speaker.say(r) }
                }
            }
            Command.TellTime -> {
                val c = Calendar.getInstance()
                speaker.say("Saat " + TrTime.spokenClock(c[Calendar.HOUR_OF_DAY], c[Calendar.MINUTE]))
            }
            Command.TellDate -> speaker.say("Bugün " + SimpleDateFormat("d MMMM yyyy, EEEE", Tr.LOCALE).format(Date()))
            Command.Battery -> {
                val bm = ctx.getSystemService(BatteryManager::class.java)
                val pct = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                speaker.say("Şarj yüzde $pct" + if (bm.isCharging) ", şarj oluyor." else ".")
            }
            is Command.Torch -> torch(cmd.on)
            is Command.OpenApp -> openApp(cmd.name)
            is Command.Volume -> volume(cmd.action)
            is Command.Media -> media(cmd.action)
            is Command.Navigate -> {
                val nav = Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=" + Uri.encode(cmd.dest)))
                if (!start(nav, quiet = true)) start(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" + Uri.encode(cmd.dest))))
                speaker.say("${cmd.dest} için yol tarifi açılıyor.")
            }
            Command.Cancel -> speaker.stop()
            is Command.Unknown -> {}
        }
    }

    private fun dial(number: String) {
        val uri = Uri.fromParts("tel", number, null)
        if (ctx.checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED) {
            try {
                // placeCall works from the background service; an ACTION_CALL activity start may be blocked.
                ctx.getSystemService(TelecomManager::class.java).placeCall(uri, Bundle())
                return
            } catch (e: Exception) {
                Bus.log("placeCall: $e")
            }
        }
        start(Intent(Intent.ACTION_DIAL, uri))
    }

    private fun alarm(w: When?) {
        if (w == null) {
            speaker.say("Saati anlayamadım. Örneğin: yarın sabah sekize alarm kur.")
            return
        }
        val (h, m) = when (w) {
            is When.At -> w.hour to w.minute
            is When.After -> Calendar.getInstance().apply { add(Calendar.SECOND, w.seconds) }
                .let { it[Calendar.HOUR_OF_DAY] to it[Calendar.MINUTE] }
        }
        val i = Intent(AlarmClock.ACTION_SET_ALARM)
            .putExtra(AlarmClock.EXTRA_HOUR, h)
            .putExtra(AlarmClock.EXTRA_MINUTES, m)
            .putExtra(AlarmClock.EXTRA_MESSAGE, "Asistan")
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (start(i)) {
            val day = if (w is When.At && w.tomorrow) "Yarın " else ""
            speaker.say("${day}saat ${TrTime.spokenClock(h, m)} için alarm kuruldu.")
        }
    }

    private fun timer(seconds: Int?) {
        if (seconds == null || seconds > 86400) {
            speaker.say("Süreyi anlayamadım. Örneğin: beş dakikalık zamanlayıcı kur.")
            return
        }
        val i = Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            .putExtra(AlarmClock.EXTRA_MESSAGE, "Asistan")
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
        if (start(i)) speaker.say("${TrTime.spokenDuration(seconds)} zamanlayıcı kuruldu.")
    }

    private fun torch(on: Boolean) {
        val cm = ctx.getSystemService(CameraManager::class.java)
        val id = cm.cameraIdList.firstOrNull {
            cm.getCameraCharacteristics(it).get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        }
        if (id == null) { speaker.say("Bu telefonda fener yok."); return }
        cm.setTorchMode(id, on)
    }

    private fun openApp(name: String) {
        val pm = ctx.packageManager
        val apps = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
        val variants = Tr.stemVariants(name).map { Tr.phon(it) }
        var bestLabel = ""; var bestPkg = ""; var bestScore = 0.0
        for (a in apps) {
            val label = a.loadLabel(pm).toString()
            val key = Tr.phon(label)
            val keyTokens = key.split(' ')
            for (v in variants) {
                var sc = Tr.similarity(v, key)
                if (keyTokens.size > 1) sc = maxOf(sc, keyTokens.maxOf { Tr.similarity(v, it) } * 0.95)
                if (sc > bestScore) { bestScore = sc; bestLabel = label; bestPkg = a.activityInfo.packageName }
            }
        }
        if (bestScore < 0.6) { speaker.say("$name diye bir uygulama bulamadım."); return }
        val launch = pm.getLaunchIntentForPackage(bestPkg) ?: return
        if (start(launch)) speaker.say("$bestLabel açılıyor.")
    }

    private fun volume(action: String) {
        val am = ctx.getSystemService(AudioManager::class.java)
        val s = AudioManager.STREAM_MUSIC
        when (action) {
            "up" -> repeat(2) { am.adjustStreamVolume(s, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI) }
            "down" -> repeat(2) { am.adjustStreamVolume(s, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI) }
            "mute" -> am.adjustStreamVolume(s, AudioManager.ADJUST_MUTE, AudioManager.FLAG_SHOW_UI)
            "max" -> am.setStreamVolume(s, am.getStreamMaxVolume(s), AudioManager.FLAG_SHOW_UI)
        }
    }

    private fun media(action: String) {
        val am = ctx.getSystemService(AudioManager::class.java)
        val code = when (action) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            else -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
        }
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
    }

    private fun start(i: Intent, quiet: Boolean = false): Boolean = try {
        ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        if (!quiet) speaker.say("Bunu yapabilecek bir uygulama bulunamadı.")
        false
    } catch (e: SecurityException) {
        if (!quiet) speaker.say("Bunun için izin gerekiyor.")
        Bus.log("startActivity: $e")
        false
    }

    fun shutdown() = io.shutdown()
}
