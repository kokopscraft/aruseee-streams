<#
    update-live.ps1

    いま配信中かどうかを yt-dlp で調べて、
    index.html の /* LIVE:BEGIN */ 〜 /* LIVE:END */ の間を書き換えます。

    使い方:
        .\update-live.ps1
            チャンネルを見て、配信中なら点灯・していなければ消灯に合わせます。
            配信が始まったときと終わったとき、どちらもこれ1つで足ります。

        .\update-live.ps1 -Off
            問い合わせずに消灯（live: null）に戻します。
            yt-dlp も通信も要らないので、配信終了後のいちばん確実な手段です。

        .\update-live.ps1 -Url https://www.youtube.com/watch?v=XXXXXXXXXXX
            チャンネルではなく、この配信を見て判断します。
            限定公開でチャンネルの /live に出てこない配信のときに使います。

        .\update-live.ps1 -Url ... -Force -Note "21時ごろから"
            まだ始まっていない待機枠でも点灯させます。

    必要なもの:
        yt-dlp （PATHが通っていること。-YtDlp で場所を直接指定もできます）
        -Off のときは要りません。

    ・APIキーは要りません。限定公開の配信でもURLが分かれば取得できます
    ・書き換え前に public\index.html.bak を作ります（.gitignore 済み）
    ・点灯するのは本当に配信が始まっているときだけです。待機枠（公開予約）の
      ときは「配信中」と出すと嘘になるため、お知らせを出すだけで止まります。
      待機枠を先に出したいときは -Force を付けてください
    ・配信中の動画が archives にも入っていても、index.html 側が「過去の配信」
      から自動で外すので、urls.txt はいつ足しても構いません

    このスクリプトはリポジトリのルートに置きます。
    Cloudflare Pages の公開ディレクトリは public なので、
    これが配信されることはありません。
#>

