import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/printer_service.dart';
import '../services/storage_service.dart';
import '../services/sound_service.dart';
import '../services/order_service.dart';
import '../services/update_service.dart';

/// Ayarlar ekrani — panel'den gelen yazıcı listesi (read-only + test) + uygulama tercihleri.
/// 18 May 2026: Mustafa kuralı — kategori/departman routing YOK. Yazıcı → ürün eşleştirmesi
/// PANELDEN yönetilir (panel_products.printer_id). Bu ekran sadece:
///   - Mevcut yazıcıları listeler (panel.syncresto.com → POS → Yazıcılar'dan ekleniyor)
///   - Test fişi atar
///   - Default fallback yazıcı seçimi (printer_id atanmamış ürünler için)
///   - Auto-print, ses, auto-update toggle'lari
class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  final ApiService _api = ApiService();
  final PrinterService _printerService = PrinterService();
  final StorageService _storage = StorageService();
  final SoundService _sound = SoundService();
  final OrderService _orderService = OrderService();
  final UpdateService _updateService = UpdateService();

  List<Map<String, dynamic>> _printers = [];
  int? _defaultPrinterId;
  bool _loading = true;
  bool _testing = false;
  bool _autoPrint = true;
  bool _soundEnabled = true;
  bool _autoUpdate = true;
  UpdateInfo? _updateInfo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await _api.getPrinters();
    setState(() {
      _printers = list;
      _defaultPrinterId = _storage.getDefaultPrinterId();
      _autoPrint = _storage.getAutoPrint();
      _soundEnabled = _storage.getSoundEnabled();
      _autoUpdate = _storage.getAutoUpdateCheck();
      _loading = false;
    });
    // Update check (sessiz)
    _updateService.checkForUpdate().then((info) {
      if (mounted) setState(() => _updateInfo = info);
    });
  }

  Future<void> _selectDefault(Map<String, dynamic> printer) async {
    final id = printer['id'];
    if (id is! int) return;
    setState(() => _defaultPrinterId = id);
    _printerService.setSelectedPrinter(printer);
    await _storage.saveSelectedPrinterId(id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('"${printer['name']}" varsayılan fallback yazıcı olarak ayarlandı'),
        backgroundColor: const Color(0xFF16A34A),
      ));
    }
  }

  Future<void> _testPrinter(Map<String, dynamic> printer) async {
    setState(() => _testing = true);
    final ip = (printer['ip_address'] ?? printer['ip'] ?? '').toString();
    final port = printer['port'] is int ? printer['port'] as int : 9100;
    final ok = await _printerService.testPrint(ip, port);
    if (!mounted) return;
    setState(() => _testing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? '✓ ${printer['name']} test fişi gönderildi'
          : '✗ ${printer['name']} ($ip:$port) bağlanılamadı'),
      backgroundColor: ok ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
    ));
  }

  Future<void> _checkUpdate() async {
    final info = await _updateService.checkForUpdate();
    if (!mounted) return;
    setState(() => _updateInfo = info);
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Güncelleme bilgisi alınamadı')));
      return;
    }
    if (!info.updateAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Güncel sürüm: v${info.currentVersion}')));
      return;
    }
    _showUpdateDialog(info);
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0xFFDBEAFE), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.system_update, color: Color(0xFF2563EB)),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('Yeni Sürüm Mevcut')),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Mevcut: v${info.currentVersion}'),
          const SizedBox(height: 4),
          Text('Yeni: v${info.latestVersion}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF16A34A))),
          if (info.isCritical) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(6)),
              child: const Text('⚠ Kritik güncelleme — en kısa sürede yükleyin',
                style: TextStyle(color: Color(0xFFB91C1C), fontWeight: FontWeight.bold)),
            ),
          ],
          if (info.releaseNotes != null && info.releaseNotes!.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Yenilikler:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(info.releaseNotes!, style: const TextStyle(fontSize: 13)),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Daha Sonra')),
          ElevatedButton.icon(
            onPressed: info.downloadUrl == null ? null : () async {
              Navigator.pop(context);
              await _updateService.openDownloadUrl(info.downloadUrl!);
            },
            icon: const Icon(Icons.download, size: 16),
            label: const Text('İndir'),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        actions: [
          if (_updateInfo?.updateAvailable == true)
            IconButton(
              tooltip: 'Yeni sürüm: v${_updateInfo!.latestVersion}',
              icon: const Icon(Icons.system_update, color: Color(0xFFFEF3C7)),
              onPressed: () => _showUpdateDialog(_updateInfo!),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // === Tercihler ===
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(children: [
                      SwitchListTile(
                        value: _autoPrint,
                        onChanged: (v) async {
                          setState(() => _autoPrint = v);
                          await _storage.saveAutoPrint(v);
                          await _orderService.setAutoPrint(v);
                        },
                        title: const Text('Otomatik Yazdırma'),
                        subtitle: const Text('Yeni sipariş geldiğinde otomatik fişe basar'),
                        secondary: const Icon(Icons.print, color: Color(0xFF2563EB)),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        value: _soundEnabled,
                        onChanged: (v) async {
                          setState(() => _soundEnabled = v);
                          await _sound.setEnabled(v);
                          if (v) await _sound.playNewOrder(); // önizleme
                        },
                        title: const Text('Sesli Bildirim'),
                        subtitle: const Text('Yeni sipariş geldiğinde ses çalar'),
                        secondary: Icon(_soundEnabled ? Icons.volume_up : Icons.volume_off,
                            color: _soundEnabled ? const Color(0xFF16A34A) : Colors.grey),
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        value: _autoUpdate,
                        onChanged: (v) async {
                          setState(() => _autoUpdate = v);
                          await _storage.saveAutoUpdateCheck(v);
                        },
                        title: const Text('Otomatik Güncelleme Kontrolü'),
                        subtitle: Text(_updateService.currentVersion != null
                            ? 'Mevcut sürüm: v${_updateService.currentVersion}'
                            : 'Yeni sürüm varsa bildirim gösterir'),
                        secondary: const Icon(Icons.system_update, color: Color(0xFF7C3AED)),
                      ),
                      ListTile(
                        leading: const Icon(Icons.search),
                        title: const Text('Şimdi Güncelleme Kontrol Et'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _checkUpdate,
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                // === Yazıcı listesi ===
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(children: [
                    Icon(Icons.print, size: 18, color: Color(0xFF475569)),
                    SizedBox(width: 8),
                    Text('PANELDEN GELEN YAZICILAR',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF475569), letterSpacing: 0.5)),
                  ]),
                ),
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(8)),
                  child: const Row(children: [
                    Icon(Icons.info_outline, size: 16, color: Color(0xFF2563EB)),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Ürün → yazıcı eşleştirmesi panel.syncresto.com → POS → Ürünler sayfasından yapılır. '
                        'Default seçilen yazıcı, eşleşmemiş ürünler için yedek olarak kullanılır.',
                        style: TextStyle(fontSize: 12, color: Color(0xFF1E40AF), height: 1.4),
                      ),
                    ),
                  ]),
                ),
                if (_printers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Text(
                      'Sunucuda yazıcı tanımı yok.\nLütfen panel.syncresto.com → POS → Yazıcılar sayfasından yazıcı ekleyin.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 15),
                    ),
                  )
                else
                  ..._printers.map((p) {
                    final id = p['id'];
                    final isDefault = id == _defaultPrinterId;
                    final ip = p['ip_address'] ?? p['ip'] ?? '?';
                    final port = p['port'] ?? 9100;
                    final isActive = p['is_active'] == true;
                    final type = p['type']?.toString() ?? 'kitchen';
                    return Card(
                      elevation: isDefault ? 4 : 1,
                      color: isDefault ? const Color(0xFFEFF6FF) : null,
                      child: ListTile(
                        leading: Icon(
                          isActive ? Icons.print : Icons.print_disabled,
                          color: isDefault ? const Color(0xFF2563EB) : (isActive ? Colors.grey[700] : Colors.grey),
                          size: 32,
                        ),
                        title: Row(children: [
                          Expanded(
                            child: Text(p['name']?.toString() ?? 'Yazıcı',
                              style: TextStyle(fontWeight: isDefault ? FontWeight.bold : FontWeight.normal)),
                          ),
                          if (isDefault)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2563EB),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Text('VARSAYILAN',
                                style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                        ]),
                        subtitle: Text('$ip:$port • $type${isActive ? '' : ' • PASİF'}',
                          style: TextStyle(color: isActive ? Colors.grey[600] : Colors.red[300])),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: 'Test fişi yazdır',
                            icon: const Icon(Icons.send, size: 20, color: Color(0xFF16A34A)),
                            onPressed: _testing ? null : () => _testPrinter(p),
                          ),
                          IconButton(
                            tooltip: isDefault ? 'Varsayılan' : 'Varsayılan yap',
                            icon: Icon(isDefault ? Icons.check_circle : Icons.radio_button_unchecked,
                                color: isDefault ? const Color(0xFF16A34A) : Colors.grey),
                            onPressed: isActive ? () => _selectDefault(p) : null,
                          ),
                        ]),
                      ),
                    );
                  }),
              ],
            ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          height: 50,
          child: ElevatedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Yazıcı Listesini Yenile'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
