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
import 'api_service.dart';

class HtmlPrintService {
  static final HtmlPrintService _instance = HtmlPrintService._internal();
  factory HtmlPrintService() => _instance;
  HtmlPrintService._internal();

  final LogService _log = LogService();

  // TEK-SEFERDE-TEK-PRINT kilidi: WebView2/CDP aynı anda iki print'i E_ABORT'la reddeder
  // ve headless webview'i seri kullanmak en güvenlisi. Completer zinciri ile seri kuyruk.
  Future<void> _serialLock = Future<void>.value();

  // 30 Haz 2026 — ÖNİZLEME HIZLANDIRMA: KALICI (singleton) headless WebView2.
  // Eski kod her işte yeni HeadlessInAppWebView oluşturup run() (WebView2/Edge süreç
  // soğuk-init, ~yüzlerce ms) edip dispose ediyordu → art arda/çakışan basım+önizlemede
  // hissedilir gecikme. Artık WebView2'yi BİR KEZ run() edip tutuyoruz; her iş sadece
  // loadUrl + CDP printToPDF. _runSerial zaten tek-seferde-tek-iş garantiliyor → paylaşım
  // güvenli (per-iş durumu instance alanlarında). Sadece Windows'ta yaşar; app kapanınca
  // disposeShared ile kapatılır (zorunlu değil — OS süreç temizler).
  HeadlessInAppWebView? _sharedHeadless;
  InAppWebViewController? _sharedController;
  // Aktif iş durumu (tek anda tek iş — _runSerial garantisi). onLoadStop bunları okur.
  Completer<Uint8List?>? _activeCompleter;
  bool _activeResolved = false;
  String? _activeUrl; // url yolu mu (about:blank sahte-sinyalini ele)

  /// WebView2 loadData baseUrl fallback origin'i — HARDCODED domain YOK. Tenant'in
  /// ApiService base'inden (scheme://host) turetilir; yoksa guvenli varsayilan.
  String _baseOriginForWebView() {
    try {
      final b = ApiService().baseUrl;
      if (b.isNotEmpty) {
        final u = Uri.parse(b);
        if (u.hasScheme && u.host.isNotEmpty) {
          return '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}/';
        }
      }
    } catch (_) {}
    return 'https://panel.syncresto.com/'; // son care (eski davranis)
  }

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

  /// GERÇEK CHROMIUM (WebView2) → PDF. Sitedeki Chrome window.print ile BİREBİR motor.
  ///
  /// 30 Haz 2026 — KÖK NEDEN FIX (printToPDF BOS data):
  /// Eski yol HTML string'i `loadData` (native = NavigateToString) ile yüklüyordu. Windows'ta
  /// bunun İKİ kanıtlanmış sorunu var:
  ///   (1) NavigateToString baseUrl'i YOK SAYAR → location=about:blank, origin=NULL → harici
  ///       CSS/JS/QR/logo kaynaklari null-origin politikasiyla cekilemez ("cache bos" kaniti),
  ///   (2) NavigateToString htmlContent 2MB ile SINIRLI; JS'li TAM HTML kolayca asar → cagri
  ///       sessizce reddedilir (failedLog), sayfa about:blank kalir → printToPDF BOS data.
  /// ÇÖZÜM: HTML string'i hic tasima. WebView2'yi GERCEK HTTP URL'ine (receipt-html?key=...)
  /// `loadUrl` (native = Navigate) ile gonder → gercek origin + 2MB sinir yok → dolu PDF.
  /// `url`: tam receipt-html adresi (api_service.receiptHtmlUrl). Windows-only; mac null.
  Future<Uint8List?> _urlToPdf(String url) async {
    if (!Platform.isWindows) {
      _log.warning(LogType.general,
          'URL→PDF (WebView2) yalnizca Windows: bu platformda atlandi (Platform=${Platform.operatingSystem})');
      return null;
    }
    return _runSerial<Uint8List>(() => _renderToPdfInternal(url: url));
  }

  /// FALLBACK (URL uretilemezse): HTML string'i loadData ile yukle. Windows null-origin/2MB
  /// risklerini tasir (bu yuzden tercih EDILMEZ) ama URL yolu kullanilamadiginda en azindan
  /// eski davranisi korur. Windows-only; mac null.
  Future<Uint8List?> _htmlToPdf(String html) async {
    if (!Platform.isWindows) {
      _log.warning(LogType.general,
          'HTML→PDF (WebView2) yalnizca Windows: bu platformda atlandi (Platform=${Platform.operatingSystem})');
      return null;
    }
    return _runSerial<Uint8List>(() => _renderToPdfInternal(html: html));
  }

