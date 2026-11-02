# P11 · 本地库重构开工前的现状核查 + comix.to 全 50 话批量下载

> 日期：2026-10-24
> 阶段：P11（本地库重构 / 本地-网络双模式权限升级）开工前侦查 + 下载链路复测
> 版本基线：`2.8.16+260`

---

## 一、本次任务的两条线

| 线 | 内容 | 状态 |
|----|------|------|
| A | 读开场白 → 核查磁盘图书馆 + 记录表代码 → 出排版决策与阶段顺序 | 已出报告，待拍板 |
| B | 从 comix.to 下载《The Runaway Extra and the Obsessive Duke》全 50 话 | 48 话 Rokari + 第50话 Lux 批量中 |

---

## 二、磁盘图书馆现状（`ComicLibrary/`）

### 2.1 三分结构

| 目录 | 用途 |
|------|------|
| `downloads/` | 下载/成品库（当前 11 本） |
| `projects/` | 翻译工程（BT 工程目录） |
| `translated/` | 翻译产物 |

### 2.2 `downloads/` 下章节文件夹命名**三种风格并存**

| 风格 | 实例 | 推断来源 |
|------|------|----------|
| `<话号> [源站]` | `116 [comix.to]`、`109 [comix.to]` | 早期下载任务，只知道源站 |
| `<话号> [翻译组]` | `1 [Lua Comic]` | 站点给了组名 |
| 纯话号 | `119` | 组名缺失，`parseChapterTitle` 兜底 |

⇒ 结论：没有统一规则，**磁盘上的事实先于规则存在**。任何新命名规则都必须**兼容读取旧目录**。

### 2.3 `local.db.cover` 列已经暴露了"封面不只一张"的诉求

实测取值（同一列里三种语义混用）：

| comic | cover 值 | 语义 |
|-------|----------|------|
| Error the Echo | `cover.jpg` | 书根伴随文件 |
| The Archvillain's Dying Nanny | `116 [comix.to]\0.webp` | **章节目录里的第 0 页** |
| cos写真 | `Hane Ame 雨波 - Asagi (Taimanin)\01.jpg` | **子目录里的图** |

⇒ 用户提出的"封面可以是任意章节里的一张"，在数据层已经发生，只是靠人手写相对路径，**没有语义、没有多张、没有季度标签**。

---

## 三、记录表代码现状（双层存储）

### 3.1 旧层：`data/local.db`（单表 + JSON 列）

```sql
CREATE TABLE comics (
  id TEXT, title TEXT, subtitle TEXT, tags TEXT, directory TEXT,
  chapters TEXT, cover TEXT, comic_type INTEGER, downloadedChapters TEXT,
  created_at INTEGER, description TEXT, source TEXT, update_time TEXT,
  PRIMARY KEY (id, comic_type)
)
```

- `tags` / `chapters` / `downloadedChapters` 全是 **JSON 字符串**，无法建索引、无法局部更新。
- `comic_type` 是**旧架构源类型 int**（`0` = 本地，`496108553` = comix，`233488852` = 包子…），`id` 同列混着自增小整数（`1`/`2`/`4`/`5`）与 `hid//slug`（`9lmnj//error-the-echo`）。
- `source` 列存在但**全部为空串** —— 说明"用户手填来源"这条路只在 UI 层存在，没沉淀。

### 3.2 域层：`mangrove.db` / `domain_database.dart`（schemaVersion = 4，15 张表）

| 分组 | 表 | 角色 |
|------|----|------|
| 源身份 | `source_platforms` / `source_platform_aliases` | 平台规范化 + 别名（legacy int / plugin key） |
| 作品 | `comics` / `works` / `work_sources` | 漫画实体、原作实体、两者关联 |
| 网络源 | `comic_sources` / `chapter_sources` | **网络同步字段的家**（source_url、组名、组内序号…） |
| 本地 | `local_library_items` | **本地字段的家**（directory、import_root、storage_state） |
| 内容 | `chapters` / `pages` | 章节与页 |
| 标签 | `source_tags` / `comic_source_tags` / `tags` | 源标签 vs 本地标签分离 |
| 行为 | `history_events` / `favorites` | 阅读历史、收藏 |

