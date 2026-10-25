package com.bergamota.asistan

import android.content.Context
import org.json.JSONObject

data class Contact(val name: String, val number: String)

class Prefs(ctx: Context) {
    private val sp = ctx.applicationContext.getSharedPreferences("asistan", Context.MODE_PRIVATE)

    var wakeWord: String
        get() = sp.getString("wake", "asistan")!!.ifBlank { "asistan" }
        set(v) = sp.edit().putString("wake", v.trim()).apply()

    /** Switched on by the user: the service runs all the time and comes back after a reboot. */
    var enabled: Boolean
        get() = sp.getBoolean("enabled", false)
        set(v) = sp.edit().putBoolean("enabled", v).apply()

    /** Treat every sentence as a command (no wake word). */
    var noWakeWord: Boolean
        get() = sp.getBoolean("noWake", false)
        set(v) = sp.edit().putBoolean("noWake", v).apply()

    /** Used for the weather when the location is unknown. */
    var city: String
        get() = sp.getString("city", "")!!
        set(v) = sp.edit().putString("city", v.trim()).apply()

    /** Text-to-speech engine package ("" = system default), voice name ("" = automatic), speed and pitch. */
    var ttsEngine: String
        get() = sp.getString("ttsEngine", "")!!
        set(v) = sp.edit().putString("ttsEngine", v).apply()

    var ttsVoice: String
        get() = sp.getString("ttsVoice", "")!!
        set(v) = sp.edit().putString("ttsVoice", v).apply()

    var ttsRate: Float
        get() = sp.getFloat("ttsRate", 1.15f)
        set(v) = sp.edit().putFloat("ttsRate", v).apply()

    var ttsPitch: Float
        get() = sp.getFloat("ttsPitch", 1.0f)
        set(v) = sp.edit().putFloat("ttsPitch", v).apply()

    /** After the wake word, let the phone's own (Google) on-device recognizer hear the command. */
    var systemRecognizer: Boolean
        get() = sp.getBoolean("systemRecognizer", true)
        set(v) = sp.edit().putBoolean("systemRecognizer", v).apply()

    private fun aliasJson() = JSONObject(sp.getString("aliases", "{}")!!)

    /** Spoken nicknames ("eşim", "annem") -> contact. Key is [Tr.ascii] of the nickname. */
    fun aliases(): List<Triple<String, String, Contact>> {
        val j = aliasJson()
        return j.keys().asSequence().map { k ->
            val o = j.getJSONObject(k)
            Triple(k, o.getString("label"), Contact(o.getString("name"), o.getString("number")))
        }.toList()
    }

    fun putAlias(label: String, c: Contact) {
        val j = aliasJson()
        j.put(Tr.ascii(label), JSONObject().put("label", Tr.norm(label)).put("name", c.name).put("number", c.number))
        sp.edit().putString("aliases", j.toString()).apply()
    }

    fun removeAlias(label: String): Boolean {
        val j = aliasJson()
        if (j.remove(Tr.ascii(label)) == null) return false
        sp.edit().putString("aliases", j.toString()).apply()
        return true
    }
}
