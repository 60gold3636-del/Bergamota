package com.bergamota.asistan

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the assistant after a reboot or an update if the user had enabled it. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (!Prefs(ctx).enabled || AssistantService.running) return
        try {
            AssistantService.start(ctx, AssistantService.ACTION_BOOT)
        } catch (e: Exception) {
            // Not a privileged install: Android 12+ refuses background microphone starts.
            // The Magisk module's service.sh starts it as root instead.
            Bus.log("Açılışta başlatılamadı: $e")
        }
    }
}
