package com.bergamota.asistan

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract.CommonDataKinds.Phone
import kotlin.math.abs
import kotlin.math.max

/** Finds the contact meant by a spoken name: nicknames first, then a fuzzy search of the phone book. */
class ContactFinder(private val ctx: Context, private val prefs: Prefs) {

    fun find(spoken: String): Contact? {
        val variants = Tr.stemVariants(spoken).map { Tr.phon(it) }

        var best: Contact? = null
        var bestScore = 0.0
        for ((key, _, c) in prefs.aliases()) {
            val k = Tr.phon(key)
            val sc = variants.maxOf { Tr.similarity(it, k) }
            if (sc > bestScore) { best = c; bestScore = sc }
        }
        if (bestScore >= 0.8) return best

        if (ctx.checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) return null
        best = null; bestScore = 0.0
        var bestRank = -1
        val proj = arrayOf(Phone.DISPLAY_NAME, Phone.NUMBER, Phone.IS_SUPER_PRIMARY, Phone.TYPE)
        ctx.contentResolver.query(Phone.CONTENT_URI, proj, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(0) ?: continue
                val number = c.getString(1) ?: continue
                val sc = score(Tr.phon(name), variants)
                val rank = (if (c.getInt(2) != 0) 2 else 0) + (if (c.getInt(3) == Phone.TYPE_MOBILE) 1 else 0)
                if (sc > bestScore + 1e-6 || (abs(sc - bestScore) < 1e-6 && rank > bestRank)) {
                    best = Contact(name, number); bestScore = sc; bestRank = rank
                }
            }
        }
        return if (bestScore >= 0.72) best else null
    }

    private fun score(name: String, variants: List<String>): Double {
        val nameTokens = name.split(' ').filter { it.isNotEmpty() }
        var best = 0.0
        for (v in variants) {
            best = max(best, Tr.similarity(v, name))
            val vt = v.split(' ')
            if (vt.size == 1) {
                for (nt in nameTokens) best = max(best, Tr.similarity(v, nt) * 0.97)
            } else if (nameTokens.size >= vt.size) {
                best = max(best, Tr.similarity(v, nameTokens.take(vt.size).joinToString(" ")) * 0.98)
            }
        }
        return best
    }
}
