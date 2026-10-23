# Mangrove 同组重复 bug 根因取证工作日志

> 主题：验证并定位用户报告的"下载面板某翻译组章节数虚高 / 同组重复"现象（以 503jz 为例）。
> 时间：2026-10-17。
> 用户原话线索：Lua Comic 显示 40 章（应 ≤37）、35/36/37 重复；"未分组"实为 unknown group，
> 真组名应为 NUVIATOON；分组切换按钮不准确。要求用浏览器自动化验证、结论程序化、不虚报。
> 结论与代码定位已沉淀进 `A07b-comix章节列表采集与分组.md §3~§5`。

## 1. 目标与假设

- **用户主张（需逐一验证）**：
  1. 503jz 下载面板 Lua Comic 显示 ~40 章（错误，最多 37/38）；
  2. Lua Comic 的 35/36/37 重复；
  3. 仅 Lua Comic 有此问题；
  4. 面板"未分组"= 网页 unknown group，但真组名应是 NUVIATOON；
  5. 分组切换按钮不准确。
- **AI 初始假设**：先看是"源站真有重复"还是"Mangrove 本地合并/展示 bug"。

## 2. 工具与方法（AI 分析路线，全面记录）

### 2.1 源站取证（CDP 直连，程序化，不靠截图）
- 复用 `C:\Temp\cdp_lib.js` + `C:\Temp\comix_profile`（绕过 ABE/Chrome 155 锁文件）。
- `comix_probe_iwsmf.js`：确认行结构 `.mchap-row__group`（`a.mchap-row__group[href=/groups/9302]`）、
  计数文案 `Showing 1 to 20 of 371 items`、候选按钮含 "All groups"。
- `comix_groups_iwsmf.js`：转储分组下拉菜单（`.fdrop__pop--menu` / `.fdrop__item`），
  确认 14 个组选项。
- `comix_groups_count.js`：逐组过滤并读 `Showing X to Y of Z items` → 各组真实条目数
  （Lua=38 / MagusManga=37 / Valir=37 / Nyx=37 / Rokari=37 / EZManga=34 / Luna=34 /
  Rinko=34 / Nuviatoon=32 / Violet=25 / UToon=21 / Reset=4 / Unknown=1 / All=371）。
- `comix_verify2.js`：
  - `?group_id=0`（Unknown group）仅 1 行 **Ch.32**，其 `.mchap-row__uploader` = **"Uploaded by NUVIATOON"**
    ⇒ 主张④成立（unknown group 标签误导，真组名在 uploader 字段）；
  - Lua Comic 三页共 **38 章 Ch.1–38，dupes=[]** ⇒ 主张①②③的"源站有重复"被**否定**；
  - mnm90 首页 `of 594 items` ⇒ 主张③"仅 Lua 有此问题"需看本地库，不从源头否定。

### 2.2 本地库取证（DB 交叉验证）
- `data/local.db` / `details_cache.db` 须连同 `-wal` 拷贝后查询。
- 解析 `comics` 表 503jz（`503jz//i-will-save-my-father`）的 `chapters` JSON：
  结构 `{"话号":[{group,lang,title,key,uploadedAt},...]}`。
- 结果（实时数据，2026-10-19 复读）：
  - **38 个话号、375 条 version 记录**；
  - **4 处 intra-(组,话) 重复**：Lua Comic **Ch.35/36/37 各 ×2**、Valir Scans **Ch.34 ×2**；
  - Lua Comic 实计 **41 条**（应 38）、Valir 实计 38（应 37）；
  - 每条重复 = `{key=URL, uploadedAt:0}` 与 `{key:"", 无 lang/无 uploadedAt}` 并存 →
    **两条 chapterKey 不同** → `mergedWith` 按 key 并集时当成两条独立版本全部保留。
- ⚠️ `details_cache.db` 现存 503jz 记录组构成与 local 不一致、且 `title` 字段指向另一部漫画，
  **不作为干净对照基线**（如实标注，不谎称"缓存干净"）。

### 2.3 代码定位（三处链路）
- **采集侧** `comix_client.dart:_fetchChaptersByDom`（L1784）：翻页轮询首行 href（最多 8s），
  站方加密解密慢 → `DOM: page $p not effective after wait, stopping`（L1868）→ **直接 break**，
  只采到部分页；单次 run 内仅按 `href` 去重（L1886-1893），跨 run 的半截采集被 `mergedWith` 累加。
- **合并侧** `models.dart:ComicChapters.mergedWith`（L774）：版本化分支按 **`chapterKey` 并集**，
  **无 (group, chapterNumber) 逻辑去重** → URL-key 版与空 key 版共存。
- **展示侧** `actions.dart:_buildDownloadSections`（L593）：按 `scanlationGroup` 分节，
  `items: allVersions`（每 version 一条）→ 面板计数 = 全部 version 条数，重复条目直接放大显示
  （Lua Comic 41 / 面板约 40）。

## 3. 观察与数据（汇总）

| 维度 | 源站（CDP 实测） | Mangrove local.db（实时） |
|---|---|---|
| Lua Comic 章节数 | 38（无重复） | 41（35/36/37 各 ×2） |
| Valir Scans 章节数 | 37（无重复） | 38（Ch.34 ×2） |
| 总 version 记录 | 371（All groups） | 375 |
| 话号数 | 38 | 38 |

⇒ **源站干净，重复是 Mangrove 本地生成**。主张①（显示虚高）✅、主张②（35/36/37 重复）✅、
主张④（unknown group 标签误导，真组名 NUVIATOON）✅；主张③"仅 Lua 有此问题"——本地库里
Valir 也有 1 处重复，故"仅 Lua"不完全成立，但 Lua 最严重（3 处）。

## 4. 结论

- 🔴 「同组重复 / 章节数虚高」是 **Mangrove 自身 bug**，非源站现象。
- 根因链：**翻页卡顿只采部分页** → `mergedWith` 仅按 chapterKey 并集、把"URL-key 版"与
  "空 key 版"同一话同一组当成两条独立版本 → `_buildDownloadSections` 按 version 计数放大显示。
- 次要：分组切换/"Unknown group"标签不准确，真组名应取 uploader 字段（NUVIATOON）。

## 5. 反向验证（不虚报，呼应 A02）

- 注入对照：若源站真有重复，则 CDP 逐组 `dupes` 应非空——实测 `dupes=[]`，证明源头无重复；
  本地库 `key=""` 与 `key=URL` 并存则证明重复是本地合并产生（断言真的 FAIL/PASS，非空结果判 PASS）。
- 全程结论来自程序化读取（DOM 计数 / DB JSON），截图仅作复核。

## 6. 修复方向（用户明确：暂不写回代码）

1. `mergedWith` 增加「(group, chapterNumber) 逻辑去重」或归一化空 key；
2. `_fetchChaptersByDom` 翻页失败不直接 break，改为重试/续采或标记"采集不完整"；
3. 下载面板优先用 uploader 真组名，弃用 "Unknown group" 兜底标签。

## 7. 遗留 / 未决

- 空 key（无 lang/无 uploadedAt）条目的**确切来源**尚待完全锁定（疑似某次失败/半截采集或旧版
  序列化格式残留）；但"两条 key 共存 → mergedWith 未去重"的现象与根因已确证，不影响修复方向。
