# 项目清理 + BallonTranslator 参考库瘦身 + 推送 GitHub 实施计划

> 2026-10-12 ｜ Plan Mode 产出，**审批后才动手**。
> 范围限定三件事：① 整理乱文件/清测试残留；② BT 参考库去留（翻译管线吸收度审计）；③ 整理后推送 GitHub。

---

## 一、调研结论（先纠正一个关键误解）

### 1. 6.2GB **从来没有进过 git**，删它不会改变远程仓库体积

- `Ballonstranslator_win_minium/`（6.19GB）、`builds/`、`ComicLibrary/`、`Ballonstranslator_store/`、`Mangrove-portable/`、`Mangrove/build/`、`Mangrove/.dart_tool/` **全部已在 .gitignore 中、tracked 文件数 = 0**。
- 本地 `.git` 只有 **39.1MB**（20 个提交、958 个 tracked 文件）；历史中最大的 blob 是打包字体 NotoSansSC/KR（4.9~8.7MB）和 `Mangrove/tools/nuget.exe`（8.4MB，Flutter Windows 构建要用），没有异常大物。
- 所以：删 BT 文件夹的收益是**释放本地磁盘 6.2GB**；GitHub 端本来就不受影响。远程"提交空间"不受这个文件夹拖累。
- 当前分支 `main` 领先 `origin/main` **10 个提交未推**，外加 P14~P45 大量改动还没 commit。**真正的上传工作 = 提交未提交成果 + push**。

### 2. 体积分布（实测）

| 目录 | 体积 | 性质 | 处置 |
|---|---|---|---|
| `Ballonstranslator_win_minium/` | **6,188MB** | BT 参考库（pylibs 5,491 + models 663 + 源码仅 9.2） | **瘦身到 ~17MB**（见第三节） |
| `Mangrove/build/` + `.dart_tool/` + `windows/.../ephemeral/` | 1,424MB | Flutter 可再生物（删了要全量重建） | **保留**（已忽略，不碍 git） |
| `builds/archive/` | 167MB | 10/8-9 旧构建、迁移备份、s95 旧夹具（唯一引用是一个脚本的历史注释） | **删** |
| `builds/_stale_venera/` | 131MB | 旧 Venera 解包残留 | **删** |
| `builds/mangrove/` | 110MB | **当前**构建安装产物（App 实际运行的版本） | **保留** |
| `ComicLibrary/` | 279MB | 用户资料库（下载/工程/成品三个根） | **不动** |
| `Ballonstranslator_store/` | 162MB | 你的 FT 工程（含 edit-check 门禁真实夹具） | **不动** |
| `Mangrove-portable/` | 74MB | 旧 Venera portable（venera.exe，已废弃） | **删** |
| `builds/_rv_backup/` + `reports/` + 各种 json/log | ~6.5MB | 反向验证自动备份与运行时报告（工具会自动重建） | **删内容** |
| `tools/` | 13.2MB | 其中 rustup-init.exe 12.4MB（一次性安装包） | 删 exe 与探针残留 |
| `venera-configs-main/` | 0.8MB | 下载源取证测试引用的上游源配置（tracked 36 文件） | **保留** |

### 3. headless 文件**不是残留，是现役门禁**