### 3.3 桥接：`ComicStateRepository.mirrorLocalComic()`

```
LocalComic → identityFor(sourceKey, id) → ComicIdentity(comicId, platform, type)
           → _db.ensureComicSource(...)   // 写 comics + comic_sources
           → _db.markLocalLibraryItem(...) // 写 local_library_items
           → _mirrorChapters(...)          // 写 chapters + chapter_sources
```

### 3.4 🔴 结论：**已经是"多张表"，缺的不是分层而是"覆盖层"**

- 网络字段（`comic_sources` / `chapter_sources`）与本地字段（`local_library_items`）**在域库里已经天然分表**，开场白设想的"多张记录表分隔两种模式"不需要从零造。
- **真正缺的是第 16 张表**：本地对网络值的**覆盖**（title/author/description/cover/status/tags 的本地值）。现在本地覆盖只能回写 `comics` 表本身，下一次网络刷新（`refreshComicDetails`）就会把用户改的字**冲掉**——这正是 P10「详细记录表」埋下的隐患。

---

## 四、模式开关现状（与设想的差距）

- 现在的"本地/网络模式"= **全局设置**：`appdata.settings['comicDisplayLocalMode']`（`download_manager_store.dart:431`）。
- 语义只是**章节列表过滤**（隐藏未下载章节），与"信息权限"无关。
- 新需求要的是 **per-comic 模式**（每本漫画自己决定显示网络壳还是本地覆盖）。
  ⇒ 键从 `settings: bool` 变成 `local_library_items.mode`（或等价 per-comic 表），且**必须迁移**旧键（作为新漫画的默认值）。

---

## 五、comix.to 下载链路（复测结论）

### 5.1 站点仍可用

- 直连不通，走 `127.0.0.1:7890` 代理正常（200 / 33KB / 0.9s）。
- 章节清单：**476 条目 / 50 个话号（1~50 无缺号）/ 13 个翻译组**，与几天前一致 ⇒ 采集流程**未失效**。

| 组 | 话数 | 组 | 话数 |
|----|------|----|------|
| EZManga / Nyx Scans / Rokari Comics / Violet Scans | 各 49 | Valir Scans | 48 |
| MagusManga | 46 | Fairy / Siren / Tapas | 各 38 |
| Luna Toons | 33 | Lua Comic | 20 |
| RinkoComics | 17 | Lux Manga | 2 |

🔴 **Rokari Comics 只到第 49 话，第 50 话只有 Lux Manga** ⇒ 要凑齐全 50 话必须跨组。

### 5.2 新发现的坑（本阶段新增）

| # | 现象 | 根因 | 处置 |
|---|------|------|------|
| 1 | `ModuleNotFoundError: requests` | 本机 `python` 指向 WorkBuddy 自带 3.13 裸环境 | 必须用 **`py -3.12`**（装了 requests + websockets），已写进脚本 docstring |
| 2 | 第48话只剩 67/83 页，16 个节点 `is-loading`、`naturalWidth=0`、`src=""` | 站点阅读器并发拉 80+ 张图，经本地代理时 **`net::ERR_HTTP2_PROTOCOL_ERROR`**（一次实测 19 条失败），失败后**不自动重试**，节点停在 `is-errored` | ①文档创建前注入 `SRC_PATCH_JS` 拦 `HTMLImageElement.prototype.src` setter，把地址记到 `el.__srcVal`；②失败节点直接用该地址交 python 侧独立连接重下（ch49 已验证 95/95）；③仍无地址才滚动补救 |
| 3 | 日志看起来"卡死"，实际在下图 | stdout 重定向到文件时**块缓冲**，`tail` 只看到旧内容 | 后台任务一律 `py -3.12 -u` + `PYTHONUNBUFFERED=1` |
| 4 | `--numbers 48` 命中 7 个组的第48话，误建 `48 [EZManga] [comix.to]` | `--numbers` 与 `--group` 是并列过滤，单独用 numbers 不限定组 | 必须 `--group` + `--numbers` 同时给 |
| 5 | 章节目录名想加源站标签 | 磁盘扫描器靠 `chapterDirectoryName()`（`chapter_directory.dart`，唯一真相）反查章节 key，**多一个 `[comix.to]` 就查不到** | 规则需在 `chapterDirectoryName` 同步升级 + 读取侧双格式兼容（待拍板） |

