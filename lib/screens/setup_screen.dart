import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/log_service.dart';
import 'orders_screen.dart';

/// İlk açılış: Sunucu URL + API key (SR_PRT_xxx) girişi.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _urlCtrl = TextEditingController(text: 'https://panel.syncresto.com');
  final _keyCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.startsWith('SR_PRT_')) {
      _keyCtrl.text = text;
      setState(() {});
    }
  }

  Future<void> _connect() async {
    final url = _urlCtrl.text.trim();
    final key = _keyCtrl.text.trim();
    if (url.isEmpty || !url.startsWith('http')) {
      setState(() => _error = 'Sunucu URL hatalı (örn: https://panel.syncresto.com)');
      return;
    }
    if (!key.startsWith('SR_PRT_') || key.length < 24) {
      setState(() => _error = 'API key formatı: SR_PRT_xxxxxxxxxxxx');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final api = ApiService();
    api.init();
    api.setBaseUrl(url);

    final result = await api.validateApiKey(key);

    if (result['valid'] == true) {
      api.setApiKey(key);
      final storage = StorageService();
      await storage.saveApiUrl(url);
      await storage.saveApiKey(key);
      await storage.saveRestaurantName(result['restaurant_name']?.toString() ?? 'SyncResto Print');

      LogService().logAction('SyncResto Print baglandi', details: {
        'restaurant_name': result['restaurant_name'],
        'integration_id': result['integration_id'],
      });

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const OrdersScreen()),
      );
      return;
    }

    setState(() {
      _busy = false;
      _error = result['error']?.toString() ?? 'Doğrulama başarısız';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(32),
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.print, color: Colors.white, size: 40),
                  ),
                  const SizedBox(height: 16),
                  const Text('SyncResto Print',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Color(0xFF1F2937))),
                  const Text('Online Sipariş Yazıcı',
                    style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
                  const SizedBox(height: 28),

                  TextField(
                    controller: _urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Sunucu URL',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  TextField(
                    controller: _keyCtrl,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: 'SR_PRT_xxxxxxxxxxxxxxxxxxxxxxxxxx',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.content_paste),
                        tooltip: 'Yapıştır',
                        onPressed: _paste,
                      ),
                    ),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEE2E2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(children: [
                        const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_error!,
                          style: const TextStyle(color: Color(0xFF991B1B), fontSize: 13))),
                      ]),
                    ),
                  ],

                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton(
                      onPressed: _busy ? null : _connect,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: _busy
                        ? const SizedBox(width: 22, height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Text('Bağlan', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),

                  const SizedBox(height: 16),
                  const Text(
                    'API key syncresto.com/adminsync → Print App Keys sayfasından alınır.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
