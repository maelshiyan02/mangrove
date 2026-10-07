# ComicLibrary 路径统一 + Venera 多本地翻译引擎 + 汉化成品导出 实施计划（一轮交付）

## 一、调研结论（均有代码/实测证据）

### 1. 目录冲突精确定位
- **Venera 本地库要求纯净目录**：[local_comic_scanner.dart L49-L60](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/utils/local_comic_scanner.dart#L49-L60)：章节目录内出现**任何子目录**即判整本无效；非图片文件虽被忽略但用户要求目录只留图片（便于直接打包 cbz）。
- **BT 把所有产物写进图片目录**：[proj_imgtrans.py L424-L435](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/utils/proj_imgtrans.py#L424-L435) 直接在图片目录建 `mask/ inpainted/ result/ assets/` 与 `<type>_<名>.json`；另有 `bubcuts/`、docx（L1423/L1430）、`*_translation.txt/*_source.txt`（[L1471-L1473](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/utils/proj_imgtrans.py#L1471-L1473)）、`textstyles.json`（mainwindow L1556）。
- **BT 下载器污染**：[download_dialog.py L203](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/ui/download_dialog.py#L203) 每章写 `_source_urls.json`；输出目录默认空白；命名为长章节名，非 Venera 布局。
- **BT 导出默认目录**=[图片目录](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/ui/mainwindow.py#L2427)。
- **现状路径**：Venera 本地库已是 `D:\Ballonstranslator_Windows\ComicLibrary\downloads`（证据 `%APPDATA%\io.github.kyosee\venera\local_path`），`translated\` 已手工创建。Venera 下载布局：`<库>/<漫画>/cover.* + details.json + <0,1,2>/<1,2….webp>`。

### 2. Venera AI 翻译现状
- 本地 ONNX OCR（检测 + 日 manga-ocr / 中英 / 英 / 韩，[translation_models.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_models.dart)）→ 翻译仅两档（OpenAI 兼容 [LLM](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/llm_translator.dart)、[Google 免费](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/public_translator.dart)）→ ONNX 抹字 → 叠加渲染。
- 译文存 `image_translation.db`，渲染图在缓存；Venera 自身不污染图片目录。
- 引擎接入条件齐备：ONNX FFI 泛型张量推理 + [encoder-decoder 自回归循环先例](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_worker.dart#L629-L666)；[hf_tokenizer.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/hf_tokenizer.dart) 已实现 SentencePiece（Metaspace+BPE/Unigram）解析但**无调用方**；[renderTranslatedPage](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/page_renderer.dart#L17) 纯 dart:ui 离屏出 PNG，天然可用于批量导出。
- 导出管线单一入口 `ExportTaskManager._buildToCache`（[export_tasks.dart L369](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/export_tasks.dart#L369)），已支持 cbz/pdf/epub；导出目录每次手选不记忆。

### 3. BT 引擎参考
- 离线仅 M2M100（多语言，[trans_m2m100.py](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/modules/translators/trans_m2m100.py)）与 Sugoi（日→英，[trans_sugoi.py](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/modules/translators/trans_sugoi.py)）；支持 `--headless --exec_dirs` 批量。
- **NLLB-200** 覆盖 `jpn_Jpan/kor_Hang/eng_Latn/spa_Latn/lat_Latn/zho_Hans/zho_Hant`，一个模型覆盖全部需求；distilled 有 600M（轻量）与 1.3B（高质量）两档。

## 二、统一目录布局（已确认）

```
D:\Ballonstranslator_Windows\ComicLibrary\
├─ downloads\                     生肉唯一区 = Venera 本地库根（保持纯净：仅图片 + cover/details.json）
│  └─ <漫画>\ cover.webp · details.json · 0\1.webp …
└─ translated\
   ├─ projects\                   BT 工程区（嵌套镜像 downloads 相对路径）
   │  ├─ <漫画>\
   │  │  ├─ manga_<漫画>.json · textstyles.json
   │  │  ├─ mask\ inpainted\ assets\ result\
   │  │  └─ source_urls\ <0,1,2….json> index.json   （下载清单与章节名映射镜像）
   │  └─ _external\<目录名>_<8位hash>\…              打开 downloads 外目录的兜底
   └─ exports\                     成品区（按漫画再按格式）
      └─ <漫画>\
         ├─ images\<章节名>\001.jpg…
         ├─ <漫画>.cbz / .zip
         ├─ <漫画>.pdf
         └─ <漫画>.epub
```
镜像规则集中在一个映射函数：源目录在 `manga_source_root` 内 → `workspace_root + relpath`；外部 → `workspace_root/_external/<basename>_<hash8>`。

## 三、实施内容（一轮完成，按依赖顺序 A→B→C→D，全部自动化验证后统一真机验收）

# A. BT 路径治理

### A1. 新增 `ballontranslator/utils/workspace.py`（唯一路径权威）
- 读 pcfg：`manga_source_root / translation_workspace_root / translation_export_root / download_default_dir`。
- API：`workspace_dir_for(img_dir)`、`export_root_for(img_dir)`（→ exports/<漫画>）、`manifest_path_for(chapter_dir)`、`external_fallback(img_dir)`；realpath 归一、跨盘安全；**根目录未配置时回退旧行为**（零破坏）。

### A2. `utils/config.py` ProgramConfig 新默认键（L413 附近）
- 四个路径键默认空串（UI 预填 D 盘推荐值），`venera_compatible_download: bool = True`。

### A3. `ui/configpanel.py`
- "漫画库路径"分组：4 个目录选择 + Venera 兼容下载勾选 + "一键设为推荐布局"按钮（写入 ComicLibrary 三个路径）。

### A4. `utils/proj_imgtrans.py`（核心重定向）
- `load()`：`self.directory` 仍是**只读图片源**；新增 `self.workspace`；`proj_path/mask_dir/inpainted_dir/result_dir/assets_dir` 及 bubcuts/docx 路径全部基于 workspace；建目录建在 workspace；图片读取仍走 directory（相对 page name、章节子目录语义不变）。
- `save()`/快照备份跟随 workspace；`dump_txt_path` 改 workspace；`to_dict` 增 `workspace`/`source_directory` 字段（搬家自愈）。
- **旧产物一次性迁移**：load 发现图片目录旁的旧 json/mask/inpainted/result/assets/txt，GUI 询问、headless 直接移动到 workspace，写 `logs/path_migration.log`，同步 recent_proj_list。
- 全量 grep 审计所有 `self.directory`/`proj.directory` 拼接点（mainwindow 约 10 处、proj_imgtrans 全部路径方法），无一遗漏。

### A5. `ui/mainwindow.py` 配套
- 独立 textstyles 路径、章节导出默认目录（`exports/<漫画>`，建议名=章节名）、最近列表、docx、txt 导出全部跟随新映射。
- 重下失败页/单页重下（L2663、L2745）清单改读 `manifest_path_for`，兼容旧邻接文件并自动迁移。
- headless 流程无需改调用（映射在 load 内完成）。

### A6. `ui/download_dialog.py`
- out_edit 默认 `download_default_dir`。
- Venera 布局（勾选默认开）：`<out>/<漫画>/cover.<ext>` + `<0,1,2>/<1,2….ext>`；原章节标题/组/时间戳映射与源 URL 清单写 `projects/<漫画>/source_urls/<idx>.json` + `index.json`，**图片目录零非图片文件**。
- 关勾选保留长章节目录名，但清单仍写 workspace；DownloadWorker/RedownloadWorker 全部清单 IO（L131/L203/L329-L381）走统一映射。

# B. Venera 多本地离线翻译引擎（引擎注册表架构，首批 3 个引擎）

### B0. 模型选型闸门（编码第一步，证据落盘后再写推理代码）
联网核实并记录：HF 上 ① NLLB-200-distilled-1.3B int8 ONNX（encoder+**no-past decoder**+tokenizer.json fast 格式）② 同 600M ③ Sugoi（日→英）ONNX（确认其 SentencePiece/BPE 词表文件形态）。要求：文件齐、许可证可再分发、可经 hf-mirror 拉取；任一缺可信预编译则记录替代仓并继续（不自行转模型为默认路径，除非用户同意）。用户接受大体积、质量优先。

### B1. 引擎注册表：新增 `lib/foundation/image_translation/translation_engines.dart`
- `LocalEngineDescriptor { id, displayName, modelComponent, supported(src,tgt), forcedBosToken, tokenizerKind, notes }`。
- 首批注册：
  - `nllb_1.3b`：多语言双向（ja/en/ko/es/la/zh/zh-TW 互译），质量档；
  - `nllb_600m`：同覆盖，轻量档；
  - `sugoi_ja_en`：仅 ja→en（目标英文时的日文专项）。
- 引擎与现有云端档统一为一个"翻译引擎"选择器：LLM（现有 provider 体系）/ Google / NLLB-1.3B / NLLB-600M / Sugoi。

### B2. `translation_models.dart`
- 注册三个 ModelComponent（文件清单/大小/镜像 URL 复用 `{hf}` 机制），模型管理页新增 "Machine Translation" 分区；`workerPaths()` 带 MT 文件。

### B3. 新增 `local_nmt_translator.dart` + worker 接入
- NLLB：源句注入源语言 token、decoder 强制 BOS=目标语言 token，v1 用 no-past 贪心解码（复用 manga-ocr argmax/重复环模式）；Sugoi 按其签名封装。逐句翻译（v1 不 batching），输出同构 `LlmTranslationResult(texts, {})`（本地档无术语表，与 Google 档一致）。
- session/tokenizer 缓存于 worker isolate，随空闲释放；[translation_worker.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_worker.dart) 新增 `translateLines` 通道与 `WorkerModelPaths` 字段。
- [translation_pipeline.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_pipeline.dart) 按引擎设置分派；不支持当前语对的引擎在 UI 禁用并提示。

### B4. 设置与就绪检查
- appdata 新增 `imageTranslationEngine`（默认 llm，现状不变）；reader.dart 设置组：引擎下拉、源语言增加 Spanish/Latin（OCR 复用英文拉丁 rec，`ocrFor` 增 es/la→en 映射）、目标语言补齐 la；引擎下挂模型状态/未装跳模型管理页。
- translation_service 就绪检查：本地档要求 detector + 所需 OCR + 对应 MT 组件均安装。

### B5. 测试
- Dart 单测：NLLB tokenizer.json 用 HfTokenizer 编解码已知句（Metaspace/Unigram）、强制语言 token、语对支持矩阵；Sugoi 词表路径按 B0 证据补。
- `flutter test` + `flutter analyze`。

# C. Venera 汉化成品导出（cbz/zip、图片文件夹、PDF、EPUB，均可选叠加译文）

### C1. 导出任务扩展（export_tasks.dart + local_comics_page.dart）
- 导出对话框增选项：①「使用已存译文渲染页面」开关（默认关=现状原图导出）② 目标格式新增"图片文件夹"（cbz/pdf/epub 已有）。
- 译文导出构建：逐页读原图 → 从 TranslationStore 取该页 regions；有译文则 [renderTranslatedPage](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/page_renderer.dart) 渲染（默认 **patch 模式**，不需要抹字模型；可选 smart 模式跑 ONNX inpaint，慢）；无译文页默认导出原图（可选"跳过/报错"策略）。暂存树交给现有 cbz/pdf/epub 打包；图片文件夹直接写盘。
- dart:ui 渲染必须在主 isolate（或带 PlatformDispatcher 的 Isolate）执行，打包/IO 仍走现有 isolate；任务可后台、可恢复（复用任务框架与进度）。

### C2. 默认目录
- appdata 新增 `exportLastDirectory`；导出选择器初始目录：记忆值 → `<localPath>/../translated/exports`；成品自动落 `exports/<漫画>/`（images 子目录或对应单文件），成功后记忆。

### C3. 测试
- 单测：暂存树生成（用 1 张 fixture + 假 regions 断言产出 PNG 尺寸/魔数）、未译页策略；flutter analyze/test。

# D. 全链路真机验收（一轮末尾，用户参与）
1. Venera 下载一部拷贝漫画到 downloads（纯净）。
2. BT 配置三个 ComicLibrary 路径 → 打开该漫画翻译两章 → 断言图片目录零产物、workspace 文件齐、旧产物迁移用例通过。
3. BT 下载器下载到 downloads 即为 Venera 布局且无 _source_urls 污染；Venera 本地库正常浏览。
4. Venera 装 NLLB-1.3B/600M、Sugoi（hf-mirror），断网验证 日/韩/英/西/拉丁 测试图；Sugoi 仅日→英；与 BT M2M100 抽句对照。
5. Venera 用已存译文导出 cbz/pdf/epub/图片文件夹到 exports/<漫画>，成品可被 Venera 重新导入且译文可见。
6. 云端 LLM/Google 引擎与原图导出无回归。

## 四、风险与对策
- **BT 硬编码遗漏**：全量 grep 审计 + fixture 自动化断言"图片目录树只有图片"。
- **ONNX 签名差异（KV cache/attention mask/Sugoi 词表）**：v1 统一 no-past 贪心；Sugoi 适配以 B0 实际证据为准，不可行则该引擎延后并明示，其余不受影响。
- **大模型速度/内存**：1.3B 仅在用户选择时装载；逐句+token 上限；saver 性能模式限制预翻译。
- **译文导出性能**：patch 模式零模型依赖；smart 模式标注耗时；dart:ui 渲染的 isolate 约束用主 isolate 渲染队列解决。
- **配置为空/老用户**：全部回退旧行为，迁移均有日志与确认。
- **跨盘移动**：shutil.move 语义即复制+删除，大目录移动前提示。

## 五、明确不做
- BT/Venera 进程级 sidecar 联动（用户已否决）。
- 更改 Venera 桌面默认本地库路径（用户已自行配置）。
