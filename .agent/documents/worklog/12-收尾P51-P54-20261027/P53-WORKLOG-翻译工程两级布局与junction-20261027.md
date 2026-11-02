# P53 · 翻译工程 = 另一种类型的漫画（漫画级根 → 章节级工程）

**日期**：2026-10-27　**版本**：`2.8.29+273`（承接 P52 `2.8.28+272`）
**需求方**：用户五点勘误（原文见文末）

---

## 〇、勘误记录（这一版的起点）

前一版把 P53 做成了「**整本一个**工程」（一章都不选，建工程时把整本一起收进来、
绑定键换成 `eid='0'`、向导删掉选章那一步）。用户明确纠偏：

> 「首先你搞清楚中文漫画不会用于新建翻译工程，其次创建翻译工程的步骤没问题，
> 只是最终的逻辑变成生成的都归类到翻译工程所属的以漫画为主题而不是以章节为
> 主题的情况。但是没有叫你创建翻译工程就强行把整本漫画一起翻译创建。我们最终
> 还是单个章节单个章节的选择的。」

⇒ **仍然一章一章地建**；变的只是「建完之后归到哪本书下面」。
前一版的代码（整本 plan / `wholeComicEid` / 绑定键改写 / 向导去选章）已全部回退。

---

## 一、五点勘误 → 实现落点

| # | 用户要求 | 实现 |
|---|---|---|
| 1 | 生成的图标 logo 用新图标 | `pubspec.yaml` 的 `flutter_launcher_icons.image_path` 从旧图 `assets/new_logo.png` 改为 `assets/app_icon.png`；重跑 FLI + Pillow 重建 7 尺寸 ico |
| 2 | 工程不再复制原件，`source/` 给"导向原件的快捷方式"；记录表要记链接关系 | `ProjectBootstrap.linkSource`（Windows `mklink /J`，其它平台 `ln -s`，失败才回落复制）；`StudioProjectMeta.originalPath` 记原件真实目录；**封面例外**（复制，因为卡片在素材漫画被删后会变空白） |
| 3 | 详情页要和普通漫画一样，章节区列的是翻译工程 | `TranslationProjectDetailPage` 不再自绘 UI，直接用 `ComicPage`（普通漫画详情页那套）；章节区列的是**已有工程的章节**（章节键 = 源章节目录名） |
| 4 | 翻译工程能进合集，和原漫画放一起 | 工程卡是 `ComicType.local` 记录 ⇒ 天然可入合集；合集成员点 `bt_` 卡走 `ComicPage` |
| 5 | 漫画级下面要多一层章节级（`109[violet scans]` 那一层） | 布局改成两级：`<projectsRoot>/<漫画名>/<章节键>/` |

> 附：用户点出「中文漫画不会用于新建翻译工程」—— 本批**未**加语言过滤（判据不可靠），
> 但验证一律用非中文漫画（`The Perks of Being a Villainess` / `The Runaway Extra…`）。

---

## 二、数据模型（P53 定稿）

```
<ComicLibrary>/
  downloads/<漫画>/                       ← 原件唯一一份（只读）
  projects/<漫画名>/                      ← 漫画级根 = 一张卡 = 一本漫画
      mangrove_project.json               ← 边车 level=comic（comicId/comicTitle/sourceKey/originalPath/cover）
      cover.jpg                           ← 从素材漫画复制的封面（借用）
      <章节键>/                           ← 章节级工程（如 "109 [Violet Scans] [comix.to]"）
          mangrove_project.json           ← 边车 level=chapter（+ eid/originalPath）
          imgtrans_<名字>.json             ← 真正的工程（页键带章节前缀）
          source/                         ← 【junction】→ downloads/<漫画>
          inpainted/ mask/ result/        ← 产物（只写这里）
```

- **章节键 = 源章节目录名**：它同时是阅读键、工程子目录名、详情页章节列表的键。
  三者同一个字符串，才不会"详情页第 109 话点开却是第 108 话的工程"。
