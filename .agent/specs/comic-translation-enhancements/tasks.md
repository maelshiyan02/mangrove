# 漫画翻译精细化三项功能 - 实施计划

分期：阶段一（G1 框选翻译，任务 1-4）→ 阶段二（G2 合并翻译，任务 5-9）→ 阶段三（G3 排序与拼接，任务 10-14）。每阶段结束用户真机验证通过后再进入下一阶段。

## 阶段一：框选区域识别翻译（G1）

### Task 1: 画布"框选翻译"鼠标交互与状态
- **Status**: completed
- **Priority**: high
- **Depends On**: None
- **Completion Evidence**:
  - canvas.py 新增 `RegionTranslateTool = 4`（image_edit.py）、信号 `region_translate_rect(QRectF)`/`region_translate_mode_changed(bool)`、enter/exit 模式、Esc 退出、连续框选；clear_states/setPaintMode 同步复位。
  - tests/test_region_translate_tool.py：TR-1.1 单次拖拽坐标 ≈(20,30,120,90) 且只发 1 次；TR-1.2 连续两次发 2 次、Esc 后不再发信号。`Ran 7 ... OK`。
- **Description**:
  - 在 canvas.py 增加新的画布交互状态（与现有 textblock 建框橡皮圈同构）：进入后鼠标拖动画矩形，松开发出新信号 `region_translate_rect(QRectF)`；坐标为场景/图像坐标，与 `end_create_textblock` 一致。
  - 工具激活期间显示矩形辅助框、可连续拖选；Esc 或外部切换工具退出；与现有选择/绘制模式互不干扰。
- **Acceptance Criteria Addressed**: AC-1, AC-2
- **Test Requirements**:
  - `rule` TR-1.1: offscreen 下模拟按下-拖动-松开，Canvas 发出 1 次 region_translate_rect 且矩形坐标等于拖拽矩形；证据：pytest 输出。
  - `rule` TR-1.2: 连续两次拖拽发出 2 次信号；按 Esc 后再拖拽不发信号且状态复位；证据：pytest 输出。

### Task 2: 底部工具栏"框选翻译"按钮
- **Status**: completed
- **Priority**: high
- **Depends On**: Task 1
- **Completion Evidence**:
  - drawingpanel.py 新增 regionTool（对象名 DrawRegionTool、互斥、tooltip、配置恢复）、快捷键 G（mainwindow.py）、两张 SVG 图标、对象名作用域样式；canvas 侧退出经 region_translate_mode_changed 同步按钮。
  - TR-2.1：工具互斥测试通过；修复了长文本提示页撑宽 QStackedWidget 导致画布视口光标回归 6 连失败的问题（改为空面板+按钮 tooltip），回归 18/18 全绿。TR-2.2 留待真机。
- **Description**:
  - drawingpanel.py 按现有 hand/inpaint/pen/rect 按钮同构新增"框选翻译"按钮（对象名作用域样式、tooltip、可选中态、快捷键 Esc 由画布处理）；新增/复用 SVG 图标放 resources/icons。
  - 切换逻辑写入现有 `pcfg.drawpanel.current_tool` 分派处，Canvas 进入/退出对应模式；与 `mainwindowbars`/funcmaps 现有工具切换接线一致。
- **Acceptance Criteria Addressed**: AC-3, AC-13
- **Test Requirements**:
  - `rule` TR-2.1: 点击按钮后 checked 状态与画布模式一致，点击其他工具互斥退出；证据：offscreen 测试。
  - `rubric` TR-2.2: 入口一致性；1-5；1=风格突兀难找，3=能用但需说明，5=与现有工具完全同构且 tooltip 清晰；阈值 >=4；证据：真机界面检查。

