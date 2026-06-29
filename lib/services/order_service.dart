// =============================================================================
// SyncResto Print — Sipariş Orkestratörü (v3)
// 18 May 2026 — POS print-kitchen pattern adaptasyonu
//
// Akış:
//   1) WebSocket'ten 'order-received' geldi
//   2) Ses cal (sound enabled ise)
//   3) UI listener'lari bilgilendir (kart listesi guncellensin)
//   4) Auto-print kapaliysa cik
//   5) Backend'den GET /print-groups (her item'in printer_id'sini grup haline getirir)
//   6) Her group icin: printerService.sendRawToIp(ip, port, bytes)
//      - Basariliysa backend mark-printed
//      - Basarisizsa lokal kuyruga ekle (PrintQueueService 5sn'de retry)
//   7) Hata varsa retry pop-up acil (UI listener)
//   8) unassigned_items varsa "X urunun yazicisi yok" uyari (UI listener)
//
// PANEL'DEN GELEN ROUTING — kategori/departman mapping YOK (panel_products.printer_id zaten var)
// =============================================================================

import 'dart:async';
import 'dart:convert'; // 27 Haz 2026: server-side ESC/POS base64 decode
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'printer_service.dart';
import 'html_print_service.dart'; // 29 Haz: özet fişi online HTML → ESC/POS raster
import 'log_service.dart';
import 'websocket_service.dart';
import 'sound_service.dart';
import 'storage_service.dart';
import 'local_db_service.dart';

class OrderService {
  static final OrderService _instance = OrderService._internal();
  factory OrderService() => _instance;
  OrderService._internal();

  final ApiService _api = ApiService();
  final PrinterService _printer = PrinterService();
  // 29 Haz 2026: özet fişi = online HTML → ESC/POS raster → IP:9100 (HtmlPrintService.buildEscposFromHtml)
  final HtmlPrintService _htmlPrint = HtmlPrintService();
  final LogService _log = LogService();
  final WebSocketService _ws = WebSocketService();
  final SoundService _sound = SoundService();
  final StorageService _storage = StorageService();
  final LocalDbService _db = LocalDbService();

  // 28 Haz 2026: çift-basım önleme — bu oturumda işlenen sipariş id'leri.
  // Reconnect telafisi ile WebSocket eventi aynı siparişi iki kez tetiklemesin.
  final Set<int> _processedOrderIds = <int>{};

  /// UI listener — yeni sipariş geldi (kart listesini yenile)
  final List<void Function(Map<String, dynamic>)> _onNewOrderListeners = [];
  void addOnNewOrderListener(void Function(Map<String, dynamic>) cb) => _onNewOrderListeners.add(cb);
  void removeOnNewOrderListener(void Function(Map<String, dynamic>) cb) => _onNewOrderListeners.remove(cb);

  /// UI listener — yazıcı fail oldu, retry pop-up göster
  /// payload: { orderId, orderNumber, failedGroups: [{printer_name, printer_ip, items}] }
  final List<void Function(Map<String, dynamic>)> _onPrintFailedListeners = [];
  void addOnPrintFailedListener(void Function(Map<String, dynamic>) cb) => _onPrintFailedListeners.add(cb);
  void removeOnPrintFailedListener(void Function(Map<String, dynamic>) cb) => _onPrintFailedListeners.remove(cb);

  /// UI listener — yazıcısı atanmamış ürünler (panel'de düzeltilmesi gerek)
  /// payload: { orderId, orderNumber, unassignedItems: [{product_name, quantity, ...}] }
  final List<void Function(Map<String, dynamic>)> _onUnassignedItemsListeners = [];
  void addOnUnassignedItemsListener(void Function(Map<String, dynamic>) cb) => _onUnassignedItemsListeners.add(cb);
  void removeOnUnassignedItemsListener(void Function(Map<String, dynamic>) cb) => _onUnassignedItemsListeners.remove(cb);

  bool _autoPrint = true;
  bool get autoPrint => _autoPrint;
  Future<void> setAutoPrint(bool v) async {
    _autoPrint = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_print', v);
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _autoPrint = prefs.getBool('auto_print') ?? true;
  }

