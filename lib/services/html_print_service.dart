// =============================================================================
// SyncResto Print — MÜŞTERİ/ÖZET FİŞİ: online HTML → görsel → ESC/POS raster → IP:9100
// 29 Haz 2026 (Mustafa: "özet fiş sitede nasılsa BİREBİR olacak").
//
// Özet/müşteri fişi = onlinedeki ÖZEL HTML tasarımı (admin.js generateReceiptHTML +
// admin.css + QR). Backend /orders/:id/receipt-html?static=1 standalone, JS'siz,
// sade-inline-CSS, table-layout STATİK HTML döndürür (TEK KAYNAK — sitede değişince
// burası da değişir, build YOK).
//
// AĞ TERMALİNE (IP:9100) basım: OS yazıcı sürücüsü/eşleştirme YOK. HTML → PDF
// → raster görsel (printing.raster) → ESC/POS raster komutu (Generator.imageRaster)
// → ham TCP IP:9100 (mutfak fişiyle aynı yol).
//
// 29 Haz 2026 — HTML→PDF MOTORU DEĞİŞTİ: Printing.convertHtml Windows masaüstünde
// MissingPluginException veriyordu (Chromium yok). Yerine htmltopdfwidgets (saf Dart,
// Chromium'suz): HTMLToPdf().convert(html) → List<pw.Widget> → pdf paketi MultiPage.
// Sonraki adım (printing.raster → image → ESC/POS) AYNEN korundu (çalışıyordu).
//
// QR: static HTML'de [[QR:https://...maps?q=lat,lng]] placeholder metni gelir. barcode
// paketiyle QR matrisi üretip image (v4) canvas'a çizer → PNG → base64 data URI → HTML'e
// <img> olarak gömeriz (htmltopdfwidgets <img> data-uri'yi render eder).
//
// İZOLE: mutfak ürün fişi (printer_service.dart ESC/POS, _generateOrderReceipt) AYRI.
// =============================================================================

import 'dart:convert';
import 'dart:typed_data';
import 'package:printing/printing.dart';
import 'package:pdf/widgets.dart' as pw;
// htmltopdfwidgets, package:pdf/pdf.dart'ı (PdfPageFormat) ve package:pdf/widgets.dart'ı
// re-export eder; PdfPageFormat'ı buradan kullanıyoruz (ayrı pdf/pdf.dart import gereksiz).
import 'package:htmltopdfwidgets/htmltopdfwidgets.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'package:barcode/barcode.dart' as bc;
import 'log_service.dart';

class HtmlPrintService {
  static final HtmlPrintService _instance = HtmlPrintService._internal();
  factory HtmlPrintService() => _instance;
  HtmlPrintService._internal();

  final LogService _log = LogService();

  // [[QR:url]] placeholder (backend static HTML, lat/lng varsa).
  static final RegExp _qrPlaceholder = RegExp(r'\[\[QR:([^\]]+)\]\]');

  /// OS'ta kurulu yazıcıları listele (ayar ekranı için — opsiyonel, artık zorunlu değil).
  Future<List<Printer>> listOsPrinters() async {
    try {
      return await Printing.listPrinters();
    } catch (e) {
      _log.warning(LogType.general, 'OS yazıcı listesi alinamadi: $e');
      return [];
    }
  }

  /// STATİK HTML → 80mm PDF (htmltopdfwidgets, saf Dart — Chromium YOK, Windows uyumlu).
  /// `HTMLToPdf().convert(html)` → `List<pw.Widget>`; MultiPage ile 80mm sayfaya basılır.
  /// Yükseklik içeriğe göre uzar (double.infinity + MultiPage otomatik sayfalama).
  Future<Uint8List?> _htmlToPdf(String html) async {
    try {
      final List<pw.Widget> widgets = await HTMLToPdf().convert(html);
      final doc = pw.Document();
      doc.addPage(
        pw.MultiPage(
          pageFormat: const PdfPageFormat(
            80 * PdfPageFormat.mm,
            double.infinity,
            marginAll: 2 * PdfPageFormat.mm,
          ),
          build: (context) => widgets,
        ),
      );
      return await doc.save();
    } catch (e) {
      _log.error(LogType.error, 'HTML→PDF cevirme hatasi (htmltopdfwidgets): $e');
      return null;
    }
  }

  /// `[[QR:url]]` placeholder'larını çöz: URL varsa QR'ı PNG base64 `img` etiketi olarak
  /// göm, URL yoksa/üretilemezse placeholder'ı temizle. Birden fazla placeholder destekler.
  String _resolveQrPlaceholders(String html) {
    return html.replaceAllMapped(_qrPlaceholder, (m) {
      final url = (m.group(1) ?? '').trim();
      if (url.isEmpty) return '';
      try {
        final png = _buildQrPng(url);
        if (png == null) return '';
        final b64 = base64Encode(png);
        // 76px ≈ 20mm @96dpi. Ortalanması fiş HTML'inin kendi CSS'ine bırakılır.
        return '<img src="data:image/png;base64,$b64" width="76" height="76" '
            'style="width:76px;height:76px;" alt="QR" />';
      } catch (e) {
        _log.warning(LogType.general, 'QR üretilemedi (placeholder temizlendi): $e');
        return '';
      }
    });
  }

  /// QR kodu PNG byte olarak üret (saf Dart). barcode.Barcode.qrCode().make(...) →
  /// BarcodeBar elemanları (left/top/width/height/black); image (v4) canvas'a siyah
  /// kareler çizip encodePng. quiet-zone için kenarda beyaz boşluk bırakılır.
  Uint8List? _buildQrPng(String data, {int size = 152}) {
    try {
      final qr = bc.Barcode.qrCode(
        errorCorrectLevel: bc.BarcodeQRCorrectionLevel.medium,
      );
      // Beyaz tuval (size x size). Modüller bunun üzerine siyah çizilir.
      final image = img.Image(width: size, height: size);
      img.fill(image, color: img.ColorRgb8(255, 255, 255));
      final black = img.ColorRgb8(0, 0, 0);

      for (final el in qr.make(data, width: size.toDouble(), height: size.toDouble())) {
        if (el is! bc.BarcodeBar) continue;
        if (!el.black) continue;
        final x1 = el.left.floor();
        final y1 = el.top.floor();
        final x2 = (el.left + el.width).ceil() - 1;
        final y2 = (el.top + el.height).ceil() - 1;
        img.fillRect(image, x1: x1, y1: y1, x2: x2, y2: y2, color: black);
      }
      return Uint8List.fromList(img.encodePng(image));
    } catch (e) {
      _log.warning(LogType.general, 'QR PNG üretim hatasi: $e');
      return null;
    }
  }

  /// Online HTML özet fişini AĞ TERMALİNE (IP:9100) ESC/POS raster olarak bas.
  /// HTML → PDF → raster görsel → Generator.imageRaster → bytes. sendBytes ile gönderilir.
  /// Döner: ESC/POS byte listesi (null = üretilemedi, caller fallback/kuyruk).
  Future<List<int>?> buildEscposFromHtml(String html, {int dpi = 203}) async {
    try {
      // [[QR:url]] placeholder'larını gerçek <img> base64 QR'a çevir (yoksa temizle).
      final resolvedHtml = _resolveQrPlaceholders(html);

      final pdf = await _htmlToPdf(resolvedHtml);
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
