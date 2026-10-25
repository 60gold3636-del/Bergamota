package com.bergamota.asistan

import java.util.Locale

/** Turkish text helpers: normalisation, fuzzy matching and suffix stripping. */
object Tr {
    val LOCALE: Locale = Locale("tr", "TR")
    private val nonWord = Regex("[^\\p{L}\\p{N}:]+")

    /** "Ahmet'i ARA!" -> "ahmeti ara" */
    fun norm(s: String): String =
        s.replace("'", "").replace("’", "").lowercase(LOCALE).replace(nonWord, " ").trim()

    fun tokens(s: String): List<String> = norm(s).split(' ').filter { it.isNotEmpty() }

    /** Folds Turkish letters so "Şükrü" and "sukru" compare equal. */
    fun ascii(s: String): String {
        val sb = StringBuilder()
        for (c in norm(s)) {
            sb.append(
                when (c) {
                    'ç' -> 'c'; 'ğ' -> 'g'; 'ı' -> 'i'; 'ö' -> 'o'; 'ş' -> 's'; 'ü' -> 'u'
                    'â' -> 'a'; 'î' -> 'i'; 'û' -> 'u'
                    else -> c
                }
            )
        }
        return sb.toString()
    }

    /** Rough phonetic key so "vatsap" finds "WhatsApp" and "yutub" finds "YouTube". */
    fun phon(s: String): String {
        var k = ascii(s).replace("ph", "f").replace("th", "t").replace("ou", "u").replace("oo", "u")
            .replace("ee", "i").replace('w', 'v').replace('q', 'k').replace("x", "ks")
        val sb = StringBuilder()
        for (c in k) if (sb.isEmpty() || sb.last() != c || c == ' ') sb.append(c)
        k = sb.toString()
        if (k.length > 4 && k.endsWith("e")) k = k.dropLast(1)
        return k
    }

    fun levenshtein(a: String, b: String): Int {
        if (a == b) return 0
        if (a.isEmpty()) return b.length
        if (b.isEmpty()) return a.length
        var prev = IntArray(b.length + 1) { it }
        var cur = IntArray(b.length + 1)
        for (i in 1..a.length) {
            cur[0] = i
            for (j in 1..b.length) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                cur[j] = minOf(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            }
            val t = prev; prev = cur; cur = t
        }
        return prev[b.length]
    }

    fun similarity(a: String, b: String): Double {
        if (a.isEmpty() && b.isEmpty()) return 1.0
        return 1.0 - levenshtein(a, b).toDouble() / maxOf(a.length, b.length)
    }

    private val caseSuffixes = listOf(
        "nın", "nin", "nun", "nün", "yla", "yle", "dan", "den", "tan", "ten",
        "ya", "ye", "yı", "yi", "yu", "yü", "nı", "ni", "nu", "nü", "na", "ne",
        "da", "de", "ta", "te", "a", "e", "ı", "i", "u", "ü"
    )

    /** "eşimi" -> [eşimi, eşim]; "ahmet yılmazı" -> [ahmet yılmazı, ahmet yılmaz]. Only the last word is stemmed. */
    fun stemVariants(phrase: String): List<String> {
        val t = norm(phrase)
        val out = linkedSetOf(t)
        val cut = t.lastIndexOf(' ')
        val head = if (cut >= 0) t.substring(0, cut + 1) else ""
        val last = t.substring(cut + 1)
        for (suf in caseSuffixes) {
            if (last.length > suf.length + 2 && last.endsWith(suf)) out.add(head + last.dropLast(suf.length))
        }
        return out.toList()
    }
}
