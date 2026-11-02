# P5 · 翻译工程新建 / 绑定逻辑重构（显式归属 + 空壳工程 + 新建流程统一）

日期：2026-10-23 ｜ 版本：`2.8.13+257` ｜ 构建：`BUILD_OK`

## 一、目标（承接 P8 的「后续」）

1. **不再强依赖"已有素材 + 封面"**：空文件夹（0 页）的工程也能建出来、也能被登记、也能被归类。
2. **新建流程统一**：本地库工程段卡 / 翻译工程归类页 / 工作室菜单三处都走同一个 `createStudioProject`。
3. **工程 ↔ 漫画归属写入工程元数据**，供 P4 归类页使用，**替代 `subtitle` 隐式归类**。

## 二、根因：P4 的归类其实一直是错的（P5-2）

上一轮 P4 建了「翻译工程归类页」，页面按 `LocalComic.subtitle` 把同一本漫画的多个 `bt_` 工程并到一页。
但 `BtProjectManager._registerLocal` 里 `subtitle` 的真实来源是**工程 json 的祖父目录名**：

```
_localcomics_page.dart 无关
bt_project_manager.dart:697   final grandParent = _basename(_dirname(_dirname(jsonPath)));
bt_project_manager.dart:707   subtitle: grandParent,
```

而 `ProjectBootstrap.create` 建的布局是 `<projectsRoot>/<漫画名>-<章节名>/imgtrans_*.json`
—— 祖父目录**永远是 `projectsRoot` 自己**（"projects"）。于是：

- "同一本漫画的多个工程归到一页"实际变成了"同一个 root 下的**所有**工程归到一页"；
- 页标题显示成 `projects` 而不是漫画名。

这不是"归类规则不够健壮"，而是**归类键选错了对象**：`subtitle` 表达的是"工程目录的上一级叫什么"，不是"这个工程属于哪本漫画"。

## 三、显式归属：边车文件 `mangrove_project.json`

### 3.1 为什么不是写进 `imgtrans_*.json`（P5-1）

`imgtrans_*.json` 的**顶层键序被断言锁死**（`lib/headless_p3_checks.dart` 的 `key_order_matches_ft`
逐键比对 FT 的 `['directory','pages','current_img','image_info','page_order','chapters']`），
且工程 json 承诺"读回再存一次**零字节 diff**"。往里加一个 `comicId` 顶层键会立刻打破这两条。

⇒ 归属信息只能放在**工程目录里另一份文件**里 —— 与 `ArtifactReconciliation` 的 `.artifacts.json` 同一条思路。

### 3.2 新文件 `lib/foundation/translation_project/studio_project_meta.dart`

| 字段 | 含义 |
|---|---|
| `comicId` | 来源漫画在 `local.db` 里的 id（`cid`） |
| `comicTitle` | 来源漫画名（归类页标题 + 工程卡副标题） |
| `sourceKey` | 来源漫画的 sourceKey（网络源才有，版本化源用于区分翻译组） |
| `eid` | 绑定的章节 eid（无章节漫画恒 `'0'`） |

- 文件名刻意**不叫** `imgtrans_*` —— 否则会被工程扫描当成又一个工程登记（与 `.artifacts.json` 同类坑）。
- 读取失败（文件不存在 / 损坏 / 缺 `comicId`）**一律返回 null，不抛**：边车只是归类辅助，缺它最多让归类回落，不该让一轮扫描炸掉。
- 写入用**临时文件 + rename 原子写**（P5-4）：半截 JSON 解析失败 ⇒ 边车读成 null ⇒ 归类静默退回到要被消灭的 `subtitle` 兜底。
- 落点是**工程 json 的父目录**（= 工程根），不是 `directory`（`source/` 副本根）—— 边车描述的是"这个工程"，必须跟着工程 json 走。

### 3.3 归类键格式必须统一（P5-3）

边车存 `cid` + `sourceKey`，绑定表（`studioReaderBindings`）存 `cid@sourceKey`。
两边都经 `glossaryScopeOf(cid, sourceKey)` 拼 ⇒ **算出的键天然一致**。
于是"一个工程从『没有边车』变成『有边车』"时，同一本漫画的其它工程**不会被拆散到另一页**。

## 四、写入 / 读取链路

| 环节 | 位置 | 动作 |
|---|---|---|
| 写入 | `StudioReaderLink.ensureBinding` | 新建工程、复用既有工程、老绑定补齐 —— **三条路径都写**边车 |
| 写入时机 | 同上 | **工程创建那一刻**写，不等扫描（P4 归类要靠它，而扫描是异步的） |
| 读取 | `BtProjectManager.associationFor(project)` | 读工程根的边车 |
| 消费 1 | `BtProjectManager._registerLocal` | `subtitle` 改用**来源漫画名**（原来恒为 "projects"） |
| 消费 2 | `translation_project_detail_page._scopeOf` | 归类键：边车 → 绑定表 → 「只列自己」 |

### 4.1 `_registerLocal` 的"未变更就跳过"判据必须加上 subtitle（P5-10）

边车是**后**写的：工程建成 → 边车落盘 → 才 `scan()`。所以第一次扫描登记的行副标题还是旧值，
边车落盘后的第二次扫描**必须**能把���改成漫画名。不比这一项，这一行就永远停在旧值上。

## 五、空壳工程（0 页）—— 不再强依赖"已有素材 + 封面"

### 5.1 向导允许选没有页图的章节

