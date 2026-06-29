// =============================================================================
// SyncResto Print — MÜŞTERİ/ÖZET FİŞİ: online HTML → görsel → ESC/POS raster → IP:9100
// 29 Haz 2026 (Mustafa: "özet fiş sitede nasılsa BİREBİR olacak").
//
// Özet/müşteri fişi = onlinedeki ÖZEL HTML tasarımı (admin.js generateReceiptHTML +
// admin.css + QR). Backend /orders/:id/receipt-html JS'li TAM HTML döndürür (TEK
// KAYNAK — sitede değişince burası da değişir, build YOK). ?noprint=1 ile otomatik
// window.print TETİKLENMEZ (PDF'i biz CDP ile alacağız).
//
// AĞ TERMALİNE (IP:9100) basım: OS yazıcı sürücüsü/eşleştirme YOK. HTML → PDF
// → raster görsel (printing.raster) → ESC/POS raster komutu (Generator.imageRaster)
// → ham TCP IP:9100 (mutfak fişiyle aynı yol).
//
// 29 Haz 2026 — HTML→PDF MOTORU GERÇEK CHROMIUM'A GEÇTİ: htmltopdfwidgets (saf Dart)
// render'ı sitedeki Chrome window.print PDF'ine BENZEMİYORDU (CSS/JS/QR eksik). Çözüm:
// flutter_inappwebview (Windows backend = WebView2 / Edge Chromium). Gizli HeadlessInAppWebView
// ile HTML yüklenir, sayfanın kendi JS'i QR'ı üretir, sonra Chrome DevTools Protocol
// `Page.printToPDF` ile PDF byte'ı alınır → sitedeki window.print PDF'iyle AYNI motor, AYNI çıktı.
//   - flutter_inappwebview_windows 0.6.0'da `createPdf()` Dart'ta var AMA native dispatch
//     tablosunda YOK → runtime'da UnimplementedError. O yüzden createPdf KULLANMIYORUZ.
//     Bunun yerine native olarak DESTEKLENEN `callDevToolsProtocolMethod` (CDP) kullanılır.
//   - CDP `Page.printToPDF` 80mm fiş için: paperWidth=3.149in, kenar boşluğu ~0,
//     printBackground=true, scale=1, preferCSSPageSize=true (HTML @page size'ı varsa).
//
// Sonraki adım (printing.raster → image → ESC/POS) AYNEN korundu (çalışıyordu).
//
// macOS SINIRI: WebView2 Windows-only. Mac'te _htmlToPdf null döner (app çökmez,
// sadece Mac'te önizleme/basım yok — saha Windows'ta tam çalışır).
//
// TEK-SEFERDE-TEK-PRINT: WebView2 aynı anda tek print işlemi destekler + headless webview'i
// seri kullanmak en güvenlisi → _serialLock ile basım/önizleme sıraya alınır (çakışma yok).
//
// İZOLE: mutfak ürün fişi (printer_service.dart ESC/POS, _generateOrderReceipt) AYRI.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' show Size;
// `Printer` hem flutter_inappwebview hem printing tarafından export ediliyor → çakışma.
// Bize buradan webview API'leri lazım; `Printer`'ı GİZLE (listOsPrinters printing'den kullanır).
import 'package:flutter_inappwebview/flutter_inappwebview.dart' hide Printer;
import 'package:printing/printing.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'log_service.dart';

class HtmlPrintService {
  static final HtmlPrintService _instance = HtmlPrintService._internal();
  factory HtmlPrintService() => _instance;
  HtmlPrintService._internal();

  final LogService _log = LogService();

  // TEK-SEFERDE-TEK-PRINT kilidi: WebView2/CDP aynı anda iki print'i E_ABORT'la reddeder
  // ve headless webview'i seri kullanmak en güvenlisi. Completer zinciri ile seri kuyruk.
  Future<void> _serialLock = Future<void>.value();

  /// OS'ta kurulu yazıcıları listele (ayar ekranı için — opsiyonel, artık zorunlu değil).
  Future<List<Printer>> listOsPrinters() async {
    try {
      return await Printing.listPrinters();
    } catch (e) {
      _log.warning(LogType.general, 'OS yazıcı listesi alinamadi: $e');
      return [];
    }
  }

