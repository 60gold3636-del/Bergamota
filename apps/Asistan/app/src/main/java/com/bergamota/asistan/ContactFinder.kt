package com.bergamota.asistan

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Phone
import kotlin.math.max

/**
 * Finds the contact meant by a spoken name. The whole phone book is searched automatically
 * (cached, refreshed when contacts change); nicknames are optional extras.
 */
class ContactFinder(ctx: Context, private val prefs: Prefs) {
    private val app = ctx.applicationContext

    private class Entry(val contact: Contact, val key: String, val tokens: List<String>, val rank: Int)

    companion object {
        @Volatile
        private var cache: List<Entry>? = null
        private var observing = false

        /** Same person, different words: "eşimi ara" also finds a contact saved as "Aşkım" or "Karım". */
        private val synonyms = listOf(
            listOf("eşim", "karım", "kocam", "hanımım", "hanım", "aşkım", "hayatım", "sevgilim", "canım", "beyim", "bitanem", "eş"),
            listOf("annem", "anneciğim", "anam", "validem", "anne"),
            listOf("babam", "babacığım", "pederim", "baba")
        ).map { g -> g.map { Tr.phon(it) }.toSet() }
    }

    private fun entries(): List<Entry> {
        cache?.let { return it }
        if (app.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) return emptyList()
        synchronized(ContactFinder::class.java) {
            if (!observing) {
                app.contentResolver.registerContentObserver(
                    ContactsContract.Contacts.CONTENT_URI, true,
                    object : ContentObserver(null) {
                        override fun onChange(selfChange: Boolean) { cache = null }
                    }
                )
                observing = true
            }
        }
        val byName = LinkedHashMap<String, Entry>()
        val proj = arrayOf(Phone.DISPLAY_NAME, Phone.NUMBER, Phone.IS_SUPER_PRIMARY, Phone.TYPE)
        app.contentResolver.query(Phone.CONTENT_URI, proj, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(0) ?: continue
                val number = c.getString(1) ?: continue
                val rank = (if (c.getInt(2) != 0) 2 else 0) + (if (c.getInt(3) == Phone.TYPE_MOBILE) 1 else 0)
                val key = Tr.phon(name)
                if (key.isEmpty()) continue
                val old = byName[key]
                if (old == null || rank > old.rank) {
                    byName[key] = Entry(Contact(name, number), key, key.split(' ').filter { it.isNotEmpty() }, rank)
                }
            }
        }
        return byName.values.toList().also { cache = it }
    }

    /** Loads the phone book in the background so the first call is instant. */
    fun preload() = Thread { entries() }.start()

    fun count(): Int = entries().size

    /** Names for the recognizer to expect. */
    fun names(): List<String> = (prefs.aliases().map { it.second } + entries().map { it.contact.name }).distinct()

    fun find(spoken: String): Contact? {
        val direct = Tr.stemVariants(spoken).map { Tr.phon(it) }
        val related = direct.flatMap { v -> synonyms.filter { v in it }.flatten() }.filter { it !in direct }

        var best: Contact? = null
        var bestScore = 0.0
        for ((key, _, c) in prefs.aliases()) {
            val k = Tr.phon(key)
            val sc = max(direct.maxOf { Tr.similarity(it, k) }, related.maxOfOrNull { Tr.similarity(it, k) * 0.95 } ?: 0.0)
            if (sc > bestScore) { best = c; bestScore = sc }
        }
        if (bestScore >= 0.8) return best

        best = null; bestScore = 0.0
        var bestRank = -1
        for (e in entries()) {
            val sc = max(score(e, direct), score(e, related) * 0.95)
            if (sc > bestScore + 1e-6 || (sc > bestScore - 1e-6 && e.rank > bestRank)) {
                best = e.contact; bestScore = sc; bestRank = e.rank
            }
        }
        return if (bestScore >= 0.72) best else null
    }

    private fun score(e: Entry, variants: List<String>): Double {
        var best = 0.0
        for (v in variants) {
            best = max(best, Tr.similarity(v, e.key))
            val vt = v.split(' ')
            if (vt.size == 1) {
                for (nt in e.tokens) best = max(best, Tr.similarity(v, nt) * 0.97)
            } else if (e.tokens.size >= vt.size) {
                best = max(best, Tr.similarity(v, e.tokens.take(vt.size).joinToString(" ")) * 0.98)
            }
        }
        return best
    }
}