  // 29 Haz 2026: İlk bağlantı mı? Program AÇILIRKEN geçmiş (basılmamış) siparişler
  // çekilip işlenmesin (Mustafa: "açılışta geçmişi boşver, sonra gelenler yazılsın").
  // Sadece program açıldıktan SONRA socket kopup yeniden bağlanırsa telafi yapılır.
  bool _firstConnect = true;

  void start() {
    _ws.onNewOrder = (orderData) async {
      await _handleIncomingOrder(orderData);
    };
    // 28 Haz 2026: socket bağlanınca kaçan siparişleri telafi et.
    // 29 Haz 2026: İLK bağlantıda (program açılışı) telafi YAPMA — geçmiş atlanır.
    // Açılışta var olan tüm açık siparişler _processedOrderIds'e eklenir (bir daha basılmaz).
    _ws.onReconnected = () async {
      if (_firstConnect) {
        _firstConnect = false;
        await _seedProcessedFromHistory();   // geçmişi "işlendi" say, basma
        return;
      }
      await printMissedOrders();             // gerçek reconnect → kaçanları telafi et
    };
  }

  /// 29 Haz 2026: Program açılışında var olan basılmamış siparişleri "işlendi" olarak
  /// işaretle (basMA). Böylece açılış-anı geçmişi atlanır; bundan SONRA gelen yeni
  /// siparişler normal işlenir. Reconnect telafisi de bunları tekrar çekmez.
  Future<void> _seedProcessedFromHistory() async {
    try {
      final existing = await _api.getUnprintedOrders(windowMin: 240);
      for (final o in existing) {
        final id = _intOrNull(o['id']);
        if (id != null) _processedOrderIds.add(id);
      }
      _log.logAction('Açılış: ${existing.length} geçmiş sipariş atlandı (sadece bundan sonrakiler basılır)');
    } catch (e) {
      _log.warning(LogType.action, 'Açılış geçmiş atlama hatasi: $e');
    }
  }

  /// Yeni sipariş geldi
  Future<void> _handleIncomingOrder(Map<String, dynamic> orderData) async {
    var orderId = _intOrNull(orderData['id']);
    final orderNumber = orderData['order_number']?.toString() ?? '#?';

    _log.logAction('Yeni online sipariş: $orderNumber', details: {
      'order_id': orderId,
      'source': orderData['source'],
      'auto_print': _autoPrint,
    });

    // 1) Ses cal
    await _sound.playNewOrder();

    // 2) UI listenerlari bilgilendir (sipariş geldi popup/snackbar)
    for (final cb in List.of(_onNewOrderListeners)) {
      try { cb(orderData); } catch (_) {}
    }

    if (!_autoPrint) {
      _log.warning(LogType.action, 'Otomatik yazdırma KAPALI', details: {'order_id': orderId});
      return;
    }

    // 18 May 2026: WebSocket payload bazen sadece order_number gonderir (ID yok).
    // O zaman recent endpoint'inden bulmaya calis.
    if (orderId == null && orderNumber != '#?' && orderNumber.isNotEmpty) {
      _log.logAction('ID yok, order_number ile aranıyor: $orderNumber');
      final found = await _api.findOrderByNumber(orderNumber);
      if (found != null) {
        orderId = _intOrNull(found['id']);
        _log.logAction('Bulundu: id=$orderId');
      }
    }

    if (orderId == null) {
      _log.error(LogType.error, 'Sipariş ID bulunamadi, basilamiyor', details: {'order_data': orderData});
      return;
    }

    // Çift-basım önleme: bu sipariş bu oturumda zaten işlendiyse atla
    // (WebSocket eventi + reconnect telafisi aynı siparişi iki kez tetikleyebilir).
    if (_processedOrderIds.contains(orderId)) {
      _log.logAction('Sipariş zaten işlendi, atlandi (çift-basım önleme): $orderNumber');
      return;
    }
    _processedOrderIds.add(orderId);

    // 3) Backend'den printer grouplari al + bas (mutfak ESC/POS + müşteri HTML özet)
    await _printOrderViaBackendGroups(orderId, orderNumber);
  }

