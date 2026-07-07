import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/date_symbol_data_local.dart';

import 'services/api_service.dart';
import 'services/storage_service.dart';
import 'services/sound_service.dart';
import 'services/print_queue_service.dart';
import 'services/update_service.dart';
import 'services/log_service.dart';
import 'screens/setup_screen.dart';
import 'screens/orders_screen.dart';

/// Windows'ta Dart/BoringSSL, işletim sisteminin kök sertifika deposunu OKUR ama
/// Windows'un otomatik kök indirme (CryptoAPI auto root update) mekanizmasını
/// TETİKLEMEZ. Deposunda gerekli kök (Let's Encrypt → ISRG Root X1) cache'lenmemiş
/// saha PC'sinde TLS `CERTIFICATE_VERIFY_FAILED` (handshake.cc:321) ile patlar →
/// validate/socket-token DioException → UI'da "Bağlantı hatası". Tarayıcı/curl Schannel
/// ile anında indirir, Dart indiremez. Çözüm: Mozilla CA bundle'ı (cacert.pem) taşı ve
/// SecurityContext'e yükle. `withTrustedRoots: true` sistem trust'ını PARALEL tutar
/// (union trust) → eski çalışan PC'lerde regresyon yok. Dio + socket_io_client + http
/// paketlerinin ÜÇÜNÜ birden kapsar. Ref: Flutter #54896, #41945 · Caller ID v0.3.1'de kanıtlandı.
class _SyncRestoHttpOverrides extends HttpOverrides {
  SecurityContext? _ctx;

  Future<void> loadCaBundle() async {
    try {
      final bytes = await rootBundle.load('assets/certs/cacert.pem');
      _ctx = SecurityContext(withTrustedRoots: true);
      _ctx!.setTrustedCertificatesBytes(bytes.buffer.asUint8List());
    } catch (_) {
      _ctx = null; // bundle yüklenemezse sistem trust'a düş (eski davranış)
    }
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // context = çağıranın BİLEREK verdiği SecurityContext → önceliklidir. Yoksa CA bundle.
    return super.createHttpClient(context ?? _ctx);
  }
}

final _httpOverrides = _SyncRestoHttpOverrides();

void main() async {
  // TLS CA bundle'ı devreye al (Windows boringssl sistem CA'yı otomatik indirmez).
  HttpOverrides.global = _httpOverrides;
  WidgetsFlutterBinding.ensureInitialized();
  // ensureInitialized SONRASI — rootBundle hazır olmalı.
  await _httpOverrides.loadCaBundle();
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
