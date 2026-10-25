package com.bergamota.asistan

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.Build
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/** Weather from Open-Meteo (free, no API key). Blocking: call from a worker thread. */
object Weather {
    private data class Place(val lat: Double, val lon: Double, val name: String?)

    fun report(ctx: Context, spokenCity: String?, tomorrow: Boolean, savedCity: String): String {
        val place = try {
            when {
                spokenCity != null -> geocode(spokenCity)
                else -> here(ctx) ?: savedCity.takeIf { it.isNotBlank() }?.let { geocode(it) }
            }
        } catch (e: Exception) {
            return "Hava durumu alınamadı. İnternet bağlantısını kontrol et."
        } ?: return if (spokenCity != null) "$spokenCity bulunamadı."
        else "Konumunu bulamadım. Konum iznini ver ya da uygulamada şehrini yaz."

        val url = String.format(
            Locale.US,
            "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f" +
                "&current=temperature_2m,weather_code,wind_speed_10m" +
                "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max" +
                "&timezone=auto&forecast_days=2",
            place.lat, place.lon
        )
        val j = try { JSONObject(get(url)) } catch (e: Exception) {
            return "Hava durumu alınamadı. İnternet bağlantısını kontrol et."
        }
        val daily = j.getJSONObject("daily")
        val d = if (tomorrow) 1 else 0
        val max = daily.getJSONArray("temperature_2m_max").getDouble(d).roundToInt()
        val min = daily.getJSONArray("temperature_2m_min").getDouble(d).roundToInt()
        val code = daily.getJSONArray("weather_code").getInt(d)
        val rain = daily.optJSONArray("precipitation_probability_max")?.optInt(d, -1) ?: -1

        val sb = StringBuilder()
        if (place.name != null) sb.append(place.name).append(" için. ")
        if (tomorrow) {
            sb.append("Yarın ${describe(code)}. En yüksek $max, en düşük $min derece.")
        } else {
            val cur = j.getJSONObject("current")
            val now = cur.getDouble("temperature_2m").roundToInt()
            sb.append("Şu an $now derece, ${describe(cur.getInt("weather_code"))}. ")
            sb.append("Bugün en yüksek $max, en düşük $min derece.")
        }
        if (rain >= 0) sb.append(" Yağış ihtimali yüzde $rain.")
        return sb.toString()
    }

    private fun geocode(city: String): Place? {
        val q = URLEncoder.encode(city, "UTF-8")
        val j = JSONObject(get("https://geocoding-api.open-meteo.com/v1/search?name=$q&count=1&language=tr&format=json"))
        val r = j.optJSONArray("results")?.optJSONObject(0) ?: return null
        return Place(r.getDouble("latitude"), r.getDouble("longitude"), r.optString("name", city))
    }

    private fun here(ctx: Context): Place? {
        if (ctx.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) return null
        val lm = ctx.getSystemService(LocationManager::class.java) ?: return null
        val providers = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER, LocationManager.PASSIVE_PROVIDER)
        var best: Location? = providers
            .mapNotNull { p -> try { lm.getLastKnownLocation(p) } catch (e: Exception) { null } }
            .maxByOrNull { it.time }
        if (best == null && Build.VERSION.SDK_INT >= 30) {
            val found = AtomicReference<Location?>()
            val latch = CountDownLatch(1)
            val exec = Executors.newSingleThreadExecutor()
            try {
                lm.getCurrentLocation(LocationManager.NETWORK_PROVIDER, null, exec) { l -> found.set(l); latch.countDown() }
                latch.await(6, TimeUnit.SECONDS)
            } catch (e: Exception) {
            } finally {
                exec.shutdown()
            }
            best = found.get()
        }
        return best?.let { Place(it.latitude, it.longitude, null) }
    }

    private fun get(url: String): String {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 6000
        c.readTimeout = 6000
        c.setRequestProperty("User-Agent", "Asistan/0.1 (Android)")
        try {
            if (c.responseCode != 200) throw RuntimeException("HTTP ${c.responseCode}")
            return c.inputStream.bufferedReader().use { it.readText() }
        } finally {
            c.disconnect()
        }
    }

    /** WMO weather code -> Turkish. */
    private fun describe(code: Int): String = when (code) {
        0 -> "açık"
        1 -> "çoğunlukla açık"
        2 -> "parçalı bulutlu"
        3 -> "kapalı"
        45, 48 -> "sisli"
        51, 53, 55 -> "çiseliyor"
        56, 57 -> "dondurucu çisenti var"
        61 -> "hafif yağmurlu"
        63 -> "yağmurlu"
        65 -> "şiddetli yağmurlu"
        66, 67 -> "dondurucu yağmur var"
        71 -> "hafif karlı"
        73 -> "karlı"
        75 -> "yoğun kar yağışlı"
        77 -> "kar taneli"
        80, 81 -> "sağanak yağışlı"
        82 -> "şiddetli sağanak yağışlı"
        85, 86 -> "kar sağanaklı"
        95 -> "gök gürültülü sağanak var"
        96, 99 -> "dolulu fırtına var"
        else -> "değişken"
    }
}