  // ==========================================================================
  // 28 Haz 2026 — RECONNECT TELAFİSİ
  // Socket koptuğunda kaçan siparişleri çek + bas. websocket_service onConnect'te
  // (yeniden bağlanınca) çağrılır. Backend /orders/recent?unprinted=1 (printed_at NULL).
  // auto=1 → kaynak-bazlı otomatik-yazdırma kapalıysa backend boş döner (merkezi karar).
  // Çift-basım: _processedOrderIds + backend printed_at kontrolü.
  // ==========================================================================
  Future<void> printMissedOrders() async {
    if (!_autoPrint) return;
    try {
      final missed = await _api.getUnprintedOrders(windowMin: 120);
      if (missed.isEmpty) return;
      _log.logAction('Reconnect telafisi: ${missed.length} basılmamış sipariş bulundu');
      for (final o in missed) {
        final id = _intOrNull(o['id']);
        final no = o['order_number']?.toString() ?? '#?';
        if (id == null) continue;
        if (_processedOrderIds.contains(id)) continue;
        _processedOrderIds.add(id);
        await _printOrderViaBackendGroups(id, no);
      }
    } catch (e) {
      _log.warning(LogType.action, 'Reconnect telafisi hatasi: $e');
    }
  }

  /// Manuel "Tekrar Yazdir" UI butonu — kaynak-bazlı otomatik kontrolü BYPASS et
  /// (kullanıcı bilerek bastırıyor, kapalı kaynak olsa bile bassın).
  Future<bool> reprintOrder(int orderId) async {
    final order = await _api.getOrder(orderId);
    if (order == null) {
      _log.error(LogType.error, 'Tekrar yazdir: sipariş yok', details: {'order_id': orderId});
      return false;
    }
    final orderNumber = order['order_number']?.toString() ?? '#?';
    return await _printOrderViaBackendGroups(orderId, orderNumber, auto: false);
  }

