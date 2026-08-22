// =============================================================================
// SyncResto Print — USB/OS Yazıcı (Windows RAW spooler pass-through)
// 22 Ağu 2026 — Mustafa
//
// AMAÇ: Özet/müşteri fişi AĞ (IP:9100) ile gönderilemezse YEDEK olarak, print-PC'ye
// USB ile takılı Windows yazıcısına AYNI ESC/POS byte'larını gönder (kesici korunur).
//
// 🔴 İZOLE + YEDEK: IP:9100 yolu BİRİNCİL ve DEĞİŞMEDİ. Bu yol yalnızca ağ başarısızsa
//    ve ayar AÇIKSA devreye girer (default KAPALI). Mutfak ESC/POS akışına dokunmaz.
//
// YÖNTEM: winspool.drv RAW datatype — OpenPrinter → StartDocPrinter(pDatatype:'RAW')
//    → StartPagePrinter → WritePrinter → EndPage/EndDoc/ClosePrinter. GDI/sürücü yok,
//    IP:9100 ile BİREBİR aynı byte'lar → kesici/feed/raster davranışı korunur.
// x64: Flutter Windows x64 derler; win32 FFI pointer boyutu otomatik → sorunsuz.
// macOS: Platform.isWindows guard → winspool HİÇ çağrılmaz (DynamicLibrary açılmaz).
// =============================================================================

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'printer_service.dart';
import 'log_service.dart';

class OsPrinterService {
  static final OsPrinterService _instance = OsPrinterService._internal();
  factory OsPrinterService() => _instance;
  OsPrinterService._internal();

  final LogService _log = LogService();

  // Win32 yazıcı durum/nitelik sabitleri (win32 paketinde adlandırılmış sabit garanti
  // değil → yerel tanım; değerler kalıcı Win32 API değerleridir).
  static const int _PRINTER_STATUS_PAUSED = 0x00000001;
  static const int _PRINTER_STATUS_ERROR = 0x00000002;
  static const int _PRINTER_STATUS_PAPER_JAM = 0x00000008;
  static const int _PRINTER_STATUS_PAPER_OUT = 0x00000010;
  static const int _PRINTER_STATUS_OFFLINE = 0x00000080;
  static const int _PRINTER_STATUS_NOT_AVAILABLE = 0x00001000;
  static const int _PRINTER_STATUS_DOOR_OPEN = 0x00400000;
  static const int _PRINTER_ATTRIBUTE_WORK_OFFLINE = 0x00000400;

  /// Yazıcı basmaya hazır mı? (offline/hata/kağıt yok ise false → hayalet-baskı önleme).
  /// Durum okunamazsa "hazır" varsayar (aşırı kısıtlayıcı olma).
  Future<bool> isReady(String printerName) async {
    if (!Platform.isWindows || printerName.isEmpty) return false;
    final pName = printerName.toNativeUtf16();
    final phPrinter = calloc<IntPtr>();
    try {
      if (OpenPrinter(pName, phPrinter, nullptr) == 0) return false;
      final hPrinter = phPrinter.value;
      try {
        final pcbNeeded = calloc<Uint32>();
        try {
          GetPrinter(hPrinter, 2, nullptr, 0, pcbNeeded);
          final cb = pcbNeeded.value;
          if (cb == 0) return true; // durum alınamadı → hazır varsay
          final buf = calloc<Uint8>(cb);
          try {
            if (GetPrinter(hPrinter, 2, buf, cb, pcbNeeded) == 0) return true;
            final info = buf.cast<PRINTER_INFO_2>().ref;
            const badStatus = _PRINTER_STATUS_PAUSED |
                _PRINTER_STATUS_ERROR |
                _PRINTER_STATUS_PAPER_JAM |
                _PRINTER_STATUS_PAPER_OUT |
                _PRINTER_STATUS_OFFLINE |
                _PRINTER_STATUS_NOT_AVAILABLE |
                _PRINTER_STATUS_DOOR_OPEN;
            if ((info.Status & badStatus) != 0) return false;
            if ((info.Attributes & _PRINTER_ATTRIBUTE_WORK_OFFLINE) != 0) return false;
            return true;
          } finally {
            calloc.free(buf);
          }
        } finally {
          calloc.free(pcbNeeded);
        }
      } finally {
        ClosePrinter(hPrinter);
      }
    } catch (e) {
      _log.warning(LogType.error, '[USB] durum kontrol hata ($printerName): $e');
      return false;
    } finally {
      calloc.free(pName);
      calloc.free(phPrinter);
    }
  }

  /// Ham ESC/POS byte'larını Windows yazıcısına RAW gönder. Başarı = spooler kabul etti.
  Future<bool> sendRawBytes(String printerName, List<int> bytes,
      {String docName = 'SyncResto-Ozet-Fis'}) async {
    if (!Platform.isWindows || printerName.isEmpty || bytes.isEmpty) return false;
    if (!await isReady(printerName)) {
      _log.warning(LogType.error, '[USB] yazıcı hazır değil, atlandı: $printerName');
      return false;
    }
    final pName = printerName.toNativeUtf16();
    final phPrinter = calloc<IntPtr>();
    final docInfo = calloc<DOC_INFO_1>();
    final pDocName = docName.toNativeUtf16();
    final pDatatype = 'RAW'.toNativeUtf16();
    final pcWritten = calloc<Uint32>();
    Pointer<Uint8>? data;
    try {
      if (OpenPrinter(pName, phPrinter, nullptr) == 0) {
        _log.warning(LogType.error, '[USB] OpenPrinter başarısız: $printerName');
        return false;
      }
      final hPrinter = phPrinter.value;
      try {
        docInfo.ref
          ..pDocName = pDocName
          ..pOutputFile = nullptr
          ..pDatatype = pDatatype;
        if (StartDocPrinter(hPrinter, 1, docInfo) == 0) {
          _log.warning(LogType.error, '[USB] StartDocPrinter başarısız: $printerName');
          return false;
        }
        try {
          if (StartPagePrinter(hPrinter) == 0) return false;
          try {
            data = calloc<Uint8>(bytes.length);
            data.asTypedList(bytes.length).setAll(0, bytes);
            var total = 0;
            while (total < bytes.length) {
              final ok = WritePrinter(
                  hPrinter, (data + total).cast(), bytes.length - total, pcWritten);
              if (ok == 0) return false;
              final w = pcWritten.value;
              if (w <= 0) return false;
              total += w;
            }
            final done = total == bytes.length;
            if (done) _log.logAction('[USB] RAW basıldı: $printerName ($total byte)');
            return done;
          } finally {
            EndPagePrinter(hPrinter);
          }
        } finally {
          EndDocPrinter(hPrinter);
        }
      } finally {
        ClosePrinter(hPrinter);
      }
    } catch (e) {
      _log.error(LogType.error, '[USB] gönderim hata ($printerName): $e');
      return false;
    } finally {
      calloc.free(pName);
      calloc.free(phPrinter);
      calloc.free(docInfo);
      calloc.free(pDocName);
      calloc.free(pDatatype);
      calloc.free(pcWritten);
      if (data != null) calloc.free(data);
    }
  }

  /// Kurulu Windows yazıcılarına test fişi (Ayarlar → USB Test Fişi).
  Future<bool> testPrint(String printerName) async {
    final bytes = await PrinterService().generateTestReceiptBytes();
    return sendRawBytes(printerName, bytes, docName: 'SyncResto-Test');
  }
}
