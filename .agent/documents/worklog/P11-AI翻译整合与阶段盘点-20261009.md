# P11 · 阶段盘点报告（对照 VeneraX v2.3.5 · 聚焦 AI 翻译整合）

> 2026-10-09 · 触发：用户六问之「第二」
> 方法：扫描 `.agent/memory` 工作日志 + 附录（A08 排期 / A01 环境 / A02 硬规矩）
>        + 上游对照日志（P10.12 / P10.13）→ 逐条回代码核实 → 实跑全量 headless 取证
> 口径：宿主 = `Mangrove/lib/`；上游 = `Maelshiyan02/Mangrove` v2.3.5（fork 自 VeneraX）

---

## 〇、一句话结论

1. **AI 翻译「整体搬迁到翻译工作室」已完成**（本轮 P1a + 上一轮 P1b）。原本躺在
   `reader.dart`「AI 翻译（实验性）」分组里的**全部设置项**（引擎 / LLM 服务商 / 提示词 /
   测试翻译 / 源语言 / 目标语言 / 性能模式 / 高级滑块 / 翻译模型 / 清空结果）现已整体迁入
   工作室的「翻译设置」页；普通阅读设置里**只留「翻译这一章」开关**（per-chapter 入队开关）。
2. 这一动作本属于计划阶段 `S9.5-b「旧流程退出 + 阅读器合流」` 的主体，**P10.13（2026-10-08）
   曾记它"未开工"——本报告把它更新为"设置合流已完成，旧链路退出待 GUI 验收"**。
3. 上游 v2.3.5 可吸取项 **7/10 已落地**（剩 取消加载 / PDF 导入 / 任务页搜索 三项）。
4. BT × Mangrove 整合率 ≈ **62%**（52 个原子点：✅23 / ⚠️14 / ❌15）。

---

## 一、AI 翻译整合专题（本次重点核查）

### 1.1 本轮交付（2026-10-09，P1a）

| 子项 | 落点（改后） | 状态 |
|---|---|---|
| 翻译引擎 | `ReaderSettings._aiTranslationChildren` → 工作室「翻译设置」页 | ✅ 已迁入 |
| LLM 服务商 / 提示词 / 测试翻译 / 源·目标语言 / 性能模式 / 高级滑块 / 模型 / 清空结果 | 同上（同方法内 children 列表，原样复用） | ✅ 已迁入 |
| 普通阅读设置里只留「翻译这一章」开关 | `ReaderSettings._buildTranslateThisChapterTile()`（独立 sliver） | ✅ 已收减 |
| 工作室入口 | `studio_page.dart` AppBar 新增【翻译设置】`IconButton`（→ `StudioTranslationSettingsPage`） | ✅ 已接 |
| `onlyTranslation` 模式 | `ReaderSettings(onlyTranslation:true)` 早退到 `_buildTranslationOnly`（`SliverAppbar` 标题「Translation settings」） | ✅ 已实现 |

- **验证**：`run_build_task.py` → `BUILD_OK`（pubget/analyze/build/install 全 0）；
  `run_headless_task.py edit-check <MDGH-ch1.json>` → **PASS (192 checks)**（未回退）。
- i18n：新键 `"Translation settings"→"翻译设置"/"翻譯設定"` 已在 `translation.json` 注册（CRLF 未破）。

### 1.2 上一轮交付（P1b）· 详情页⋮菜单

- `comic_details_page/actions.dart` 的「开启/关闭 AI 翻译」已**改名为「翻译这一章」**并
  **绑定到绑定表**（`studioReaderBindings[cid@src@eid]`），与阅读设置、阅读器侧栏那枚开关
  **同源**（都走 `_comicTranslationBound()` / `_toggleComicTranslation()`）。
- 详情页无"当前章"概念，取**第一本已下载章节**作代表章（同 `reader.dart` 的
  `_isChapterTranslated()` / `_toggleChapterTranslation()` 镜像实现）。

### 1.3 仍属「进行中 / 待做」的 AI 翻译相关项

