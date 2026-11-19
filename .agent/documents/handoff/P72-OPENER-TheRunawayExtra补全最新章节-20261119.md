# P72 · OPENER · 补全 The Runaway Extra and the Obsessive Duke 到最新章节

> 生成时间：2026-11-19 23:20（承接 P70/P71 收口会话）
> 性质：**内容补全任务**（不改业务代码，除非取证发现新的映射/合并缺陷）
> 目标页：https://comix.to/title/6emnz-the-runaway-extra-and-the-obsessive-duke

---

## 1. 一句话任务

把《The Runaway Extra and the Obsessive Duke》从当前已落盘的 **第 50 话**补到**源站最新章节**，逐话校验落盘完整、图片可解码、本地库登记正确，且刷新章节**不再报新增**。

## 2. 已知基线（开工前先复核，不要凭本文件数字下结论）

| 项 | 现值 | 怎么复核 |
|---|---|---|
| 库内记录 | `comics.id = 2`，`chapters` **50 格**、`downloadedChapters` **50 条**（versioned 单版本） | `select chapters,downloadedChapters from comics where id=2` 后 json 解析 |
| 磁盘目录 | 50 个：`1 [Rokari Comics] [comix.to]` ~ `49 [Rokari Comics] [comix.to]` + `50 [Lux Manga] [comix.to]` | `ls ComicLibrary/downloads/The Runaway Extra and the Obsessive Duke` |
| 组别 | Rokari Comics（1–49）、Lux Manga（50） | 组过滤权威表现场确认 |
| 库健康度 | 无重复格（P71 折叠逻辑已生效） | 自查脚本：格数 == 唯一话号数 |

> 🔴 **第 50 话已换组（Lux Manga）**，说明这本书发生过 scanlation 组切换。Rokari 是否也补到 50+ 必须靠组过滤核验，不能假设「Rokari 停在 49」。

## 3. 硬规矩（违反即返工）

1. **禁止**在会话里直接跑 `flutter` / `dart`。构建走 `python tools/run_build_task.py`，自检走 `python tools/run_headless_task.py`。
2. 本会话**无渲染表面**：像素、解码、渲染、出图只能用户 GUI 会话验证。PIL 解码校验可以在本地 Python venv 做（不算渲染）。
3. 任何「已完成 ✅」必须有**会真红的断证**：空结果判 FAIL，不是「没报错就算过」。
4. 用户明令：**不要靠删历史重导**来绕过合并/映射问题（那会掩盖真因）。
5. 视频/语音/图片证据不落库；临时产物写系统临时目录，交付目录只留可运行文件。

## 4. 下载通道（已验证可用，别换路线）

- **必须浏览器自动化**：`_reference/apps/Scrapling/.venv`（scrapling 0.5.1 + patchright chromium），代理 `127.0.0.1:7890`。Mangrove 内置下载器对 comix.to 不行（WAF TLS 指纹 + SPA 签名 token）。
- **导航铁律（A25/P59）**：一个会话**只导航首页一次**，之后靠 `history.pushState` 切章节；连续 `goto` 会触发 WAF/503。
- **取章节 URL**：详情页组下拉 `.fdrop.mpage__group button`（`aria-haspopup=menu`）→ 点 `[role=menuitemradio]` 选组 → URL 变 `?group_id=N` → 列表只含该组，逐行取 `a[href*=chapter]`，`chapter-N` 即话号。
  - 🔴 **组别真相只认组过滤表**。`Previous chapter` 链是站内顺序跳，**可能换组**，只能当交叉验证，不能当依据。
- **取图**：`MutationObserver` + 遍历点全部 `[aria-label*="Go to page N"]` 收 `src`，判据 **收图数 == 页按钮数**。
- **取字节**：无 Referer / 无 `Sec-Fetch-*` 的朴素直连（**带 comix Referer 反而 403**），8 并发、3 次重试。

## 5. 每话核验四件套（缺一不可）

1. 收图数 == 页按钮数；
2. 页号 `0..n-1` 无空洞（编号连续、无重名覆盖）；
3. PIL 真实 `load()` 全通过（0 失败），分辨率风格与同组已有章节一致；
4. 落盘后首/中/末抽样再解一次。

## 6. 落盘与库登记

