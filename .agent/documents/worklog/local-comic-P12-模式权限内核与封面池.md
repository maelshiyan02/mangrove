# P11–P13 施工记录 · 模式权限内核 / 封面池 / 章节显示名

> 日期：2026-10-24 ｜ 版本：`2.8.17+261`（上一版 `2.8.16+260`）
> 上游决策：`local-comic-P11-本地库重构开工与comix全量下载.md` 里 D1~D4 全部选 A
> 构建验证：三次 `python tools/run_build_task.py` 全部 `BUILD_OK`（analyze/build/install rc 均 0）

---

## 一、这次实际交付了什么

用户拍板「按建议做」，即：
D1 章节目录带源站 / D2 模式开关改 per-comic / D3 封面语义命名 / D4 覆盖表单表 KV。
三者按 **P11 模式内核 → P12 封面池 → P13 章节显示名** 的顺序落地。

| 阶段 | 内容 | 主要落点 |
|---|---|---|
| **P11** | 覆盖表 + per-comic 显示模式 + 三层合并读取 + 覆盖编辑对话框 | `comic_field_overrides` 表 · `comic_override_store.dart` · `comic_override_dialogs.dart` |
| **P12** | 封面池（`cover/` + `[cover]season(N)`）+ 选封面对话框 + 不再被当章节 | `cover_pool.dart` · `cover_picker_dialog.dart` · 扫描器/刷新/deriveCover 三处跳过 |
| **P13** | 章节显示名清洗（key 不动，只改 title） | `chapterDisplayName()` · 扫描器 · `refreshLocalComicChapters` |

---

## 二、P11：覆盖层（本地自定义盖在网络信息壳上）

### 2.1 数据表

```sql
CREATE TABLE IF NOT EXISTS comic_field_overrides (
  comic_id   TEXT NOT NULL,
  field_key  TEXT NOT NULL,
  value_json TEXT,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (comic_id, field_key)
);
```

三个设计决定，都有明确理由：

1. **为什么单独一张表**：`comics` 表存的是网络同步来的字段。用户改名后直接回写
   `comics`，下一次刷新元数据就被网络值冲掉——本地改动凭空消失。覆盖值单独存，
   读取时三层合并：`覆盖值 > 网络值 > 兜底`。
2. **为什么 KV 而不是每类信息一张专表**：需要覆盖的字段会随阶段推进不断变多
   （P12 加封面、P13 加章节命名、后面还会加阅读偏好）。KV 一张表加一个常量 key，
   免迁移。
3. **为什么故意不加外键**：本地漫画在 `mirrorLocalComic` 落库之前就可能被编辑，
   加外键会让那次写入静默失败（`PRAGMA foreign_keys=ON`）。孤儿行由删除时显式清理。

`schemaVersion` 4 → 5（`_schemaSql` 全是 `IF NOT EXISTS`，旧库直接补表，无需迁移脚本）。

### 2.2 per-comic 模式

- 旧：`appdata.settings['comicDisplayLocalMode']` 是**全局**开关，5 个页面在用。
- 新：值存 `comic_field_overrides.display_mode`（`network` / `local`），
  **未设置过的本子回落到全局值**——全局开关降级为"默认值"，仍留在系统设置里。
- 语义也升级：不再只是"章节列表要不要隐藏未下载"，而是**信息权限**
  （网络模式看源头内容，本地模式看已下载 + 自定义）。

新增 `ComicOverrideStore.comicIdOf(sourceKey, sourceComicId)`：UI 手里只有
`comic.id`（= 源侧 sourceComicId），覆盖行必须挂在域库主键
（`remote:comix.to:11522449`）上——同一作品在不同平台是不同 `comic_id`，
各自的覆盖互不干扰。

### 2.3 合并发生在哪

`_ComicPageActions.overlayLocalOverrides(raw)`，**只在 `buildContent` 入口调一次**：

```dart
Widget buildContent(BuildContext context, ComicDetails data) {
  data = overlayLocalOverrides(data);   // 只影响渲染
  ...
}
```

这样下面的下载/阅读/收藏仍用原始 `data`（要的是源侧 id 与真实章节结构，
不是被改过的展示文案）。局部变量遮蔽参数，改动面最小。

只覆盖 `title` / `subtitle` / `description` 三项（P11 范围）。`cover` 归 P12 的封面池管。

### 2.4 写入口

`showComicOverrideDialog`：**本地模式 + 网络漫画**才出现（`Icons.edit_note`）。
每项都显示「网络原文」作为 helperText，并带「全部恢复原文」。

一个细节：保存时若某字段与网络原文一致，写 `null`（= 清除覆盖）而不是写同值。
否则"我改了一下又改回去"会留下一条无意义覆盖行——以后网络侧更新标题，
用户会莫名看到旧标题，还以为自己被改过。

---

## 三、P12：封面池

### 3.1 目录约定

```
<漫画目录>/
  cover/
    [cover]season(1).jpg
    [cover]season(2).jpg
  cover.jpg                ← 旧布局，继续支持（兼容回退）
  1 [Rokari Comics] [comix.to]/
```