  /// Basım/önizleme işini seri kuyruğa al (aynı anda 2 WebView2 print çakışmasın).
  Future<T?> _runSerial<T>(Future<T?> Function() job) {
    final completer = Completer<T?>();
    final previous = _serialLock;
    _serialLock = completer.future.then<void>((_) {}, onError: (_) {});
    previous.whenComplete(() async {
      try {
        completer.complete(await job());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// GERÇEK CHROMIUM (WebView2) HTML → PDF. Sitedeki Chrome window.print ile BİREBİR motor.
  /// Gizli HeadlessInAppWebView'e HTML yüklenir, sayfanın JS'i (QR vs.) çalışır, onLoadStop +
  /// kısa bekleme sonrası CDP `Page.printToPDF` ile PDF byte'ı alınır (80mm fiş ayarları).
  /// Windows-only; macOS'ta null döner (graceful).
  Future<Uint8List?> _htmlToPdf(String html) async {
    if (!Platform.isWindows) {
      _log.warning(LogType.general,
          'HTML→PDF (WebView2) yalnizca Windows: bu platformda atlandi (Platform=${Platform.operatingSystem})');
      return null;
    }
    return _runSerial<Uint8List>(() => _htmlToPdfInternal(html));
  }

  /// Asıl WebView2 + CDP işi. _runSerial içinden çağrılır (kilitli).
  Future<Uint8List?> _htmlToPdfInternal(String html) async {
    HeadlessInAppWebView? headless;
    final pdfCompleter = Completer<Uint8List?>();
    var resolved = false;

    void finish(Uint8List? bytes) {
      if (resolved) return;
      resolved = true;
      if (!pdfCompleter.isCompleted) pdfCompleter.complete(bytes);
    }

    try {
      headless = HeadlessInAppWebView(
        // Gizli/ekran-dışı render — görünür pencere açılmaz.
        initialSize: const Size(384, 1200), // ~80mm @96dpi genişlik referansı
        initialSettings: InAppWebViewSettings(
          transparentBackground: false,
          // JS sayfanın kendi QR/format script'i için açık (TAM HTML, static değil).
          javaScriptEnabled: true,
          supportZoom: false,
        ),
        onLoadStop: (controller, url) async {
          try {
            // Sayfanın JS'i (QR üretimi, layout) tamamlansın diye kısa bekleme.
            // DOMContentLoaded onLoadStop'ta zaten geçmiştir; QR canvas/SVG render +
            // font yüklemesi için küçük tampon (kanıtlı "render bitmeden bas" tuzağı).
            await Future<void>.delayed(const Duration(milliseconds: 350));

            // CDP Page.printToPDF — Chromium'un kendi PDF motoru (window.print ile aynı).
            // 80mm fiş: paperWidth=3.149in, kenarlar ~0, printBackground=true (admin.css
            // arkaplan/renkler), scale=1. preferCSSPageSize=true → HTML'de @page size varsa
            // ona uyar; yoksa paperWidth/paperHeight kullanılır. paperHeight büyük (fiş tek parça).
            final result = await controller.callDevToolsProtocolMethod(
              methodName: 'Page.printToPDF',
              parameters: {
                'printBackground': true,
                'scale': 1.0,
                'paperWidth': 3.149, // 80mm = 3.149 inch
                'paperHeight': 200.0, // büyük → fiş tek sayfa (uzunsa CDP böler)
                'marginTop': 0.0,
                'marginBottom': 0.0,
                'marginLeft': 0.0,
                'marginRight': 0.0,
                'preferCSSPageSize': true,
                'displayHeaderFooter': false, // tarih/URL header/footer istemiyoruz
              },
            );

            final dataB64 = (result is Map) ? result['data'] as String? : null;
            if (dataB64 == null || dataB64.isEmpty) {
              _log.error(LogType.error,
                  'WebView2 CDP Page.printToPDF bos döndü (result=$result)');
              finish(null);
              return;
            }
            finish(base64Decode(dataB64));
          } catch (e) {
            _log.error(LogType.error, 'WebView2 CDP printToPDF hatasi: $e');
            finish(null);
          }
        },
        onReceivedError: (controller, request, error) {
          // Ana frame yükleme hatası → PDF üretilemez.
          _log.warning(LogType.general,
              'WebView2 yükleme hatasi: ${error.description} (${request.url})');
          finish(null);
        },
      );

      await headless.run();

      final controller = headless.webViewController;
      if (controller == null) {
        _log.error(LogType.error, 'WebView2 controller null (headless run basarisiz)');
        finish(null);
      } else {
        // HTML string'i UTF-8 olarak yükle (Türkçe karakter sorunsuz). baseUrl: göreli
        // asset/QR isteklerinin çözülebilmesi için (HTML tam standalone ise etkisi yok).
        await controller.loadData(
          data: html,
          mimeType: 'text/html',
          encoding: 'utf8',
          baseUrl: WebUri('https://panel.syncresto.com/'),
        );
      }

      // PDF gelene kadar bekle (timeout güvenliği: ağ/JS takılırsa app kilitlenmesin).
      final pdf = await pdfCompleter.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          _log.error(LogType.error, 'WebView2 HTML→PDF zaman asimi (20sn)');
          return null;
        },
      );
      return pdf;
    } catch (e) {
      _log.error(LogType.error, 'HTML→PDF (WebView2) genel hata: $e');
      return null;
    } finally {
      try {
        await headless?.dispose();
      } catch (_) {}
    }
  }

  /// ÖNİZLEME (yazıcıya göndermez): TAM HTML → WebView2 (Chromium) PDF bytes.
  /// Ekranda PdfPreview ile gösterilir. Gerçek basımla AYNI render motoru (WebView2),
  /// yani önizlemede görünen = yazıcıdan çıkacak tasarım (sitedeki window.print ile birebir).
  /// macOS'ta null döner (Mac'te önizleme yok — saha Windows).
  Future<Uint8List?> buildPdfFromHtml(String html) async {
    try {
      return await _htmlToPdf(html);
    } catch (e) {
      _log.error(LogType.error, 'Önizleme PDF üretilemedi: $e');
      return null;
    }
  }

  /// Online HTML özet fişini AĞ TERMALİNE (IP:9100) ESC/POS raster olarak bas.
  /// HTML → (WebView2) PDF → raster görsel → Generator.imageRaster → bytes. sendBytes ile gönderilir.
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
