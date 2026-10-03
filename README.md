# Galaxy

**Galaxy Extension**, Visual Studio Code için açık kaynak bir yapay zekâ kod tamamlama motorudur. **D** diliyle yazılmış yerel (native) bir süreç ağır işi — bağlam birleştirme, sıralama, prompt kurma ve ağ G/Ç'si — üstlenirken, ince bir **TypeScript** katmanı bunu editörle köprüler. Sonuç: mikrosaniyeler içinde gelen yerel ilk yanıt ve geldiğinde öneriyi iyileştiren model destekli gri hayalet metin (ghost text).

## Öne çıkanlar

| Özellik | Açıklama |
| --- | --- |
| Önce yerel, sonra model | Statik analiz anında yanıt verir; model sonucu hayalet metni yerinde iyileştirir. |
| Hibrit tamamlamalar | Tek bir sıralı aday listesi hem öneri listesini hem gri satır içi öneriyi besler. |
| Yerel motor | `GalaxyEngine`, uzun ömürlü bir alt süreç olarak başlatılan tek bir yerel D çalıştırılabilir dosyasıdır. |
| Satır ayrımlı IPC | `stdin`/`stdout` üzerinden satır sonu ayrımlı JSON, protokolü basit, taşınabilir ve hata ayıklanabilir tutar. |
| Takılabilir sağlayıcılar | Yapılandırmayla seçilen herhangi bir OpenAI uyumlu uç nokta veya yerel Ollama çalışma zamanı. |
| Ortanın doldurulması (FIM) | Prefix, suffix ve sonraki satırların tamamı iletilir; böylece FIM'e ayarlanmış modeller doğru bağlamı alır. |
| Koruma katmanlı birleştirme | Sürüklenme işaretleri, tekrar eden satırlar, boş satır aralıkları ve prefix uyuşmazlığı düşük kaliteli çıktıyı eler. |
| Çevrimdışı çalışabilir | Yerel boru hattının tamamı hiçbir ağ erişimi olmadan çalışır. |
| Dil farkındalığı | D, TypeScript, JavaScript, Python, Rust, Go, C, C++, Java, JSON, HTML ve CSS için profiller. |

## Mimari

```
┌──────────────────────────────────────────────────────────────┐
│  Visual Studio Code                                          │
│  ┌────────────────────┐        ┌──────────────────────────┐  │
│  │ extension.ts       │        │ completionProvider.ts    │  │
│  │ etkinleştirme/yaşam│──────▶│ istemci + sağlayıcılar   │  │
│  └────────────────────┘        └───────────┬──────────────┘  │
└─────────────────────────────────────────────┼────────────────┘
             response · delta · final │ abort
┌─────────────────────────────────────────────▼────────────────┐
│  GalaxyEngine (yerel D çalıştırılabilir dosyası)            │
│  ┌──────────┐   ┌────────────┐   ┌───────────┐ ┌──────────┐  │
│  │ app.d    │──▶│ completer.d│◀─▶│ fetcher.d │ │ prompt   │  │
│  │ stdio IPC│   │ sıralama   │   │ sağlayıcı │ │ + birleş. │  │
│  │ olay döng│   │ + birleşt. │   │ + akış    │ │          │  │
│  └──────────┘   └────────────┘   └─────┬─────┘ └──────────┘  │
└────────────────────────────────────────┼───────────────────────┘
                 OpenAI uyumlu /v1/completions
                 Ollama /api/generate (NDJSON)
```

### Sorumluluklar

* **`extension/src/extension.ts`** motorun binary'sini çözer, onu arka plan süreci olarak başlatır, her iki sağlayıcı yüzeyini kaydeder, durum çubuğu kaydını yönetir; komutları, yapılandırma değişikliklerini, kapanışı ve modeli çalışma anında yeniden yapılandıran `config` gönderimini yönetir.
* **`extension/src/completionProvider.ts`** istek başına akış destekli, satır sonu ayrımlı JSON istemcisini; debounce katmanını; öneri listesi için `CompletionItemProvider`'ı ve hayalet metin için `InlineCompletionItemProvider`'ı uygular.
* **`engine/source/app.d`** sürecin giriş noktasıdır. `stdin` üzerinden istek zarflarını okur, yönlendirir, her isteği iki fazlı yanıtlar ve `response`, `delta` ve `final` zarflarını `stdout` üzerine geri yazar.
* **`engine/source/completer.d`** imleç konumunu ve çevreleyen satırları puanlanmış adaylara dönüştürür, ortanın doldurulması (FIM) prompt'unu kurar ve doğrulanmış model çıktısını sıralı listeye birleştirir.
* **`engine/source/fetcher.d`** yapılandırılmış sağlayıcıya HTTP çağrısını timeout, yeniden deneme, kimlik bilgisi yönetimi, önek önbelleği ve akış ayrıştırmasıyla birlikte gerçekleştirir.