  // Aktif işi bitir (onLoadStop/onReceivedError/timeout buradan tetikler).
  void _finishActive(Uint8List? bytes) {
    if (_activeResolved) return;
    _activeResolved = true;
    final c = _activeCompleter;
    if (c != null && !c.isCompleted) c.complete(bytes);
  }

  /// CDP printToPDF + sonuc okuma (paylasimli onLoadStop icinden cagrilir).
  Future<void> _capturePdf(InAppWebViewController controller) async {
    try {
      // Render-bitti GARANTISI: sabit beklemeden once gercek 'load' event'ini bekle
      // (about:blank false-positive'i + DOM/QR yarim render tuzagini eler). Sayfa
      // zaten complete ise hemen, degilse window load'a kadar (max ~10sn) bekle.
      await controller.evaluateJavascript(source: '''
        (function(){ return new Promise(function(res){
          if (document.readyState === 'complete') { res(true); return; }
          var done=false; var fin=function(){ if(!done){done=true;res(true);} };
          window.addEventListener('load', fin, {once:true});
          setTimeout(fin, 10000);
        }); })()
      ''');
      // QR canvas/SVG cizimi + web-font yuklemesi icin kucuk tampon (300→120ms: 'load'
      // zaten beklendi, fontlar genelde hazir; onizleme/basim hizlanir).
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // CDP Page.printToPDF — Chromium'un kendi PDF motoru (window.print ile aynı).
      // 80mm fiş: paperWidth=3.149in, kenarlar ~0, printBackground=true, scale=1.
      // preferCSSPageSize=true → HTML'de @page size varsa ona uyar.
      // transferMode=ReturnAsBase64 → 'data' alanini base64 ile doldurur (stream YOK;
      // WebView2'de CDP IO.read stream'leri pratikte kullanilamaz → acik garanti).
      final result = await controller.callDevToolsProtocolMethod(
        methodName: 'Page.printToPDF',
        parameters: {
          'printBackground': true,
          'scale': 1.0,
          'paperWidth': 3.149, // 80mm = 3.149 inch
          // 30 Haz 2026 — paperHeight 200in DEĞİL: 200in @203dpi ≈ 40.600px dev bitmap
          // (eski toPng yolunda dart:ui 8192 doku sınırını ~5× aşıp özet fişi öldürüyordu).
          // 60in hâlâ uzun pazaryeri fişlerine yeter; içerik aşarsa CDP böler, _mergeVertical
          // birleştirir (tek görsel). Yeni RGBA decode yolu zaten boyut-güvenli; bu ek emniyet.
          'paperHeight': 60.0,
          'marginTop': 0.0,
          'marginBottom': 0.0,
          'marginLeft': 0.0,
          'marginRight': 0.0,
          'preferCSSPageSize': true,
          'displayHeaderFooter': false,
          'transferMode': 'ReturnAsBase64',
        },
      );

      final dataB64 = (result is Map) ? result['data'] as String? : null;
      if (dataB64 == null || dataB64.isEmpty) {
        _log.error(LogType.error,
            'WebView2 CDP Page.printToPDF bos döndü (result=$result)');
        _finishActive(null);
        return;
      }
      _finishActive(base64Decode(dataB64));
    } catch (e) {
      _log.error(LogType.error, 'WebView2 CDP printToPDF hatasi: $e');
      _finishActive(null);
    }
  }

  /// Paylasilan (singleton) headless WebView2'yi garanti et (bir kez run). Windows-only.
  /// Soguk-init yalnizca ILK cagrida olur; sonraki isler ucuz loadUrl ile gelir.
  Future<InAppWebViewController?> _ensureSharedWebView() async {
    if (_sharedController != null) return _sharedController;
    final headless = HeadlessInAppWebView(
      // Gizli/ekran-dışı render — görünür pencere açılmaz.
      initialSize: const Size(384, 1200), // ~80mm @96dpi genişlik referansı
      initialSettings: InAppWebViewSettings(
        transparentBackground: false,
        // JS sayfanın kendi QR/format script'i için açık (TAM HTML, static değil).
        javaScriptEnabled: true,
        supportZoom: false,
      ),
      onLoadStop: (controller, loadedUrl) async {
        // about:blank = sahte sinyal (loadData null-origin VEYA henuz navigate olmamis).
        // URL yolundayken bunu yok say; gercek receipt-html URL'i gelince calis.
        final u = loadedUrl?.toString() ?? '';
        if (_activeUrl != null && (u.isEmpty || u.startsWith('about:blank'))) {
          return;
        }
        await _capturePdf(controller);
      },
      onReceivedError: (controller, request, error) {
        // Ana frame yükleme hatası → PDF üretilemez.
        _log.warning(LogType.general,
            'WebView2 yükleme hatasi: ${error.description} (${request.url})');
        _finishActive(null);
      },
    );
    await headless.run();
    final controller = headless.webViewController;
    if (controller == null) {
      _log.error(LogType.error, 'WebView2 controller null (headless run basarisiz)');
      try {
        await headless.dispose();
      } catch (_) {}
      return null;
    }
    _sharedHeadless = headless;
    _sharedController = controller;
    return controller;
  }

