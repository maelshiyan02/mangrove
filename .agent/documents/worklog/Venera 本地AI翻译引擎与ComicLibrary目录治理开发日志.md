# Venera 本地 AI 翻译引擎与 ComicLibrary 目录治理开发日志

> **涉及工程**：VeneraX（Flutter 漫画阅读器，实验性 AI 翻译）＋ BallonsTranslator（桌面汉化工具，下称 BT）
> **Venera 源码**：`d:\Ballonstranslator_Windows\VeneraX-master\VeneraX-master\`（Flutter 3.44.3 / Dart 3.12.2）
> **BT 源码**：`d:\Ballonstranslator_Windows\Ballonstranslator_win_minium\ballontranslator\`
> **文档性质**：跨多轮对话的功能调整思路、代码事实、踩坑记录、简单改动方法与验收基线
> **配套计划**：[comic_library_paths_and_local_nmt_plan.md](file:///d:/Ballonstranslator_Windows/.trae/documents/comic_library_paths_and_local_nmt_plan.md)
> **编写原则**：所有模型参数、token id、接口签名均来自真实文件实测或运行断言；计划中的猜测若被实测推翻，以实测结论为准并明确标注。

---

## 1. 需求起源：两个必须同时解决的问题

### 1.1 Venera 缺多语言本地翻译引擎

Venera 的实验性 AI 翻译管线已具备完整的「OCR → 翻译 → 抹字 → 渲染」骨架，但翻译环节只有两档**在线**方案：OpenAI 兼容 LLM（[llm_translator.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/llm_translator.dart)）与 Google 免费翻译。用户的核心诉求是离线支持 **英文、日文、韩文**，并覆盖漫画中偶尔出现的 **西班牙文、拉丁文**。

### 1.2 BT 产物污染与 Venera「纯净目录」冲突

- Venera 的本地库扫描器 [local_comic_scanner.dart L49-L60](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/utils/local_comic_scanner.dart#L49-L60) 要求章节目录内**出现任何子目录即判整本漫画无效**；理想状态是目录中只有图片（外加 Venera 自己的 `cover.*`、`details.json`），这样可以直接打包 CBZ。
- BT 旧版却把全部工程产物写进图片目录：[proj_imgtrans.py](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/utils/proj_imgtrans.py) 直接在图片目录建 `mask/ inpainted/ result/ assets/ bubcuts/`、`<类型>_<名>.json`、docx、`*_translation.txt / *_source.txt`、`textstyles.json`；下载器每章再写一个 `_source_urls.json`。

> **关键认知：两个工具的产物必须按职责分流。** 下载的生肉目录（`downloads`）永远纯净；BT 的工程文件进 `translated/projects`；两边的汉化成品统一进 `translated/exports`。Venera 的译文数据本身存在 App 自己的 SQLite（`App.dataPath/image_translation.db`，见 [translation_store.dart L110](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_store.dart#L110)），**从设计上就不落漫画目录**，所以它只需要解决「成品导出到哪里」。

---

## 2. 统一目录布局（最终方案）

```
D:\Ballonstranslator_Windows\ComicLibrary\
├─ downloads\                     生肉唯一区 = Venera 本地库根（保持纯净）
│  └─ <漫画>\ cover.webp · details.json · 0\1.webp · 1\2.webp …
└─ translated\
   ├─ projects\                   BT 工程区（嵌套镜像 downloads 的相对路径）
   │  ├─ <漫画>\
   │  │  ├─ manga_<漫画>.json · textstyles.json
   │  │  ├─ mask\ inpainted\ assets\ result\
   │  │  └─ source_urls\ <0,1,2….json> · index.json   （下载清单与章节映射）
   │  └─ _external\<目录名>_<8位hash>\…               打开 downloads 外目录的兜底
   └─ exports\                     成品区（BT 与 Venera 共用默认根）
      └─ <漫画>\  cbz / pdf / epub / images 文件夹
