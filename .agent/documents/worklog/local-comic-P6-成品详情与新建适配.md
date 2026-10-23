# P6 · 成品（`ft_`）详情与新建适配

日期：2026-10-23 ｜ 版本：`2.8.14+258` ｜ 构建：`BUILD_OK`

## 一、背景

本地库三段（素材 / 工程 / 成品）在 P3/P4/P5 之后都各自能用了，但**成品**这一段一直
是"半条链路"：

| 环节 | 状态 | 问题 |
|---|---|---|
| 导出（工程 → `translated/`） | ✅ `FinishedExport.publish` | —— |
| **成品登记进 `local.db`** | ⚠️ 只在**导出那一刻** | 换设备 / 重装软件 / 误删记录后，磁盘上成品还在、库里却没了 |
| 成品与原版合成"一张卡两个页签" | ⚠️ 导出流程**没传** `sourceComicId` | 凑不出第二个成员 ⇒ 不建集合 ⇒ 成品成了一张孤立的卡 |
| 成品详情页 | ⚠️ 与素材/工程**完全同款** | 用户以为成品还能加章、还能建工程 |

P2 的代码注释里就留着这笔账：
> `projects/`（工程）与 `translated/`（成品）不在此处理：前者交给 `BtProjectManager.scan`，
> **后者留待 Phase 6 统一适配 `ft_` 前缀与成品详情。**

## 二、刷新登记 `translated/` → `ft_` 成品卡

新增 `lib/utils/local_comic_edit.dart` 的 `registerUnlistedProductFolders()`，
并接进本地库页的刷新按钮（`local_comics_page.dart`）。

- 根目录 = `<ComicLibrary>/translated`（`downloads/` 的**兄弟**，不是它自己）。
- 每个子目录登记成一张 `ft_` 卡，**标题**沿用导出口径 `FinishedExport.titleFor(名)` = `X · 翻译版`，
  **标签** `['Translated']`，与 `FinishedExport._register` 完全一致 ⇒ 刷新出来的卡
  与导出时登记的那张长得一模一样。
- 已有记录 ⇒ **刷新**它（成品可能新增了章节），不算"新登记"。

### 2.1 id 必须与导出时逐字节一致（P6-1）

id = `FinishedExport.idFor(目录绝对路径)`，而导出时算的是
`Directory('<translatedRoot>/<漫画名>').path`。

🔴 刷新这一侧必须用**同一个函数**、**同一个路径形态**（`Directory.path`，Windows 上是
反斜杠；`idFor` 自己只做 `toLowerCase()`，**不归一化分隔符**）。算出来的 id 差一个字符，
成品就会在库里变成**两张卡**（导出登记的那张 + 刷新补登记的这张）—— 而用户看到的是
"同一个成品出现了两次"，且删哪张都不对。

### 2.2 `rejectExisting: false`

与 `FinishedExport._register` 同一条理由：成品与素材同名是正常的（`X · 翻译版`），
不能被扫描器的重名守卫挡下。

## 三、导出流程补 `sourceComicId` —— 成品与原版合成一张卡

`FinishedExport.publish(sourceComicId:)` 这个参数**一直存在**，但本地库的导出流程
**从来没传过** ⇒ `_ensureCollection` 只凑得出一个成员 ⇒ `members.length < 2` ⇒
不建集合 ⇒ "原版 / 翻译版"两个页签这个设计等于没上线。

- 传什么：P5 的**显式归属边车** `mangrove_project.json` 里的 `comicId`
  （`StudioProjectMeta.readFromProjectDir(工程 json 的父目录)`）。
  ⇒ P5 的归属信息在这里第一次被**真正用上**，而不是只用来归类。

### 3.1 `_ensureCollection` 找来源漫画必须按 id，不能按 `ComicType.local`（P6-2）

原实现是 `LocalManager().find(sourceComicId, ComicType.local)`。
🔴 但从网络源（comix.to 等）下载到本地的漫画，`comic_type` 是**源类型整数**
（例如 `496108553`），**不是 0** ⇒ `find(..., local)` 永远找不到它 ⇒ 即便传了
`sourceComicId`，网络漫画的成品**依然凑不出第二个成员**。

