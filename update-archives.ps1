<#
    update-archives.ps1

    urls.txt に並べたURLから yt-dlp でタイトルと配信日を取得し、
    index.html の /* ARCHIVES:BEGIN */ 〜 /* ARCHIVES:END */ の間を書き換えます。

    使い方:
        .\update-archives.ps1

    必要なもの:
        yt-dlp （PATHが通っていること。--yt-dlp で場所を直接指定もできます）

    ・限定公開の配信でも、URLさえ分かれば取得できます（APIキー不要）
    ・書き換え前に public\index.html.bak を作ります（.gitignore 済み）
    ・取得に失敗した行は、タイトルの代わりに動画IDを入れて先に進みます

    このスクリプトと urls.txt はリポジトリのルートに置きます。
    Cloudflare Pages の公開ディレクトリは public なので、
    これらが配信されることはありません。
#>

[CmdletBinding()]
param(
    [string]$Html   = (Join-Path $PSScriptRoot 'public\index.html'),
    [string]$Urls   = (Join-Path $PSScriptRoot 'urls.txt'),
    [string]$YtDlp  = 'yt-dlp'
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

# 取得に失敗した動画があっても最後まで進みたいので、ネイティブコマンドの
# 終了コードで止まらないようにしておきます（PowerShell 7.3以降の設定）。
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# ---- 事前チェック ---------------------------------------------------------
foreach ($p in @($Html, $Urls)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "ファイルが見つかりません: $p" }
}
if (-not (Get-Command $YtDlp -ErrorAction SilentlyContinue)) {
    throw "yt-dlp が見つかりません。PATHを通すか -YtDlp でパスを指定してください。"
}

# ---- URLから動画IDを取り出す ---------------------------------------------
function Get-VideoId([string]$s) {
    if ($s -match '[?&]v=([\w-]{6,})')              { return $Matches[1] }
    if ($s -match '/(?:live|embed|shorts|v)/([\w-]{6,})') { return $Matches[1] }
    if ($s -match 'youtu\.be/([\w-]{6,})')          { return $Matches[1] }
    if ($s -match '^[\w-]{6,}$')                    { return $s }
    return $null
}