### Task 3: 建块→OCR→翻译接线与最小尺寸保护
- **Status**: completed
- **Priority**: high
- **Depends On**: Task 1, Task 2
- **Completion Evidence**:
  - manager.py 抽出 `_create_textblock_item_from_rect`，新增 `on_region_translate_rect`：线程运行中拒绝、短边 <10px tooltip 拒绝（不落块）、合法则 CreateItemCommand 建普通 TextBlkItem 并以 mode=1 调 translateBlkitemList，完成走现成 on_blktrans_finished/RunBlkTransCommand（自动入撤销栈）。
  - TR-3.1/3.2 替身测试通过（mode=1 调用 1 次；过小不调用；线程忙不调用）。TR-3.3 的普通块/两次 Ctrl+Z 真机部分留待真机验证。
- **Description**:
  - SceneTextManager 接收 region_translate_rect：复用 onEndCreateTextBlock 的建块逻辑（抽取共用建块方法），先以 CreateItemCommand 建普通 TextBlock，再调用 `mainwindow.translateBlkitemList([blkitem], 1)`（OCR+翻译，完成回调现成、自动入撤销栈）。
  - 矩形小于阈值（默认按现有 OCR 可裁剪最小尺寸常量）不发请求，轻量提示并不落块。
  - 翻译运行期间沿用已有 busy/禁用机制，避免与全图 RUN 并发。
- **Acceptance Criteria Addressed**: AC-1, AC-2
- **Test Requirements**:
  - `rule` TR-3.1: 合法矩形下建块 1 个且 translateBlkitemList 以 mode=1 被调用 1 次（用替身记录）；证据：pytest。
  - `rule` TR-3.2: 过小矩形不调用建块/翻译；证据：pytest。
  - `rule` TR-3.3: 新块为普通块（pairwidget 存在、可编辑/删除），完成后经现有 on_blktrans_finished 路径产生撤销命令；Ctrl+Z 两次依次回退译文与建块；证据：pytest + 真机记录。

### Task 4: 阶段一 i18n、文案与验证
- **Status**: completed
- **Priority**: medium
- **Depends On**: Task 2, Task 3
- **Completion Evidence**:
  - zh_CN.ts/zh_TW.ts 新增 DrawingPanel「Region translate」（框选翻译/框選翻譯）与 SceneTextManager「Drag a larger region to recognize text」（拖动一个更大的区域来识别文字/拖曳一個更大的區域來辨識文字），临时 PySide6 lrelease 编译 .qm 后已删除临时目录。
  - TR-4.1：RegionTranslateI18nTest 加载两个 .qm 断言中文译文通过（含 DrawingPanel/Canvas 两个上下文）。TR-4.2：py_compile OK；region+三套既有测试共 25 个全部通过；git diff --check OK。主窗口 offscreen 冒烟在基线同样因字体注册表依赖真实 GUI 而不可用，属环境限制，验证转真机。
- **真机反馈修复（G 键在文本编辑模式无效）**:
  - 根因：DrawingPanel 是右侧 QStackedWidget 的第 0 页，文本编辑模式下显示的是第 1 页 TextPanel，面板被隐藏；G 走 `shortcutSetCurrentToolByName` 的 `isVisible()` 守卫静默失效，新增按钮也只在绘图模式可见。
  - 修复：G 改为独立处理器 `MainWindow.shortcutRegionTranslate`（任意面板状态可切换，再按一次退出）；DrawingPanel 新增 `activate_region_tool()`（不要求面板可见）；画布右键菜单新增可勾选「Region translate (G)」入口；canvas 进入时保存/退出时恢复 gv dragMode，面板按钮改为 QSignalBlocker 纯 UI 同步，不再靠按钮信号副作用恢复画布。
  - 新增 RegionTranslateTextModeTest 6 个测试（面板隐藏时激活/文本模式拖选/Esc 恢复/画布侧入口同步/dragMode 记忆），全套 25/25 通过；简繁 .qm 补 Canvas 上下文「框选翻译/框選翻譯」。
- **Description**:
  - 全部新文案走 tr()；更新 zh_CN/zh_TW .ts，用临时 PySide6 lrelease 重编译 .qm（不污染内置环境）。
  - py_compile、git diff --check、offscreen 启动与上述测试；交付用户真机验证（AC-1/2/3）。
