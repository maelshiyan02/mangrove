class Baozi extends ComicSource {
  // 此漫画源的名称
  name = "包子漫画";

  // 唯一标识符
  key = "baozi";

  // 🔴 2026-10-11 (Mangrove P39) 清理死域名：
  // - `bzmgcn.com` / `baozimhcn.com` / `cnbzmg.com` 现已 302 重定向到官方
  //   `www.baozimh.com/__gatekeeper_challenge`（Cloudflare 硬挑战，实测 cn.cnbzmg.com
  //   /cn.bzmgcn.com/cn.baozimhcn.com 全部 403），是「包子每章卡在验证」的元凶；
  // - `asgb-a3.bzcdn.net` TLS 证书主体不匹配（SEC_E_WRONG_PRINCIPAL）。
  // 存活镜像 webmota/kukuc/twmanga/dinnerku 与图床 s1.bzcdn / s2.bzcdn 等均实测
  // 200 且**无 CF 挑战**（P39 取证），固优先使用。保留上游 PoW 挑战降级逻辑。
  //
  // 🔴 2026-10-11 P41：镜像长期"200 但拿不到图"的真根因不是网络/CF，而是站点
  // Vue SSR + AMP 改版后章节页图片 DOM 变为
  // `.comic-contain div[data-v] > amp-img.comic-contain__item[data-src]`，
  // 旧解析器选择器 `.comic-contain > .chapter-img` 0 命中 → 误兜底 appcn。
  // loadEp::parseImages 已改为后代选择器直取 .comic-contain__item（新旧通吃）。
  //
  // 🔴 2026-10-11 P42：站点把**每个章节再分页**（标题形如 "第1话(1/4)"，
  // URL 依次 0_<ep>.html / 0_<ep>_2.html …，每页约 50 张且相邻页有重叠）。
  // 旧实现只取第一页 ⇒ 每章恒定 50 张（用户复测："被限制成 50 页"）。
  // loadEp 已改为逐页抓取 + 按图片 URL 去重保序。
  //
  // 🔴 2026-10-27 (Mangrove P48) 包子源"最新章只有 App 能看"修复:
  //   实证(灭门家族重生者 第152章): 镜像站对刚更新的最新章内容同步残缺——
  //   章页 200 但只塞 1 张图、且引用了错误 slug(meishaonianbangjiashijian
  //   -aojianyixi2)的资源, 该资源在镜像 CDN(s2.bzcdn.net)上根本不存在(404
  //   NoSuchKey); 完整正确的图只在官方 app 域(appcn.baozimh.com, 用 s2/s
  //   .baozicdn.com)有 91 张。镜像侧未升级防护(无新 CF 挑战), 纯属镜像同步
  //   滞后 + 资源主机不匹配。修复四处:
  //   ① 图床候选补 s2.baozicdn.com / s.baozicdn.com(官方域真实图床);
  //   ② onImageLoad 改为**链式穷举**所有图床(引擎每轮重读 configs
  //      .onLoadFailed, 故每个候选自带下一个 onLoadFailed, distinct 闭包避免
  //      free 后复用同一 JSInvokable);
  //   ③ collectPages 首图识别"残缺/串错书": 首图数极少(<5) 且 所有首图都不含
  //      本书 slug(comicId) ⇒ 抛 DomainBlock 触发回落官方 app 域;
  //   ④ 回落**不得**改写/吞掉 CloudflareException: appcn 对本 App 下发 CF 挑战
  //      (Dio 层抛 CloudflareException), UI 靠该消息自动跑离屏验证再重试。
  //      v1.2.6 曾把它包成 DomainChallenge 且自塞 UA —— 已在 v1.2.7 撤销
  //      (UA 非变量, 挑战判据是 TLS 指纹; 引擎缺省注入 webUA)。
  // 🔴 2026-10-31 (Mangrove P54-baozi) 整章分页 + comicId 后缀修复 (v1.2.8):
  //   站点现把每章再分页(标题 "第N话(a/b)"), 且阅读页 URL 的 comicId 必须带
  //   per-comic 后缀(<cid>_<suffix>, 如 _9lavj0), 否则第 2 页起被站点钳制回第 1 页
  //   → 逐页去重 added=0 提前 break → 整章恒被截断成 50 页(实测"秘密小姐"第11话
  //   只显 50 页, 实有 144 页)。修复: loadInfo 从章节 href 提取后缀存盘, loadEp 拼
  //   到 comicId 后。appcn 兜底路径维持不带后缀(P48 行为, 未实测验证)。
  version = "1.2.9";

  minAppVersion = "1.0.0";

  // 更新链接
  url = "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/baozi.js";

  settings = {
    language: {
      title: "简繁切换",
      type: "select",
      options: [
        { value: "cn", text: "简体" },
        { value: "tw", text: "繁體" },
      ],
      default: "cn",
    },
    domains: {
      title: "主域名",
      type: "select",
      options: [
        { value: "webmota.com" },
        { value: "kukuc.co" },
        { value: "twmanga.com" },
        { value: "dinnerku.com" },
      ],
      default: "webmota.com",
    },
    cdn_domains: {
      title: "图片资源站域名",
      type: "select",
      options: [
        { value: "s1.bzcdn.net" },
        { value: "as-rsa1-usla.baozicdn.com" },
        { value: "as.baozimh.com" },
        { value: "s1.baozicdn.com" },
        { value: "s2.baozicdn.com" },
        { value: "s.baozicdn.com" },
        { value: "", text: "默认" },
      ],
      default: "",
    },
    auto_failover: {
      title: "域名自动故障转移",
      title_eng: "Automatic domain failover",
      type: "switch",
      default: true,
    },
    image_quality: {
      title: "图片质量",
      type: "select",
      options: [
        {
          value: "/w640",
          text: "640p"
        },
        {
          value: "",
          text: "原图"
        }
      ],
      default: "/w640",
    },
  };

  // 动态生成完整域名
  get lang() {
    return this.loadSetting("language") || this.settings.language.default;
  }
  get baseUrl() {
    let domain = this.loadSetting("domains") || this.settings.domains.default;
    return `https://${this.lang}.${domain}`;
  }

  get imageQuality() {
    return this.loadSetting("image_quality") || "";
  }

  get autoFailover() {
    return this.loadSetting("auto_failover") !== false;
  }

  // 浏览器 UA, 用于图片防盗链
  static browserUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

  // 上次成功的网页域名, init() 时从持久化数据恢复
  _goodDomain = null;

  // 🔴 2026-10-31 (Mangrove P54-baozi) 整章分页修复:
  //   站点把每章再分页(标题如 "第11话(1/3)"), 且阅读页 URL 的 comicId 现在必须带
  //   per-comic 后缀(形如 <cid>_9lavj0), 否则第 2 页起被站点钳制回第 1 页内容,
  //   逐页去重后 added=0 提前 break → 整章恒被截断成 50 页(用户实测"秘密小姐"第11话
  //   只显示 50 页, 实有 144 页)。loadInfo 从章节 href 提取该后缀存于此 + 持久化,
  //   loadEp 拼到 comicId 后面。无后缀(旧站点/无分页章)时维持空串, 兼容旧行为。
  _comicIdSuffix = null;

  init() {
    try {
      this._goodDomain = this.loadData("good_web_domain") || null;
    } catch (e) {
      this._goodDomain = null;
    }
  }

  // 用户在设置中选择的域名
  get selectedDomain() {
    return this.loadSetting("domains") || this.settings.domains.default;
  }

  // 最近触发过验证挑战(PoW)的域名 → 30 分钟内降级。
  // 目的: 验证一次之后, 后续章节直接走可用域, 不再每章都先吃一次 2 分钟挑战。
  get _challengedDomains() {
    try {
      return this.loadData("challenged_domains") || {};
    } catch (e) {
      return {};
    }
  }

  _markChallenged(domain) {
    if (!domain) return;
    try {
      const map = this._challengedDomains;
      map[domain] = Date.now();
      this.saveData("challenged_domains", map);
    } catch (e) {}
  }

  _isChallenged(domain) {
    const ts = this._challengedDomains[domain];
    return !!ts && Date.now() - ts < 30 * 60 * 1000;
  }

  // 有序的网页域名候选: 上次可用域名 → 选中域名 → 其余未挑战域 → 被挑战域
  get webDomains() {
    const selected = this.selectedDomain;
    let rest = this.settings.domains.options
      .map((o) => o.value)
      .filter((v) => v && v !== selected);
    rest = [...new Set(rest)];
    const good =
      this.autoFailover && this._goodDomain && this._goodDomain !== selected
        ? this._goodDomain
        : null;
    const fresh = (d) => !this._isChallenged(d);
    let ordered = [];
    if (good && fresh(good)) ordered.push(good);
    if (fresh(selected)) ordered.push(selected);
    ordered.push(...rest.filter((d) => d !== good && fresh(d)));
    // 被挑战过的域排最后: 真没别的可用时再试
    if (!fresh(selected)) ordered.push(selected);
    ordered.push(...rest.filter((d) => d !== good && !fresh(d)));
    return [...new Set(ordered)];
  }

  // 与 webDomains 对应的完整 baseUrl 候选
  baseCandidates() {
    return this.webDomains.map((d) => `https://${this.lang}.${d}`);
  }

  // 记住成功的域名, 仅在变化时写盘, 避免频繁 IO
  _rememberGoodDomain(domain) {
    if (!domain || domain === this._goodDomain) return;
    this._goodDomain = domain;
    try {
      this.saveData("good_web_domain", domain);
    } catch (e) {}
  }

  // 判断错误是否值得切换到下一个域名
  // 403(镜像封锁/防盗链)、429(限流)、0 与 5xx(网络/服务端) 才切换;
  // 404 属于业务错误(漫画确实不存在), 不切换, 避免掩盖真实结果
  _isFallbackError(error) {
    if (!this.autoFailover) return false;
    const msg = String((error && error.message) || error || "");
    const statusMatch = msg.match(/invalid status code:\s*(\d+)/i);
    if (statusMatch) {
      const code = Number(statusMatch[1]);
      return code === 0 || code === 403 || code === 429 || code >= 500;
    }
    // 自定义的"页面可达但内容为空/被风控"标记
    if (/domainblock/i.test(msg)) return true;
    // 403+挑战被 Dart 侧包装成 CloudflareException：换下一个镜像域名
    // （挑战域的 cookie 与本域不互通，重试本域只会再吃一次挑战）。
    if (/cloudflare/i.test(msg)) return true;
    return /timeout|timed out|connection (?:reset|closed|refused|aborted|closed by peer)|peer closed|broken pipe|network error|failed to fetch|fetch failed|unexpected.?eof|socket (?:exception|hangu|error)|getaddrinfo|host lookup|name or service not known|errnoexception|winerror|10054|10061|11001/i.test(
      msg
    );
  }

  // 依次尝试各镜像域名执行 operation(base, domain)
  // 只有可回退错误才切换, 成功后记住该域名
  async withDomains(operation) {
    const bases = this.baseCandidates();
    let lastError = null;
    for (let i = 0; i < bases.length; i++) {
      const base = bases[i];
      const domain = this.webDomains[i];
      try {
        const result = await operation(base, domain);
        this._rememberGoodDomain(domain);
        return result;
      } catch (e) {
        lastError = e;
        // 挑战(PoW)过的域名降级, 后续请求直接走可用域
        if (/cloudflare|challenge/i.test(String((e && e.message) || e))) {
          this._markChallenged(domain);
        }
        if (i < bases.length - 1 && this._isFallbackError(e)) {
          continue;
        }
        throw e;
      }
    }
    throw lastError;
  }

  // 图片 CDN 候选(与网页域名独立, 可单独故障转移)
  get cdnCandidates() {
    return [
      ...new Set(
        this.settings.cdn_domains.options.map((o) => o.value).filter((v) => v)
      ),
    ];
  }

  // 按设置替换图片 URL 中的图床域名与质量参数
  _applyImageSettings(imgUrl) {
    const match = imgUrl.match(
      /^(https?:\/\/)?([^/\s:]+)(:\d+)?(\/[a-z]comic\/.*)/
    );
    if (!match) return imgUrl;
    const cdnSetting = this.loadSetting("cdn_domains");
    const domain = cdnSetting === "" || !cdnSetting ? match[2] : cdnSetting;
    return `${match[1]}${domain}${this.imageQuality}${match[4]}`;
  }

  // 图床候选(排除当前域)的全部替换, 按优先级排列, 路径保持不变。
  // 用于 onImageLoad 链式穷举: 引擎每轮都会重读 configs.onLoadFailed
  // (images.dart:294), 故每个 onLoadFailed 返回"下一个候选 + 自带下一个
  // onLoadFailed"; 且每个链接都是独立闭包(引擎会 free 上一个, 不可复用引用)。
  _cdnAlternativesFor(url) {
    if (!this.autoFailover || !url || !/^https?:\/\//i.test(url)) return [];
    const match = url.match(/^(https?:\/\/)([^\/:]+)(:\d+)?(\/.*)$/i);
    if (!match) return [];
    const current = match[2];
    return this.cdnCandidates
      .filter((h) => h !== current)
      .map((h) => `${match[1]}${h}${match[3] || ""}${match[4]}`);
  }


  /// 账号
  /// 设置为null禁用账号功能
  account = {
    /// 登录
    /// 返回任意值表示登录成功
    login: async (account, pwd) => {
      let res = await Network.post(
        `${this.baseUrl}/api/bui/signin`,
        {
          "content-type":
            "multipart/form-data; boundary=----WebKitFormBoundaryFUNUxpOwyUaDop8s",
        },
        '------WebKitFormBoundaryFUNUxpOwyUaDop8s\r\nContent-Disposition: form-data; name="username"\r\n\r\n' +
        account +
        '\r\n------WebKitFormBoundaryFUNUxpOwyUaDop8s\r\nContent-Disposition: form-data; name="password"\r\n\r\n' +
        pwd +
        "\r\n------WebKitFormBoundaryFUNUxpOwyUaDop8s--\r\n"
      );
      if (res.status !== 200) {
        throw "Invalid status code: " + res.status;
      }
      let json = JSON.parse(res.body);
      let token = json.data;
      Network.setCookies(this.baseUrl, [
        new Cookie({
          name: "TSID",
          value: token,
          domain: this.loadSetting("domains") || this.settings.domains.default,
        }),
      ]);
      return "ok";
    },

    // 退出登录时将会调用此函数
    logout: function () {
      Network.deleteCookies(
        this.loadSetting("domains") || this.settings.domains.default
      );
    },

    get registerWebsite() {
      return `${this.baseUrl}/user/signup`;
    },
  };

  /// 解析漫画列表
  parseComic(e) {
    let url = e.querySelector("a").attributes["href"];
    let id = url.split("/").pop();
    let title = e.querySelector("h3").text.trim();
    let cover = e.querySelector("a > amp-img").attributes["src"];
    let tags = e.querySelectorAll("div.tabs > span").map((e) => e.text.trim());
    let description = e.querySelector("small").text.trim();
    return {
      id: id,
      title: title,
      cover: cover,
      tags: tags,
      description: description,
    };
  }

  parseJsonComic(e) {
    return {
      id: e.comic_id,
      title: e.name,
      subTitle: e.author,
      cover: `https://static-tw.baozimh.com/cover/${e.topic_img}?w=285&h=375&q=100`,
      tags: e.type_names,
    };
  }

  /// 探索页面
  /// 一个漫画源可以有多个探索页面
  explore = [
    {
      /// 标题
      /// 标题同时用作标识符, 不能重复
      title: "包子漫画",

      /// singlePageWithMultiPart 或者 multiPageComicList
      type: "singlePageWithMultiPart",

      load: async () => {
        return await this.withDomains(async (base) => {
          var res = await Network.get(base);
          if (res.status !== 200) {
            throw "Invalid status code: " + res.status;
          }
          let document = new HtmlDocument(res.body);
          let parts = document.querySelectorAll("div.index-recommend-items");
          let result = {};
          for (let part of parts) {
            let title = part.querySelector("div.catalog-title").text.trim();
            let comics = part
              .querySelectorAll("div.comics-card")
              .map((e) => this.parseComic(e));
            if (comics.length > 0) {
              result[title] = comics;
            }
          }
          if (Object.keys(result).length === 0) {
            // 页面可达但没有任何分区, 通常是镜像风控/异常页
            throw new Error("DomainBlock: empty explore page");
          }
          return result;
        });
      },
    },
  ];

  /// 分类页面
  /// 一个漫画源只能有一个分类页面, 也可以没有, 设置为null禁用分类页面
  category = {
    /// 标题, 同时为标识符, 不能与其他漫画源的分类页面重复
    title: "包子漫画",
    parts: [
      {
        name: "类型",

        // fixed 或者 random
        // random用于分类数量相当多时, 随机显示其中一部分
        type: "fixed",

        // 如果类型为random, 需要提供此字段, 表示同时显示的数量
        // randomNumber: 5,

        categories: [
          "全部",
          "恋爱",
          "纯爱",
          "古风",
          "异能",
          "悬疑",
          "剧情",
          "科幻",
          "奇幻",
          "玄幻",
          "穿越",
          "冒险",
          "推理",
          "武侠",
          "格斗",
          "战争",
          "热血",
          "搞笑",
          "大女主",
          "都市",
          "总裁",
          "后宫",
          "日常",
          "韩漫",
          "少年",
          "其它",
        ],

        // category或者search
        // 如果为category, 点击后将进入分类漫画页面, 使用下方的`categoryComics`加载漫画
        // 如果为search, 将进入搜索页面
        itemType: "category",

        // 若提供, 数量需要和`categories`一致, `categoryComics.load`方法将会收到此参数
        categoryParams: [
          "all",
          "lianai",
          "chunai",
          "gufeng",
          "yineng",
          "xuanyi",
          "juqing",
          "kehuan",
          "qihuan",
          "xuanhuan",
          "chuanyue",
          "mouxian",
          "tuili",
          "wuxia",
          "gedou",
          "zhanzheng",
          "rexie",
          "gaoxiao",
          "danuzhu",
          "dushi",
          "zongcai",
          "hougong",
          "richang",
          "hanman",
          "shaonian",
          "qita",
        ],
      },
    ],
    enableRankingPage: false,
  };

  /// 分类漫画页面, 即点击分类标签后进入的页面
  categoryComics = {
    load: async (category, param, options, page) => {
      return await this.withDomains(async (base) => {
        let res = await Network.get(
          `${base}/api/bzmhq/amp_comic_list?type=${param}&region=${options[0]}&state=${options[1]}&filter=%2a&page=${page}&limit=36&language=${this.lang}&__amp_source_origin=${base}`
        );
        if (res.status !== 200) {
          throw "Invalid status code: " + res.status;
        }
        let maxPage = null;
        let json = JSON.parse(res.body);
        if (!json.next) {
          maxPage = page;
        }
        return {
          comics: json.items.map((e) => this.parseJsonComic(e)),
          maxPage: maxPage,
        };
      });
    },
    // 提供选项
    optionList: [
      {
        options: ["all-全部", "cn-国漫", "jp-日本", "kr-韩国", "en-欧美"],
      },
      {
        options: ["all-全部", "serial-连载中", "pub-已完结"],
      },
    ],
  };

  /// 搜索
  search = {
    load: async (keyword, options, page) => {
      return await this.withDomains(async (base) => {
        let res = await Network.get(
          `${base}/search?q=${encodeURIComponent(keyword)}`
        );
        if (res.status !== 200) {
          throw "Invalid status code: " + res.status;
        }
        let document = new HtmlDocument(res.body);
        let comics = document
          .querySelectorAll("div.comics-card")
          .map((e) => this.parseComic(e));
        return {
          comics: comics,
          maxPage: 1,
        };
      });
    },

    // 提供选项
    optionList: [],
  };

  /// 收藏
  favorites = {
    /// 是否为多收藏夹
    multiFolder: false,
    /// 添加或者删除收藏
    addOrDelFavorite: async (comicId, folderId, isAdding) => {
      if (!isAdding) {
        let res = await Network.post(
          `${this.baseUrl}/user/operation_v2?op=del_bookmark&comic_id=${comicId}`
        );
        if (!res.status || res.status >= 400) {
          throw "Invalid status code: " + res.status;
        }
        return "ok";
      } else {
        let res = await Network.post(
          `${this.baseUrl}/user/operation_v2?op=set_bookmark&comic_id=${comicId}&chapter_slot=0`
        );
        if (!res.status || res.status >= 400) {
          throw "Invalid status code: " + res.status;
        }
        return "ok";
      }
    },
    // 加载收藏夹, 仅当multiFolder为true时有效
    // 当comicId不为null时, 需要同时返回包含该漫画的收藏夹
    loadFolders: null,
    /// 加载漫画
    loadComics: async (page, folder) => {
      let res = await Network.get(`${this.baseUrl}/user/my_bookshelf`);
      if (res.status !== 200) {
        throw "Invalid status code: " + res.status;
      }
      let document = new HtmlDocument(res.body);
      function parseComic(e) {
        let title = e.querySelector("h4 > a").text.trim();
        let url = e.querySelector("h4 > a").attributes["href"];
        let id = url.split("/").pop();
        let author = e
          .querySelector("div.info > ul")
          .children[1].text.split("：")[1]
          .trim();
        let description = e
          .querySelector("div.info > ul")
          .children[4].children[0].text.trim();

        return {
          id: id,
          title: title,
          subTitle: author,
          description: description,
          cover: e.querySelector("amp-img").attributes["src"],
        };
      }
      let comics = document
        .querySelectorAll("div.bookshelf-items")
        .map((e) => parseComic(e));
      return {
        comics: comics,
        maxPage: 1,
      };
    },
  };

  /// 单个漫画相关
  comic = {
    // 加载漫画信息
    loadInfo: async (id) => {
      let document = await this.withDomains(async (base) => {
        let res = await Network.get(`${base}/comic/${id}`);
        if (res.status !== 200) {
          throw "Invalid status code: " + res.status;
        }
        let doc = new HtmlDocument(res.body);
        if (!doc.querySelector("h1.comics-detail__title")) {
          throw new Error("DomainBlock: comic detail unavailable");
        }
        return doc;
      });

      let title = document.querySelector("h1.comics-detail__title").text.trim();
      let cover = document.querySelector("div.l-content > div > div > amp-img")
        .attributes["src"];
      let author = document
        .querySelector("h2.comics-detail__author")
        .text.trim();
      let tags = document
        .querySelectorAll("div.tag-list > span")
        .map((e) => e.text.trim());
      tags = [...tags.filter((e) => e !== "")];
      let updateTime = document
        .querySelector("div.supporting-text > div > span > em")
        ?.text.trim()
        .replace("(", "")
        .replace(")", "");
      if (!updateTime) {
        const getLastChapterText = () => {
          // 合并所有章节容器（处理可能存在多个列表的情况）
          const containers = [
            ...document.querySelectorAll(
              "#chapter-items, #chapters_other_list"
            ),
          ];
          let allChapters = [];
          containers.forEach((container) => {
            const chapters = container.querySelectorAll(".comics-chapters > a");
            allChapters.push(...Array.from(chapters));
          });
          const lastChapter = allChapters[allChapters.length - 1];
          return (
            lastChapter?.querySelector("div > span")?.text.trim() ||
            "暂无更新信息"
          );
        };
        updateTime = getLastChapterText();
      }
      let description = document
        .querySelector("p.comics-detail__desc")
        .text.trim();
      let chapters = new Map();
      let i = 0;
      for (let c of document.querySelectorAll(
        "div#chapter-items > div.comics-chapters > a > div > span"
      )) {
        chapters.set(i.toString(), c.text.trim());
        i++;
      }
      for (let c of document.querySelectorAll(
        "div#chapters_other_list > div.comics-chapters > a > div > span"
      )) {
        chapters.set(i.toString(), c.text.trim());
        i++;
      }
      if (i === 0) {
        // 将倒序的最新章节反转
        const spans = Array.from(
          document.querySelectorAll("div.comics-chapters > a > div > span")
        ).reverse();
        for (let c of spans) {
          chapters.set(i.toString(), c.text.trim());
          i++;
        }
      }
      let recommend = [];
      for (let c of document.querySelectorAll("div.recommend--item")) {
        if (c.querySelectorAll("div.tag-comic").length > 0) {
          let title = c.querySelector("span").text.trim();
          let cover = c.querySelector("amp-img").attributes["src"];
          let url = c.querySelector("a").attributes["href"];
          let id = url.split("/").pop();
          recommend.push({
            id: id,
            title: title,
            cover: cover,
          });
        }
      }
      // updateTime 将 Y年 M月 D日 转化为 Y-M-D
      let updateDate = updateTime
        .replace(/年/g, "-")
        .replace(/月/g, "-")
        .replace(/日/g, "");

      // 🔴 2026-10-31 提取 per-comic 后缀供 loadEp 拼接(整章分页修复):
      //   章节链接现为 /user/page_direct?comic_id=<cid>_<suffix>&section_slot=0&...
      //   阅读页 URL 的 comicId 必须带此后缀, 否则第 2 页起被站点钳制回第 1 页。
      try {
        const firstChapHref = document
          .querySelector("#chapter-items a, #chapters_other_list a")
          ?.attributes?.["href"];
        if (firstChapHref) {
          const sm = firstChapHref.match(
            new RegExp(
              "comic_id=" +
                id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") +
                "(_[^&\\s\"]+)"
            )
          );
          if (sm && sm[1]) {
            this._comicIdSuffix = sm[1];
            this.saveData("baozi_chapter_suffix_" + id, sm[1]);
          }
        }
      } catch (e) {}

      return new ComicDetails({
        title: title,
        cover: cover,
        description: description,
        tags: {
          作者: [author],
          标签: tags,
        },
        chapters: chapters,
        recommend: recommend,
        updateTime: updateDate,
      });
    },
    loadEp: async (comicId, epId) => {
      // 🔴 2026-11-02 整章分页修复(最终版, 自愈式):
      //   旧实现把 per-comic 后缀寄望于 loadInfo 预先抽取(this._comicIdSuffix /
      //   saveData)。但**阅读器直进章节时 loadInfo 不会先跑** → 后缀缺失 → 第 2 页
      //   被站点钳制回第 1 页 → 逐页去重 added=0 提前 break → 整章恒 50 页。
      //   现改为 loadEp **自给自足**: 先取首页(站点对"首页无后缀"也返回正确内容),
      //   再从首页 HTML 的翻页链接里**现取**本漫画 per-comic 后缀(形如 <cid>_<suffix>),
      //   之后逐页用带后缀的 effectiveId 抓取, 按图片 URL 去重保序。不同镜像后缀不同
      //   → 从当前镜像 HTML 现取, 天然镜像无关。
      //   兼容站点两种形态:
      //     · 整章单页(如 appcn, 144 图一次给全) → 首页即全, 第 2 页无新图 → break;
      //     · 整章分页(如 webmota, 每页 ~50, 标题 (1/3)) → 跟随分页拿全 144。

      // 网页阅读页与 App 页 DOM 同构, 使用同一解析器
      // 🔴 2026-10-11 (Mangrove P41) 站点 Vue SSR + AMP 改版:
      //   .comic-contain
      //     └ div[data-v]            (新增的包裹层, 旧版没有)
      //         └ amp-img#chapter-img-N-N.comic-contain__item[data-src]
      //   旧选择器 ".comic-contain > .chapter-img" 同时假设了「直接子节点」
      //   和「chapter-img 是 class」, 改版后双重不匹配 → HTTP 200 却解析出
      //   0 张图 → 四个镜像全抛 DomainBlock → 误兜底 appcn → Cloudflare 卡死
      //   (P41 运行时埋点实锤, curl 同页 50 图正常)。
      //   新写法直接选容器后代的 .comic-contain__item 取 data-src,
      //   对新旧(节点是 amp-img 或内层包裹 item)两种 DOM 都成立。
      const parseImages = (body) => {
        const doc = new HtmlDocument(body);
        const images = [];
        doc.querySelectorAll(".comic-contain .comic-contain__item").forEach(
          (imgNode) => {
            const attrs = imgNode.attributes || {};
            const imgUrl = attrs["data-src"] || attrs["src"];
            if (imgUrl) {
              images.push(this._applyImageSettings(imgUrl));
            }
          }
        );
        return images;
      };

      // 标题形如 "第1话(1/4)" → {current,total}; 无分页标记的站点返回 null
      const pagerOf = (body) => {
        const t = String(body).match(/<title>([^<]*)<\/title>/);
        if (!t) return null;
        const m = t[1].match(/[（(](\d+)\s*\/\s*(\d+)[）)]/);
        if (!m) return null;
        return { current: parseInt(m[1], 10), total: parseInt(m[2], 10) };
      };
      const pagePath = (page) =>
        page === 1 ? `0_${epId}.html` : `0_${epId}_${page}.html`;

      // 🔴 从首页 HTML 的翻页链接提取本漫画 per-comic 后缀。
      //   首页里形如 .../comic/chapter/<cid>(_<suffix>)?/0_<epId>_<N>.html (N>=2)
      //   的链接, 捕获其中的 _<suffix> 段。兜底返回 ""(单页站点无需后缀)。
      const detectSuffix = (body) => {
        try {
          const doc = new HtmlDocument(body);
          const cidQ = comicId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
          const epQ = String(epId).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
          const re = new RegExp(
            "comic/chapter/" + cidQ + "(_[^/\"\\s]+)?/0_" + epQ + "_(\\d+)\\.html"
          );
          let suffix = "";
          doc.querySelectorAll("a").forEach((a) => {
            const href = (a.attributes && a.attributes["href"]) || "";
            const m = href.match(re);
            if (m && m[2] && parseInt(m[2], 10) >= 2) {
              suffix = m[1] || "";
            }
          });
          return suffix;
        } catch (e) {
          return "";
        }
      };

      // 1) 优先走网页阅读页: 随主域名自动故障转移, 无需 Cloudflare 验证
      //    https://<lang>.<镜像>/comic/chapter/<comicId>/0_<epId>.html
      try {
        const images = await this.withDomains(async (base) => {
          // 1a) 取首页(无需后缀, 站点对首页无后缀也返回正确内容)
          const firstRes = await Network.get(
            `${base}/comic/chapter/${comicId}/${pagePath(1)}`
          );
          if (!firstRes || firstRes.status !== 200) {
            throw `Invalid status code: ${firstRes ? firstRes.status : "null"}`;
          }
          // 1b) 自愈: 从首页翻页链接现取后缀, 兜底 loadInfo 留下的值 / 持久化
          let comicIdSuffix =
            detectSuffix(firstRes.body) || this._comicIdSuffix || "";
          if (!comicIdSuffix) {
            try {
              comicIdSuffix =
                this.loadData("baozi_chapter_suffix_" + comicId) || "";
            } catch (e) {}
          }
          if (comicIdSuffix) {
            try {
              this._comicIdSuffix = comicIdSuffix;
              this.saveData("baozi_chapter_suffix_" + comicId, comicIdSuffix);
            } catch (e) {}
          }
          const effectiveId =
            comicIdSuffix && !comicId.endsWith(comicIdSuffix)
              ? comicId + comicIdSuffix
              : comicId;

          // 1c) 逐页收集(首页已取, 后续页用带后缀的 effectiveId)
          const seen = new Set();
          const collected = [];
          const pushImages = (urls) => {
            let added = 0;
            for (const u of urls) {
              if (seen.has(u)) continue;
              seen.add(u);
              collected.push(u);
              added++;
            }
            return added;
          };

          let added = pushImages(parseImages(firstRes.body));
          if (collected.length === 0) {
            throw new Error("DomainBlock: empty chapter images");
          }
          // 🔴 2026-10-27 (Mangrove P48) 镜像"200 但残缺/串错书"识别(保留):
          //   主信号: 所有首图都不含本书 slug(comicId) ⇒ 串错书; 仅当同时满足
          //   "首图极少(<5)"才判残缺。正常章图多(≥50)且 slug 正确, 两者互斥。
          const slugOk = collected.some((u) => u.indexOf(comicId) >= 0);
          if (!slugOk && collected.length < 5) {
            throw new Error(
              "DomainBlock: mirror chapter images reference a different comic " +
                "(slug mismatch, likely an unsynced latest chapter)"
            );
          }
          let pager = pagerOf(firstRes.body);
          let total = pager ? pager.total : null;

          // 跟随分页: 第 2 页起用带后缀的 effectiveId
          for (let page = 2; page <= 200; page++) {
            const res = await Network.get(
              `${base}/comic/chapter/${effectiveId}/${pagePath(page)}`
            );
            if (!res || res.status !== 200) {
              if (total != null && page <= total) {
                throw new Error(
                  `DomainBlock: chapter page ${page} status ${res ? res.status : "null"}`
                );
              }
              break;
            }
            const pg = pagerOf(res.body);
            if (pg) {
              if (pg.current > pg.total) break; // 越界被站点钳制到末页
              if (total == null) total = pg.total;
            }
            const pgAdded = pushImages(parseImages(res.body));
            if (pgAdded === 0) break; // 无新图即到底(兼容无分页标记站点)
            if (total != null && page >= total) break;
          }
          return collected;
        });
        return { images: images };
      } catch (webError) {
        // 2) 所有镜像网页都失败时, 兜底官方 App 接口 appcn.baozimh.com。
        //
        // 🔴 2026-10-27 (Mangrove P48, v1.2.7 定稿) 该域对**本 App** 会下发
        //   Cloudflare 挑战: Dio 层识别 403 + `Cf-Mitigated: challenge` 后抛
        //   `CloudflareException`, 由 UI 错误页(lib/components/loading.dart)
        //   解析该消息 → 自动跑一次**离屏 WebView 验证** → 成功即自动 retry。
        //   这是 App 既有的自愈通道, **源里绝不能把它吞掉或改写成别的字符串**,
        //   否则 CloudflareException.fromString 匹配不上 ⇒ 自动验证不触发 ⇒
        //   用户只看到一条干巴巴的报错(v1.2.6 曾这么干, 属回归, 已撤销)。
        //
        //   同理**不要**在这里自己塞 User-Agent: curl 实测 UA 不是关键变量
        //   (Chrome/126、131、155 三个 UA 全是 200), 挑战判据来自 Dart/BoringSSL
        //   的 TLS 指纹, 源层换 UA 无效; 而引擎(js_engine.dart `_http`)本就会在
        //   缺省时注入 consts.webUA, 源再写死一个版本号只会随浏览器更新过期。
        if (!this._isFallbackError(webError)) {
          throw webError;
        }
        const appBase = "https://appcn.baozimh.com/baozimhapp";
        const images = await collectPages(async (page) => {
          const res = await Network.get(
            `${appBase}/comic/chapter/${comicId}/${pagePath(page)}`
          );
          return { status: res.status, body: res.body };
        });
        return { images: images };
      }
    },

    // 章节图片加载配置: 携带站点 Referer 防盗链;
    // 当前图床失败时**链式穷举**所有候选 CDN 重试(路径不变)——
    // 引擎每轮重读 configs.onLoadFailed, 所以每个 onLoadFailed 返回
    // "下一个候选 URL + 自带下一个 onLoadFailed"。每个链接闭包互相独立,
    // 避免引擎 free 上一个后复用同一 JSInvokable 导致 use-after-free。
    onImageLoad: (url, comicId, epId) => {
      const referer = `${this.baseUrl}/`;
      const buildHeaders = () => ({
        Referer: referer,
        "User-Agent": this.constructor.browserUA,
      });
      const alts = this._cdnAlternativesFor(url);
      if (alts.length === 0) {
        return { headers: buildHeaders() };
      }
      // link(k): 第 k 个候选也失败时, 返回第 k+1 个候选并挂上 link(k+1)。
      // 每个 link 都是新闭包, 互不相同。
      const link = (k) => () => {
        if (k >= alts.length) return null;
        const next = { url: alts[k], headers: buildHeaders() };
        if (k + 1 < alts.length) next.onLoadFailed = link(k + 1);
        return next;
      };
      return {
        headers: buildHeaders(),
        retryLimit: alts.length + 1,
        onLoadFailed: link(0),
      };
    },
  };
}