- **一张卡 = 一本漫画**：`BtProjectManager._registerComicLocal` 按漫画级根登记
  一条 `LocalComic`（封面/标题/简介/标签**借用素材漫画**，章节 = 已有工程的章节）。
- **点章节 = 进工作室**：`comic_details_page/actions.dart::read` 见到 `bt_` 前缀
  就分流到 `TranslationStudioPage`（复合多重显示），不进图片扫描阅读器。

---

## 三、为什么不复制也安全

`TextInpainter.erase` **只写** `project.workspace/inpainted`，读 `project.directory`。
`directory` 现在是 junction（指向原件）⇒ 原件**只被读取**。产物写在工程自己的
`inpainted/mask/result` 里，删工程也删不到原件。

删工程时额外做一步：`comic_deletion.dart::unlinkSourceLink` **先摘链接再删目录**
（两级都要摘：`<根>/source` 与 `<根>/<章节>/source`）。实测 Dart 的
`deleteSync(recursive: true)` 不穿透 junction，但那是实现细节不是契约。

---

## 四、改动清单

| 文件 | 改了什么 |
|---|---|
| `pubspec.yaml` | FLI 图源改成 `assets/app_icon.png`（生成图标回退的根因） |
| `foundation/translation_project/studio_project_meta.dart` | 边车加 `level`（comic/chapter）、`originalPath`、`cover` |
| `foundation/translation_project/project_bootstrap.dart` | `create(parentName:)` 落两级；`ensureComicRoot`（漫画级根 + 封面）；`linkSource`（junction）；`planComic`（含 `cover/` 不是章节的修正）；`_existingProjectJson`（同名工程复用） |
| `foundation/translation_project/studio_reader_app.dart` | `StudioReaderTarget.comicName`；`ensureBinding` 先建/复用漫画级根再落章节工程；`_existingComicRootName`（按 `cid@sourceKey` 认领已有根）；章节级边车 |
| `foundation/bt_project/bt_project_manager.dart` | 扫描按漫画级根分组；`_registerComicLocal`（一张卡 = 一本）；`chapterKeysOf/chapterProjectId/chapterProjectFor`；`comicRootForJson`；跳过 `_` 开头备份目录；`createFromDownload(comicName:)` |
| `foundation/comic_deletion.dart` | 删工程前摘两级 `source` 链接 |
| `foundation/appdata.dart` | `flushImplicitData()`（headless 落盘等待） |
| `pages/comic_details_page/actions.dart` | `bt_` 卡点章节 ⇒ 工作室 |
| `pages/translation_studio/translation_project_detail_page.dart` | 改成"就是 `ComicPage`" |
| `pages/translation_studio/studio_project_menu.dart` | 向导名字建议改成**漫画名**（不带章节） |
| `lib/headless_p53_migrate.dart`（新） | `migrate-nested`：平铺工程搬进两级 + 边车/封面/json `directory`/绑定归位；默认 dry-run |
| `lib/headless_p53_relink.dart`（新） | `project-relink`：老工程的 `source` 副本 ⇒ junction（页对不上就跳过；副本改名备份不删） |
| `lib/headless_p53_layout_check.dart`（新） | `project-layout-check`：真实库上核验「卡 → 章节 → 工程 → 原件」 |
| `lib/headless_p53_create_check.dart`（新） | `project-create-check`：走向导同一条 `ensureBinding`，核验创建落点 |
| `lib/headless_p3_checks.dart` | 3b 组从"复制"改成"链接 + 两级布局"（7 条新断言） |

---

## 五、验证（证据）

