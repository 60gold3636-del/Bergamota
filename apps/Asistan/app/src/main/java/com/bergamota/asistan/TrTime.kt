package com.bergamota.asistan

/** A time the user asked for: a clock time (24 h) or "N seconds from now". */
sealed class When {
    data class At(val hour: Int, val minute: Int, val tomorrow: Boolean) : When()
    data class After(val seconds: Int) : When()
}

/** Spoken Turkish numbers, durations and clock times ("yarın sabah sekiz buçukta", "dokuza çeyrek var"). */
object TrTime {
    private val units = linkedMapOf(
        "sıfır" to 0, "bir" to 1, "iki" to 2, "üç" to 3, "dört" to 4, "dörd" to 4,
        "beş" to 5, "altı" to 6, "yedi" to 7, "sekiz" to 8, "dokuz" to 9
    )
    private val tens = linkedMapOf(
        "on" to 10, "yirmi" to 20, "otuz" to 30, "kırk" to 40, "elli" to 50,
        "altmış" to 60, "yetmiş" to 70, "seksen" to 80, "doksan" to 90
    )
    private val numSuffixes = setOf(
        "", "a", "e", "ya", "ye", "ı", "i", "u", "ü", "yı", "yi", "yu", "yü",
        "da", "de", "ta", "te", "dan", "den", "tan", "ten", "na", "ne", "nda", "nde"
    )
    private val digitsWithSuffix = Regex("^(\\d{1,4})([a-zçğıöşü]*)$")
    private val clock = Regex("^(\\d{1,2})[:.](\\d{2})")

    private data class Word(val value: Int, val isTens: Boolean, val suffix: String)

    private fun word(tok: String): Word? {
        digitsWithSuffix.find(tok)?.let { m ->
            if (m.groupValues[2] in numSuffixes) return Word(m.groupValues[1].toInt(), false, m.groupValues[2])
        }
        for ((w, v) in tens) if (tok.startsWith(w) && tok.substring(w.length) in numSuffixes) return Word(v, true, tok.substring(w.length))
        for ((w, v) in units) if (tok.startsWith(w) && tok.substring(w.length) in numSuffixes) return Word(v, false, tok.substring(w.length))
        return null
    }

    /** Number starting at t[i]: (value, tokens consumed). "kırk beş" -> (45, 2). */
    fun number(t: List<String>, i: Int): Pair<Int, Int>? {
        if (i !in t.indices) return null
        val w = word(t[i]) ?: return null
        if (w.isTens && w.suffix.isEmpty() && i + 1 < t.size && t[i + 1].toIntOrNull() == null) {
            val u = word(t[i + 1])
            if (u != null && !u.isTens && u.value in 1..9) return (w.value + u.value) to 2
        }
        return w.value to 1
    }

    private fun unitSeconds(tok: String): Int? = when {
        tok.startsWith("saniye") -> 1
        tok.startsWith("dakika") || tok == "dk" -> 60
        tok.startsWith("saat") -> 3600
        else -> null
    }

    private fun isHalf(tok: String) = tok.startsWith("buçu")

    /** "bir buçuk saat", "yarım saat", "iki saat on dakika", "kırk beş saniye" -> seconds. */
    fun duration(t: List<String>): Int? {
        var total = 0.0
        var found = false
        var i = 0
        while (i < t.size) {
            if ((t[i] == "yarım" || t[i] == "çeyrek") && i + 1 < t.size) {
                val u = unitSeconds(t[i + 1])
                if (u != null) {
                    total += if (t[i] == "yarım") u / 2.0 else u / 4.0
                    found = true; i += 2; continue
                }
            }
            val n = number(t, i)
            if (n != null) {
                var j = i + n.second
                var v = n.first.toDouble()
                if (j < t.size && isHalf(t[j])) { v += 0.5; j++ }
                val u = if (j < t.size) unitSeconds(t[j]) else null
                if (u != null) {
                    total += v * u
                    found = true
                    i = j + 1
                    if (i < t.size && isHalf(t[i])) { total += u / 2.0; i++ }
                    continue
                }
            }
            i++
        }
        return if (found && total >= 1) total.toInt() else null
    }

