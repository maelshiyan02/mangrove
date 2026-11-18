# P61 工作日志：GUI 离线实测验证与已有取证判定

> 日期：2026-11-15　｜　类型：施工日志　｜　上游：[P60 工作日志](P60-WORKLOG-包子拷贝源A方案加固与反向验证-20261115.md)
> 路线：用户拍板「**离线验证优先 + 只清 300MB BMP**」。
> 口径：不 commit / 不 push；不管 `Novel_Store/Scrapling_HANDOVER_20261115.md`；不动 `venera-configs-main` 的 5/6；不碰 2.2GB `modify_backup`、`.nuget`、22MB 修复备份；GUI 全程后台（`PostMessageW` + `PrintWindow`，不抢焦点、不注入键盘）。
> 取证目录：`Mangrove/test-materials/runs/gui_verify_20261115/`

---

## 0. 结论先行

| 项 | 结果 |
|---|---|
| 离线阅读器 UI 实测 | ✅ **通过**：本地漫画正文真机渲染成功，全程无 `HandshakeException` |
| 验收四项（翻页 / 缩放 / 外观抽屉 / 失败重试） | ✅ 3 项本轮真机通过 + 1 项由上一轮取证覆盖 |
| 已有 41 张 GUI 取证 | ⚠️ **不能作为离线验证证据**：全部是在线章节失败态，正文从未渲染 |
| 已有取证质量 | ⚠️ 22 张 BMP 只有 **13 张互不相同**，3 组字节级复用 |
| 判据自检 | ✅ 4 条反向口全部真红 / 真绿（脚本级 3 + GUI 层 1） |
| A 方案 JS 源改动真机网络回归 | ❌ **未验证**（离线路线绕开网络），仍被 7890 未监听阻塞 |
| 代码 / 提交 | 未改任何生产源码；未 commit / push |

**最重要的一条纠偏**：上一轮 `t1`–`t7`、`01`–`08` 的截图，中央一直是
`DioException [unknown]: Connection terminated during handshake` /
`Error: HandshakeException: Connection terminated during handshake` 错误页，
点「重试」后仍失败。所谓「GUI 验证」拍的是**在线章节失败态的 UI 交互**，
不是离线阅读器验证 —— 交接说明里「正准备改为离线验证」的判断属实，
这批截图**不能**写成「阅读器 UI 已通过」。

---

## 1. 现场快检（只读，接手时实测）

| 项 | 现场结果 | 判定 |
|---|---|---|
| `127.0.0.1:7890` | **NOT_LISTENING** | ⚠️ 新发现 |
| Clash for Windows | 5 个进程在跑（含 `clash-win64` PID 19060） | 进程活着、端口没开 → `HandshakeException` 更可能是本机代理未监听，不是玄学源站握手 |
| Mangrove GUI 进程 | 0 个 | 两条路线都需后台拉起 |
| `builds/mangrove/mangrove.exe` | 存在，139264 B，2026-11-14 21:33 | ✅ `gui_once.bat` 可用，无需重建 |
| 运行时副本 | `data/comic_source/copy_manga(5).js` = **1.9.0**、`baozi.js` = **1.3.0**，与 `comic_source/` 一致 | ✅ 坑 #1（副本滞后）已排除 |
| 本地相册 | `Error the Echo` 183 图、`灭门家族的重生者 · 英文版` 707 图等 14 个目录 | ✅ 素材完好 |

GUI 由后台任务拉起：PID `17892`、顶层 `722350`、子窗口 `FLUTTERVIEW` `32179906`。
本轮**未**调用 `SetCursorPos` / `SendInput` / `SetForegroundWindow` / 置顶，也未注入键盘。

---

## 2. 判据与反向口（会真红才算数）

两层判据，互不借取证面：

- **A. CHANGED**：`md5(整文件)` 不等 **且** 变化像素数 ≥ 20 → 操作是否让画面真的变了。
  逐行比较 32bpp BGRA 原始像素，输出变化行数、变化像素数、屏幕坐标包围盒。