  /// Sipariş yazdir — backend printer grouplari ile (POS print-kitchen pattern).
  /// [auto] true → kaynak-bazlı otomatik-yazdırma kontrolü uygulanır (kapalı kaynak basılmaz).
  Future<bool> _printOrderViaBackendGroups(int orderId, String orderNumber, {bool auto = true}) async {
    // Backend'den printer grouplari al (auto=1 → kapalı kaynak boş döner)
    final data = await _api.getOrderPrintGroups(orderId, auto: auto);
    if (data == null) {
      _log.error(LogType.error, 'Printer grouplari alinamadi', details: {'order_id': orderId});
      return false;
    }

    // Kaynak-bazlı otomatik-yazdırma kapalı → backend boş döndü, basma (merkezi karar).
    if (data['skipped'] == 'source_auto_print_off') {
      _log.logAction('Otomatik yazdırma bu kaynak için kapalı (panel #pos-printers): $orderNumber');
      return false;
    }

    final ticket = (data['ticket'] as Map?)?.cast<String, dynamic>() ?? {};
    final printerGroups = (data['printerGroups'] as List?) ?? [];
    final unassignedItems = (data['unassigned_items'] as List?) ?? [];

    // Atanmamış ürünler — Mustafa kuralı: SADECE uyarı, default fallback YOK.
    // Kullanıcı panelden eşleştirmeyi kendisi yapsın (yanlış yazıcıya basma riski daha kötü).
    if (unassignedItems.isNotEmpty) {
      _log.warning(LogType.action,
        'Yazıcısı atanmamış ürün: ${unassignedItems.length} adet (sipariş $orderNumber) — '
        'panel → Ürün Eşleştirme sayfasından eşleştirilmesi gerek',
        details: {'order_id': orderId, 'count': unassignedItems.length}
      );
      for (final cb in List.of(_onUnassignedItemsListeners)) {
        try {
          cb({
            'orderId': orderId,
            'orderNumber': orderNumber,
            'unassignedItems': unassignedItems,
          });
        } catch (_) {}
      }
    }

    if (printerGroups.isEmpty) {
      _log.warning(LogType.action, 'Yazdırılacak grup yok (tüm ürün unassigned)', details: {'order_id': orderId});
      return false;
    }

    int successCount = 0;
    final List<Map<String, dynamic>> failedGroups = [];

    // Her group icin yazıcıya bas
    for (final group in printerGroups) {
      if (group is! Map) continue;
      final g = group.cast<String, dynamic>();
      final printerId = _intOrNull(g['printer_id']);
      final printerName = g['printer_name']?.toString();
      final ip = g['printer_ip']?.toString() ?? '';
      final port = _intOrNull(g['printer_port']) ?? 9100;
      final groupItems = (g['items'] as List?) ?? [];

      if (ip.isEmpty || groupItems.isEmpty) {
        _log.warning(LogType.action, 'Group atlandi: ip=$ip items=${groupItems.length}');
        continue;
      }

      // Bu group'a ozel kismi sipariş (sadece bu yazıcının itemlari)
      final partialTicket = Map<String, dynamic>.from(ticket);
      partialTicket['items'] = groupItems;
      partialTicket['_print_printer'] = printerName ?? '';

      try {
        // 27 Haz 2026: SERVER-SIDE ESC/POS (bayrak aciksa). Sunucudan hazir byte cek;
        // null/hata -> mevcut Flutter render'a FALLBACK (davranis birebir korunur).
        // 29 Haz 2026 — MUTFAK fişi: ürün-bazlı yazıcı → 'MUTFAK' departmanı (Flutter POS BİREBİR:
        // sadece ürün+ekstra+çıkarılan+not, fiyat/toplam/ödeme YOK). Eskiden 'KASA' idi → mutfak
        // fişinde de toplam çıkıyordu (yanlış). Özet/müşteri fişi AYRI (online HTML, aşağıda).
        List<int>? bytes;
        if (_storage.getServerSideReceipt()) {
          try {
            final esc = await _api.getOrderEscpos(orderId, printerId: printerId, paperWidth: 80, department: 'MUTFAK');
            final groups = (esc?['groups'] as List?) ?? [];
            // Bu yaziciya ait grubu bul (printer_id ile); yoksa tek grup varsa onu al.
            Map<String, dynamic>? mg;
            for (final x in groups) {
              if (x is Map && _intOrNull(x['printer_id']) == printerId) { mg = x.cast<String, dynamic>(); break; }
            }
            mg ??= (groups.length == 1 && groups.first is Map) ? (groups.first as Map).cast<String, dynamic>() : null;
            final b64 = mg?['escpos_base64']?.toString();
            if (b64 != null && b64.isNotEmpty) {
              bytes = base64Decode(b64);
              _log.logAction('Server-side ESC/POS kullanildi: $orderNumber → $printerName');
            }
          } catch (e) {
            _log.warning(LogType.action, 'Server-side ESC/POS alinamadi, eski render fallback: $e');
          }
        }
        // Fallback / bayrak kapali: Flutter render — MUTFAK departmanı (sade)
        bytes ??= await _printer.generateOrderReceiptBytes(partialTicket, 'MUTFAK');
        final ok = await _printer.sendRawToIp(ip, port, bytes);
        if (ok) {
          successCount++;
          _log.logAction('Yazdırıldı: $orderNumber → $printerName ($ip)');
        } else {
          // Lokal kuyruga ekle (PrintQueueService 5sn'de retry)
          await _db.addJob(
            printType: 'order',
            orderId: orderId,
            orderNumber: orderNumber,
            printerId: printerId,
            printerName: printerName,
            printerIp: ip,
            printerPort: port,
            receiptData: {
              'order': partialTicket,
              'department': 'MUTFAK',
            },
          );
          failedGroups.add({
            'printer_id': printerId,
            'printer_name': printerName,
            'printer_ip': ip,
            'items': groupItems,
          });
          _log.warning(LogType.error, '$orderNumber → $printerName BASAMADI, kuyruğa eklendi');
        }
      } catch (e) {
        _log.error(LogType.error, 'Yazdırma exception: $e', details: {'order_id': orderId});
        await _db.addJob(
          printType: 'order',
          orderId: orderId,
          orderNumber: orderNumber,
          printerId: printerId,
          printerName: printerName,
          printerIp: ip,
          printerPort: port,
          receiptData: {
            'order': partialTicket,
            'department': 'MUTFAK',
          },
        );
        failedGroups.add({
          'printer_id': printerId,
          'printer_name': printerName,
          'printer_ip': ip,
          'items': groupItems,
          'error': e.toString(),
        });
      }
    }

    // 28 Haz 2026: MÜŞTERİ/ÖZET FİŞİ (online HTML). Mutfak ürün fişlerinden AYRI.
    // panel #pos-printers "Özet Fiş Yazıcısı" (online_order_summary_printer_id) +
    // online_order_print_summary='1' ise basılır. Mutfak ESC/POS akışı etkilenmez.
    await _printCustomerSummaryHtml(orderId, orderNumber);

    // Backend mark — en az 1 başarılıysa
    if (successCount > 0) {
      await _api.markOrderPrinted(orderId);
    }
    if (failedGroups.isNotEmpty) {
      await _api.reportPrintFailed(orderId, error: '${failedGroups.length} yazıcı basamadı');
      // UI'ya bildir (retry modal)
      for (final cb in List.of(_onPrintFailedListeners)) {
        try {
          cb({
            'orderId': orderId,
            'orderNumber': orderNumber,
            'failedGroups': failedGroups,
          });
        } catch (_) {}
      }
    }

    return successCount > 0;
  }

