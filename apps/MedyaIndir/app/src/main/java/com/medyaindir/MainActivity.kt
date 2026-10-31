package com.medyaindir

import android.app.Activity
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Intent
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.view.View
import android.webkit.MimeTypeMap
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.TextView
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import java.io.File

class MainActivity : Activity() {

    private lateinit var link: EditText
    private lateinit var ses: RadioButton
    private lateinit var indirBtn: Button
    private lateinit var cubuk: ProgressBar
    private lateinit var durum: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        link = findViewById(R.id.link)
        ses = findViewById(R.id.ses)
        indirBtn = findViewById(R.id.indir)
        cubuk = findViewById(R.id.cubuk)
        durum = findViewById(R.id.durum)

        if (!Python.isStarted()) Python.start(AndroidPlatform(this))

        findViewById<Button>(R.id.yapistir).setOnClickListener {
            val cm = getSystemService(ClipboardManager::class.java)
            val metin = cm.primaryClip?.getItemAt(0)?.coerceToText(this)?.toString()
            if (metin != null) link.setText(linkiAyikla(metin))
        }
        indirBtn.setOnClickListener { baslat() }
        paylasimiAl(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        paylasimiAl(intent)
    }

    private fun paylasimiAl(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND) {
            intent.getStringExtra(Intent.EXTRA_TEXT)?.let { link.setText(linkiAyikla(it)) }
        }
    }

    private fun linkiAyikla(metin: String): String =
        Regex("https?://\\S+").find(metin)?.value ?: metin.trim()

    private fun baslat() {
        val url = link.text.toString().trim()
        if (!url.startsWith("http")) {
            durum.text = "Lütfen geçerli bir link girin."
            return
        }
        val sadeceSes = ses.isChecked
        indirBtn.isEnabled = false
        cubuk.visibility = View.VISIBLE
        cubuk.isIndeterminate = true
        durum.text = "Bilgiler alınıyor…"

        Thread {
            val gecici = File(cacheDir, "indirme").apply { deleteRecursively(); mkdirs() }
            try {
                val py = Python.getInstance().getModule("indirici")
                val sonuc = py.callAttr("indir", url, sadeceSes, gecici.absolutePath, Geri())
                val yollar = sonuc.asList().map { it.toString() }
                if (yollar.isEmpty()) throw RuntimeException("Dosya bulunamadı")
                val adlar = yollar.map { kaydet(File(it)) }
                ui {
                    durum.text = "✔ Kaydedildi (İndirilenler/MedyaIndir):\n" + adlar.joinToString("\n")
                }
            } catch (e: Throwable) {
                val mesaj = (e.message ?: e.toString()).lines()
                    .firstOrNull { it.contains("ERROR") } ?: (e.message ?: e.toString()).take(400)
                ui { durum.text = "✘ İndirilemedi:\n$mesaj" }
            } finally {
                gecici.deleteRecursively()
                ui {
                    indirBtn.isEnabled = true
                    cubuk.visibility = View.GONE
                }
            }
        }.start()
    }

    /** Dosyayı herkese açık İndirilenler/MedyaIndir klasörüne kopyalar. */
    private fun kaydet(dosya: File): String {
        val uzanti = dosya.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(uzanti)
            ?: "application/octet-stream"
        val degerler = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, dosya.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/MedyaIndir")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, degerler)
            ?: throw RuntimeException("Kayıt oluşturulamadı")
        contentResolver.openOutputStream(uri)!!.use { cikis ->
            dosya.inputStream().use { it.copyTo(cikis) }
        }
        degerler.clear()
        degerler.put(MediaStore.MediaColumns.IS_PENDING, 0)
        contentResolver.update(uri, degerler, null, null)
        return dosya.name
    }

    private fun ui(blok: () -> Unit) = runOnUiThread(blok)

    /** Python tarafından çağrılır. */
    inner class Geri {
        fun ilerleme(oran: Double, hiz: String) {
            ui {
                if (oran < 0) {
                    cubuk.isIndeterminate = true
                    durum.text = "İndiriliyor… $hiz"
                } else {
                    cubuk.isIndeterminate = false
                    cubuk.progress = (oran * 1000).toInt()
                    durum.text = "İndiriliyor… %" + (oran * 100).toInt() + "  $hiz"
                }
            }
        }
    }
}