```

| 目录 | 谁写入 | 内容 | 漫画图片目录是否被污染 |
|---|---|---|---|
| `downloads` | Venera 下载 / BT 下载器（Venera 兼容布局） | 仅图片 + `cover.*` + `details.json` | —（本身就是图片目录） |
| `translated/projects` | BT | 工程 json、mask/inpainted/result/assets、txt/docx、下载清单 | 否，全部重定向 |
| `translated/exports` | BT 导出 / Venera 导出 | cbz/pdf/epub/图片文件夹成品 | 否 |
| Venera AppData `image_translation.db` | Venera | 译文 regions、术语表（SQLite） | 否，与漫画目录完全无关 |

---

## 3. A 阶段：BT 路径治理（已完成，40+ fixture 断言通过）

### 3.1 核心思路：建立「唯一路径权威」，禁止各处手拼路径

新增 [workspace.py](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/utils/workspace.py)，所有「图片目录 ↔ 工作区/导出区」的换算集中在这一个无 Qt 依赖的模块里。这样 GUI、headless、下载器、重下失败页等所有调用方拿到的路径永远一致。

**映射规则（一个函数决定）：**
- 源目录在 `manga_source_root` 内 → 工作区 = `translation_workspace_root + 相同相对路径`；
- 源目录在库外任意位置 → `translation_workspace_root/_external/<安全目录名>_<路径sha1前8位>`（同名目录不互相覆盖）；
- 章节目录与漫画级目录导出时归并到同一个 `exports/<漫画名>`；
- **三个根路径任一未配置 → 对应 API 原样返回图片目录（旧行为），保证老用户零破坏。**

### 3.2 改动清单与简单改动方法

| 文件 | 改动 | 维护时怎么改 |
|---|---|---|
| [workspace.py](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/utils/workspace.py)（新增） | 唯一映射权威：`workspace_dir_for()`、`export_root_for()`、`manifest_path_for()`、`write_chapter_manifest()`、`migrate_legacy_project()` 等 | 要改目录规则只动这一个文件；常量 `PROJECT_DIR_NAMES=('mask','inpainted','result','assets')`、`TEMP_DIR_NAMES=('bubcuts','img_folder')`、清单名 `source_urls/index.json` 也在此 |
| [config.py L418-426](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/utils/config.py#L418-L426) | 新增 5 个配置键：`manga_source_root / translation_workspace_root / translation_export_root / download_default_dir`（默认空串）＋ `venera_compatible_download=True` | 新增路径类配置照此加到 ProgramConfig 并给空串默认值 |
| `ui/configpanel.py` | 「漫画库路径」分组：4 个目录选择 + Venera 兼容勾选 + 「一键设为推荐布局」按钮（写入 ComicLibrary 三路径） | — |
| `utils/proj_imgtrans.py`（核心重定向） | `self.directory` 退化为**只读图片源**；新增 `self.workspace`；proj/mask/inpainted/result/assets/bubcuts/docx/txt 路径全部基于 workspace；`to_dict` 增加 `workspace/source_directory` 字段（搬家自愈） | 任何新产物路径一律拼 `self.workspace`，图片读取才用 `self.directory` |
| `ui/mainwindow.py` | 独立 textstyles、章节导出默认 `exports/<漫画>`、最近列表、docx/txt 导出跟随新映射 | grep 所有 `self.directory` / `proj.directory` 拼接点审计 |
| `ui/download_dialog.py` | 输出默认 `download_default_dir`；Venera 布局：`<out>/<漫画>/cover.<ext>` + `<0,1,2>/<1,2….ext>`；章节标题/组/时间戳/源 URL 清单写 `projects/<漫画>/source_urls/<idx>.json` + `index.json` | 图片目录零非图片文件；清单 IO 一律走 `write_chapter_manifest()` |

### 3.3 旧产物一次性迁移（不丢用户数据）

`load()` 打开旧工程时，若发现图片目录旁残留旧 json/mask/inpainted/result/assets/txt/docx：
- **GUI**：通过 `migration_confirm_hook` 弹窗询问是否迁移；
- **headless**：直接迁移（批量场景不交互）；
- 同时处理漫画级项目下各**章节子目录**里的旧产物（`manga_*` 与历史 `imgtrans_*` 两种前缀都认）；
- 移动用「目录按文件合并后删空壳」的 `_merge_move`（跨盘即复制+删除）；
- 全程写 `logs/path_migration.log`，镜像已存在时去重不覆盖较新文件，并同步 recent_proj_list。

---

## 4. B 阶段：Venera 多本地离线翻译引擎（引擎注册表架构）

### 4.1 B0 模型选型闸门——实测推翻了计划中的两点假设

编码推理之前，先对模型文件做真实取证，结论比初版计划更保守、更可靠：

| 事项 | 计划假设 | 实测结论（以 tokenizer.json / 模型文件为准） |
|---|---|---|
| 拉丁语 | 以为 NLLB-200 覆盖 `lat_Latn` | **FLORES-200 没有拉丁语 token**，三档离线引擎全部不支持 `la`；拉丁语只能走在线 LLM |
| 日→英专项 | 计划用 Sugoi | 实际落地 **Opus-MT（Marian）ja→en**，仅约 110 MB；其 normalizer 是 `Precompiled + null charsmap`（no-op） |
| 解码方式 | 不确定 KV cache | 首批 ONNX 均为 **no-past 贪心解码**，v1 不做 batching、不做 KV cache，签名统一 |

**三档引擎（与在线 LLM 共用同一个引擎选择器）：**

| 引擎 id | 模型 | 体积 | 语对 |
|---|---|---|---|
| `nllb_1_3b` | NLLB-200-distilled-1.3B int8 | ~1.9 GB | ja / ko / en / es / zh ↔ zh-TW 等互译（质量档） |
| `nllb_600m` | NLLB-200-distilled-600M int8 | ~0.9 GB | 同上（轻量档） |
| `opus_ja_en` | Opus-MT ja→en（Marian） | ~110 MB | **仅日语→英语** |

**实测解码参数（写死在描述符里，不靠猜）：**

- NLLB：encoder 输入 `[源语言token, …pieces, eos=2]`；decoder 从**强制目标语言 token** 起贪心，`eos=2 / pad=1 / bos=0 / max_length=200`。token id：`jpn_Jpan=256079, kor_Hang=256098, eng_Latn=256047, zho_Hans=256200, zho_Hant=256201, spa_Latn=256161`。
- Opus-MT（Marian）：encoder `[…pieces, eos=0]`；`decoder_start=pad=60715`、`eos=0`、`bad_words=[60715]`、`max=512`。

### 4.2 架构总览：注册表 + 单一分派入口

```
设置页选择器 (appdata: imageTranslationEngine)
        │