- **Acceptance Criteria Addressed**: AC-3, AC-13
- **Test Requirements**:
  - `rule` TR-4.1: QTranslator 加载新 zh_CN.qm 后工具名/tooltip 有中文译文；证据：offscreen 断言。
  - `rule` TR-4.2: py_compile 与全部新增测试通过；证据：命令输出。

## 阶段二：多断句合并翻译与回填（G2）

### Task 5: 译文自动切分工具函数与测试
- **Status**: completed
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 新增纯函数工具（ballontranslator/utils 下新模块）：输入整句译文、N、源片段长度（或框面积）权重，输出 N 段。规则：优先在 CJK（。！？…，、；：）与拉丁（. ! ? … , ; : 换行）标点边界切分；标点段数与 N 不等时按权重就近边界分配，保证拼接无损、顺序不乱。
  - 不写 UI、不依赖 Qt（可被测试直接导入）。
- **Acceptance Criteria Addressed**: AC-6, AC-8
- **Test Requirements**:
  - `rule` TR-5.1: 任意输入满足 `''.join(parts)==merged`（忽略切分插入/移除的分隔策略差异时以"无损重建"函数验证）、len(parts)==N、顺序一致；证据：pytest（含空段、N=2、N>段数等边界）。
  - `rubric` TR-5.2: 切分合理度；1-5；1=常切断词句，3=均匀但部分不自然，5=基本落在标点边界且长度均衡；阈值 >=4；证据：≥6 组 CJK/拉丁代表例句评审记录。
- **Completion Evidence**: 新增 `ballontranslator/utils/translation_split.py`（DP+greedy、标点 rank、权重兜底、doctest）与 `tests/test_translation_split.py`，20 个用例全过（无损/随机 200 例/权重/空段/CJK+拉丁+日文+引号+小数标点质量/性能）。

### Task 6: "合并翻译"对话框
- **Status**: completed
- **Priority**: high
- **Depends On**: Task 5
- **Description**:
  - 新对话框 ui/merge_translate_dialog.py（主题样式遵循 AGENTS.md，对象名作用域、无外部点击误关）：左侧源片段列表（上移/下移、可编辑拼合原文、连接符预览），"翻译"按钮；右侧 N 个目标行（自动预填、逐行编辑、上移/下移改映射）；确定/取消。
  - 翻译调用 ModuleManager 新增的轻量异步接口（translate_text_async：复用 TranslateThread 模块准备/异常对话框，翻译临时 TextBlock，不进入 UI 块列表），成功回填译文区，失败弹错误且不关闭。
- **Acceptance Criteria Addressed**: AC-4, AC-5, AC-6
- **Test Requirements**:
  - `rule` TR-6.1: 源片段上移/下移与编辑后，待翻译文本随之变化；证据：offscreen 测试。
  - `rule` TR-6.2: 翻译成功路径译文区显示结果；模拟翻译异常时 blocks 数据不变且对话框保留；证据：pytest（替身翻译器）。
  - `rule` TR-6.3: 目标行数恒为 N、拼接无损、可编辑、上下移改变映射顺序；证据：pytest。
- **Completion Evidence**: 新增 `ballontranslator/ui/merge_translate_dialog.py`（ApplicationModal、连接符横排空格/竖排直接相接/换行、源片段重排联动拼合框、翻译中禁用、失败错误框不关窗、取消 cancel pending）；`module_manager.py` 新增 `translate_merged_text/cancel_merge_translation` 与 `TranslateThread.translateSingleText/single_translate_finished`（worker 内自捕获异常，不经兜底错误框）。TR-6.1~6.3 由 `tests/test_merge_translate.py` 覆盖（17 用例全过）。

### Task 7: 合并翻译入口与选择顺序
- **Status**: completed
- **Priority**: medium
- **Depends On**: Task 6
- **Description**:
  - 画布右键菜单（多选时）与文本面板增加"合并翻译..."入口；选中 <2 块时禁用。
  - 按画布阅读顺序（selected_text_items 的排序结果）收集块；竖排/横排方向沿用块属性并允许对话框内调整。
  - headless 下入口安全 no-op。
