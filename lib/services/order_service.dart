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
  final LogService _log = LogService();
  final WebSocketService _ws = WebSocketService();
  final SoundService _sound = SoundService();
  final StorageService _storage = StorageService();
  final LocalDbService _db = LocalDbService();

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

  void start() {
    _ws.onNewOrder = (orderData) async {
      await _handleIncomingOrder(orderData);
    };
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

    // 3) Backend'den printer grouplari al + bas
    await _printOrderViaBackendGroups(orderId, orderNumber);
  }

  /// Manuel "Tekrar Yazdir" UI butonu
  Future<bool> reprintOrder(int orderId) async {
    final order = await _api.getOrder(orderId);
    if (order == null) {
      _log.error(LogType.error, 'Tekrar yazdir: sipariş yok', details: {'order_id': orderId});
      return false;
    }
    final orderNumber = order['order_number']?.toString() ?? '#?';
    return await _printOrderViaBackendGroups(orderId, orderNumber);
  }

  /// Sipariş yazdir — backend printer grouplari ile (POS print-kitchen pattern)
  Future<bool> _printOrderViaBackendGroups(int orderId, String orderNumber) async {
    // Backend'den printer grouplari al
    final data = await _api.getOrderPrintGroups(orderId);
    if (data == null) {
      _log.error(LogType.error, 'Printer grouplari alinamadi', details: {'order_id': orderId});
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
        List<int>? bytes;
        if (_storage.getServerSideReceipt()) {
          try {
            final esc = await _api.getOrderEscpos(orderId, printerId: printerId, paperWidth: 80, department: 'KASA');
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
        // Fallback / bayrak kapali: mevcut Flutter render (DEGISMEDI)
        bytes ??= await _printer.generateOrderReceiptBytes(partialTicket, 'KASA');
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
              'department': 'KASA',
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
            'department': 'KASA',
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

  int? _intOrNull(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