`studio_project_menu.dart` 的第 2 步过去把无页图的章节 `enabled: false`（灰掉）⇒
"这一章还没有页图"的用户**没有任何出路**。现在允许选中，并在副标题与第 3 步都写明
"新建的工程将是空的"。

### 5.2 `ensureBinding` 的空章拒绝对两条链路要分开（P5-7）

阅读器开关（`studio_enqueue.dart`）拨一下就凭空多一个空工程是另一种噪声 ⇒ 该链路**继续拒**
（`'chapter-has-no-page'`）。只有向导显式传 `allowEmptyShell: true` 才放行。

### 5.3 空壳工程必须靠"有归属"证明自己不是坏文件（P5-6）

`_scan` 过去是"无封面 ⇒ 跳过"，而跳过 ⇒ 工程从工作室列表消失且无诊断。
现在判据改成 **"无封面 且 无归属边车"** 才算坏文件；有边车的 0 页工程照常登记（`cover` 记空串）。

### 5.4 空封面不能去拼 `coverFile`（P5-5）

`LocalComic.coverFile` = `File(FilePath.join(baseDir, cover))`。`cover` 为空串时
`FilePath.join(baseDir, '')` **落回 `baseDir` 本身**（那是个目录）⇒ `exists()` 为真 ⇒
后面 `readAsBytes()` 直接对着目录读，抛出来的是一句看不懂的路径错误。
`LocalComicImageProvider` 改为：`cover` 为空 ⇒ 不走 `coverFile`，直接走既有的"扫目录找第一张图"兜底。

## 六、新建流程统一（三个入口，同一条实现）

| 入口 | 位置 | 触发 |
|---|---|---|
| 本地库工程段卡 | `local_comics_page.dart`（P8 的常驻卡片） | `createStudioProject(context)` |
| 翻译工程归类页 | 本次新增的 AppBar `+` | `createStudioProject(context, presetComicId: <来源漫画 id>)` |
| 工作室 / 漫画详情页 | `StudioProjectMenu` | `createStudioProject(context, presetComicId: …)` |

- `createStudioProject` 的返回值从 `void` 改为 `StudioProjectOutcome?` ⇒ 归类页建完能就地刷新
  （"再建一个工程"建完必须立刻出现在列表里）。取消/失败 ⇒ `null`。
- 归类页的预选 id **只认边车里的 `comicId`**（P5-8）：绑定表只有 `cid@sourceKey`，
  而 `cid` 自身是否含 `@` 是未定的，从 scope 反解 `cid` 有歧义。拿不到就不预选，向导从第 1 步开始。

## 七、命名坑点（沉淀到主记忆 `MEMORY.md`）

- **P5-1 显式归属写边车，不写 json 顶层键**：`imgtrans_*.json` 顶层键序被 `key_order_matches_ft` 锁死，加键即破坏零字节 diff 契约。
- **P5-2 `subtitle` 不是漫画名**：它是工程 json 的**祖父目录名**，而工程布局 `<projectsRoot>/<漫画名>-<章节名>/` 的祖父目录恒为 `projectsRoot` ⇒ 归类会把同一 root 下所有工程并成一页、标题显示 "projects"。**归类键必须表达"属于哪本漫画"，不是"上一级目录叫什么"**。
- **P5-3 归类键格式统一**：边车与绑定表都用 `glossaryScopeOf` 拼 `cid@sourceKey`，两档回落才可能互认。
- **P5-4 边车落点 = 工程 json 父目录**：不是 `directory`（`source/` 副本根）；落错位置会在工程结构变动时丢失。
- **P5-5 空封面不能拼 `coverFile`**：`join(baseDir, '')` 落回目录本身，`exists()` 为真 ⇒ 对着目录 `readAsBytes()`。
- **P5-6 空壳靠"有归属"自证**：坏文件判据是"无封面 **且** 无归属边车"，不是单看封面。
- **P5-7 空章拒绝对两条链路分开**：向导放行（`allowEmptyShell: true`），阅读器开关继续拒。
- **P5-8 `ComicType.fromKey` 要非空串**：`sourceKey` 为 null 时按 `''` 处理（与原非空入参等价）。
- **P5-9 归类兜底宁可少列不可误并**：无边车无绑定的老工程按"只列自己"处理，不要按 `subtitle` 合并（那正是要消灭的误并）。
- **P5-10 "未变更就跳过"判据要含 subtitle**：边车后写 ⇒ 首次登记的是旧副标题，不比这一项则永远停在旧值。
- **P5-11 边车文件名避开 `imgtrans_*`**：否则被工程扫描当成又一个工程登记（与 `.artifacts.json` 同类坑）。

## 八、校验

- `flutter analyze`：**0 error**（80 issues 全是既有 info/warning；本批新增文件 `studio_project_meta.dart` 无任何告警）。
- i18n 审计 `tools/tl_key_audit.py`：**TOTAL MISSING = 0**（顺带补齐了 P4 遗留的 4 个缺失键：`翻译工程` / `该漫画下还没有翻译工程` / `未命名章节` / `@pageCount 页 · 翻译工程`）。
- Windows release 构建（pywin32 venv + S4U 沙盒）：`builds/build.log` 全绿 `BUILD_OK`，版本 `2.8.13+257`。
- `flutter test` 仍**不可在沙盒内跑**（flutter_tester WebSocket 握手失败，全部文件在 loading 阶段统一报错、`+0`），属环境限制；测试逻辑须让用户在 GUI 会话复跑。

## 九、后续

- P6：成品（`ft_`）详情与新建适配（`translated/` 刷新登记确认、成品段常驻卡导出流程、详情页差异提示）。
