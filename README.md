# アルセチカさんの配信置き場

アルセチカさんの配信アーカイブを有志がまとめている非公式サイトです。

## リポジトリの構成

```
.
├── public/            ← Cloudflare Pages が配信するのはここだけ
│   ├── index.html     サイト本体（これ1枚で完結）
│   └── _headers       レスポンスヘッダー設定
├── urls.txt           配信URLの一覧（ここにURLを足していく）
├── update-archives.ps1  urls.txt から index.html を書き換えるスクリプト
└── .gitignore
```

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

配信が始まったら `public/index.html` の `SITE.live` を次のように書き換えます。

```javascript
live: {
  title: "配信タイトル",
  url: "https://www.youtube.com/watch?v=XXXXXXXXXXX"
},
```

配信が終わったら `live: null,` に戻します。

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
