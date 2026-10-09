// S9.5-b · 阅读侧读工程产物的断言集。
//
// ## 为什么单独一个文件
//
// 同 P1 / P7 的理由：`headless.dart` 已经 3100 行，把断言塞进去会让"再加一条"
// 变成"动核心文件"，而那正是最该被看到的断言被跳过的路径。
//
// ## 这一批钉的是什么
//
// S9.5-b 把阅读器的**图片来源**整个换掉了：从"读时即时翻译"改成"读工程产物"。
// 换掉之后，出错的形态全部是**静默**的 —— 用户看到一张图，看不出它是不是错的：
//
// * 选错了产物 ⇒ 少一层译文（看着像"这一页本来就没字"）；
// * 页键映射错 ⇒ 显示**另一页**的图（完全正常的一张图）；
// * 只有底图没有块却重绘 ⇒ 一张去字的白页（看着像"翻译把字弄没了"）；
// * 绑定按 cid 而不是按章存 ⇒ 第二章静默覆盖第一章。
//
// 所以每一条断言都写成"**判据 + 一个故意做错的同类实现**"：绿路径喂正确实现，
// 红路径喂那一个错误实现，**同一个判据**必须翻脸。判据恒真 = 装饰品。
//
// ## 为什么必须有纯逻辑层
//
// 本会话没有渲染表面（`A01 §3`），像素级的差异只能人工验。所以"读哪一份"这件事
// 被抽到 `studio_reader.dart`（零 Flutter / 零 dart:io 依赖），才第一次能被
// headless 真正验完 —— 这一条本身也是一条断言（`reader.decision_layer_is_pure`）。
library;

import 'dart:io';

import 'package:mangrove/foundation/translation_project/studio_reader.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

const _readerImagesPath = 'lib/pages/reader/images.dart';
const _readerImageProviderPath =
    'lib/foundation/image_provider/reader_image.dart';
const _decisionPath = 'lib/foundation/translation_project/studio_reader.dart';
const _appPath = 'lib/foundation/translation_project/studio_reader_app.dart';
const _enqueuePath = 'lib/foundation/translation_project/studio_enqueue.dart';
const _readerSettingsPath = 'lib/pages/settings/reader.dart';
const _tasksPath =
    'lib/foundation/image_translation/pre_translation_tasks.dart';
const _tasksPagePath = 'lib/pages/tasks_page.dart';
const _toolPath = 'lib/headless_pipeline_check.dart';
const _initPath = 'lib/init.dart';

class _Probe {
  const _Probe(this.name, this.green, this.red, this.detail);

  final String name;
  final bool Function() green;
  final bool Function() red;
  final String Function() detail;
}

