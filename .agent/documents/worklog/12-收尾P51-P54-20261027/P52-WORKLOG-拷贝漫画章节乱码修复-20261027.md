# P52 · 拷贝漫画章节乱码修复（第一次告白 / dycgb）

## 1. 现象（用户报）
《第一次告白》（本地 id=`dycgb`，源 `copy_manga`）执行「网络信息刷新」后，原本正常的章节列表
变成乱码：章节标题显示为 `第39244565话` / `第44059405话` 这类被错误解析的「话号」，以及一整串
UUID 碎片（`003b54f5-31b5-…`、`fff13136-d071-…`）。这是 P51 §5.1 记载的遗留「假绿」现象的实锤。

## 2. 取证（实时库）
- `data/details_cache.db`（源缓存）**完全正确**：`copy_manga/dycgb → {默認:{uuid: 第1话 … 第64话}}`（64 话）。
- `data/local.db`（本地库）**已损坏**：`dycgb.chapters` 共 63 条，外键全部是 UUID，内 `title` 被写成
  - `第39244565话` / `第44059405话`（UUID 首段为纯数字，被当话号）；
  - 或原样 UUID（`003b54f5-…`，首段含字母，未包成 第N话）。
- 全库 12 本漫画中**仅 `dycgb`** 受影响（拷贝漫画 UUID key 专属）。

## 3. 根因
唯一写入 `第<uuid首段>话` 的代码路径是 `local_comic_edit.dart` 的 `refreshLocalComicChapters`
里的 `relabel` 循环：它对每个版本的 `chapterKey`（拷贝漫画是 UUID）调用 `chapterDisplayName(key)`，
把源站给的正确 `第N话` 标题覆盖掉。

`chapterDisplayName → splitLeadingChapterNumber` 的负向断言 `(?![0-9A-Za-z])` 只挡住了
「首段含字母」的 UUID（`003b54f5-…` 读不出 → 原样返回），却**漏掉首段纯数字的 UUID**
（`39244565-0629-…`：首段后接 `-`，不是字母数字 → 断言放行 → 读成 `第39244565话`）。
`chapterNumberValueOf`（排序/去重唯一入口）同样漏判，导致排序也曾把 UUID 首段当话号。

> 网络刷新路径（`_persistEnrichedChapters → enrichComicChapters → mergedWith`）只增不减、保留本地
> title，**不会**主动破坏；它只是把已经被「刷新章节」写坏的 title 保留了下来，所以用户在「网络信息刷新」
> 后看到乱码。

## 4. 修复（代码）
- `lib/foundation/chapter_directory.dart`
  - 新增顶层 `isUuidLike(String)`（完整 8-4-4-4-12 十六进制形态判定）。
  - `splitLeadingChapterNumber` 开头加 UUID 守卫：UUID 直接返回 null，绝不当话号。
- `lib/foundation/chapter_title_parser.dart`
  - `chapterNumberValueOf` 内联同一套 UUID 正则守卫（叶子模块不反向依赖 chapter_directory），返回 null。
- `lib/utils/local_comic_edit.dart`
  - `relabel` 循环：UUID 形态的 `chapterKey` 直接 `continue`，**保留源站给的 第N话**，不再用
    `chapterDisplayName(key)` 覆盖。

## 5. 修复（数据）
- 关 App 后备份 `data/local.db` → `local.db.bak.20261027-163715`。
- 用 `details_cache.db` 的 `uuid→第N话` 映射，重建 `dycgb.chapters` 为 versioned 矩阵：
  外键 = 数字 `1..63`（源站话号，保证升序），`title = 第N话`，`key = 原 UUID`（目录/下载/进度
  全部按 UUID 对齐，一个字节不动）。源站第 64 话本地未下载，暂不包含（用户可再次网络刷新补全）。

## 6. 验证
- `flutter analyze` rc=0；`flutter build windows --release` rc=0；`cmake --install` rc=0 → BUILD_OK。
- headless `chapter-order --comic dycgb`：**PASS**。`allLabels = 第1话…第63话`（单调不减），
  `prefixedKeys=0`，`orderViolations=[]`。`idsHead` 仍为 UUID，证明源站 key 未被改动。
- 全库 12 本 `chapter-order` 闸门：**12 passed / 0 failures**（无回归）。

## 7. 版本
`2.8.26+270 → 2.8.27+271`（pubspec.yaml）。改动只进本地 git，未推送。

---

## 8. 续修：副标题（小字行）UUID 碎片（第24话 / 第28话 等）

### 8.1 现象（用户二次报）
主标题修复（第 1–7 节）后，用户在《第一次告白》章节网格里**仍看到两格乱码**——第 24 话、第 28 话。
经核对，乱码位于**章节格子下方的小字副标题行**（翻译组/来源标识），不是主标题。该行为 UUID 碎片
（如 `-0629-11f1-b4dc-fa163e02432f`），且只出现在**部分**章节（其余章节无副标题，所以用户只注意到 24/28）。