TranslationEngines.activeLocal   ← null 表示走云端
        │
TranslationDispatcher.translateBatch()   ← 全 App 唯一翻译入口
   ├── null        → LlmTranslator（现有在线 provider / Google 体系）
   └── 本地描述符  → LocalNmtTranslator → NMT isolate(_NmtEngine)
```

| 文件 | 职责 | 关键事实 |
|---|---|---|
| [translation_engines.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_engines.dart)（新增） | `LocalEngineDescriptor`（id/componentId/kind/eos 等/`supports(src,tgt)`）＋ `TranslationEngines` 注册表 | 云端 id=`'llm'`，设置键 `imageTranslationEngine`；纯函数 `buildEncoderIds / initialDecoderIds`；`supports`：auto 接受、同基语言不互译 |
| [translation_models.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_models.dart) | 3 个 `ModelComponent`，文件名归一为 `encoder.onnx / decoder.onnx / tokenizer.json` | 体积常量 1.93B/0.9B/0.11B；`ocrFor` 中 `en‖es‖la → 英文 OCR`；识别语言 `['zh','en','ko','es','la']` |
| [hf_tokenizer.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/hf_tokenizer.dart) | SentencePiece（Metaspace + BPE/Unigram）解析、编解码 | NFKC 开关见 4.4 |
| [translation_worker.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_worker.dart) | 专用 NMT isolate（`debugName='nmtTranslationWorker'`，线程 clamp(1,4)）；`_NmtEngine` load/translate/_runEncoder/_decodeStep | 切换引擎先 close 旧的；单行异常返回空串保原图；顶层 `hasRepetitionLoop()` 防死机 |
| [local_nmt_translator.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/local_nmt_translator.dart)（新增） | 本地引擎批量翻译外观，输出与在线同构 | 本地档无术语表，与 Google 档一致返回空 glossary |
| [translation_dispatcher.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_dispatcher.dart)（新增） | 全 App 唯一翻译入口 | 阅读页单页路径与预翻译批量路径都走它，二者永不漂移 |
| [translation_pipeline.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_pipeline.dart) | analyzePage 走 dispatcher；`renderPage(bytes, regions, {mode})` | smart 模式先 `TextInpainter.erase` 再渲染；patch 模式零模型依赖 |
| [translation_service.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_service.dart) | `translatePageGroup / isReadyForLang / isReadyForComic`；缓存键 `cacheKeyFor(sourceKey,cid,eid,page)` | 本地漫画 sourceKey 用 `'local'`，页号 **1-based** |

### 4.3 设置 UI 与就绪检查

- [reader.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/pages/settings/reader.dart)：「Translation engine」选择器（云端 LLM ＋ 3 本地档）；源/目标语言增加 es、la（Latin 帮助文案注明无离线引擎）；切换引擎调用 `TranslationModels.invalidateReadyCache()` 刷新就绪态；全局项不传 comicId。
- 「Translation models」副标题 `_translationModelsSubtitle()` 综合三项判断：OCR 是否就绪、活动本地引擎组件是否安装、当前语对是否被该引擎支持。
- [translation_models_settings.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/pages/settings/translation_models_settings.dart)：模型管理重排为三分区——**detector / OCR / Machine translation (offline engines)**；活动引擎的 componentId 计入 requiredIds；英文 OCR 改名「English OCR (also Spanish)」。
- [appdata.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/appdata.dart)：`imageTranslationEngine` 默认 `'llm'`（现状不变），且列为**设备本地不同步**键（多 GB 模型不一定每台机都装）。

### 4.4 三个容易错的语义细节（都有测试锁定）

1. **NFKC 归一化开关**：默认开启（SentencePiece 导出常态）；**仅当** normalizer 是 Map、`type=='Precompiled'` 且 `precompiled_charsmap==null` 时才关闭（Opus-MT no-op）。注意「没有 normalizer 字段」≠「关闭归一化」——这是早期踩过的坑，全角字符在无 normalizer 时仍应折叠成 ASCII。
2. **`zh → zh-TW` 豁免**：简繁转换实际走 OpenCC，**不经过 NMT**。因此引擎语对表拒绝 zh↔zh-TW，但就绪检查与设置副标题对该语对直接返回「就绪」，不能误报「引擎不支持」。
3. **重复环防护**：`hasRepetitionLoop(ids)`（连续 4 个相同 token，或末尾出现 3-token 周期重复）判定解码死机，避免贪心解码无限循环。

---

## 5. C 阶段：Venera 汉化成品导出

### 5.1 译文镜像：让现有打包器「无感知」消费译文

新增 [translated_export.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translated_export.dart)，`TranslatedExport.buildMirror(comic, parentDir, {onProgress})`：

1. 在临时缓存下建 `mirror/`，**重建与原漫画完全一致的布局**（封面在根、章节用 `downloadedChapters` 的数字名作子目录；扁平漫画用 eid `'0'`、页面写根目录）；
2. 逐页用 `cacheKeyFor('local', comic.id, eid, page+1)` 查 `TranslationStore`：
   - 有非空 regions → 主 isolate 内 `renderPage()` 渲染成 **PNG**（扩展名同步改 `.png`），模式取该漫画当前 patch/smart 配置；
   - `null`（从未翻译）或空 list（无文字）→ **逐字节原样复制**；
3. 封面永不翻译，原样复制；
4. 返回一个**故意不注册**到 LocalManager 的 LocalComic：其 `directory` 是含分隔符的绝对路径，`LocalComic.baseDir` 会原样使用，于是 CBZ/PDF/EPUB 打包器可直接消费它，无需在本地库留垃圾条目；
5. 镜像位于导出任务的 cacheDir 下，任务结束 `finally` 自动删除——**生肉目录零接触**。

> dart:ui 的 Canvas/Picture/toByteData 必须在主 isolate，所以渲染留在主 isolate async 循环；只有图片文件夹的整树复制用 `copyDirectoryIsolate` 防 UI 冻结。

### 5.2 导出格式与任务框架改动（[export_tasks.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/export_tasks.dart)）

- `ExportFormat` 新增 `images('')` 与 `isDirectoryOutput` / `label='Image folder'`；`_buildToCache()` 对 images 显式抛 `UnsupportedError`（它没有单一产物文件）。
- `ExportTask` 新增持久化字段 `useTranslations`（JSON 键同名，旧任务缺键默认 false）；`startExport()` 增参；**merged 的 venera_comics 单遍打包无法消费镜像，强制 false**。
- `_run()` 循环分流：文件格式走原有 build→流式 copy；images 格式把目标当成 Directory，普通导出复制原漫画树、译文导出复制 mirror 树（isolate）。resume 的「目标已存在则跳过」对文件/目录两种目标都成立。
- [cbz.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/utils/cbz.dart) 与 [epub.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/utils/epub.dart) 两处取图改为 public 的 `getImagesForComic(comic, ep)`（不经 `find`，因此能读未注册镜像），并显式剥掉 `file://` 前缀；PDF 导出本就按绝对路径自己 listSync，天然兼容镜像。