void runP8Checks(
  CheckSink check, {
  required Directory packageRoot,
}) {
  final probes = <_Probe>[];
  void probe(
    String name,
    bool Function() green,
    bool Function() red,
    String Function() detail,
  ) {
    probes.add(_Probe(name, green, red, detail));
  }

  String code(String rel) =>
      File('${packageRoot.path}/$rel').readAsStringSync();
  bool codeHas(String rel, String needle) => code(rel).contains(needle);

  // ── 1 · 来源优先级（`chooseReaderPageSource`） ─────────────────────────

  probe(
    'result_bitmap_wins_over_re_rendering',
    // 有成品就不重绘：重绘要解码 + 上色，而成品是已经排好版的那一张。
    () =>
        chooseReaderPageSource(
          hasResult: true,
          hasInpainted: true,
          hasBlocks: true,
        ) ==
        ReaderPageSource.projectResult,
    // 故障路径 = "先看底图"（把顺序反过来）。
    () => _renderFirst(hasResult: true, hasInpainted: true, hasBlocks: true) ==
        ReaderPageSource.projectResult,
    () => '绿=有 result 取 result / 故障=先看 inpainted 的实现会落到 projectRender',
  );

  probe(
    'missing_result_re_renders_from_the_base',
    // 工作室刚改完、`result/` 还没重生成的那一页，只有这条路立刻反映编辑。
    () =>
        chooseReaderPageSource(
          hasResult: false,
          hasInpainted: true,
          hasBlocks: true,
        ) ==
        ReaderPageSource.projectRender,
    // 故障 = "只要没有成品就回原图"（S9.5-a 之前那段补不上的空档）。
    () => _resultOnly(hasResult: false, hasInpainted: true, hasBlocks: true) ==
        ReaderPageSource.projectRender,
    () => '绿=无 result 有底图则现绘 / 故障=只认 result 的实现会回原图',
  );

  probe(
    'erased_base_without_blocks_is_never_rendered',
    // 🔴 这一条是整批里最要紧的：只有底图没有块时重绘 = 一张**去字的白页**，
    // 比原图更糟 —— 用户会以为"翻译把字弄没了"。
    () =>
        chooseReaderPageSource(
          hasResult: false,
          hasInpainted: true,
          hasBlocks: false,
        ) ==
        ReaderPageSource.original,
    // 故障 = 忽略 `hasBlocks`（"有底图就画"）。
    () => _ignoreBlocks(hasResult: false, hasInpainted: true, hasBlocks: false) ==
        ReaderPageSource.original,
    () => '绿=有底图无块 → 原图 / 故障=忽略 hasBlocks 的实现会去重绘白页',
  );

  probe(
    'no_artifact_at_all_is_the_original',
    // 没跑过管线的章页照旧显示原图（这也正是"关开关就回原图"的落点）。
    () =>
        chooseReaderPageSource(
          hasResult: false,
          hasInpainted: false,
          hasBlocks: false,
        ) ==
        ReaderPageSource.original,
    // 故障 = 无条件重绘。
    () => _alwaysRender(
              hasResult: false,
              hasInpainted: false,
              hasBlocks: false,
            ) ==
        ReaderPageSource.original,
    () => '绿=无产物 → 原图 / 故障=无条件重绘的实现不返回原图',
  );

  // ── 2 · 页键映射（阅读器绝对路径 → 工程页键） ─────────────────────────

  probe(
    'relative_key_strips_the_comic_root',
    () => relativePageKey(
          'file://D:/lib/Comic Library/我的漫画/1 [Asura Scans]/1.webp',
          r'D:\lib\Comic Library\我的漫画',
        ) ==
        '1 [Asura Scans]/1.webp',
    // 故障 = 只取文件名。取名会在多章漫画上撞车（每一话的第一页都叫
    // `1.webp`），而且撞车之后**看不出错**——只是显示了别一话的图。
    () => _basenameKey(
          'file://D:/lib/Comic Library/我的漫画/1 [Asura Scans]/1.webp',
          r'D:\lib\Comic Library\我的漫画',
        ) ==
        '1 [Asura Scans]/1.webp',
    () => '绿=剥掉漫画根得到相对页键 / 故障=只取文件名时判据不成立',
  );

  probe(
    'path_outside_the_comic_root_is_rejected',
    // 🔴 前缀不匹配必须返回 null，**绝不猜**。猜错的后果是给用户看另一页。
    () =>
        relativePageKey(
          'file://D:/other/另一本漫画/1.webp',
          r'D:\lib\Comic Library\我的漫画',
        ) ==
        null,
    // 故障 = 取名兜底（`_basenameKey` 对任何路径都给得出一个键）。
    () =>
        _basenameKey(
          'file://D:/other/另一本漫画/1.webp',
          r'D:\lib\Comic Library\我的漫画',
        ) ==
        null,
    () => '绿=外来路径 → null / 故障=取名兜底会给出一个"看起来正常"的键',
  );

  probe(
    'same_basename_in_two_chapters_does_not_collide',
    // `第1话/1.webp` 与 `第2话/1.webp` 的 `1.webp` 完全相同 —— 这条判据存在
    // 的全部理由就是这一种撞车。
    () =>
        projectPageKeyFor(
          projectPageKeys: const ['第1话/1.webp', '第2话/1.webp'],
          imagePath: 'file://D:/lib/我的漫画/第2话/1.webp',
          comicDirectory: r'D:\lib\我的漫画',
        ) ==
        '第2话/1.webp',
    // 故障 = 按文件名匹配，两话都命中第一条。
    () =>
        _basenameMatch(
          projectPageKeys: const ['第1话/1.webp', '第2话/1.webp'],
          imagePath: 'file://D:/lib/我的漫画/第2话/1.webp',
          comicDirectory: r'D:\lib\我的漫画',
        ) ==
        '第2话/1.webp',
    () => '绿=相对路径精确对应 / 故障=按文件名匹配会取到第 1 话那一页',
  );

  probe(
    'separators_and_drive_case_are_normalised',
    // 工程 json 里可能是 `0\1.webp` 而磁盘上是 `0/1.webp`；`D:` 与 `d:` 是
    // 同一个盘。字符串比较区分这三者，而它们指的是同一页。
    () =>
        projectPageKeyFor(
          projectPageKeys: const [r'0\1.webp'],
          imagePath: 'file://d:/lib/c/0/1.webp',
          comicDirectory: 'D:/lib/c/',
        ) ==
        r'0\1.webp',
    // 故障 = 原样比较（分隔符 / 大小写都算差异）。
    () =>
        _rawCompare(
          projectPageKeys: const [r'0\1.webp'],
          imagePath: 'file://d:/lib/c/0/1.webp',
          comicDirectory: 'D:/lib/c/',
        ) ==
        r'0\1.webp',
    () => '绿=归一化后命中 / 故障=原样比较会落空',
  );

  // ── 3 · 绑定表 ───────────────────────────────────────────────────────

  probe(
    'binding_key_carries_the_chapter',
    // 🔴 一个工程就是一"章"（`ProjectBootstrap.plan` 按 comicDirectory +
    // chapterName 建）。按 cid 一个键会让第二章静默覆盖第一章的绑定 ——
    // 覆盖之后界面完全正常，只是读错了工程。
    () =>
        StudioReaderBindings.key(cid: 'c1', sourceKey: 's1', eid: 'e1') !=
        StudioReaderBindings.key(cid: 'c1', sourceKey: 's1', eid: 'e2'),
    // 故障 = 键里不带 eid。
    () => _cidOnlyKey('c1', 's1', 'e1') != _cidOnlyKey('c1', 's1', 'e2'),
    () => '绿=键带 eid 两章不同 / 故障=只带 cid 时两章是同一个键',
  );

  probe(
    'null_source_key_normalises_to_empty_not_null_literal',
    // 阅读器拼的是 `'$cid@${sourceKey ?? ''}@$eid'`。若这里拼成字面量 `null`，
    // 同一本漫画会在两条路径上有两个键 —— 写进 A、读的是 B，于是"绑定没生效"
    // 而且看不出为什么。
    () =>
        StudioReaderBindings.key(cid: 'c1', sourceKey: null, eid: 'e1') ==
        'c1@@e1',
    () => _interpolateNullKey('c1', null, 'e1') == 'c1@@e1',
    () => '绿=null 源键拼成空 / 故障=直接插值时拼成字面量 null',
  );

  probe(
    'a_binding_missing_a_field_is_rejected_whole',
    // 🔴 半条绑定比没有绑定更危险：它会以"有工程"的身份通过判据，然后在读页键
    // 时静默落原图 —— 界面上就是"译文没出来"，没有任何线索。
    () =>
        StudioReaderBinding.fromJson({'json': '/p/imgtrans_p.json'}) == null &&
        StudioReaderBinding.fromJson({'comicDirectory': '/d/c'}) == null &&
        StudioReaderBinding.fromJson('not a map') == null,
    // 故障 = 缺字段时给默认值（于是"半条"也活了下来）。
    () =>
        _lenientBinding({'json': '/p/imgtrans_p.json'}) == null,
    () => '绿=缺 json/comicDirectory 整条作废 / 故障=宽松解析会留下半条',
  );

  probe(
    'a_read_modify_write_drops_corrupt_entries',
    // 坏条目在**读**的时候跳过、在**写**的时候不复制 ⇒ 一次读-改-写自然清掉，
    // 不需要一个"清理"按钮（也就不会有人忘记点它）。
    () => _dropsCorruptEntries(_tableWithCorruptEntry().toJson()),
    // 故障 = 写回时原样搬运（坏条目留下来，每次启动都被重新解析一遍）。
    () => _dropsCorruptEntries(_verbatimRoundTrip()),
    () => '绿=坏条目在读时被跳过、写时被丢弃 / 故障=原样搬运会把它留下',
  );

  probe(
    'binding_roundtrips_through_json',
    () => _bindingSurvivesRoundTrip(_tableWithCorruptEntry().toJson()),
    // 故障 = 写回时只留一半字段（于是读回来整条作废）。
    () => _bindingSurvivesRoundTrip(_truncatedRoundTrip()),
    () => '绿=写-读往返一致 / 故障=只留 json 键时读回来是 null',
  );

  probe(
    'binding_carries_the_origin_identity',
    // 工作室手里只有工程 id（`bt_<hash>`），术语表的 scope 只能经绑定表反查回来。
    // 丢了这两个字段，工作室会回落成 `comicId` —— 而**一个工程 = 一章** ⇒ 同一本
    // 漫画的 20 章各有一份互不相通的术语表，界面上完全看不出来。
    () {
      final table = StudioReaderBindings();
      table.put(
        'c1@s1@e1',
        const StudioReaderBinding(
          jsonPath: '/p/imgtrans_p.json',
          comicDirectory: '/d/c',
          projectDirectory: '/p/source',
          originScope: 'c1@s1',
          group: 'Asura Scans',
        ),
      );
      // 走一遍 json：表里存的就是 json，内存里对得上不代表盘上对得上。
      final read = StudioReaderBindings.from(table.toJson())['c1@s1@e1'];
      return read != null &&
          read.originScope == 'c1@s1' &&
          read.group == 'Asura Scans';
    },
    // 故障 = 写回时漏掉这两个键的那一版（读回来是空串 ⇒ 反查失效）。
    () {
      final read = StudioReaderBindings.from({
        'c1@s1@e1': const {
          'json': '/p/imgtrans_p.json',
          'comicDirectory': '/d/c',
          'projectDirectory': '/p/source',
        },
      })['c1@s1@e1'];
      return read != null &&
          read.originScope == 'c1@s1' &&
          read.group == 'Asura Scans';
    },
    () => '绿=来源身份写-读往返一致 / 故障=漏写时读回来是空串',
  );

  probe(
    'legacy_binding_without_the_origin_still_parses',
    // 🔴 加字段不得让老条目整条作废：整条作废会让阅读器**读不到产物** —— 比
    // "术语表回落成 comicId"严重得多。
    () {
      final read = StudioReaderBinding.fromJson({
        'json': '/p/imgtrans_p.json',
        'comicDirectory': '/d/c',
      });
      return read != null && read.originScope.isEmpty && read.group.isEmpty;
    },
    // 故障 = 把"来源身份"也当成必填字段的那一版解析。
    () => _strictBinding({
          'json': '/p/imgtrans_p.json',
          'comicDirectory': '/d/c',
        }) !=
        null,
    () => '绿=老绑定照旧可读（来源为空）/ 故障=把新字段当必填时会整条作废',
  );

  probe(
    'reverse_lookup_ignores_path_shape',
    // 写绑定那边是 `Directory` 拼出来的，工作室那边是 `File.path` —— 两者可能差
    // 一个斜杠方向或盘符大小写。"差一点就算不上"的后果是术语表**静默**回落。
    () {
      final table = StudioReaderBindings();
      table.put(
        'c1@s1@e1',
        const StudioReaderBinding(
          jsonPath: r'D:\Mangrove_Windows\p\imgtrans_p.json',
          comicDirectory: '/d/c',
          projectDirectory: '/p/source',
          originScope: 'c1@s1',
        ),
      );
      final hit = table.forJsonPath('d:/mangrove_windows/p/imgtrans_p.json');
      return hit?.originScope == 'c1@s1';
    },
    // 故障 = 拿路径直接做字符串比较（形状不同就查不到）。
    () {
      const stored = r'D:\Mangrove_Windows\p\imgtrans_p.json';
      const asked = 'd:/mangrove_windows/p/imgtrans_p.json';
      return stored == asked;
    },
    () => '绿=反查容忍斜杠/大小写 / 故障=直接字符串比较时查不到',
  );

  // ── 4 · 还要跑哪些页 ────────────────────────────────────────────────

  probe(
    'pages_needing_work_judge_on_result_not_on_intermediates',
    // 🔴 S9.5-a 的 78 页正是"有 inpainted 没有 result"。拿中间态当"跑过了"，
    // 那一批页会**永远**不再被处理 —— 而且没有任何地方会报出来。
    () =>
        studioPagesNeedingWork(
          chapterPages: const ['0/1.webp', '0/2.webp', '0/3.webp'],
          pagesWithResult: const {'0/1.webp'},
        ).join(',') ==
        '0/2.webp,0/3.webp',
    // 故障 = 用中间产物当"已完成"。
    () =>
        _intermediateAsDone(
          chapterPages: const ['0/1.webp', '0/2.webp', '0/3.webp'],
          pagesWithResult: const {'0/1.webp'},
          pagesWithIntermediates: const {'0/1.webp', '0/2.webp'},
        ).join(',') ==
        '0/2.webp,0/3.webp',
    () => '绿=只按 result 判 / 故障=按中间态判时 0/2 会被跳过',
  );

  probe(
    'pages_needing_work_keeps_reading_order',
    // 执行顺序就是阅读顺序：跑出来的进度条与用户翻页的顺序一致。
    () =>
        studioPagesNeedingWork(
          chapterPages: const ['0/2.webp', '0/10.webp'],
          pagesWithResult: const {},
        ).join(',') ==
        '0/2.webp,0/10.webp',
    // 故障 = 排序去重（`0/10.webp` 会跑到 `0/2.webp` 前面 —— 字符串序不是
    // 阅读序，正是 `ProjectBootstrap._pageNameCompare` 专门处理的那件事）。
    () =>
        _sortedPages(
          chapterPages: const ['0/2.webp', '0/10.webp'],
          pagesWithResult: const {},
        ).join(',') ==
        '0/2.webp,0/10.webp',
    () => '绿=保持调用方给的阅读顺序 / 故障=字符串排序把 0/10 排到 0/2 之前',
  );

// ── 5 · 接线（静态扫描 + 对照组） ────────────────────────────────────

  probe(
    'chapter_page_keys_are_restricted_to_that_chapter',
    // 工程可能被工作室手工加过别章的页（或工程名与章节目录名不一致）。
    // 入队时把**别话的页**跑进来 = 白烧一次 LLM，而且产物落在别话的键上。
    () =>
        studioChapterPageKeys(
          projectPageKeys: const ['第1话/1.webp', '第1话/2.webp', '第2话/1.webp'],
          chapterName: '第2话',
        ).join(',') ==
        '第2话/1.webp',
    // 故障 = 不做前缀过滤（整本工程都跑）。
    () =>
        _allPages(
          projectPageKeys: const ['第1话/1.webp', '第1话/2.webp', '第2话/1.webp'],
          chapterName: '第2话',
        ).join(',') ==
        '第2话/1.webp',
    () => '绿=只留这一章的页 / 故障=不按章节过滤会带上第 1 话的两页',
  );

  probe(
    'chapter_prefix_does_not_match_a_longer_sibling',
    // 🔴 `第1话` 是 `第1话-番外` 的前缀。判据必须是 `'<章>/'`（带分隔符），
    // 否则番外话的页会被当成正片的页跑进来，而产物键看起来完全正常。
    () =>
        studioChapterPageKeys(
          projectPageKeys: const ['第1话/1.webp', '第1话-番外/1.webp'],
          chapterName: '第1话',
        ).join(',') ==
        '第1话/1.webp',
    // 故障 = 不带分隔符的前缀匹配。
    () =>
        _prefixWithoutSlash(
          projectPageKeys: const ['第1话/1.webp', '第1话-番外/1.webp'],
          chapterName: '第1话',
        ).join(',') ==
        '第1话/1.webp',
    () => '绿=带斜杠前缀只命中正片 / 故障=裸前缀会把番外话一起收进来',
  );

  probe(
    'empty_chapter_name_means_the_whole_project',
    // 无章节的漫画：页直接躺在工程根下，没有目录前缀。此时**全部**页都属于
    // 这一"章"。返回空列表会让入队判成 `noPage`，用户看到"这一章没有可读的
    // 页面图"——而页其实好端端地在那儿。
    () =>
        studioChapterPageKeys(
          projectPageKeys: const ['1.webp', '2.webp'],
          chapterName: '',
        ).join(',') ==
        '1.webp,2.webp',
    // 故障 = 空前缀 → 空前缀 + '/' 什么都匹配不到。
    () =>
        _prefixWithoutSlash(
          projectPageKeys: const ['1.webp', '2.webp'],
          chapterName: '',
        ).join(',') ==
        '1.webp,2.webp',
    () => '绿=无章节漫画取全部页 / 故障=拼成 "/" 前缀会一页都取不到',
  );

  probe(
    'switch_queues_the_chapter_instead_of_translating_on_read',
    // 交付 1 的落点：开关的动作是**入队**（建/复用工程 + 排任务），而开关的
    // **真相**是绑定表 —— 不是 `appdata` 里的一个布尔。
    () => _switchQueuesTheChapter(code(_readerSettingsPath)),
    // 故障路径 = 旧写法（只写一个布尔设置、算一个翻译缓存键）。
    () => _switchQueuesTheChapter(
      'ImageTranslationService.setEnabledForComic(cid, sourceKey, v);\n'
      'translationKey = ImageTranslationService.cacheKeyFor(a, b, c, d);',
    ),
    () => '绿=开关入队 + 按绑定取真相 / 故障=旧写法（布尔设置 + 缓存键）不满足',
  );

  probe(
    'one_chapter_loop_is_shared_by_the_tool_and_the_app',
    // 🔴 `P9.6 §四`：工装验的必须是产品跑的那条路。整章循环只有一份实现
    // （`StudioChapterRunner`），工装与阅读侧入队都调它。
    () =>
        _oneChapterLoop(
          code(_toolPath),
          code(_enqueuePath),
        ),
    // 故障路径 = 应用侧手写一个循环（自己 for + 自己 ProjectWriter.save）。
    () => _oneChapterLoop(
      code(_toolPath),
      'for (final pageKey in pending) {\n'
      '  await ProjectWriter.save(root: project.workspace, project: project);\n'
      '}',
    ),
    () => '绿=两侧都调 StudioChapterRunner.run / 故障=应用侧另写一套循环不满足判据',
  );

  probe(
    'studio_cancellation_actually_reaches_the_token',
    // V1 的"可取消"：任务卡上的取消必须让管线在页边界停下。只把卡片从列表里
    // 挪走 = 后台照样跑完一整章。
    () => _studioCancellationReachesTheToken(code(_tasksPath)),
    // 故障路径 = 没有那一行（取消只改状态）。
    () => _studioCancellationReachesTheToken(
      'void cancel(String id) {\n  _canceledIds.add(id);\n}',
    ),
    () => '绿=cancel 里点了令牌 / 故障=不点令牌时判据不成立',
  );

  probe(
    'task_framework_stays_out_of_the_studio_engine',
    // 🔴 交付 4 的红线：**只接展示**。旧引擎的任务框架不该认识
    // `StudioChapterRunner` —— 执行体是注入进来的，框架只知道"有个东西在跑"。
    () => _taskFrameworkStaysOutOfTheStudioEngine(code(_tasksPath)),
    // 故障路径 = 框架直接 import 并调用工作室的整章循环。
    () => _taskFrameworkStaysOutOfTheStudioEngine(
      'studioRunner;\n'
      "import 'package:mangrove/foundation/translation_project/"
      "studio_chapter_runner.dart';\n"
      'await StudioChapterRunner.run(project: p, pageKeys: k, options: o);',
    ),
    () => '绿=框架只有注入点 studioRunner / 故障=直接调 StudioChapterRunner 不满足',
  );

  probe(
    'pause_is_not_offered_for_studio_tasks',
    // `StudioChapterRunner` 只认 `CancellationToken`，没有暂停。画一个按下去
    // 没反应的暂停键 = UI 在说谎，所以按钮和管理层都要挡住。
    () =>
        _pauseIsHiddenForStudioTasks(code(_tasksPagePath), code(_tasksPath)),
    // 故障路径 = 少了管理层的守卫（status 会变成 paused 而管线在继续跑）。
    () => _pauseIsHiddenForStudioTasks(
      code(_tasksPagePath),
      'void pause(String id) {\n  task.status = paused;\n}',
    ),
    () => '绿=按钮与管理器都挡 studio / 故障=管理器不挡时 paused 是假状态',
  );

  probe(
    'studio_runner_is_registered_before_resuming_pending_tasks',
    // 🔴 顺序即契约：先装执行体再续跑。反过来的话，上次会话遗留的 studio 任务
    // 会因为 `studioRunner is null` 被标成 failed —— 一个由启动顺序制造出来、
    // 没有任何线索的失败。
    () => _registeredBeforeResume(code(_initPath)),
    // 故障路径 = 顺序颠倒（同一判据喂一段反过来的源码）。
    () => _registeredBeforeResume(
      'PreTranslationTaskManager.instance.resumePendingTasks();\n'
      'registerStudioTaskRunner();',
    ),
    () => '绿=先注册后续跑 / 故障=顺序颠倒时判据不成立',
  );

  probe(
    'decision_layer_is_pure',
    // 🔴 这一条是"上面那些断言能被跑起来"的前提：`studio_reader.dart` 只要
    // import 了 flutter / dart:ui / dart:io，headless 里就再也验不动它
    // （`A01 §3` 没有渲染表面；`init()` 之前也没有 appdata）。
    () => _importsNoneOf(
      packageRoot,
      _decisionPath,
      const ['dart:ui', 'dart:io', 'package:flutter'],
    ),
    // 🔴 同一个判据喂给 app 侧文件：它**真的** import 了 `dart:io`（要读 json），
    // 所以判据在那里为 false ⇒ 说明这条扫描真的能看见 import。
    () => _importsNoneOf(packageRoot, _appPath, const ['dart:io']),
    () => '绿=纯逻辑层不碰 io/ui/flutter / 故障=app 侧对照组确实碰 dart:io',
  );

  probe(
    'reader_image_path_never_asks_the_engine_whether_a_page_is_translated',
    // 🔴 V4 的断言锁：源码里 `ImageTranslationService.instance.isTranslated(`
    // 的调用点必须归零。留着它 = 旧内联链路还在被触发，只是走不到而已。
    () =>
        !_engineCallSites(packageRoot, 'isTranslated(').any(
          (site) => site.startsWith('lib/pages/') ||
              site.startsWith('lib/foundation/image_provider/'),
        ),
    // 🔴 对照组：**引擎文件自己**必须有这个方法体（否则上面的"归零"可能只是
    // 扫描器坏了 —— 空结果判 FAIL）。喂进去之后判据必须为 false。
    () => _engineCallSites(packageRoot, 'isTranslated(').isEmpty,
    () => '绿=阅读路径与图片 provider 里一处都没有 / 故障=全仓都空（扫描器坏了）',
  );

  probe(
    'reader_provider_is_bound_to_a_studio_project_not_a_translation_key',
    // 阅读器的入口必须从绑定表取工程，而不是从 `TranslationConfig` 现算一个
    // 缓存键。判据同时要求"取了绑定"和"没有留给旧引擎的字段"。
    () => _bindsToStudioProject(code(_readerImagesPath)),
    // 故障路径：把一段**旧的**调用喂给同一个判据（它算 `translationKey`）。
    () => _bindsToStudioProject(
      'translationKey = ImageTranslationService.cacheKeyFor(a, b, c, d);\n'
      'ReaderImageProvider(imageKey, sourceKey, cid, eid, page,\n'
      '    translationKey: translationKey);',
    ),
    () => '绿=按绑定取工程 / 故障=旧写法（算 translationKey）不满足判据',
  );

  probe(
    'renderer_reads_project_artifacts',
    // 交付 2 的落点：产物来自 `TranslationProjectIo` + `resultPath` /
    // `renderProjectResultPage`，不是任何"读时即时翻译"的缓存。
    () => _readsArtifacts(code(_appPath)),
    // 故障路径 = 去掉 `resultPath(`（那就只剩现绘，成品位图永远读不到）。
    () => _readsArtifacts(
      'final project = await TranslationProjectIo.load(file);\n'
      'return renderProjectResultPage(project, pageKey);',
    ),
    () => '绿=读 result/ 优先、其次现绘 / 故障=少了 resultPath 就不满足',
  );

  probe(
    'reader_provider_carries_the_artifact_revision',
    // V3 的机制：产物变了必须换一个新的 provider，否则 Flutter 的 imageCache
    // 会把旧图一直还回来（界面上完全正常，只是永远不更新）。
    () =>
        codeHas(_readerImagesPath, 'studioRevision:') &&
        _keysOnRevision(code(_readerImageProviderPath)),
    // 故障路径 = 少了 revision 段（缓存键就与产物变更无关了）。
    () => _keysOnRevision(
      r'String get key => "$imageKey@$sourceKey@$cid@$eid@$enableResize";',
    ),
    () => '绿=键里带 studioRevision / 故障=键与产物变更无关',
  );

  // ── 跑 ──────────────────────────────────────────────────────────────

  for (final item in probes) {
    bool green;
    bool red;
    String err = '';
    try {
      green = item.green();
    } catch (e) {
      green = false;
      err = 'green threw: $e';
    }
    try {
      red = item.red();
    } catch (e) {
      // 故障路径抛异常 ≠ 断言变红。
      red = true;
      err = '${err.isEmpty ? '' : '$err | '}red threw: $e';
    }
    check(
      'reader.${item.name}',
      green && !red,
      '${item.detail()} | 绿路径=${green ? 'true' : 'FALSE'} '
      '故障路径=${red ? '仍绿(装饰品)' : '变红'}${err.isEmpty ? '' : ' | $err'}',
    );
  }
}

