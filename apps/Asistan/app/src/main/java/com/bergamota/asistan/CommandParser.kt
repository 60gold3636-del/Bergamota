package com.bergamota.asistan

sealed class Command {
    data class Call(val who: String) : Command()
    data class Alarm(val time: When?) : Command()
    data class Timer(val seconds: Int?) : Command()
    data class Weather(val city: String?, val tomorrow: Boolean) : Command()
    data object TellTime : Command()
    data object TellDate : Command()
    data object Battery : Command()
    data class Torch(val on: Boolean) : Command()
    data class OpenApp(val name: String) : Command()
    data class Volume(val action: String) : Command() // up, down, mute, max
    data class Media(val action: String) : Command() // play, pause, next, previous
    data class Navigate(val dest: String) : Command()
    data object Cancel : Command()
    data class Unknown(val text: String) : Command()
}

/** Turns a recognised Turkish sentence into a [Command]. Keyword based, order matters. */
object CommandParser {
    private val filler = setOf(
        "lütfen", "acaba", "bana", "hemen", "şimdi", "şu", "bi", "için", "benim",
        "mısın", "misin", "musun", "müsün", "mı", "mi", "mu", "mü", "hadi"
    )
    private val callWords = setOf("ara", "arar", "arayın", "arasana", "arayabilir", "aramak", "çaldır")
    private val openWords = setOf("aç", "açar", "açsana", "başlat", "çalıştır", "açın")
    private val appNoise = setOf(
        "uygulamasını", "uygulaması", "uygulamayı", "uygulama", "programını", "programı"
    )
    private val callNoise = setOf("telefonla", "telefondan", "bir", "beni", "numarasını", "numarayı")
    private val notCities = setOf("bugün", "yarın", "burada", "orada", "şurada", "dışarıda", "dışarda", "yarında")

    fun parse(raw: String): Command? {
        val t = Tr.tokens(raw).filter { it !in filler }
        if (t.isEmpty()) return null
        val s = t.joinToString(" ")
        fun has(vararg w: String) = w.any { it in t }
        fun pre(vararg p: String) = t.any { tok -> p.any { tok.startsWith(it) } }

        if (pre("alarm", "uyandır")) return Command.Alarm(TrTime.parse(s))
        if (has("saat") && pre("kaç")) return Command.TellTime

        if (pre("zamanlayıcı", "sayaç") || s.contains("geri say") ||
            (pre("sonra") && (s.contains("haber ver") || pre("hatırlat", "uyar")))
        ) return Command.Timer(TrTime.duration(t))

        val weatherWord = t.indexOfFirst { it == "hava" || it == "havalar" || it == "havada" || it.startsWith("havanın") }
        if ((weatherWord >= 0 && (pre("nasıl", "durum", "derece", "sıcak", "soğuk", "yağ") || t.size <= 3)) ||
            pre("sıcaklık") || (pre("yağmur", "kar") && pre("yağ")) || (pre("kaç") && pre("derece"))
        ) {
            var city: String? = null
            val before = t.getOrNull(weatherWord - 1)
            if (before != null && before !in notCities && Regex(".{3,}(da|de|ta|te)$").matches(before)) {
                city = before.dropLast(2)
            }
            return Command.Weather(city, pre("yarın"))
        }

        if (pre("fener", "flaş", "flas", "ışığ", "ışık")) return Command.Torch(!pre("kapat", "söndür", "kapa"))
        if (pre("şarj", "batarya") || has("pil", "pilim", "pili")) return Command.Battery
        if (s.contains("günlerden") || pre("tarih") || s.contains("ayın kaç") || s.contains("hangi gün")) return Command.TellDate

        if (has("ses", "sesi", "sesini", "sesler", "sessize", "sessiz")) {
            return Command.Volume(
                when {
                    pre("kıs", "azalt", "düşür", "alçalt") -> "down"
                    has("sessiz", "sessize") || pre("kapat", "kapa") -> "mute"
                    s.contains("son ses") || pre("sonuna", "en yüksek", "full") -> "max"
                    else -> "up"
                }
            )
        }

        if (pre("müzi", "şarkı", "parça", "medya") || has("durdur", "duraklat", "sonraki", "önceki")) {
            when {
                pre("durdur", "duraklat", "kapat") -> return Command.Media("pause")
                pre("sonraki", "atla") || has("geç") -> return Command.Media("next")
                pre("önceki") -> return Command.Media("previous")
                pre("devam", "çal", "başlat", "aç") -> return Command.Media("play")
            }
        }

        val navIdx = t.indexOfFirst { it == "yol" || it.startsWith("götür") || it.startsWith("navigasyon") }
        if (navIdx > 0) {
            val dest = t.subList(0, navIdx).filter { it != "beni" }
            if (dest.isNotEmpty()) {
                val d = dest.joinToString(" ")
                return Command.Navigate(dropDative(d))
            }
        }

        val callIdx = t.indexOfLast { it in callWords }
        val telIdx = t.indexOfFirst { it == "telefon" }
        if (callIdx >= 0 || (telIdx >= 0 && t.getOrNull(telIdx + 1) == "et")) {
            val words = when {
                callIdx > 0 -> t.subList(0, callIdx)
                callIdx == 0 -> t.subList(1, t.size)
                else -> t.subList(0, telIdx)
            }.filter { it !in callNoise }
            if (words.isNotEmpty()) return Command.Call(words.joinToString(" "))
        }

        if (has("iptal", "vazgeç", "boşver", "dur", "sus", "kes")) return Command.Cancel

        val last = t.last()
        if (last in openWords && t.size >= 2) {
            val name = t.dropLast(1).filter { it !in appNoise }
            if (name.isNotEmpty()) return Command.OpenApp(name.joinToString(" "))
        }

        return Command.Unknown(s)
    }

    /** "ankaraya" -> "ankara", "kadıköye" -> "kadıköy" (the y belongs to the stem after o/ö/u/ü). */
    private fun dropDative(phrase: String): String {
        val vowels = "aeıi"
        return when {
            phrase.length > 4 && (phrase.endsWith("ya") || phrase.endsWith("ye")) && phrase[phrase.length - 3] in vowels -> phrase.dropLast(2)
            phrase.length > 3 && (phrase.endsWith("a") || phrase.endsWith("e")) -> phrase.dropLast(1)
            else -> phrase
        }
    }
}
