# 新对话开场白 · Mangrove P56 阅读器翻页与桌面布局（对齐 comix.to）

> **用法**：新开会话时把本文件整段粘贴作为第一条消息。目标是在**不读历史对话**的前提下，
> 让接手的 agent 直接进入可施工状态。
> **任务来源**：用户 2026-11-14 口述（原文见附录 A，施工前请逐条核对语义）。
> 本轮编号：**P56**（P55 为进度审计；P47 为上一轮阅读器优化，文档可直接复用）。

---

## 一、项目身份与开工前置

Mangrove 是 Windows/Flutter 的漫画 AI 汉化阅读器（VeneraX fork + BallonTranslator 合并）。

- 仓库根：`D:\AI Coding Project Management\Mangrove\`
- Flutter 工程：`Mangrove\Mangrove\`
- 文档唯一真相：`Mangrove\.agent\documents\`（`docs/`、`.trae/` 是指向它的 junction）
- 当前版本：**`3.1.0+275`**（`Mangrove/Mangrove/pubspec.yaml` 为唯一权威）
- 当前 HEAD：`8906e4d`（2026-11-14「翻译模块归并」，已 push）

开工前**必读**（按序，别跳过）：

1. `A08-排期与阶段现状.md` —— 现在在哪、哪些标 🟡、验收口径两列制。
2. `documents/analysis/P55-ANALYSIS-项目进度与文档一致性审计-20261114.md` —— 进度与偏差的唯一口径。
3. `documents/plans/P47-PLAN-阅读器优化实施-20261014.md` + `documents/analysis/P47.0-ANALYSIS-comix-to与Mangrove阅读器对比-20261014.md`
   —— 上一轮阅读器优化的设计与 comix.to 对照结论，**本轮是它的延续**。
4. `documents/plans/P47-ASSETS-comix阅读器参考截图/` —— 15 张 comix 参考截图，先看图再改代码。
5. `A01`（构建工装）、`A02`（反向验证）。

---

## 二、本轮任务（用户口径 → 可执行条目）

### T1 空格页面向下翻（核心）

- 空格 = 向**下**翻一屏的**约半页**（用户原话「幅度大概是半页左右就可以了」）。
- 滑动效果（时长/曲线/是否惯性）参考 **comix.to 阅读器**与**包子漫画阅读器**；
  用户明确要求先打开网站实测，不要凭空定参数。
- 范围：**连续/条漫模式优先**；gallery（左右翻页）模式下的空格语义要单独定义并写进帮助。
- 现状：空格**没有任何绑定**（见第三节），所以「取消图片选中 / 唤出上下栏」是 Flutter
  焦点激活的副产物，不是设计。接手第一件事是把空格显式接管，别再依赖默认行为。

### T2 桌面端 / 移动端两套布局

- 用户要的是**模式设置**（桌面端 UI 布局 / 移动端布局），不是 `App.isDesktop` 平台硬判断。
- 本轮**只做桌面端**；移动端只出计划（Mangrove 还没有移动版）。
- 两套布局应共用同一份数据与状态，只在「控件位置/尺寸/手势/快捷键」上分叉；
  不要复制出第二套 reader。

### T3 桌面快捷键

- `↑ / ↓`：上下翻页（连续模式下即滚动半页/一页，与 T1 同一套步进）。
- `← / →`：**前后章节跳转**（注意：现在是「上一页/下一页」，语义要改）。
- `空格`：按 T1。
- 帮助对话框与实现必须逐条对齐（现在帮助里写着 Space / A D W S / Shift+←→，代码里全都没有）。

### T4 章节切换交互重构

- **去掉**「滚到顶/底再拉动就跳章」：连续模式过拉即跳、gallery 翻过首尾页即跳、
  自动滚动到底即跳，这三处都要改成**不自动跳**。
- **去掉**右下角弹出的 58×58 浮动箭头按钮。
- **改为** comix.to 式：滚动到章末时在内容下方弹出**两个按钮**（上一章 / 下一章），
  点击才跳转；位置、尺寸、出现时机按 comix.to 实测。
- gallery 模式已有的章末双卡（`ChapterEndNavCards`）与这条要求要统一成一套视觉。

### T5 桌面控件重排（对齐 comix.to 阅读器）

- 章节树/章节列表：从左抽屉**移到右上角**浮层（comix.to 的章节下拉）。
- 页面树（页轨）：**保留在左下/左缘**。
- 章节指示（`‹ Ch.12 / 48 ›`）左右保留**前后章节按钮**（现有 `ChapterCapsule` 已是这个形态，
  但默认关闭且位于顶栏中部，需要并入右上角那一组）。
- 右下角时钟+电池：**整体左移**让出右侧空间。
- 让出的位置放：**缩放百分比 + 缩小/放大按钮**（现有 `ReaderZoomBar` 已有
  `% / − / + / 适应`，但默认关闭、hover 才出现、位置在 `right:16 bottom:100`）。

---

## 三、现状代码地图（2026-11-14 实测，行号可直接跳）

| 关注点 | 落点 | 现状 |
|---|---|---|
| 键盘总入口 | [reader.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/reader.dart#L486-L527) | `KeyboardListener(autofocus: true)`；只处理 F12 全屏与帮助键，其余转发给当前控制器 |
| gallery 按键 | [images.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/images.dart#L744-L797) | 按 `ReaderMode` 映射方向键翻页；长按重复 200ms（开动画）/50ms |
| 连续模式按键 | [images.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/images.dart#L2506-L2553) | 方向键 → `animateTo(offset ± height*0.25, 200ms, Curves.ease)`，**这就是空格要复用的步进** |
| 帮助对话框 | [help_dialog.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/help_dialog.dart#L36-L64) | 写着 Space / A D W S / Shift+←→，**代码里零实现**（虚标） |
| 全库空格绑定 | — | `LogicalKeyboardKey.space` 在 `lib/` 下**无任何命中** |
| gallery 章边界 | [images.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/images.dart#L533-L542) | 翻到哨兵页 i==0 / i==total+1 就**立刻**跳上一章/下一章 |
| 连续模式过拉跳章 | [images.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/images.dart#L1890-L1898) | `onPointerUp` 里 `jumpToPrevChapter/NextChapter` 为真即跳，并收起浮动按钮 |
| 自动滚动到底跳章 | [images.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/images.dart#L1046-L1061) | `scrollBy` 到 `maxScrollExtent` 直接 `toNextChapter()` |
| 角落浮动按钮 | [scaffold.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/scaffold.dart#L391-L405)、[scaffold.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/scaffold.dart#L1328-L1380) | `right:16 bottom:36`，58×58，由 `showFloatingButtonValue` ±1 驱动 —— **本轮要删** |
| gallery 章末双卡 | [chapter_end_nav.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/chapter_end_nav.dart) | 44 高、320~360 宽，两张竖排；`readerShowChapterEndNav` 默认开；**仅 gallery** |
| 顶栏章节胶囊 | [chapter_capsule.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/chapter_capsule.dart) | `‹ Ch.n / N ›` 连体按钮，点中间开章节抽屉；`readerChapterCapsule` 默认关 |
| 章节抽屉 | [scaffold.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/scaffold.dart#L1093-L1100) | `_openSideBar(..., width: 400)`，从侧边推入 —— 要改成右上浮层 |
| 左缘页轨 | [scaffold.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/scaffold.dart#L450-L456)、[page_rail.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/page_rail.dart#L3-L16) | 宽 24，仿 comix `.rpage-progress--left`；仅 `readerProgressBarPosition == 'left'` 时出现（默认 `bottom`） |
| 页码 | [scaffold.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/scaffold.dart#L1040-L1060) | `bottom:13 left:25` |
| 时钟+电池 | [scaffold.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/scaffold.dart#L1075-L1090) | `bottom:13 right:25`；开关 `enableClockAndBatteryInfoInReader` |
| 缩放簇 | [scaffold.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/scaffold.dart#L406-L413)、[zoom_bar.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/zoom_bar.dart) | `right:16 bottom:100`，hover 2s 显示，`readerShowZoomBar` 默认关；gallery 显示 `1.5x`，continuous 显示 `150%` |
| 右缘竖工具栏 | [side_toolbar.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/side_toolbar.dart) | `readerSideToolbar` 默认关；用户说「上下栏的功能大部分已被右侧工具栏取代」 |
| 阅读模式 | [reader.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/reader/reader.dart#L1162-L1186) | 6 值：gallery/continuous × LTR/RTL/TTB；`isGallery` / `isContinuous` |
| 阅读器设置默认值 | [appdata.dart](file:///d:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/foundation/appdata.dart#L578-L604) | `readerShowZoomBar` / `readerShowChapterEndNav` / `readerProgressBarPosition` / `readerChapterCapsule` / `readerSideToolbar` / `readerChromeHideTrigger` 等 |
| 设置界面 | `lib/pages/settings/reader.dart` | 上述 key 的开关都在这里；新增 key 必须同时进 `utils/sync_skip.dart` 白名单 |

🔴 **不要动**：`lib/foundation/translation/**`。旧翻译链路 2026-11-14 刚整体拆除，
阅读器侧已无任何翻译入口；本轮改阅读器 UI 不要顺手碰它。

---

## 四、施工前必做：参考站点实测（用户明确要求）

1. 打开 comix.to 的阅读器（先用内置浏览器或 Chrome 扩展，按 `TRAE-browseruse` 走），
   **逐项记录**，写成 `P56-ANALYSIS-…` 或直接记进工作日志：
   - 空格一次滚动的**像素数**与**视口比例**（预估 ≈ 0.5 屏，需实测）；
   - 滚动**时长与缓动**（linear / ease-out；是否有惯性/平滑滚动）；
   - 连续滚到章末时，两个按钮的**位置/尺寸/间距/出现阈值**（距底多少 px 出现）；
   - 章节下拉在右上角的**锚点、宽度、遮罩行为**；
   - 左下页轨的**宽度、当前页高亮、hover 展开**；
   - 右下角控件组的**顺序与间距**（百分比、±、时钟）。
2. 同一批指标在**包子漫画**阅读器上再测一遍，用于交叉验证（用户点名这两个站）。
3. 截图存 `documents/plans/P56-ASSETS-阅读器参考截图/`，命名带站点与控件名，
   供后续像素对照与人工验收。

---

## 五、设计要点与边界

1. **步进与快捷键先抽纯函数/纯表**
   - 例：`double readerTurnFraction(...)`、`List<ReaderShortcut> desktopShortcuts(...)`、
     `bool shouldShowChapterEndOverlay(...)`。
   - 理由：agent 无渲染表面，「空格滚了多少」只能靠 headless 注入故障打红，
     不能靠"看起来对"。参照 P9/P10 的探针写法（绿路径 + 故障注入红路径），
     在 `headless_p*_checks.dart` 里加一组 `reader.*` 断言。
2. **不自动跳章**是硬约束：删掉三处隐式跳转（gallery 哨兵页、连续过拉、自动滚动到底），
   统一改由「章末浮层两个按钮」显式触发。要防止「删了跳转但也没了出口」——
   浮层必须在最后一张图下方**始终可达**（包括图片未加载完、只有一页、章节为空）。
3. **双布局是设置项**：建议新增 `readerLayoutMode`（`desktop` / `mobile` / `auto`，
   默认 `auto` 按窗口宽度或平台推断），所有桌面专属控件（页轨、缩放簇、快捷键提示、
   右上章节浮层）都读这个开关，而不是各自散读 `App.isDesktop`。
   - 本轮只把 `desktop` 做完整；`mobile` 保留现有行为（移动端计划另文）。
4. **章节胶囊/章末卡片/浮动按钮三者合一**：避免出现"两套前后章按钮"。
   目标视觉：右上角 `‹ 12 / 48 ›`；章末内容下方两张卡片；角落浮动按钮删除。
5. **时钟左移**要为缩放簇留出固定宽度，别用负 margin 硬挤；两者在窄窗口下要能换行或隐藏。
6. **i18n**：新增文案必须走 `.tl`，并在 `assets/translation.json` 的 zh_CN + zh_TW 同步；
   提交前把该文件 CRLF 还原（编辑工具会整体改 LF，产生上千行脏 diff）。

---

## 六、验收与门禁

- 编译：`flutter analyze --no-pub` 无 error。
- 构建：`python tools/run_build_task.py` → `builds/build.log` 出现 **BUILD_OK**；
  产物在 `Mangrove/builds/mangrove/`，要在**该目录**运行 exe（`Release/` 缺 DLL）。
- 回归门禁（在 `builds/mangrove` 下 `.\mangrove.exe --headless <cmd>`）：
  `glossary-ui-check`（29）、`block-ops-check`（129）、`glossary-check`（26）应保持全 PASS。
- 新增门禁：空格步进、快捷键映射、章末浮层触发条件、无隐式跳章 —— 至少一组进 P9/P10 类探针。
- GUI 验收：agent 无渲染表面，人工必须过一遍「空格半页、方向键上下翻页、左右切章、
  滚到底出两按钮、右上章节浮层、右下百分比缩放」。**没有记录不许标 ✅**（A08 两列口径）。

---

## 七、硬规矩（沿用，不重复解释）

- 构建只走 `tools/run_build_task.py`，venv：
  `C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe`。
- 改动前先 `git status`；每批施工 = 1 个小版本（本轮预期 `3.1.0+276`）。
- 任何「已完成 ✅」必须有故障注入断言真的 FAIL；空结果判 FAIL（A02）。
- 中文汇报，结论先行、条目化、附实测证据。
- 文档命名 `P56-{TYPE}-{主题}-20261114.md`；本轮工作日志进 `worklog/13-…` 新目录。

---

## 八、建议施工顺序

1. 实测 comix.to + 包子（第四节点），把参数与截图落盘，**先给用户确认空格幅度与动画**。
2. 抽纯逻辑 + 加 headless 探针（先红后绿）。
3. 实现空格/方向键映射（T1、T3），顺手把 `help_dialog.dart` 改成与实现一致。
4. 删三处隐式跳章 + 删角落浮动按钮，加章末双按钮浮层（T4）。
5. 桌面布局重排：右上章节浮层、左下页轨、右下缩放簇、时钟左移（T5）。
6. 引入 `readerLayoutMode`，把桌面专属控件挂到开关上（T2 的桌面部分）。
7. 构建 + 门禁 + 人工验收；写 WORKLOG、更新 A08 / P55 / INDEX；提交。

---

## 附录 A：用户原话（2026-11-14，逐字，语义以此为准）

> 「优化阅读器的翻页方式，我需要你仿照 comix.to 网站以及其他很多 web 网站的翻页效果，
> 让我可以使用空格进行向下滑动翻页。原本的空格是什么效果我不是很清楚。还有翻页的幅度
> 大概是半页左右就可以了，具体滑动效果也请你参考 comix.to 网站的阅读器或者包子漫画的
> 阅读器滑动效果。然后进一步调整阅读器的上一章和下一章效果。具体也是参考 comix.to 网站
> 的阅读器界面。请你最好打开浏览器看看这个网站浏览器的各个控件。我们现在在 mangrove 的
> 漫画阅读器进行空格的效果，大概是能取消图片选中？然后点击左右侧或唤出上下栏，而很明显
> 上下栏的功能大部分都已经被我在右侧的工具栏取代了。因为这一套是赋予于上下条漫的格式，
> 而老的阅读器主要是服务手机端，我们需要设置两者模式，一种是电脑的桌面端 ui 布局，一种是
> 手机的移动端布局。电脑端布局还需要配备快捷键。比如上下方向键可以上下翻页，左右方向键
> 可以前后章节跳转。然后还需要改动前后章节跳转效果，不再服从页面到顶或者到底部的时候，
> 再拉动就会跳转。而是要像 comix.to 网站的阅读器一样，拉到底部的时候会弹出两个按钮可以
> 向前或者向后跳转。去掉原先在角落弹出的按钮。最后再参考 comix.to 网站阅读器，原本左下角
> 的章节树像是移动到右上角，而页面树还是保留在左下角，现在章节数的左右可以补充两个前后
> 章节跳转按钮。而在右下角的时间显示区域，请你移动到靠左边一点让出空间。现在这里要多放置
> 一个百分比显示大小与缩放的加减按钮。总之大概是这些，你参考网页端的阅读器修改我们的阅读器
> 桌面版本，然后至于移动端的版本，可以延后考虑。因为我们还没有开发 mangrove 的移动版，
> 只是做好计划。」
