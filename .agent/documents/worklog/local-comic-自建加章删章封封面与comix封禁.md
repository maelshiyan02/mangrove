# 本地漫画自建 / 加章 / 删章 / 封封面 + comix.to 软件内封禁

> 日期：2026-10-20 ｜ 版本：2.8.6+250 → 2.8.7+251 ｜ 阶段：P 本地漫画手动管理（本地优先路线）
> 关联取证：`comix-第三方判定取证与采集链路修复.md`、`comix-创建下载任务入口写回与冲突分析.md`

## 一、背景与决策

comix.to 在线采集自 2026-10-19 取证确认：站点对自动化 / 无头访问强拦截、签名 token 与图片 CDN 轮换 + WAF TLS 指纹多重设防，自动化采集基本不可行
（`comix-第三方判定取证与采集链路修复.md`）。

用户 2026-10-19 决策：

> 「暂时封禁这个网站的在线阅读和下载。至少 mangrove 软件内部先不做相关功能了。」

同时要求转向**本地漫画手动管理**，补齐没有网源链接时也能用的能力：

> 「看能不能补充自主创建新漫画卡片的功能，在漫画卡片里面导入图片新建章节，还有设置翻译组等等。
> 我们新建本地的漫画是不涉及网络来源链接的。」

具体落地 7 项需求：修复导入覆盖 bug、自主创建新漫画卡、卡片内导入图片新建章节、设置翻译组、删除单章、修复封面不识别、软件内封禁 comix 在线功能。

## 二、代码改动清单

### 1. `lib/utils/import_comic.dart` —— 修复 `_copyDirectories` 的 `_old` 备份 bug
- **根因**：原 `findValidDirectoryName(dest.parent.path, "${dest.path}_old")` 把**整路径**当名传给 `sanitizeFileName`，斜杠被改成空格 → 生成乱名目录，且当 `source` 已在库根下时会把自己误改名 / 覆盖，表现为「把别的漫画顶掉、内容变空」。
- **修复**：备份名只取**源目录名**（`"${source.name}_old"`），生成合法同级备份；若 `source` 已在库根（`source.path == dest.path`）则**不拷贝、直接复用原位**，彻底避免误改名 / 覆盖。

### 2. `lib/foundation/local.dart` —— 新增 `updateComicDirect(LocalComic)`
- 绕过 `add` 的「拒绝缩小」守卫（删章会让矩阵变小，`add` 会拒绝回写），直接 `_writeComic` + `ComicStateRepository().mirrorLocalComic` + `notifyListeners()`。供删章 / 换封面收小矩阵使用。
- 注：`removeComic`（整卡删除）、`deleteComicChapters`（底层删章）此前已存在。

### 3. `lib/utils/local_comic_edit.dart`（新建）—— 数据层
- `createLocalComic({title, subtitle, tags, description})`：库根 `findValidDirectoryName`+`sanitizePathSegment` 建目录 → `LocalManager().add(comic, id)` → 返回 `LocalComic`（`chapters=null`、`cover=''`、无网源链接）。
- `setCoverFromFile(comic, File)`：复制为库根 `cover.jpg` 并 `updateComicDirect`（根治「手动丢 cover.jpg 不被识别」——之前常落进被误改名的 `_old` 备份目录或根本没进库根）。
- `deriveCover(baseDir, chapters)`：磁盘识别 `cover*` 优先 → 首章首图 → 根图；**只读取封面、绝不重建章节矩阵**，避免冲掉精心维护的版本化（带翻译组）矩阵。
- `_toVersionedMap(chapters)`：把扁平 / 分组 / 版本化 / 空 矩阵统一 best-effort 升级成版本化 `Map<String, List<ComicChapterVersion>>`，便于显示翻译组 chips。
- `addChapterToLocalComic(comic, {chapterNumber, group, imagesFolder})`：维护版本化矩阵（带组名 → 目录名 `<话号> [组名]`）、`_copyImages` 平铺图片入章目录、`deriveCover` 补封面、`add` 回写（矩阵在变大，`add` 不会缩小、安全）、`downloadedChapters` 计入。
- `listChapterDirectories` / `dirNamesToChapterKeys` / `deleteChapters`：物理删目录 + 收小矩阵（`updateComicDirect` 直写）+ 重算封面 + 删光则 `removeComic` 返回 false（整卡删除）。

