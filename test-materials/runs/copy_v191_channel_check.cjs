/* P63 Copy 源 v1.9.1 双通道修复验证桩 —— 真实加载 comic_source/copy_manga(5).js，
 * 用内存 store + 可编程 Network 桩驱动 ensureChannel / webSearch 的行为断言。
 *
 * 被测缺陷（P62 现场定位）：
 *   ① ensureChannel 用 homeIndex.results.recComics 判活。该推荐位在 region=0 下
 *      对匿名用户恒为空（topics/topicsList/recComics 三者 total 都是 0），于是
 *      **正常通道被误判成「App 已死」**，markAppDead() 写入 12 小时持久锁。
 *   ② 锁生效后搜索全部降级到网页端，而网页端搜索 JSON 接口对任何关键词都返回
 *      results.list=[]，且 webSearch 不抛错 ⇒ 界面「无错误的空白结果」。
 *
 * 判据（每条都必须能真红，见末尾反向口）：
 *   A. 探针必须打 /api/v3/search/comic（不再是 homeIndex）
 *   B. recComics 为空的 homeIndex 响应不得让通道判死（历史缺陷的直接复现面）
 *   C. 探活成功必须清掉持久化的 _app_dead_until（自愈）
 *   D. 探针 210 ⇒ 必须判死（反向口：证明 B 不是「永远判活」的假绿）
 *   E. webSearch 收到空 list 必须抛错（不许静默返回空数组）
 *   F. webSearch 收到非空 list 必须正常返回（反向口：证明 E 不是「永远抛错」）
 *
 * 用法: node copy_v191_channel_check.cjs [源文件]
 */
const fs = require("fs");

const argv = process.argv.slice(2);
const SRC = argv[0] || "D:/AI Coding Project Management/Mangrove/comic_source/copy_manga(5).js";
const raw = fs.readFileSync(SRC, "utf8");

// ---- 最小框架桩 ----
class ComicSource {
  constructor() {
    this._data = Object.create(null);
    this._settings = Object.create(null);
  }
  loadData(k) {
    return this._data[k];
  }
  saveData(k, v) {
    this._data[k] = v;
  }
  deleteData(k) {
    delete this._data[k];
  }
  loadSetting(k) {
    return this._settings[k];
  }
  saveSetting(k, v) {
    this._settings[k] = v;
  }
}
const Convert = {
  hmacString: () => "stub-sig",
  decodeBase64: (s) => s,
  encodeUtf8: (s) => s,
};
const Network = { get: async () => ({ status: 200, body: "{}" }), post: async () => ({ status: 200, body: "{}" }) };

let CopyManga;
try {
  CopyManga = new Function(
    "ComicSource", "Convert", "Network", "console", "setTimeout",
    raw + "\n;return CopyManga;"
  )(ComicSource, Convert, Network, { log: () => {} }, (fn) => fn());
} catch (e) {
  console.error("加载 copy 源失败:", String((e && e.message) || e));
  process.exit(2);
}

let pass = 0, fail = 0;
const assert = (cond, msg, detail) => {
  if (cond) { pass++; console.log("  OK   " + msg); }
  else { fail++; console.log("  FAIL " + msg + (detail ? "  [" + detail + "]" : "")); }
};

/** 造一个隔离实例：内存 store + 可控 Network + 固定 apiUrl/headers。 */
function makeInstance(opts) {
  const o = opts || {};
  const inst = new CopyManga();
  inst._settings["channel_mode"] = o.channelMode || "auto";
  inst._data["_app_dead_until"] = o.deadUntil;
  // 避免依赖设备指纹生成逻辑，直接固定两个 URL/头
  Object.defineProperty(inst, "apiUrl", { get: () => "https://api.test", configurable: true });
  Object.defineProperty(inst, "headers", { get: () => ({ "x-test": "1" }), configurable: true });
  inst._netCalls = [];
  inst._netHandler = o.handler || (async () => ({ status: 200, body: "{}" }));
  return inst;
}

