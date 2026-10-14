# mangrove 阅读器样式修改计划（桌面端 · B 中度借鉴路线）

> **依据**：《[comix-to与mangrove阅读器对比分析](comix-to与mangrove阅读器对比分析.md)》（2026-10-14，全部结论带 DOM/CSSOM/代码实测）
> **路线**：B 中度借鉴——保留 mangrove 成熟架构与功能密度，选择性吸收 comix 的边缘页轨、可见缩放、章尾导航、主题自定义等。
> **平台**：本轮**仅规划并实施 Windows / macOS / Linux 桌面端**；移动端 mangrove 开发尚浅，所有移动端适配仅在第 8 章预留，留待移动端开发期处理。
> **范围**：阅读素材 / 成品 / 网络漫画三类读者共用的阅读器。**不触碰翻译工作室与翻译管线**（扫描、OCR、译文叠加、译文/原图徽标逻辑保持现状）。
> **总原则**：
> 1. 新元素一律**可开关、有合理默认值**，默认不改变老用户习惯；
> 2. 新增颜色一律取 `colorScheme.*`，跟随全局主题，不硬编码；
> 3. 先做与现有架构正交的新组件（页轨、主题预设），再做存量 UI 调整；
> 4. 每个 P0/P1 项独立可发布、可回退。

---

## 目录

