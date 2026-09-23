<#
    update-archives.ps1

    urls.txt に並べたURLから yt-dlp でタイトルと配信日を取得し、
    index.html の /* ARCHIVES:BEGIN */ 〜 /* ARCHIVES:END */ の間を書き換えます。

    使い方:
        .\update-archives.ps1            新しく足したURLだけ取得します
        .\update-archives.ps1 -Refresh   載っているものも含めて、全部取り直します

    必要なもの:
        yt-dlp （PATHが通っていること。-YtDlp で場所を直接指定もできます）

    ・限定公開の配信でも、URLさえ分かれば取得できます（APIキー不要）
    ・書き換え前に public\index.html.bak を作ります（.gitignore 済み）
    ・タイトルと日付がそろって index.html に載っている動画は、yt-dlp に
      聞かずにそのまま使います。何十件もまとめて聞くと、YouTubeの
      ボット確認で止められやすくなるためです
    ・取得に失敗しても、index.html に載っていたタイトルと日付は消しません
    ・yt-dlp で取れなかった新しい動画は、埋め込み用の oEmbed からタイトルだけ
      取ります。日付は空欄のまま進み、次に yt-dlp が動いたときに埋まります
    ・どこからも取れなかったものだけ、タイトルの代わりに動画IDを入れます

    このスクリプトと urls.txt はリポジトリのルートに置きます。
    Cloudflare Pages の公開ディレクトリは public なので、
    これらが配信されることはありません。
#>

