/**
 * comix.to 漫画源 v0.6.4
 *
 * 架构：
 * - 元数据：HTTP GET 详情页 initial-data（comix.to 只有详情页有 SSR）
 * - 章节/图片/搜索/发现/分类：走 Dart 桥接（常驻 headless webview，
 *   截获 SPA 自己发出的 /api/v1/* 请求），无窗口不弹窗
 *
 * ⚠️ 教训（v0.3.0 事故）：
 * 1. class 体内不能写 `var`（QuickJS 语法错误 → 整个源加载失败）
 * 2. class 实例字段不能在方法里裸引用（_xxx 是全局查找，不是 this._xxx）。
 *    需要跨方法共享的可变状态放模块级 var（本文件的 _chaptersCache）。
 * 3. 改完必须 node --check 语法校验，再同步到
 *    %APPDATA%/io.github.kyosee/venera/comic_source/（JS 源不进安装包）
 *
 * ⚠️ 教训（v0.5.0 章节/图片只采到几页）：
 * 4. 站方的 API 签名 token 参数名是 **单下划线 `_`**，不是 `__`。
 *    写错会导致所有 API 路径被判"无 token"而降级 DOM（又慢又不全）。
 * 5. token 绑定完整 query string，改任何参数都失效 → 分页必须让 SPA 自己发。
 * 6. 阅读器是 Swiper **slides 虚拟化**（同时只渲染 3~5 张），不是懒加载，
 *    所以 DOM 兜底只能拿到 3~4 张。必须走 API 截获。
 * 7. 图片 CDN（wowpic）防盗链校验 Referer，且高负载时单张响应极慢 →
 *    onImageLoad 带 Referer + timeoutSeconds=90 + cache-bust 重试。
 *    （经验来自 BallonsTranslator 的 utils/scraper/comix_client.py）
 *
 * ⚠️ 教训（v0.6.0 图片全 403）：
 * 8. 2026-10 起整站（含 static.comix.to 封面域）上了 Cloudflare，图片 CDN
 *    轮换域（*.joshuanotes.site 等）是按 **TLS 指纹** 拦截的 WAF（1020 页），
 *    dart:io HttpClient 无论带什么头都 403；真实浏览器内核可直接加载
 *    （连 Referer 都不用）。所以 onImageLoad / onThumbnailLoad 返回
 *    viaWebview: true，由 Dart 侧用离屏 WebView 取字节（ComixImageWorker）。
 */

// 模块级缓存：同一会话内章节列表只采一次
var _chaptersCache = {};

// 图片重试计数：同一 URL 失败次数，用于 cache-bust 绕开 CDN 坏副本
var _comixImageRetry = {};

var _comixUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// CDN 防盗链：comix.to 的图片只校验 Referer，带上即可直连下载
var _comixImageHeaders = {
    "Referer": "https://comix.to/",
    "User-Agent": _comixUA,
    "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
};

// 给 URL 追加一次性查询参数，强制 CDN 边缘节点回源（绕开缓存的坏副本）
function _comixBust(url) {
    var n = (_comixImageRetry[url] || 0) + 1;
    _comixImageRetry[url] = n;
    var sep = url.indexOf("?") >= 0 ? "&" : "?";
    return url + sep + "_bt=" + Date.now().toString(36) + n.toString(36);
}

// 图片加载配置：viaWebview=true 走 Dart 侧离屏 WebView（真实浏览器 TLS，
// 绕开 CDN 的指纹 WAF 与主站域的 CF challenge）。Dart 侧为导航优先 +
// 3 通道并行，这里的超时是"整张图的硬预算"（导航+回读共用）。
// ⚠️ 阅读与下载是两套预算（Dart 侧按 forDownload 取字段）：
// - 阅读：timeoutSeconds=30 硬超时 + retryLimit=0（单次尝试）——用户要求
//   "10s 出图可容忍，30s 即超时"，到点出错误 UI + 手动重试按钮，不干等；
// - 下载：downloadTimeoutSeconds=30 + downloadRetryLimit=3 —— 单图 30s 硬
//   超时（用户要求：30s 即证明无效，记 missing 待修复）；comix_client 还会对
//   连续 2 次 403/导航失败的"章节 token"降级 6s 快失败（S12 主机封锁检测）。
function _comixImageConfig(url) {
    return {
        url: url,
        headers: _comixImageHeaders,
        timeoutSeconds: 30,
        viaWebview: true,
        retryLimit: 0,
        downloadTimeoutSeconds: 30,
        downloadRetryLimit: 3,
        onLoadFailed: function() {
            return _comixImageConfig(_comixBust(url));
        },
    };
}