  /// İptal fişi yaz (POS pattern). data: { product_name, quantity, order_number, customer_name, reason, notes }
  /// Yazıcı: panel'den product → printer eşleştirmesi varsa o, yoksa fallback default
  Future<bool> printCancelItem(Map<String, dynamic> data) async {
    final productName = (data['product_name'] ?? '').toString();
    if (productName.isEmpty) return false;

    // Yazıcıyı bul: ya data.printer_ip verilmiş, ya da getPrinters'tan default
    String? ip = data['printer_ip']?.toString();
    int port = _intOrNull(data['printer_port']) ?? 9100;
    int? printerId = _intOrNull(data['printer_id']);
    String? printerName = data['printer_name']?.toString();

    if (ip == null || ip.isEmpty) {
      // Default printer fallback
      final defaultId = _storage.getDefaultPrinterId();
      if (defaultId != null) {
        final printers = await _api.getPrinters();
        final p = printers.firstWhere(
          (x) => _intOrNull(x['id']) == defaultId,
          orElse: () => <String, dynamic>{},
        );
        if (p.isNotEmpty) {
          ip = (p['ip_address'] ?? p['ip'] ?? '').toString();
          port = (p['port'] is int) ? p['port'] as int : (int.tryParse('${p['port']}') ?? 9100);
          printerId = defaultId;
          printerName = p['name']?.toString();
        }
      }
    }

    if (ip == null || ip.isEmpty) {
      _log.error(LogType.error, 'İptal fişi yazıcı yok', details: {'data': data});
      return false;
    }

    final bytes = await _printer.generateCancelReceiptBytes({
      ...data,
      'time': DateTime.now().toIso8601String(),
    });

    final ok = await _printer.sendRawToIp(ip, port, bytes);
    if (!ok) {
      await _db.addJob(
        printType: 'cancel',
        orderId: _intOrNull(data['order_id']),
        orderNumber: data['order_number']?.toString(),
        printerId: printerId,
        printerName: printerName,
        printerIp: ip,
        printerPort: port,
        receiptData: data,
      );
    }
    return ok;
  }