`Mangrove/lib/headless_p1_checks.dart` … `headless_p15_checks.dart` + `headless_pipeline_check.dart` + `headless_script_checks.dart`（17 个文件）**全部被 [headless.dart](file:///d:/Mangrove_Windows/Mangrove/lib/headless.dart#L39-L55) import**，就是日常跑的 block-ops / run-plan / bootstrap / glossary / edit-check 六门禁断言本体。**一个都不能删。**

### 4. BallonTranslator 翻译管线吸收度审计

App 是纯 Flutter/Dart 独立实现，**运行时完全不执行 BT 的 Python**（只读 `imgtrans_*.json` 工程文件做互操作；模型也是自己从 HuggingFace 下载的 PP-OCR / manga-ocr / NLLB，与 BT 的 lama/CTD/ocr_ar 模型完全不同）。

| BT 能力 | BT 实现 | Mangrove 现状 | 判定 |
|---|---|---|---|
| OCR | mit48px 系列 + 十几种云 OCR | manga-ocr（日，ONNX）+ PP-OCRv4 中/英、v3 英、韩文 rec，worker isolate 跑 | ✅ 主流语言已吸收 |
| 翻译 | 12 种 MT + LLM + 上下文/术语表 | LLM endpoint + NLLB-1.3B/600M + Opus-MT 本地 ONNX + Google 免费端点 + 术语表 + 批量请求 + 限流 + OpenCC | ✅ 吸收且有超越（本地大模型、整章批量） |
| 排版渲字 | text_layout / fontformat / stroke_width / text_alpha_mask / text_effects | page_renderer + font_fit（自动字号/居中/竖排多列/反色描边）+ 跨页投影片段渲染 | ✅ 主体吸收，另有跨页创新 |
| 文字取色 | textblock_mask.py 腐蚀掩膜取均值 | text_color.dart 借同一思路（3×3 腐蚀+Otsu），P34 已正反验证 | ✅ 已吸收 |
| 字体探测/注册 | font_detect / font_registry（sfnt 解析） | system_fonts.dart 同款 sfnt 解析 + 打包 Noto SC/KR | ✅ 等效替代 |
| 去字 inpainting | lama / aot / ffc / patchmatch（大模型） | 纯 Dart：Otsu 分笔画 + 外扩 ≥30% + 最近邻填充（借 BT 经验值），**零模型下载**；mask 双端共用 | 🟠 路线取舍：轻量/零依赖，复杂背景质量上限低于 lama |
| 气泡/文本检测 | comic-text-detector（YOLOv5+DB 实例分割）、textlines_merge、split_text_region | PP-OCRv4 DBNet 行检测 + balloon_clustering 启发式聚框/分栏 | 🟠 常规版式够用；实例分割在代码注释中已自认为未来 P0-1 级工作 |
| 工程互操作 | proj_imgtrans / io_utils | bt_project 只读、json_codec 读写 imgtrans JSON、result/ 为真相 | ✅ 双向兼容 |
| panel_finder 分格 | 有 | 无 | ⬜ 未吸收（目前无需求） |
| pkuseg 中文分词后处理 | 有 | 无（LLM/NLLB 翻译不需要） | ⬜ 无需 |
| image_generation / LLM image | 有 | 无 | ⬜ 超范围 |
| 云 OCR/MT 引擎数量 | 十余种 | Google 1 个公共端点 + LLM | ⬜ 可以后按需加，接口已留 |

**审计结论**：翻译管线**主干可借鉴的优点（OCR、翻译、排版、取色、字体探测、工程互操作）都已吸收**，且有本地 NMT、批量管线、跨页渲染等超越项。明确未吸收的只有三项质量上限/扩展型能力：**① CTD 实例分割检测；② lama AI 去字；③ panel_finder 分格**。这三项的参考价值集中在 BT **Python 源码（9.2MB）**里；5.5GB 的便携 Python 环境和 663MB 模型对我们没有任何用途（模型不同源、App 不跑 Python），**可以安全删除**。

---

## 二、文件改动清单

### A. 删除：测试残留 / 陈旧产物（全部已被 gitignore，零 git 风险，释放约 386MB）

1. `builds/archive/`（167MB）、`builds/_stale_venera/`（131MB）、`builds/_rv_backup/`（5.6MB，RV 工具下次自动重建）、`builds/reports/`（0.4MB）。
2. `builds/` 根下运行时垃圾：`gate_*.json/.out`、`step_*.log`、`build_run*.txt`、`headless.out`、`edit_check*.json/.txt`、`export_check*.json`、`reverse_verification.json`、`rv_deletion_run.txt`、`cache_check.json`、`_direct.*`、`_head_tj.json`、`_inner_probe.txt`、`_rv_check.json`、`_tj_*.py`、`build.log`（保留 `README.md`）。
3. 仓库根 10 个一次性报告：`block_ops_check.json`、`edit_check.json`、`glossary_check.json`、`glossary_ui_check.json`、`run_plan_check.json`、`bootstrap_check.json`、`download_check.json`、`studio_scan.json`、`cache_check.json`、`migrate_sources.json`、`pipeline_check.json`、`script_check.json`、`s6_project_check.json`、`s7_export_check.json`。
4. `Mangrove-portable/`（74MB 旧 Venera portable）。
5. `tools/` 残留：`rustup-init.exe`（12.4MB）、`spike/`（S5/S6 旧探针）、`s6_harness/`（旧独立门禁，已被 app 内 headless 门禁取代）、`probe_out/`（一次性 HTML 抓取样本）、`forensics_out/`（可再生成）、`__pycache__/`、`analyze_out.txt`、`build_out.txt`、`headless_once.bat`、`probe_copy_web.py`…`probe_copy_web5.py`、`dbg_comick.py`、`test_async_interop.py`（均被 `forensics_download_sources.py` 取代，runner 不 import 它们）。
6. 根目录 `copy_aes.js`（与 `tools/copy_aes.js` 重复）。

### B. git 跟踪修正（untrack，不删本地用途文件）

- `git rm --cached`：`bootstrap_check.json`（在 .gitignore 但早年被跟踪）、`tools/analyze_out.txt`（日志）。
- 复查 `Mangrove/tools/nuget.exe`（8.4MB）：**保留**（Flutter Windows CMake 构建链使用）。
- 补强 .gitignore：`tools/forensics_out/`、根报告 json（已有列举，补漏 `download_check.json` 等已在列的不动）、`*.rvbak` 若有。

### C. BallonTranslator 参考库瘦身（释放约 6,171MB，保留 ~17MB 源码参考）

- **删**：`ballontrans_pylibs_win/`（5,491MB 便携 Python）、`data/`（663MB，BT 模型与缓存；我们不用）、`.btrans_cache/`、`.git/`（BT 自己的历史，需要时可重新 clone）、`logs/`、`tmp/`、`config/` 运行期产物、各处 `__pycache__`。
- **留**：`ballontranslator/`（9.2MB 源码，CTD/lama/panel_finder 未来移植参考）、`resources/`、`doc/`、`tests/`、`scripts/`、`README*`、`LICENSE`、`requirements.txt`、`pyproject.toml`、`launch*`。
- 该目录仍在 .gitignore 内，瘦身后只占本地磁盘、不进 GitHub。

### D. 明确不动

- `ComicLibrary/`、`Ballonstranslator_store/`（用户数据 + 门禁夹具）、`builds/mangrove/`（当前可用产物）、`Mangrove/build/`+`.dart_tool/`（删了全量重建；如你想进一步释放 1.4GB 可在计划批准时告知，我再删）、`venera-configs-main/`、17 个现役 headless_*.dart、tools 现役工装（run_build_task / run_headless_task / agent_links_check / _reverse_verify / _rv_drive / _summarise_edit_check / _make_chapter_carrier / forensics_download_sources / test_copy_v180 / test_comick_fix / test_copy_aes / copy_aes.js / inspect_font / tl_key_audit / 三个 .bat 手动入口）。

---

## 三、实施步骤（按依赖顺序）

1. **提交前安全扫描**：对待提交内容做密钥/令牌 grep（Clash secret、API key、token），确认无敏感信息。
2. **执行 A 组删除**（DeleteFile / Remove-Item），删后列目录复核。
3. **执行 B 组 git untrack**，更新 `.gitignore`。
4. **执行 C 组 BT 瘦身**；先输出保留清单与体积复核，再删大目录。
5. **分组提交**（建议 3 个 commit，信息用中文，沿用仓库风格）：
   - `feat: P14-P45 工作室/字体/下载源修复与门禁扩充`（`Mangrove/` + `tools/` 代码）
   - `docs: P14-P45 工作日志/记忆/GUI 复测脚本`（`.agent/`、`docs/`、`P29-*.md`、`AGENTS.md` 等）
   - `chore: 清理测试残留与陈旧产物，补 .gitignore`
6. **推送**：`git push origin main`（10 个旧提交 + 3 个新提交；github 走 127.0.0.1:7890 代理，已在 gitconfig 固化）。
7. **验证**：
   - `git status` 干净；`git log origin/main..HEAD` 为空；
   - GitHub 上确认新提交可见、仓库大小无异常；
   - 删除后跑一次 **六门禁**（block-ops/run-plan/bootstrap/glossary/glossary-ui/edit-check）证明工装删除没伤到验证链；
   - 跑 `python tools/agent_links_check.py` 体检；
   - `Mangrove/assets/comix_to.js` 与 appdata 运行时副本仍 SHA256 一致（P45 状态不回退）。

## 四、风险与兜底

- **BT 源码误删风险** → 只删 pylibs/data/缓存/.git，源码整目录保留；删除前再列一次保留清单。
- **删错现役工装** → 17 个 headless 文件已证实全部被 import；tools 删除清单已逐个核实引用；`_rv_backup` 与报告目录工具会自动重建。
- **推不上去**（代理/凭据）→ 代理配置已固化（A09）；凭据走 gh/manager 无弹框链路（P 历史已修）；失败不做 force、不重写历史。
- **历史里有 VeneraX 旧对象**（~数 MB）→ 39MB 的 .git 完全健康，**不做 history rewrite**（高风险无收益）。
- **Ballonstranslator_store 被误删** → 不进删除清单；它同时是门禁夹具库。
- 任何一步发现与计划不符，立即停下报告，不扩大操作。