// API 条目 → VeneraX comic 卡片。字段名按详情 API 推断（hid/slug/title/poster），
// 兼容 poster 对象/字符串、url 路径兜底。
function _comixMapComic(it) {
    var hid = (it.hid || "").toString();
    var slug = (it.slug || "").toString();
    if ((!hid || !slug) && it.url) {
        var m = /\/title\/([A-Za-z0-9]+)-?(.+)?$/.exec(it.url);
        if (m) {
            if (!hid) hid = m[1];
            if (!slug && m[2]) slug = m[2];
        }
    }
    if (!hid) return null;
    var cover = "";
    if (it.poster && typeof it.poster === 'object') {
        cover = it.poster.large || it.poster.medium || it.poster.small || "";
    } else if (typeof it.poster === 'string') {
        cover = it.poster;
    } else if (it.cover) {
        cover = it.cover;
    }
    var tags = [];
    if (it.genres && it.genres.length) {
        for (var i = 0; i < it.genres.length; i++) {
            var g = it.genres[i];
            tags.push(typeof g === 'string' ? g : (g.title || ""));
        }
    } else if (it.types && it.types.length) {
        tags = it.types.slice();
    }
    return {
        id: hid + "//" + slug,
        title: it.title || hid,
        cover: cover,
        tags: tags,
    };
}

function _comixMapList(res) {
    var items = (res && res.items) || [];
    var lastPage = (res && res.lastPage) || 0;
    var comics = [];
    for (var i = 0; i < items.length; i++) {
        var c = _comixMapComic(items[i]);
        if (c) comics.push(c);
    }
    return { comics: comics, maxPage: lastPage || (comics.length > 0 ? 1 : 0) };
}

class ComixTo extends ComicSource {
    name = "comix.to";
    key = "comix_to";
    version = "0.6.4";
    minAppVersion = "1.4.0";
    url = "https://comix.to";

    // === 搜索：SPA 搜索页是空壳（无 SSR），API 要签名 token，
    // 必须走 headless webview 桥接（comix_browse）===
    search = {
        load: async function(keyword, searchOption, page) {
            page = page || 1;
            console.log("comix_to: search keyword=" + keyword + " page=" + page);
            var res = await sendMessage({
                method: "comix_browse",
                query: { q: keyword },
                page: page,
            });
            var out = _comixMapList(res);
            console.log("comix_to: search got " + out.comics.length + " comics, maxPage=" + out.maxPage);
            return out;
        },
        loadNext: async function(keyword, searchOption, next) {
            if (!next) return { comics: [], next: null };
            var res = await this.load(keyword, searchOption, next);
            var hasMore = res.maxPage > next;
            return { comics: res.comics, next: hasMore ? next + 1 : null };
        },
    };

    // === 发现：真实数据（/browse 默认排序 = 最新更新）===
    explore = [{
        title: "comix.to 最新更新",
        type: "multiPageComicList",
        load: async function(page) {
            page = page || 1;
            var res = await sendMessage({
                method: "comix_browse",
                query: {},
                page: page,
            });
            return _comixMapList(res);
        },
    }];

    // === 分类：types/statuses 是稳定枚举（从前端 bundle 逆向确认）。
    // genres_in 需要数字 id（/api/v1/manga/genres 动态获取），暂不接入。===
    category = {
        title: "comix.to",
        parts: [{
            name: "类型",
            type: "fixed",
            categories: ["Manga", "Manhwa", "Manhua", "Other"],
            itemType: "category",
            categoryParams: ["manga", "manhwa", "manhua", "other"],
        }, {
            name: "状态",
            type: "fixed",
            categories: ["连载中", "已完结", "休刊", "已断更"],
            itemType: "category",
            categoryParams: ["releasing", "finished", "on_hiatus", "discontinued"],
        }],
        enableRankingPage: false,
    }

    categoryComics = {
        load: async function(category, param, options, page) {
            page = page || 1;
            var query = {};
            // param 属于 types 还是 statuses：按枚举值判断
            if (["manga", "manhwa", "manhua", "other"].indexOf(param) >= 0) {
                query.types = param;
            } else {
                query.statuses = param;
            }
            var res = await sendMessage({
                method: "comix_browse",
                query: query,
                page: page,
            });
            return _comixMapList(res);
        },
    };