[CmdletBinding()]
param(
    [string]$Html   = (Join-Path $PSScriptRoot 'public\index.html'),
    [string]$Urls   = (Join-Path $PSScriptRoot 'urls.txt'),
    [string]$YtDlp  = 'yt-dlp',
    [switch]$Refresh
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

# ---- 文字列を JavaScript の文字列リテラルにする ----------------------------
# ConvertTo-Json でJSONの文字列リテラルにする（引用符やバックスラッシュ対策）。
# あわせて "</" を "<\/" にします。文字列の中でも </script> と書くと
# HTMLのほうが先に <script> の終わりだと解釈して、ページが壊れるためです。
function ToJsString([string]$s) {
    return (($s | ConvertTo-Json -Compress) -replace '</', '<\/')
}

# 画面に出すためだけに、JavaScript の文字列リテラルを普通の文字列に戻します
function FromJsString([string]$js) {
    if (-not $js) { return '' }
    try { return [string]($js | ConvertFrom-Json) } catch { return $js.Trim('"') }
}

# ---- yt-dlp の ERROR: の行を、画面に出す短い理由にする ---------------------
function Get-FailureReason($errorLines) {
    $first = @($errorLines) | Select-Object -First 1
    if (-not $first) { return '' }
    if ($first -match 'not a bot') { return 'YouTubeのボット確認で止められました' }
    # それ以外は yt-dlp の文面から "ERROR: [youtube] 動画ID: " を落として、そのまま出します
    $text = ($first -replace '^ERROR:\s*(\[[^\]]*\]\s*)?([\w-]{11}:\s*)?', '').Trim()
    if ($text.Length -gt 100) { $text = $text.Substring(0, 100) + '…' }
    return $text
}

# ---- yt-dlp にタイトルと配信日を聞く -------------------------------------
#  --print-to-file を使うのは文字化け対策です。標準出力を PowerShell が
#  受け取ると、コンソールの文字コード次第でタイトルが壊れます（日本語が
#  全滅します）。yt-dlp 自身にUTF-8でファイルへ書かせれば影響を受けません。
#
#  fulltitle を使うのは、配信中の動画の %(title)s には yt-dlp が現在時刻を
#  足すためです（"タイトル 2026-09-03 22:54" になってしまいます）。
#
#  失敗したときの理由（yt-dlp の ERROR: の行）も拾って返します。捨てていると
#  「取得できませんでした」としか出せず、ボット確認で止められているのか、
#  動画が消されたのかが分かりません。
function Get-VideoMeta([string]$url) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aruseee-arch-{0}.txt" -f [System.Guid]::NewGuid().ToString('N'))
    $errors = @()
    try {
        # stderr を受け取るあいだだけ Stop を緩めます。古い PowerShell では、
        # stderr の1行目が来た時点で例外になってしまうためです。
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $errors = @(& $YtDlp --skip-download --no-warnings --no-playlist `
                            --print-to-file "%(fulltitle)s`t%(upload_date)s" $tmp $url 2>&1 |
                        ForEach-Object { "$_" } |
                        Where-Object { $_ -like 'ERROR:*' })
        } catch {
            # 取れない動画（削除済みなど）はここに来ることがあります。呼び出し側で処理します。
        } finally {
            $ErrorActionPreference = $saved
        }

        $result = [pscustomobject]@{
            Title   = ''
            Date    = $null
            Reason  = (Get-FailureReason $errors)
            Blocked = [bool](@($errors) -match 'not a bot')
        }

        if (-not (Test-Path -LiteralPath $tmp)) { return $result }

        $line = [System.IO.File]::ReadAllLines($tmp, [System.Text.Encoding]::UTF8) |
                Where-Object { $_ -ne '' } |
                Select-Object -First 1
        if (-not $line) { return $result }

        $parts = $line.Split("`t")
        $title = $parts[0].Trim()
        if ($title -eq 'NA') { $title = '' }
        $result.Title = $title

        if ($parts.Length -gt 1) {
            $raw = $parts[1].Trim()
            if ($raw -match '^\d{8}$') {
                $result.Date = '{0}-{1}-{2}' -f $raw.Substring(0,4), $raw.Substring(4,2), $raw.Substring(6,2)
            }
        }

        return $result
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# ---- yt-dlp で取れなかったときの控え: oEmbed にタイトルだけ聞く ------------
#  oEmbed は埋め込み用の公開の入口で、限定公開の動画でもタイトルを返します
#  （yt-dlp の fulltitle と同じ文字列です）。yt-dlp とは別の入口なので、
#  yt-dlp がボット確認で止められていても通ることがあります。
#  日付は返ってこないので、タイトル専用です。
function Get-OEmbedTitle([string]$url) {
    $api = 'https://www.youtube.com/oembed?format=json&url=' + [uri]::EscapeDataString($url)
    try {
        $res = Invoke-RestMethod -Uri $api -TimeoutSec 20
        return ([string]$res.title).Trim()
    } catch {
        return ''
    }
}

# ---- urls.txt を読む ------------------------------------------------------
$lines = [System.IO.File]::ReadAllLines($Urls, [System.Text.Encoding]::UTF8) |
         ForEach-Object { $_.Trim() } |
         Where-Object   { $_ -ne '' -and -not $_.StartsWith('#') }

if ($lines.Count -eq 0) { throw "urls.txt にURLが1件もありません。" }

# ---- index.html にすでに載っているタイトルと日付を読む --------------------
#  聞き直さなくて済むものは聞き直さない、取れなかったときに消さない、のために
#  使います。タイトルは JavaScript の文字列リテラルの形のまま持っておき、
#  そのまま書き戻します（戻してから書き直すと、エスケープの違いで差分が出るため）。
#
#  変数名を $html にしないこと。PowerShell は大文字小文字を区別しないため、
#  パラメーターの $Html を中身で上書きしてしまい、保存先が壊れます。
$source = [System.IO.File]::ReadAllText($Html, [System.Text.Encoding]::UTF8)

# 動画IDは大文字と小文字を区別します。@{} は区別しないので Dictionary を使います
$known = New-Object 'System.Collections.Generic.Dictionary[string,object]'

$blockMatch = [regex]::Match($source, '(?s)/\* ARCHIVES:BEGIN \*/(.*?)/\* ARCHIVES:END \*/')
if ($blockMatch.Success) {
    $jsString = '"(?:[^"\\]|\\.)*"'
    # { ... } をひとつずつ取り出します。タイトルの中の { } で切れないよう、
    # 文字列リテラルはまとめて読み飛ばします
    $objectRe = '\{(?:[^{}"]|' + $jsString + ')*\}'

    foreach ($obj in [regex]::Matches($blockMatch.Groups[1].Value, $objectRe)) {
        $urlMatch = [regex]::Match($obj.Value, '\burl:\s*(' + $jsString + ')')
        if (-not $urlMatch.Success) { continue }
        $knownId = Get-VideoId $urlMatch.Groups[1].Value
        if (-not $knownId -or $known.ContainsKey($knownId)) { continue }

        $titleMatch = [regex]::Match($obj.Value, '\btitle:\s*(' + $jsString + ')')
        $dateMatch  = [regex]::Match($obj.Value, '\bdate:\s*"(\d{4}-\d{2}-\d{2})"')

        $titleJs = if ($titleMatch.Success) { $titleMatch.Groups[1].Value } else { $null }
        # 空のタイトルと、前回どこからも取れずに動画IDを入れておいたものは
        # 「タイトル無し」として扱い、取り直しの対象にします
        if ($titleJs -eq '""' -or $titleJs -ceq ('"' + $knownId + '"')) { $titleJs = $null }

        $known[$knownId] = [pscustomobject]@{
            TitleJs = $titleJs
            Date    = $(if ($dateMatch.Success) { $dateMatch.Groups[1].Value } else { $null })
        }
    }
}

Write-Host "$($lines.Count) 件のURLを処理します..." -ForegroundColor Cyan

# ---- タイトルと日付をそろえる ----------------------------------------------
$entries = New-Object System.Collections.Generic.List[object]
$asked   = 0
$reused  = 0
$noTitle = 0
$noDate  = 0
$blocked = $false
$i       = 0

foreach ($line in $lines) {
    $i++
    $id = Get-VideoId $line
    if (-not $id) {
        Write-Warning "[$i/$($lines.Count)] URLとして読めませんでした: $line"
        continue
    }

    $url  = "https://www.youtube.com/watch?v=$id"
    $prev = if ($known.ContainsKey($id)) { $known[$id] } else { $null }
    Write-Host ("[{0}/{1}] {2}" -f $i, $lines.Count, $id) -NoNewline

    # タイトルも日付もそろっているものは聞き直しません（-Refresh のときだけ聞き直します）
    if ($prev -and $prev.TitleJs -and $prev.Date -and -not $Refresh) {
        Write-Host "  （登録済み）$(FromJsString $prev.TitleJs)" -ForegroundColor DarkGray
        $entries.Add([pscustomobject]@{ TitleJs = $prev.TitleJs; Date = $prev.Date; Url = $url })
        $reused++
        continue
    }

    $meta = Get-VideoMeta $url
    $asked++
    if ($meta.Blocked) { $blocked = $true }

    $newTitleJs  = if ($meta.Title) { ToJsString $meta.Title } else { $null }
    $prevTitleJs = if ($prev) { $prev.TitleJs } else { $null }
    $prevDate    = if ($prev) { $prev.Date } else { $null }

    # -Refresh のときは取り直した値を優先し、ふだんは載っている値を優先します
    # （ふだん聞きにいくのは、足りない項目を埋めるときだけなので）。
    # どちらの場合も、取れなかった項目は載っている値のまま残します。
    if ($Refresh) {
        $titleJs = if ($newTitleJs) { $newTitleJs } else { $prevTitleJs }
        $date    = if ($meta.Date)  { $meta.Date }  else { $prevDate }
    } else {
        $titleJs = if ($prevTitleJs) { $prevTitleJs } else { $newTitleJs }
        $date    = if ($prevDate)    { $prevDate }    else { $meta.Date }
    }

    $why  = if ($meta.Reason) { "（yt-dlp: $($meta.Reason)）" } else { '' }
    $from = ''
    if (-not $titleJs) {
        $oembed = Get-OEmbedTitle $url
        if ($oembed) {
            $titleJs = ToJsString $oembed
            $from    = '（タイトルは oEmbed から）'
        }
    }

    if (-not $titleJs) {
        Write-Host "  取得できませんでした$why" -ForegroundColor Yellow
        $titleJs = ToJsString $id
        $noTitle++
    } elseif ($meta.Title) {
        Write-Host "  $(FromJsString $titleJs)" -ForegroundColor DarkGray
    } else {
        Write-Host "  $(FromJsString $titleJs)$from$why" -ForegroundColor Yellow
    }
    if (-not $date) { $noDate++ }

    $entries.Add([pscustomobject]@{ TitleJs = $titleJs; Date = $date; Url = $url })
}

if ($entries.Count -eq 0) { throw "1件も取得できなかったので中止します。index.html は変更していません。" }

# ---- JavaScript の配列に組み立てる ---------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('    /* ARCHIVES:BEGIN */')
[void]$sb.AppendLine('    /* ここは update-archives.ps1 が自動生成します。タイトルと日付は次の実行でも引き継ぎますが、それ以外の書き足し（note など）は消えます */')

for ($n = 0; $n -lt $entries.Count; $n++) {
    $e     = $entries[$n]
    $comma = if ($n -lt $entries.Count - 1) { ',' } else { '' }

    [void]$sb.AppendLine("    { title: $($e.TitleJs),")
    if ($e.Date) {
        [void]$sb.AppendLine("      date: $(ToJsString $e.Date),")
    }
    [void]$sb.AppendLine("      url: $(ToJsString $e.Url) }$comma")
    if ($n -lt $entries.Count - 1) { [void]$sb.AppendLine() }
}

[void]$sb.Append('    /* ARCHIVES:END */')
$block = $sb.ToString()

# ---- index.html を書き換える ----------------------------------------------
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
Write-Host ("完了: {0} 件を index.html に書き込みました（yt-dlp に問い合わせ {1} 件 / 登録済みをそのまま {2} 件）。" -f $entries.Count, $asked, $reused) -ForegroundColor Green
if ($noTitle -gt 0) {
    Write-Host "うち $noTitle 件はタイトルを取得できず、動画IDのままです。" -ForegroundColor Yellow
}
if ($noDate -gt 0) {
    Write-Host "うち $noDate 件は日付が空欄です。yt-dlp が動くときにもう一度実行すると埋まります。" -ForegroundColor Yellow
}
if ($blocked) {
    Write-Host "yt-dlp が YouTube のボット確認で止められています。時間をおくと通るようになることがあります。" -ForegroundColor Yellow
}
Write-Host "元のファイルは $backup に残しています。" -ForegroundColor DarkGray

# 取得に失敗した動画があると yt-dlp の終了コードが 0 以外で残り、このスクリプト
# 自体が失敗したように見えるので、明示的に 0 で終わります。
exit 0
