// =============================================================================
// SyncResto Print — Yerel SQLite DB (print queue + offline-first)
// 18 May 2026 — Mustafa
//
// Amaç:
//   - Online sipariş geldi, yazıcı düştü → kuyruğa al, geri gelince bas
//   - "İptal fişi" gibi extra job'lar için ortak kuyruk
//   - 5 saniyede bir background retry (POS pattern)
//
// Backend bagımsız — sqflite_common_ffi ile masaüstü çalışır (macOS/Windows/Linux).
// =============================================================================

import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';

class LocalDbService {
  static final LocalDbService _instance = LocalDbService._internal();
  factory LocalDbService() => _instance;
  LocalDbService._internal();

  Database? _db;
  bool _initialized = false;

  Future<Database> get database async {
    if (_db != null) return _db!;
    if (!_initialized) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      _initialized = true;
    }
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getApplicationSupportDirectory();
    final path = '${dir.path}/syncresto_print.db';
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE print_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            print_type TEXT NOT NULL,        -- 'order', 'cancel', 'test'
            order_id INTEGER,                -- panel_orders.id (varsa)
            order_number TEXT,               -- gosterim icin
            printer_id INTEGER,              -- hedef yazıcı id
            printer_name TEXT,
            printer_ip TEXT NOT NULL,
            printer_port INTEGER DEFAULT 9100,
            receipt_data TEXT NOT NULL,      -- JSON: { order: {...}, department, items_subset }
            status TEXT NOT NULL DEFAULT 'pending',  -- 'pending', 'completed', 'failed'
            retry_count INTEGER NOT NULL DEFAULT 0,
            max_retries INTEGER NOT NULL DEFAULT 5,
            error_message TEXT,
            created_at TEXT NOT NULL,
            last_attempt_at TEXT,
            completed_at TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_pq_status ON print_queue(status, created_at)');
        await db.execute('CREATE INDEX idx_pq_order ON print_queue(order_id)');
      },
    );
  }

  // === CRUD ===

  /// Kuyruga yeni is ekle. Donus: yeni id
  Future<int> addJob({
    required String printType,      // 'order' | 'cancel' | 'test'
    int? orderId,
    String? orderNumber,
    required int? printerId,
    String? printerName,
    required String printerIp,
    int printerPort = 9100,
    required Map<String, dynamic> receiptData,
    int maxRetries = 5,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return await db.insert('print_queue', {
      'print_type': printType,
      'order_id': orderId,
      'order_number': orderNumber,
      'printer_id': printerId,
      'printer_name': printerName,
      'printer_ip': printerIp,
      'printer_port': printerPort,
      'receipt_data': jsonEncode(receiptData),
      'status': 'pending',
      'retry_count': 0,
      'max_retries': maxRetries,
      'created_at': now,
      'last_attempt_at': now,
    });
  }

  /// Bekleyenleri getir (background retry icin)
  Future<List<Map<String, dynamic>>> getPendingJobs() async {
    final db = await database;
    return await db.query(
      'print_queue',
      where: "status = 'pending' AND retry_count < max_retries",
      orderBy: 'created_at ASC',
      limit: 50,
    );
  }

  /// Tum (pending + failed) — UI listesi icin
  Future<List<Map<String, dynamic>>> getAllActiveJobs() async {
    final db = await database;
    return await db.query(
      'print_queue',
      where: "status IN ('pending', 'failed')",
      orderBy: 'created_at DESC',
      limit: 100,
    );
  }

  /// Tek bir is
  Future<Map<String, dynamic>?> getJob(int id) async {
    final db = await database;
    final r = await db.query('print_queue', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first;
  }

  /// Basarili olarak isaretle
  Future<void> markCompleted(int id) async {
    final db = await database;
    await db.update('print_queue', {
      'status': 'completed',
      'completed_at': DateTime.now().toIso8601String(),
    }, where: 'id = ?', whereArgs: [id]);
  }

  /// Basarisiz — retry_count artar, max'a ulasinca 'failed' olur
  Future<void> markFailed(int id, String? errorMessage) async {
    final db = await database;
    final r = await db.query('print_queue', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return;
    final job = r.first;
    final newRetry = (job['retry_count'] as int) + 1;
    final maxR = job['max_retries'] as int;
    await db.update('print_queue', {
      'retry_count': newRetry,
      'error_message': errorMessage,
      'last_attempt_at': DateTime.now().toIso8601String(),
      'status': newRetry >= maxR ? 'failed' : 'pending',
    }, where: 'id = ?', whereArgs: [id]);
  }

  /// Sifirla — manuel "tekrar dene" UI butonu
  Future<void> resetJob(int id) async {
    final db = await database;
    await db.update('print_queue', {
      'status': 'pending',
      'retry_count': 0,
      'error_message': null,
    }, where: 'id = ?', whereArgs: [id]);
  }

  /// Sil
  Future<void> deleteJob(int id) async {
    final db = await database;
    await db.delete('print_queue', where: 'id = ?', whereArgs: [id]);
  }

  /// Eski tamamlananlari sil (>1 saat)
  Future<void> cleanupOldCompleted() async {
    final db = await database;
    final oneHourAgo = DateTime.now().subtract(const Duration(hours: 1)).toIso8601String();
    await db.delete('print_queue', where: "status = 'completed' AND completed_at < ?", whereArgs: [oneHourAgo]);
  }

  /// 28 Haz 2026 (Flutter POS şişme dersi): KAPSAMLI periyodik temizlik.
  /// - completed > 1 saat: sil (basılmış, gerek yok)
  /// - failed > 7 gün: sil (kullanıcı 7 gün görsün, sonra kalıcı birikmesin)
  /// Periyodik çağrılır (boot-only DEĞİL — POS'ta koşullu temizlik GB şişmesi yapmıştı).
  /// Geçmiş sipariş DB'de TUTULMAZ; sadece yazıcı kuyruğu. VACUUM ile dosya fiilen küçülür.
  Future<void> cleanupOldJobs() async {
    final db = await database;
    final now = DateTime.now();
    final oneHourAgo = now.subtract(const Duration(hours: 1)).toIso8601String();
    final sevenDaysAgo = now.subtract(const Duration(days: 7)).toIso8601String();
    await db.delete('print_queue', where: "status = 'completed' AND completed_at < ?", whereArgs: [oneHourAgo]);
    await db.delete('print_queue', where: "status = 'failed' AND last_attempt_at < ?", whereArgs: [sevenDaysAgo]);
    try { await db.execute('VACUUM'); } catch (_) {}
  }

  /// Ozet: { pending: N, failed: N, completed: N }
  Future<Map<String, int>> getSummary() async {
    final db = await database;
    final pending = await db.rawQuery("SELECT COUNT(*) AS c FROM print_queue WHERE status = 'pending'");
    final failed = await db.rawQuery("SELECT COUNT(*) AS c FROM print_queue WHERE status = 'failed'");
    final completed = await db.rawQuery("SELECT COUNT(*) AS c FROM print_queue WHERE status = 'completed'");
    return {
      'pending': (pending.first['c'] as int?) ?? 0,
      'failed': (failed.first['c'] as int?) ?? 0,
      'completed': (completed.first['c'] as int?) ?? 0,
    };
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