- **B. HAS_CONTENT**：中央内容盒 `(700,250)-(1900,1150)` 内「与**该区域众数底色**不同的像素」占比 ≥ 10%
  → 中央是丰富图像（封面/漫画页）还是近乎纯色的失败态。附带亮像素占比作独立辅助取证。

> 🔴 判据 B 曾出现**假绿**：初版拿四角像素当底色，四角落在标题栏/时间戳上，
> 结果错误页也被判 `HAS_CONTENT`（100%）。改为「基准取自被测区域自身」后修复。
> 这是 §0-18/21「基准必须是权威真相、两个投影互比是假绿」的又一次实测。

| 反向口 | 注入 | 期望 | 实测 |
|---|---|---|---|
| N1 恒等对 | 同一张 BMP 复制成 before/after（模拟操作完全无效） | `SAME` | ✅ `SAME`，变化像素 0 |
| N2 内容擦除 | 把 `01_launch.bmp` 中央盒涂成区域众数底色 | `NO_CONTENT` | ✅ `NO_CONTENT` |
| N2 正向参照 | 未擦除的 `01_launch.bmp` 原图 | `HAS_CONTENT` | ✅ `HAS_CONTENT` 33.48% |
| GUI 层故障注入 | 取 `p61_04_zoom_plus` 真实取证，把 `after` 换成 `before` 再过同一判据 | `SAME` | ✅ `SAME`（真实对判 `CHANGED`） |

脚本退出码：`SELFTEST PASS` / `negative_control = PASS`。
机器可读取证：`offline_ui_verdict_evidence.json`、`p61_actions.jsonl`、`bmp_to_png_manifest.json`。

---

## 3. 已有 41 张取证的逐条判定（不重拍、只定性）

### 3.1 before/after 对（判据 A）

| # | 对 | 判定 A | 变化像素 | 包围盒（屏幕） | 语义判定 |
|---|---|---|---|---|---|
| 1 | `02_input_probe` | `SAME` | 0 | — | ❌ **FAIL**：before/after 字节相同，早期输入投递未生效 |
| 2 | `04_wheel` | `SAME` | 0 | — | ❌ **FAIL**：同上，滚轮未生效 |
| 3 | `t1_view_phys` | `CHANGED` | 2,224,729 | `[289,9,2559,1379]` | ✅ 主界面 → 阅读器（大范围切换） |
| 4 | `t2_reader` | `CHANGED` | 995,351 | `[9,9,2553,1379]` | ✅ 进入阅读器 / 加载转圈态 |
| 5 | `t3_zoom_plus` | `SAME` | 0 | — | ❌ **FAIL**：三张字节相同，缩放 `+` 未生效 |
| 6 | `t4_appearance` | `CHANGED` | 3,470,773 | 全屏 | ⚠️ 弱通过：菜单确实出现，但全屏重绘、语义不纯 |
| 7 | `t5_close_drawer` | `CHANGED` | 3,470,773 | 全屏 | ⚠️ 弱通过：与上一条互为镜像 |
| 8 | `t6_retry` | `CHANGED` | 21,798 | `[34,77,1937,846]` | ✅ 失败态「重试」按钮有响应 |
| 9 | `t7_zoom_label` | `CHANGED` | **201** | `[1273,674,1310,689]` | ❌ 存疑：变化落在中央错误文字区，**不是**右下缩放标签；`100%` 未变 |

### 3.2 中央内容判定（判据 B）

| 画面 | 非底色占比 | 亮像素占比 | 判定 |
|---|---|---|---|
| 主界面（`01_launch` / `02_after` / `03_hover` / `04_wheel_after` / `t1_view_phys_before`） | **33.48%** | 28.31% | `HAS_CONTENT` |
| 全部阅读器截图（`05_reader_loaded`、`08_after_retry`、`t2`–`t7` after 等） | **0.02% – 1.68%** | 0.02% – 1.55% | `NO_CONTENT` |

→ **客观结论：上一轮阅读器正文一页都没渲染出来。**

### 3.3 取证复用（字节级 md5 分组）

