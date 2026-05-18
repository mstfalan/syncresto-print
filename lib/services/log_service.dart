import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Log seviyesi
enum LogLevel { info, warning, error }

/// Log türü
enum LogType { error, sync, syncError, login, action, update, general }

/// Tek bir log kaydı
class LogEntry {
  final LogLevel level;
  final LogType type;
  final String message;
  final Map<String, dynamic>? details;
  final int? userId;
  final String? userName;
  final DateTime timestamp;

  LogEntry({
    required this.level,
    required this.type,
    required this.message,
    this.details,
    this.userId,
    this.userName,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'log_level': level.name,
        'log_type': _typeToString(type),
        'message': message,
        'details': details,
        'user_id': userId,
        'user_name': userName,
        'timestamp': timestamp.toIso8601String(),
      };

  String _typeToString(LogType type) {
    switch (type) {
      case LogType.syncError:
        return 'sync_error';
      default:
        return type.name;
    }
  }
}

/// Merkezi log servisi - POS loglarını SyncResto'ya gönderir
class LogService {
  static final LogService _instance = LogService._internal();
  factory LogService() => _instance;
  LogService._internal();

  Dio? _dio;
  String? _apiKey;
  String? _deviceId;
  String? _appVersion;
  String? _platform;
  int? _currentUserId;
  String? _currentUserName;

  final List<LogEntry> _pendingLogs = [];
  Timer? _flushTimer;
  bool _isInitialized = false;
  bool _isFlushing = false;

  // Ayarlar
  static const int _maxPendingLogs = 50;
  static const Duration _flushInterval = Duration(seconds: 30);
  static const String _pendingLogsKey = 'pending_pos_logs';

  /// Servisi başlat
  Future<void> init(Dio dio, String apiKey) async {
    if (_isInitialized) return;

    _dio = dio;
    _apiKey = apiKey;
    await _loadDeviceInfo();
    await _loadPendingLogs();
    _startFlushTimer();
    _isInitialized = true;

    info(LogType.general, 'Log servisi başlatıldı');
  }

  /// Cihaz bilgilerini yükle
  Future<void> _loadDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      final packageInfo = await PackageInfo.fromPlatform();

      _appVersion = packageInfo.version;

