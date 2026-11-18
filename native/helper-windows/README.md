# Zeyvola Windows yardımcısı

Zeyvola'nın Windows'ta kullandığı küçük bir program. Üç işi var:

- **`--input`:** Ekran kaydı sürerken fare tuşlarını ve tekerleği bildirir (otomatik zoom için). Windows'un düşük düzeyli fare kancasını (`WH_MOUSE_LL`) kullanır; olayları yutmaz, diğer uygulamalara aynen geçer. Klavyeyi okumaz, diske yazmaz, ağa bağlanmaz.
  - **`--input --window <HWND>`:** Pencere kaydında ayrıca kaydedilen pencerenin görünen çerçevesini (`DwmGetWindowAttribute`, `DWMWA_EXTENDED_FRAME_BOUNDS`; olmazsa `GetWindowRect`) saniyede yaklaşık 30 kez okur, değiştikçe bildirir. Uygulama imleci ve tıklamaları pencereye göre yazar. Pencereden başka bilgi okunmaz.
- **`--extract-audio <video> <ses.wav>`:** Eklenen bir videonun sesini (ör. AAC) Windows'un kendi Media Foundation çözücüsüyle çözer ve 16 bit PCM WAV yazar. Çözülemeyen ses için hata döner; uygulama kullanıcıyı uyarır.
- **`--encode-mp4 <çıktı.mp4> <genişlik> <yükseklik> <fps> <bit hızı> <ses 0|1>`:** Ekran kartında H.264 kodlayıcısı yoksa MP4 dışa aktarmayı Windows'un kendi Media Foundation kodlayıcılarıyla (yazılım H.264 ve AAC; Sink Writer) yazar. Uygulama stdin'den NV12 kareleri ve 16 bit stereo PCM gönderir. `--encode-probe <dosya.mp4>` aynı kurulumu küçük bir denemeyle sınar. Electron'un OpenH264 kodlayıcısı kullanılmaz.

Çıktı biçimi: `src/main.zig` başındaki açıklama.

## Kaynaklar

Yardımcı Zig ile yazılmıştır (Zig 0.17):

| Dosya | İçerik |
| --- | --- |
| `src/main.zig` | Dört kip ve giriş noktası (`wWinMainCRTStartup`) |
| `src/win.zig` | Kullanılan Windows ve Media Foundation bildirimleri; COM yöntem tablolarının yuva sıraları derleme anında denetlenir |
| `src/line.zig` | JSON satırı (sabit arabellek, bellek ayırmadan) |
| `src/parse.zig` | Komut satırı sayıları, stdin'deki "stop" satırı, dışa aktarma paket başlığı |
| `src/wav.zig` | 16 bit PCM WAV başlığı |
| `src/rt.zig` | Derleyicinin çağırabileceği `memset` / `memcpy` / `memmove` |
| `build.zig` | Derleme adımları |
| `imports/*.def` | Çağrılan sistem DLL işlevlerinin listesi |
| `zeyvola-win.rc` | Dosya özelliklerindeki sürüm bilgisi |

## Derleme

```bash
pnpm native:win   # → native/helper-windows/bin/zeyvola-win.exe (x64, imzasız)
```

`build.sh` yalnızca `zig build --prefix .` çalıştırır; `apps/desktop/scripts/package.mjs` aynı komutu kabuk olmadan çağırır. Windows, macOS ve Linux'ta aynı şekilde derlenir. Birim testleri (Windows çağrısı gerektirmeyen kısımlar, derleyen makinede çalışır):

```bash
cd native/helper-windows && zig build test --summary all
```

Programa üçüncü taraf hiçbir şey girmez:

- C çalışma zamanı ve compiler-rt bağlanmaz; giriş noktası bizim, standart kitaplığın başlangıç kodu girmez. Zig standart kitaplığından koda işlev girmez (panik işleyicisi tek bir trap komutudur).
- Zig'in hazır Windows bağlamaları kullanılmaz; gereken bildirimler `src/win.zig` içinde, Microsoft'un belgelerine ve Microsoft'un windows-rs bağlamalarına göre bu proje için yazıldı.
- İçe aktarma kitaplıkları derleme sırasında `imports/*.def` dosyalarından (`zig dlltool`) üretilir; bu dosyalar yalnızca çağrılan sistem DLL işlevlerini listeler (KERNEL32, USER32, SHELL32, ole32, dwmapi, MFPlat, MFReadWrite). Sink Writer bildirimleri ve GUID'leri, `tests/media-check/mf-check.ps1` dosyasının gerçek bir Windows makinesinde kullandığı değerlerle aynıdır.

`tools/codec-audit.mjs`, paketteki `resources/bin/zeyvola-win.exe` dosyasının yalnızca bu DLL'lere bağlı olduğunu ve kodlayıcı olarak yalnızca `MFCreateSinkWriterFromURL` dışında kodlayıcı, klavye veya ağ işlevi içe aktarmadığını denetler.

**Durum:** Gerçek Windows'ta henüz test edilmedi.