# ---- yt-dlp にタイトルと配信日を聞く -------------------------------------
#  --print-to-file を使うのは文字化け対策です。標準出力を PowerShell が
#  受け取ると、コンソールの文字コード次第でタイトルが壊れます（日本語が
#  全滅します）。yt-dlp 自身にUTF-8でファイルへ書かせれば影響を受けません。
#
#  fulltitle を使うのは、配信中の動画の %(title)s には yt-dlp が現在時刻を
#  足すためです（"タイトル 2026-09-03 22:54" になってしまいます）。
function Get-VideoMeta([string]$url) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aruseee-arch-{0}.txt" -f [System.Guid]::NewGuid().ToString('N'))
    try {
        try {
            & $YtDlp --skip-download --no-warnings --no-playlist `
                     --print-to-file "%(fulltitle)s`t%(upload_date)s" $tmp $url 2>$null | Out-Null
        } catch {
            # 取れない動画（削除済みなど）はここに来ます。呼び出し側で処理します。
        }

        if (-not (Test-Path -LiteralPath $tmp)) { return $null }

        $line = [System.IO.File]::ReadAllLines($tmp, [System.Text.Encoding]::UTF8) |
                Where-Object { $_ -ne '' } |
                Select-Object -First 1
        if (-not $line) { return $null }

        $parts = $line.Split("`t")
        $title = $parts[0].Trim()
        if ($title -eq 'NA') { $title = '' }

        $date = $null
        if ($parts.Length -gt 1) {
            $raw = $parts[1].Trim()
            if ($raw -match '^\d{8}$') {
                $date = '{0}-{1}-{2}' -f $raw.Substring(0,4), $raw.Substring(4,2), $raw.Substring(6,2)
            }
        }

        return [pscustomobject]@{ Title = $title; Date = $date }
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# ---- urls.txt を読む ------------------------------------------------------
$lines = [System.IO.File]::ReadAllLines($Urls, [System.Text.Encoding]::UTF8) |
         ForEach-Object { $_.Trim() } |
         Where-Object   { $_ -ne '' -and -not $_.StartsWith('#') }

if ($lines.Count -eq 0) { throw "urls.txt にURLが1件もありません。" }

Write-Host "$($lines.Count) 件のURLを処理します..." -ForegroundColor Cyan

# ---- yt-dlp でメタデータを取得 --------------------------------------------
$entries = New-Object System.Collections.Generic.List[object]
$failed  = 0
$i       = 0

foreach ($line in $lines) {
    $i++
    $id = Get-VideoId $line
    if (-not $id) {
        Write-Warning "[$i/$($lines.Count)] URLとして読めませんでした: $line"
        $failed++
        continue
    }

    $url = "https://www.youtube.com/watch?v=$id"
    Write-Host ("[{0}/{1}] {2}" -f $i, $lines.Count, $id) -NoNewline

    $title = $null
    $date  = $null
    $meta  = Get-VideoMeta $url
    if ($meta) {
        $title = $meta.Title
        $date  = $meta.Date
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        Write-Host "  取得できませんでした" -ForegroundColor Yellow
        $title = $id
        $failed++
    } else {
        Write-Host "  $title" -ForegroundColor DarkGray
    }

    $entries.Add([pscustomobject]@{ Id = $id; Title = $title; Date = $date; Url = $url })
}

if ($entries.Count -eq 0) { throw "1件も取得できなかったので中止します。index.html は変更していません。" }

# ---- JavaScript の配列に組み立てる ---------------------------------------
# 文字列は ConvertTo-Json でJSONの文字列リテラルにする（引用符やバックスラッシュ対策）。
# あわせて "</" を "<\/" にします。文字列の中でも </script> と書くと
# HTMLのほうが先に <script> の終わりだと解釈して、ページが壊れるためです。
function ToJsString([string]$s) {
    return (($s | ConvertTo-Json -Compress) -replace '</', '<\/')
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('    /* ARCHIVES:BEGIN */')
[void]$sb.AppendLine('    /* ここは update-archives.ps1 が自動生成します。手で書き換えても次の実行で消えます */')

for ($n = 0; $n -lt $entries.Count; $n++) {
    $e     = $entries[$n]
    $comma = if ($n -lt $entries.Count - 1) { ',' } else { '' }

    [void]$sb.AppendLine("    { title: $(ToJsString $e.Title),")
    if ($e.Date) {
        [void]$sb.AppendLine("      date: $(ToJsString $e.Date),")
    }
    [void]$sb.AppendLine("      url: $(ToJsString $e.Url) }$comma")
    if ($n -lt $entries.Count - 1) { [void]$sb.AppendLine() }
}

[void]$sb.Append('    /* ARCHIVES:END */')
$block = $sb.ToString()

# ---- index.html を書き換える ----------------------------------------------
# 変数名を $html にしないこと。PowerShell は大文字小文字を区別しないため、
# パラメーターの $Html を中身で上書きしてしまい、保存先が壊れます。
$source = [System.IO.File]::ReadAllText($Html, [System.Text.Encoding]::UTF8)

$pattern = '(?s)[ \t]*/\* ARCHIVES:BEGIN \*/.*?/\* ARCHIVES:END \*/'
if ($source -notmatch $pattern) {
    throw "index.html に ARCHIVES:BEGIN / ARCHIVES:END のマーカーが見つかりません。"
}

# 置換文字列に $ が含まれても壊れないよう MatchEvaluator を使う
$evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }
$updated   = [regex]::Replace($source, $pattern, $evaluator)

$backup = "$Html.bak"
[System.IO.File]::WriteAllText($backup, $source,  $utf8NoBom)
[System.IO.File]::WriteAllText($Html,   $updated, $utf8NoBom)

Write-Host ""
Write-Host "完了: $($entries.Count) 件を index.html に書き込みました。" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "うち $failed 件はタイトルを取得できず、動画IDのままです。" -ForegroundColor Yellow
}
Write-Host "元のファイルは $backup に残しています。" -ForegroundColor DarkGray

# 取得に失敗した動画があると yt-dlp の終了コードが 0 以外で残り、このスクリプト
# 自体が失敗したように見えるので、明示的に 0 で終わります。
exit 0
