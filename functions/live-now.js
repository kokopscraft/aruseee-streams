/**
 * GET /live-now
 * GET /live-now?debug=1
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
 *   わからない { "unknown": true, "reason": "..." }
 *
 * 「わからない」を分けてある理由:
 *   YouTubeが同意画面やボット確認のページを返してきたときも、HTTPの status は
 *   200 です。そのページには itemprop のメタが入っていないので、それを
 *   「配信していない」と答えてしまうと、ページ側はその答えを確定した事実として
 *   受け取り、index.html の SITE.live に書いてある「配信中」を消してしまいます。
 *   読めなかったときは live: false ではなく unknown を返し、ページ側には
 *   SITE.live のままでいてもらいます（index.html 側は unknown を見たら何も
 *   しません）。
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
 *   ・そのページが「配信のページ」だと分かって、
 *   ・isLiveBroadcast が True で
 *   ・endDate が無く（あれば、その配信はもう終わっています）
 *   ・startDate が未来でない（未来なら待機枠なので、まだ配信中ではない）
 *
 * ページの種類の見分けは identifier と canonical で付けます。
 *   動画ID（11文字）           → その配信のページ。上の判定にかける
 *   チャンネルID（UC…24文字）  → チャンネルのページ。/live に配信が無い状態
 *                                なので、はっきり「配信していない」
 *   どちらでもない             → 知らないページ。unknown
 *
 * HTMLRewriter を使うのは、1MBほどあるYouTubeのページをJavaScriptの文字列に
 * せずに、必要なタグだけ抜き出すためです。文字列にして正規表現をかけると
 * CPU時間の上限に当たります。
 *
 * チャンネルの /live に出てこない配信（限定公開など）は、この関数からは
 * 見えません。そういう配信は update-live.ps1 -Url <URL> で index.html に
 * 直接書いてください。この関数はその値を消したりしません。
 *
 * ?debug=1 を付けると、判定に使った材料をそのまま返します。キャッシュを
 * 通さず、YouTubeにも毎回聞きにいきます。「Cloudflareから見えているページは
 * 何なのか」を確かめるための出口です（手元で動くのにデプロイ先で動かない、
 * というときに効きます）。
 */

/* 調べにいくチャンネル。ハンドルが変わったらここだけ直せば動きます */
const CHANNEL = "https://www.youtube.com/@aruseee";

/* 結果を寝かせる秒数。配信の開始・終了がサイトに出るまでの最大の遅れです。
   短くするとYouTubeへの問い合わせが増えます */
const CACHE_SECONDS = 60;

/* 「わからない」を寝かせる秒数。読めなかっただけなので短めにして、
   次の問い合わせで立ち直れるようにします */
const UNKNOWN_CACHE_SECONDS = 15;

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

/* YouTubeの動画IDは必ず11文字です */
const VIDEO_ID_RE = /^[\w-]{11}$/;

/* チャンネルIDは UC で始まる24文字です。配信していないとき、チャンネルの
   /live はチャンネルのページになり、itemprop="identifier" には動画IDではなく
   **チャンネルID**が入ります。それを動画IDとして扱わないよう見分けます */
const CHANNEL_ID_RE = /^UC[\w-]{22}$/;