| 项 | 归属 | 状态 | 说明 |
|---|---|---|---|
| 旧链路"阅读时逐页即时翻译"退出 | `S9.5-b S3` | 🟠 进行中 | 阅读端「翻译这一章」开关语义已切换为"该章入队工作室"（`S9.5-b S4` 已交付），但**旧即时翻译代码路径尚未删除**（先迁后删，A08 §3 硬依赖）。 |
| 阅读侧产物解析纯逻辑层 | `S9.5-b S2` | ⏳ 待做 | 阅读器读 `result/`·`inpainted` 的纯逻辑抽口未落地。 |
| S9.5-a 端到端人工验收 | `S9.5-a` | 🔴 卡 GUI | 本会话无渲染表面，整章跑只能在用户 GUI 会话做（`P9.8 §八` 13 步）。 |
| S9.5-a 新代码反向验证抽口 | `S9.5-b S1` | ⏳ 待做 | 三处纯逻辑抽口（两阶段顺序契约 / 降采样判据 / 底图只取原图）方案已定未实施（A08 §6.2）。 |

> 🔴 **关键纠正**：P10.13（2026-10-08）把"旧 AI 翻译退出"整体记为"未开工"，是因为当时
> 设置合流尚未做。**现在设置合流已完成（P1a/P1b）**，故 S9.5-b 的实际进度应从"0"修正为
> "设置与开关语义已合流，旧代码路径清理待 GUI 验收后收尾"。

---

## 二、整体阶段进度（A08 §1）

```
S5 ✅ → S6 ✅ → S7 只读画布 ✅ → S7U ✅ → S8 ✅(P8.1)
     → S9 检测/OCR/翻译管线 ✅（第 0/1/2 批全完成；edit-check 122→192）
     → ★ S9.5-a 端到端验证（施工完成，验收待 GUI）
     → S9.5-b 旧流程退出 + 阅读器合流   ← 本轮回合推进到「设置合流」
     → S10 跨页缝合 ／ S11 术语+记忆+导出回流（可互换）
     → S12 下载增强 → S13 versioned
```

- **术语表搬进工作室（S11 第 1/4 块）**：A/B/C/D 四块 ✅（2026-10-08 交付，含
  `glossary-ui-check` 22 条、`glossary-check` 26 条）。
- **验证套件总量（改名后首次全量实跑，2026-10-08）**：259 条断言全绿
  （edit 125→192 / bootstrap 22 / glossary 26 / run-plan 15 / block-ops 36 /
  glossary-ui 22 / cache 6 / script 7）。

---

## 三、对照上游 VeneraX v2.3.5

### 3.1 可吸取项完成进度（来源 P10.13 §一，逐条回代码核实）

| # | 项 | 状态 | 证据 |
|---|---|---|---|
| ① | 自定义翻译脚本（QuickJS 沙箱） | ✅ | `script_translator.dart` + `LlmProviderKind.script` + `script-check` 7/7 |
| ② | 大文件导出修复（epub 流式 + 空字节守卫） | ✅ | `utils/epub.dart` 注释直书「P10.10 ②, upstream v2.3.5」 |
| ③ | 缓存冻结路径 + 启动扫描先于写入 | ✅ | `cache_manager.dart` `_cachePath` / `writeCache` 首行 `await ready` |
| ④ | 缓存启动索引 | ✅ | `CREATE TABLE cache` + `CREATE INDEX` + `_scanDir()` |
| ⑤ | 取消加载要真取消 | ❌ | 全库搜 `activeCoverRead/coverReads/trackActive` = 0 命中 |
| ⑥ | PDF 导入为本地漫画 | ❌ | `pubspec.yaml` 无 `pdfrx`/`pdfium`；导入白名单不含 pdf |
| ⑦ | 自选缓存目录 | ✅ | `setCustomDirectory` + `_prepareDirectory` |
| ⑧ | 设置作用域/继承（global/device/per-comic） | ✅ | `appdata.settings.getReaderSetting/...` |
| ⑨ | 任务页搜索/筛选 | ❌ | `tasks_page.dart` 仅 Current/History 两 Tab |
| ⑩ | WebDAV 同步白名单 | ✅ | `sync_skip.dart` `SyncSkipCategory` × N |

