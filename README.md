# アルセチカさんの配信置き場

アルセチカさんの配信アーカイブを有志がまとめている非公式サイトです。

## リポジトリの構成

```
.
├── public/            ← Cloudflare Pages が配信するのはここだけ
│   ├── index.html     サイト本体（これ1枚で完結）
│   └── _headers       レスポンスヘッダー設定
├── functions/         ← Cloudflare Pages Functions
│   └── live-now.js    /live-now 「いま配信中か」を答える
├── urls.txt           配信URLの一覧（ここにURLを足していく）
├── update-archives.ps1  urls.txt から「過去の配信」を書き換えるスクリプト
├── update-live.ps1      「いまの配信」を配信状況に合わせるスクリプト
└── .gitignore
```

`functions/` は `public` の外ですが、これは公開されないためではなく、
Cloudflare Pages が `functions/` を**リポジトリのルートから**探す仕様の
ためです。ビルド出力ディレクトリ（`public`）とは別系統で扱われます。中身は
静的ファイルとしては配信されず、`/live-now` というURLとして動きます。

> **`public/functions/` に移動しないでください。** 公式ドキュメントに
> 「Make sure that the `/functions` directory is at the root of your Pages
> project (and not in the static root, such as `/dist`)」とあり、出力
> ディレクトリの中に置くと関数として認識されず、ただのJavaScriptファイルが
> 公開されるだけになります。

`update-archives.ps1` と `urls.txt` をルートに置いているのは、`public` の外なら
公開されないためです。`.ps1` が誰でもダウンロードできる状態になるのを避けています。

## Cloudflare Pages の設定

GitHubリポジトリを接続したうえで、ビルド設定を次のようにします。

| 項目 | 値 |
| --- | --- |
| フレームワークプリセット | なし |
| ビルドコマンド | （空欄） |
| ビルド出力ディレクトリ | `public` |

ビルド処理は不要です。`main` ブランチにpushすると自動でデプロイされます。

`functions/` のために設定を足す必要はありません。Cloudflare Pages が自動で
拾って `/live-now` として公開します。デプロイ後に
`https://＜サイトのURL＞/live-now` を開くと、`{"live":false}` のような
JSONが返るはずです。404 になる場合は関数が拾われていないので、
Cloudflare Pages の管理画面で「Functions」にファイルが表示されているか
確認してください（拾われていなくてもサイト自体はこれまで通り動き、
「いまの配信」が `SITE.live` の値のままになるだけです）。

## 配信を追加する手順

1. `urls.txt` の一番上に配信URLを1行足す
2. `.\update-archives.ps1` を実行する（yt-dlp が必要）
3. 変更をコミットしてpushする

タイトルと配信日は yt-dlp が取得して `public/index.html` に書き込みます。
手で入力するのはURLだけです。

yt-dlp が使えない環境では、`public/index.html` の `ARCHIVES:BEGIN` 〜
`ARCHIVES:END` の間を直接編集しても構いません。`title` を省略すると
動画IDが表示されます。

## 配信中の表示

「いまの配信」は**自動で切り替わります**。配信のたびに何かする必要はありません。

ページを開くと `/live-now` に問い合わせて、いま本当に配信中かどうかを確かめ、
その結果で表示を決めます。ページを開いたままにしている人の画面も、3分おきに
確かめて自動で切り替わります。

`public/index.html` の `SITE.live` は、その問い合わせができなかったときに
使われる**保険の値**です（ページを開いた瞬間の表示でもあります）。ふだんは
`live: null` のままで構いません。

### なぜサーバー側で確かめるのか

ブラウザから直接 youtube.com を読むことはできません（CORSで止まります）。
そこで同じオリジンの `functions/live-now.js` を経由しています。これは
**Cloudflare Pages Functions**（= Cloudflare Workers）で、`functions/` を
リポジトリのルートに置くだけで `/live-now` として公開されます。ビルド設定は
変えなくてよく、APIキーも要りません。

YouTubeがチャンネルの `/live` ページの `<head>` に入れている schema.org の
メタタグを読んで判断しています。

| 見ているもの | 意味 |
| --- | --- |
| `itemprop="isLiveBroadcast"` | 配信（だった）かどうか |
| `itemprop="endDate"` | **これがあると、その配信はもう終わっている** |
| `itemprop="startDate"` | 未来なら待機枠なので、まだ配信中ではない |
| `itemprop="identifier"` | 動画ID |
| `itemprop="name"` | 配信タイトル |

答えは60秒キャッシュされるので、配信の開始・終了がサイトに出るまで最大1分
ほどの遅れがあります。

答えは3種類あります。

| 答え | ページ側の動き |
| --- | --- |
| `{"live":true,…}` | その配信を「配信中」として出す |
| `{"live":false}` | 消灯する |
| `{"unknown":true,…}` | **何もしない**（`SITE.live` の値のまま） |