// ── 故意做错的同类实现（红路径的对照物） ──────────────────────────────
//
// 🔴 红路径必须检验**同一个命题**，只是喂不同的实现。若红路径检验的是另一个
// 命题，它为 true 只说明那个命题成立，判据依然没被证伪（P7 第一版栽的坑）。

/// "先看底图"的来源选择 —— 把顺序反过来的那一版。
ReaderPageSource _renderFirst({
  required bool hasResult,
  required bool hasInpainted,
  required bool hasBlocks,
}) {
  if (hasInpainted) return ReaderPageSource.projectRender;
  if (hasResult) return ReaderPageSource.projectResult;
  return ReaderPageSource.original;
}

/// "只认成品"的来源选择 —— 没有 `result/` 就回原图（S9.5-a 之前那段空档）。
ReaderPageSource _resultOnly({
  required bool hasResult,
  required bool hasInpainted,
  required bool hasBlocks,
}) =>
    hasResult ? ReaderPageSource.projectResult : ReaderPageSource.original;

/// 忽略 `hasBlocks` 的那一版 —— 会把去字底图画成一张白页。
ReaderPageSource _ignoreBlocks({
  required bool hasResult,
  required bool hasInpainted,
  required bool hasBlocks,
}) {
  if (hasResult) return ReaderPageSource.projectResult;
  if (hasInpainted) return ReaderPageSource.projectRender;
  return ReaderPageSource.original;
}