### 5.3 统一选项对话框与默认目录（[local_comics_page.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/pages/local_comics_page.dart)）

- CBZ / PDF / EPUB / 图片文件夹四种格式共用一个 `_showExportOptions()` 对话框：一个「Render stored translations」开关（**默认关＝原图导出**）＋目标文件夹显示与「Change」按钮；菜单新增「Export as image folder」。
- 默认目录 `_suggestedExportFolder()`：优先读记忆值 `exportLastDirectory`，否则建议 `<本地库>/../translated/exports`（本机即 `D:\Ballonstranslator_Windows\ComicLibrary\translated\exports`），选定后写回 appdata。
- 前台进度监听抽成 `_trackExportProgress()`，普通导出与 `.venera_comics` 流程共用；译文镜像阶段在标题显示 `(done/total)` 页级进度。
- 注意组件契约：项目内 `ContentDialog.title` 只接受 **`String?` 不是 Widget**（analyze 会报 `argument_type_not_assignable`）。

---

## 6. 历次错误、根因与修复决策

| 错误/风险 | 表现 | 根因 | 修复 | 防复发规则 |
|---|---|---|---|---|
| NFKC 开关误判 | 全角字符在 Opus 下被错误归一化 | 把「无 normalizer」也当成关闭 NFKC | 默认 true，仅 Precompiled+null charsmap 才 false | 两种情形各写断言 |
| zh→zh-TW 报「引擎不支持」 | 简繁页无法就绪 | 用 NMT 语对表衡量 OpenCC 语对 | reader 副标题与 `isReadyForLang` 两处豁免 | 特殊语对单独列规则 |
| 错误 import | analyze uri_does_not_exist | 写成 `package:venera/log.dart` | 实际路径 `package:venera/foundation/log.dart` | 以 analyze 为准 |
| ContentDialog 传 Widget | analyze 类型错误 | 套用了 Material AlertDialog 习惯 | title 传 String | 用项目自有组件先看构造签名 |
| 无效 `src == null` 判断 | unnecessary_null_comparison | 上游 `??=` 后 src 已非空 | 删除冗余判断 | — |
| 测试 const set 重复元素 | equal_elements_in_const_set | 两个 spread 集合有交集 | 合并为单个 set 字面量 | — |
| BPE fixture 期望落空 | `'a'` 编出 `[1,2]` 而非 `[3]` | 空 merges 时多字符词表 token 本应由 merge 规则产生 | fixture 补 `'▁ a'` merge；未归一化全角字符断言 `[1,0]`（marker+unk） | 测试 fixture 要符合真实 tokenizer 语义 |
| 同步分类测试失败 | `sync_skip_test` 红 | `imageTranslationHfEndpoint` 同时在用户可选同步类别与强制 `_disableSync` 中 | 从 `_disableSync` 移除（端点选择可同步；只有引擎 id 与导出路径设备本地） | 新建设置键二选一归属 |
| GitHub 依赖拉不下来 | git early EOF / 并发挂死 | 直连 github.com 443 超时；公共加速并发限流 | 发现本机 Clash `127.0.0.1:7890`；串行 mirror 10 个仓库到本地，再用 git `insteadOf` 重写到 `file:///` 本地镜像 | 见第 7 节 |
| pub get 符号链接失败 | `flutter pub get` 退出码 1 | 沙箱禁止创建目录符号链接（Windows 开发者模式/权限） | analyze/test 不依赖 symlink，可正常跑；`flutter build windows` 需在沙箱外执行一次 | 桌面打包前沙箱外 pub get |

