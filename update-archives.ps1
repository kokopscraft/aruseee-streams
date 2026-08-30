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
    try {
        $raw = & $YtDlp --skip-download --no-warnings --no-playlist `
                        --print "%(title)s`t%(upload_date)s" $url 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $parts = ([string]$raw).Split("`t")
            $title = $parts[0]
            if ($parts.Length -gt 1 -and $parts[1] -match '^\d{8}$') {
                $date = '{0}-{1}-{2}' -f $parts[1].Substring(0,4),
                                          $parts[1].Substring(4,2),
                                          $parts[1].Substring(6,2)
            }
        }
    } catch { }

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
# 文字列は ConvertTo-Json でJSONの文字列リテラルにする（引用符やバックスラッシュ対策）
function ToJsString([string]$s) { return ($s | ConvertTo-Json -Compress) }

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
$html = [System.IO.File]::ReadAllText($Html, [System.Text.Encoding]::UTF8)

$pattern = '(?s)[ \t]*/\* ARCHIVES:BEGIN \*/.*?/\* ARCHIVES:END \*/'
if ($html -notmatch $pattern) {
    throw "index.html に ARCHIVES:BEGIN / ARCHIVES:END のマーカーが見つかりません。"
}

# 置換文字列に $ が含まれても壊れないよう MatchEvaluator を使う
$evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }
$updated   = [regex]::Replace($html, $pattern, $evaluator)

$backup = "$Html.bak"
[System.IO.File]::WriteAllText($backup,  $html,    $utf8NoBom)
[System.IO.File]::WriteAllText($Html,    $updated, $utf8NoBom)

Write-Host ""
Write-Host "完了: $($entries.Count) 件を index.html に書き込みました。" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "うち $failed 件はタイトルを取得できず、動画IDのままです。" -ForegroundColor Yellow
}
Write-Host "元のファイルは $backup に残しています。" -ForegroundColor DarkGray