### 8.2 根因（第二层，与主标题不同路径）
主标题乱码的根因是 `chapterNumberValueOf` / `relabel` 把 UUID 当话号（已修）。
**副标题**走的是另一条路：`chapters.dart::_chapterGroupLabel`：

```dart
if (_displayChapters.isVersioned) {
  final group = _displayChapters.scanlationGroupAt(i);
  if (group != null && group.isNotEmpty) { return ...; }
  // 🔴 旧代码在这里回退：final ref = parseChapterDirectoryName(key);
  //    —— key 是源站 chapterKey（拷贝漫画 = UUID），被当磁盘目录名解析：
  //    UUID 首段纯数字 → 当话号；尾段 `-0629-11f1-…` → 当组名 → 灰字乱码。
}
```

dycgb 是版本化漫画（`mergedWith` 写入版本矩阵，源站 chapterKey = UUID），且**每个版本都没有
`scanlationGroup`**（源没给组名）。旧逻辑在无组名时错误地用 `parseChapterDirectoryName(UUID)` 兜底，
UUID 首段纯数字的那部分章节就解析出 `-0629-…` 之类垃圾副标题；首段含字母的章节解析返回 null（无副标题），
所以只有「部分」章节显脏——正是用户看到的 24/28 两格。

### 8.3 修复（代码）
- `lib/pages/comic_details_page/chapters.dart`（`_chapterGroupLabel`）
  - 版本化章节、无翻译组时：**直接返回 `null`**（无副标题），**绝不再回退 `parseChapterDirectoryName(key)`**。
  - 仅当存在语言覆盖（`langPrefix` 非空）时返回语言标签；否则 `null` → UI 不渲染小字。
  - 这一分支对**任意** UUID 形态都安全（不再有「首段纯数字」的漏判），彻底消除副标题乱码。

> 注：`parseChapterDirectoryName` 在非版本化分支（扁平本地漫画等）仍正常使用，本修复只收紧版本化分支的兜底。

### 8.4 验证
- 代码路径推演：dycgb `isVersioned=true` + `scanlationGroupAt(i)=null`（63 章全 null）+ 无 `chapter_languages`
  覆盖（`taggedLanguages:0`）→ `_chapterGroupLabel` 对 63 章**全部返回 null** → 副标题行不渲染，无 UUID 可能。
- headless `chapter-order` 闸门复跑（2.8.28 build）：dycgb `allLabels=第1话…第63话`、`orderViolations=[]`、
  `prefixedKeys=0`、`taggedLanguages=0`、`passed=true`；**全库 12 本 + 1 合集全 PASS**（无回归）。
- 后台 GUI：用 `tools/launch_gui_task.py` 拉起（InteractiveToken 计划任务）+ `builds/ui_bg.py`（`PrintWindow`
  截图 / `PostMessage` 后台点击，不抢焦点）核验标题栏图标为新绿色设计；dycgb 章节网格的像素级截图因该本
  位于「本地」区 31 本横向列表深处、后台无法键入搜索框定位，未做单本像素核验——但副标题分支已证明为恒 null，
  乱码不可能复现。

---

## 9. 全量图标换新（用户用 AI 重绘软件图标）

### 9.1 新设计
绿色圆角卡片堆叠 + 白色十字/网格。源图 `D:\AI Coding Project Management\Mangrove\icon.png`（1024×1024 RGBA）。

### 9.2 已换清单
- `assets/app_icon.png`：用户已自替换新图（与 `icon.png` 字节一致，md5 相同）。
- `windows/runner/resources/app_icon.ico`：**EXE 内嵌图标**。原文件仅单帧 256×256；用 Pillow 从新 PNG
  重生成 **7 尺寸**（16/24/32/48/64/128/256），提取 `builds/mangrove/mangrove.exe` 内嵌图标并 ViewImage
  确认 = 新绿色卡片设计（满足「`mangrove.exe` 的图标也要是新的」）。
- `assets/app_icon.ico`：资产 ICO，同步重生成 7 尺寸。

### 9.3 未核验（本项目 Windows-only，可暂缓）
- macOS `macos/Runner/Assets.xcassets/AppIcon.appiconset/`（16/32/64/128/256/512/1024.png）。
- `lib/.../launcher_icon.dart` 内变体预设（`mangrove_original/user_logo/new_logo2/3`，启动图标选择器可选项，非默认）。
  用户要求「全部更换」，Windows 端已毕；macOS/变体待确认是否需跟随新设计。

### 9.4 版本
`2.8.27+271 → 2.8.28+272`（pubspec.yaml）。改动只进本地 git，未推送。

## 10. 交付清单（本轮）
- 修复：`lib/pages/comic_details_page/chapters.dart`（副标题不再解析 UUID）。
- 图标：`windows/runner/resources/app_icon.ico`、`assets/app_icon.ico`（7 尺寸重建）。
- 版本：`pubspec.yaml` 2.8.28+272。
- 验证：headless `chapter-order` 12 本 + 1 合集全 PASS；exe 图标提取确认新设计。
- 未提交：本地 git 待 `git add` + `git commit`（不推送），包含上述 + P52 第 1–7 节全部改动。