---

## 7. 开发环境搭建（本机无 Flutter SDK，全程不污染系统盘）

所有 Flutter 相关数据统一放 `D:\Ballonstranslator_Windows\flutter_sdk\`：

| 项 | 值/做法 |
|---|---|
| SDK | Flutter 3.44.3（与 pubspec 约束一致）解压于 `flutter_sdk\flutter` |
| `PUB_CACHE` | `flutter_sdk\pub_cache`（默认的 `AppData\Local\Pub` 在沙箱内 errno=5） |
| `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL` | `https://pub.flutter-io.cn` / `https://storage.flutter-io.cn` |
| `APPDATA` / `LOCALAPPDATA` / `USERPROFILE` / `HOME` | 全部重定向到 `flutter_sdk\appdata_roaming / appdata_local / fakehome`（否则 flutter tool state、Dart analysis server 写真实 AppData 被沙箱拒） |
| GitHub git 依赖 | pubspec 有 10 个 `github.com/venera-app/*` git 依赖。经本机代理 `http://127.0.0.1:7890` 串行 `git clone --mirror` 到 `flutter_sdk\gh_mirror\<repo>.git`，再在独立 gitconfig 配 `url.file:///D:/.../gh_mirror/.insteadOf = https://github.com/venera-app/`，`GIT_CONFIG_GLOBAL` 指向该 gitconfig |
| 常用命令 | 先 set 上述环境变量，再跑 `flutter pub get` / `flutter analyze` / `flutter test` |

