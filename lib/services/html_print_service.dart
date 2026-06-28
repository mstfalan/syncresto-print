// =============================================================================
// SyncResto Print — MÜŞTERİ/ÖZET FİŞİ HTML basım servisi (28 Haz 2026)
//
// Mustafa kuralı:
//   - Müşteri/özet fişi = onlinedeki HTML tasarımı BİREBİR (admin.js generateReceiptHTML
//     + admin.css). Backend /orders/:id/receipt-html standalone HTML döndürür (TEK KAYNAK
//     — sitede fiş değişince burası da değişir, Flutter build GEREKMEZ).
//   - Yazdırma "Chrome'da Yazdır → termal seç" gibi: HTML → PDF → OS yazıcı sürücüsü.
//     Termaller Windows'ta KURULU (Chrome'da görünüyor). Ham TCP IP:9100 DEĞİL.
//
// `printing` paketi: HtmlToPdf ile HTML'i PDF'e çevirir, sonra OS yazıcısına basar.
//   - Sessiz basım (yazıcı adı biliniyorsa): Printing.directPrintPdf(printer, ...)
//   - Yazıcı seçilmemişse: Printing.layoutPdf (Chrome gibi yazdır penceresi açılır,
//     kullanıcı termali seçer — Mustafa'nın tarif ettiği akış).
//
// İZOLASYON: Bu servis SADECE müşteri/özet HTML fişi içindir. Mutfak ürün fişi
// (ESC/POS, printer_service.dart) HİÇ DOKUNULMAZ. Flutter POS AYRI repo.
// =============================================================================

import 'dart:typed_data';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'log_service.dart';

class HtmlPrintService {
  static final HtmlPrintService _instance = HtmlPrintService._internal();
  factory HtmlPrintService() => _instance;
  HtmlPrintService._internal();

  final LogService _log = LogService();

  /// OS'ta kurulu yazıcıları listele (ayar ekranında eşleştirme için).
  /// Dönen: Printer (name, url, isDefault...). Termaller burada görünür.
  Future<List<Printer>> listOsPrinters() async {
    try {
      return await Printing.listPrinters();
    } catch (e) {
      _log.warning(LogType.general, 'OS yazıcı listesi alinamadi: $e');
      return [];
    }
  }

  /// HTML'i PDF'e çevir (Chrome headless / printing motoru).
  /// 80mm termal = ~226pt genişlik. Fiş CSS @page ile yüksekliği otomatik.
  Future<Uint8List?> _htmlToPdf(String html) async {
    try {
      // 80mm rulo: genişlik sabit, yükseklik içeriğe göre uzar.
      return await Printing.convertHtml(
        format: const PdfPageFormat(
          80 * PdfPageFormat.mm,
          double.infinity,
          marginAll: 2 * PdfPageFormat.mm,
        ),
        html: html,
      );
    } catch (e) {
      _log.error(LogType.error, 'HTML→PDF cevirme hatasi: $e');
      return null;
    }
  }

  /// Belirli bir OS yazıcısına SESSİZ bas (yazıcı adı/url biliniyorsa).
  /// osPrinterName = panel "Özet Fiş Yazıcısı" → eşleştirilmiş Windows yazıcı adı.
  /// Döner: true = basıldı. Yazıcı bulunamaz/hata → false (caller fallback eder).
  Future<bool> printHtmlToOsPrinter(String html, String? osPrinterName) async {
    final pdf = await _htmlToPdf(html);
    if (pdf == null) return false;

    try {
      // Yazıcı adı verilmişse onu bul, sessiz bas.
      if (osPrinterName != null && osPrinterName.isNotEmpty) {
        final printers = await listOsPrinters();
        Printer? target;
        for (final p in printers) {
          if (p.name == osPrinterName || p.url == osPrinterName) { target = p; break; }
        }
        if (target != null) {
          final ok = await Printing.directPrintPdf(
            printer: target,
            onLayout: (_) async => pdf,
            name: 'SyncResto-Ozet-Fis',
          );
          if (ok) {
            _log.logAction('Özet fiş HTML basildi (sessiz): $osPrinterName');
            return true;
          }
          _log.warning(LogType.action, 'directPrintPdf false dondu: $osPrinterName');
        } else {
          _log.warning(LogType.action,
            'Eşleştirilen OS yazıcısı bulunamadi: "$osPrinterName" — yazdır penceresi açılacak');
        }
      }
      // Yazıcı yok/bulunamadı → Chrome gibi yazdır penceresi (kullanıcı termali seçer).
      // Mustafa: "yazdır dediğimizde Chrome'un yazdırma penceresi çıkıyor, orda termali seçip bastırıyoruz".
      final ok = await Printing.layoutPdf(
        onLayout: (_) async => pdf,
        name: 'SyncResto-Ozet-Fis',
        usePrinterSettings: true,
      );
      if (ok) _log.logAction('Özet fiş HTML basildi (yazdır penceresi)');
      return ok;
    } catch (e) {
      _log.error(LogType.error, 'Özet fiş HTML basım hatasi: $e');
      return false;
    }
  }

  /// Önizleme (yazdırmadan PDF byte üret) — ayar ekranı "Önizle" için.
  Future<Uint8List?> previewPdf(String html) => _htmlToPdf(html);
}
