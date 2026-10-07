# 单文本框"重译"按钮实施计划

## 一、调研结论

### 你提出的两种翻译模式，现状如下

1. **初步翻译（全图自动模式）——已具备，无需改动**
   点 RUN 后走 `RunPipelineDialog` → `module_manager.runImgtransPipeline(...)`，自动完成文字检测 → OCR → 翻译 → 抹图 → 排版，文本框由检测模型自动分配（[mainwindow.py#L2148](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/ui/mainwindow.py#L2148)）。

2. **细致翻译（单框修正模式）——后端已完整，但没有显眼入口**
   后端单框管线 `runBlktransPipeline(blk_list, mode, blk_ids)` 早已存在（[module_manager.py#L813](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/ui/module_manager.py#L813)），mode 语义：

   | mode | 动作 |
   |---|---|
   | -1 | **仅重译**（用文本框里当前的原文重新翻译） |
   | 0 | 仅重新 OCR |
   | 1 | OCR + 翻译 |
   | 2 | OCR + 翻译 + 抹图 |
   | 3 | 仅抹图 |

   目前它只挂在**画布右键菜单**（translate / OCR / OCR and translate，[canvas.py#L1500-L1504](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/ui/canvas.py#L1500-L1504)），而右侧文本面板每个原文/译文行（`TransPairWidget`）只能手动打字，没有任何按钮。

3. **回写与撤销链路现成**：`MainWindow.translateBlkitemList()` 会先把原文编辑框内容写回 `blk.text`，再启动后台翻译；完成后 `on_blktrans_finished` 推入 `RunBlkTransCommand`，自动刷新译文框和画布，且 **Ctrl+Z 可撤销**（[drawing_commands.py#L84](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/ui/drawing_commands.py#L84)）。

### 结论

本次需求 = 在每个文本块的原文/译文行上加一个**「重译」按钮**，复用现成的 mode=-1 管线。典型用法正好覆盖你说的两种错误：
- 译文错 → 直接点「重译」；
- 原文 OCR 提取错 → 在原文框改对文字 → 点「重译」按修正后的原文重新翻译。
（若希望连原文也重新识别，右键菜单已有"OCR并翻译"，本次不重复造。）

## 二、改动文件

1. **[widgets.py](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/ui/text_engine/editing/widgets.py)**（`TransPairWidget` 类，L722）
   - 新增信号 `retranslate_clicked = Signal(int)`（携带该块 idx）；
   - 每行左侧序号列下方加一个紧凑 `QToolButton`：`objectName='PairRetranslateButton'`、文字 `tr('Retranslate')`、tooltip `tr('Re-translate this block from its current source text')`、`NoFocus`（不打断正在编辑的输入框）；
   - 新增 `set_retranslate_busy(enabled)` 供翻译运行时禁用/恢复。

2. **[manager.py](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/ui/text_engine/editing/manager.py)**（`SceneTextManager`，pair 创建处在 L553-576）
   - 连接 `pair_widget.retranslate_clicked → on_retranslate_requested(idx)`；
   - 新处理器：idx 越界保护 → 后台线程忙（`imgtrans_thread.isRunning()`）则忽略 → 原文为空则聚焦原文框提示输入 → 否则调用现成的 `mainwindow.translateBlkitemList([blkitem], -1)`；
   - pair 创建时把 `imgtrans_thread.started/finished` 连到该按钮的禁用/启用（页面切换时旧控件销毁，连接自动解除）。

3. **[stylesheet.css](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/resources/stylesheet.css)**
   - 增加 `QToolButton#PairRetranslateButton` 作用域样式：小号、方形内边距、主题强调色 `rgb(30,147,229)`，不写全局 QToolButton 规则。

4. **翻译文件**（遵循项目 i18n 约定，新 UI 文案走 tr()）
   - [zh_CN.ts](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/resources/translate/zh_CN.ts)、zh_TW.ts 新增 `TransPairWidget` 上下文：`Retranslate→重译/重譯`、tooltip→`使用当前原文重新翻译该文本框/使用目前原文重新翻譯此文本框`；
   - 重新编译 `zh_CN.qm`、`zh_TW.qm`（环境无 lrelease，见风险项）；
   - ko_KR 本次不更新，韩文界面回退英文，不影响功能。

## 三、实施步骤（依赖顺序）

1. widgets.py：加信号、按钮、busy 方法；
2. manager.py：加信号连接与 `on_retranslate_requested` 处理器、busy 联动；
3. stylesheet.css：加作用域样式；
4. 更新 zh_CN/zh_TW 的 .ts 并重编译 .qm；
5. 验证（见下）。

## 四、依赖与注意

- 不新增任何 Python 依赖、不改翻译/ OCR 后端、不改工程 JSON 格式、不影响初译全图流程；
- 翻译在后台 `ImgtransThread` 执行，不阻塞 UI（沿用现有线程）；
- 主窗口中 st_manager(L355) 先于 module_manager(L478) 创建，因此线程信号只能在 pair 运行时创建处连接，不能在 `__init__` 连；
- 按钮点击走 NoFocus，原文框未提交的文字也会被 `translateBlkitemList` 实时读取，无需额外保存动作。

## 五、验证

- `python -m py_compile` 三个改动的 .py；`git diff --check`；
- offscreen(Qt) 冒烟：实例化 `TransPairWidget`，模拟点击确认发出 `retranslate_clicked(idx)`；用 `QTranslator` 加载新 zh_CN.qm，确认 `Retranslate` 译为「重译」；
- 真实软件界面联调（需要你机器上的翻译器/模型）由你执行：改原文→点重译→译文刷新→Ctrl+Z 可回退。

## 六、风险与对策

- **环境无 lrelease 编译 .qm**：拟在系统临时目录用 `pip install --target` 临时取 PySide6-Essentials 的 lrelease.exe 编译，用完即删，不污染内嵌 Python 环境；若失败则功能照常上线（按钮临时显示英文 Retranslate），.ts 译文已入库，后续有 Qt 环境时一条命令可补编译。
- **重复点击/与全图 RUN 并发**：`isRunning()` 防护 + 运行中禁用全部重译按钮。
- **空原文点击**：不发请求，聚焦到原文框。