PowerShell 5 注意用 `;` 不用 `&&`；执行策略红字是噪音，看 `$LASTEXITCODE` 即可。

---

## 8. 验证体系与结果

| 验证 | 命令/内容 | 结果 |
|---|---|---|
| 静态检查 | `flutter analyze` | **0 error / 0 warning**；13 条 info 全部是项目既有风格基线（prefer_initializing_formals 等），与本次改动无关 |
| 定向单测 | `translation_engines_test`（注册表/语对矩阵/framing/重复环）、`hf_tokenizer_test`（NFKC 开关）、`export_task_test`（images 格式/useTranslations 持久化）、`translation_worker_policy_test`（OCR 聚类策略） | 48/48 通过 |
| 全量测试 | `flutter test` | **832/832 全部通过** |
| BT 侧 | workspace 映射、旧产物迁移、纯净目录 fixture | 40+ 断言通过（A 阶段） |

测试锁定的关键不变量：NLLB framing `[256079,10,11,2]` / decoder 初值 `[256200]`、缺语言 token 抛 `ArgumentError`；Marian framing `[10,11,0]` / `[60715]`；`la` 被所有离线引擎拒绝、`auto` 被接受、Opus 仅 ja→en；images 格式 `ext==''` 且 `isDirectoryOutput==true`；`useTranslations` 缺键默认 false。