改为按 **id** 遍历本地库查找（不按 comicType）。这与 `StudioReaderLink.locate`
的注释是同一条教训：**类型要从 sourceKey 重建，不能写死 local**。

## 四、成品详情页的差异提示

### 4.1 判据：id 前缀，不是 `comicType`（P6-3）

`comic_page.dart` 新增 `_isProduct` = `comic.id.startsWith(FinishedExport.idPrefix)`。
与 `comic_card_kind.dart` 的三分法同源。**不看 `comicType`** —— 成品的
`comic_type` 也是 `local`，拿它判会把真正的本地素材一起算成成品。

### 4.2 两处入口对成品关闭

| 位置 | 处理 | 理由 |
|---|---|---|
| AppBar「创建翻译工程」（`StudioProjectMenu`） | 成品**不显示** | 成品是导出结果，拿它当素材再加工是错的；向导本来也把 `ft_` 排除在候选之外，留个按钮只会让人点进一个选不了任何东西的向导 |
| 章节标题行「添加章节」（P8 加的常驻按钮） | 成品**不显示** | 往成品目录里加章，下次导出同一本会被覆盖 ⇒ 用户加的章**无声消失** |

### 4.3 只读提示条

标题下方加一条 `secondaryContainer` 提示条：「翻译成品 / 这是从翻译工程导出的成品，
页图已经排好版，不能再编辑章节。」

🔴 放在标题下方、其它区块之上 —— 差异是**整页**的性质，不该藏在页脚。

## 五、命名坑点（沉淀到主记忆 `MEMORY.md`）

- **P6-1 刷新补登记的 id 必须与登记时逐字节一致**：`FinishedExport.idFor` 只 `toLowerCase()`、**不归一化分隔符** ⇒ 两侧都要用 `Directory.path` 的原样路径；差一个字符 ⇒ 同一成品在库里变两张卡。
- **P6-2 找来源漫画按 id，不按 `ComicType.local`**：网络下载到本地的漫画 `comic_type` 是源类型整数（`496108553`），写死 local 永远找不到 ⇒ 成品凑不出第二个成员 ⇒ 不建集合。
- **P6-3 成品身份看 id 前缀，不看 `comicType`**：成品的 `comic_type` 也是 `local`，用它判会把真素材一起算成成品。
- **P6-4 成品不给编辑入口**：加章会被下次导出覆盖（无声消失）；建工程等于拿成品当素材。
- **P6-5 三段目录的刷新兜底要各自成条**：`downloads/`→`registerUnlistedDownloadFolders`、`projects/`→`BtProjectManager.scan`、`translated/`→`registerUnlistedProductFolders`；只补一条就会有一类产物"磁盘上有、库里没有"。
- **P6-6 成品提示放页面上部**：差异是整页性质，不是页脚小字。

## 六、校验

- `flutter analyze`：**0 error**（80 issues 全是既有 info/warning；本批触及的文件里
  残留的 `unnecessary_cast`×3 / `unused_element_parameter`×2 / `library_private_types_in_public_api`×1
  均为改动前既有）。
- i18n 审计 `tools/tl_key_audit.py`：**TOTAL MISSING = 0**。
- Windows release 构建（pywin32 venv + S4U 沙盒）：`builds/build.log` 全绿 `BUILD_OK`，版本 `2.8.14+258`。

## 七、已知限制（留给后续）

- 成品的**批量管理**（`Batch manage`）仍可用：它能删章/改章序，而成品目录删章会让
  导出结果与库不一致。本批只关了"加章"与"建工程"两个**新增/派生**入口，批量管理
  属于**用户主动的破坏性操作**（有确认弹窗），暂按现状保留。
- `flutter test` 仍**不可在沙盒内跑**（flutter_tester WebSocket 握手失败），
  须让用户在 GUI 会话复跑。

## 八、后续

- P7：记忆与规则沉淀（目录三分 / id 前缀 / 空漫画语义的统一表述），
  以及本地素材分类标准是否调整（仍待用户确认）。