**小结：7/10 已落地；未做 = ⑤⑥⑨**。其中 ⑥ 需新原生依赖（pdfium），⑤⑨ 是小工装，均未进当前
`S9.5` 排期。

### 3.2 BT × Mangrove 整合度基线（P10.12 / A08 §1.1.5）

- **整合率 ≈ 62%**（52 原子点：✅23 / ⚠️14 / ❌15）。
- **宿主超过 BT 的 7 项**：气泡聚类+阅读顺序 / 吸附对齐 / 成品发布（多 CBZ·PDF·EPUB）/
  术语表 per-comic+阻断词+桥接失败可见 / headless 验证体系（14 子命令 **259** 条，BT 无）/
  抹字复原 / mask 字形级语义。
- **BT 远超宿主的 6 项**：引擎数量 / 上下文记忆 / VLM / 绘制层 / 校对闭环 / 配置面宽度。
- **最该补三项**（能力跃迁 ÷ 代价）：
  1. 🔴 LLM 上下文记忆三层 + VLM OCR（跨页一致 + 竖排阅读顺序）；
  2. 🔴 校对闭环三件套（txt/md 导出 → 按页回导 → 全局搜索替换+拼写检查，纯 Dart 可测）；
  3. 🟠 手绘 mask 画笔 + 形状填充（顺手补 `Skip simple cases` + `filter_mask_by_bboxes`）。

---

## 四、已实现 / 进行中 / 待做（汇总）

### ✅ 已实现（本轮及近期）
- AI 翻译设置整体迁入工作室 + 详情页「翻译这一章」改名绑绑定表（P1a / P1b）。
- 打开翻译工程默认单页+缩放（P4）；工程封面独立 `cover.<ext>`（P5）；本地库右上角分类彩色标签（P6）。
- 术语表进工作室（S11 第 1/4 块）；S-N1/N2/N3（识别/翻译按钮、运行确认弹窗、mask 生产+抹字复原）。
- 上游可吸取项 7/10；headless 验证体系 259 条全绿。

### 🟠 进行中
- S9.5-a 端到端人工验收（卡 GUI 无渲染表面）。
- S9.5-b 旧链路退出（设置合流已完成，旧代码路径清理待验收后收尾）。
- 11 条反向验证占位（用户已决定延后，账本已透明化）。

### ❌ 待做（按优先级）
1. S9.5-a 新代码反向验证抽口（3 处纯逻辑）。
2. S9.5-b S2/S3：阅读侧产物解析纯逻辑层 + 旧即时链路删除（先迁后删）。
3. 上游未做三项：⑤ 取消加载真取消 / ⑥ PDF 导入 / ⑨ 任务页搜索。
4. BT 整合最该补三项：① 上下文记忆+VLM ② 校对闭环 ③ 手绘 mask。
5. 改名遗留：补 `baseline/post-rename` git tag（基线不可由 git 追溯）。

---

## 五、给用户的下一步建议（性价比排序）
1. **（小）补 git 基线 tag**：`git tag -a baseline/post-rename-20261009` —— 现已无 tag，归因只能靠文档。
2. **（小）新建 FT 工程 GUI 按钮**：`BtProjectManager.createFromDownload` 能力层已就绪、`bootstrap-check` 已验，只差 UI 接线（本地库菜单 → "新建翻译工程"）。
3. **（中）S9.5-b 旧链路退出**：设置合流已完成，下一步清旧即时翻译代码路径（务必先迁后删）。
4. **（小）自定义脚本入口可发现性**：在服务商页顶部加"自定义脚本"直达（现藏在服务类型第 3 项）。
5. **（中～大）PDF 导入**：需引 `pdfium` 原生依赖，否则图片↔PDF 永远单向。
