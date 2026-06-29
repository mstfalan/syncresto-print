import 'dart:io';
import 'dart:async';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

import 'log_service.dart';
import 'storage_service.dart';

/// SyncResto Print — ESC/POS termal yazici servisi.
/// Fis formati: SyncResto POS v1.3.6 `_generateOrderReceipt` ile birebir aynı
/// (POS'ta sahada test edilmis, kasa/mutfak yazicilariyla uyumlu).
class PrinterService {
  static final PrinterService _instance = PrinterService._internal();
  factory PrinterService() => _instance;
  PrinterService._internal();

  final LogService _log = LogService();

  // Aktif yazici (UI'dan secilen)
  Map<String, dynamic>? _selectedPrinter;
  Map<String, dynamic>? get selectedPrinter => _selectedPrinter;
  void setSelectedPrinter(Map<String, dynamic>? p) {
    _selectedPrinter = p;
  }

  /// Güvenli sayı dönüşümü. PostgreSQL numeric kolonları JSON'da STRING gelir
  /// ("320.00") → 'as num' cast patlıyordu (type 'String' is not a subtype of
  /// type 'num' in type cast). num, String, null hepsini güvenli işler.
  static double _toDouble(dynamic v, {double fallback = 0}) {
    if (v == null) return fallback;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim().replaceAll(',', '.')) ?? fallback;
    return fallback;
  }

  /// Online sipariş fişi yazdır.
  /// [printers] verilirse o yazıcılara, yoksa _selectedPrinter'a gönderir.
  /// [department] = 'KASA' ise totals/odeme dahil; 'MUTFAK' ise sadece urun listesi.
  Future<bool> printOrderReceipt(
    Map<String, dynamic> order, {
    List<Map<String, dynamic>>? printers,
    String department = 'KASA',
  }) async {
    final targets = <Map<String, dynamic>>[];
    if (printers != null && printers.isNotEmpty) {
      targets.addAll(printers);
    } else if (_selectedPrinter != null) {
      targets.add(_selectedPrinter!);
    } else {
      print('[Printer] Yazici secilmemis');
      _log.error(LogType.error, 'Yazici secilmemis — siparis basilmadi', details: {'order_number': order['order_number']});
      return false;
    }

    final bytes = await _generateOrderReceipt(order, department);

    int successCount = 0;
    for (final p in targets) {
      final ip = (p['ip_address'] ?? p['ip'] ?? '').toString();
      final port = (p['port'] is int ? p['port'] as int : int.tryParse('${p['port']}') ?? 9100);
      if (ip.isEmpty) continue;

      final ok = await _sendToPrinter(ip, port, bytes);
      if (ok) {
        successCount++;
        _log.logAction('Siparis fisi basildi', details: {
          'printer_name': p['name'],
          'printer_ip': ip,
          'order_number': order['order_number'],
        });
      } else {
        _log.error(LogType.error, 'Siparis fisi yazdirilamadi', details: {
          'printer_name': p['name'],
          'printer_ip': ip,
          'order_number': order['order_number'],
        });
      }
    }
    return successCount > 0;
  }

  /// Tek yaziciya bayt gonderme (TCP/IP port 9100). v1.2.0 davranisi (basit + saglam).
  Future<bool> _sendToPrinter(String ip, int port, List<int> bytes) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
      socket.add(bytes);
      await socket.flush();
      await Future.delayed(const Duration(milliseconds: 300));
      await socket.close();
      return true;
    } catch (e) {
      print('[Printer] $ip:$port baglanti hatasi: $e');
      try { socket?.destroy(); } catch (_) {}
      return false;
    }
  }

  /// 18 May 2026: PrintQueueService icin public wrapper'lar.
  /// _generateOrderReceipt ve _sendToPrinter private — kuyruk servisi de cagirabilsin.
  Future<List<int>> generateOrderReceiptBytes(Map<String, dynamic> order, String department) {
    return _generateOrderReceipt(order, department);
  }

  Future<bool> sendRawToIp(String ip, int port, List<int> bytes) {
    return _sendToPrinter(ip, port, bytes);
  }

  /// Iptal fisi (POS pattern — printCancelItem)
  /// data: { product_name, quantity, customer_name, reason, time, notes }
  Future<List<int>> generateCancelReceiptBytes(Map<String, dynamic> data) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];

    final brandName = _turkishToAscii(StorageService().getRestaurantName() ?? 'SYNCRESTO');
    final productName = _turkishToAscii((data['product_name'] ?? '').toString());
    final quantity = data['quantity'] ?? 1;
    final customerName = _turkishToAscii((data['customer_name'] ?? '').toString());
    final reason = _turkishToAscii((data['reason'] ?? 'Belirtilmedi').toString());
    final time = data['time']?.toString() ?? _formatDate(DateTime.now().toIso8601String());
    final notes = _turkishToAscii((data['notes'] ?? '').toString());
    final orderNumber = data['order_number']?.toString() ?? '';

    bytes += generator.text('** IPTAL URUN **',
      styles: const PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2, width: PosTextSize.size2));
    bytes += generator.feed(1);
    bytes += generator.text(brandName.toUpperCase(),
      styles: const PosStyles(align: PosAlign.center, bold: true));
    bytes += generator.hr(ch: '=');

    if (orderNumber.isNotEmpty) {
      bytes += generator.text('SIPARIS: #$orderNumber', styles: const PosStyles(bold: true));
    }
    bytes += generator.text('Tarih: $time');
    bytes += generator.hr();

    if (customerName.isNotEmpty) {
      bytes += generator.text('Musteri: $customerName');
    }
    bytes += generator.feed(1);

    bytes += generator.text('$quantity x $productName',
      styles: const PosStyles(bold: true, height: PosTextSize.size2));
    bytes += generator.feed(1);

    bytes += generator.text('SEBEP: $reason', styles: const PosStyles(bold: true));
    if (notes.isNotEmpty) {
      bytes += generator.text('Not: $notes');
    }
    bytes += generator.hr(ch: '=');
    bytes += generator.text('LUTFEN URUNU HAZIRLAMAYIN',
      styles: const PosStyles(align: PosAlign.center, bold: true));
    bytes += generator.feed(3);
    bytes += generator.cut();
    return bytes;
  }

  /// Test fişi (Yazıcı Ayarları'ndaki "Test Et" butonu)
  Future<bool> testPrint(String ip, int port) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];
    bytes += generator.text('** SYNCRESTO PRINT **',
      styles: const PosStyles(align: PosAlign.center, bold: true, height: PosTextSize.size2));
    bytes += generator.feed(1);
    bytes += generator.text('Test fisi', styles: const PosStyles(align: PosAlign.center));
    bytes += generator.text(_formatDate(DateTime.now().toIso8601String()),
      styles: const PosStyles(align: PosAlign.center));
    bytes += generator.feed(2);
    bytes += generator.text('Yazici: $ip:$port', styles: const PosStyles(align: PosAlign.center));
    bytes += generator.feed(3);
    bytes += generator.cut();
    return await _sendToPrinter(ip, port, bytes);
  }

  // ===========================================================================
  // FIS FORMATI — SyncResto POS v1.3.6 _generateOrderReceipt birebir kopya
  // ===========================================================================

  Future<List<int>> _generateOrderReceipt(Map<String, dynamic> order, String department) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm80, profile);
    List<int> bytes = [];

    // ===== HEADER =====
    // Multi-tenant: brand_name oncelikle order._settings'ten (backend gondermisse),
    // yoksa giris yapan tenant'in storage'da kayitli adi, son fallback 'SYNCRESTO'.
    final settings = order['_settings'] as Map<String, dynamic>?;
    final tenantName = StorageService().getRestaurantName();
    final brandName = _turkishToAscii(
      (settings?['brand_name'] as String?) ?? tenantName ?? 'SYNCRESTO',
    );
    final contactPhone = settings?['contact_phone'] ?? '';

    bytes += generator.text(
      brandName.toUpperCase(),
      styles: const PosStyles(
        align: PosAlign.center,
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
      ),
    );
    if (contactPhone.toString().isNotEmpty) {
      bytes += generator.text(
        'Tel: $contactPhone',
        styles: const PosStyles(align: PosAlign.center),
      );
    }
    bytes += generator.hr(ch: '=');

    // ===== ORDER INFO =====
    final orderNumber = order['order_number'] ?? order['ticket_number'] ?? '';
    bytes += generator.text(
      'SIPARIS: #$orderNumber',
      styles: const PosStyles(bold: true),
    );
    bytes += generator.text('Tarih: ${_formatDate(order['created_at']?.toString())}');

    // Kanal etiketi (web/getir/trendyol vb.)
    final source = order['source']?.toString() ?? '';
    if (source.isNotEmpty) {
      bytes += generator.text(_turkishToAscii('Kaynak: ${_sourceLabel(source)}'),
        styles: const PosStyles(bold: true));
    }
    bytes += generator.hr();

    // ===== CUSTOMER INFO =====
    bytes += generator.text(
      'MUSTERI BILGILERI',
      styles: const PosStyles(bold: true),
    );

    final customerName = _turkishToAscii(order['customer_name']?.toString() ?? 'Misafir');
    bytes += generator.text(customerName);

    if (order['customer_phone'] != null && order['customer_phone'].toString().isNotEmpty) {
      bytes += generator.text('Tel: ${order['customer_phone']}');
    }

    if (order['customer_address'] != null && order['customer_address'].toString().isNotEmpty) {
      bytes += generator.text(_turkishToAscii(order['customer_address'].toString()));
    }

    if (order['courier_notes'] != null && order['courier_notes'].toString().isNotEmpty) {
      bytes += generator.text('Not: ${_turkishToAscii(order['courier_notes'].toString())}');
    }

    if (order['notes'] != null && order['notes'].toString().isNotEmpty) {
      bytes += generator.text('Siparis Notu: ${_turkishToAscii(order['notes'].toString())}');
    }
    bytes += generator.hr();

    // ===== PRODUCTS =====
    bytes += generator.text(
      'URUNLER',
      styles: const PosStyles(bold: true),
    );

    final items = order['items'] as List? ?? [];
    for (final item in items) {
      if (item is! Map) continue;
      final name = _turkishToAscii(
        (item['product_name'] ?? item['name'] ?? '').toString(),
      );
      final qty = item['quantity'] ?? 1;

      // Urun adi kalin ve buyuk (fiyat yok — POS davranisi)
      bytes += generator.text(
        '$qty x $name',
        styles: const PosStyles(
          bold: true,
          height: PosTextSize.size2,
        ),
      );

      // Extras
      if (item['extras'] != null && (item['extras'] as List).isNotEmpty) {
        for (final extra in item['extras']) {
          if (extra is Map) {
            final exName = (extra['name'] ?? '').toString();
            final exVal = (extra['value_name'] ?? extra['value'] ?? '').toString();
            final txt = exVal.isEmpty ? exName : (exName.isEmpty ? exVal : '$exName: $exVal');
            bytes += generator.text('  + ${_turkishToAscii(txt)}');
          } else {
            bytes += generator.text('  + ${_turkishToAscii(extra.toString())}');
          }
        }
      }

      // Options (Getir/marketplace alternatifi)
      if (item['options'] != null && (item['options'] as List).isNotEmpty) {
        for (final opt in item['options']) {
          bytes += generator.text('  + ${_turkishToAscii(opt.toString())}');
        }
      }

      // Notes
      final note = (item['notes'] ?? item['note'] ?? '').toString();
      if (note.isNotEmpty) {
        bytes += generator.text(
          '  >>> ${_turkishToAscii(note)} <<<',
          styles: const PosStyles(bold: true),
        );
      }

      bytes += generator.text(''); // Bosluk
    }
    bytes += generator.hr();

    // ===== TOTALS (sadece KASA fişinde) =====
    final isKasa = department.toUpperCase() == 'KASA';
    if (isKasa) {
      final subtotal = _toDouble(order['subtotal']);
      final deliveryFee = _toDouble(order['delivery_fee']);
      final discountAmount = _toDouble(order['discount_amount'] ?? order['discount']);
      final total = _toDouble(order['total'], fallback: subtotal);

      if (subtotal > 0) {
        bytes += generator.row([
          PosColumn(text: 'Ara Toplam:', width: 8),
          PosColumn(
            text: '${subtotal.toStringAsFixed(2)} TL',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      if (deliveryFee > 0) {
        bytes += generator.row([
          PosColumn(text: 'Teslimat:', width: 8),
          PosColumn(
            text: '${deliveryFee.toStringAsFixed(2)} TL',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      if (discountAmount > 0) {
        bytes += generator.row([
          PosColumn(text: 'Indirim:', width: 8),
          PosColumn(
            text: '-${discountAmount.toStringAsFixed(2)} TL',
            width: 4,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]);
      }

      bytes += generator.hr();
      bytes += generator.row([
        PosColumn(
          text: 'TOPLAM:',
          width: 6,
          styles: const PosStyles(bold: true, height: PosTextSize.size2),
        ),
        PosColumn(
          text: '${total.toStringAsFixed(2)} TL',
          width: 6,
          styles: const PosStyles(
            align: PosAlign.right,
            bold: true,
            height: PosTextSize.size2,
          ),
        ),
      ]);

      // Ödeme yöntemi — 29 Haz 2026: pazaryeri HAM Türkçe etiketi ("Online Kredi/Banka Kartı")
      // _paymentMethodLabel default'unda aynen dönüyordu; ı/Ö karakteri ESC/POS'u patlatıyordu
      // ("Invalid argument: Contains invalid characters"). _turkishToAscii ZORUNLU.
      final paymentMethod = order['payment_method'];
      if (paymentMethod != null && paymentMethod.toString().isNotEmpty) {
        bytes += generator.hr();
        bytes += generator.text(
          _turkishToAscii('Odeme: ${_paymentMethodLabel(paymentMethod.toString())}'),
          styles: const PosStyles(align: PosAlign.center, bold: true),
        );
      }
    }

    // ===== FOOTER =====
    bytes += generator.hr(ch: '=');
    bytes += generator.text(
      'Afiyet olsun!',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.text(
      'SyncResto POS',
      styles: const PosStyles(align: PosAlign.center),
    );

    bytes += generator.feed(3);
    bytes += generator.cut();

    return bytes;
  }

  // ===========================================================================
  // HELPERS — POS ile birebir
  // ===========================================================================

  // 29 Haz 2026 — ESC/POS yalnızca ASCII/CP437 basabilir. Türkçe + tüm non-ASCII
  // karakterler "Invalid argument: Contains invalid characters" hatası veriyordu
  // (örn pazaryeri ham etiketi "Online Kredi/Banka Kartı"). GÜVENLİ HALE GETİR:
  // bilinen Türkçe → ASCII karşılığı, kalan tüm ASCII-dışı karakteri sadeleştir/at.
  String _turkishToAscii(String text) {
    if (text.isEmpty) return text;
    const turkishChars = 'ÇçĞğİıÖöŞşÜü';
    const asciiChars   = 'CcGgIiOoSsUu';
    String result = text;
    for (int i = 0; i < turkishChars.length; i++) {
      result = result.replaceAll(turkishChars[i], asciiChars[i]);
    }
    // Yaygın non-ASCII semboller → ASCII eşdeğeri
    result = result
        .replaceAll('₺', 'TL')
        .replaceAll('’', "'").replaceAll('‘', "'")
        .replaceAll('“', '"').replaceAll('”', '"')
        .replaceAll('—', '-').replaceAll('–', '-')
        .replaceAll('…', '...')
        .replaceAll(' ', ' '); // non-breaking space
    // Kalan TÜM ASCII-dışı (kod > 126) karakterleri at — yazıcı patlamasın (garanti).
    final sb = StringBuffer();
    for (final cu in result.codeUnits) {
      if (cu >= 32 && cu <= 126) sb.writeCharCode(cu);
      else if (cu == 10 || cu == 13) sb.writeCharCode(cu); // satır sonu koru
      // diğer her şey (kalan Türkçe/emoji/kontrol) → atla
    }
    return sb.toString();
  }

  String _formatDate(String? isoDate) {
    if (isoDate == null || isoDate.isEmpty) return '';
    try {
      final dt = DateTime.parse(isoDate).toLocal();
      return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return isoDate;
    }
  }

  String _paymentMethodLabel(String method) {
    switch (method) {
      case 'cash':
        return 'Nakit';
      case 'card':
        return 'Kredi Karti';
      case 'multinet':
        return 'Multinet';
      case 'sodexo':
        return 'Sodexo';
      case 'setcard':
        return 'Setcard';
      case 'online':
      case 'paytr':
        return 'Online Odeme';
      default:
        return method;
    }
  }

  String _sourceLabel(String source) {
    switch (source.toLowerCase()) {
      case 'web':
        return 'Web Sitesi';
      case 'app':
        return 'Mobil Uygulama';
      case 'phone':
        return 'Telefon';
      case 'getir':
        return 'GETIR';
      case 'yemeksepeti':
        return 'Yemeksepeti';
      case 'trendyol':
        return 'Trendyol';
      case 'migros':
        return 'Migros Yemek';
      default:
        return source.toUpperCase();
    }
  }
}