`unknown` を分けているのが大事なところです。YouTubeが同意画面やボット確認の
ページを返してきたときも、HTTPの status は 200 です。そこには `itemprop` の
メタが入っていないので、これを「配信していない」と答えてしまうと、手で書いた
`SITE.live` の「配信中」まで消えてしまいます。読めなかったときは
`unknown` を返し、ページ側には何もさせません。

「読めた上で配信していない」のか「読めなかった」のかは、`identifier` と
`canonical` で見分けます。動画ID（11文字）なら配信のページ、チャンネルID
（`UC…` 24文字）やチャンネルのURLならチャンネルのページ（= 配信していない）、
どちらでもなければ知らないページ（= `unknown`）です。

### 何が返ってきているか確かめる

```
https://＜サイトのURL＞/live-now?debug=1
```

判定に使った材料をそのまま返します。キャッシュを通さず、YouTubeにも毎回
聞きにいきます。

| 項目 | 見どころ |
| --- | --- |
| `finalUrl` | 追跡の末にどのURLへ着いたか（同意画面へ飛んでいれば一目で分かる） |
| `pageTitle` | 配信タイトルなら正常。「Before you continue」などなら弾かれている |
| `itempropsSeen` | 空っぽなら schema.org のメタが無いページを受け取っている |
| `meta` | 抜き出せた値 |
| `decided` | その材料での判定結果 |

手元で `npx wrangler pages dev public` を動かして
`http://127.0.0.1:8788/live-now?debug=1` と見比べると、コードの問題なのか、
Cloudflareから YouTube がどう見えているかの問題なのかが切り分けられます。

### 手元で `SITE.live` も合わせておきたいとき

`/live-now` があれば不要ですが、保険の値も合わせておきたい場合や、
Cloudflare Pages Functions を使わない場合はこちらを使います。

```powershell
.\update-live.ps1
```

チャンネルを yt-dlp で見て、配信中なら「配信中」の枠と埋め込みプレイヤーを
出し、配信していなければ `live: null,` に戻します。始まったときと終わった
ときで、どちらもこれ1つです。実行したらコミットしてpushします。

| コマンド | すること |
| --- | --- |
| `.\update-live.ps1` | チャンネルを見て、配信状況に合わせる |
| `.\update-live.ps1 -Off` | 問い合わせずに消灯に戻す（yt-dlp も通信も不要） |
| `.\update-live.ps1 -Url <URL>` | チャンネルではなく、その配信を見て判断する |
| `.\update-live.ps1 -Url <URL> -Force` | まだ始まっていない待機枠でも点灯させる |
| `.\update-live.ps1 -Note "21時まで"` | 枠の下にひとこと添える |

待機枠（公開予約）のときは、そのままだと「配信中」と嘘になるため点灯しません。
先に枠を出したいときだけ `-Force` を付けてください。

### 限定公開など、チャンネルの `/live` に出てこない配信

`/live-now` からは見えないので、手で指定します。`-Url` か `-Force` を付けて
実行すると `pinned: true` が書き込まれ、`/live-now` の答えより優先されます。

```powershell
.\update-live.ps1 -Url https://www.youtube.com/watch?v=XXXXXXXXXXX -Force
```

`pinned: true` が付いているあいだは自動確認で動きません。配信が終わったら
`.\update-live.ps1 -Off` で消灯に戻してください。

### 手で書き換える場合

`public/index.html` の `LIVE:BEGIN` 〜 `LIVE:END` の間を次の形にします
（マーカーのコメント行は消さないでください）。

```javascript
live: {
  title: "配信タイトル",
  url: "https://www.youtube.com/watch?v=XXXXXXXXXXX",
  note: "23時ごろまで",       // 任意。枠の下に出るひとこと
  pinned: true                // 任意。自動確認で動かされたくないとき
},
```

配信が終わったら `live: null,` に戻します。

配信中の動画を `urls.txt` に足してしまっても大丈夫です。配信中のものは
「過去の配信」から自動で外れるので、二重には出ません。配信が終われば
そのまま過去の配信として並びます。

## 検索エンジンへの対応

限定公開の配信をまとめているため、既定で検索結果に載らない設定にしています。

- `public/index.html` の `<meta name="robots" content="noindex, nofollow">`
- `public/_headers` の `X-Robots-Tag: noindex, nofollow`

`robots.txt` で `Disallow` にしていないのは意図的です。クロールを禁止すると
noindex の指示自体が読まれず、外部リンク経由で検索結果に載ってしまうためです。

閲覧できる人を絞りたい場合は、Cloudflare Zero Trust の Access を
Pages プロジェクトに設定すると、メールアドレスや所属で制限できます。

## 権利について

サムネイル画像・配信タイトル・配信内容など、配信に関する一切の権利は
アルセチカさんに帰属します。当サイトは有志による非公式のリンク集です。