## İstek yaşam döngüsü

```
istemci                                  motor                        sağlayıcı
  |  completion (ai.enabled)                  |                            |
  |------------------------------------------>|                            |
  |  response  (yerel, anında)                |                            |
  |<------------------------------------------|                            |
  |  delta   ...                             |                            |
  |<------------------------------------------|                            |
  |  final    (doğrulanmış, birleştirilmiş)   |                            |
  |<------------------------------------------|                            |
```

1. Motor her tuş vuruşunu yerel boru hattıyla yanıtlar; böylece öneri listesi ve ilk hayalet metin ağ için hiç beklemez.
2. Model çağrısı motor döngüsünde çalışır ve çıktısını `delta` zarfları halinde geri akıtır.
3. Doğrulayıcı metni temizler, prefix sürekliliğini denetler ve sonucu en yüksek puanlı aday olarak birleştirip `final` zarfıyla teslim eder.
4. `abort` kuyrukta bekleyen üretimi iptal eder. Eklenti iki üretimin asla örtüşmesine izin vermez; böylece bayat bir yanıt çizilmek yerine atılır.

Motor tasarım gereği aynı anda tek üretimi işler. Bu, yerel süreci tek iş parçacıklı, deterministik ve kilitsiz tutar; eklenti de istekleri birleştirerek aynı anda en fazla bir model çağrısının uçuşta olmasını sağlar.

## Proje yapısı

```
.
├── package.json
├── tsconfig.json
├── .vscodeignore
├── .gitignore
├── README.md
├── LICENSE
├── .vscode
│   ├── launch.json
│   └── tasks.json
├── engine
│   ├── dub.json
│   └── source
│       ├── app.d
│       ├── completer.d
│       └── fetcher.d
└── extension
    └── src
        ├── extension.ts
        └── completionProvider.ts
```

## Ön koşullar

