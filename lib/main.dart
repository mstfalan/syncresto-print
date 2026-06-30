import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'services/api_service.dart';
import 'services/storage_service.dart';
import 'services/sound_service.dart';
import 'services/print_queue_service.dart';
import 'services/update_service.dart';
import 'services/log_service.dart';
import 'screens/setup_screen.dart';
import 'screens/orders_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('tr_TR', null);

  // === Temel servisler ===
  final storage = StorageService();
  await storage.init();

  final api = ApiService();
  api.init();

  // === 18 May 2026: Yeni servisler ===
  await SoundService().init();
  await UpdateService().init();

  // Saved API URL + key varsa restore
  final savedUrl = storage.getApiUrl();
  final savedKey = storage.getApiKey();
  bool hasSession = false;
  if (savedUrl != null && savedKey != null) {
    api.setBaseUrl(savedUrl);
    api.setApiKey(savedKey);
    final result = await api.validateApiKey(savedKey);
    if (result['valid'] == true) {
      hasSession = true;
    } else {
      hasSession = true;
      print('[main] validate fail: ${result['error']} — yine de session açıldı');
    }
  }

  // 30 Haz 2026 — LogService init (KÖR UÇUŞ FIX): eskiden HİÇ çağrılmıyordu →
  // _dio/_apiKey null → flush() erken-return → özet-fiş/raster logları SAHADAN GELMİYORDU.
  // Oturum varsa (base+key set) paylasilan ApiService Dio + print-key ile baslat → loglar
  // sunucuya akar (özet fiş raster hatasi vs. artik gorunur). Hata olsa bile (auth/endpoint)
  // loglar pending kalir, app etkilenmez — basim/onizleme akisina dokunmaz.
  if (hasSession && savedKey != null) {
    try {
      await LogService().init(api.dio, savedKey);
    } catch (_) {}
  }

  // Print queue background retry — oturum varsa baslat
  if (hasSession) {
    PrintQueueService().start();
  }

  runApp(SyncRestoPrintApp(initialRoute: hasSession ? '/orders' : '/setup'));
}

class SyncRestoPrintApp extends StatelessWidget {
  final String initialRoute;
  const SyncRestoPrintApp({super.key, required this.initialRoute});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncResto Print',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: initialRoute == '/orders' ? const OrdersScreen() : const SetupScreen(),
    );
  }
}
