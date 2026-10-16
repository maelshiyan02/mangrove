# A13 · 术语表 / BT 整合度基线 / 早期工装修复档案

> **触发时机**：碰术语表（glossary）/ `GlossaryBridge`；评估"还差 BT 哪些能力"；
> 查反向验证账本、`_rv_drive` 落盘逻辑、`build.log` 为什么是 0 字节时。
> 上级索引：`../MEMORY.md` ｜ 阶段总览：`A08` ｜ 日志：`W00a`/`W00b`

---

## 1. ④ 术语表搬进工作室（S11 第 1/4 块）· 2026-10-08 能力层已交付

| 块 | 状态 | 说明 |
|---|---|---|
| **A 抽 store** | ✅ | `translation_project/glossary_store.dart`（+ `image_translation/glossary_term.dart` + 6 行的 `glossary_store_app.dart`）。旧引擎改为**纯转发**，同一份 implicitData 只有一个 owner |
| **B 接线** | ✅ | `studio_page` 传 `glossary`；`StudioPageRun.glossary` 带回回报术语并逐页 merge |
| **C UI 入口** | ✅ **已交付 2026-10-08** | 编辑器**去引擎化**（`GlossaryBackend` 抽象 + `StoreGlossaryBackend`/`ServiceGlossaryBackend`），工作室 AppBar 加【术语表】按钮，scope = `comicId`；`--headless glossary-ui-check`（**22** 条起） |
| **D 桥接（新增块）** | ✅ | `glossary_bridge.dart`：免 Key 公共端点与本地 NMT 走「译前占位 → 译后还原」 |

- **验证**：`--headless glossary-check` → **PASS (26 checks)**，全部运行时故障注入（M08 模式，一次构建验完）。
  现行全套基线见 `A08`（glossary 26 / glossary-ui 30）。
- 🔴 **测不到的**：术语是否真进了 prompt、哨兵是否真穿过 NMT 分词器 —— 需 GUI 跑。
  `GlossaryBridge` 的 `lost` / `residue` 会在 `logs.txt` 里打 `Glossary Bridge` 警告；
  工作室收尾那行 `Log.info('Studio Pipeline', …)` 新增 `glossaryLearned` 字段。

## 2. 🔴 BT × Mangrove 整合度基线（2026-10-08 实测，`W00b` W50/P10.12）

**整合率 ≈ 62%**（口径：10 维度拆成 **52 个可独立验证的原子能力点**；✅23 / ⚠️14 / ❌15，
算法权重 1、UI/配置权重 0.5）。

🔴 **互补而非单向覆盖**。宿主**超过** BT 的 7 项：气泡聚类+阅读顺序 / 吸附对齐（宿主独有）/
成品发布（多 CBZ·PDF·EPUB）/ 术语表 per-comic 作用域+阻断词+桥接失败可见 /
headless 验证体系（14 子命令，断言数随轮增长，BT 无）/ 抹字复原 / mask 字形级语义。
BT 远超宿主的 6 项：引擎数量 / 上下文记忆 / VLM / 绘制层 / 校对闭环 / 配置面宽度。

**最该补的三项**（按「能力跃迁 ÷ 代价」）：

| # | 项 | 为何是它 |
|---|---|---|
| ①🔴 | **LLM 上下文记忆三层 + VLM OCR** | 唯一能把"逐页孤立翻译"提到"跨页一致 + 竖排阅读顺序正确"的项。落点已全有（`translation_dispatcher` 单门 / `run_dialog` 开关位 / `ocrRegion` 裁剪窗口可当 VLM 编号框底图）；难点是 `LlmTranslator` 要先扩 vision |
| ②🔴 | **校对闭环三件套** | txt/md 导出 → 按页回导（四类报告）→ 全局搜索替换+拼写检查。**纯 Dart、无模型依赖、headless 全测** ⇒ 投产比最高；可复用 `finished_export` 字节比对与 `edit-check` 的测试习惯 |
| ③🟠 | **手绘 mask 画笔 + 形状填充** | S-N3 让 `mask/` 成了真产物但**用户改不了**。BT 能改是因为 mask 本就独立落盘 —— 我们现在也有同样前提。顺手补 `Skip simple cases` + `filter_mask_by_bboxes` 两个小开关（纯 Dart 可测）|