  // ==========================================================================
  // 28 Haz 2026 — MÜŞTERİ/ÖZET FİŞİ (online HTML, TEK KAYNAK)
  // Tasarım = onlinedeki HTML (backend /orders/:id/receipt-html → admin.js
  // generateReceiptHTML + admin.css). printing paketi ile OS yazıcısına basar.
  // Yazıcı = panel "Özet Fiş Yazıcısı" (online_order_summary_printer_id) ↔ lokal
  // eşleştirilmiş OS yazıcı adı. İZOLE: mutfak ESC/POS akışına dokunmaz.
  // ==========================================================================
  // 29 Haz 2026 — ÖZET/MÜŞTERİ FİŞİ: artık IP:9100 ESC/POS (mutfak gibi ham TCP).
  // Eskiden HTML→OS yazıcı sürücüsüydü ama özet yazıcısı AĞ termali (IP:9100) ve OS
  // eşleştirmesi gerekiyordu → otomatik basamıyordu. Çözüm: özet yazıcısının IP'sine
  // doğrudan ESC/POS özet fişi (KASA departmanı: ürünler + toplam + ödeme). Eşleştirme YOK.
  Future<void> _printCustomerSummaryHtml(int orderId, String orderNumber) async {
    try {
      final cfg = await _api.getOnlineReceiptConfig();
      // Özet fişi kapalıysa hiç basma (panel ayarı)
      if (cfg == null || cfg['print_summary'] != true) return;

      final sp = cfg['summary_printer'];
      if (sp is! Map) {
        _log.warning(LogType.action,
          'Özet fişi açık ama "Özet Fiş Yazıcısı" seçili/aktif değil (panel #pos-printers) — atlandi',
          details: {'order_id': orderId});
        return;
      }
      final ip = (sp['ip_address'] ?? sp['ip'] ?? '').toString();
      final port = _intOrNull(sp['port']) ?? 9100;
      final printerName = sp['name']?.toString() ?? 'Özet Yazıcı';
      if (ip.isEmpty) {
        _log.warning(LogType.action, 'Özet yazıcı IP yok: $printerName', details: {'order_id': orderId});
        return;
      }

      // 29 Haz 2026 — ÖZET FİŞİ = SİTEDEKİ ÖZEL HTML (BİREBİR). Backend /orders/:id/receipt-html
      // (admin.js generateReceiptHTML + admin.css + QR, TEK KAYNAK). HTML → görsel → ESC/POS raster
      // → AĞ termaline IP:9100 (OS yazıcı eşleştirme YOK). Mutfak fişinden TAMAMEN farklı tasarım.
      // JS'li TAM HTML (static KALDIRILDI): gerçek Chromium/WebView2 sayfanın JS'ini çalıştırır,
      // QR'ı kendi üretir. noprint=1 → otomatik window.print tetiklenmesin (PDF'i biz CDP ile alırız).
      final html = await _api.getReceiptHtml(orderId, noprint: true);
      if (html == null || html.isEmpty) {
        _log.warning(LogType.action, 'Özet HTML fişi alinamadi: $orderNumber', details: {'order_id': orderId});
        return;
      }
      final bytes = await _htmlPrint.buildEscposFromHtml(html);
      if (bytes == null || bytes.isEmpty) {
        _log.warning(LogType.error, 'Özet HTML→ESC/POS raster üretilemedi: $orderNumber', details: {'order_id': orderId});
        return;
      }
      final ok = await _printer.sendRawToIp(ip, port, bytes);
      if (ok) {
        _log.logAction('Müşteri özet fişi (online HTML) basildi: $orderNumber → $printerName ($ip)');
      } else {
        // Başarısız → lokal kuyruğa (raw ESC/POS byte ile retry)
        await _db.addJob(
          printType: 'raw',
          orderId: orderId,
          orderNumber: orderNumber,
          printerId: _intOrNull(sp['id']),
          printerName: printerName,
          printerIp: ip,
          printerPort: port,
          receiptData: { 'raw_base64': base64Encode(bytes) },
        );
        _log.warning(LogType.error, 'Özet fişi BASILAMADI, kuyruğa eklendi: $orderNumber → $printerName ($ip)',
          details: {'order_id': orderId});
      }
    } catch (e) {
      _log.error(LogType.error, 'Özet fişi hatasi: $e', details: {'order_id': orderId});
    }
  }

  int? _intOrNull(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
