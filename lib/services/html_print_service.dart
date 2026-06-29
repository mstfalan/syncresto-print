// =============================================================================
// SyncResto Print — MÜŞTERİ/ÖZET FİŞİ: online HTML → görsel → ESC/POS raster → IP:9100
// 29 Haz 2026 (Mustafa: "özet fiş sitede nasılsa BİREBİR olacak").
//
// Özet/müşteri fişi = onlinedeki ÖZEL HTML tasarımı (admin.js generateReceiptHTML +
// admin.css + QR). Backend /orders/:id/receipt-html standalone HTML döndürür (TEK
// KAYNAK — sitede değişince burası da değişir, build YOK).
//
// AĞ TERMALİNE (IP:9100) basım: OS yazıcı sürücüsü/eşleştirme YOK. HTML → PDF
// (printing/Chromium) → raster görsel (printing.raster) → ESC/POS raster komutu
// (Generator.imageRaster) → ham TCP IP:9100 (mutfak fişiyle aynı yol).
//
// İZOLE: mutfak ürün fişi (printer_service.dart ESC/POS, _generateOrderReceipt) AYRI.
// =============================================================================

import 'dart:typed_data';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'log_service.dart';

class HtmlPrintService {
  static final HtmlPrintService _instance = HtmlPrintService._internal();
  factory HtmlPrintService() => _instance;
  HtmlPrintService._internal();

  final LogService _log = LogService();

  /// OS'ta kurulu yazıcıları listele (ayar ekranı için — opsiyonel, artık zorunlu değil).
  Future<List<Printer>> listOsPrinters() async {
    try {
      return await Printing.listPrinters();
    } catch (e) {
      _log.warning(LogType.general, 'OS yazıcı listesi alinamadi: $e');
      return [];
    }
  }

  /// HTML → 80mm PDF (Chromium/printing). Yükseklik içeriğe göre uzar.
  Future<Uint8List?> _htmlToPdf(String html) async {
    try {
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

  /// Online HTML özet fişini AĞ TERMALİNE (IP:9100) ESC/POS raster olarak bas.
  /// HTML → PDF → raster görsel → Generator.imageRaster → bytes. sendBytes ile gönderilir.
  /// Döner: ESC/POS byte listesi (null = üretilemedi, caller fallback/kuyruk).
  Future<List<int>?> buildEscposFromHtml(String html, {int dpi = 203}) async {
    try {
      final pdf = await _htmlToPdf(html);
      if (pdf == null) return null;

      // PDF → raster görsel(ler). 80mm @203dpi ≈ 576px genişlik (termal tam en).
      // raster() sayfa sayfa image verir; özet fiş tek sayfa beklenir (uzunsa birleştir).
      final List<img.Image> pages = [];
      await for (final page in Printing.raster(pdf, dpi: dpi.toDouble())) {
        final png = await page.toPng();
        final decoded = img.decodePng(png);
        if (decoded != null) pages.add(decoded);
      }
      if (pages.isEmpty) return null;

      // Sayfaları dikey birleştir (tek görsel) — termal genişliğine (576px) ölçekle.
      final merged = _mergeVertical(pages);
      const targetWidth = 576; // 80mm @203dpi
      final resized = merged.width > targetWidth
          ? img.copyResize(merged, width: targetWidth)
          : merged;
      // Termal için 1-bit benzeri: gri tonlama (imageRaster zaten dither/threshold uygular)
      final gray = img.grayscale(resized);

      final profile = await CapabilityProfile.load();
      final generator = Generator(PaperSize.mm80, profile);
      List<int> bytes = [];
      bytes += generator.imageRaster(gray, align: PosAlign.center);
      bytes += generator.feed(2);
      bytes += generator.cut();
      return bytes;
    } catch (e) {
      _log.error(LogType.error, 'HTML→ESC/POS raster hatasi: $e');
      return null;
    }
  }

  // Birden çok sayfa görselini dikey birleştir (aynı genişliğe getirip alt alta).
  img.Image _mergeVertical(List<img.Image> pages) {
    if (pages.length == 1) return pages.first;
    final w = pages.map((p) => p.width).reduce((a, b) => a > b ? a : b);
    final totalH = pages.fold<int>(0, (s, p) => s + p.height);
    final out = img.Image(width: w, height: totalH);
    img.fill(out, color: img.ColorRgb8(255, 255, 255));
    int y = 0;
    for (final p in pages) {
      img.compositeImage(out, p, dstX: 0, dstY: y);
      y += p.height;
    }
    return out;
  }
}