/// 无条件现绘的那一版。
ReaderPageSource _alwaysRender({
  required bool hasResult,
  required bool hasInpainted,
  required bool hasBlocks,
}) =>
    ReaderPageSource.projectRender;

/// 只取文件名的页键（多章漫画上会撞车）。
String? _basenameKey(String imagePath, String comicDirectory) {
  final path = normaliseReaderPath(imagePath);
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// 按文件名匹配页键的那一版。
String? _basenameMatch({
  required Iterable<String> projectPageKeys,
  required String imagePath,
  required String comicDirectory,
}) {
  final key = _basenameKey(imagePath, comicDirectory);
  if (key == null) return null;
  for (final candidate in projectPageKeys) {
    if (normaliseReaderPath(candidate).split('/').last == key) return candidate;
  }
  return null;
}

/// 原样比较（不归一化分隔符与大小写）的那一版。
String? _rawCompare({
  required Iterable<String> projectPageKeys,
  required String imagePath,
  required String comicDirectory,
}) {
  var rel = imagePath;
  if (rel.startsWith('file://')) rel = rel.substring(7);
  final root = comicDirectory;
  if (!rel.startsWith('$root/')) return null;
  rel = rel.substring(root.length + 1);
  for (final candidate in projectPageKeys) {
    if (candidate == rel) return candidate;
  }
  return null;
}

/// 键里不带 `eid` 的那一版。
String _cidOnlyKey(String cid, String? sourceKey, String eid) =>
    '$cid@${sourceKey ?? ''}';

/// 直接插值 `sourceKey` 的那一版（null 会拼成字面量 `null`）。
String _interpolateNullKey(String cid, String? sourceKey, String eid) =>
    '$cid@$sourceKey@$eid';

/// 缺字段时给默认值的那一版（半条绑定活了下来）。
StudioReaderBinding? _lenientBinding(Object? raw) {
  if (raw is! Map) return null;
  return StudioReaderBinding(
    jsonPath: raw['json']?.toString() ?? '',
    comicDirectory: raw['comicDirectory']?.toString() ?? '',
    projectDirectory: raw['projectDirectory']?.toString() ?? '',
  );
}

/// 把"来源身份"也当成必填字段的那一版解析 —— 老绑定会被它整条作废。
StudioReaderBinding? _strictBinding(Map<String, Object?> raw) {
  final json = raw['json']?.toString().trim() ?? '';
  final comic = raw['comicDirectory']?.toString().trim() ?? '';
  final origin = raw['originScope']?.toString().trim() ?? '';
  if (json.isEmpty || comic.isEmpty || origin.isEmpty) return null;
  return StudioReaderBinding(
    jsonPath: json,
    comicDirectory: comic,
    projectDirectory: '',
    originScope: origin,
  );
}

/// 写回时原样搬运（坏条目留在表里）的那一版。
Map<String, Object?> _verbatimRoundTrip() => {
  'c1@s1@e1': const StudioReaderBinding(
    jsonPath: '/p/imgtrans_p.json',
    comicDirectory: '/d/c',
    projectDirectory: '/p/source',
  ).toJson(),
  'c1@s1@e2': {'json': ''},
};

/// 一张"有一条合法绑定 + 一条坏条目"的表，再 `put` 进第三条 —— 于是它同时
/// 覆盖了"读的时候跳过坏条目"和"写的时候带上合法条目"。
StudioReaderBindings _tableWithCorruptEntry() {
  final table = StudioReaderBindings({
    'c1@s1@e1': const StudioReaderBinding(
      jsonPath: '/p/imgtrans_p.json',
      comicDirectory: '/d/c',
      projectDirectory: '/p/source',
    ).toJson(),
    'c1@s1@e2': {'json': ''},
  });
  table.put(
    'c1@s1@e3',
    const StudioReaderBinding(
      jsonPath: '/p2/imgtrans_p2.json',
      comicDirectory: '/d/c2',
      projectDirectory: '/p2/source',
    ),
  );
  return table;
}

/// 判据：合法的两条都在，坏的那条被丢掉。
///
/// 🔴 绿/红两条路径喂的是**同一个**判据，只是喂不同的写回结果
/// （`StudioReaderBindings.toJson()` vs `_verbatimRoundTrip()`）。
bool _dropsCorruptEntries(Map<String, Object?> written) =>
    written.containsKey('c1@s1@e1') &&
    written.containsKey('c1@s1@e3') &&
    !written.containsKey('c1@s1@e2');

/// 判据：写进去的那条绑定能被**逐字段**读回来。
bool _bindingSurvivesRoundTrip(Map<String, Object?> written) {
  final read = StudioReaderBindings.from(written)['c1@s1@e1'];
  return read != null &&
      read.jsonPath == '/p/imgtrans_p.json' &&
      read.comicDirectory == '/d/c' &&
      read.projectDirectory == '/p/source';
}

/// 只留一个键的那一版写回（读回来时缺字段 ⇒ 整条作废）。
Map<String, Object?> _truncatedRoundTrip() => {
  'c1@s1@e1': {'json': '/p/imgtrans_p.json'},
};

/// 用中间产物当"已完成"的那一版。
List<String> _intermediateAsDone({
  required List<String> chapterPages,
  required Set<String> pagesWithResult,
  required Set<String> pagesWithIntermediates,
}) =>
    [
      for (final page in chapterPages)
        if (!pagesWithResult.contains(page) &&
            !pagesWithIntermediates.contains(page))
          page,
    ];

/// 排序去重的那一版（阅读顺序丢了）。
List<String> _sortedPages({
  required List<String> chapterPages,
  required Set<String> pagesWithResult,
}) =>
    ([
      for (final page in chapterPages)
        if (!pagesWithResult.contains(page)) page,
    ]..sort());

/// 该文件有没有 import [forbidden] 里的任何一个。
bool _importsNoneOf(
  Directory packageRoot,
  String relPath,
  List<String> forbidden,
) {
  final file = File('${packageRoot.path}/$relPath');
  if (!file.existsSync()) return false;
  final source = file.readAsStringSync();
  for (final dep in forbidden) {
    // 🔴 只看 import / export 行，不看正文：这些文件的类文档里会**提到**
    // `dart:ui`（解释为什么不能用它），全文搜就会把说明文字当成依赖。
    final re = RegExp(
      "^\\s*(import|export)\\s+'${RegExp.escape(dep)}",
      multiLine: true,
    );
    if (re.hasMatch(source)) return false;
  }
  return true;
}

/// 全仓源码里出现 [needle] 的文件（相对包根），用于"调用点归零"这类断言。
///
/// 🔴 扫 `lib/` 下每一个 `.dart`，**不**看 `build/`（那里是生成物）。
List<String> _engineCallSites(Directory packageRoot, String needle) {
  final root = Directory('${packageRoot.path}/lib');
  final hits = <String>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (!entity.readAsStringSync().contains(needle)) continue;
    final rel = entity.path
        .substring(packageRoot.path.length + 1)
        .replaceAll('\\', '/');
    hits.add(rel);
  }
  return hits;
}