### 5.3 命名决策（本次已按此落盘，可回滚）

```
<话号> [<翻译组>] [<来源站点>]
例：48 [Rokari Comics] [comix.to]
```

- 兼容旧写法：无组名时退化为 `<话号> [comix.to]`（即 `116 [comix.to]` 那类）。
- 落点：`tools/comix_browser_dl.py::chapter_dir_name()`，`--site-tag` 默认 `comix.to`，置空则只留组名。

### 5.4 单章实测数据

| 章节 | 节点 | 落盘 | 失败 | 耗时 | 备注 |
|------|------|------|------|------|------|
| Ch.49 [Rokari] | 95 | 95 | 0 | 219s | 首版脚本 |
| Ch.48 [Rokari] 第一轮 | 83 | 67 | 0 | 259s | 16 节点被当"广告页"丢弃 |
| Ch.48 [Rokari] 补丁后 | 83 | 82+1 | 0 | ~6min | 救回 28 个失败节点；缺 1 页是人为杀进程 |

---

## 六、待用户拍板的排版决策

| # | 决策点 | 选项 | 建议 |
|---|--------|------|------|
| D1 | 章节文件夹是否带源站 | A `[组名]`（不改代码）／B `[组名] [源站]`（改 `chapterDirectoryName` + 双格式读） | **B**，与本次落盘一致 |
| D2 | 模式键粒度 | A 保持全局 `settings` ／B 改 per-comic（`local_library_items.mode`） | **B**，否则"每本独立覆盖"无从谈起 |
| D3 | 封面文件夹命名 | A `[cover]season(1).jpg` ／B `season-1.jpg` ／C 元数据表 + 原样文件名 | **A**（自解释、可被 `[cover]` 前缀统一识别） |
| D4 | 覆盖表形态 | A 单表 KV（`comic_field_overrides`）／B 每类信息一张专表 | **A** 起步（字段会变，KV 免迁移），字段稳定后再拆专表 |

## 七、阶段顺序提案

| 阶段 | 内容 | 依赖 |
|------|------|------|
| P11 | 详情页模式内核：per-comic 模式 + 覆盖表 + 读写合并层（网络值兜底、本地值覆盖） | D2/D4 |
| P12 | 封面文件夹：多封面 + 语义命名 + 选图器 + 旧 `cover.jpg` 兼容 | D3 |
| P13 | 章节目录命名升级 + 磁盘批量迁移（含回滚脚本） | D1 |
| P14 | 建文件夹交互（本地库目录治理 / 新建漫画落盘） | P11 |
| 延后 | 章节缩略图模式（选章内图作封面）、翻译工作室管线（水印去除） | — |

---

## 八、验收口径（写给下一个会话）

1. 模式切换后**重启应用仍保持**，且**另一本漫画不受影响**（per-comic 生效）。
2. 本地覆盖的标题/描述在 `refreshComicDetails` 之后**不被网络值冲掉**（故障注入：手动改标题 → 触发网络刷新 → 断言仍是本地值）。
3. 封面文件夹内 `[cover]season(1)` / `[cover]season(2)` 都能被详情页切换，删掉文件夹后回落到 `cover.jpg`。
4. 章节目录改名后，**旧目录仍能被识别**（双格式读取）；迁移脚本 `--dry-run` 输出与实跑一致。
5. 下载侧：任一章节落盘页数 == DOM 节点数，`_manifest.json` 的 `pending` 必须为空。