排序：`coverSeasonOf()` 读季度号，**季度从新到旧**；读不出季度号的（贺图/特典）
排后面按文件名。默认封面 = 季度号最大的那张。

### 3.2 三条路径都必须跳过 `cover/`

这是这次最容易漏的地方——`cover/` 是个有图的子目录，三个地方都会把它当章节：

| 位置 | 漏掉后的症状 |
|---|---|
| `scanLocalComicDirectory` | 导入后详情页多一个叫 "cover" 的章节 |
| `refreshLocalComicChapters` | 点一次"刷新章节"就长出这个假章节 |
| `deriveCover` 的"首章首图"兜底 | 可能把封面图当成某章的第 1 页 |

统一走 `isCoverDirectoryName()`（`chapter_directory.dart`），三处都调它。

### 3.3 不能无脑重算封面

`deriveCover` 原本在**加章 / 删章 / 刷新章节**三条路径上都会被调用，每次都重算。
后果：用户从池里挑了 `season(1)`，只要加一章就被打回 `season(2)`——
这种"改了又自己变回去"的 bug 极难归因。

新增 `_deriveCoverKeepSelection()`：旧封面文件还在就保留，只有失效（那季被删）
才重算。三条路径统一走它。

---

## 四、P13：章节显示名

**只改显示，不动 key。** `LocalComic.chapters` 是 `Map`：key = 目录名（读图时的
路径来源），value = 显示名。改名就等于把已下载的图弄丢，所以：

```
`49 [Rokari Comics] [comix.to]`  →  第49话 · Rokari Comics
`116 [comix.to]`                 →  第116话        （方括号里只有源站，不算组名）
`12.5`                           →  第12.5话
`默認` / `番外`                   →  原样            （不是数字开头，别硬套）
```

源站标签的判据是"带点的域名形状"（`^[\w-]+(?:\.[\w-]+)+$`），有空格的一律当组名。
读者关心"谁翻的"，不关心"从哪抓的"——但目录名里保留源站（同话不同源各自成目录）。

`refreshLocalComicChapters` 里加了 `relabeled` 标记：显示名有变化时即使没有新章节
也要写回，否则"这次刷新只改了内存 map，磁盘还是旧标题"。

---

## 五、踩的坑（都花了时间）

1. **🔴 构建工装 python 不是默认 python**：`python tools/run_build_task.py` 会
   `ModuleNotFoundError: win32com`。有 pywin32 的是
   `C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe`。
   （`envs/summonerlens` 只有 duckdb/pandas，`py -3.12` 只有 requests/websockets。）
2. **`part of` 文件里加 import 要加到宿主文件**：`chapters.dart` / `actions.dart`
   都是 `part of 'comic_page.dart'`，往它们里写 `import` 直接语法错误。
3. **`.tl` 扩展不在 `foundation/app.dart`**，在 `utils/translations.dart`。
   新对话框只 import 了 app.dart → 9 条 `undefined_getter`。
4. **`context.colorScheme` 是项目扩展**，在 `foundation/context.dart`。
5. **🔴 手抄 `LocalComic(...)` 构造会静默丢字段**：`setCoverFromFile` 抄的时候漏了
   `source` / `updateTime`——用户先"编辑信息"填了来源和更新时间，再换一次封面，
   这两个字段被清空。已抽出 `_copyLocalComicWith()` 统一处理。
6. **脚本里 `Edit` 重复插入**：一次编辑把同一个函数写了两遍（`selectCoverFromPool`），
   编译器只报"重复定义"，但注释被吃掉更隐蔽。改用行号级 Python 删除修正。

---

## 六、验证记录

| 轮次 | 结果 | 说明 |
|---|---|---|
| 1 | `BUILD_FAIL` analyze rc=1 | 9 条 `.tl` undefined_getter（缺 translations import） |
| 2 | `BUILD_OK` | P11 |
| 3 | `BUILD_FAIL` analyze rc=1 | 4 条 `colorScheme` undefined_getter |
| 4 | `BUILD_OK` | P12 |
| 5 | `BUILD_OK` | P13 |

i18n：`assets/translation.json` zh_CN / zh_TW 各 +13 条，两侧 1919 键完全对齐（缺键 0）。

---

## 七、没做的（明确边界）

- 封面池的**增删改界面**：现在靠用户在资源管理器里放图，程序只读。够用，先不做。
- 从章节里挑一张当封面（章节缩略图模式）：按开场白明确延后。
- `tags` / `author` / `status` 的覆盖：表里已有 key，UI 只开了标题/副标题/简介三项。
- 覆盖层的**网络刷新冲突提示**：现在网络值变了不会提示"你有本地覆盖"。等有实际痛感再加。

---

## 八、下一步

1. `--restart-each` 逐章下载跑完（46 章 × ~5min），跑完核查每章页数 vs `nodes`。
2. Ch.2 是上次中断的残留（12 页）、Ch.3 缺 1 页 → 新代码已能自动识别残留并重下，
   等主任务跑完后单独补这两章。
3. P14：本地库目录治理（建文件夹交互 + 落盘）。