  /// App kapanırken paylasilan WebView2'yi serbest birak (zorunlu degil; OS de temizler).
  Future<void> disposeShared() async {
    try {
      await _sharedHeadless?.dispose();
    } catch (_) {}
    _sharedHeadless = null;
    _sharedController = null;
  }

  /// Asıl WebView2 + CDP işi. `url` verilirse loadUrl (TERCIH — gercek origin, 2MB yok),
  /// yoksa `html` ile loadData (fallback). _runSerial içinden çağrılır (kilitli → tek anda
  /// tek iş; per-iş durumu instance alanlarinda guvenli). Paylasilan singleton WebView2'yi
  /// yeniden kullanir (soguk-init tekrarlanmaz → onizleme hizlanir).
  Future<Uint8List?> _renderToPdfInternal({String? url, String? html}) async {
    // Per-iş durumunu hazirla (kilit altinda — yarismaz).
    final pdfCompleter = Completer<Uint8List?>();
    _activeCompleter = pdfCompleter;
    _activeResolved = false;
    _activeUrl = url;

    try {
      final controller = await _ensureSharedWebView();
      if (controller == null) {
        _finishActive(null);
      } else if (url != null) {
        // TERCIH EDILEN YOL: gercek HTTP URL'ine navigate (loadUrl = native Navigate).
        // baseUrl/2MB sorunu YOK; gercek origin → CSS/JS/QR cozulur → dolu printToPDF.
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
      } else {
        // FALLBACK: HTML string (loadData = NavigateToString). Windows null-origin/2MB
        // risklerini tasir; baseUrl HARDCODED domain YERINE tenant API origin'inden turetilir.
        await controller.loadData(
          data: html ?? '',
          mimeType: 'text/html',
          encoding: 'utf8',
          baseUrl: WebUri(_baseOriginForWebView()),
        );
      }

      // PDF gelene kadar bekle (timeout güvenliği: ağ/JS takılırsa app kilitlenmesin).
      final pdf = await pdfCompleter.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _log.error(LogType.error, 'WebView2 →PDF zaman asimi (30sn) — render/QR tamamlanamadi');
          return null;
        },
      );
      return pdf;
    } catch (e) {
      _log.error(LogType.error, '→PDF (WebView2) genel hata: $e');
      // Paylasilan webview bozulmus olabilir → bir sonraki is taze kursun.
      await disposeShared();
      return null;
    } finally {
      // Per-iş alanlarini temizle (bir sonraki is taze baslasin).
      _activeCompleter = null;
      _activeResolved = true;
      _activeUrl = null;
    }
  }

  /// 30 Haz 2026 — orderId → PDF (TERCIH EDILEN YOL). receipt-html URL'ini api_service'ten
  /// uretip WebView2'yi GERCEK URL'e navigate eder (loadUrl). URL uretilemezse (key yok vs.)
  /// caller HTML string'i `buildPdfFromHtml`/`buildEscposFromHtml`'e verip fallback edebilir.
  Future<Uint8List?> _orderToPdf(int orderId) async {
    final url = ApiService().receiptHtmlUrl(orderId, noprint: true);
    if (url == null) {
      _log.warning(LogType.general,
          'receipt-html URL uretilemedi (base/key eksik) — HTML string fallback gerekli (order=$orderId)');
      return null;
    }
    return _urlToPdf(url);
  }

  /// ÖNİZLEME (yazıcıya göndermez): sipariş receipt-html → WebView2 (Chromium) PDF bytes.
  /// GERCEK URL'e navigate (loadUrl) → null-origin/2MB sorunu YOK → dolu PDF. URL uretilemezse
  /// [htmlFallback] varsa loadData ile dener. Ekranda PdfPreview ile gösterilir. mac: null.
  Future<Uint8List?> buildPdfFromOrder(int orderId, {String? htmlFallback}) async {
    try {
      final pdf = await _orderToPdf(orderId);
      if (pdf != null) return pdf;
      if (htmlFallback != null && htmlFallback.isNotEmpty) {
        return await _htmlToPdf(htmlFallback);
      }
      return null;
    } catch (e) {
      _log.error(LogType.error, 'Önizleme PDF üretilemedi: $e');
      return null;
    }
  }

  /// (Geriye donuk) HTML string → PDF. URL yolu kullanilamadiginda fallback. mac: null.
  Future<Uint8List?> buildPdfFromHtml(String html) async {
    try {
      return await _htmlToPdf(html);
    } catch (e) {
      _log.error(LogType.error, 'Önizleme PDF üretilemedi (HTML fallback): $e');
      return null;
    }
  }

  /// Sipariş online fişini AĞ TERMALİNE (IP:9100) ESC/POS raster olarak bas (TERCIH EDILEN YOL).
  /// receipt-html URL → (WebView2 loadUrl) PDF → raster → Generator.imageRaster → bytes.
  /// URL uretilemezse [htmlFallback] ile loadData dener. Döner: ESC/POS byte listesi (null = üretilemedi).
  Future<List<int>?> buildEscposFromOrder(int orderId, {String? htmlFallback, int dpi = 203}) async {
    Uint8List? pdf = await _orderToPdf(orderId);
    if (pdf == null && htmlFallback != null && htmlFallback.isNotEmpty) {
      pdf = await _htmlToPdf(htmlFallback);
    }
    return _pdfToEscpos(pdf, dpi: dpi);
  }

  /// (Geriye donuk) HTML string → ESC/POS raster. URL yolu kullanilamadiginda fallback.
  Future<List<int>?> buildEscposFromHtml(String html, {int dpi = 203}) async {
    final pdf = await _htmlToPdf(html);
    return _pdfToEscpos(pdf, dpi: dpi);
  }

  /// PDF bytes → ESC/POS raster (ortak son adim). null PDF → null.
  ///
  /// 30 Haz 2026 — KÖK NEDEN FIX (özet fiş KASA'dan çıkmıyor):
  /// Eski kod her sayfa için `page.toPng()` çağırıyordu. `toPng()` (printing/raster.dart)
  /// içeride `ui.decodeImageFromPixels` + `image.toByteData(png)` kullanır → dart:ui'nin
  /// Skia DOKU (texture) sınırı 8192px'e tabidir. Fiş PDF sayfası çok uzun olduğunda
  /// (paperHeight büyük → 203dpi'de on binlerce px yükseklik) bu sınır AŞILIR → görsel
  /// cap'lenir/bozulur, `toByteData` null/çöp döner → decodePng null → `pages` BOŞ →
  /// `_pdfToEscpos` null → "Özet HTML→ESC/POS raster üretilemedi" → KASA'ya HİÇ basılmaz.
  /// ÇÖZÜM: `toPng()`/dart:ui'yi tamamen ATLA. `Printing.raster` zaten ham RGBA piksel
  /// (PdfRaster.pixels) veriyor → doğrudan `img.Image.fromBytes` (saf CPU, image paketi)
  /// ile decode et. image paketi keyfi boyutu işler (8192 doku sınırı YOK). Bu tek başına
  /// özet fişi kurtarır. (Ek katman: paperHeight makul tutuldu → dev sayfa hiç oluşmaz.)
  Future<List<int>?> _pdfToEscpos(Uint8List? pdf, {int dpi = 203}) async {
    try {
      if (pdf == null) return null;

      // PDF → raster görsel(ler). 80mm @203dpi ≈ 576px genişlik (termal tam en).
      // raster() sayfa sayfa ham RGBA verir; özet fiş tek sayfa beklenir (uzunsa birleştir).
      final List<img.Image> pages = [];
      await for (final page in Printing.raster(pdf, dpi: dpi.toDouble())) {
        // toPng()/decodeImageFromPixels (dart:ui 8192 doku sınırı) YERİNE ham RGBA'dan
        // doğrudan img.Image kur — keyfi yükseklik güvenli, raster null dönmez.
        final im = img.Image.fromBytes(
          width: page.width,
          height: page.height,
          bytes: page.pixels.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        );
        pages.add(im);
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