- **Acceptance Criteria Addressed**: AC-4, AC-13
- **Test Requirements**:
  - `rule` TR-7.1: 选中 0/1 块时入口禁用，≥2 可用且打开对话框携带正确数量与顺序的片段；证据：offscreen 测试。
- **Completion Evidence**: `canvas.py` 新增 `merge_translate_requested` 信号与右键菜单项（文本面板右键复用同一菜单路由），`<2` 块 setEnabled(False)；`mainwindow.py` 新增 `on_merge_translate_requested`（headless no-op、按 idx 阅读序、开框前同步 e_source 原文、确认后按对话框顺序 push 命令）。TR-7.1 由 MergeEntryHandlerTest 覆盖（0/1 no-op、≥2 携带正确数量与重排顺序）。

### Task 8: 回填撤销命令与几何不变保证
- **Status**: completed
- **Priority**: high
- **Depends On**: Task 6, Task 7
- **Description**:
  - drawing_commands.py 新增 MergeTranslateCommand：记录每块 translation 快照（含空串）与目标行映射；redo 写入并刷新 pairwidget/canvas 文本与排版，undo 整体恢复；不触碰 xyxy/lines/角度/fontformat。
  - 确认后保存时机沿用现有机制；取消不产生任何修改。
- **Acceptance Criteria Addressed**: AC-7, AC-13
- **Test Requirements**:
  - `rule` TR-8.1: redo 后各块 translation 等于映射目标行；undo 后全部恢复快照；xyxy/lines 逐字段不变；证据：pytest。
  - `rule` TR-8.2: 取消对话框无命令入栈、无数据变化；证据：pytest。
- **Completion Evidence**: `drawing_commands.py` 新增 `MergeTranslateCommand`（快照含空串；blk.translation + e_trans/blkitem 文档双写，沿用 setPlainTextAndKeepUndoStack 与 op_counter 吸收首次 redo；rich_text 清空；不触碰几何；长度不齐抛 ValueError）；取消路径对话框 reject 仅 cancel pending、不 push 命令（由 mainwindow 保证）。MergeTranslateCommandTest 验证 redo/undo（含空串）与 xyxy/lines/angle/fontformat 快照一致；MergeDialogInteractionTest 验证取消无写入。

### Task 9: 阶段二 i18n 与整体验证
- **Status**: completed
- **Priority**: medium
- **Depends On**: Task 8
- **Description**:
  - zh_CN/zh_TW .ts/.qm 更新；py_compile、git diff --check、全部新增测试；交付真机验证（AC-4~8、AC-12 部分）。
- **Acceptance Criteria Addressed**: AC-4, AC-5, AC-6, AC-7, AC-8, AC-13
- **Test Requirements**:
  - `rule` TR-9.1: 新增文案在 zh_CN/zh_TW 下均有译文；证据：QTranslator 断言。
  - `rule` TR-9.2: 全部测试与语法检查通过；证据：命令输出。
- **Completion Evidence**: zh_CN.ts/zh_TW.ts 新增 MergeTranslateDialog 全量文案与 Canvas "Merge translate..."（简体"合并翻译..."/繁体"合併翻譯..."），临时 lrelease 编译 .qm 后已删除临时目录；MergeI18nTest QTranslator 断言通过；全部改动文件 py_compile 通过、git diff --check 干净；`test_merge_translate`(17)+`test_translation_split`(20)+`test_pair_scan_verify`+`test_pair_widget_interactions`+`test_region_translate_tool` 共 63 用例 OK；`test_text_transform_undo` 仅余 1 个已知基线失败（grid_modal，与本期无关）。待真机验证。

## 阶段三：页面排序与纵向拼接（G3）

### Task 10: 工程模型自定义页面顺序与兼容
- **Status**: pending
- **Priority**: high
- **Depends On**: None
- **Description**:
  - ProjImgTrans 增加可选顺序字段（JSON 顶层如 page_order），保存/加载往返；无字段时完全等同文件名字典序；新增 reorder_pages(new_order) 同步 pages 顺序映射，插入/删除页面时维护该字段。
  - 旧 JSON（含 Ballonstranslator_store 现有工程）加载零错误、顺序不变。