22 张 BMP 仅 **13 张互不相同**，3 组重复：

| md5 前缀 | 张数 | 文件 |
|---|---|---|
| `c77f7fc3…` | 7 | `01_launch` / `02_before` / `02_after` / `03_hover` / `04_wheel_before` / `04_wheel_after` / `t1_view_phys_before`（全为同一张主界面） |
| `9612637a…` | 3 | `t3_zoom_plus_before` / `t3_zoom_plus_after` / `t4_appearance_before`（全为同一张错误页） |
| `b12c67f3…` | 2 | `t5_close_drawer_after` / `t6_retry_before` |

这解释了 #1/#2/#5 的 `SAME` 不是「画面没变」，而是**同一份文件被当作前后两次取证**；
也解释了 #6/#7 变化像素数完全相同（开/关抽屉互为镜像）。

---

## 4. 本轮真机离线验证（8 条操作，全部后台）

驱动：`drive_offline.py`（**纯 ctypes**，因本机 3.8/3.10/3.12/3.13/3.14 全部缺 pywin32，
上一轮 `drive.py` 的运行环境已不在；不装依赖、不引入运行时）。
输入投 `FLUTTERVIEW` 子窗口，`PrintWindow(hwnd,dc,2)` 抓顶层；`SetProcessDpiAwarenessContext(-4)`
保证 2560×1380 物理坐标；取证直接落 PNG，不再产生 13.5MB BMP。

| # | tag | 动作 / 坐标 | 判定 | 独立语义读数（目视 / 文本真相） |
|---|---|---|---|---|
| 0 | `p61_00_launch` | 冷启动首帧 | CAPTURED | 2560×1380，**与旧 `01_launch.bmp` 像素级完全一致**（环境可复现） |
| 1 | `p61_01_open_local` | click `(410,680)` 本地封面 | CHANGED | 进入详情页「秘密小姐」，226 话章节列表，无网络错误 |
| 2 | `p61_02_enter_reader` | click `(2395,382)`「继续」 | CHANGED | **漫画页真的渲染**：`Ch.2 / 126`、`第1话 - 7/230`、`100%`，无 `HandshakeException` |
| 3 | `p61_03_wheel_next` | wheel `-6` | CHANGED | 画面明显下移，但页码仍 `7/230` → **页内滚动生效，未换页** |
| 4 | `p61_04_zoom_plus` | click `(2400,1350)`「+」 | CHANGED | 缩放 `100% → 110%`，画面放大 |
| 5 | `p61_05_wheel_far` | wheel `-30` | CHANGED | 页码 `7/230 → 8/230`，换成完全不同的一页（蓝色走廊 + 台词气泡） |
| 6 | `p61_06_appearance` | click `(2230,95)` 主题图标 | CHANGED | 右上展开「白天 / **黑夜**（选中）/ 护眼」，画面加遮罩 |
| 7 | `p61_07_close_appearance` | 再点同图标 | CHANGED | 菜单消失、遮罩去除，`8/230`、`110%` 保持 |

> 每条 PASS 都有**独立文本真相**（页码 / 百分比 / 菜单选项 / 错误文案），
> 不靠 md5 单条取证自证；md5 只作「真的变了」的辅助证据。

### 4.1 验收清单

| 交接说明要求 | 判定 | 证据 |
|---|---|---|
| 翻页 | ✅ PASS | `p61_05_wheel_far`：`7/230 → 8/230` 且画面完全不同 |
| 缩放 | ✅ PASS | `p61_04_zoom_plus`：`100% → 110%` |
| 外观抽屉 | ✅ PASS | `p61_06` 展开 + `p61_07` 关闭，成对取证 |
| 加载失败重试 | ✅ 由上一轮取证覆盖 | `t6_retry` CHANGED 21,798 px + `08_after_retry` 重试后仍为错误页；**本轮离线成功态未触发重试，未重复验证** |
| 阅读器正文渲染（离线核心） | ✅ PASS | `p61_02` 起 6 张截图均有漫画页，零网络错误 |