/// 阅读器入口是不是"按绑定取工程"（判据即断言里那三个合取项）。
bool _bindsToStudioProject(String source) =>
    source.contains('StudioReaderStore.bindingFor(') &&
    source.contains('studioJsonPath:') &&
    !source.contains('translationKey');

/// 产物读取是否齐全（判据即断言里那三个合取项）。
bool _readsArtifacts(String source) =>
    source.contains('TranslationProjectIo.load') &&
    source.contains('resultPath(') &&
    source.contains('renderProjectResultPage(');

/// 缓存键是否带产物变更计数。
bool _keysOnRevision(String source) => source.contains('studioRevision');

// ── S4（开关 = 该章入队）的红路径对照物与判据 ──────────────────────────

/// 不做章节过滤的那一版（整本工程都跑）。
List<String> _allPages({
  required List<String> projectPageKeys,
  required String chapterName,
}) => List<String>.of(projectPageKeys);

/// 不带分隔符的前缀匹配（`第1话` 会命中 `第1话-番外/...`；
/// 空前缀会拼成 `'/'` 而什么都匹配不到）。
///
/// 🔴 空章的那一支必须显式写成 `'/'`：**裸空串对任何字符串都算前缀**
/// （`'x'.startsWith('')` 为真），照绿路径那样直接透传空前缀，这一条红路径会
/// 与绿路径同解（第一次就是这么写错的，`edit-check` 当场报"仍绿(装饰品)"）。
List<String> _prefixWithoutSlash({
  required List<String> projectPageKeys,
  required String chapterName,
}) {
  final prefix = normaliseReaderPath(chapterName);
  final wanted = prefix.isEmpty ? '/' : prefix.toLowerCase();
  return [
    for (final key in projectPageKeys)
      if (normaliseReaderPath(key).toLowerCase().startsWith(wanted)) key,
  ];
}