- 目录命名唯一真相：`chapterDirectoryName` = `sanitizePathSegment('$number$site')` → 本次形如 `51 [Lux Manga] [comix.to]`。**组名必须取自组过滤表**，不要猜。
- 库写入前**先备份** `data/local.db{,-wal,-shm}` → `data/local.db.bak.p72-YYYYMMDD-HHMMSS{,-wal,-shm}`。
- 登记走「等价键」口径（P70 修复）：`chapterKeysForDirectoryName()` 会把 `N [组] [comix.to]`、`第N话 · 组`、UUID key 视为同一话，`downloadedChapters` 只需保留规范 key（目录同形的编号 key）。
- 写库后必须验证：**格数 == 唯一话号数**、`downloaded` 条数 == 磁盘目录数、无孤儿 key（不在矩阵内的下载 key 数 = 0）。

## 7. P70/P71 已踩过的坑（本轮别重犯）

| # | 坑 | 规避 |
|---|---|---|
| 1 | **UUID 被当成话号**：`^(\d+)` 宽匹配会把 `0fbab379-…` 读成第 0 话，曾把 69 话错配成 47 个 UUID | 任何话号归一前先挡 UUID（`chapterNumberKeyOf` 已内置，别绕过它） |
| 2 | **只修增量不修存量**：P70 让「以后不再翻倍」，但库里已有的 138 格照旧渲染，网格逐格查下载状态 ⇒ 双倍查询 + 双倍布局 = 卡顿 | 改归一/合并逻辑时必须同时检查存量是否需自愈（`_migrateDuplicateChapterKeys` 是模板） |
| 3 | **Dart `List == const [...]` 是引用比较**，恒假：让基线 96/97，且会让后续注入「看起来只红目标」 | 列表比较逐项或 `listEquals`；恒假断言与恒真断言同罪 |
| 4 | **`Iterable` 没有 `containsAll`**，编译期 `undefined_method` | 先 `.toSet()` |
| 5 | **构建产物时间戳滞后**：`builds/mangrove/mangrove.exe` mtime 早于源码 ⇒ headless 跑旧 exe，跑出 93 条**假基线** | 自检前先比 exe 与源码 mtime/sha256 |
| 6 | **故障注入锚点不唯一**：`return keys.toList();` 在文件里出现两次，`replace_nth(...,2)` 直接 `INJECT_MISS` | 锚点必须带上下文（用 `diskGroup` 等上下文拼唯一串） |
| 7 | **`headless.dart` 是 CRLF**：`git diff --check` 把它全判成 trailing whitespace | 用 `git -c core.whitespace=cr-at-eol diff --check` |
| 8 | **`INJECT_MISS` 会写进台账为 FAIL** | 单组重跑会按 case 合并回台账，别手动改台账洗绿 |
| 9 | **headless 不写 `data/logs.txt`**（启动即截断），日志行只在 GUI 会话可见 | 别拿 headless 输出里「没有日志」当「没有问题」 |
| 10 | **多组同话并存**（`默認/默认/default`、不同组）：组名未归一时会被当两话 | 折等口径 = 话号 + **归一翻译组** + 语种；跨组同话号要保留（`dedupe_keeps_distinct_scanlation_groups` 守着这条） |

## 8. 验收清单

- [ ] 组过滤权威表证明「源站最新话号」与「各组覆盖区间」，记录到日志；
- [ ] 每话四件套全过，逐话张数列表落台账；
- [ ] 磁盘目录话号连续、命名与 `chapterDirectoryName` 一致；
- [ ] 库：格数 == 唯一话号数、downloaded == 目录数、孤儿 0；
- [ ] 刷新章节返回「没有新增」（新话已入库后应无新增）；
- [ ] 用户 GUI 复核：新话显示蓝标、可打开、不卡顿。

## 9. 交付与收尾

- 版本号规则见 `A15`：改代码才递增（`3.1.9+285` → 若本轮只补数据，**不升**）。
- 日志写到 `.agent/documents/worklog/14-漫画源A方案升级P60-20261115/P72-WORKLOG-…-20261120.md`，同步 `.agent/documents/INDEX.md`、`W00-工作日志索引.md`、`.agent/memory/YYYY-MM-DD.md`。
- 台账 `test-materials/runs/p72_*.json`。
- 收尾写 HANDOFF 断点快照（本文件即为模板）。