---

## 5. 取证保全与 BMP 清理

- 22 张 BMP = **296.5 MB**；其中 11 张原本没有对应 PNG。
- `bmp_to_png.py`（纯标准库自写 PNG 编码器）把缺失的 11 张转出 PNG，
  **逐像素回读校验 `identical=True` 11/11**，全部 2560×1380。
- 原有 11 张 PNG 为 RGB(`ct=2`) 格式，已被图片查看器成功渲染；本轮新增 PNG 为 RGBA(`ct=6`)。
  两者格式不同属正常，`decode_png_rows` 的 RGBA 专用校验器不适用旧图，非文件损坏。
- 删除 22 个大 BMP 后复核目录体积（见 §5.1）。
- 未删除：任一 PNG / JSON / JSONL / 脚本 / `drive.py` / `gui_once.bat`。

### 5.1 清理执行结果

| 项 | 实测 |
|---|---|
| 删除前 | 41 文件 / **301.4 MB**（22 BMP = 296.5 MB + 18 PNG + `drive.py`） |
| 通用 PNG 结构校验 | **46 张 / 0 坏**（18 张 RGB `ct=2` + 28 张 RGBA `ct=6`，IDAT 解压长度与 filter 全合法） |
| 每张 BMP 都有对应 PNG | ✅ 22/22，缺失 0 |
| 新转 11 张逐像素校验 | ✅ `identical=True` 11/11 |
| 删除 | 22 个 BMP **逐文件**删除（每个都先断言同名 PNG 存在），留 `bmp_cleanup_20261115.json`（含每个文件的 md5 / 字节数 / 保留 PNG 名） |
| 删除后 | **54 文件 / 45.9 MB**，剩余 BMP = 0，`all_png_kept=True`，`SELFTEST PASS` |
| 释放 | **296.5 MB**（目录净减 ≈ 255 MB，因本轮新增取证 PNG 约 41 MB） |

未删除任何 PNG / JSON / JSONL / 脚本；未触碰 git 与其他残留。

---

## 6. 边界与未决（必须如实说明）

1. **A 方案 JS 源改动（`baozi.js` 1.3.0 / `copy_manga(5).js` 1.9.0）本轮未被真机网络回归验证。**
   离线路线走本地漫画，绕开了漫画源网络链路；P60 的结论仍是「离线 Node 桩 25/25 + 13/13 + 4 轮注入」。
   要验网络行为必须先恢复代理，另开一轮「真机网络回归」。
2. `127.0.0.1:7890` **仍未监听**（Clash 进程在跑）。这是 P60 §5-2「未做真实网络回归」的直接阻塞点，
   也大概率是上一轮 `HandshakeException` 的根因 —— 建议先查 Clash 端口/系统代理配置，成本低于排查源站握手。
3. 未 commit / push；`Scrapling_HANDOVER_20261115.md` 按口径未触碰；
   `venera-configs-main` 的 5/6 未动；2.2GB `modify_backup`、`.nuget`、22MB 修复备份未动。
4. `t7_zoom_label` 的 201 像素变化落在中央错误文字区，命名语义与实际画面不符，
   **以画面为准**，不把「命名」当取证（§0-13/15）。

---

## 7. 复现命令

```bash
cd "D:/AI Coding Project Management/Mangrove/test-materials/runs/gui_verify_20261115"

# 已有取证的客观判定 + 3 条反向口（不需要 GUI）
python analyze_pairs.py            # -> offline_ui_verdict_evidence.json, SELFTEST PASS

# BMP -> PNG 无损转换 + 逐像素校验（不删 BMP）
python bmp_to_png.py               # -> bmp_to_png_manifest.json

# 真机离线驱动（需 GUI 已后台启动；<pid> 换成实际 PID）
python drive_offline.py <pid> shot  <tag>
python drive_offline.py <pid> click <tag> <x> <y> [wait]
python drive_offline.py <pid> wheel <tag> <x> <y> <delta> [wait]
# -> p61_actions.jsonl + p61_<tag>*.png
```
