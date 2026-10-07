class Baozi extends ComicSource {
  // 此漫画源的名称
  name = "包子漫画";

  // 唯一标识符
  key = "baozi";

  version = "1.2.0";

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
        { value: "bzmgcn.com" },
        { value: "baozimhcn.com" },
      ],
      default: "webmota.com",
    },
    cdn_domains: {
      title: "图片资源站域名",
      type: "select",
      options: [
        { value: "s1.bzcdn.net" },
        { value: "asgb-a3.bzcdn.net" },
        { value: "as-rsa1-usla.baozicdn.com" },
        { value: "as.baozimh.com" },
        { value: "s1.baozicdn.com" },
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

  // 有序的网页域名候选: 选中域名 → 上次可用域名 → 其余配置域名
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
    let ordered = [selected];
    if (good) ordered.push(good);
    ordered.push(...rest.filter((d) => d !== good));
    return ordered;
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

  // 图床加载失败时的备用地址: 换另一个 CDN, 路径保持不变
  _altCdnUrlFor(url) {
    if (!this.autoFailover || !url || !/^https?:\/\//i.test(url)) return null;
    const match = url.match(/^(https?:\/\/)([^\/:]+)(:\d+)?(\/.*)$/i);
    if (!match) return null;
    const current = match[2];
    const alt = this.cdnCandidates.find((h) => h !== current);
    if (!alt) return null;
    return `${match[1]}${alt}${match[3] || ""}${match[4]}`;
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
      // 网页阅读页与 App 页 DOM 同构, 使用同一解析器
      const parseImages = (body) => {
        const doc = new HtmlDocument(body);
        const images = [];
        doc.querySelectorAll(".comic-contain > .chapter-img").forEach(
          (imgNode) => {
            const imgUrl =
              imgNode.querySelector(".comic-contain__item")?.attributes?.[
                "data-src"
              ];
            if (imgUrl) {
              images.push(this._applyImageSettings(imgUrl));
            }
          }
        );
        return images;
      };

      // 1) 优先走网页阅读页: 随主域名自动故障转移, 无需 Cloudflare 验证
      //    https://<lang>.<镜像>/comic/chapter/<comicId>/0_<epId>.html
      try {
        const images = await this.withDomains(async (base) => {
          const res = await Network.get(
            `${base}/comic/chapter/${comicId}/0_${epId}.html`
          );
          if (res.status !== 200) {
            throw `Invalid status code: ${res.status}`;
          }
          const list = parseImages(res.body);
          if (list.length === 0) {
            throw new Error("DomainBlock: empty chapter images");
          }
          return list;
        });
        return { images: images };
      } catch (webError) {
        // 2) 所有镜像网页都失败时, 兜底官方 App 接口(该域已启用 Cloudflare,
        //    需在应用内做一次 Cloudflare verification)
        if (!this._isFallbackError(webError)) {
          throw webError;
        }
        const appUrl = `https://appcn.baozimh.com/baozimhapp/comic/chapter/${comicId}/0_${epId}.html`;
        const res = await Network.get(appUrl);
        if (res.status !== 200) {
          throw `Invalid status code: ${res.status}`;
        }
        return { images: parseImages(res.body) };
      }
    },

    // 章节图片加载配置: 携带站点 Referer 防盗链;
    // 当前图床失败时自动换备用 CDN 重试一次(路径不变)
    onImageLoad: (url, comicId, epId) => {
      const referer = `${this.baseUrl}/`;
      const buildHeaders = () => ({
        Referer: referer,
        "User-Agent": this.constructor.browserUA,
      });
      const config = { headers: buildHeaders() };
      const altUrl = this._altCdnUrlFor(url);
      if (altUrl) {
        config.onLoadFailed = () => ({
          url: altUrl,
          headers: buildHeaders(),
        });
      }
      return config;
    },
  };
}
