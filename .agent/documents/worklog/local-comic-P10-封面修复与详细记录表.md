# P10 · 自定义封面修复 + 模式切换按钮 + 详细记录表（用户验收反馈）

日期：2026-10-24 ｜ 版本：`2.8.16+260` ｜ 构建：`BUILD_OK`

## 一、背景（用户人工验收发现的一组问题）

1. **Bug（核心）**：用户自建的本地漫画（「新建漫画」+ 导入章节生成）在详情页点「更换封面 / Custom Cover」**失败**。判断"大概率是我们创建新漫画和一些代码没有做好适配"。
2. **不要隐藏模式切换按钮**：本地漫画（自己创建、非网站源生成记录）的详情页，**不要故意隐藏"本地模式 / 网络模式"切换按钮**——只是记录表里没有相关基础章节信息记录罢了，该按钮仍是有效的视图控制（隐藏未下载章节），应正常显示。
3. **配置"详细记录表"（新功能）**：为本地漫画补齐可自定义元信息，用户可自行设置：作者、更新时间、来源、标签、进度（上次阅读进度）、描述，及更多可编辑项；按字体大小，封面右侧**最多约 8 个漫画信息字段**。

## 二、根因 #1（封面 bug）— 误用 BtProjectManager 管本地漫画封面

- **根因**：`actions.dart` 与 `cover_viewer.dart` 的 `_setCustomCover` 都调 `BtProjectManager().setCover(comic.id, bytes)`。但 `BtProjectManager.setCover`（bt_project_manager.dart:319）只管**翻译工程**：内部 `ensureProject(comicId)` 对本地漫画 id（无对应翻译工程）**返回 null → 必然失败**，报 "Failed to set cover"。本地漫画的封面从来就不该走翻译工程那条链路。
- **修复**：两处都改为
  `LocalManager().find(comic.id, ComicType.local)` 取本地记录 → `setCoverFromFile(localComic, File(result.path))`（写库根 `cover.jpg` + 回写本地记录）→ `LocalComicImageProvider(updated).evict()` 清缓存 → 刷新 / 关闭封面查看页。
  - `lib/pages/comic_details_page/actions.dart::_setCustomCover`（约 949 行）
  - `lib/pages/comic_details_page/cover_viewer.dart::_setCustomCover`（约 155 行）

## 三、根因 #2（二次 bug）— 换封面 / 改信息后 UI 不刷新

- **根因**：`refreshLocalComic()` 原只更新 `_localComic`，不重建 `data`（ComicDetails）。而详情页的封面 / 章节 chips / 右侧信息区都读 `data`（只在 `loadData` / `_localDetails` 时构建一次），导致换封面、改信息后界面"看起来没变"。
- **修复**（`lib/pages/comic_details_page/comic_page.dart::refreshLocalComic`，约 333 行）：在更新 `_localComic` 后，用最新记录重建 `data = _localDetails(refreshed, ...)`，再 `update()`。封面与右侧信息同步刷新。

## 四、模式切换按钮 — 本地漫画也显示

- **修改**（`lib/pages/comic_details_page/comic_page.dart`，约 1172 行）：显示条件由 `if (comicSource != null)` 改为 `if (comicSource != null || _localComic != null)`。本地漫画（有本地记录）也给出"网络/本地显示模式"切换按钮，由用户自行切换视图。
  - 注释同步更新为 P10 说明（P3 当时误以为本地漫画无网络模式可言而隐藏，本次纠正）。

## 五、详细记录表 — 本地漫画自定义元信息

### 5.1 数据层（lib/foundation/local.dart）
- `LocalComic` 新增字段（默认空串）：`source`（自定义来源标签，如 "Rokari Comics"）、`updateTime`（自定义更新时间，自由文本）。
- `fromRow` / `toJson` 同步新增这两个字段。
- `_writeComic` 的 SQL 增加 `source`、`update_time` 两列。
- `_ensureSchema` 新增**幂等 ALTER**：`ADD COLUMN source TEXT NOT NULL DEFAULT ''` 与 `ADD COLUMN update_time TEXT NOT NULL DEFAULT ''`（旧库自动迁移，不会炸）。
- `_localDetails`：JSON map 的 `'updateTime'` 由 `null` 改为注入 `localComic.updateTime`（本地漫画更新时间进入 ComicDetails，右侧信息区可显示）。
- `_buildComicSummary` 的 `badge` 优先用本地自定义来源：`_localComic?.source.isNotEmpty == true ? _localComic!.source : ComicSource.find(comic.sourceKey)?.name`。

