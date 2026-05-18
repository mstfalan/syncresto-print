# SyncResto Print

Online sipariş termal yazıcı uygulaması — Flutter (Windows / macOS / Linux).

`panel.syncresto.com` üzerinden gelen web ve marketplace siparişleri (Getir, Trendyol, Yemeksepeti, Migros) otomatik olarak ESC/POS termal yazıcılara basar.

## Özellikler

- **Online sipariş otomatik yazdırma** — WebSocket ile gerçek zamanlı
- **Çoklu yazıcı routing** — her ürün kendi yazıcısına (POS pattern)
- **Print queue** — SQLite tabanlı 5sn arka plan retry (offline-first)
- **Yazıcı fail pop-up** — fail olunca uyarı + manuel tekrar yazdır
- **Yazıcı atanmamış ürün uyarısı** — kullanıcı panel.syncresto.com → POS → Ürünler sayfasından eşleştirir
- **İptal fişi** — sipariş iptali için ayrı fiş
- **Sesli bildirim** — açılıp kapatılabilir
- **Otomatik güncelleme** — GitHub release version check
- **Multi-tenant** — `X-Print-Key` (SR_PRT_xxx) authentication

## Kurulum

1. Releases sayfasından `SyncResto-Print-Windows.zip` indir + çıkart
2. `syncresto_print.exe` çalıştır
3. Setup ekranında:
   - API URL: `https://panel.syncresto.com`
   - Print Key: admin panelden aldığın `SR_PRT_xxx`
4. Yazıcı Ayarları'ndan termal yazıcı(lar)ı kontrol et + test fişi at
5. Sipariş geldiğinde otomatik fişe basar

## Geliştirme

```bash
flutter pub get
flutter run -d macos        # macOS
flutter run -d windows      # Windows
flutter build macos --release
flutter build windows --release
```

## Mimari

- **Frontend**: Flutter desktop (Material 3)
- **Backend API**: `panel.syncresto.com/api/print/*` (X-Print-Key auth)
- **WebSocket**: panel-{id} room — `order-received` event
- **Yazıcı**: ESC/POS, TCP/IP port 9100, 80mm
- **Local DB**: SQLite (sqflite_common_ffi) — print queue
- **Ses**: audioplayers (asset: `new_order.mp3`)
- **Update**: package_info_plus + url_launcher

## Backend Endpoint'leri

| Method | Path | Açıklama |
|---|---|---|
| POST | `/api/print/validate` | Print key doğrula |
| POST | `/api/print/socket-token` | WebSocket JWT al |
| GET | `/api/print/printers` | Tanımlı yazıcılar |
| GET | `/api/print/orders/recent` | Son siparişler |
| GET | `/api/print/orders/:id` | Sipariş detayı |
| GET | `/api/print/orders/:id/print-groups` | Ürün → yazıcı grupları |
| POST | `/api/print/orders/:id/mark-printed` | Basıldı işaretle |
| POST | `/api/print/orders/:id/report-print-failed` | Başarısız bildir |
| GET | `/api/print/version` | Sürüm bilgisi (auto-update) |

## Lisans

Özel — SyncResto.
