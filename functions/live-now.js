/**
 * GET /live-now
 *
 * いまアルセチカさんが配信中かどうかを調べて、JSONで返します。
 * Cloudflare Pages Functions（= Cloudflare Workers）として動きます。
 * リポジトリのルートに functions/ を置くと、ビルド設定を変えなくても
 * Cloudflare Pages が自動で拾って /live-now で公開してくれます。
 *
 * なぜサーバー側でやるのか:
 *   ブラウザから直接 youtube.com を読むことはできません（CORSで止まります）。
 *   同じオリジンのこの関数を経由すれば、その制限を受けません。
 *
 * 返すもの:
 *   配信中     { "live": true, "id": "...", "title": "...", "url": "...",
 *               "startedAt": "2026-09-03T13:03:53+00:00" }
 *   していない { "live": false }
 *
 * APIキーは要りません。YouTubeがページの <head> に入れている schema.org の
 * メタタグを読んでいるだけです。実際にこう入っています。
 *
 *   <link rel="canonical" href="https://www.youtube.com/watch?v=XXXXXXXXXXX">
 *   <meta itemprop="identifier"      content="XXXXXXXXXXX">
 *   <meta itemprop="name"            content="配信タイトル">
 *   <meta itemprop="isLiveBroadcast" content="True">
 *   <meta itemprop="startDate"       content="2026-09-03T13:03:53+00:00">
 *   <meta itemprop="endDate"         content="...">   ← 配信が終わると増える
 *
 * 判定は次のとおりです。
 *   ・isLiveBroadcast が True で
 *   ・endDate が無く（あれば、その配信はもう終わっています）
 *   ・startDate が未来でない（未来なら待機枠なので、まだ配信中ではない）
 *
 * HTMLRewriter を使うのは、1MBほどあるYouTubeのページをJavaScriptの文字列に
 * せずに、必要なタグだけ抜き出すためです。文字列にして正規表現をかけると
 * CPU時間の上限に当たります。
 *
 * チャンネルの /live に出てこない配信（限定公開など）は、この関数からは
 * 見えません。そういう配信は update-live.ps1 -Url <URL> で index.html に
 * 直接書いてください。この関数はその値を消したりしません（後述の SKEW と
 * 同じく、判断できないときは「わからない」を返すだけです）。
 */

/* 調べにいくチャンネル。ハンドルが変わったらここだけ直せば動きます */
const CHANNEL = "https://www.youtube.com/@aruseee";

/* 結果を寝かせる秒数。配信の開始・終了がサイトに出るまでの最大の遅れです。
   短くするとYouTubeへの問い合わせが増えます */
const CACHE_SECONDS = 60;

/* 予定時刻をわずかに過ぎただけの待機枠を「配信中」と誤判定しないための余裕（ミリ秒） */
const SKEW_MS = 60 * 1000;

const BROWSER_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

/* HTMLの属性値に入っている実体参照を戻します（&amp; → &）。
   YouTubeは content="People &amp; Blogs" のように書いてきます */
function decodeEntities(s) {
  if (!s || s.indexOf("&") === -1) return s || "";
  return s
    .replace(/&(?:#(\d+)|#[xX]([0-9a-fA-F]+)|(amp|lt|gt|quot|apos|#39));/g, function (all, dec, hex, name) {
      if (dec) return String.fromCodePoint(parseInt(dec, 10));
      if (hex) return String.fromCodePoint(parseInt(hex, 16));
      switch (name) {
        case "amp":  return "&";
        case "lt":   return "<";
        case "gt":   return ">";
        case "quot": return '"';
        default:     return "'";
      }
    });
}

/* YouTubeの動画IDは必ず11文字です。
   配信していないとき、チャンネルの /live はチャンネルのページになり、
   itemprop="identifier" には動画IDではなく**チャンネルID**（UC…の24文字）が
   入ります。それを動画IDとして扱ってしまわないよう、長さで弾きます */
const VIDEO_ID_RE = /^[\w-]{11}$/;