### 5.2 编辑信息对话框（lib/pages/local_comic_edit_dialogs.dart）
- 新增 `showEditLocalComicInfoDialog(BuildContext, LocalComic)` 与 `_EditLocalComicInfoDialog`。
- 字段（六个 `TextEditingController`，`initState` 从 `widget.comic` 预填）：
  标题（漫画名）/ 作者 / 翻译组（可选）/ 来源（可选，如 Rokari Comics）/ 更新时间（可选，自由文本）/ 标签（逗号分隔，可选）/ 简介（可选）。
- 保存：构造完整 `LocalComic`（保留 `chapters/cover/directory/downloadedChapters/createdAt`，赋值 `source/updateTime/description/tags/subtitle`），调 `LocalManager().updateComicDirect(updated)` 后 `Navigator.pop(context, updated)`。
- 详情页 `showMoreActions` 本地漫画分支展开为两个菜单项：`Custom Cover` 与 `Edit Info`（后者调 `showEditLocalComicInfoDialog`）。

### 5.3 封面右侧信息字段（已有能力，本次点亮）
- `ComicDescription`（comic.dart:1240）在封面右侧渲染信息行：作者、来源 badge、标签、更新时间、描述、进度（上次阅读进度，由 history 自动提供）等。可见行数受高度预算限制（固定高度 tile 最多约 5+extra 行；详情页无限高度全部显示）。
- 本次本地漫画补齐 `source`/`updateTime`/`description`/`tags` 后，右侧"最多约 8 个字段"的信息区对本地漫画同样可用；**"进度"行本就由阅读历史自动渲染，无需新增独立字段**。

## 六、i18n 收尾
- `assets/translation.json` 补登 7 个缺失键（zh_CN = 源串、zh_TW = 繁体）：`Edit Info` / `编辑信息` / `标题（漫画名）` / `作者 / 翻译组（可选）` / `来源（可选，如 Rokari Comics）` / `更新时间（可选，自由文本）` / `请填写标题`。

## 七、坑点（沉淀到主记忆 `MEMORY.md`）
- **P10-封面根因**：本地漫画封面必须用 `LocalManager` + `setCoverFromFile`，**绝不能再调 `BtProjectManager().setCover`**（后者只管翻译工程，本地 id 必失败）。
- **P10-刷新必重建 data**：`refreshLocalComic()` 只更新 `_localComic` 不重建 `data` 会导致 UI 不刷新；换封面 / 改信息后必须 `data = _localDetails(refreshed, ...)` 同步。
- **P10-模式按钮不藏本地漫画**：本地漫画（有 `_localComic`）也应显示网络/本地显示模式切换，条件 `comicSource != null || _localComic != null`。
- **P10-本地漫画自定义字段落点**：`source`/`updateTime` 走 `LocalComic` 字段 + DB 幂等 ALTER；`description`/`tags` 复用既有字段，由"编辑信息"对话框统一写入 `updateComicDirect`。进度行由 history 自动提供，不重复造字段。

## 八、校验
- `flutter analyze`：**0 error**（上次已全绿；本次新对话框删除未用 `cs` 变量后无新增 warning）。
- i18n 复扫：0 缺失。
- Windows release 构建（pywin32 venv + S4U 沙盒）：`builds/build.log` 全绿 `BUILD_OK`，版本 `2.8.16+260`。

## 九、后续
- 本地漫画手动管理能力（自建 / 加章 / 删章 / 换封面 / 编辑信息 / 刷新）已闭环。
- "进度（上次阅读进度）"由阅读历史自动渲染，无需额外自定义字段；若用户后续要"手动标注进度"，再单独评估。
