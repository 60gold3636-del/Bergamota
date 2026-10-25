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
import android.speech.tts.TextToSpeech
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.SeekBar
import android.widget.Spinner
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
    private var preview: Speaker? = null
    private lateinit var engineSpin: Spinner
    private lateinit var voiceSpin: Spinner
    private lateinit var contactsInfo: TextView
    private var engineIds = listOf<String>()
    private var voiceIds = listOf<String>()

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
        contactsInfo = findViewById(R.id.contactsInfo)

        val systemRec = findViewById<CheckBox>(R.id.systemRec)
        systemRec.isChecked = prefs.systemRecognizer
        systemRec.setOnCheckedChangeListener { _, on -> prefs.systemRecognizer = on }
        findViewById<Button>(R.id.recDownload).setOnClickListener {
            val ok = try { CommandRecognizer(this, {}, {}).downloadTurkish() } catch (e: Exception) { false }
            if (ok) {
                Toast.makeText(this, "İndirme istendi (bildirimden takip edin)", Toast.LENGTH_LONG).show()
            } else {
                // Older Android: Google app > Settings > Voice > Offline speech recognition.
                Toast.makeText(this, "Google uygulaması > Ayarlar > Ses > Çevrimdışı konuşma tanıma > Türkçe", Toast.LENGTH_LONG).show()
                try {
                    startActivity(Intent("com.google.android.googlequicksearchbox.action.PRIVACY_SETTINGS_VOICE"))
                } catch (e: Exception) {
                    try { startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)) } catch (e2: Exception) {}
                }
            }
        }
        setupVoice()

        toggle.setOnClickListener {
            if (AssistantService.running) {
                AssistantService.start(this, AssistantService.ACTION_STOP)
            } else if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(runtimePerms, REQ_PERMS)
            } else {
                prefs.enabled = true
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
                    val sp = localSpeaker ?: Speaker(this, onBusy = {}).also { localSpeaker = it }
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
        // Opened from Settings while enabled but not running (e.g. killed): bring it back.
        if (prefs.enabled && !AssistantService.running &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        ) AssistantService.start(this)
        refresh()
        onLog(Bus.logText())
    }

    override fun onPause() {
        Bus.listener = null
        super.onPause()
    }

    override fun onDestroy() {
        preview?.shutdown()
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
        toggle.text = if (AssistantService.running) "Asistanı kapat" else "Asistanı etkinleştir (sürekli çalışır)"

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
        aliases.text = if (list.isEmpty()) "Gerek yok: rehberdeki herkes adıyla aranır. \"Eşim\", \"Aşkım\", \"Karım\", \"Annem\" gibi kayıtlar da kendiliğinden bulunur. Kişi bambaşka bir adla kayıtlıysa buradan bağlayın."
        else list.joinToString("\n") { (_, label, c) -> "$label → ${c.name} (${c.number})" }
        if (checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            contactsInfo.text = "✗ Rehber izni yok: \"İzinleri ver\"e basın, sonra herkes adıyla aranabilir."
        } else {
            Thread {
                val n = ContactFinder(this, prefs).count()
                runOnUiThread { contactsInfo.text = "✓ Rehberdeki $n kişinin tamamı otomatik tanınıyor. Örn: \"asistan Ahmet Yılmaz'ı ara\"." }
            }.start()
        }
    }

    private fun notifyVoice() {
        if (AssistantService.running) AssistantService.start(this, AssistantService.ACTION_RELOAD_VOICE)
    }

    private fun setupVoice() {
        engineSpin = findViewById(R.id.engine)
        voiceSpin = findViewById(R.id.voice)
        val rate = findViewById<SeekBar>(R.id.rate)
        val pitch = findViewById<SeekBar>(R.id.pitch)
        val rateLabel = findViewById<TextView>(R.id.rateLabel)
        val pitchLabel = findViewById<TextView>(R.id.pitchLabel)
        preview = Speaker(this, {}, { runOnUiThread { fillVoices() } })

        // Bars: 0..30 -> 0.5x..2.0x
        fun label() {
            rateLabel.text = "Konuşma hızı: %.2fx".format(prefs.ttsRate)
            pitchLabel.text = "Ses tonu: %.2fx".format(prefs.ttsPitch)
        }
        rate.progress = ((prefs.ttsRate - 0.5f) * 20).toInt()
        pitch.progress = ((prefs.ttsPitch - 0.5f) * 20).toInt()
        label()
        val bars = object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(bar: SeekBar, p: Int, fromUser: Boolean) {
                if (!fromUser) return
                if (bar === rate) prefs.ttsRate = 0.5f + p / 20f else prefs.ttsPitch = 0.5f + p / 20f
                label()
            }
            override fun onStartTrackingTouch(bar: SeekBar) {}
            override fun onStopTrackingTouch(bar: SeekBar) {
                preview?.applyTuning()
                preview?.say(SAMPLE)
                notifyVoice()
            }
        }
        rate.setOnSeekBarChangeListener(bars)
        pitch.setOnSeekBarChangeListener(bars)

        engineSpin.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, pos: Int, id: Long) {
                val e = engineIds.getOrNull(pos) ?: return
                if (e == prefs.ttsEngine) return
                prefs.ttsEngine = e
                prefs.ttsVoice = ""
                preview?.reload()
                notifyVoice()
            }
            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }
        voiceSpin.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, pos: Int, id: Long) {
                val v = voiceIds.getOrNull(pos) ?: return
                if (v == prefs.ttsVoice) return
                prefs.ttsVoice = v
                preview?.applyTuning()
                preview?.say(SAMPLE)
                notifyVoice()
            }
            override fun onNothingSelected(parent: AdapterView<*>?) {}
        }
        findViewById<Button>(R.id.voiceTest).setOnClickListener { preview?.say(SAMPLE) }
        findViewById<Button>(R.id.voiceInstall).setOnClickListener {
            try {
                startActivity(Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA).apply {
                    prefs.ttsEngine.takeIf { it.isNotEmpty() }?.let { setPackage(it) }
                })
            } catch (e: Exception) {
                startActivity(Intent("com.android.settings.TTS_SETTINGS"))
            }
        }
    }

    private fun fillVoices() {
        val sp = preview ?: return
        val engines = sp.engines()
        engineIds = listOf("") + engines.map { it.name }
        engineSpin.adapter = ArrayAdapter(
            this, android.R.layout.simple_spinner_dropdown_item,
            listOf("Varsayılan") + engines.map { it.label }
        )
        engineSpin.setSelection(engineIds.indexOf(prefs.ttsEngine).coerceAtLeast(0))

        val voices = sp.voices()
        voiceIds = listOf("") + voices.map { it.name }
        val labels = listOf(if (voices.isEmpty()) "Türkçe ses yok — \"Yeni ses indir\"" else "Otomatik") +
            voices.mapIndexed { i, v ->
                "Ses ${i + 1}" + (if (v.isNetworkConnectionRequired) " (internetli)" else "") + "  ·  " + v.name
            }
        voiceSpin.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, labels)
        voiceSpin.setSelection(voiceIds.indexOf(prefs.ttsVoice).coerceAtLeast(0))
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
        private const val SAMPLE = "Merhaba, ben Erhan'ın asistanıyım. Yarın sabah sekiz için alarm kuruldu."
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
