# A03 · 磁盘布局与 FT 工程互读

> **触发时机**：碰 `ComicLibrary/`、碰工程 JSON、做零字节 diff、安排新目录**之前**。
> 上级索引：`../MEMORY.md` ｜ 相关：`A05`（出图）· `A06`（下载）

---

## 1. 磁盘布局（三个根）

```
ComicLibrary/
├── downloads/<漫画>/<章节>/<n>.webp  + cover    ← 本地库（阅读器直接读）
├── projects/<工程名>/imgtrans_*.json + mask/ inpainted/ result/   ← 工作室（`bt_` 卡）
└── translated/<漫画>/<章节>/<n>.png            ← 成品（`ft_` 卡，自成一张普通本地卡）
```

- `btProjectRoot` = `ComicLibrary\projects`（可用 `;` 配多个根；**单根时必须在 projects 与 downloads 之间二选一**）。
- 🚩 **扫描器红线**（`local_comic_scanner`）：
  - 章节目录内出现**任何子目录** → **整本被拒**；
  - 必须有封面；
  - 图片白名单：`jpg jpeg png webp gif jpe`；`json` 被忽略。
  ⇒ **`mask/`+`inpainted/`+`result/`+json 四件套绝不能落在 `downloads/<漫画>/` 里**；
  ⇒ `projects/` 必须是 `downloads/` 的**兄弟目录**，不是它的子目录。

## 2. 「A 方案」：原图与产物分家

- 工程的 `directory` 指向 `ComicLibrary/downloads/<漫画>`（**原图不复制**）；
- 工程的 `workspace` 不写时**回落到 json 的父目录** = `projects/<工程名>`；
- ⇒ `mask/` `inpainted/` `result/` 落在 `projects/` 下，**不污染 downloads**。
- 🔴 **原图是「可弃素材」**：工程模型**不得**把原图存在当作自身存在的前提。
  （P8.0 的"工程凭空消失"就是这么来的：删掉原图 → 封面取不到 → 静默跳过 → 工作室空白。）

## 3. FT 工程（BallonTranslator）互读

### 3.1 结构

- 顶层键：`directory` / `pages`（形如 `0/1.webp`）/ `current_img` / `image_info` / `page_order` / `chapters`，**可选** `workspace`。
- `TextBlock` 共 **23 键**；`FontFormat` 共 **32 键**。
- `image_info` 实测形如 `{finish_code, width, height, translation_target}`。

### 3.2 🔥 零字节 diff 的三个坑

1. **分隔符**：Python `json.dumps` 默认 `", "` / `": "`，而 Dart `jsonEncode` **无空格**
   → 自实现了 `PyJson`（等价于 `separators=(', ', ': ')`）。
   ⇒ **用 Python 生成载体 JSON 时必须显式 `separators=(', ', ': ')`**，否则 round-trip 立刻失败
   （`indent=4` 更是灾难）。
2. **浮点指数阈值不同**：Python 在 `1e16` / `1e-7` 附近切指数记法并用**带符号两位**（`1e+16`、`1e-07`），
   Dart 阈值是 21 / -6 且**不补零**。
3. **模型必须做「有序 DOM 透传」**（不物化键、未知字段原样保留），否则会出现**幻影页键**让 diff 非零。
   ⇒ 推论：**同一页里「人工块」与「自动块」必须同键集** —— 所以 `TextBlock.fromOcr(...)` **只能在 `createDefault(...)` 之上 mutate**，不能另起一套。

### 3.3 `workspace` 的取值规则

`workspace` = **json 里显式写了就用它，没写就用 json 的父目录**。
🔴 **读不到就别回写**（写回去就是编造，会让零字节 diff 失败）。

### 3.4 `rich_text` 是完整 Qt HTML

- `rich_text` 存的是**完整的 Qt `qrichtext` HTML**，FT 画布渲染的是它，**不是 `translation` 字段**。
- ⇒ **改译文必须同步重建 `rich_text`**（`rich_text_sync.dart`）：
  - `size` 用 **pt**；
  - `letter-spacing` 写成 `(ls-1)em`，并镜像一个 `data-btrans-letter-spacing` 属性；
  - 浮点尾巴必须 `toStringAsFixed` 去尾零（`1.15-1.0 = 0.1499999999999999`）。

## 4. 载体（测试工程）清单

| 载体 | id / 位置 | 特点 |
|---|---|---|
| `My Dragon Girlfriend Has Returned` | `downloads/` + `projects/MDGH-ch1` | 8 话号 / 84 版本 / 11 组，**原图完整** |
| `MDGH-ch1` | `bt_c3d2c83c`，94 页 | 整章端到端载体；页尺寸 18 种，含**一张 1532×1024 横向跨页图** |
| `S9Fixture` | `bt_6c25fb2a`，5 页 | **带原图**；支持空工程自举；现有 1 个真实块 |
| `Error the Echo` | `bt_*`，85 块 | 块数据可用，但**原图已删** → 只能验"不碰图像内容"的项 |

- ⚠️ **应用没有「从下载创建工程」的入口**（`BtProjectManager` 只有 `ensureProject` / `scan`；`ProjectWriter.adopt` 只被 headless 校验调用）
  → 整章载体靠离线工具 `tools/_make_chapter_carrier.py` 生成。
- 🔴 `S9Fixture` 的三条硬约束（见该目录 `README.md`）：
  1. **不得移动/改名 json**（`bt_` 卡 id = json 路径的 FNV 哈希，移位即换 id）；
  2. **不得塞进 `downloads/`**（章节目录有子目录 → 整本被拒）；
  3. Python 生成载体 JSON **必须 `separators=(', ', ': ')`**。

## 5. 路径与目录命名

- **章节目录名唯一真相 = `chapterDirectoryName(chapters, chapterKey)`**：
  下载 / 读取 / 删除 / 缺页表 / 磁盘反查**必须全部调它**（旧目录靠 `migrateChapterDirectories()` 迁移）。
- `findValidId` 必须带 `AND id GLOB '[0-9]*'`：`CAST(id AS INTEGER)` 会把 `bt_xxx` 变成 `0` → 导入即崩。
- ⚠️ 目录名里可能有**多字节与百分号编码陷阱**，见 `A02 §5`。
