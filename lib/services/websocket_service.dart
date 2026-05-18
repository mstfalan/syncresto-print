import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'log_service.dart';

/// SyncResto Print — minimal WebSocket istemcisi.
/// Backend panel-X room'una otomatik join (JWT'den), 'order-received' event dinler.
class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  IO.Socket? _socket;
  bool _isConnected = false;
  String? _serverUrl;
  String? _authToken;
  final LogService _logService = LogService();

  // Event callbacks
  Function(Map<String, dynamic>)? onNewOrder;
  Function(bool)? onConnectionChange;

  bool get isConnected => _isConnected;

  Future<void> connect(String serverUrl, {required String token}) async {
    var url = serverUrl;
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (url.startsWith('http://')) url = url.replaceFirst('http://', 'https://');
    _serverUrl = url;
    _authToken = token;
    _connect();
  }

  void _connect() {
    if (_serverUrl == null || _authToken == null) return;
    try {
      print('[WebSocket] Connecting to: $_serverUrl');

      _socket = IO.io(_serverUrl!, <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
        'reconnection': true,
        'reconnectionDelay': 5000,
        'reconnectionAttempts': 100,
        'auth': {'token': _authToken},
      });

      _socket!.onConnect((_) {
        print('[WebSocket] Connected');
        _isConnected = true;
        onConnectionChange?.call(true);
        _logService.info(LogType.general, 'WebSocket baglantisi kuruldu', details: {'server': _serverUrl});
      });

      _socket!.onDisconnect((_) {
        print('[WebSocket] Disconnected');
        _isConnected = false;
        onConnectionChange?.call(false);
      });

      _socket!.onConnectError((error) {
        print('[WebSocket] Connect error: $error');
        _isConnected = false;
        onConnectionChange?.call(false);
        _logService.error(LogType.error, 'WebSocket baglanti hatasi', details: {'error': error.toString()});
      });

      // Backend panel.syncresto.com 'order-received' event emit eder (web/marketplace orders).
      // 18 May 2026: Backend payload'i camelCase + minimal (panelId, source, orderNumber, total, customerName).
      // Flutter snake_case bekliyor, normalize edelim. ID yoksa hemen sonra getOrder ile cekilir.
      _socket!.on('order-received', (data) {
        try {
          if (data is Map) {
            final raw = Map<String, dynamic>.from(data);
            final normalized = <String, dynamic>{
              // Snake_case alanlar (Flutter standardi)
              'order_number': raw['order_number'] ?? raw['orderNumber'] ?? '',
              'source': raw['source'] ?? 'web',
              'total': raw['total'] ?? 0,
              'customer_name': raw['customer_name'] ?? raw['customerName'] ?? '',
              'customer_phone': raw['customer_phone'] ?? raw['customerPhone'] ?? '',
              'panel_id': raw['panel_id'] ?? raw['panelId'],
              // ID — backend emit'inde gonderilmeyebilir, OrderService order_number ile DB'den cekecek
              'id': raw['id'] ?? raw['orderId'] ?? raw['order_id'],
              // Items — backend emit'inde yok, OrderService API call'ile cekecek
              'items': raw['items'] ?? [],
              'created_at': raw['created_at'] ?? DateTime.now().toIso8601String(),
              // Tum ham veriyi de tutalim (gelecek alan eklemeleri icin)
              '_raw': raw,
            };
            print('[WebSocket] order-received: ${normalized['order_number']} (id=${normalized['id']})');
            onNewOrder?.call(normalized);
          }
        } catch (e) {
          print('[WebSocket] order-received parse hata: $e');
        }
      });

      // Backward-compat: web siparisleri 'new_web_order' eventi ile de gelebilir
      _socket!.on('new_web_order', (data) {
        try {
          if (data is Map) {
            final order = Map<String, dynamic>.from(data['order'] ?? data);
            onNewOrder?.call(order);
          }
        } catch (_) {}
      });
    } catch (e) {
      print('[WebSocket] Connection setup error: $e');
      _isConnected = false;
      onConnectionChange?.call(false);
    }
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
    onConnectionChange?.call(false);
  }

  void dispose() {
    disconnect();
  }
}