    // 注意：不定义 favorites —— comix.to 收藏需要站内账号登录，未实现登录前
    // 不提供该功能（parser 检测不到 favorites 就不会显示收藏入口，
    // 避免 "Not login" 报错）。
    account = {};
    settings = {};

    // === 漫画详情 + 章节 ===
    comic = {
        loadInfo: async function(id) {
            console.log("comix_to: loadInfo id=" + id);
            var hid, slug;
            if (id.indexOf('//') >= 0) {
                var parts = id.split('//');
                hid = parts[0];
                slug = parts[1] || '';
            } else {
                hid = id;
                slug = '';
            }
            if (!hid) throw new Error("invalid comic id: " + id);

            var headers = {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Accept": "text/html,*/*",
            };

            var html = null;
            // slug 为空时不要拼尾随 '-'（会 404）
            var urls = slug
                ? ["https://comix.to/title/" + hid + "-" + slug]
                : [];
            urls.push("https://comix.to/title/" + hid);
            for (var i = 0; i < urls.length; i++) {
                console.log("comix_to: fetching " + urls[i]);
                try {
                    var res = await Network.get(urls[i], headers);
                    console.log("comix_to: status=" + res.status + " len=" + (res.body ? res.body.length : 0));
                    if (res.status === 200 && res.body) {
                        html = res.body;
                        break;
                    }
                } catch (e) {
                    console.warn("comix_to: fetch err: " + e);
                }
            }
            // 2026-10-05：整站 CF managed challenge 后 dio 通道全 403。
            // 降级走常驻离屏 WebView 的页内同源 fetch（与章节采集同一通道）。
            if (!html) {
                for (var j = 0; j < urls.length; j++) {
                    try {
                        console.log("comix_to: fallback to webview fetch " + urls[j]);
                        var res2 = await sendMessage({
                            method: "comix_fetch_html",
                            url: urls[j],
                        });
                        if (res2 && res2.status === 200 && res2.body) {
                            html = res2.body;
                            break;
                        }
                    } catch (e2) {
                        console.warn("comix_to: webview fetch err: " + e2);
                    }
                }
            }
            if (!html) throw new Error("all URLs failed for hid=" + hid);

            // comix.to 实际格式：<script type="application/json" id="initial-data">
            var startTag = 'id="initial-data">';
            var startIdx = html.indexOf(startTag);
            if (startIdx < 0) throw new Error("no initial-data in page");
            var jsonStart = startIdx + startTag.length;
            var endIdx = html.indexOf('</script>', jsonStart);
            if (endIdx < 0) throw new Error("malformed initial-data");
            var data = JSON.parse(html.substring(jsonStart, endIdx));

            var detail = null;
            var queries = data.queries || {};
            var detailKey = JSON.stringify(["manga", "detail", hid]);
            if (queries[detailKey]) {
                detail = queries[detailKey];
            } else {
                var keys = Object.keys(queries);
                for (var j = 0; j < keys.length; j++) {
                    if (keys[j].indexOf('"manga"') >= 0 && keys[j].indexOf('"detail"') >= 0) {
                        detail = queries[keys[j]];
                        break;
                    }
                }
            }
            if (!detail) throw new Error("no manga detail for hid " + hid);
            console.log("comix_to: title=" + detail.title + " status=" + detail.status);

            var cover = "";
            if (detail.poster && typeof detail.poster === 'object') {
                cover = detail.poster.large || detail.poster.medium || "";
            } else if (typeof detail.poster === 'string') {
                cover = detail.poster;
            }

            var tagsObj = {};
            if (detail.demographics && detail.demographics.title) {
                tagsObj["人群"] = [detail.demographics.title];
            }
            if (detail.genres && detail.genres.length > 0) {
                var gnames = [];
                for (var gi = 0; gi < detail.genres.length; gi++) {
                    if (detail.genres[gi].title) gnames.push(detail.genres[gi].title);
                }
                if (gnames.length > 0) tagsObj["类型"] = gnames;
            }
            if (detail.tags && detail.tags.length > 0) {
                var tnames = [];
                for (var ti = 0; ti < detail.tags.length; ti++) {
                    if (detail.tags[ti].title) tnames.push(detail.tags[ti].title);
                }
                if (tnames.length > 0) tagsObj["标签"] = tnames;
            }
            var authors = [];
            if (detail.authors) {
                if (Array.isArray(detail.authors)) {
                    for (var ai = 0; ai < detail.authors.length; ai++) {
                        if (detail.authors[ai].title) authors.push(detail.authors[ai].title);
                    }
                } else if (detail.authors.title) {
                    authors.push(detail.authors.title);
                }
            }
            if (authors.length > 0) tagsObj["作者"] = authors;
            var artists = [];
            if (detail.artists) {
                if (Array.isArray(detail.artists)) {
                    for (var a2 = 0; a2 < detail.artists.length; a2++) {
                        if (detail.artists[a2].title) artists.push(detail.artists[a2].title);
                    }
                } else if (detail.artists.title) {
                    artists.push(detail.artists.title);
                }
            }
            if (artists.length > 0) tagsObj["画师"] = artists;
            var statusMap = {"releasing": "连载", "completed": "完结", "hiatus": "休刊", "cancelled": "取消"};
            var status = statusMap[detail.status] || "";
            if (status) tagsObj["状态"] = [status];
            var updateTime = detail.chapterUpdatedAtFormatted || detail.updatedAtFormatted || "";
            if (updateTime) tagsObj["更新"] = [updateTime];

            var mangaUrl;
            if (detail.url && detail.url.charAt(0) === '/') {
                mangaUrl = "https://comix.to" + detail.url;
            } else {
                mangaUrl = "https://comix.to/title/" + (detail.hid || hid) + "-" + (slug || "");
            }

            // --- 章节列表（先查缓存，命中直接返回） ---
            var chapters = {};
            var cacheKey = hid + '|' + slug;
            if (_chaptersCache[cacheKey] && Object.keys(_chaptersCache[cacheKey]).length > 0) {
                console.log("comix_to: using cached chapters for " + cacheKey);
                chapters = _chaptersCache[cacheKey];
            } else {
                try {
                    console.log("comix_to: calling Dart bridge comix_fetch_chapters...");
                    var versioned = await sendMessage({
                        method: "comix_fetch_chapters",
                        hid: hid,
                        slug: slug,
                    });
                    if (versioned && typeof versioned === 'object' && Object.keys(versioned).length > 0) {
                        chapters = versioned;
                        _chaptersCache[cacheKey] = versioned;
                        console.log("comix_to: got " + Object.keys(versioned).length + " chapter numbers, cached");
                    } else {
                        console.warn("comix_to: headless webview returned empty chapters");
                    }
                } catch (e) {
                    console.warn("comix_to: fetch chapters via bridge failed: " + e);
                }
            }

            var subtitle = "";
            if (detail.altTitles && detail.altTitles.length > 0) {
                var alts = [];
                for (var ai2 = 0; ai2 < Math.min(3, detail.altTitles.length); ai2++) {
                    if (detail.altTitles[ai2]) alts.push(detail.altTitles[ai2]);
                }
                subtitle = alts.join(" / ");
            }

            return {
                title: detail.title || hid,
                subtitle: subtitle,
                cover: cover,
                description: detail.synopsis || "",
                tags: tagsObj,
                chapters: chapters,
                url: mangaUrl,
                uploadTime: updateTime,
            };
        },

        loadEp: async function(comicId, epId) {
            console.log("comix_to: loadEp comicId=" + comicId + " epId=" + epId);
            if (!epId) throw new Error("comix_to: empty epId");
            // epId 是 versioned map 里的章节 key（comix.to 章节页完整 URL）。
            // Dart 侧 ComixClient 用常驻 headless webview 打开该章节页，
            // 截获 SPA 自己发出的 /api/v1/chapters/{id} JSON 响应。
            var images = await sendMessage({
                method: "comix_fetch_pages",
                chapterUrl: epId,
            });
            if (!Array.isArray(images) || images.length === 0) {
                throw new Error("comix_to: no images returned for " + epId);
            }
            console.log("comix_to: loadEp got " + images.length + " images");
            return { images: images };
        },

        // === 图片加载配置 ===
        // 图片 CDN 轮换域有按 TLS 指纹拦截的 CF WAF，封面域 static.comix.to
        // 上了 CF challenge——都必须走 WebView（viaWebview），dio 链路已废。
        onImageLoad: function(imageKey, comicId, epId) {
            return _comixImageConfig(imageKey);
        },

        // 封面/缩略图在 static.comix.to（CF challenge 后面），同样走 WebView
        // （首次约几秒过挑战，之后同源/缓存走快路径）
        onThumbnailLoad: function(imageKey, comicId) {
            return {
                url: imageKey,
                headers: _comixImageHeaders,
                timeoutSeconds: 30,
                viaWebview: true,
            };
        },
    };
}
