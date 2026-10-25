#!/system/bin/sh
# Runs as root after boot (late_start service). Grants what a voice assistant
# needs and starts the listener; the app stops again at once if the user has
# not enabled it (ACTION_BOOT checks the "enabled" switch).
PKG=com.bergamota.asistan

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 8

for p in RECORD_AUDIO CALL_PHONE READ_CONTACTS ACCESS_COARSE_LOCATION POST_NOTIFICATIONS; do
  pm grant "$PKG" "android.permission.$p" 2>/dev/null
done
appops set "$PKG" SYSTEM_ALERT_WINDOW allow 2>/dev/null
appops set "$PKG" RUN_IN_BACKGROUND allow 2>/dev/null
appops set "$PKG" RUN_ANY_IN_BACKGROUND allow 2>/dev/null
dumpsys deviceidle whitelist "+$PKG" >/dev/null 2>&1

am start-foreground-service -n "$PKG/.AssistantService" -a com.bergamota.asistan.BOOT >/dev/null 2>&1