/// 开关是不是"入队 + 按绑定取真相"。
bool _switchQueuesTheChapter(String source) =>
    source.contains('StudioChapterQueue.enqueue(') &&
    source.contains('StudioChapterQueue.unbind(') &&
    source.contains('StudioReaderStore.bindingFor(');

/// 整章循环是不是**同一份**实现（工装与阅读侧入队都调它）。
bool _oneChapterLoop(String toolSource, String appSource) =>
    toolSource.contains('StudioChapterRunner.run(') &&
    appSource.contains('StudioChapterRunner.run(');

/// 取消是否真的点到了 `CancellationToken`，且 studio 任务有明确标记。
bool _studioCancellationReachesTheToken(String source) =>
    source.contains('_studioTokens[id]?.cancel()') &&
    source.contains('static StudioTaskRunner? studioRunner') &&
    source.contains('studio: true');

/// 旧引擎的任务框架有没有伸手进工作室的引擎。
///
/// 🔴 判据锚在**调用与 import**上，不锚在裸类名上：文件头与各方法的注释里
/// 必须能写出"本方法不认识 `StudioChapterRunner`"这句话 —— 那是这条红线的
/// 说明。若判据是"文件里不许出现这个类名"，注释本身就会把它打红。
bool _taskFrameworkStaysOutOfTheStudioEngine(String source) =>
    source.contains('studioRunner') &&
    !source.contains('StudioChapterRunner.run(') &&
    !RegExp(
      r"import\s+'[^']*studio_chapter_runner\.dart'",
    ).hasMatch(source);

/// 暂停对 studio 任务是否**既**没有按钮**又**在管理层被挡。
bool _pauseIsHiddenForStudioTasks(String tasksPage, String manager) =>
    tasksPage.contains('if (!task.studio)') && manager.contains('|| task.studio');

/// 注册执行体是否在续跑之前（顺序即契约）。
bool _registeredBeforeResume(String source) {
  final registered = source.indexOf('registerStudioTaskRunner()');
  final resumed = source.indexOf('resumePendingTasks()');
  return registered >= 0 && resumed >= 0 && registered < resumed;
}
