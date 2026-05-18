// =============================================================================
// SyncResto Print — Background Print Queue Retry Servisi
// 18 May 2026 — Mustafa
//
// PrintQueueService her 5sn'de bir LocalDb'deki pending job'lari isler:
//   - receipt_data'yı JSON parse → printerService._sendToPrinter
//   - Basariliysa markCompleted + backend mark-printed
//   - Basarisizsa markFailed (retry_count++)
//   - Max retries asilirsa 'failed' state'e gecer, UI'da kullanici manuel yenileyebilir
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'local_db_service.dart';
import 'printer_service.dart';
import 'api_service.dart';
import 'log_service.dart';

class PrintQueueService {
  static final PrintQueueService _instance = PrintQueueService._internal();
  factory PrintQueueService() => _instance;
  PrintQueueService._internal();

  final LocalDbService _db = LocalDbService();
  final PrinterService _printer = PrinterService();
  final ApiService _api = ApiService();
  final LogService _log = LogService();

  Timer? _timer;
  bool _processing = false;

  /// Listener'lar (UI badge sayisi icin)
  final List<void Function(Map<String, int>)> _onSummaryChange = [];
  void addSummaryListener(void Function(Map<String, int>) cb) => _onSummaryChange.add(cb);
  void removeSummaryListener(void Function(Map<String, int>) cb) => _onSummaryChange.remove(cb);

  bool get isRunning => _timer != null;

  /// Servisi baslat
  void start() {
    if (_timer != null) return;
    _log.logAction('[PrintQueue] Otomatik retry baslatildi (5sn aralik)');
    // Hemen bir kez calistir
    _process();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _process());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _log.logAction('[PrintQueue] Otomatik retry durduruldu');
  }

  Future<void> _process() async {
    if (_processing) return;
    _processing = true;
    try {
      final pending = await _db.getPendingJobs();
      if (pending.isEmpty) {
        await _notifySummary();
        return;
      }
      for (final job in pending) {
        final id = job['id'] as int;
        await _processJob(id, job);
        await Future.delayed(const Duration(milliseconds: 400)); // yazıcıyı bogmayalim
      }
      // Eski tamamlananlari temizle
      await _db.cleanupOldCompleted();
      await _notifySummary();
    } catch (e) {
      _log.error(LogType.error, '[PrintQueue] islem hata: $e');
    } finally {
      _processing = false;
    }
  }

  Future<bool> _processJob(int id, Map<String, dynamic> job) async {
    try {
      final printType = job['print_type'] as String;
      final ip = job['printer_ip'] as String;
      final port = (job['printer_port'] as int?) ?? 9100;
      final orderId = job['order_id'] as int?;
      final receiptDataJson = job['receipt_data'] as String;
      final data = jsonDecode(receiptDataJson) as Map<String, dynamic>;

      List<int> bytes;
      if (printType == 'order') {
        final order = data['order'] as Map<String, dynamic>;
        final department = (data['department'] as String?) ?? 'KASA';
        bytes = await _printer.generateOrderReceiptBytes(order, department);
      } else if (printType == 'cancel') {
        bytes = await _printer.generateCancelReceiptBytes(data);
      } else {
        // 'test' veya bilinmeyen — atla
        await _db.markCompleted(id);
        return true;
      }

      final ok = await _printer.sendRawToIp(ip, port, bytes);
      if (ok) {
        await _db.markCompleted(id);
        // Backend'e mark-printed
        if (orderId != null && printType == 'order') {
          await _api.markOrderPrinted(orderId, printerName: job['printer_name'] as String?);
        }
        _log.logAction('[PrintQueue] OK job=$id printer=$ip orderNumber=${job['order_number']}');
        return true;
      } else {
        await _db.markFailed(id, 'TCP basarisiz');
        _log.warning(LogType.error, '[PrintQueue] FAIL job=$id printer=$ip (retry: ${(job['retry_count'] as int) + 1}/${job['max_retries']})');
        if (orderId != null && printType == 'order' && (job['retry_count'] as int) + 1 >= (job['max_retries'] as int)) {
          await _api.reportPrintFailed(orderId, error: 'Max retry asildi', printerName: job['printer_name'] as String?);
        }
        return false;
      }
    } catch (e) {
      _log.error(LogType.error, '[PrintQueue] job=$id exception: $e');
      await _db.markFailed(id, e.toString());
      return false;
    }
  }

  /// Manuel retry — UI butonu (failed job icin retry_count sifirla + dene)
  Future<bool> retryJobNow(int id) async {
    await _db.resetJob(id);
    final job = await _db.getJob(id);
    if (job == null) return false;
    return await _processJob(id, job);
  }

  Future<void> deleteJob(int id) async {
    await _db.deleteJob(id);
    await _notifySummary();
  }

  Future<Map<String, int>> getSummary() => _db.getSummary();
  Future<List<Map<String, dynamic>>> getAllActiveJobs() => _db.getAllActiveJobs();

  Future<void> _notifySummary() async {
    final s = await _db.getSummary();
    for (final cb in _onSummaryChange) {
      try { cb(s); } catch (_) {}
    }
  }
}