* Visual Studio Code `1.84.0` veya üzeri
* Node.js `18` veya üzeri
* Bir D araç zinciri — `PATH` üzerinde `dmd` ya da `ldc2`
* [DUB](https://dub.pm/) paket yöneticisi
* Eklenti istemcisi için `npm`

## Derleme

```bash
npm install
npm run engine:build
npm run build
```

`engine/dub.json` sabit bir `targetPath` ile çalıştırılabilir hedef tanımladığı için motor derlemesi `engine/bin/galaxy-engine` (Windows'ta `galaxy-engine.exe`) konumunda tek bir çalıştırılabilir dosya üretir.

| Betik | Amacı |
| --- | --- |
| `npm run engine:build` | `dmd` ile sürüm (release) derlemesi. |
| `npm run engine:build:lcd` | `ldc2` ile sürüm derlemesi. |
| `npm run engine:build:debug` | Çalışma zamanı sınır denetimleriyle hata ayıklama derlemesi. |
| `npm run engine:run` | Motoru doğrudan başlatır ve `stdin` üzerinden konuşturur. |
| `npm run build` | Eklentiyi `out/` klasörüne derler. |
| `npm run watch` | Artımlı TypeScript derlemesi. |
| `npm run typecheck` | Dosya üretmeden tip denetimi. |
| `npm run compile` | Motor ve eklentiyi tek komutta derler. |
| `npm run package` | `vsce` ile bir `.vsix` üretir. |
| `npm run package:full` | Önce motoru derler, sonra onu da içeren `.vsix` üretir. |

## Çalıştırma

VS Code içinde `F5` ile Extension Development Host başlatın ya da paketlenmiş bir sürüm kurun.

1. Desteklenen bir dilde bir kaynak dosyası açın.
2. Bir tanımlayıcı prefix'i yazın; sıralı listeyi ve gri satır içi öneriyi izleyin.
3. Satır içi öneriyi kabul etmek için `Tab`, listedeki vurgulu maddeyi kabul etmek için `Enter` tuşuna basın.
4. Yeniden derlemeden sonra motor süreci değişirse `Galaxy: Restart Engine` komutunu kullanın.

Durum çubuğu kaydı motorun yaşam döngüsünü gösterir. Üzerine gelerek binary yolunu ve son taşıma hatasını görün.

## Protokol

`stdin` ve `stdout` üzerindeki her satır tek bir JSON nesnesidir.

### Başlatma

```json
{ "id": "1", "type": "initialize", "payload": { "client": "vscode", "clientVersion": "0.1.0" } }
```

```json
{ "id": "1", "type": "response", "status": "ok", "protocol": "1.0.0", "payload": { "languages": ["d", "typescript"], "engineVersion": "0.1.0", "provider": "ollama", "aiEnabled": true } }
```

### Tamamlama

```json
{ "id": "2", "type": "completion", "payload": { "filePath": "/w/app.d", "languageId": "d", "line": 12, "character": 8, "prefix": "wri", "suffix": "", "currentLine": "        wr", "previousLines": ["import std.stdio;"], "nextLines": ["}"], "ai": { "enabled": true, "provider": "auto", "model": "qwen2.5-coder:1.5b", "stream": true, "promptStyle": "fim" } } }
```

```json
{ "id": "2", "type": "response", "status": "ok", "protocol": "1.0.0", "payload": { "source": "local", "trigger": "identifier", "isIncomplete": false, "inlineText": "writeln", "aiQueued": true, "generation": 1, "items": [ { "label": "writeln", "text": "writeln", "kind": "function", "detail": "void writeln(T)(T value)", "score": 920, "inline": true } ] } }
```

### Model yanıtı

```json
{ "id": "2", "type": "delta", "status": "ok", "protocol": "1.0.0", "payload": { "source": "ai", "text": "iteln(\"galaxy\");\n", "done": false } }
```

```json
{ "id": "2", "type": "final", "status": "ok", "protocol": "1.0.0", "payload": { "source": "ai", "provider": "ollama", "model": "qwen2.5-coder:1.5b", "inlineText": "iteln(\"galaxy\");", "available": true, "rejected": false, "rejectReason": "", "acceptedLines": 1, "overlap": 2, "finishReason": "stop", "elapsedMs": 118, "done": true, "items": [] } }
```

### Desteklenen istek tipleri

| Tip | Yön | Amaç |
| --- | --- | --- |
| `initialize` | istemciden motora | El sıkışma, yetenek ve sürüm değişimi. |
| `completion` | istemciden motora | Bağlama duyarlı aday üretimi, isteğe bağlı olarak bir model çağrısıyla. |
| `config` | istemciden motora | Uç nokta, kimlik bilgileri, timeout'lar ve modeli çalışma anında yeniden yapılandırır. |
| `abort` | istemciden motora | Hedef kimliğe göre kuyruktaki bir üretimi iptal eder. |
| `health` | istemciden motora | Yaşayabilirlik denetimi ve istatistikler. |
| `shutdown` | istemciden motora | Zarif sonlandırma. |

### Yanıt tipleri

| Tip | Anlamı |
| --- | --- |
| `response` | İstek kimliğine ait birincil yanıt. Bekleyen promise'i çözer. |
| `delta` | Bir istek kimliği için artımlı model metni. Hayalet metni yerinde günceller. |
| `final` | Doğrulanmış metni ve birleştirilmiş aday listesini taşıyan nihai model yanıtı. |

Bozuk zarflar döngüyü asla sonlandırmaz. Motor `status` alanını `error` yaparak yanıt verir ve okumaya devam eder; böylece tek bir hatalı tuş vuruşu oturumu öldüremez.

## Paketleme

```bash
npm run package:full
code --install-extension galaxy-extension-0.1.0.vsix
```

VSIX; manifesti, derlenmiş eklentiyi (`out/` altında), lisansı ve açıklama dosyasını içerir. Kaynaklar, `tsconfig.json` ve motor kaynakları `.vscodeignore` ile dışlanır; derlenmiş binary ise `engine/bin/galaxy-engine.exe` (ya da `engine/bin/galaxy-engine`) konumunda **var olduğu anda** otomatik olarak pakete eklenir. Bu yüzden yayın komutu `package:full`'dür.

Binary yoksa eklenti yine kurulur ve başlar: durum çubuğu `missing` bildirir, çıktı kanalı nedenini açıklar ve `galaxy.engine.path` bir binary'yi gösterene ya da motor derlenene kadar öneri listesi yalnızca yerel sıralamaya düşer.

## Model kurulumu

Galaxy iki sağlayıcı bağdaştırıcısıyla gelir ve aralarından birini otomatik seçer.

### Yerel, kimlik bilgisi gerektirmez

```bash
ollama serve
ollama pull qwen2.5-coder:1.5b
```

```json
{
  "galaxy.ai.enabled": true,
  "galaxy.ai.provider": "ollama",
  "galaxy.ai.model": "qwen2.5-coder:1.5b"
}
```

### Bulut, kendi anahtarınızla

```bash
export GALAXY_API_KEY=sk-...
```

```json
{
  "galaxy.ai.enabled": true,
  "galaxy.ai.provider": "openai",
  "galaxy.ai.model": "qwen2.5-coder-7b-instruct",
  "galaxy.ai.chatMode": true
}
```

`galaxy.ai.provider` değeri `auto` iken `GALAXY_API_KEY` mevcutsa bulut rotası, yoksa yerel rota kullanılır.

### Prompt stilleri

* `fim` kodu `<|fim_prefix|>`, `<|fim_suffix|>` ve `<|fim_middle|>` belirteçleriyle sarar ve `suffix` alanıyla `/v1/completions` adresine gönderir. FIM'e ayarlanmış modeller için bunu kullanın.
* `instruct` fence içinde bir talimat bloğu kurar. Yalnızca sohbet uç noktaları (örneğin `/chat/completions`) için `galaxy.ai.chatMode` ile birlikte kullanın.

### Çıktı doğrulaması

Üretilen metin; düz metne kayarsa, bir kod fence'i açarsa, bir satırı tekrarlarsa, arka arkaya birden fazla boş satır açarsa, suffix ile çelişen ikinci bir ifade eklerse ya da yazılan prefix'i sürdürmezse elenir. Bu denetimlerden geçen her şey en yüksek puanlı aday olur.

## Yapılandırma

Tüm ayarlar `galaxy` ad alanı altında bulunur.

| Ayar | Varsayılan | Anlamı |
| --- | --- | --- |
| `galaxy.engine.path` | `""` | Binary'nin açık konumu. Boş bırakılırsa otomatik arama yapılır. |
| `galaxy.engine.enabled` | `true` | Arka plan süreci için ana anahtar. |
| `galaxy.engine.autoRestart` | `true` | Beklenmedik kapanıştan sonra yeniden başlatır. |
| `galaxy.engine.requestTimeoutMs` | `2500` | İstek başına iptal penceresi. |
| `galaxy.engine.requestDebounceMs` | `60` | Tuş vuruşu debounce süresi. |
| `galaxy.engine.modelTimeoutMs` | `4000` | Yerel motor bir şey üretmediğinde satır içi sağlayıcının model yanıtını bekleme süresi. |
| `galaxy.completion.list.enabled` | `true` | Öneri listesi yüzeyi. |
| `galaxy.completion.inline.enabled` | `true` | Gri hayalet metin yüzeyi. |
| `galaxy.completion.inline.mode` | `hybrid` | `hybrid`, `inline` ya da `list`. |
| `galaxy.completion.inline.minPrefixLength` | `1` | Hayalet metin görünmeden önce gereken yazılan karakter sayısı. |
| `galaxy.completion.inline.maxItems` | `5` | İstek başına dönen aday sayısı. |
| `galaxy.completion.suppressInComments` | `true` | Yorum ve dizge içindeki konumlarda istek yapmaz. |
| `galaxy.completion.languages` | manifest'e bakın | Sağlayıcıların kaydedileceği dil tanımlayıcıları. |
| `galaxy.service.endpoint` | `https://api.galaxy.dev/v1` | Uzak servis temel adresi. |
| `galaxy.service.apiKeyEnv` | `GALAXY_API_KEY` | Kimlik bilgisini taşıyan ortam değişkeni. |
| `galaxy.service.timeoutMs` | `4000` | Motor tarafındaki HTTP timeout süresi. |
| `galaxy.service.maxRetries` | `2` | HTTP çağrısı başına yeniden deneme bütçesi. |
| `galaxy.ai.enabled` | `false` | Model destekli hayalet metin için ana anahtar. |
| `galaxy.ai.provider` | `auto` | `auto`, `openai`, `ollama` ya da `none`. |
| `galaxy.ai.model` | `""` | Model tanımlayıcısı. Boş bırakılırsa AI kapalı kalır. |
| `galaxy.ai.ollamaEndpoint` | `http://127.0.0.1:11434` | Yerel çalışma zamanının adresi. |
| `galaxy.ai.maxTokens` | `96` | Üretilecek token sayısının üst sınırı. |
| `galaxy.ai.temperature` | `0.2` | Örnekleme sıcaklığı. |
| `galaxy.ai.stream` | `true` | Artımlı delta ister. |
| `galaxy.ai.chatMode` | `false` | `/v1/completions` yerine `/chat/completions` kullanır. |
| `galaxy.ai.promptStyle` | `fim` | `fim` ya da `instruct`. |
| `galaxy.ai.prefixLines` | `60` | İmleçten önceki bağlam satırı sayısı. |
| `galaxy.ai.suffixLines` | `24` | İmleçten sonraki bağlam satırı sayısı. |
| `galaxy.logging.level` | `info` | Çıktı kanalının ayrıntı düzeyi. |

Model ayarları, siz değiştirdiğiniz anda bir `config` isteğiyle motora gönderilir; yeniden yükleme gerekmez.

## Bilinen sınırlamalar

* Motor tasarım gereği tek iş parçacıklıdır. Bir model çağrısı süresince döngüyü meşgul eder; bu yüzden eklenti aynı anda en fazla bir üretimi uçuşta tutar, kalanları birleştirir. `abort` kuyruktaki işi iptal eder, uçuştaki HTTP isteğini değil.
* Akış ayrıştırması hem OpenAI tarzı sunucu tarafı olaylarını (server-sent events) hem Ollama'nın satır sonu ayrımlı JSON'unu işler; akışsız yanıtlara da tolerans gösterir. Parça düzeyinde teslim, sağlayıcının her tokenı ayrı ayrı göndermesine bağlıdır.
* Öneri listesi bilinçli olarak yalnızca yereldir. Model çıktısı hayalet metin yüzeyine yönlendirilir; bu, yazarken listenin anında çizilmesini korur.

## Geliştirme akışı

* Önce motoru derleyin. Eklenti, kurulum klasörüne göre `bin/`, `engine/bin/` ve `out/engine/bin/` konumlarını yoklar ve reddedilen her adayı `Galaxy Engine` çıktı kanalına yazar.
* `completer.d` üzerinde çalışırken `npm run engine:build:debug` komutunu kullanın; böylece ön kontroller ve sınır denetimleri devreye girer, sonra sürüm derlemesine dönün.
* `npm run engine:run` ile elle bir tamamlama zarfı göndererek motor davranışını editör davranışından yalıtın.
* Motor her zarf için tek bir JSON satırı basar; bu nedenle `engine/bin/galaxy-engine < requests.jsonl` ile kaydedilmiş bir oturumu yeniden oynatabilirsiniz.
* Bir sağlayıcı sessizce yanıt vermeyi bıraktığında `Galaxy: Show Engine Logs` ile çıktı kanalını okuyun. `health` isteği sağlayıcı, model, sunulan istek ve model sayaclarını bildirir.

## Katkıda bulunma

1. Depoyu çatallayın ve bir konu dalı oluşturun.
2. Protokolü geriye uyumlu tutun; alan ekleyin, mevcut alanların anlamını değiştirmeyin.
3. Pull request açmadan önce `npm run typecheck` ve `npm run engine:build` komutlarını çalıştırın.
4. Pull request gövdesinde gözlemlenebilir davranışı anlatın.

## Lisans

MIT. Tam metin için depoya bakın.