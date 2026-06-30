import 'dart:async';
import 'package:dio/dio.dart';

import 'log_service.dart';

/// SyncResto Print — Backend API client (panel.syncresto.com / api/print).
/// Caller ID pattern ile aynı: X-Print-Key header authentication.
class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  late Dio _dio;
  String _baseUrl = '';
  String? _apiKey;
  bool _initialized = false;

  void init() {
    if (_initialized) return;
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      validateStatus: (s) => s != null && s < 500,
    ));
    _initialized = true;
  }

  void setBaseUrl(String url) {
    _baseUrl = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    _dio.options.baseUrl = _baseUrl;
  }

  void setApiKey(String apiKey) {
    _apiKey = apiKey;
    _dio.options.headers['X-Print-Key'] = apiKey;
  }

  String? get apiKey => _apiKey;
  String get baseUrl => _baseUrl;

  /// 30 Haz 2026 — LogService init icin paylasilan Dio (baseUrl + X-Print-Key zaten ayarli).
  /// LogService bunu kullanip /api/print/logs'a log yollar (saha kor-ucusu biter).
  Dio get dio => _dio;

  /// Lisans dogrulama (X-Print-Key header ile)
  /// Backend: POST /api/print/validate
  Future<Map<String, dynamic>> validateApiKey(String apiKey) async {
    try {
      final response = await _dio.post(
        '/api/print/validate',
        options: Options(headers: {'X-Print-Key': apiKey}),
      );

      if (response.statusCode == 200 && response.data['valid'] == true) {
        return Map<String, dynamic>.from(response.data);
      }
      return {
        'valid': false,
        'error': response.data['error'] ?? 'Gecersiz API key',
      };
    } on DioException catch (e) {
      return {
        'valid': false,
        'error': e.response?.data?['error'] ?? e.message ?? 'Baglanti hatasi',
      };
    } catch (e) {
      return {'valid': false, 'error': e.toString()};
    }
  }

  /// Socket.io baglantisi icin kisa-sureli JWT
  Future<String?> getSocketToken() async {
    try {
      final response = await _dio.post('/api/print/socket-token');
      if (response.statusCode == 200 && response.data['token'] != null) {
        return response.data['token'].toString();
      }
      return null;
    } on DioException catch (_) {
      return null;
    }
  }

  /// Yazici listesi (admin panelden tanimli)
  Future<List<Map<String, dynamic>>> getPrinters() async {
    try {
      final response = await _dio.get('/api/print/printers');
      if (response.statusCode == 200 && response.data is List) {
        return List<Map<String, dynamic>>.from(
          (response.data as List).map((e) => Map<String, dynamic>.from(e)),
        );
      }
      return [];
    } on DioException catch (e) {
      print('[API] getPrinters hatasi: ${e.message}');
      return [];
    }
  }

  /// Son siparisler (gecmis ekrani — pagination)
  Future<List<Map<String, dynamic>>> getRecentOrders({int limit = 50, int offset = 0, String? status}) async {
    try {
      final response = await _dio.get('/api/print/orders/recent', queryParameters: {
        'limit': limit,
        'offset': offset,
        if (status != null) 'status': status,
      });
      if (response.statusCode == 200 && response.data is List) {
        return List<Map<String, dynamic>>.from(
          (response.data as List).map((e) => Map<String, dynamic>.from(e)),
        );
      }
      return [];
    } on DioException catch (e) {
      print('[API] getRecentOrders hatasi: ${e.message}');
      return [];
    }
  }

  /// 18 May 2026: Sipariş printer grouplari (POS print-kitchen pattern).
  /// Response: { ticket: {...}, printerGroups: [{printer_id, printer_name, printer_ip, printer_port, items[]}],
  ///             unassigned_items: [...] }
  /// Her group'u Flutter app ilgili yazıcıya gonderir. unassigned_items varsa uyari modal.
  /// [auto] true → backend kaynak-bazlı otomatik-yazdırma kapalıysa printerGroups
  /// BOŞ döner (skipped:'source_auto_print_off'). Otomatik akışta true, manuel reprint'te false.
  Future<Map<String, dynamic>?> getOrderPrintGroups(int orderId, {bool auto = false}) async {
    try {
      final response = await _dio.get(
        '/api/print/orders/$orderId/print-groups',
        queryParameters: {if (auto) 'auto': 1},
      );
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data);
      }
      return null;
    } on DioException catch (e) {
      print('[API] getOrderPrintGroups hatasi: ${e.message}');
      return null;
    }
  }

  /// 27 Haz 2026: SERVER-SIDE ESC/POS — sunucu hazir fis byte'i (base64) doner.
  /// Bayrak (server_side_receipt) aciksa kullanilir; null donerse caller eski
  /// generateOrderReceiptBytes()'a FALLBACK eder (mevcut davranis korunur).
  /// Donen: { groups: [{printer_id, printer_ip, printer_port, paper_width, escpos_base64, ...}], ... }
  Future<Map<String, dynamic>?> getOrderEscpos(int orderId,
      {int? printerId, int paperWidth = 80, String department = 'KASA'}) async {
    try {
      final qp = <String, dynamic>{'paper_width': paperWidth, 'department': department};
      if (printerId != null) qp['printer_id'] = printerId;
      final response = await _dio.get('/api/print/orders/$orderId/escpos', queryParameters: qp);
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data);
      }
      return null;
    } on DioException catch (e) {
      print('[API] getOrderEscpos hatasi (fallback eski render): ${e.message}');
      return null;
    }
  }

  /// 18 May 2026: order_number ile sipariş ara (WebSocket payload'da ID yoksa).
  /// Backend `/orders/recent` zaten order_number ile filtreliyor — sadece eşleseni döner.
  Future<Map<String, dynamic>?> findOrderByNumber(String orderNumber) async {
    try {
      final response = await _dio.get('/api/print/orders/recent', queryParameters: {
        'limit': 20,
      });
      if (response.statusCode == 200 && response.data is List) {
        final list = response.data as List;
        for (final r in list) {
          if (r is Map && (r['order_number']?.toString() == orderNumber)) {
            return Map<String, dynamic>.from(r);
          }
        }
      }
      return null;
    } on DioException catch (_) {
      return null;
    }
  }

  /// Tek siparis detayi
  Future<Map<String, dynamic>?> getOrder(int orderId) async {
    try {
      final response = await _dio.get('/api/print/orders/$orderId');
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data);
      }
      return null;
    } on DioException catch (e) {
      print('[API] getOrder hatasi: ${e.message}');
      return null;
    }
  }

  /// Yazici basariyla bastiktan sonra siparisi 'printed' isaretle
  Future<bool> markOrderPrinted(int orderId, {String? printerName}) async {
    try {
      final response = await _dio.post(
        '/api/print/orders/$orderId/mark-printed',
        data: {
          if (printerName != null) 'printer_name': printerName,
        },
      );
      return response.statusCode == 200 && response.data['success'] == true;
    } on DioException catch (e) {
      print('[API] markOrderPrinted hatasi: ${e.message}');
      return false;
    }
  }

  /// Yazici fail durumunda hata bildir
  Future<bool> reportPrintFailed(int orderId, {required String error, String? printerName}) async {
    try {
      final response = await _dio.post(
        '/api/print/orders/$orderId/report-print-failed',
        data: {
          'error': error,
          if (printerName != null) 'printer_name': printerName,
        },
      );
      return response.statusCode == 200;
    } on DioException catch (_) {
      return false;
    }
  }

  /// Sürüm bilgisi
  Future<Map<String, dynamic>?> getVersion() async {
    try {
      final response = await _dio.get('/api/print/version');
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data);
      }
      return null;
    } on DioException catch (_) {
      return null;
    }
  }

  // ==========================================================================
  // 28 Haz 2026 — MÜŞTERİ/ÖZET FİŞİ online HTML (TEK KAYNAK, build-siz)
  // Tasarim sunucuda (admin.js generateReceiptHTML + admin.css). Site degisince
  // bu HTML de degisir. Flutter printing paketi ile OS yazicisina basilir.
  // ==========================================================================

  /// Online ozet fis ayari: { print_summary: bool, summary_printer_id: int?, mode: 'html'|'escpos' }
  /// Backend /online-receipt-config (panel_settings online_order_print_summary + online_order_summary_printer_id).
  Future<Map<String, dynamic>?> getOnlineReceiptConfig() async {
    try {
      final response = await _dio.get('/api/print/online-receipt-config');
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data);
      }
      return null;
    } on DioException catch (e) {
      print('[API] getOnlineReceiptConfig hatasi: ${e.message}');
      return null;
    }
  }

  /// Siparisin ONLINE HTML fisini ham string olarak getir (standalone, CSS+JS inline).
  /// 29 Haz 2026: artik GERCEK CHROMIUM (WebView2) ile basilir → JS'li TAM HTML cekilir
  /// (static=1 KALDIRILDI). Sayfanin kendi JS'i QR'i ve formati kendisi uretir, biz CDP
  /// Page.printToPDF ile PDF aliriz. ?noprint=1 → backend otomatik window.print script'ini
  /// ATLAR (biz PDF alacagiz, yazici diyalogu/oto-print acilmasin). noprint VARSAYILAN true.
  Future<String?> getReceiptHtml(int orderId, {bool noprint = true}) async {
    try {
      final response = await _dio.get(
        '/api/print/orders/$orderId/receipt-html',
        queryParameters: {
          if (noprint) 'noprint': 1,
        },
        options: Options(responseType: ResponseType.plain),
      );
      if (response.statusCode == 200 && response.data is String) {
        return response.data as String;
      }
      return null;
    } on DioException catch (e) {
      print('[API] getReceiptHtml hatasi: ${e.message}');
      return null;
    }
  }

  /// 30 Haz 2026 — receipt-html ENDPOINT'inin TAM URL'i (WebView2 loadUrl icin).
  /// KÖK NEDEN FIX: loadData (NavigateToString) Windows'ta baseUrl'i yok sayar →
  /// null-origin about:blank + 2MB sinir → printToPDF BOS data. Cozum: HTML string'i
  /// hic tasima, WebView2'yi GERCEK HTTP URL'ine navigate ettir (gercek origin →
  /// CSS/JS/QR cozulur, 2MB sinir yok). Auth: backend print-app-auth ?key= query'i
  /// destekler (X-Print-Key header yerine — WebView2 navigation custom header gonderemez).
  /// MULTI-TENANT: base ApiService().baseUrl'den, key setup'tan — HARDCODED domain YOK.
  /// key bos ise null doner (caller eski HTML yoluna fallback eder).
  String? receiptHtmlUrl(int orderId, {bool noprint = true}) {
    final base = _baseUrl;
    final key = _apiKey;
    if (base.isEmpty || key == null || key.isEmpty) return null;
    final qp = <String>[
      'key=${Uri.encodeQueryComponent(key)}',
      if (noprint) 'noprint=1',
    ];
    return '$base/api/print/orders/$orderId/receipt-html?${qp.join('&')}';
  }

  /// Reconnect telafisi: basilmamis (printed_at NULL) son siparisler.
  /// auto=1 -> backend kaynak-bazli otomatik-yazdirma kapaliysa BOS doner (merkezi karar).
  Future<List<Map<String, dynamic>>> getUnprintedOrders({int windowMin = 120, bool auto = true}) async {
    try {
      final response = await _dio.get('/api/print/orders/recent', queryParameters: {
        'unprinted': 1,
        'window_min': windowMin,
        if (auto) 'auto': 1,
      });
      if (response.statusCode == 200 && response.data is List) {
        return List<Map<String, dynamic>>.from(
          (response.data as List).map((e) => Map<String, dynamic>.from(e)),
        );
      }
      return [];
    } on DioException catch (e) {
      print('[API] getUnprintedOrders hatasi: ${e.message}');
      return [];
    }
  }
}