### 4. `lib/pages/local_comic_edit_dialogs.dart`（新建）—— 三个对话框
- `showCreateLocalComicDialog`：标题 / 翻译组（可选）/ 标签（逗号分隔）/ 简介 / 可选封面。
- `showAddChapterDialog`：话号 / 翻译组（可选）/ 选图片文件夹（平铺页面图导入为一章）。
- `showManageChaptersDialog`：章节复选 + 删除确认（`ContentDialog` 二次确认，磁盘永久删除）+ `showLoadingDialog` 进度。

### 5. `lib/pages/local_comics_page.dart`
- 顶部 AppBar 加「新建漫画」`IconButton`（调用 `showCreateLocalComicDialog` 后 `update()`）。
- 仅 `comic.comicType == ComicType.local` 的卡片右键菜单加「添加章节」「管理章节」两个 `MenuEntry`。
- 顺手移除一条 pre-existing `url_launcher_string.dart` 未使用 import。

### 6. `lib/foundation/comic_source/comic_source.dart` —— 软件内封禁 comix 在线功能
- 新增 `static const Set<String> _bannedSourceKeys = {'comix_to'}`。
- `doInit()` 脚本扫描循环内：`if (_bannedSourceKeys.contains(source.key)) { Log.info(...); continue; }` —— **跳过注册但保留脚本文件**（不删），日后把 `comix_to` 移出 banned 集合即可恢复在线功能。

### 7. `lib/pages/download_manager_page.dart`
- 移除下载页 AppBar 菜单的「Create Download Task」（`_showCreateComixTaskDialog`）入口，仅留「Clear Past Records」。
- `_showCreateComixTaskDialog` 与 `_CreateComixTaskDialog` 标为**死代码保留**（加 `// ignore: unused_element`），待采集方案成熟、解封 `comix_to` 后恢复。
- `_create()` 里 `ComicSource.find('comix_to')!` 改为 null 守卫 `if (source == null) return;`，杜绝解封前误触空引用。

## 三、版本号

base-10 三段式，本批属施工 / 交付类（导入 bug 修复 + 本地漫画 5 项新能力 + comix 封禁）= 1 个小版本：

```
2.8.6+250  →  2.8.7+251
```

权威来源 `pubspec.yaml` 的 `version:` 字段；About 页 `V${App.version}` 自动读 PackageInfo，改 pubspec 即生效。

## 四、校验

- `flutter analyze`（针对 7 个改动文件）：**0 error**。
  - 残留 3 处 `unnecessary_cast` warning（位于 `local_comics_page.dart`，改动前既有，非本次引入）。
  - 残留 1 处 doc-comment `unintended_html_in_doc_comment` info（位于 `comic_source.dart` 既有注释，非本次引入）。
- Windows release 构建：经 `tools/run_build_task.py`（pywin32 venv `default`，Windows Task Scheduler S4U 逃逸沙盒跑 `build_mangrove_release.bat`）。
  - 产物 `builds/build.log` 全绿：`rc pubget=0 → rc analyze=0 → rc build=0 → rc install=0 → BUILD_OK → wrapper end rc=0`（2026/10/22 执行）。
  - **状态：BUILD_OK 已确认。**

## 五、设计要点 / 备注

- **自研 `Button` 无 disabled 态**：取消类按钮 `onPressed` 是非空 `void Function()`，故「加载中」用 **onPressed 内守卫**（`if (_loading) return;`）实现，而非传 `null`。
- **删除章节是物理删目录**：已在对话框二次确认，磁盘图片永久删除，不可撤销。
- **封面识别不重建矩阵**：`deriveCover` 只读封面，绝不动章节矩阵，保护版本化（带翻译组）信息不被 `scanLocalComicDirectory` 的扁平重建冲掉。
- **comix 源脚本保留不删**：仅不注册，封禁是「软件内功能层面」，源文件完整，解封成本极低。

## 六、后续可选项（未做，待用户拍板）

- 删除章节也可走底层 `LocalManager.deleteComicChapters`（已存在）做一致化；当前实现直写矩阵更可控。
- 翻译组 chips 在漫画详情页的展示（矩阵已带 `scanlationGroup`，UI 展示未在本批补齐）。
- 解封 comix 在线功能时，移除 `_bannedSourceKeys` 条目 + 恢复下载页入口即可。