[CmdletBinding()]
param(
    [string]$Html    = (Join-Path $PSScriptRoot 'public\index.html'),
    [string]$Channel = 'https://www.youtube.com/@aruseee',
    [string]$Url,
    [string]$Note,
    [switch]$Force,
    [switch]$Off,
    [string]$YtDlp   = 'yt-dlp'
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

# 配信していないときの yt-dlp は終了コード0以外で終わります。それが
# 途中終了の原因にならないようにしておきます（PowerShell 7.3以降の設定）。
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# ---- 事前チェック ---------------------------------------------------------
if (-not (Test-Path -LiteralPath $Html)) { throw "ファイルが見つかりません: $Html" }

if (-not $Off -and -not (Get-Command $YtDlp -ErrorAction SilentlyContinue)) {
    throw "yt-dlp が見つかりません。PATHを通すか -YtDlp でパスを指定してください。（消灯だけなら -Off が使えます）"
}

# ---- URLから動画IDを取り出す ---------------------------------------------
function Get-VideoId([string]$s) {
    if ($s -match '[?&]v=([\w-]{6,})')                    { return $Matches[1] }
    if ($s -match '/(?:live|embed|shorts|v)/([\w-]{6,})') { return $Matches[1] }
    if ($s -match 'youtu\.be/([\w-]{6,})')                { return $Matches[1] }
    if ($s -match '^[\w-]{6,}$')                          { return $s }
    return $null
}

# ---- yt-dlp に配信の状態を聞く -------------------------------------------
#  --print-to-file を使うのは文字化け対策です。標準出力を PowerShell が
#  受け取るとコンソールの文字コード次第でタイトルが壊れることがあります。
#  yt-dlp 自身にUTF-8でファイルへ書かせれば、その影響を受けません。
function Get-StreamInfo([string]$target) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aruseee-live-{0}.txt" -f [System.Guid]::NewGuid().ToString('N'))
    try {
        # fulltitle を使います。live_status が is_live のとき %(title)s には
        # yt-dlp が現在時刻を足すため、そのままでは "タイトル 2026-09-03 22:56" になります。
        try {
            & $YtDlp --skip-download --no-warnings --no-playlist --ignore-no-formats-error `
                     --print-to-file "%(id)s`t%(live_status)s`t%(fulltitle)s" $tmp $target 2>$null | Out-Null
        } catch {
            # 配信が無いときは yt-dlp がエラーで終わります。異常ではないので進みます。
        }

        if (-not (Test-Path -LiteralPath $tmp)) { return $null }

        $line = [System.IO.File]::ReadAllLines($tmp, [System.Text.Encoding]::UTF8) |
                Where-Object { $_ -ne '' } |
                Select-Object -First 1
        if (-not $line) { return $null }

        $parts = $line.Split("`t")
        if ($parts.Length -lt 2) { return $null }

        $id = Get-VideoId $parts[0]
        if (-not $id) { return $null }

        $title = if ($parts.Length -gt 2) { $parts[2].Trim() } else { '' }
        if ($title -eq 'NA') { $title = '' }

        return [pscustomobject]@{
            Id     = $id
            Status = $parts[1].Trim()
            Title  = $title
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# ---- いまの状態を決める ---------------------------------------------------
$stream = $null

if ($Off) {
    Write-Host "消灯にします（問い合わせはしません）。" -ForegroundColor Cyan
}
else {
    $target = if ($Url) { $Url } else { "$($Channel.TrimEnd('/'))/live" }
    Write-Host "配信の状態を調べています: $target" -ForegroundColor Cyan

    $info = Get-StreamInfo $target

    if (-not $info) {
        Write-Host "配信は見つかりませんでした。消灯にします。" -ForegroundColor Yellow
    }
    elseif ($info.Status -eq 'is_live') {
        Write-Host "配信中です: $($info.Title)" -ForegroundColor Green
        $stream = $info
    }
    elseif ($info.Status -eq 'is_upcoming') {
        if ($Force) {
            Write-Host "待機枠ですが -Force が付いているので点灯します: $($info.Title)" -ForegroundColor Yellow
            $stream = $info
        }
        else {
            # ここで何もせずに抜けると、前の配信の live: が残ったままになります。
            # 「配信が終わって次の待機枠が立った」ときに終わった配信を配信中と
            # 言い続けてしまうので、待機枠のときも消灯にそろえます。
            Write-Host "待機枠（公開予約）でした。まだ始まっていないので消灯にします。" -ForegroundColor Yellow
            Write-Host "待機枠を先に出したいときは -Force を付けてください。" -ForegroundColor DarkGray
        }
    }
    else {
        # was_live（配信済み）や not_live（ふつうの動画）はここに来ます。
        # チャンネルの /live は、配信していないときに直前の配信を返すことがあります。
        if ($Force) {
            Write-Host "配信中ではありません（$($info.Status)）が、-Force が付いているので点灯します。" -ForegroundColor Yellow
            $stream = $info
        }
        else {
            Write-Host "いまは配信していません（$($info.Status)）。消灯にします。" -ForegroundColor Yellow
        }
    }
}

# ---- JavaScript の値に組み立てる -----------------------------------------
# 文字列は ConvertTo-Json でJSONの文字列リテラルにする（引用符やバックスラッシュ対策）。
# あわせて "</" を "<\/" にします。文字列の中でも </script> と書くと
# HTMLのほうが先に <script> の終わりだと解釈して、ページが壊れるためです。
function ToJsString([string]$s) {
    return (($s | ConvertTo-Json -Compress) -replace '</', '<\/')
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('  /* LIVE:BEGIN */')

if ($stream) {
    $title = if ($stream.Title) { $stream.Title } else { $stream.Id }
    $liveUrl = "https://www.youtube.com/watch?v=$($stream.Id)"

    # 中身の行を先に並べてから , を付けます（最後の行だけ , が要らないため）
    $fields = New-Object System.Collections.Generic.List[string]
    $fields.Add("    title: $(ToJsString $title)")
    $fields.Add("    url: $(ToJsString $liveUrl)")
    if ($Note) { $fields.Add("    note: $(ToJsString $Note)") }

    # -Url や -Force は「人がこの配信を出すと決めた」ということなので、印を付けます。
    # pinned: true が付いていると、ページ側の /live-now による自動確認では
    # 動かしません。チャンネルの /live に出てこない配信を手で出しているときに、
    # 「見つからないから消灯」と判断されてしまうのを防ぐためです。
    if ($Url -or $Force) { $fields.Add('    pinned: true') }

    [void]$sb.AppendLine('  live: {')
    for ($k = 0; $k -lt $fields.Count; $k++) {
        $comma = if ($k -lt $fields.Count - 1) { ',' } else { '' }
        [void]$sb.AppendLine("$($fields[$k])$comma")
    }
    [void]$sb.AppendLine('  },')
}
else {
    [void]$sb.AppendLine('  live: null,')
}

[void]$sb.Append('  /* LIVE:END */')
$block = $sb.ToString()

# ---- index.html を書き換える ----------------------------------------------
# 変数名を $html にしないこと。PowerShell は大文字小文字を区別しないため、
# パラメーターの $Html を中身で上書きしてしまい、保存先が壊れます。
$source = [System.IO.File]::ReadAllText($Html, [System.Text.Encoding]::UTF8)

$pattern = '(?s)[ \t]*/\* LIVE:BEGIN \*/.*?/\* LIVE:END \*/'
if ($source -notmatch $pattern) {
    throw "index.html に LIVE:BEGIN / LIVE:END のマーカーが見つかりません。"
}

# 置換文字列に $ が含まれても壊れないよう MatchEvaluator を使う
$evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }
$updated   = [regex]::Replace($source, $pattern, $evaluator)

if ($updated -eq $source) {
    Write-Host ""
    Write-Host "すでにその状態でした。index.html は変更していません。" -ForegroundColor DarkGray
    # 配信していないときの yt-dlp は 0 以外で終わります。その値がこのスクリプトの
    # 終了コードとして残ると「失敗した」ように見えるので、明示的に 0 で終わります。
    exit 0
}

$backup = "$Html.bak"
[System.IO.File]::WriteAllText($backup, $source,  $utf8NoBom)
[System.IO.File]::WriteAllText($Html,   $updated, $utf8NoBom)

Write-Host ""
if ($stream) {
    Write-Host "完了: 「配信中」の表示に切り替えました。" -ForegroundColor Green
    Write-Host "  $($stream.Title)" -ForegroundColor DarkGray
    Write-Host "  https://www.youtube.com/watch?v=$($stream.Id)" -ForegroundColor DarkGray
} else {
    Write-Host "完了: 「いまは配信していません」の表示に戻しました。" -ForegroundColor Green
}
Write-Host "コミットしてpushすると反映されます。" -ForegroundColor DarkGray
Write-Host "元のファイルは $backup に残しています。" -ForegroundColor DarkGray

# 配信していないときの yt-dlp は 0 以外で終わります。その値がこのスクリプトの
# 終了コードとして残ると「失敗した」ように見えるので、明示的に 0 で終わります。
exit 0
