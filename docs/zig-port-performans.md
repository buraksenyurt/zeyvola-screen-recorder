# Zig geçişi: C ile Zig arasındaki performans farkı

Windows yardımcısı (`zeyvola-win.exe`) C'den Zig'e taşındıktan sonra iki sürüm aynı Windows makinesinde, aynı girdilerle yan yana ölçüldü. Bu belge sonuçları ve nasıl ölçüldüklerini anlatır. Ham veriler [zig-port-performans.json](zig-port-performans.json) dosyasında, ölçüm betiği [tools/bench/c-vs-zig.mjs](../tools/bench/c-vs-zig.mjs) içinde.

## Özet

- **Hız: ölçülebilir bir fark yok.** Altı senaryonun hepsinde Zig sürümünün medyan süresi C'ninkinin ±%3'ü içinde. Farkların çoğu bu makinenin turdan tura oynamasından büyük değil (%95 güven aralığı sıfırı içeriyor).
- **Süreyi yardımcının kendi kodu belirlemiyor.** Zamanın neredeyse tamamı Windows'ta geçiyor: süreç başlatma (~16 ms), Media Foundation'ın H.264/AAC kodlayıcıları ve AAC çözücüsü. Yardımcının kendi işi stdin'den okuyup Media Foundation arabelleğine aktarmak ve JSON satırı yazmaktan ibaret.
- **İstatistiksel olarak ayırt edilebilen tek fark çok küçük:** Zig sürümü açılış ve kapanışta yaklaşık %2–3 daha az CPU döngüsü harcıyor (~1 milyon döngü, bu işlemcide 1 ms'nin altında). Kullanıcı bunu fark etmez.
- **Bellek: aynı.** Tepe çalışma kümesi Zig'de yaklaşık 0,1 MB düşük (bir-iki bellek sayfası). Özel bellek aynı.
- **Boyut:** yayımlanan Zig derlemesi (`fast`) 28 672 bayt, C'den %7 küçük. `small` ayarıyla 18 432 bayt (%40 küçük) ve ölçülebilir bir hız kaybı yok.

## Ortam

| | |
| --- | --- |
| İşlemci | 12th Gen Intel Core i7-1255U (2 P + 8 E çekirdek, 12 iş parçacığı; dizüstü) |
| Bellek | 32 GB |
| İşletim sistemi | Windows 11 Pro, derleme 10.0.26300 |
| Derleyici | Zig 0.17.0 (iki taraf da; C tarafı `zig cc`) |
| Node.js | 22.14.0 (yalnızca ölçüm betiği) |
| Tarih | 2026-11-18 |

## Karşılaştırılan derlemeler

| Ad | Kaynak | Derleme |
| --- | --- | --- |
| **C** | `785273e` (portdan önceki son commit): `zeyvola-win.c`, `win-api.h` | O commit'teki `build.sh`'in bayraklarıyla: `zig cc -O2 -nostdinc -nostdlib -fno-builtin …` |
| **Zig (fast)** | Bu dal: `native/helper-windows/src/*.zig` | `zig build -Doptimize=fast` (yayımlanan derleme budur) |
| **Zig (small)** | Aynı kaynak | `zig build -Doptimize=small` (karşılaştırma için) |

Üçü de aynı `.def` içe aktarma tanımlarını, aynı sürüm kaynağını kullanıyor ve C çalışma zamanı olmadan bağlanıyor.

## Yöntem

- Her çalışma, bu iş için yazılmış küçük bir ölçüm aracıyla ([tools/bench/measure.zig](../tools/bench/measure.zig)) başlatılıyor. Araç yardımcıyı `CreateProcessW` ile başlatıyor, stdin ve stdout'u ona bağlıyor, bitince süreç nesnesinden şunları okuyor:
  - **Süre:** `QueryPerformanceCounter` ile, süreç başlatmadan bitişine kadar.
  - **CPU döngüsü:** `QueryProcessCycleTime`, sürecin bütün iş parçacıklarının toplamı. Kısa çalışmalarda da hassas olduğu için CPU karşılaştırması bununla yapıldı. `GetProcessTimes` yaklaşık 15,6 ms'lik adımlarla saydığından kısa çalışmalar için kullanılmadı.
  - **Bellek:** `K32GetProcessMemoryInfo`, tepe çalışma kümesi ve tepe özel bellek.
- Derlemeler sırayla değiştirilerek çalıştırıldı (C, Zig, Zig small, C, …). Böylece işlemci saati, ısınma ve arka plan işleri üç derlemeyi aynı ölçüde etkiler. Her derlemenin ilk çalışması ısınma sayıldı, sonuca katılmadı.
- Her çalışmanın yanıtı denetlendi (çıkış kodu, `done`/`ready`/`converted` satırı ve kare sayısı). Yanlış bir yanıt ölçümü durdururdu; hiç olmadı.
- Video girdisi 30 farklı NV12 karesinden (hareket eden bir degrade ve kare) ve 440 Hz stereo sesten oluşuyor. Kodlayıcının sabit bir görüntüyü kolayca sıkıştırmasını önlemek için kareler döngüyle değişiyor. Üç derleme de aynı baytları alıyor.
- "C'ye göre" sütunu medyanların oranı. Köşeli parantez içindeki aralık bu oranın %95 bootstrap güven aralığı (5 000 yeniden örnekleme, sabit tohum). **Aralık 0'ı içeriyorsa fark bu makinenin gürültüsünden ayırt edilemiyor demektir.**

Tekrarlamak için (Windows, Zig 0.17):

```bash
node tools/bench/c-vs-zig.mjs --scale 3 --json docs/zig-port-performans.json
```

`--scale` çalışma sayısını çarpar. Bu belgedeki ölçüm `--scale 3` ile yapıldı ve yaklaşık 4 dakika sürdü.

## İkili boyutu ve bağımlılıklar

| Derleme | Boyut (bayt) | C'ye göre | DLL | İçe aktarılan işlev |
| --- | ---: | ---: | ---: | ---: |
| C | 30 720 | — | 7 | 40 |
| Zig (fast, yayımlanan) | 28 672 | −%6,7 | 7 | 38 |
| Zig (small) | 18 432 | −%40,0 | 7 | 38 |

İki işlevin farkı `lstrcmpA` ve `lstrcmpW`. Zig sürümü dize karşılaştırmasını kendisi yaptığı için bunlara gerek kalmadı. DLL listesi aynı ve `codec-audit` denetiminden aynen geçiyor.

macOS FFmpeg listeleyicisi (`ffmpeg-codecs`) bu makinede çalıştırılamadığı için yalnızca boyutu karşılaştırıldı. C tarafı `zig cc -O1` (eski `clang -O1`'in yerine), Zig tarafı `-O small`:

| Mimari | C (bayt) | Zig (bayt) |
| --- | ---: | ---: |
| arm64 | 50 680 | 50 288 |
| x86_64 | 17 426 | 16 870 |

## Sonuçlar: C ile yayımlanan Zig derlemesi

Süreler milisaniye, medyan. Turlar: açılış 180, `--input` 90, deneme 30, kodlamalar 15'er, ses çıkarma 30.

| Senaryo | C | Zig | Süre farkı [%95 GA] | CPU döngüsü farkı [%95 GA] | Tepe çalışma kümesi C → Zig (MB) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Açılış (`--version`) | 16,3 | 16,1 | −%0,8 [−4,6, +2,2] | **−%2,0 [−2,9, −0,6]** | 8,04 → 7,92 |
| `--input`: kanca kur, `stop`, kaldır | 16,5 | 16,5 | −%0,1 [−3,8, +3,6] | **−%3,0 [−4,4, −0,9]** | 8,12 → 8,00 |
| `--encode-probe` | 88,8 | 88,0 | −%0,9 [−3,6, +2,1] | −%0,5 [−1,5, +0,7] | 61,1 → 61,0 |
| `--encode-mp4` 1280×720, 300 kare + AAC | 744,7 | 732,5 | **−%1,6 [−4,3, −0,1]** | −%1,8 [−2,9, +0,3] | 211,3 → 209,5 |
| `--encode-mp4` 1920×1080, 300 kare + AAC | 1 394,4 | 1 393,3 | −%0,1 [−1,2, +1,5] | −%0,7 [−2,4, +1,5] | 396,1 → 396,1 |
| `--extract-audio` 120 s AAC → WAV | 461,6 | 450,9 | −%2,3 [−5,8, +3,8] | −%1,5 [−5,5, +2,9] | 17,2 → 17,1 |

Kalın değerlerin aralığı sıfırı içermiyor. Bunlar da büyüklük olarak küçük: açılışta ~0,6–1 milyon döngü, 720p kodlamada 12 ms (10 saniyelik videoda).

## Sonuçlar: Zig `small` derlemesi

| Senaryo | Zig (small) | Süre, C'ye göre [%95 GA] | CPU döngüsü, C'ye göre [%95 GA] |
| --- | ---: | ---: | ---: |
| Açılış (`--version`) | 15,8 | −%2,7 [−5,0, −0,2] | −%1,6 [−2,5, −0,4] |
| `--input` | 16,0 | −%3,0 [−5,4, +0,4] | −%2,6 [−4,0, +0,1] |
| `--encode-probe` | 88,0 | −%0,9 [−3,1, +3,2] | +%0,2 [−1,1, +2,1] |
| `--encode-mp4` 720p | 734,6 | −%1,4 [−3,9, +0,2] | −%0,7 [−1,7, +0,8] |
| `--encode-mp4` 1080p | 1 392,8 | −%0,1 [−1,6, +1,8] | −%0,4 [−1,4, +2,4] |
| `--extract-audio` | 458,6 | −%0,7 [−5,2, +4,0] | −%0,6 [−4,8, +3,0] |

`small` derlemesi C'den yavaş değil; `fast` ile de arasında ölçülebilir bir fark yok.

## Yorum

**Zaman nerede geçiyor?** Açılış ve `--input` senaryolarında 16 ms'nin neredeyse tamamı Windows'un süreci yaratması, DLL'leri yüklemesi ve kapatması. Yardımcının kendi kodu birkaç mikrosaniyelik iş yapıyor. Kodlama senaryolarında süreç ~1,4 s'de ~5,6 s CPU harcıyor. Bu, Media Foundation kodlayıcısının birden çok çekirdekte çalıştığını gösteriyor. Yardımcının payı kareyi stdin'den doğrudan Media Foundation'ın arabelleğine okumak. Arada kopya yok, iki sürümde de aynı. `--extract-audio`'da süre AAC çözücüsüne ve diske yazmaya gidiyor. Bu yüzden dilin değişmesi, bu programda ancak çok küçük bir fark yaratabilirdi. Ölçüm de bunu gösteriyor.

**Açılıştaki küçük CPU farkı nereden geliyor?** Kesin bir nedeni ölçülmedi. Olası açıklamalar: ikili bir-iki sayfa daha küçük (yüklenecek ve sayfa hatası verecek sayfa daha az) ve iki içe aktarma daha az bağlanıyor. Tepe çalışma kümesindeki ~0,1 MB'lık düşüş de bir-iki sayfaya denk geliyor. Fark 1 ms'nin altında olduğu için pratikte önemsiz.

**`fast` mı, `small` mı?** Bu yardımcıda `small`, hiçbir senaryoda ölçülebilir bir bedel olmadan ikiliyi %36 küçültüyor (28 672 → 18 432 bayt). Kurulum boyutu açısından anlamlı bir kazanç değil, çünkü paketin geri kalanı yüzlerce MB. Yine de `build.zig`'deki varsayılanı `small` yapmak hiçbir şey kaybettirmez. Bu belge yalnızca ölçüyor; varsayılan `fast` olarak bırakıldı.

## Sınırlar

- **Tek makine, dizüstü.** i7-1255U'nun P/E çekirdekleri ve güç yönetimi turdan tura sapma yaratıyor; bazı turlar medyanın iki katına çıktı (ör. 1080p'de 1,8 s). Medyan ve bootstrap aralığı bu uç değerlere dayanıklı, ama masaüstü bir işlemcide aralıklar daha dar olurdu.
- **`--input`'un olay yolu ölçülmedi.** Fare tıklaması ve tekerlek olaylarının JSON'a dönüşme süresi, kullanıcının faresine sahte olay göndermeden ölçülemediği için senaryoya alınmadı. Ölçülen kısım, kancanın kurulup kaldırılmasıyla ilk `ready` satırı. Olay başına iş, birkaç sayı biçimlendirip tek bir `WriteFile` yapmak; iki sürümde de aynı.
- **Donanım kodlayıcısı yok.** Yardımcı yalnızca ekran kartında H.264 kodlayıcısı olmadığında kullanılıyor ve Media Foundation'ın yazılım kodlayıcısını çalıştırıyor. Ölçüm de bu yolu ölçüyor.
- **macOS listeleyicisi çalıştırılmadı**, yalnızca boyutu karşılaştırıldı. İşi birkaç yüz codec adını yazdırmak; süresi `dlopen`'a gidiyor.
- **Süreç CPU süresi** (`cpuMs`, JSON'da) 15,6 ms'lik adımlarla sayıldığından kısa senaryolarda karşılaştırma için kullanılmamalı. Örneğin denemedeki 94 ms ile 78 ms arasındaki fark tam bir adım. Döngü sayısı (`megacycles`) bu sorunu taşımıyor.