---

## 9. 后续简单改动方法（可复用操作手册）

1. **再加一个离线翻译引擎**：① 在 [translation_models.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_models.dart) 注册 `ModelComponent`（encoder/decoder/tokenizer 三件套）；② 在 [translation_engines.dart](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/lib/foundation/image_translation/translation_engines.dart) 加一个 `LocalEngineDescriptor`（语对矩阵、eos/bos、token 名）。同族 NLLB 直接复用 `_NmtEngine`；新模型族才需要在 worker 里加 framing 分支。pipeline/dispatcher/UI **无需改动**，选择器与模型分区会自动出现。
2. **改翻译产物/成品的落点**：只改 BT 的 [workspace.py](file:///d:/Ballonstranslator_Windows/Ballonstranslator_win_minium/ballontranslator/utils/workspace.py) 映射，或 Venera 的 `_suggestedExportFolder()`；不要在业务代码里再手拼绝对路径。
3. **新增导出格式**：在 `ExportFormat` 加枚举（区分单文件/目录输出），补 `_buildToCache` 分支或目录复制分支，并在 export_task_test 加 ext/label/isDirectoryOutput 断言。
4. **排查「翻译就绪」问题**：按 detector → OCR（注意 es/la 复用英文 OCR）→ MT 组件 → 语对支持（zh→zh-TW 走 OpenCC）四层依次看 `_translationModelsSubtitle` 与 `isReadyForLang`。
5. **译文从不出现在漫画目录**：Venera 译文只在 AppData 的 `image_translation.db`；要把译文变成可见成品，必须显式走导出（镜像渲染）。

---

## 10. 已知限制与明确不做

- **拉丁语无离线引擎**（FLORES-200 无对应 token），只能走在线 LLM；UI 已注明。
- 本地 NMT v1 为**逐句 no-past 贪心解码**，不做 batching / beam search / KV cache；Opus-MT 仅 ja→en。
- 切换引擎**不会主动失效**旧译文缓存（缓存键按语言对而非引擎）；需要新引擎结果时手动 retranslate。
- 图片文件夹格式只面向真实文件系统（桌面为主），不做 Android SAF 的目录回退。
- 不做 BT↔Venera 进程级 sidecar 联动；不改 Venera 桌面默认本地库路径（用户已自行配置为 downloads）。

## 11. D 阶段真机验收清单（待用户参与）

- [ ] 三个离线引擎分别安装后**断网**：日/韩/英→中、西语走 NLLB；Opus 仅日→英；拉丁语正确提示走在线。
- [ ] BT 配置 ComicLibrary 三路径，打开 downloads 内漫画翻译两章：图片目录零产物，projects 文件齐全，旧产物迁移有日志。
- [ ] BT 下载器下载到 downloads 即 Venera 布局（cover + 数字章节目录），无 `_source_urls.json` 污染，Venera 能直接浏览。
- [ ] Venera 翻译后分别导出 CBZ/PDF/EPUB/图片文件夹（译文开关 开/关 各一次），落 `translated/exports/<漫画>/`，可被 Venera 重新导入且译文可见。
- [ ] 云端 LLM/Google 与原图导出无回归；导出大漫画时 UI 不卡死、任务可后台/恢复。
- [ ] 桌面正式打包前，在沙箱外执行一次 `flutter pub get`（生成插件符号链接）再 `flutter build windows`。
