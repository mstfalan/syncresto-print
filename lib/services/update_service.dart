// =============================================================================
// SyncResto Print — Auto-update Servisi
// 18 May 2026 — Mustafa: POS gibi GitHub release sistem
//
// Backend /api/print/version endpoint'inden mevcut sürümü cek; pubspec ile karşılaştır.
// Yeni sürüm varsa kullanıciya modal göster + download URL'i tarayicida ac.
// Auto-update DOSYA INDIRMEZ — kullanıcı manuel olarak browser'dan indirir,
// arsivi cikarip mevcut binary'nin yerine kopyalar (POS pattern ile aynı).
// =============================================================================

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'api_service.dart';
import 'storage_service.dart';
import 'log_service.dart';

class UpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final bool updateAvailable;
  final String? downloadUrl;
  final String? releaseNotes;
  final bool isCritical;

  UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.updateAvailable,
    this.downloadUrl,
    this.releaseNotes,
    this.isCritical = false,
  });
}

class UpdateService {
  static final UpdateService _instance = UpdateService._internal();
  factory UpdateService() => _instance;
  UpdateService._internal();

  final StorageService _storage = StorageService();
  final ApiService _api = ApiService();
  final LogService _log = LogService();

  String? _currentVersion;
  String? _currentBuildNumber;

  Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
      _currentBuildNumber = info.buildNumber;
    } catch (e) {
      _log.warning(LogType.general, 'UpdateService init hata: $e');
    }
  }

  String? get currentVersion => _currentVersion;

  /// Backend'den son surumu sorgula. Donus: UpdateInfo veya null (hata)
  Future<UpdateInfo?> checkForUpdate() async {
    if (!_storage.getAutoUpdateCheck()) return null;
    if (_currentVersion == null) await init();
    try {
      final remote = await _api.getVersion();
      if (remote == null) return null;
      final latest = remote['version']?.toString() ?? '0.0.0';
      final downloadUrl = remote['download_url']?.toString();
      final notes = remote['release_notes']?.toString();
      final critical = remote['critical'] == true;
      final available = _isNewer(latest, _currentVersion ?? '0.0.0');
      return UpdateInfo(
        currentVersion: _currentVersion ?? '0.0.0',
        latestVersion: latest,
        updateAvailable: available,
        downloadUrl: downloadUrl,
        releaseNotes: notes,
        isCritical: critical,
      );
    } catch (e) {
      _log.warning(LogType.general, 'Update check hata: $e');
      return null;
    }
  }

  /// Semver karsilastirmasi (basit, X.Y.Z formatinda)
  bool _isNewer(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s.split('+').first) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s.split('+').first) ?? 0).toList();
    while (pa.length < 3) pa.add(0);
    while (pb.length < 3) pb.add(0);
    for (int i = 0; i < 3; i++) {
      if (pa[i] > pb[i]) return true;
      if (pa[i] < pb[i]) return false;
    }
    return false;
  }

  /// Download URL'i tarayicida ac (kullanici manuel indirip kuracak)
  Future<bool> openDownloadUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _log.warning(LogType.general, 'Update URL acilamadi: $e');
    }
    return false;
  }
}