1. [分期总览](#1-分期总览)
2. [P0-1 左侧页轨（核心新组件）](#2-p0-1-左侧页轨核心新组件)
3. [P0-2 全局多配色方案与整体换色](#3-p0-2-全局多配色方案与整体换色)
4. [P1 桌面端增强项](#4-p1-桌面端增强项)
5. [P2 后续低优先级项](#5-p2-后续低优先级项)
6. [移动端预留设计（本轮不实施）](#6-移动端预留设计本轮不实施)
7. [实施顺序与里程碑](#7-实施顺序与里程碑)
8. [桌面端验收矩阵](#8-桌面端验收矩阵)

---

## 1. 分期总览

| 项 | 内容 | 价值 | 成本 | 平台 | 主要落点 | 新设置键（建议） |
|---|---|---|---|---|---|---|
| P0-1 | 左侧边缘页轨（进度组件可换位置） | 高 | 中 | 桌面 | 新建 `lib/pages/reader/page_rail.dart`；scaffold.dart；reader.dart；settings/reader.dart | `readerProgressBarPosition` = `bottom`（默认）/ `left` |
| P0-2 | 多配色方案 + 自定义种子色 + 预览 | 高 | 中 | 全平台（桌面先行验证） | main.dart；settings/app.dart；translation.json；新建设置子页 | `colorSchemePreset`、`customSeedColor`（迁移旧 `color`） |
| P1-1 | 右下缩放百分比 / 适应宽度簇 | 中 | 小 | 桌面 | scaffold.dart + reader.dart（PhotoView scale 控制） | `readerShowZoomBar`（默认关） |
| P1-2 | 章节胶囊式上下话 +「当前/总数」 | 中 | 小 | 桌面 | scaffold.dart 顶栏区域 | 无（跟随 P0-1 布局微调） |
| P1-3 | gallery 章尾 Prev/Next 导航大卡 | 中 | 小 | 全 | images.dart 章末页构建 | `readerShowChapterEndNav`（默认开） |
| P1-4 | 快捷键 / 手势帮助弹窗（`?`） | 中 | 小 | 桌面 | 新建 reader/help_dialog.dart；shortcut 注册 | 无 |
| P1-5 | 设置补项：一键灰度、压暗、单击/双击显隐、匀速自动滚动 | 中 | 小–中 | 桌面优先 | settings/reader.dart；images.dart；reader.dart | 见 4.5 |
| P1-6 | 可选右缘竖工具栏 | 中 | 中 | 桌面 | 新建 reader/side_toolbar.dart | `readerSideToolbar`（默认关） |
| P2-1 | 评论右侧抽屉化 + continuous 章末内嵌 | 中 | 中–大 | 桌面 | reader 布局 + chapter_comments.dart（受图源评论 API 约束） | `readerCommentDrawer`（默认关） |
| P2-2 | 章节列表搜索 / 相对时间 / 翻译组锁定 | 中 | 中 | 桌面 | chapters.dart | — |
| P2-3 | 社交分享按钮组 | 低 | 小 | 全 | 章尾卡（系统 share 已覆盖核心） | 默认关 |

---

## 2. P0-1 左侧页轨核心新组件

### 2.1 功能定义

把"阅读进度指示"从固定底栏升级为**可换位置的同一组件**，设置二选一：

- **Bottom（默认，现状）**：底栏滑条 + 页码胶囊，行为完全保持；
- **Left（新增）**：左缘页轨。底栏第一行中的滑条隐藏（页码胶囊与上一章/下一章钮保留），左缘出现 comix 风格页轨。

Left 态三态：**已读**（强调色 55% 透明）/ **当前页**（强调色实心）/ **未读**（onSurfaceVariant 18% 透明）；收起时仅 3px 细条，**鼠标进入左缘 24px 热区整条展开为 24px**，每格 hover 显示页码气泡，点击跳页。

### 2.2 视觉规格（桌面端，对齐 comix 实测值，按 Flutter/M3 换色）

| 元素 | 规格 |
|---|---|
| 热区容器 | 高 = 阅读区顶（顶栏底）到底；宽 **24dp**；透明；顶/底栏隐藏时上沿从 56 → 0（180–250ms）；z 序位于内容之上、弹层之下 |
| 页格（收起） | 宽 **3dp**，高 = 轨道高 / 总页数 − 1（页间 1dp 分隔，分隔色取阅读背景色） |
| 页格（展开） | 宽 **24dp**（180ms `Curves.easeOut`），右对齐；当前格与 hover 格为强调色实心 |
| 未读色 | `colorScheme.onSurfaceVariant.withValues(alpha:.18)` |
| 已读色 | `colorScheme.primary.withValues(alpha:.55)` |
| 当前色 | `colorScheme.primary` |
| 页码气泡 | M3 inverseSurface 底 / onInverseSurface 字（对应 comix `#A0A0A0` 底 `#181A1C` 字）；圆角 4；垂直 padding 0、水平 5dp；字号 12–13；出现在轨道右侧、垂直居中；淡入 150–200ms |
| 光标 | `SystemMouseCursors.click` |
| 触控 | 桌面端不实现手势展开（容器已 24dp，可直接点按）；移动端见第 6 章 |

> 说明：comix 用 CSS 变量 `--accent` 驱动三态；本设计用 `colorScheme.primary`，P0-2 主题换色后页轨自动跟随，三套读者（素材/成品/网络漫画）同时生效。

### 2.3 技术设计

**新文件**：`lib/pages/reader/page_rail.dart`

```
ReaderPageRail（StatefulWidget，const 无参，经 context.reader 取状态）
├─ Positioned(left:0, top:0, bottom:0, width:24)（由 scaffold Stack 挂载）
├─ MouseRegion(onEnter/onExit 维护 _expanded；onHover 维护 _hoverIndex)
├─ Column(children: List.generate(maxPage, _seg))
│   └─ _Seg：GestureDetector(onTap: jumpToPage(i))
│           + AnimatedContainer(width: _expanded ? 24 : 3, 颜色三态)
└─ 页码气泡：OverlayEntry（hover 变化时重建）或 MouseRegion + Tooltip
```

- **数据源（与底栏滑条同源，禁止第二套状态）**：`context.reader` 的当前页 / 总页 / 当前话；页码变化监听复用底栏滑条现有 listener（scaffold.dart 中滑条 rebuild 的同一通路）。
- **跳转**：
  - gallery：复用现有 PageController `jumpToPage(i)`（带动画用 animateToPage，时长沿用翻页动画设置 200ms 开关语义）；
  - continuous：复用 images.dart 中按页 index 定位的现有能力（章间接续卡定位同源逻辑）滚到该页中心。
- **visited 判定**：gallery 直接比较 index ≤ current；continuous 以"已到达过的最大页 index"维护（进入阅读器初始化为当前阅读历史页；读者向后阅读单调更新；向前回翻不清空——与 comix visited 语义一致）。状态存 ReaderState 内存即可（阅读历史持久化已有，不新增持久化）。
- **跨章（无缝模式）**：页轨只渲染**当前章**页数；章切换瞬间跟随现有接续逻辑刷新；不做"全书 104 格"跨章拼接（comix 亦不拼接）。
- **控件显隐联动**：顶/底栏 `AnimatedSlide` 隐藏时页轨容器上沿同步到 0（与 comix `.rpage--chrome-hidden` 一致），页轨本身不隐藏。

**密度策略**（超长章节）：

- 轨道高 / 页数 > 2dp：逐格绘制（145 页 @900dp ≈ 6dp/格，无压力）；
- 单格高 < 2dp（约 >400 页）：P0 采用**最小格高 2dp + 轨道内部滚动**（对齐到当前页）；P1 可升级为"段聚合"（每格代表 N 页，hover 气泡显示区间）。计划先按最小高+滚动实现，聚合列为 P1 备选。

### 2.4 设置项

- 键：`readerProgressBarPosition`，值 `bottom`（默认）/ `left`；
- 位置：设置 → 阅读 → 显示分组（`lib/pages/settings/reader.dart`），用现有 `SelectSetting`；
- 仅桌面可见（`App.isWindows || App.isLinux || App.isMacOS`），副标题说明"左侧边缘显示页轨"；
- i18n：translation.json 增 `Progress bar position` / `Bottom`（可复用）/ `Left edge`，zh-CN「进度条位置 / 底部 / 左侧」；
- Left 态底栏第一行：隐藏 CustomSlider；上一章/下一章钮与页码胶囊保留（避免功能丢失）；右下 FAB 逻辑不变。

### 2.5 风险与对策

| 风险 | 对策 |
|---|---|
| 左缘 30% 点击翻页热区（gesture.dart）与 24dp 轨冲突 | 页轨在 Stack 中先于手势层命中（`HitTestBehavior.opaque`）；同时在 gesture 热区计算中把左侧 24dp 排除（双保险）；自动化测试手点左缘翻页不回归 |
| continuous 变长图，物理滚动位置 ↔ 页 index 映射抖动 | active 判定复用底栏滑条现有的当前页计算（已在线上使用），不引入新映射 |
| 气泡 Overlay 在控件快速划过时残留 | hover 退出容器时统一 remove；气泡跟随 `_hoverIndex` 单例重建 |
| 窗口高压缩（横屏小窗） | 走密度策略最小高；气泡始终可见不受压缩影响 |
| 与译文/原图徽标等翻译消费 UI 重叠 | 页轨位于内容左缘，徽标在顶栏，零交集；实施后目视检查三类读者 |

### 2.6 验收要点

- 6 种阅读模式 × 本地/网络漫画下三态色、当前页同步、点击跳转正确；
- 鼠标进出展开/收起流畅，气泡显示对应页码；
- 无缝跨章时页数刷新、visited 不串行；
- 设置切回 bottom 后底栏完全恢复原状；
- 左缘翻页热区在轨道以外区域仍然有效；
- 明暗主题 + P0-2 各配色下对比度达标。

---

## 3. P0-2 全局多配色方案与整体换色

### 3.1 现状（已核查）

- 设置 → App → Appearance：`theme_mode`（system/light/dark）+ `color`（system 动态取色 / 6 个 Material 原色）。
- [main.dart](file:///D:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/main.dart#L188-L252)：`translateColorSetting()` 单色映射 → `SeedColorScheme.fromSeeds(primaryKey, secondaryKey, tertiaryKey, FlexTones.vividBackground)` 派生 M3 明暗双色方案。
- 依赖 `dynamic_color ^1.8.1`、`flex_seed_scheme ^4.0.1` 已在 pubspec；无取色器依赖。
- 问题：预设只有单色、无成套方案、无法自定义色值、无预览、非 system 下 secondary/tertiary 不可控。

### 3.2 设计：在 M3 种子机制上扩展（不推翻重来）

保留"挑一个种子色、算法生成全套"的省心模型（优于 comix 让用户手填 5 个色值），补齐三块：**命名方案预设、自定义种子、即时预览**。

#### 3.2.1 数据模型与迁移

- 新设置键：
  - `colorSchemePreset`：`system` | `blue` | `purple` | `tokyo` | `teal` | `pink` | `amber` | `green` | `red` | `violet` | `graphite` | `sepia` | `custom`；
  - `customSeedColor`：ARGB int 字符串（如 `#7AA2F7`）。
- **兼容迁移**（App.init 一次性，幂等）：旧 `color` 值 → preset：`system→system`、`red/pink/purple/green/orange/blue` → 同名预设（orange→amber）、未知/默认 → `blue`；迁移后保留旧键不删（回退版本安全）。
- [main.dart](file:///D:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/main.dart#L188-L200) `translateColorSetting()` 改为读预设表 + custom：

| preset | 种子色（HEX） | 备注 |
|---|---|---|
| system | — | 动态取色（Material You），现状保留 |
| blue | `#2196F3`（Colors.blue） | 现状默认 |
| purple | `#8765EB` | **Comix 紫**（comix 默认强调色） |
| tokyo | `#7AA2F7` | Tokyo Night 蓝（comix Custom 实测色） |
| teal | `#14B8A6` | 青碧 |
| pink | `#EC4899` | 樱粉 |
| amber | `#F59E0B` | 琥珀（迁移旧 orange） |
| green | `#22C55E` | 翠绿 |
| red | `#EF4444` | 朱红 |
| violet | `#8B5CF6` | 紫罗兰 |
| graphite | `#6B7280` | 极简灰（低彩度） |
| sepia | `#B08968` | 暖纸（浅色模式暖色背景观感） |
| custom | `customSeedColor` | 用户取色 |

- secondary/tertiary：P0 一律 null 自动派生（与 comix Surface=Auto 同理念）；`FlexTones.vividBackground` 保持不变，保证现有观感不漂移。

#### 3.2.2 UI（Appearance → Theme Color 升级为方案选择页）

新建 `lib/pages/settings/app_color_scheme.dart`（part of settings_page 或独立页，沿用现有 `_SettingsExpansionTile` + ListTile→子页模式，与 Home Page Layout 设置同级形态）：

1. **动态取色**首项（System），仅在平台支持时可用，副标题说明跟随系统壁纸；
2. **预设方案网格**（2 列或横向 3 列卡片）：每张卡片 = 方案名 + 一组 M3 迷你样张（primary / primaryContainer / surface 三个色块，直接用 `SeedColorScheme.fromSeeds` 对该种子即时构建明/暗各一组）；选中卡片显示主色描边 + check；
3. **Custom 卡片**：点击展开取色区：
   - 推荐新增依赖 **`flex_color_picker`**（与 flex_seed_scheme 同生态、维护活跃、自带 Material 色相盘 + HEX/RGB 输入 + 明暗色板，避免自研取色器的边缘成本）；若评审不希望加依赖，降级方案：自研"色相滑条 + HEX TextField"（约 150 行，只能选种子色，无色相盘）；
   - HEX 输入实时校验；
4. **预览区**（页面顶部固定）：明/暗两个迷你 M3 样张条——FilledButton、OutlinedButton、Switch、Slider、Card、复选框，选择即时重建（`App.forceRebuild()`，沿用现有切换回调）；
5. Theme Mode（system/light/dark）选择保留在 Appearance 组原位。

#### 3.2.3 落点清单

| 文件 | 改动 |
|---|---|
| [main.dart](file:///D:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/main.dart#L188-L252) | 预设表、custom 解析、`getTheme` 读新键、DynamicColorBuilder 分支不变 |
| App 初始化（App.init / data 迁移处） | 旧 `color` → `colorSchemePreset` 一次性迁移 |
| [settings/app.dart](file:///D:/AI%20Coding%20Project%20Management/Mangrove/Mangrove/lib/pages/settings/app.dart#L44-L60) | 旧 Theme Color 的 SelectSetting 替换为子页入口 |
| 新建 `lib/pages/settings/app_color_scheme.dart` | 方案网格 + 取色器 + 预览 |
| `assets/translation.json` | 新文案（en/zh-CN/zh-TW）：Color scheme / Dynamic color / Custom color / Reset 等 |
| `pubspec.yaml` | （推荐）`flex_color_picker` |

#### 3.2.4 与阅读器的关系

- 阅读器**不直接换色逻辑**：页轨（P0-1）、章节列表当前话边框、FAB、滑条全部消费 `colorScheme`，换主题自动生效；
- 阅读背景色（白/灰/黑/羊皮纸/绿/system）与夜间遮罩维持独立设置，不并入全局方案（用户可能在任意主题下使用黑底阅读）。

### 3.3 验收要点

- 13 个预设在明/暗模式下整个软件（首页、详情、阅读器、设置、对话框）即时换色无白块/漏色；
- Custom 取色 + HEX 输入持久化，重启保持；
- 旧版 6 色与 system 设置升级后等价迁移、无感知；
- 动态取色（Material You）平台行为不回归；
- 阅读器页轨三态在所有预设下可读。

---

## 4. P1 桌面端增强项

### 4.1 右下缩放百分比 / 适应宽度簇（P1-1）

- 形态对齐 comix：`[适应宽度] [−] [50%/1x] [+]`，半透明深色底、小尺寸，只在桌面端且鼠标移动时淡入（无操作 2s 淡出，避免干扰）；
- 功能：复用 PhotoView 现有 scale 能力与 `limitImageWidth`；长卷按百分比档（建议 50/75/100/125/150%），gallery 按倍档（1x/1.5x/2x，maxScale 2.5 上限不变）；适应宽度映射到"图宽 = 图列宽"；
- 设置 `readerShowZoomBar` 默认**关**（手势/Ctrl+滚轮用户不受影响）；落点：scaffold.dart 右下 Stack + reader.dart scale 状态；
- 验收：缩放后跨章接续不复位异常，双指/Ctrl+滚轮与按钮三向同步。

### 4.2 章节胶囊与「当前/总数」（P1-2）

- 顶栏标题区可选紧凑模式：`‹  Ch.12 / 48  ›` 连体胶囊（M3 surfaceContainerHighest @ .92、圆角 4、高 34），点击中央打开章节列表边栏；末话/首话禁用；
- 与现有双行书名/话名共存：宽度 ≥ 某阈值时显示胶囊 + 悬停 tooltip 显示完整书名；窄窗维持现状；
- 落点：scaffold.dart buildTop，纯展示组件，数据源为现有 chapter/totalChapters。

### 4.3 gallery 章尾 Prev/Next 导航大卡（P1-3）

- 在 gallery 可选章末页（现有章末评论页同一插入点，images.dart）增加两张大卡：上一话 / 下一话（标题+话号，禁用态置灰），样式 M3：宽 320–360、高 44、圆角 8、surfaceContainerLow 底；
- continuous 无缝模式不插（保持无感跨章）；
- 设置 `readerShowChapterEndNav` 默认**开**（gallery 模式）；评论页与导航卡可同页上下排布。

### 4.4 快捷键帮助弹窗（P1-4）

- 新建 `lib/pages/reader/help_dialog.dart`：ContentDialog，分组两列罗列现有键位（方向/AD/WS、F12、空格、Esc、音量键仅 Android 不显示、鼠标手势：点击热区/双击缩放/长按/跨轴收藏/Ctrl+滚轮/右键菜单）；
- 入口：右缘工具栏（P1-6）问号钮 + 键盘 `?`/`F1`；桌面 shortcut 注册到阅读器 Shortcuts/Actions；
- 价值：mangrove 手势远比 comix 丰富但无任何速查入口。

### 4.5 设置补项（P1-5）

| 新设置键 | 内容 | 落点 |
|---|---|---|
| `readerGreyscale`（默认关） | 一键灰度（ColorFiltered matrix；与现有自定义滤镜互斥时的优先级写明：自定义滤镜开启时此项禁用） | images.dart 图片包装层 |
| `readerDimStrength`（0–0.4，默认 0） | 桌面新增"压暗"轻量档（区别于夜间遮罩：仅降亮不到换色），与夜间遮罩合并 UI 分组 | images.dart / scaffold 遮罩层 |
| `readerChromeHideTrigger`（`tapCenter` 默认 / `singleTapAnywhere` / `doubleTap`） | 显隐控件触发策略 | gesture.dart |
| `autoScrollSpeed`（px/s，默认 150，仅 continuous） | 新增**匀速自动滚动**（现有定时翻页保留为另一种模式；UI 上两者分段选择：按页计时 / 匀速滚动） | reader.dart 自动播放状态 |

### 4.6 可选右缘竖工具栏（P1-6）

- 新建 `lib/pages/reader/side_toolbar.dart`：34–40dp 图标钮纵向排列、透明底、半透明悬停背景；从右缘滑入，桌面端 `readerSideToolbar` 默认**关**；
- 收录：章节列表、评论（P2 接入）、全屏、自动滚动/翻页、设置、帮助；与顶/底栏功能重复但并存，纯布局偏好；
- 放在最后实施，待 P1-1~P1-5 验收后再做，避免一次改动过大。

---

## 5. P2 后续低优先级项

1. **评论右侧抽屉化**（`readerCommentDrawer` 默认关）：桌面宽屏下评论以 360–400dp 右侧抽屉常驻、阅读区压缩不遮罩（参照 comix `.rpage-cmpanel`）；continuous 章末内嵌评论流。**前置约束**：仅对提供评论 API 的图源开放；先盘点当前图源支持情况再排期。落点：scaffold.dart 响应式 Row + chapter_comments.dart。
2. **章节列表增强**（chapters.dart 400dp 边栏内）：搜索框过滤话名/话号；行内显示相对时间（图源数据支持时）；多翻译组视图增加"锁定该翻译组翻章"开关；排序增加按日期。
3. **社交分享按钮组**：章尾卡上系统 Share 之外补复制链接等（桌面端价值低，最后做）。
4. **页轨段聚合**（>400 页章节的高密度模式，见 2.3）。

---

## 6. 移动端预留设计本轮不实施

- `readerProgressBarPosition` 设置项移动端先不出现在 UI（键值可被桌面同步下来，移动端按 bottom 解释）；
- 触控态页轨设计备忘：无 hover，改用两种可选形态——①常驻 3dp 细条，点按左缘把手（24dp 热区）后整条展开保持，再点格外收起；②仅在快速滑动/拖动滑条时浮出。与移动端手势返回（系统返回在左缘）冲突需在移动端开发期专门验证（页轨右置可能成为移动端首选）；
- 缩放簇、竖工具栏、帮助弹窗、评论抽屉的触控尺寸按 ≥48dp 重新标定；
- 多配色方案（P0-2）本身平台无关，移动端随主题系统天然获得，不产生额外工作。

---

## 7. 实施顺序与里程碑

| 里程碑 | 内容 | 出口标准 |
|---|---|---|
| M1 | P0-2 多配色方案（含迁移、i18n、取色器选型落地） | 13 方案 + Custom + 预览可用；旧设置无损；为 P0-1 提供颜色地基 |
| M2 | P0-1 左侧页轨 | 设置切换、6 模式 × 三类读者验收通过（8. 矩阵） |
| M3 | P1-1/P1-3/P1-4（缩放簇、章尾导航卡、帮助弹窗） | 三个独立小项各自可回退 |
| M4 | P1-2/P1-5（胶囊、灰度/压暗/显隐策略/匀速滚动） | 设置补项完整 |
| M5 | P1-6 竖工具栏（可选） | 默认关闭，开关键在 |
| P2（不排期） | 评论抽屉、章节列表增强、分享、页轨聚合 | 图源评论 API 盘点后另立计划 |

建议 M1、M2 各一次评审；代码按现有惯例（analyze 0 error、测试同步）执行；文档与记忆按项目 `.agent/` 日志惯例登记。

---

## 8. 桌面端验收矩阵

| 维度 | 用例 |
|---|---|
| 阅读模式 | gallery LTR / RTL / T2B；continuous T2B / LTR / RTL 共 6 种 |
| 内容类型 | 本地素材（导入目录）、本地成品（图源下载内容）、网络漫画在线阅读；含一个支持评论的图源 |
| 进度组件 | bottom 原状；left 三态/展开/气泡/跳转/跨章刷新；600+ 页章节密度 |
| 主题 | 13 预设 × 明/暗/跟随系统；Custom 取色持久化；旧 `color` 配置迁移 |
| 设置 | 所有新键默认值符合本文；关闭开关后界面恢复 |
| 手势回归 | 左缘热区翻页（页轨外）、点击中央显隐、双击缩放/收藏、长按、跨轴收藏、Ctrl+滚轮、右键菜单、F12 |
| 窗口 | 常规窗、窄窗（胶囊降级为双行标题）、最大化、多显示器切换 |
| 翻译消费 | 译文/原图切换、翻译状态徽标在页轨/胶囊/各主题下显示正常（管线本身不验证） |

---

*本计划为实施蓝图，本轮不修改任何 mangrove 代码；待评审通过后按 M1→M5 执行。*