⚠️ **文档腐化教训**：核对时发现 P10.5/P10.6 有 10 处结论已被后续轮次推翻
（含「`page_order`/`chapters` 是 FT 契约」—— 实测 BT 全库 **0 命中**，是我们自加的）。
已全部**就地标注**而非文末追加，并写进 `A02 §12`。

## 3. 2026-10-07 工装修复：反向验证账本 + build.log

### 3.1 反向验证的账本被查清（两个真问题）

- **P1 的 35 条**：34 检出 / **1 未验证**（`pipeline.studio_does_not_use_legacy_engine`）。
- **P2 的 19 条**：9 检出 / **10 未验证**（`snap.*` ×7 · `studio.marquee_*` · 2 条 `pipeline.resume_*`）。
- 合计 **43 检出 + 11 未验证 = 54**，与 `_rv_backup` 的 44 个目录（43 完成 + 1 在飞）**逐条吻合**。
- 🔴 **查出的两个真问题**：
  1. `_rv_drive.py` **只在整轮结束后写盘** ⇒ 43/54 那轮被中断时**整轮结果全丢**，盘上留下的是**上一轮**（工具自身有 bug、整批全丢）的数字。**已修**：逐条落盘 + payload 记 baseline；陈旧那份归档为 `builds/reverse_verification.INVALID-20261007-1641.json`。
  2. `reverseVerified` 清单**过度声称**：11 条从未被故障打红过的断言写在"确认过 FAIL"的清单里 ⇒ `edit-check` 的 `PASS` 是**假的 ✅**。**已修**：拆出 `pendingVerification`；判据改为「两清单**合起来**覆盖 `known` + 互不相交 + `reverseVerified` 非空」，detail 如实报数。
     🔴 **刻意不因 pending 判 FAIL** —— 判 FAIL 会让最省事的修法变成"把名字删掉"，连带丢掉覆盖检查。**失效的清单比不完整的清单危险得多。**

### 3.2 S9.5-a 新代码的反向验证（方案 → 已实施）

> 状态更正：本节 2026-10-07 起草时标注"方案已定（未实施）"；**2026-10-09 已补完**
> （断言落在 `headless_p1_checks.dart` 895/923/943 行，见 `A12 §4`）。方案要点留存：

三处抽口（都是**纯逻辑**，因为 headless 无渲染表面，像素级测不了）：

| 抽口 | 落点 | 锁定断言 |
|---|---|---|
| 两阶段顺序契约（**最有价值**） | `ProjectWriter.inLayeredOrder<A,B>()` | `inpaint.layered_order_bases_first` |
| 「降采样不出底图」判据 | `canProduceInpaintedBase({decodedWidth, originalWidth})` | `inpaint.base_requires_no_downscale` |
| 「底图只从原图取」 | `inpaintedBaseSourcePath(project, pageKey)` | `inpaint.base_source_is_original` |

⚠️ `inLayeredOrder` 的断言要点：两个回调**都不含 await** ⇒ 调用后**同步**就能读到第一阶段（`await` 的是已完成 Future 才让出）。**等 future 完成再读两种顺序都会得到 `bases>results`，断言就永远绿了**。

### 3.3 ✅ `build.log` 恒为 0 字节 —— 已修

- **根因（部分）**：子批处理（`flutter` / `pub` / `cmake`）的输出**一个字都没进日志**，
  且 `>`（截断）写的行也丢了 —— 只有 `>>`（追加）能落盘。
- **修法**：`tools/build_mangrove_with_log.bat` 一律改 `>>`，并由 wrapper **按内层退出码自己补
  `=== BUILD_OK ===` / `=== BUILD_FAIL rc=n ===`**。⇒ `run_build_task.py` 现在真能报 `BUILD_OK`
  （实测 **1 分 06 秒**返回）。详见 **`A01 §1`**。
- ⚠️ **仍未解**：为什么子批处理的输出进不来 ⇒ **flutter 的报错文本依然看不到**，编译错误只能
  靠「`app.so` 没更新」间接发现。
