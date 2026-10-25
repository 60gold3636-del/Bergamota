package com.bergamota.asistan

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.Settings
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity(), Bus.Listener {
    private lateinit var prefs: Prefs
    private lateinit var status: TextView
    private lateinit var toggle: Button
    private lateinit var perms: TextView
    private lateinit var aliases: TextView
    private lateinit var log: TextView
    private lateinit var aliasName: EditText
    private var localSpeaker: Speaker? = null
    private var localAssistant: Assistant? = null

    private val runtimePerms: Array<String>
        get() = buildList {
            add(Manifest.permission.RECORD_AUDIO)
            add(Manifest.permission.CALL_PHONE)
            add(Manifest.permission.READ_CONTACTS)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        }.toTypedArray()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)
        status = findViewById(R.id.status)
        toggle = findViewById(R.id.toggle)
        perms = findViewById(R.id.perms)
        aliases = findViewById(R.id.aliases)
        log = findViewById(R.id.log)
        aliasName = findViewById(R.id.aliasName)
        val wake = findViewById<EditText>(R.id.wake)
        val noWake = findViewById<CheckBox>(R.id.noWake)
        val city = findViewById<EditText>(R.id.city)
        val testText = findViewById<EditText>(R.id.testText)

        wake.setText(prefs.wakeWord)
        noWake.isChecked = prefs.noWakeWord
        city.setText(prefs.city)
        findViewById<TextView>(R.id.help).text = HELP

        toggle.setOnClickListener {
            if (AssistantService.running) {
                AssistantService.start(this, AssistantService.ACTION_STOP)
            } else if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(runtimePerms, REQ_PERMS)
            } else {
                AssistantService.start(this)
            }
            toggle.postDelayed({ refresh() }, 300)
        }
        findViewById<Button>(R.id.listen).setOnClickListener {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                AssistantService.start(this, AssistantService.ACTION_LISTEN)
            } else requestPermissions(runtimePerms, REQ_PERMS)
        }
        findViewById<Button>(R.id.grant).setOnClickListener { requestPermissions(runtimePerms, REQ_PERMS) }
        findViewById<Button>(R.id.overlay).setOnClickListener {
            startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")))
        }
        findViewById<Button>(R.id.battery).setOnClickListener {
            try {
                startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
            } catch (e: Exception) {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
        }
        findViewById<Button>(R.id.save).setOnClickListener {
            prefs.wakeWord = wake.text.toString()
            prefs.noWakeWord = noWake.isChecked
            prefs.city = city.text.toString()
            Toast.makeText(this, "Kaydedildi", Toast.LENGTH_SHORT).show()
        }
        findViewById<Button>(R.id.aliasPick).setOnClickListener {
            if (aliasName.text.isBlank()) {
                Toast.makeText(this, "Önce takma adı yazın (örn. eşim)", Toast.LENGTH_SHORT).show()
            } else {
                @Suppress("DEPRECATION")
                startActivityForResult(Intent(Intent.ACTION_PICK, Phone.CONTENT_URI), REQ_PICK)
            }
        }
        findViewById<Button>(R.id.aliasDelete).setOnClickListener {
            if (prefs.removeAlias(aliasName.text.toString())) aliasName.setText("")
            refresh()
        }
        val run = {
            val t = testText.text.toString()
            if (t.isNotBlank()) {
                if (AssistantService.running) {
                    AssistantService.start(this, AssistantService.ACTION_TEXT, t)
                } else {
                    val sp = localSpeaker ?: Speaker(this) {}.also { localSpeaker = it }
                    val a = localAssistant ?: Assistant(this, sp).also { localAssistant = it }
                    a.handle(t)
                }
            }
        }
        findViewById<Button>(R.id.testRun).setOnClickListener { run() }
        testText.setOnEditorActionListener { _, id, _ ->
            if (id == EditorInfo.IME_ACTION_GO) { run(); true } else false
        }
    }

    override fun onResume() {
        super.onResume()
        Bus.listener = this
        refresh()
        onLog(Bus.logText())
    }

    override fun onPause() {
        Bus.listener = null
        super.onPause()
    }

    override fun onDestroy() {
        localSpeaker?.shutdown()
        localAssistant?.shutdown()
        super.onDestroy()
    }

    override fun onStatus(status: String) = refresh()

    override fun onLog(text: String) {
        log.text = text
    }

    private fun refresh() {
        status.text = if (AssistantService.running) Bus.status else "Kapalı"
        toggle.text = if (AssistantService.running) "Asistanı kapat" else "Asistanı başlat"

        fun mark(p: String) = if (checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED) "✓" else "✗"
        val pm = getSystemService(PowerManager::class.java)
        perms.text = listOf(
            "${mark(Manifest.permission.RECORD_AUDIO)} Mikrofon",
            "${mark(Manifest.permission.CALL_PHONE)} Telefon araması",
            "${mark(Manifest.permission.READ_CONTACTS)} Rehber",
            "${mark(Manifest.permission.ACCESS_COARSE_LOCATION)} Konum (hava durumu)",
            "${if (Settings.canDrawOverlays(this)) "✓" else "✗"} Üstte gösterme",
            "${if (pm.isIgnoringBatteryOptimizations(packageName)) "✓" else "✗"} Pil optimizasyonu kapalı"
        ).joinToString("\n")

        val list = prefs.aliases()
        aliases.text = if (list.isEmpty()) "Henüz yok. Örn. \"eşim\" yazıp rehberden kişiyi seçin; sonra \"asistan eşimi ara\" deyin."
        else list.joinToString("\n") { (_, label, c) -> "$label → ${c.name} (${c.number})" }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refresh()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        contentResolver.query(uri, arrayOf(Phone.DISPLAY_NAME, Phone.NUMBER), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val contact = Contact(c.getString(0) ?: "", c.getString(1) ?: return@use)
                prefs.putAlias(aliasName.text.toString(), contact)
                aliasName.setText("")
            }
        }
        refresh()
    }

    companion object {
        private const val REQ_PERMS = 1
        private const val REQ_PICK = 2
        private val HELP = """
            Önce uyandırma kelimesini söyleyin ("asistan"), bip sesinden sonra ya da aynı cümlede komutu:
            • asistan eşimi ara / annemi ara / Ahmet'i ara
            • asistan yarın sabah sekize alarm kur
            • asistan akşam yedi buçuğa alarm kur / on dakika sonraya alarm kur
            • asistan beş dakikalık zamanlayıcı kur
            • asistan bugün hava nasıl / yarın hava nasıl / İzmir'de hava nasıl (internet gerekir)
            • asistan saat kaç / bugün günlerden ne / şarj kaç
            • asistan feneri aç / feneri kapat
            • asistan sesi aç / sesi kıs / sessize al
            • asistan müziği durdur / sonraki şarkı
            • asistan kamerayı aç / WhatsApp'ı aç
            • asistan Kadıköy'e yol tarifi (internet gerekir)
            • asistan sus / iptal
            İnternet olmadan da çalışır: konuşma tanıma telefonun içinde yapılır.
        """.trimIndent()
    }
}