| 闸门 | 结果 |
|---|---|
| `bootstrap-check` | **PASS (39)**：新增 `link.source_is_a_link_not_a_copy` / `link.no_page_bytes_copied` / `link.pages_readable_through_link` / `link.directory_is_source_not_downloads` / `layout.chapter_project_nested_under_comic_root` / `layout.comic_root_sidecar_and_cover` / `layout.chapter_sidecar_is_chapter_level` / `layout.reuses_existing_json_with_other_name`，每条都"绿路径=true 故障路径=变红" |
| `project-layout-check`（真实库） | **PASS (13)**：两张卡、封面借用、章节=工程、`source` 是 link、页可读、边车层级 |
| `project-create-check`（真实库，走向导同一条函数） | **PASS (7)**：json 落在 `<根>/<章节键>/`、两级边车、封面借用、**每章只有一份 json** |
| `chapter-order`（回归） | **PASS**：13 本 + 1 个合集 |
| GUI 截图 | 首页「翻译工作室」分区 = **2 张卡**（封面是素材漫画的封面，卡上带 `109` / `1` 章节徽标） |

### 本机数据迁移结果（真实工程）

| 工程 | 迁移前 | 迁移后 |
|---|---|---|
| 做个恶女好安逸（109 话） | `projects/做个恶女好安逸/imgtrans_做个恶女好安逸.json`（平铺，`source` 是 junction） | `projects/做个恶女好安逸/109 [Violet Scans] [comix.to]/…` + 漫画级边车 + `cover.jpg` |
| The Runaway Extra…（1 话） | `projects/The Runaway Extra…/`（平铺，`source` 是 **28MB 副本**） | `projects/The Runaway Extra…/1 [Rokari Comics] [comix.to]/…`，`source` 改成 junction，副本改名留在 `source.bak_20261027-204055`（**用户可自行删除**，删掉即回收 28MB） |

---

## 六、遗留 / 待用户确认

1. **`source.bak_20261027-204055`（28MB）**：转链时按"备份优先"改名保留，确认无误后由用户删除。
2. **GUI 点击核验未完成**：本机当前会话里 Flutter 收不到后台投递的鼠标消息
   （`PostMessage`/`SendMessage`、先发 `WM_MOUSEMOVE`、甚至补发 `WM_ACTIVATE` 都试过，
   页面不动；规则又不允许动真鼠标/抢焦点）。因此"详情页长什么样"只有
   **代码路径 + 真实库断言**作证，没有点击后的截图。麻烦用户手动点一下确认：
   翻译工作室 → 做个恶女好安逸 → 应看到与普通漫画同样的详情页，章节区列 `第109话`。
3. **老工程 json 的文件名**仍是老名字（`imgtrans_做个恶女好安逸.json`）而目录是章节键。
   已加"同名工程复用"保证不会重复建；统一改名留给后续（改 json 名会牵动对账表与绑定）。
4. 中文漫画过滤未做（用户提过"中文漫画不会用于新建翻译工程"，但可靠判据缺失）。

---

## 七、用户原话（五点勘误）

> 「首先你搞清楚中文漫画不会用于新建翻译工程，其次创建翻译工程的步骤没问题，只是
> 最终的逻辑变成生成的都归类到翻译工程所属的以漫画为主题而不是以章节为主题的情况。
> 但是没有叫你创建翻译工程就强行把整本漫画一起翻译创建。我们最终还是单个章节单个
> 章节的选择的。」
>
> 「不要再用这种页面了，我要的详细页就是和普通漫画一样的这种，只不过下面的章节显示的
> 是翻译工程，而不是普通漫画。所以创建工程不单单是命名工程，还有配套的封面和详细
> 信息，我之前就说了这些都是借用已有漫画的。」
>
> 「翻译工程可以加入到合集中和对应原漫画放在一起。」
>
> 「参考 project 的情况，现在应该是在漫画翻译工程级别下面再多一个章节翻译工程级的
> 才对……正常这里要多一个 109[violet scans] 的层级。」
>
> 「我的意思很明确翻译工程的创建和漫画的保存逻辑是已有的。翻译工程就是另一种类型
> 的漫画，只不过两者使用的阅读器不同。普通漫画用图片扫描器就可以，但是翻译工程要走
> 复合多重显示。」
