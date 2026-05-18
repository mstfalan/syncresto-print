// =============================================================================
// SyncResto Print — Ses bildirim servisi
// 18 May 2026 — Mustafa: Ses açılıp kapatılabilsin
//
// audioplayers paketi masaüstüde (macOS/Windows/Linux) çalışır.
// Storage'tan sound_enabled (default: true) okur; kapalıysa hiçbir şey yapmaz.
// =============================================================================

import 'package:audioplayers/audioplayers.dart';
import 'storage_service.dart';
import 'log_service.dart';

class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  final AudioPlayer _player = AudioPlayer();
  final StorageService _storage = StorageService();
  final LogService _log = LogService();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      _ready = true;
    } catch (e) {
      _log.warning(LogType.general, 'SoundService init hata: $e');
    }
  }

  bool get isEnabled => _storage.getSoundEnabled();

  Future<void> setEnabled(bool v) async {
    await _storage.saveSoundEnabled(v);
  }

  /// Yeni sipariş sesi cal
  Future<void> playNewOrder() async {
    if (!_storage.getSoundEnabled()) return; // ses kapali
    try {
      await _player.stop(); // varsa onceki sesi durdur
      await _player.play(AssetSource('sounds/new_order.mp3'));
    } catch (e) {
      _log.warning(LogType.general, 'Ses calinamadi: $e');
    }
  }

  Future<void> dispose() async {
    try { await _player.dispose(); } catch (_) {}
  }
}