/* チャンネルのページを指す canonical。identifier が取れなかったときの控えです */
const CHANNEL_URL_RE =
  /^https?:\/\/(?:www\.)?youtube\.com\/(?:@[\w.-]+|channel\/UC[\w-]{22}|c\/[^/?#]+|user\/[^/?#]+)\/?(?:[?#]|$)/i;

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

  if (!id) {
    /* 配信のページではありませんでした。チャンネルのページだと分かるなら、
       「/live に配信が無い」＝配信していない、と言い切れます */
    if (CHANNEL_ID_RE.test(meta.identifier || "") || CHANNEL_URL_RE.test(meta.canonical || "")) {
      return { live: false };
    }
    /* チャンネルのページでもない、知らないページ（同意画面・ボット確認など）。
       ここで live: false と答えると、正しく書かれている SITE.live まで
       消してしまいます。判断できないことを、そのまま伝えます */
    return { unknown: true, reason: "unexpected-page" };
  }

  /* 配信のページのはずなのに schema.org のメタがまるごと無いときも、
     途中で別のページにすり替わったと考えて、断言しません */
  if (meta.isLiveBroadcast === undefined && meta.name === undefined) {
    return { unknown: true, reason: "no-microdata" };
  }

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
   1MBのページでもJavaScript側の負荷はほとんどありません。

   options.debug が真のときは、返ってきたページが何なのかを人が読めるように、
   <title> と itemprop の一覧も一緒に拾います。 */
async function extractMeta(response, options) {
  const meta = {};
  const debug = options && options.debug ? { pageTitle: "", itemprops: [] } : null;
  const wanted = {
    identifier: 1, name: 1, isLiveBroadcast: 1, startDate: 1, endDate: 1,
  };

  const transformed = new HTMLRewriter()
    .on("meta[itemprop]", {
      element(el) {
        const key = el.getAttribute("itemprop");
        if (!key) return;
        if (debug && debug.itemprops.length < 60 && debug.itemprops.indexOf(key) === -1) {
          debug.itemprops.push(key);
        }
        if (wanted[key] && meta[key] === undefined) {
          meta[key] = el.getAttribute("content") || "";
        }
      },
    })
    .on('link[rel="canonical"]', {
      element(el) {
        if (meta.canonical === undefined) meta.canonical = el.getAttribute("href") || "";
      },
    })
    .on("title", {
      text(chunk) {
        /* 同意画面やボット確認のページかどうかは、<title> を見れば一目で
           分かります。debug のときだけ、先頭200文字を拾います */
        if (debug && debug.pageTitle.length < 200) debug.pageTitle += chunk.text;
      },
    })
    .transform(response);

  /* 中身は使わないので、パーサーを走らせるためだけに読み捨てます。
     text() だと1MBを文字列にしてしまうので arrayBuffer() を使います */
  await transformed.arrayBuffer();
  return { meta: meta, debug: debug };
}

function jsonResponse(body, seconds) {
  return new Response(JSON.stringify(body), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": seconds > 0 ? "public, max-age=" + seconds : "no-store",
    },
  });
}

/* ?debug=1 の答え。人がブラウザで開いて読むものなので、見やすく並べて返し、
   キャッシュにも入れません */
function debugResponse(body) {
  return new Response(JSON.stringify(body, null, 2), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

export async function onRequestGet(context) {
  const { request, waitUntil } = context;
  const debug = new URL(request.url).searchParams.get("debug") === "1";

  /* 同じ答えを使いまわします。1分に1回だけYouTubeを見にいく形にするためです */
  const cacheKey = new Request(new URL("/live-now", request.url).toString(), { method: "GET" });
  const cache = caches.default;

  if (!debug) {
    const hit = await cache.match(cacheKey);
    if (hit) return hit;
  }

  const target = CHANNEL.replace(/\/+$/, "") + "/live";
  const init = {
    headers: {
      "user-agent": BROWSER_UA,
      "accept": "text/html,application/xhtml+xml",
      "accept-language": "ja,en;q=0.8",
    },
    redirect: "follow",
  };
  /* debug のときは、いまYouTubeが返してくるページをそのまま見たいので、
     Cloudflare側のキャッシュを通しません */
  if (!debug) init.cf = { cacheTtl: CACHE_SECONDS, cacheEverything: true };

  let payload;
  try {
    const upstream = await fetch(target, init);

    if (!upstream.ok) {
      /* YouTube側の一時的な失敗。「配信していない」と断言はしません。
         unknown を返すと、ページ側は index.html に書いてある値を使い続けます */
      const failed = { unknown: true, reason: "upstream " + upstream.status };
      if (debug) {
        return debugResponse({
          requested: target,
          finalUrl: upstream.url,
          status: upstream.status,
          contentType: upstream.headers.get("content-type"),
          decided: failed,
        });
      }
      return jsonResponse(failed, UNKNOWN_CACHE_SECONDS);
    }

    const found = await extractMeta(upstream, { debug: debug });
    payload = decideLive(found.meta, Date.now());

    if (debug) {
      return debugResponse({
        requested: target,
        finalUrl: upstream.url,
        status: upstream.status,
        contentType: upstream.headers.get("content-type"),
        pageTitle: found.debug.pageTitle.trim(),
        itempropsSeen: found.debug.itemprops,
        meta: found.meta,
        now: new Date().toISOString(),
        decided: payload,
      });
    }
  } catch (err) {
    const failed = { unknown: true, reason: "error" };
    if (debug) {
      return debugResponse({
        requested: target,
        error: String((err && err.message) || err),
        decided: failed,
      });
    }
    return jsonResponse(failed, UNKNOWN_CACHE_SECONDS);
  }

  const response = jsonResponse(payload, payload.unknown ? UNKNOWN_CACHE_SECONDS : CACHE_SECONDS);
  waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}
