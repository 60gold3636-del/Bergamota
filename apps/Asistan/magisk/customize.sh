# Magisk / KernelSU / APatch install script (sourced by the module installer).
PKG=com.bergamota.asistan

if [ "$API" -lt 26 ]; then
  abort "! Android 8.0 veya üstü gerekli"
fi

ui_print "- Erhan'ın Asistanı sistem uygulaması olarak kuruluyor"
ui_print "  /system/priv-app/ErhanAsistan"

# A copy installed by hand as a normal app (same signing key) simply becomes an
# update of the system app, so nothing to remove. Settings caches its tiles:
# the entry appears after the reboot.
ui_print "- Yeniden başlatınca Ayarlar ana sayfasında"
ui_print "  \"Erhan'ın Asistanı\" girişi görünür."
ui_print "- Oradan izinleri verip \"Asistanı etkinleştir\"e basın."

set_perm_recursive "$MODPATH/system" 0 0 0755 0644
