// =============================================================================
// SyncResto Print — Yazıcı Hatası Pop-up (POS pattern v1.4.6'dan port)
// 18 May 2026 — Mustafa
//
// OrderService printCancelItem veya _printOrderWithRouting fail olunca
// bu modal acilir. Listede failed grup goster + "Tekrar Yazdır" / "Kapat" butonlari.
// Tekrar Yazdir → PrintQueueService.retryJobNow ile lokal kuyruktan tekrarla.
// =============================================================================

import 'package:flutter/material.dart';
import '../services/print_queue_service.dart';
import '../services/local_db_service.dart';

class PrintRetryModal extends StatefulWidget {
  final List<Map<String, dynamic>> failedGroups; // her: {printer_name, printer_ip, department, items, order_number?}
  final String? orderNumber;
  final int? orderId;

  const PrintRetryModal({
    super.key,
    required this.failedGroups,
    this.orderNumber,
    this.orderId,
  });

  @override
  State<PrintRetryModal> createState() => _PrintRetryModalState();
}

class _PrintRetryModalState extends State<PrintRetryModal> {
  late List<Map<String, dynamic>> _groups;
  final Map<int, bool> _retrying = {};
  final Map<int, String?> _lastError = {};
  final Map<int, int> _attempts = {};
  bool _retryingAll = false;
  bool _showCheckHint = false;

  @override
  void initState() {
    super.initState();
    _groups = List.of(widget.failedGroups);
  }

  Future<bool> _retryOne(int idx) async {
    if (idx < 0 || idx >= _groups.length) return false;
    final g = _groups[idx];
    setState(() {
      _retrying[idx] = true;
      _lastError[idx] = null;
      _attempts[idx] = (_attempts[idx] ?? 0) + 1;
    });

    // Kuyruktan en yeni 'pending' veya 'failed' job'u bul (orderId + ip eslesen)
    final pq = PrintQueueService();
    final all = await pq.getAllActiveJobs();
    final jobMatch = all.firstWhere(
      (j) => j['order_id'] == widget.orderId && j['printer_ip'] == g['printer_ip'],
      orElse: () => <String, dynamic>{},
    );
    bool ok = false;
    if (jobMatch.isNotEmpty) {
      ok = await pq.retryJobNow(jobMatch['id'] as int);
    }

    if (!mounted) return ok;
    if (ok) {
      setState(() {
        _groups.removeAt(idx);
        _retrying.remove(idx);
        _lastError.remove(idx);
        _attempts.remove(idx);
      });
      if (_groups.isEmpty && mounted) {
        Navigator.of(context).pop(true);
      }
    } else {
      setState(() {
        _retrying[idx] = false;
        _lastError[idx] = 'Yazıcıya ulasilamadi';
        if ((_attempts[idx] ?? 0) >= 2) _showCheckHint = true;
      });
    }
    return ok;
  }

  Future<void> _retryAll() async {
    if (_retryingAll) return;
    setState(() => _retryingAll = true);
    final count = _groups.length;
    for (int n = 0; n < count; n++) {
      if (_groups.isEmpty) break;
      await _retryOne(0);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (mounted) setState(() => _retryingAll = false);
  }

  String _itemsSummary(List items) {
    if (items.isEmpty) return '-';
    final parts = items.take(3).map((it) {
      final qty = (it is Map ? (it['quantity'] ?? it['qty'] ?? 1) : 1);
      final name = (it is Map ? (it['product_name'] ?? it['name'] ?? '?') : '?');
      return '${qty}x $name';
    }).toList();
    if (items.length > 3) parts.add('+${items.length - 3} daha');
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => !_retryingAll,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.print_disabled, color: Color(0xFFDC2626), size: 26),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Yazıcı Hatasi',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                        const SizedBox(height: 2),
                        Text(
                          'Sipariş ${widget.orderNumber ?? "-"} — ${_groups.length} fiş yazıcıya gitmedi',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFCD34D)),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 18, color: Color(0xFFB45309)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Sipariş kuyruğa eklendi, arka planda 5 saniyede bir otomatik denenir. '
                          'Yazıcıyı kontrol edip "Tekrar Yazdır" ile elle de tetikleyebilirsiniz.',
                          style: TextStyle(fontSize: 12, color: Color(0xFF78350F), height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_showCheckHint) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFCA5A5), width: 1.5),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 20, color: Color(0xFFB91C1C)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('YAZICIYI KONTROL EDIN',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF991B1B))),
                              SizedBox(height: 4),
                              Text(
                                '• Yazıcı açık mı? (yeşil ışık)\n'
                                '• Kağıt bitti mi? (rulo takılı mı)\n'
                                '• Kapak tam kapalı mı?\n'
                                '• Ag kablosu/LAN takılı mı?\n'
                                '• Aynı ağda mı? (IP\'ye ping)\n'
                                '• Kapatıp 10 sn bekleyip tekrar açın.',
                                style: TextStyle(fontSize: 11.5, color: Color(0xFF7F1D1D), height: 1.5),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _groups.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, idx) {
                      final g = _groups[idx];
                      final printerName = (g['printer_name'] ?? 'Yazıcı').toString();
                      final dept = (g['department'] ?? 'default').toString().toUpperCase();
                      final ip = (g['printer_ip'] ?? '-').toString();
                      final items = (g['items'] as List?) ?? [];
                      final busy = _retrying[idx] == true;
                      final error = _lastError[idx];
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF9FAFB),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  const Icon(Icons.print, size: 16, color: Color(0xFF6B7280)),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(printerName,
                                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                                      overflow: TextOverflow.ellipsis),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(color: const Color(0xFFEEF2FF), borderRadius: BorderRadius.circular(4)),
                                    child: Text(dept, style: const TextStyle(fontSize: 10, color: Color(0xFF4338CA), fontWeight: FontWeight.w700)),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(ip, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280), fontFamily: 'monospace')),
                                ]),
                                const SizedBox(height: 4),
                                Text('${items.length} ürün: ${_itemsSummary(items)}',
                                  style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563))),
                                if (error != null) ...[
                                  const SizedBox(height: 4),
                                  Row(children: [
                                    const Icon(Icons.error_outline, size: 14, color: Color(0xFFDC2626)),
                                    const SizedBox(width: 4),
                                    Text(error, style: const TextStyle(fontSize: 11, color: Color(0xFFDC2626))),
                                  ]),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            height: 36,
                            child: ElevatedButton.icon(
                              onPressed: busy || _retryingAll ? null : () => _retryOne(idx),
                              icon: busy
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.refresh, size: 16),
                              label: Text(busy ? '...' : 'Tekrar'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2563EB),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                        ]),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _retryingAll ? null : () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Kapat'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        foregroundColor: const Color(0xFF6B7280),
                        side: const BorderSide(color: Color(0xFFD1D5DB)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: _retryingAll || _groups.isEmpty ? null : _retryAll,
                      icon: _retryingAll
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(_retryingAll ? 'Yazdırılıyor...' : 'Tümünü Tekrar Yazdır (${_groups.length})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFDC2626),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
