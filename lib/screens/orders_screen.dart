import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../services/api_service.dart';
import '../services/order_service.dart';
import '../services/printer_service.dart';
import '../services/storage_service.dart';
import '../services/websocket_service.dart';
import '../services/print_queue_service.dart';
import '../services/update_service.dart';
import '../services/html_print_service.dart';
import '../widgets/print_retry_modal.dart';
import 'printer_settings_screen.dart';
import 'setup_screen.dart';

/// Ana ekran — sipariş listesi (online + son geçmiş).
/// WebSocket'ten yeni sipariş geldiğinde otomatik basar (auto_print=true ise).
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  final ApiService _api = ApiService();
  final OrderService _orderService = OrderService();
  final PrinterService _printerService = PrinterService();
  final WebSocketService _ws = WebSocketService();
  final StorageService _storage = StorageService();

  final PrintQueueService _printQueue = PrintQueueService();
  final UpdateService _updateService = UpdateService();
  final HtmlPrintService _htmlPrint = HtmlPrintService();

  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  bool _wsConnected = false;
  bool _autoPrint = true;
  String _restaurantName = 'SyncResto Print';
  Timer? _refreshTimer;

  Map<String, int> _queueSummary = {'pending': 0, 'failed': 0, 'completed': 0};
  UpdateInfo? _updateInfo;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _autoPrint = _storage.getAutoPrint();
    _restaurantName = _storage.getRestaurantName() ?? 'SyncResto Print';

    // Order service'i başlat (websocket dinleyici kurar)
    await _orderService.loadSettings();
    _orderService.start();
    _orderService.addOnNewOrderListener(_onNewOrderArrived);
    _orderService.addOnPrintFailedListener(_onPrintFailed);
    _orderService.addOnUnassignedItemsListener(_onUnassignedItems);

    // Print queue badge
    _printQueue.addSummaryListener(_onQueueSummary);
    _queueSummary = await _printQueue.getSummary();

    // Update check (sessiz, başlatınca bir defa)
    _updateService.checkForUpdate().then((info) {
      if (!mounted) return;
      setState(() => _updateInfo = info);
      if (info != null && info.updateAvailable) {
        // Banner ile uyari (auto-update kapali ise de gosterilir, kritik ise mecbur)
        WidgetsBinding.instance.addPostFrameCallback((_) => _showUpdateBanner(info));
      }
    });

    // Yazıcıları çek + seçili olanı set et
    final printers = await _api.getPrinters();
    final selectedId = _storage.getSelectedPrinterId();
    if (selectedId != null && printers.isNotEmpty) {
      final selected = printers.where((p) => p['id'] == selectedId).toList();
      if (selected.isNotEmpty) _printerService.setSelectedPrinter(selected.first);
    } else if (printers.isNotEmpty) {
      // Default ya da ilk aktif yazıcı
      final defaultPrinter = printers.firstWhere(
        (p) => p['is_default'] == true,
        orElse: () => printers.first,
      );
      _printerService.setSelectedPrinter(defaultPrinter);
    }

    // WebSocket bağlan
    final token = await _api.getSocketToken();
    if (token != null) {
      _ws.onConnectionChange = (connected) {
        if (mounted) setState(() => _wsConnected = connected);
      };
      await _ws.connect(_api.baseUrl, token: token);
    }

    // 18 May 2026: Mustafa istegi — uygulama acildiginda TEMIZ basla.
    // Sadece uygulama acikken gelen yeni siparişler liste'de gosterilir.
    // Kullanici manuel "Yenile" butonuna basinca tum gecmis gelir (opsiyonel).
    // await _loadOrders();  // KALDIRILDI — bootstrap'ta gecmis yuklenmez
    // _refreshTimer = Timer.periodic(...);  // KALDIRILDI — auto-refresh yok

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadOrders({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final list = await _api.getRecentOrders(limit: 100);
      if (mounted) {
        setState(() {
          _orders = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onNewOrderArrived(Map<String, dynamic> order) {
    if (!mounted) return;
    // 18 May 2026: WebSocket payload ozet — ID camelCase/snake_case veya yok olabilir.
    // ID yoksa order_number ile bul, sonra detay cek.
    final initialId = order['id'] is int ? order['id'] as int : int.tryParse('${order['id'] ?? ''}');
    final orderNumber = order['order_number']?.toString() ?? '';

    // Once ozet kart ekle (kullanici hemen gorsun)
    setState(() {
      if (initialId != null) {
        _orders.removeWhere((o) {
          final oid = o['id'];
          return oid == initialId || int.tryParse('$oid') == initialId;
        });
      } else if (orderNumber.isNotEmpty) {
        _orders.removeWhere((o) => o['order_number']?.toString() == orderNumber);
      }
      _orders.insert(0, order);
    });

    // Snackbar — hemen goster
    _showOrderSnackbar(order);

    // 800ms sonra full data cek + guncelle
    Future.delayed(const Duration(milliseconds: 800), () async {
      try {
        Map<String, dynamic>? full;
        int? id = initialId;
        if (id != null) {
          full = await _api.getOrder(id);
        } else if (orderNumber.isNotEmpty) {
          full = await _api.findOrderByNumber(orderNumber);
          if (full != null) {
            id = full['id'] is int ? full['id'] as int : int.tryParse('${full['id']}');
          }
        }
        if (full != null && mounted) {
          setState(() {
            // Idx bul (ID veya order_number ile)
            int idx = -1;
            if (id != null) {
              idx = _orders.indexWhere((o) {
                final oid = o['id'];
                return oid == id || int.tryParse('$oid') == id;
              });
            }
            if (idx < 0 && orderNumber.isNotEmpty) {
              idx = _orders.indexWhere((o) => o['order_number']?.toString() == orderNumber);
            }
            if (idx >= 0) {
              _orders[idx] = full!;
            } else {
              _orders.insert(0, full!);
            }
          });
        }
      } catch (_) {}
    });
  }

  void _showOrderSnackbar(Map<String, dynamic> order) {
    final orderNumber = order['order_number']?.toString() ?? '#?';
    final customerName = order['customer_name']?.toString() ?? '';
    final source = order['source']?.toString() ?? '';
    final sourceLabel = {'getir': 'Getir', 'trendyol': 'Trendyol', 'yemeksepeti': 'YS', 'migros': 'Migros', 'web': 'Web', 'phone': 'Telefon'}[source] ?? source;
    final total = order['total'];
    final totalStr = total != null ? ' · ${(num.tryParse('$total') ?? 0).toStringAsFixed(0)} TL' : '';
    final cleanOrderNumber = orderNumber.replaceFirst(RegExp(r'^(TGO|GTR|YS|MGR|GO)-', caseSensitive: false), '');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🛎️ Yeni sipariş — $sourceLabel #$cleanOrderNumber · $customerName$totalStr'),
          backgroundColor: const Color(0xFF16A34A),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _onQueueSummary(Map<String, int> summary) {
    if (mounted) setState(() => _queueSummary = summary);
  }

  void _onPrintFailed(Map<String, dynamic> payload) {
    if (!mounted) return;
    final orderId = payload['orderId'] as int?;
    final orderNumber = payload['orderNumber']?.toString();
    final failedGroups = (payload['failedGroups'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (failedGroups.isEmpty) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PrintRetryModal(
        failedGroups: failedGroups,
        orderNumber: orderNumber,
        orderId: orderId,
      ),
    );
  }

  void _onUnassignedItems(Map<String, dynamic> payload) {
    if (!mounted) return;
    final orderNumber = payload['orderNumber']?.toString() ?? '';
    final unassigned = (payload['unassignedItems'] as List?) ?? [];
    if (unassigned.isEmpty) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706)),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('Yazıcı Atanmamış Ürün')),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sipariş #$orderNumber içinde ${unassigned.length} ürünün yazıcısı atanmamış:',
                style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: unassigned.map((item) {
                    final m = item is Map ? item.cast<String, dynamic>() : <String, dynamic>{};
                    final qty = m['quantity'] ?? 1;
                    final name = m['product_name'] ?? m['name'] ?? '?';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('• $qty x $name', style: const TextStyle(fontSize: 13)),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(6)),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 16, color: Color(0xFF92400E)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'panel.syncresto.com → POS → Ürünler sayfasından bu ürünlere yazıcı atayın.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF92400E), height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tamam')),
        ],
      ),
    );
  }

  // 28 Haz 2026 — TAM OTONOM GÜNCELLEME (Mustafa: "her şey tam otonom olsun").
  // İlerleme dialog'u → indir+çıkar+kur → app kapanır, yeni sürüm otomatik açılır.
  // Otonom kurulum başarısız → tarayıcı fallback.
  Future<void> _runAutoUpdate(UpdateInfo info) async {
    final url = info.downloadUrl;
    if (url == null) return;
    final progress = ValueNotifier<double>(0.0);
    final durum = ValueNotifier<String>('Hazırlanıyor...');
    _updateService.onProgress = (p, d) { progress.value = p; durum.value = d; };

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Güncelleme'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, v, __) => LinearProgressIndicator(value: v > 0 ? v : null),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<String>(
            valueListenable: durum,
            builder: (_, d, __) => Text(d, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
          ),
        ]),
      ),
    );

    final ok = await _updateService.downloadAndInstall(url);
    // ok=true ise app zaten exit(0) yaptı. Gelirsek otonom başarısız → fallback.
    if (!ok && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Otomatik kurulum yapılamadı, indirme sayfası açılıyor'),
        backgroundColor: Color(0xFFF59E0B),
      ));
      await _updateService.openDownloadUrl(url);
    }
  }

  void _showUpdateBanner(UpdateInfo info) {
    if (!mounted) return;
    // Kritik güncelleme → kullanıcıya sormadan OTONOM kur (Mustafa: tam otonom).
    if (info.isCritical && info.downloadUrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runAutoUpdate(info));
      return;
    }
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        backgroundColor: info.isCritical ? const Color(0xFFFEE2E2) : const Color(0xFFDBEAFE),
        leading: Icon(Icons.system_update, color: info.isCritical ? const Color(0xFFB91C1C) : const Color(0xFF2563EB)),
        content: Text(
          '${info.isCritical ? "Kritik güncelleme!" : "Yeni sürüm mevcut"}: '
          'v${info.currentVersion} → v${info.latestVersion}',
          style: TextStyle(
            color: info.isCritical ? const Color(0xFFB91C1C) : const Color(0xFF1E40AF),
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              if (info.downloadUrl != null) {
                _runAutoUpdate(info);
              }
            },
            child: const Text('Güncelle ve Yeniden Başlat'),
          ),
          TextButton(
            onPressed: () => ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
            child: const Text('Sonra'),
          ),
        ],
      ),
    );
  }

  Future<void> _showQueueModal() async {
    final jobs = await _printQueue.getAllActiveJobs();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Icon(Icons.queue, color: Color(0xFF2563EB), size: 26),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Yazdırma Kuyruğu',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ]),
                const SizedBox(height: 8),
                Text(
                  'Bekleyen: ${_queueSummary['pending'] ?? 0} · '
                  'Başarısız: ${_queueSummary['failed'] ?? 0} · '
                  'Tamamlanan: ${_queueSummary['completed'] ?? 0}',
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 14),
                if (jobs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Text('Kuyruk boş — tüm fişler basıldı',
                        textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 14)),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: jobs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, idx) {
                        final j = jobs[idx];
                        final status = j['status'] as String;
                        final orderNumber = j['order_number']?.toString() ?? '#?';
                        final printerName = j['printer_name']?.toString() ?? 'Yazıcı';
                        final retry = j['retry_count'] as int;
                        final maxR = j['max_retries'] as int;
                        final err = j['error_message']?.toString();
                        return Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: status == 'failed' ? const Color(0xFFFEE2E2) : const Color(0xFFF9FAFB),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: status == 'failed' ? const Color(0xFFFCA5A5) : const Color(0xFFE5E7EB)),
                          ),
                          child: Row(children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('$orderNumber → $printerName',
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  Text('${j['printer_ip']}  •  retry $retry/$maxR  •  $status',
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                                  if (err != null) Text(err,
                                      style: const TextStyle(fontSize: 11, color: Color(0xFFB91C1C))),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Tekrar dene',
                              icon: const Icon(Icons.refresh, color: Color(0xFF2563EB)),
                              onPressed: () async {
                                await _printQueue.retryJobNow(j['id'] as int);
                                Navigator.pop(context);
                                _showQueueModal();
                              },
                            ),
                            IconButton(
                              tooltip: 'Sil',
                              icon: const Icon(Icons.delete_outline, color: Color(0xFFB91C1C)),
                              onPressed: () async {
                                await _printQueue.deleteJob(j['id'] as int);
                                Navigator.pop(context);
                                _showQueueModal();
                              },
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _reprintOrder(Map<String, dynamic> order) async {
    final orderId = order['id'] is int ? order['id'] as int : int.tryParse('${order['id']}');
    if (orderId == null) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Yazdırılıyor...'), duration: Duration(seconds: 1)));

    final ok = await _orderService.reprintOrder(orderId);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(ok ? 'Fiş gönderildi' : 'Yazıcıya gönderilemedi'),
      backgroundColor: ok ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
    ));
    // 18 May 2026: Yenile cagrisi YOK — sadece o sipariş icin tekrar yazdirildi, liste degismez
  }

  /// 29 Haz 2026 — FİŞ ÖNİZLEME (yazıcıya GÖNDERMEZ). Müşteri/özet fişinin online TAM HTML
  /// tasarımını gerçek Chromium/WebView2 (CDP Page.printToPDF) ile PDF'e çevirip ekranda gösterir.
  /// Gerçek basımla AYNI render motoru → önizlemede ne görünürse yazıcıdan o çıkar. macOS: PDF null.
  Future<void> _previewReceipt(Map<String, dynamic> order) async {
    final orderId = order['id'] is int ? order['id'] as int : int.tryParse('${order['id']}');
    if (orderId == null) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('Önizleme hazırlanıyor...'), duration: Duration(seconds: 1)));

    try {
      final html = await _api.getReceiptHtml(orderId, noprint: true);
      if (html == null || html.isEmpty) {
        if (!mounted) return;
        messenger.showSnackBar(const SnackBar(content: Text('Fiş HTML alınamadı'), backgroundColor: Color(0xFFDC2626)));
        return;
      }
      final pdf = await _htmlPrint.buildPdfFromHtml(html);
      if (pdf == null || pdf.isEmpty) {
        if (!mounted) return;
        messenger.showSnackBar(const SnackBar(content: Text('Önizleme PDF üretilemedi'), backgroundColor: Color(0xFFDC2626)));
        return;
      }
      if (!mounted) return;
      // 29 Haz 2026: layoutPdf (sistem yazdırma diyaloğu) macOS sandbox'ta "does not support
      // printing" veriyor (print entitlement yok). UYGULAMA İÇİ PdfPreview ekranı ile göster —
      // entitlement gerektirmez, hem macOS hem Windows'ta çalışır, yazıcıya GÖNDERMEZ.
      final no = order['order_number']?.toString() ?? '$orderId';
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('Fiş Önizleme — $no')),
          body: PdfPreview(
            build: (_) async => pdf,
            canChangePageFormat: false,
            canChangeOrientation: false,
            canDebug: false,
            allowPrinting: false,   // macOS print entitlement yok → yazdır butonu gizli
            allowSharing: true,
            pdfFileName: 'Fis_$no.pdf',
          ),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Önizleme hatası: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Future<void> _toggleAutoPrint() async {
    setState(() => _autoPrint = !_autoPrint);
    await _orderService.setAutoPrint(_autoPrint);
    await _storage.saveAutoPrint(_autoPrint);
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Çıkış Yap'),
        content: const Text('Bu cihazı SyncResto Print bağlantısından çıkarmak istiyor musun?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('İptal')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Çıkış'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _storage.clearAll();
    _ws.disconnect();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const SetupScreen()));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _orderService.removeOnNewOrderListener(_onNewOrderArrived);
    _orderService.removeOnPrintFailedListener(_onPrintFailed);
    _orderService.removeOnUnassignedItemsListener(_onUnassignedItems);
    _printQueue.removeSummaryListener(_onQueueSummary);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        title: Row(children: [
          const Icon(Icons.print),
          const SizedBox(width: 10),
          Expanded(child: Text(_restaurantName, overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          // WebSocket durumu
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(children: [
              Icon(
                _wsConnected ? Icons.wifi : Icons.wifi_off,
                color: _wsConnected ? Colors.greenAccent : Colors.orange,
                size: 18,
              ),
              const SizedBox(width: 4),
              Text(_wsConnected ? 'Bağlı' : 'Yeniden bağlanıyor...',
                style: const TextStyle(fontSize: 12)),
            ]),
          ),
          // Auto print toggle
          Tooltip(
            message: 'Otomatik Yazdırma ${_autoPrint ? "AÇIK" : "KAPALI"}',
            child: Switch(
              value: _autoPrint,
              onChanged: (_) => _toggleAutoPrint(),
              activeColor: Colors.greenAccent,
            ),
          ),
          IconButton(
            tooltip: 'Yazıcı Ayarları',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PrinterSettingsScreen()),
              );
              setState(() {}); // dönünce refresh
            },
          ),
          // 18 May 2026: Yazdırma kuyruğu badge (POS pattern)
          Stack(children: [
            IconButton(
              tooltip: 'Yazdırma Kuyruğu',
              icon: const Icon(Icons.queue),
              onPressed: _showQueueModal,
            ),
            if ((_queueSummary['pending'] ?? 0) + (_queueSummary['failed'] ?? 0) > 0)
              Positioned(
                right: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: (_queueSummary['failed'] ?? 0) > 0 ? Colors.red : Colors.orange,
                    shape: BoxShape.circle,
                  ),
                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                  child: Text(
                    '${(_queueSummary['pending'] ?? 0) + (_queueSummary['failed'] ?? 0)}',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ]),
          IconButton(
            tooltip: 'Listeyi Temizle',
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: () {
              setState(() => _orders = []);
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'logout', child: Text('Çıkış Yap')),
            ],
          ),
        ],
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _orders.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Text(
                  'Henüz sipariş yok.\nYeni siparişler otomatik olarak listelenecek.',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : RefreshIndicator(
              // 18 May 2026: Pull-to-refresh artik eski siparişleri cekmez (Mustafa istegi).
              // Sadece queue summary'i yeniler (gorsel feedback icin).
              onRefresh: () async {
                final s = await _printQueue.getSummary();
                if (mounted) setState(() => _queueSummary = s);
              },
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: _orders.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, idx) => _OrderCard(
                  order: _orders[idx],
                  onReprint: () => _reprintOrder(_orders[idx]),
                  onPreview: () => _previewReceipt(_orders[idx]),
                ),
              ),
            ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final VoidCallback onReprint;
  final VoidCallback onPreview;
  const _OrderCard({required this.order, required this.onReprint, required this.onPreview});

  @override
  Widget build(BuildContext context) {
    final orderNumber = order['order_number']?.toString() ?? '#?';
    final source = (order['source']?.toString() ?? '').toUpperCase();
    final status = order['status']?.toString() ?? '';
    final total = order['total'] is num
        ? (order['total'] as num).toDouble()
        : double.tryParse('${order['total']}') ?? 0;
    final customerName = order['customer_name']?.toString() ?? '';
    final printedAt = order['printed_at']?.toString();
    final createdAt = order['created_at']?.toString();
    final dateStr = createdAt != null
        ? DateFormat('dd.MM HH:mm').format(DateTime.tryParse(createdAt) ?? DateTime.now())
        : '';

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          // Sol: source rozetli
          Container(
            width: 64,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: _sourceColor(source),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              source.isEmpty ? 'WEB' : source,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          const SizedBox(width: 12),
          // Orta: bilgiler
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(orderNumber, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('$customerName  •  $dateStr  •  $status',
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
              if (printedAt != null) ...[
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 14),
                  const SizedBox(width: 4),
                  Text('Basıldı: ${DateFormat('HH:mm').format(DateTime.tryParse(printedAt) ?? DateTime.now())}',
                    style: const TextStyle(fontSize: 12, color: Colors.green)),
                ]),
              ],
            ]),
          ),
          // Sağ: tutar + önizle/yazdır butonları
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${total.toStringAsFixed(2)} ₺',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton.icon(
                onPressed: onPreview,
                icon: const Icon(Icons.visibility, size: 16),
                label: const Text('Önizle', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF6B7280),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: const Size(0, 28),
                ),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: onReprint,
                icon: const Icon(Icons.print, size: 16),
                label: const Text('Yazdır', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: const Size(0, 28),
                ),
              ),
            ]),
          ]),
        ]),
      ),
    );
  }

  Color _sourceColor(String s) {
    switch (s.toLowerCase()) {
      case 'getir': return const Color(0xFF5D3EBC);
      case 'trendyol': return const Color(0xFFF27A1A);
      case 'yemeksepeti': return const Color(0xFFFA0050);
      case 'migros': return const Color(0xFF005FA9);
      default: return const Color(0xFF2563EB);
    }
  }
}