/* YouTubeのURLから動画IDを取り出します（index.html の videoIdOf と同じ考え方） */
function videoIdOf(url) {
  if (!url) return "";
  var m = /[?&]v=([\w-]{6,})/.exec(url);
  if (m) return m[1];
  m = /\/(?:live|embed|shorts|v)\/([\w-]{6,})/.exec(url);
  if (m) return m[1];
  m = /youtu\.be\/([\w-]{6,})/.exec(url);
  if (m) return m[1];
  return "";
}

/**
 * 抜き出したメタ情報から「いま配信中か」を決めます。
 * 副作用のない関数にしてあるので、そのままテストできます。
 */
export function decideLive(meta, nowMs) {
  /* identifier は動画IDのときだけ使います。チャンネルのページだと
     チャンネルIDが入っているので、そのときは canonical から取り直します */
  const id = VIDEO_ID_RE.test(meta.identifier || "")
    ? meta.identifier
    : videoIdOf(meta.canonical);
  if (!id) return { live: false };

  /* isLiveBroadcast が無い、または True でなければ、ふつうの動画です */
  if (String(meta.isLiveBroadcast).toLowerCase() !== "true") return { live: false };

  /* endDate があるなら、その配信はもう終わっています */
  if (meta.endDate) return { live: false };

  /* startDate が未来なら待機枠。まだ「配信中」ではありません */
  if (meta.startDate) {
    const start = Date.parse(meta.startDate);
    if (Number.isFinite(start) && start > nowMs + SKEW_MS) return { live: false };
  }

  const out = {
    live: true,
    id: id,
    title: decodeEntities(meta.name || ""),
    url: "https://www.youtube.com/watch?v=" + id,
  };
  if (meta.startDate) out.startedAt = meta.startDate;
  return out;
}

/* YouTubeのページから、必要な <meta> と <link> だけを抜き出します。
   HTMLRewriter はCloudflare側（Rust実装）で流しながら処理するので、
   1MBのページでもJavaScript側の負荷はほとんどありません */
async function extractMeta(response) {
  const meta = {};
  const wanted = {
    identifier: 1, name: 1, isLiveBroadcast: 1, startDate: 1, endDate: 1,
  };

  const transformed = new HTMLRewriter()
    .on("meta[itemprop]", {
      element(el) {
        const key = el.getAttribute("itemprop");
        if (key && wanted[key] && meta[key] === undefined) {
          meta[key] = el.getAttribute("content") || "";
        }
      },
    })
    .on('link[rel="canonical"]', {
      element(el) {
        if (meta.canonical === undefined) meta.canonical = el.getAttribute("href") || "";
      },
    })
    .transform(response);

  /* 中身は使わないので、パーサーを走らせるためだけに読み捨てます。
     text() だと1MBを文字列にしてしまうので arrayBuffer() を使います */
  await transformed.arrayBuffer();
  return meta;
}

function jsonResponse(body, seconds) {
  return new Response(JSON.stringify(body), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "public, max-age=" + seconds,
    },
  });
}

export async function onRequestGet(context) {
  const { request, waitUntil } = context;

  /* 同じ答えを使いまわします。1分に1回だけYouTubeを見にいく形にするためです */
  const cacheKey = new Request(new URL("/live-now", request.url).toString(), { method: "GET" });
  const cache = caches.default;

  const hit = await cache.match(cacheKey);
  if (hit) return hit;

  let payload;
  try {
    const upstream = await fetch(CHANNEL.replace(/\/+$/, "") + "/live", {
      headers: {
        "user-agent": BROWSER_UA,
        "accept": "text/html,application/xhtml+xml",
        "accept-language": "ja,en;q=0.8",
      },
      redirect: "follow",
      cf: { cacheTtl: CACHE_SECONDS, cacheEverything: true },
    });

    if (!upstream.ok) {
      /* YouTube側の一時的な失敗。「配信していない」と断言はしません。
         unknown を返すと、ページ側は index.html に書いてある値を使い続けます */
      return jsonResponse({ unknown: true, reason: "upstream " + upstream.status }, 15);
    }

    const meta = await extractMeta(upstream);
    payload = decideLive(meta, Date.now());
  } catch (err) {
    return jsonResponse({ unknown: true, reason: "error" }, 15);
  }

  const response = jsonResponse(payload, CACHE_SECONDS);
  waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}