    private enum class Period { MORNING, NOON, AFTERNOON, NIGHT }

    /** Clock time or relative time in an alarm request. */
    fun parse(text: String): When? {
        val t = Tr.tokens(text)
        val afternoonWords = t.any { it.startsWith("öğleden") || it.startsWith("öğlenden") }
        if (!afternoonWords && t.any { it.startsWith("sonra") }) duration(t)?.let { return When.After(it) }

        val tomorrow = t.any { it.startsWith("yarın") }
        val period = when {
            afternoonWords || t.any { it.startsWith("akşam") || it.startsWith("aksam") } -> Period.AFTERNOON
            t.any { it.startsWith("sabah") } -> Period.MORNING
            t.any { it.startsWith("gece") } -> Period.NIGHT
            t.any { it.startsWith("öğle") } -> Period.NOON
            else -> null
        }

        for (tok in t) clock.find(tok)?.let { m ->
            val h = m.groupValues[1].toInt(); val min = m.groupValues[2].toInt()
            if (h in 0..24 && min in 0..59) return When.At(resolve(h, period), min, tomorrow)
        }

        for (i in t.indices) {
            val n = number(t, i) ?: continue
            if (n.first !in 0..24) continue
            // "bir alarm kur" is "an alarm", not one o'clock.
            if (t[i] == "bir" && !contextAllowsOne(t, i)) continue
            var j = i + n.second
            if (j < t.size && unitSeconds(t[j]) != null) continue // a duration, not a clock time
            var hour = n.first
            var minute = 0
            if (j < t.size) {
                val nx = t[j]
                if (isHalf(nx)) {
                    minute = 30
                } else if (nx == "çeyrek") {
                    if (j + 1 < t.size && t[j + 1] == "var") { hour -= 1; minute = 45 } else minute = 15
                } else {
                    val m = number(t, j)
                    if (m != null && m.first in 0..59) {
                        val k = j + m.second
                        minute = if (k < t.size && t[k] == "var") { hour -= 1; 60 - m.first } else m.first
                    }
                }
            }
            if (hour < 0) hour += 12
            return When.At(resolve(hour, period), minute, tomorrow)
        }
        return null
    }

    private fun contextAllowsOne(t: List<String>, i: Int): Boolean {
        val prev = t.getOrNull(i - 1) ?: ""
        val next = t.getOrNull(i + 1) ?: ""
        return prev == "saat" || prev.startsWith("sabah") || prev.startsWith("gece") ||
            prev.startsWith("akşam") || prev.startsWith("öğle") || prev.startsWith("sonra") ||
            isHalf(next) || next == "çeyrek" || number(t, i + 1) != null
    }

    /**
     * 12 h spoken hour -> 24 h. Without a period word: 5-11 is morning, 12 noon, 1-4 afternoon
     * (what people mean by "üçte", "yedide uyandır").
     */
    private fun resolve(h: Int, period: Period?): Int {
        val hr = h % 24
        if (hr > 12) return hr
        return when (period) {
            Period.MORNING -> if (hr == 12) 0 else hr
            Period.AFTERNOON -> if (hr in 1..11) hr + 12 else hr
            Period.NIGHT -> when (hr) { in 6..11 -> hr + 12; 12 -> 0; else -> hr }
            Period.NOON -> if (hr in 1..6) hr + 12 else hr
            null -> if (hr in 1..4) hr + 12 else hr
        }
    }

    fun spokenClock(h: Int, m: Int): String = when {
        m == 0 -> "$h"
        m == 30 -> "$h buçuk"
        m < 10 -> "$h sıfır $m"
        else -> "$h $m"
    }

    fun spokenDuration(seconds: Int): String {
        val h = seconds / 3600; val m = (seconds % 3600) / 60; val s = seconds % 60
        val parts = mutableListOf<String>()
        if (h > 0) parts += "$h saat"
        if (m > 0) parts += "$m dakika"
        if (s > 0) parts += "$s saniye"
        return parts.joinToString(" ")
    }
}
