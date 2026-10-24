# A17 · comix.to 批量下载：图片"假缺页"与命名规则

> 上级索引：`.agent/memory/MEMORY.md` §1
> 触发时机：跑 `tools/comix_browser_dl.py` 下载任意章节、或发现"某话少了几页"时
> 相关：**A07**（comix 源）、**A07b**（章节列表采集）、**A07c**（反爬）、**A06**（下载语义）
> **批量/整章重下、判"卡住还是被封"、验收完整性 ⇒ 先读 A20**（移动替代删除 / 无记录≠完整 /
> force 不清理 / 扩展名按 magic / `ls -t` 不能当进度 / 验收五项 / 提速阶梯）
> 建立：2026-10-24（P11 开工前复测）

---

## 1. 解释器必须先对齐（最常踩）

| 命令 | 结果 |
|------|------|
| `python tools/comix_browser_dl.py …` | ❌ `ModuleNotFoundError: No module named 'requests'`（本机 `python` = WorkBuddy 自带 3.13 裸环境） |
| `py -3.12 tools/comix_browser_dl.py …` | ✅（3.12 装了 requests 2.34 + websockets 17.2） |

后台跑一律加 `-u` 或 `PYTHONUNBUFFERED=1`：
**stdout 重定向到文件时是块缓冲**，`tail` 看到的可能是几分钟前的旧内容 ——
2026-10-24 因此误判"卡死"，把正在下载的进程杀了，白丢 1 页。

---

## 2. 🔴 "页码缺失"99% 不是缺页，是浏览器加载失败

### 现象

某话 DOM 有 83 个 `.rpage-page`，却只落盘 67 页；节点 class 是
`rpage-page is-loading` 或 `rpage-page is-errored`，`img.naturalWidth=0`，
`img.getAttribute('src')` 为空。

### 根因（2026-10-24 实测证据）

- 站点阅读器在**视口懒加载**下会同时发 80+ 张图，经 `127.0.0.1:7890` 代理时
  Chrome 报 **`net::ERR_HTTP2_PROTOCOL_ERROR`**（一次实测 19 条失败 / 83 页）。
- 失败后站点**不重试**，节点永久停在 `is-errored`，`src` 属性被清空。
- ⇒ 这类节点**不是广告页**（广告页判据是 `naturalWidth <= 10` / canvas `toDataURL` < 20000 字符）。
  把它们当"空/广告节点"丢弃 = 静默丢页。

### 处置（已落地在脚本里，`SRC_PATCH_JS`）

1. `Page.addScriptToEvaluateOnNewDocument` **在页面脚本之前**注入补丁，拦
   `HTMLImageElement.prototype.src` 的 setter，把地址记到 `el.__srcVal`
   ⇒ 加载失败也能回收该页真实 URL。
2. python 侧对这类节点**直接用该 URL 自己下载**（独立连接、3 次重试、换域名回落），
   实测 ch49 95/95、ch48 救回 28 个失败节点。
3. 仍无地址的才滚动补救（最多 2 轮 × 25s），最后计入 `_manifest.json.pending`。
4. **验收口径**：`saved == nodes` 且 `pending == []`。有 pending 的章节用
   `--numbers <n> --force` 单独重跑（**必须带 `--group`**，否则命中该话所有组的版本）。

---

## 3. 图片 CDN 的多域名轮换（沿用 A07 结论）

- DOM 给的域名有相当一部分（`*.site`）对通用 HTTP 客户端 **403**（~4.5KB 响应体）。
- **路径与域名无关**：同一段 path 挂到该章主域名（如 `c127.kkplayer.wtf`）能拿到**字节一致**的图。
- 脚本已实现"先打本章出现次数最多的域名，再回落原域名"。

---

## 4. 章节目录命名（与 App 的唯一真相耦合）

```
磁盘规则：<话号> [<翻译组>] [<来源站点>]        例 48 [Rokari Comics] [comix.to]
无组名时：<话号> [<来源站点>]                  例 116 [comix.to]
```

🔴 **App 侧的唯一真相是 `lib/foundation/chapter_directory.dart::chapterDirectoryName()`**，
它目前只产出 `<话号> [组名]`。磁盘多一个 `[comix.to]` ⇒ 本地扫描器
（`LocalManager.reconcileDownloadedChapters` 用 `keyByDir[name]` 反查）**认不出来**。
⇒ 一旦确定采用带源站的命名，必须同步改这一个函数，并让读取侧**双格式兼容**
（新名优先，查不到再回落旧名）。改之前不要单方面改磁盘。

同一本漫画跨组补话是常态：本书 Rokari 到 49 话，**第 50 话只有 Lux Manga**。

---

## 5. 反爬节奏（沿用 A07c，未变更）

- 一次会话**一次**文档导航；站内跳转用 `pushState`；命中 `Third-party apps` / `Just a moment` 立即停手。
- 阅读页必须每章一次导航（无法避免），**失败不重试、不重载**。
- 2026-10-24 复测：连续 50 章级别（每章间隔 3~4 分钟）未触发拦截，476 条目清单与几天前一致。