/** 把实例上的 Network.get 调用改道到 handler（源内部用的是模块级 Network）。 */
function bindNetwork(inst) {
  Network.get = async (url, headers) => {
    inst._netCalls.push(url);
    return await inst._netHandler(url, headers);
  };
}

const HOMEINDEX_EMPTY = JSON.stringify({
  code: 200,
  message: "请求成功",
  results: {
    topics: { list: [], total: 0, limit: 4, offset: 0 },
    topicsList: { list: [], total: 0, limit: 4, offset: 0 },
    recComics: { list: [], total: 0, limit: 4, offset: 0 },
  },
});
const SEARCH_OK = JSON.stringify({
  code: 200,
  message: "请求成功",
  results: { list: [{ name: "斗罗", path_word: "doupo" }], total: 1 },
});

(async () => {
  console.log("\n=== A/B/C: 探针打 search 接口 + recComics 为空不得判死 + 清历史锁 ===");
  {
    const inst = makeInstance({
      deadUntil: String(Date.now() + 12 * 3600 * 1000), // 模拟已被错误锁死 12h
      handler: async (url) => {
        // 故意让 homeIndex 与 search 都可用，但只有 search 会被调用
        if (url.includes("/api/v3/h5/homeIndex")) return { status: 200, body: HOMEINDEX_EMPTY };
        return { status: 200, body: SEARCH_OK };
      },
    });
    bindNetwork(inst);
    await inst.ensureChannel();
    const probedSearch = inst._netCalls.some((u) => u.includes("/api/v3/search/comic"));
    const probedHome = inst._netCalls.some((u) => u.includes("/h5/homeIndex"));
    assert(probedSearch, "A. 探针请求了 /api/v3/search/comic", inst._netCalls.join(" | "));
    assert(!probedHome, "A'. 探针不再请求 homeIndex（推荐位不可作判活依据）", inst._netCalls.join(" | "));
    assert(inst._appDead === false, "B. recComics 空不会把正常通道判死", "appDead=" + inst._appDead);
    assert(
      !inst._data["_app_dead_until"],
      "C. 探活成功清掉了持久化 _app_dead_until（自愈）",
      "still=" + inst._data["_app_dead_until"]
    );
  }

  console.log("\n=== B2: 历史缺陷直接复现面 —— homeIndex 空推荐位 + 旧判据 ===");
  {
    // 用旧逻辑的等价判断，证明「同一份响应」在旧判据下必然判死
    const d = JSON.parse(HOMEINDEX_EMPTY);
    const oldWouldKill = !(
      d.results.recComics && d.results.recComics.list && d.results.recComics.list.length
    );
    assert(
      oldWouldKill === true,
      "B2. 同一份 homeIndex 响应在旧判据下确实判死（缺陷可复现）",
      "oldWouldKill=" + oldWouldKill
    );
  }

  console.log("\n=== D: 反向口 —— 探针 210 必须判死（证明 B 不是永远判活） ===");
  {
    const inst = makeInstance({ handler: async () => ({ status: 210, body: "" }) });
    bindNetwork(inst);
    await inst.ensureChannel();
    assert(inst._appDead === true, "D. 探针 210 ⇒ 判死", "appDead=" + inst._appDead);
    assert(
      !!inst._data["_app_dead_until"],
      "D'. 判死时写了 _app_dead_until",
      "val=" + inst._data["_app_dead_until"]
    );
  }

  console.log("\n=== D2: 反向口 —— 探针非 200 必须判死 ===");
  {
    const inst = makeInstance({ handler: async () => ({ status: 500, body: "" }) });
    bindNetwork(inst);
    await inst.ensureChannel();
    assert(inst._appDead === true, "D2. 探针 500 ⇒ 判死", "appDead=" + inst._appDead);
  }

  console.log("\n=== D3: 探针网络异常不得判死（网络问题 ≠ App 死亡） ===");
  {
    const inst = makeInstance({
      handler: async () => {
        throw new Error("connection terminated during handshake");
      },
    });
    bindNetwork(inst);
    await inst.ensureChannel();
    assert(inst._appDead === false, "D3. 握手异常 ⇒ 不判死", "appDead=" + inst._appDead);
    assert(inst._channelChecked === false, "D3'. 留给下次重探", "checked=" + inst._channelChecked);
  }

  console.log("\n=== E/F: webSearch 空列表必须抛错、非空必须返回 ===");
  {
    // E: 空 list ⇒ 抛错
    const inst = makeInstance({});
    inst.webGet = async () => ({
      status: 200,
      body: JSON.stringify({ code: 200, results: { list: [], total: 0 } }),
    });
    bindNetwork(inst);
    let threw = null;
    try {
      await inst.webSearch("斗罗", [], 1);
    } catch (e) {
      threw = e;
    }
    assert(!!threw, "E. 空 list ⇒ 抛错（不再静默返回空数组）", "threw=" + threw);
    assert(
      threw && /空列表|无结果/.test(String(threw.message || threw)),
      "E'. 错误信息可辨识为「空结果」",
      threw && String(threw.message || threw)
    );

    // F: 非空 list ⇒ 正常返回（反向口）
    const inst2 = makeInstance({});
    inst2.webGet = async () => ({
      status: 200,
      body: JSON.stringify({
        code: 200,
        results: {
          list: [
            {
              path_word: "doupo",
              name: "斗罗",
              author: [{ name: "唐家三少" }],
              cover: "https://x/1.jpg",
              theme: [{ name: "热血" }],
              popular: 120000,
            },
          ],
          total: 1,
        },
      }),
    });
    bindNetwork(inst2);
    let res = null, err = null;
    try {
      res = await inst2.webSearch("斗罗", [], 1);
    } catch (e) {
      err = e;
    }
    assert(!err && res && res.comics.length === 1, "F. 非空 list ⇒ 正常返回 1 条", err ? String(err) : "ok");
    assert(
      !err && res && res.comics[0].id === "doupo" && res.comics[0].title === "斗罗",
      "F'. 字段映射正确（id=path_word / title=name）",
      err ? String(err) : JSON.stringify(res && res.comics[0])
    );
  }

  console.log("\n=== G: viaChannel auto 模式在 _appDead=false 时必须走 App 通道 ===");
  {
    const inst = makeInstance({});
    inst._appDead = false;
    inst._channelChecked = true;
    inst._netHandler = async () => ({ status: 200, body: SEARCH_OK });
    bindNetwork(inst);
    let usedApp = false, usedWeb = false;
    const r = await inst.viaChannel(
      async () => { usedApp = true; return "APP"; },
      async () => { usedWeb = true; return "WEB"; }
    );
    assert(r === "APP" && usedApp && !usedWeb, "G. auto + 通道健康 ⇒ 走 App", "r=" + r);
  }

  console.log("\n=== H: viaChannel ---- _appDead=true 时才降级到 Web ===");
  {
    const inst = makeInstance({});
    inst._appDead = true;
    inst._channelChecked = true;
    bindNetwork(inst);
    let usedWeb = false;
    const r = await inst.viaChannel(
      async () => "APP",
      async () => { usedWeb = true; return "WEB"; }
    );
    assert(r === "WEB" && usedWeb, "H. 只有确认死亡才降级 Web", "r=" + r);
  }

  console.log("\n=== I: 版本与接线仍在（防止修复被回滚时静默失效）===");
  {
    const inst = makeInstance({});
    const src = fs.readFileSync(SRC, "utf8");
    assert(typeof inst.clearAppDead === "function", "I. clearAppDead 已接入", typeof inst.clearAppDead);
    assert(/search\/comic\?limit=1&offset=0&q=a/.test(src), "I'. ensureChannel 探针字面量存在");
    assert(/网页端搜索无结果/.test(src), "I''. webSearch 空结果抛错字面量存在");
  }

  console.log("\n---------------------------------------------");
  console.log("PASS = " + pass + "   FAIL = " + fail);
  console.log(fail === 0 ? "SELFTEST PASS" : "SELFTEST FAIL");
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => {
  console.error("测试异常:", e);
  process.exit(2);
});
