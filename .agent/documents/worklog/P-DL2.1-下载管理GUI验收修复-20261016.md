# P-DL2.1 下载管理 GUI 验收修复批次（2026-10-16）

> 来源：用户 GUI 人工验证基本通过，反馈两点小毛病（截图 2 张）。
> 环境铁律：构建走 `tools/run_build_task.py`（本次 BUILD_OK，1m18s，
> pubget/analyze/build/install 全 rc=0）；测试逻辑文件沙盒内不可跑，
> 由 GUI 会话跑 `tools/run_mangrove_check.bat`。

## 修复 1：下载管理页四队列 tab 英文残留

- 现象：tab「当前/当前」之外三个队列显示英文 Past / Problems / Standby。
- 根因：`_tabLabels` 走 `.tl`，但 translation.json 里这三个键**从未登记**
  （`Current` 有、其余三个没有），`.tl` 缺键回落英文。
- 修复：zh_CN 补 `Past→历史 / Problems→问题 / Standby→待命`；
  zh_TW 补 `歷史 / 問題 / 待命`。

## 修复 2：缺页修复"浓缩任务" bug（本轮重点）

- 现象（用户实测）：修复缺页弹窗里多选章节，只创建一个浓缩版修复任务；
  当前队列切面与「下载中」弹窗出现一堆空白占位，无法看到队列。
  漫画详细页的「下载修复」老按钮同样把多章缺页并在一起，抓取图片列表
  出现验证识别错误。
- 根因（双坑）：
  1. `RepairDownloadTask.id = "repair:$comicId"` —— 整本漫画共用一个 id，
     队列/弹窗按 id 索引时同漫画的第二个任务覆盖第一个，渲染空白；
  2. 弹窗 `_createTasks` 与 `enqueue` 都是"一本一个任务、targets 跨章"，
     页级统计与回写语义跨章混杂。
- 修复（`repair_download.dart`）：
  - 新增 `chapterId` 字段；id 改为 `repair:<comicId>:<chapterId>`
    （一章一 id；旧持久化数据无 chapterId → 回退旧格式，兼容恢复）；
  - `enqueue` 按章节分组（`groupRepairEntriesByChapter`）创建**多个**
    独立任务，`addTasks` 批量入队，返回任务数；toast 改为汇总式
    「已创建 @a 个修复任务」；
  - 单章任务 title 显示「漫画名 · 章节」；
  - `toJson/fromJson` 带 chapterId（旧 JSON 缺字段走兼容路径）。
- 弹窗（`download_manager_dialogs.dart`）：`_createTasks` 改调
  `RepairDownloadTask.enqueue(silent: true)`，与按钮同一套分组逻辑，
  一本内每章一个任务。

## 修复 3：修复弹窗交互升级（用户新需求）

- **折叠动效**：`_RepairComicGroup` 由静态全展开改 `ExpansionTile`
  （默认收起，点标题行整本展开/收起，自带旋转箭头 + 高度动画；
  标题行 trailing Checkbox 负责全选/全不选，与展开收起互不干扰）。
  章节标签优先用登记的章节标题，回落目录名。
- **无缺页空态**：`showMissingRepairDialog` 不再用 toast 挡掉空态，
  空态也打开弹窗，内容区显示「无缺页」（新键
  `No missing pages to repair`）。

## 修复 4：漫画详细页「下载修复」按钮升级

- `comic_page.dart`：老按钮（一键 `repairComic` 全本）→ 打开缺页修复
  弹窗的**单漫画模式**（`showMissingRepairDialog(single: ...)`），
  只列本漫画缺页章节，勾选后每章单独建任务。
- `local_comics_page.dart` 长按菜单同款「Repair missing (@a)」一并升级
  （用户未点名，但同属"下载修复老按钮"模式，保持双入口一致；
  如不想要可回退这一处）。
- 范围区别（按用户要求）：详细页/本地页按钮只针对**所属漫画**；
  下载管理里的缺页修复/统计针对全库 + 下载管理分区的问题漫画。

## 验证

- 受控构建 BUILD_OK（含 5 个改动文件 + 新测试文件同树）。
- i18n：全 lib 扫描新键 0 缺失（Past/Problems/Standby/
  No missing pages to repair/Created @a repair task(s)/Repairing...）；
  zh_CN/zh_TW 各 1810 键。
- 新增 `test/repair_task_split_test.dart`（11 条断言）：
  分组纯函数（顺序保持/单章/空）、id 唯一性与旧格式回退、
  队列 tab 翻译键、「无缺页」键。沙盒内待 GUI 会话复跑。
- 待 GUI 验收：V2' 队列 tab 中文、V3' 弹窗多选每章一任务
  （当前队列 + 下载中弹窗各显示 N 条）、折叠动效、详细页/本地页
  二级弹窗、无缺页空态。