      if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        _deviceId = windowsInfo.deviceId;
        _platform = 'windows';
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        _deviceId = macInfo.systemGUID ?? 'unknown';
        _platform = 'macos';
      } else if (Platform.isLinux) {
        final linuxInfo = await deviceInfo.linuxInfo;
        _deviceId = linuxInfo.machineId ?? 'unknown';
        _platform = 'linux';
      } else {
        _deviceId = 'unknown';
        _platform = Platform.operatingSystem;
      }
    } catch (e) {
      debugPrint('[LogService] Cihaz bilgisi alınamadı: $e');
      _deviceId = 'unknown';
      _platform = 'unknown';
    }
  }

  /// Kullanıcı bilgisini ayarla
  void setUser(int? userId, String? userName) {
    _currentUserId = userId;
    _currentUserName = userName;
  }

  /// Kullanıcı bilgisini temizle
  void clearUser() {
    _currentUserId = null;
    _currentUserName = null;
  }

  /// Info seviyesinde log ekle
  void info(LogType type, String message, {Map<String, dynamic>? details}) {
    _addLog(LogLevel.info, type, message, details: details);
  }

  /// Warning seviyesinde log ekle
  void warning(LogType type, String message, {Map<String, dynamic>? details}) {
    _addLog(LogLevel.warning, type, message, details: details);
  }

  /// Error seviyesinde log ekle
  void error(LogType type, String message,
      {Map<String, dynamic>? details, dynamic error, StackTrace? stackTrace}) {
    final errorDetails = <String, dynamic>{
      ...?details,
      if (error != null) 'error': error.toString(),
      if (stackTrace != null) 'stack_trace': stackTrace.toString().split('\n').take(10).join('\n'),
    };
    _addLog(LogLevel.error, type, message, details: errorDetails);
  }

  /// Login log'u
  void logLogin(int userId, String userName) {
    setUser(userId, userName);
    info(LogType.login, 'Kullanıcı giriş yaptı: $userName');
  }

  /// Logout log'u
  void logLogout() {
    final userName = _currentUserName ?? 'Bilinmeyen';
    info(LogType.login, 'Kullanıcı çıkış yaptı: $userName');
    clearUser();
  }

  /// Sync log'u
  void logSync(String message, {int? count, String? operation}) {
    info(LogType.sync, message, details: {
      if (count != null) 'count': count,
      if (operation != null) 'operation': operation,
    });
  }

  /// Sync error log'u
  void logSyncError(String message, {String? operation, dynamic error}) {
    this.error(LogType.syncError, message, details: {
      if (operation != null) 'operation': operation,
    }, error: error);
  }

  /// Action log'u (masa açma, kapama vb.)
  void logAction(String action, {Map<String, dynamic>? details}) {
    info(LogType.action, action, details: details);
  }

  /// Update log'u
  void logUpdate(String message, {String? version}) {
    info(LogType.update, message, details: {
      if (version != null) 'version': version,
    });
  }

  /// Log ekle
  void _addLog(LogLevel level, LogType type, String message,
      {Map<String, dynamic>? details}) {
    final entry = LogEntry(
      level: level,
      type: type,
      message: message,
      details: details,
      userId: _currentUserId,
      userName: _currentUserName,
    );

    _pendingLogs.add(entry);
    debugPrint('[LOG ${level.name.toUpperCase()}] ${type.name}: $message');

    // Max log sayısına ulaştıysa hemen gönder
    if (_pendingLogs.length >= _maxPendingLogs) {
      flush();
    }
  }

  /// Flush timer'ı başlat
  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) => flush());
  }

  /// Bekleyen logları sunucuya gönder
  Future<void> flush() async {
    if (_isFlushing) return;
    if (_pendingLogs.isEmpty || _dio == null || _apiKey == null) return;

    _isFlushing = true;
    final logsToSend = List<LogEntry>.from(_pendingLogs);
    _pendingLogs.clear();

    if (logsToSend.isEmpty) {
      _isFlushing = false;
      return;
    }

    try {
      final response = await _dio!.post(
        '/api/pos/logs',
        options: Options(
          headers: {
            'X-API-Key': _apiKey,
            'X-Device-Id': _deviceId,
            'X-App-Version': _appVersion,
            'X-Platform': _platform,
          },
        ),
        data: {
          'logs': logsToSend.map((l) => l.toJson()).toList(),
          'device_info': {
            'device_id': _deviceId,
            'app_version': _appVersion,
            'platform': _platform,
          },
        },
      );

      if (response.statusCode == 200) {
        debugPrint('[LogService] ${logsToSend.length} log gönderildi');
        await _clearPendingLogs();
      } else {
        _pendingLogs.insertAll(0, logsToSend);
        await _savePendingLogs();
      }
    } catch (e) {
      debugPrint('[LogService] Log gönderme hatası: $e');
      _pendingLogs.insertAll(0, logsToSend);
      await _savePendingLogs();
    } finally {
      _isFlushing = false;
    }
  }

  /// Bekleyen logları local'e kaydet
  Future<void> _savePendingLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logsJson = _pendingLogs.map((l) => l.toJson()).toList();
      await prefs.setString(_pendingLogsKey, jsonEncode(logsJson));
    } catch (e) {
      debugPrint('[LogService] Log kaydetme hatası: $e');
    }
  }

  /// Bekleyen logları local'den yükle
  Future<void> _loadPendingLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logsJson = prefs.getString(_pendingLogsKey);
      if (logsJson != null) {
        final logs = jsonDecode(logsJson) as List;
        for (final log in logs) {
          _pendingLogs.add(LogEntry(
            level: LogLevel.values.firstWhere(
              (l) => l.name == log['log_level'],
              orElse: () => LogLevel.info,
            ),
            type: _stringToType(log['log_type']),
            message: log['message'] ?? '',
            details: log['details'],
            userId: log['user_id'],
            userName: log['user_name'],
            timestamp: DateTime.tryParse(log['timestamp'] ?? '') ?? DateTime.now(),
          ));
        }
        debugPrint('[LogService] ${_pendingLogs.length} bekleyen log yüklendi');
      }
    } catch (e) {
      debugPrint('[LogService] Log yükleme hatası: $e');
    }
  }

  LogType _stringToType(String? type) {
    switch (type) {
      case 'sync_error':
        return LogType.syncError;
      case 'error':
        return LogType.error;
      case 'sync':
        return LogType.sync;
      case 'login':
        return LogType.login;
      case 'action':
        return LogType.action;
      case 'update':
        return LogType.update;
      default:
        return LogType.general;
    }
  }

  /// Bekleyen logları temizle
  Future<void> _clearPendingLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingLogsKey);
    } catch (e) {
      debugPrint('[LogService] Log temizleme hatası: $e');
    }
  }

  /// Servisi kapat
  Future<void> dispose() async {
    _flushTimer?.cancel();
    await flush();
    _isInitialized = false;
  }
}
