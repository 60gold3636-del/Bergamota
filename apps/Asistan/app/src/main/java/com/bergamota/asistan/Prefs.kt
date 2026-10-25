package com.bergamota.asistan

import android.content.Context
import org.json.JSONObject

data class Contact(val name: String, val number: String)

class Prefs(ctx: Context) {
    private val sp = ctx.applicationContext.getSharedPreferences("asistan", Context.MODE_PRIVATE)

    var wakeWord: String
        get() = sp.getString("wake", "asistan")!!.ifBlank { "asistan" }
        set(v) = sp.edit().putString("wake", v.trim()).apply()

    /** Treat every sentence as a command (no wake word). */
    var noWakeWord: Boolean
        get() = sp.getBoolean("noWake", false)
        set(v) = sp.edit().putBoolean("noWake", v).apply()

    /** Used for the weather when the location is unknown. */
    var city: String
        get() = sp.getString("city", "")!!
        set(v) = sp.edit().putString("city", v.trim()).apply()

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