- **Acceptance Criteria Addressed**: AC-9, AC-13
- **Test Requirements**:
  - `rule` TR-10.1: 重排→保存→重新加载后 idx 映射顺序为自定义顺序；证据：pytest 临时工程往返。
  - `rule` TR-10.2: 无 page_order 字段的旧 JSON 加载顺序等于文件名排序且不丢页；证据：pytest（含现有 store JSON 样本结构）。

### Task 11: 页面列表拖拽排序 UI
- **Status**: pending
- **Priority**: medium
- **Depends On**: Task 10
- **Description**:
  - PageListView 开启内部拖拽重排并接 reorder_pages；切换页/RUN 队列/PageRangeProgress 选择均跟随新顺序；重排后标记工程已保存状态变化。
- **Acceptance Criteria Addressed**: AC-9
- **Test Requirements**:
  - `rule` TR-11.1: offscreen 模拟拖动换位后，pageList 顺序与工程 idx 映射、selected_pages() 切片一致；证据：pytest。
  - `rule` TR-11.2: 重开工程顺序保持；证据：TR-10.1 复用 + 真机记录。

### Task 12: 纵向拼接工具函数
- **Status**: pending
- **Priority**: high
- **Depends On**: None
- **Description**:
  - 新增纯函数：两图 numpy 纵向拼接；宽度不同以最大宽度为准补白（白/可配置填充色），输出尺寸正确；生成可辨识文件名（含两源页名与前缀，如 stitch__A__B.png），冲突策略（覆盖确认/自动改名）。
  - 仅用 numpy/PIL；不触碰原文件。
- **Acceptance Criteria Addressed**: AC-10, AC-11
- **Test Requirements**:
  - `rule` TR-12.1: 等宽两图拼接结果像素等于 vstack(A,B)；证据：pytest 数组断言。
  - `rule` TR-12.2: 不等宽时输出宽=max、高=hA+hB，补白区域等于填充色，不崩溃；证据：pytest。
  - `rule` TR-12.3: 同名冲突按策略返回覆盖或新名，不静默产生重复页；证据：pytest。

### Task 13: "拼接页面"对话框与新页面注册
- **Status**: pending
- **Priority**: high
- **Depends On**: Task 10, Task 12
- **Description**:
  - 页面列表区提供"拼接页面"入口与小对话框：选择上页/下页（默认当前页与下一页），预览顺序后执行；写新图片到工程目录、向 ProjImgTrans 注册新页（pages/image_info/顺序插入到下页之后，复用 new_pages 登记避免重扫丢失）、刷新列表并跳转。
  - 核对现有移除页面机制可移除拼接页；原两页 blocks 与图片文件不变。
- **Acceptance Criteria Addressed**: AC-10, AC-11, AC-13
- **Test Requirements**:
  - `rule` TR-13.1: 执行后磁盘出现新图，pages 含新键且位置在下页之后，当前页切到新页；原两页 blocks 与文件哈希不变；证据：pytest 临时工程。
  - `rule` TR-13.2: 末页作为下页/同名冲突等边界有明确提示不崩溃；证据：pytest + 真机记录。

### Task 14: 阶段三 i18n、全量验证与收尾
- **Status**: pending
- **Priority**: medium
- **Depends On**: Task 11, Task 13
- **Description**:
  - zh_CN/zh_TW .ts/.qm；py_compile、git diff --check、全部测试；offscreen 应用启动冒烟；交付真机走查三项功能（AC-12、AC-13）；随后进入独立 Review。
- **Acceptance Criteria Addressed**: AC-9, AC-10, AC-11, AC-12, AC-13
- **Test Requirements**:
  - `rule` TR-14.1: 全部新增/既有相关测试通过、offscreen 冒烟无异常；证据：命令输出。
  - `rubric` TR-14.2: 三功能整体融入度；1-5；1=入口隐蔽风格割裂，3=可用但突兀，5=入口自然反馈一致；阈值 >=4；证据：真机走查记录。
