// =============================================================================
// SyncResto Print — Otomatik Güncelleme Servisi
// 18 May 2026 — POS gibi GitHub release sistemi
// 28 Haz 2026 — TAM OTONOM GÜNCELLEME (Mustafa: "eski dosyalari silip yenisini
//   yükleyerek yeni uygulamayi da açmali, her şey tam otonom olsun")
//
// Akış:
//   1) Backend /api/print/version → GitHub Releases'tan CANLI son sürüm + doğrudan .zip linki
//   2) Yeni sürüm varsa: .zip'i indir → geçici klasöre çıkar
//   3) Yardımcı batch script yaz (app kapandıktan SONRA çalışır):
//        - app process'i bekle/öldür
//        - mevcut kurulum klasöründeki eski dosyaları sil
//        - çıkarılan yeni dosyaları kopyala
//        - yeni syncresto_print.exe'yi aç
//        - geçici dosyaları temizle (self-clean — şişme dersi)
//   4) App kapanır, batch devralır → kullanıcı hiçbir şey yapmaz.
//
// NEDEN BATCH: çalışan .exe kendi dosyasını Windows'ta silemez/üzerine yazamaz
//   (dosya kilitli). app kapanmadan dosyalar değişemez → harici batch şart.
// =============================================================================

import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:archive/archive.dart';
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

  /// Download URL'i tarayicida ac (FALLBACK — otonom kurulum yapilamazsa kullanici manuel kursun)
  Future<bool> openDownloadUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      _log.warning(LogType.general, 'Güncelleme baglantisi acilamadi: $e');
    }
    return false;
  }

  // ==========================================================================
  // 28 Haz 2026 — TAM OTONOM GÜNCELLEME
  // Mustafa: "eski dosyalari silip yenisini yükleyerek yeni uygulamayi da
  //   açmali, her şey tam otonom olsun."
  // ==========================================================================

  /// İndirme ilerlemesi callback'i (0.0 - 1.0). UI progress bar için.
  void Function(double progress, String durum)? onProgress;

  /// .zip'i indir → çıkar → batch yaz → app'i kapat (batch devralır, otonom kurar+açar).
  /// SADECE Windows. Diğer platformlarda openDownloadUrl fallback.
  /// Döner: true = kurulum başladı (app kapanmak üzere), false = hata (UI fallback göstersin).
  Future<bool> downloadAndInstall(String downloadUrl) async {
    if (!Platform.isWindows) {
      _log.warning(LogType.general, 'Otonom güncelleme sadece Windows — tarayicida acilacak');
      return false;
    }
    // Doğrudan .zip linki şart (release sayfası HTML değil). Backend asset linkini döndürür.
    if (!downloadUrl.toLowerCase().endsWith('.zip')) {
      _log.warning(LogType.general, 'Güncelleme linki .zip degil, otonom kurulum atlandi: $downloadUrl');
      return false;
    }
    try {
      onProgress?.call(0.0, 'İndiriliyor...');
      // 1) İndir (geçici klasöre)
      final tmpDir = await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final zipPath = '${tmpDir.path}${Platform.pathSeparator}syncresto_print_update_$stamp.zip';
      final extractDir = '${tmpDir.path}${Platform.pathSeparator}syncresto_print_new_$stamp';

      final client = http.Client();
      final req = http.Request('GET', Uri.parse(downloadUrl));
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        _log.error(LogType.error, 'Güncelleme indirilemedi: HTTP ${resp.statusCode}');
        client.close();
        return false;
      }
      final total = resp.contentLength ?? 0;
      final file = File(zipPath);
      final sink = file.openWrite();
      int received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total * 0.7, 'İndiriliyor...');
      }
      await sink.close();
      client.close();
      _log.logAction('Güncelleme indirildi: $zipPath (${(received / 1048576).toStringAsFixed(1)} MB)');

      // 2) Arşivi çıkar
      onProgress?.call(0.8, 'Arşiv açılıyor...');
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final outDir = Directory(extractDir);
      if (await outDir.exists()) await outDir.delete(recursive: true);
      await outDir.create(recursive: true);
      for (final entry in archive) {
        final outPath = '$extractDir${Platform.pathSeparator}${entry.name}';
        if (entry.isFile) {
          final f = File(outPath);
          await f.create(recursive: true);
          await f.writeAsBytes(entry.content as List<int>);
        } else {
          await Directory(outPath).create(recursive: true);
        }
      }
      _log.logAction('Güncelleme arşivi açıldi: $extractDir');

      // 3) Mevcut kurulum klasörü = çalışan .exe'nin bulunduğu klasör
      final exePath = Platform.resolvedExecutable;
      final installDir = File(exePath).parent.path;
      final exeName = exePath.split(Platform.pathSeparator).last;
      final pid = pid_();

      // 4) Otonom kurulum batch script'i yaz (app kapandıktan sonra çalışır)
      onProgress?.call(0.9, 'Kurulum hazırlanıyor...');
      final batPath = '${tmpDir.path}${Platform.pathSeparator}syncresto_print_update_$stamp.bat';
      final bat = _buildUpdateBat(
        pid: pid,
        installDir: installDir,
        extractDir: extractDir,
        exeName: exeName,
        zipPath: zipPath,
        batPath: batPath,
      );
      await File(batPath).writeAsString(bat);

      // 5) Batch'i ayrı pencerede başlat → app'i kapat (batch devralır)
      onProgress?.call(1.0, 'Güncelleme uygulanıyor, uygulama yeniden başlatılacak...');
      await Process.start(
        'cmd.exe',
        ['/c', 'start', '', '/min', batPath],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
      _log.logAction('Otonom güncelleme batch başlatildi, uygulama kapaniyor');
      // App'i kapat — batch dosyaları değiştirip yeni sürümü açacak
      await Future.delayed(const Duration(milliseconds: 800));
      exit(0);
    } catch (e) {
      _log.error(LogType.error, 'Otonom güncelleme hatasi: $e');
      onProgress?.call(0.0, 'Hata: $e');
      return false;
    }
  }

  int pid_() {
    try { return pid; } catch (_) { return 0; }
  }

  /// Windows batch: app'i bekle/kapat → eski dosyaları sil → yenileri kopyala →
  /// yeni exe'yi aç → geçici dosyaları temizle (self-clean, şişme dersi).
  /// robocopy /MIR = ayna kopya (eski fazlalık dosyaları da temizler).
  String _buildUpdateBat({
    required int pid,
    required String installDir,
    required String extractDir,
    required String exeName,
    required String zipPath,
    required String batPath,
  }) {
    // CRLF satır sonu + UTF-8 sorunlarından kaçınmak için sade ASCII komutlar.
    final lines = <String>[
      '@echo off',
      'chcp 65001 >nul',
      'echo SyncResto Print guncelleniyor...',
      // Uygulama tam kapansin (dosya kilidi kalksin)
      'timeout /t 2 /nobreak >nul',
      if (pid > 0) 'taskkill /PID $pid /F >nul 2>&1',
      'taskkill /IM "$exeName" /F >nul 2>&1',
      'timeout /t 1 /nobreak >nul',
      // Eski dosyalari sil + yenileri kopyala (robocopy /MIR ayna; fazlaliklari temizler).
      // /XF batch+log dosyalarini disla; geri donus kodu 0-7 = basarili.
      'robocopy "$extractDir" "$installDir" /MIR /NFL /NDL /NJH /NJS /NP >nul',
      'if %ERRORLEVEL% GEQ 8 ( echo Kopyalama hatasi & pause & exit /b 1 )',
      // Yeni surumu ac
      'start "" "$installDir\\$exeName"',
      // Self-clean: gecici indirme/cikarma/batch dosyalarini sil (sisme dersi)
      'timeout /t 2 /nobreak >nul',
      'del /q "$zipPath" >nul 2>&1',
      'rmdir /s /q "$extractDir" >nul 2>&1',
      // Batch kendini siler
      '(goto) 2>nul & del "%~f0"',
    ];
    return lines.join('\r\n');
  }
}
