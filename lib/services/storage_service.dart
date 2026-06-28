import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// SyncResto Print — SharedPreferences sarmalayıcısı.
/// 18 May 2026: Sadece ses + auto-update toggle eklendi.
/// Yazıcı routing PANELDEN gelir (panel_products.printer_id) — burada manuel mapping YOK.
/// 28 Haz 2026: Özet HTML fişi için panel printer_id → OS yazıcı adı eşleştirmesi eklendi
///   (HTML, ESC/POS gibi ham IP:9100 değil, OS yazıcı sürücüsüyle basılır — bu yüzden
///    panel yazıcısının hangi Windows yazıcısı olduğu lokal eşleştirilir).
class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  static const _keyApiUrl = 'api_url';
  static const _keyApiKey = 'api_key';
  static const _keyRestaurantName = 'restaurant_name';
  static const _keyAutoPrint = 'auto_print';
  static const _keySelectedPrinterId = 'selected_printer_id'; // fallback: backend'de printer atanmamis urunler icin

  // 18 May 2026: Yeni alanlar
  static const _keySoundEnabled = 'sound_enabled';            // ses on/off (default true)
  static const _keyAutoUpdateCheck = 'auto_update_check';     // default true
  static const _keyServerSideReceipt = 'server_side_receipt'; // 27 Haz 2026: sunucu ESC/POS (default KAPALI)
  static const _keyOsPrinterMap = 'os_printer_map';          // 28 Haz 2026: panel printer_id → OS yazıcı adı (özet HTML fişi)

  late SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  // === API & Tenant ===
  String? getApiUrl() => _prefs.getString(_keyApiUrl);
  Future<void> saveApiUrl(String url) => _prefs.setString(_keyApiUrl, url);

  String? getApiKey() => _prefs.getString(_keyApiKey);
  Future<void> saveApiKey(String key) => _prefs.setString(_keyApiKey, key);

  String? getRestaurantName() => _prefs.getString(_keyRestaurantName);
  Future<void> saveRestaurantName(String name) => _prefs.setString(_keyRestaurantName, name);

  // === Auto print ===
  bool getAutoPrint() => _prefs.getBool(_keyAutoPrint) ?? true;
  Future<void> saveAutoPrint(bool v) => _prefs.setBool(_keyAutoPrint, v);

  // === Fallback default yazıcı (panel'de printer_id atanmamis urunler icin) ===
  int? getSelectedPrinterId() => _prefs.getInt(_keySelectedPrinterId);
  Future<void> saveSelectedPrinterId(int id) => _prefs.setInt(_keySelectedPrinterId, id);
  Future<void> clearSelectedPrinter() => _prefs.remove(_keySelectedPrinterId);
  int? getDefaultPrinterId() => getSelectedPrinterId();

  // === Ses on/off (default acik) ===
  bool getSoundEnabled() => _prefs.getBool(_keySoundEnabled) ?? true;
  Future<void> saveSoundEnabled(bool v) => _prefs.setBool(_keySoundEnabled, v);

  // === Auto-update check (default acik) ===
  bool getAutoUpdateCheck() => _prefs.getBool(_keyAutoUpdateCheck) ?? true;
  Future<void> saveAutoUpdateCheck(bool v) => _prefs.setBool(_keyAutoUpdateCheck, v);

  // === Server-side ESC/POS (27 Haz 2026, default KAPALI) ===
  // Acikken: fis byte'i sunucudan (panel /escpos) cekilir, tasarim sunucuda -> build'siz.
  // Kapali/sunucu hata: mevcut Flutter render (generateOrderReceiptBytes) FALLBACK.
  bool getServerSideReceipt() => _prefs.getBool(_keyServerSideReceipt) ?? false;
  Future<void> saveServerSideReceipt(bool v) => _prefs.setBool(_keyServerSideReceipt, v);

  // === Özet HTML fişi: panel printer_id → OS yazıcı adı eşleştirmesi (28 Haz 2026) ===
  // JSON: { "12": "POS-58 Termal", "7": "Mutfak Yazici" } (panel printer_id → Windows yazıcı adı)
  Map<int, String> getOsPrinterMap() {
    final raw = _prefs.getString(_keyOsPrinterMap);
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(int.tryParse(k) ?? -1, v.toString()))
        ..removeWhere((k, v) => k < 0);
    } catch (_) {
      return {};
    }
  }

  /// Belirli panel printer_id'sine eşleştirilmiş OS yazıcı adı (yoksa null → yazdır penceresi).
  String? getOsPrinterName(int panelPrinterId) => getOsPrinterMap()[panelPrinterId];

  Future<void> saveOsPrinterName(int panelPrinterId, String? osName) async {
    final map = getOsPrinterMap();
    if (osName == null || osName.isEmpty) {
      map.remove(panelPrinterId);
    } else {
      map[panelPrinterId] = osName;
    }
    final json = jsonEncode(map.map((k, v) => MapEntry(k.toString(), v)));
    await _prefs.setString(_keyOsPrinterMap, json);
  }

  // === Logout / reset ===
  Future<void> clearAll() async {
    await _prefs.remove(_keyApiUrl);
    await _prefs.remove(_keyApiKey);
    await _prefs.remove(_keyRestaurantName);
    await _prefs.remove(_keySelectedPrinterId);
    // ses ve auto-print tercihleri silinmez (kullanici tercihi)
  }
}
