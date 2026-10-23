import 'package:flutter/material.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/translation_project/glossary_scope.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';
import 'package:mangrove/pages/translation_studio/studio_page.dart';
import 'package:mangrove/pages/translation_studio/studio_project_menu.dart';
import 'package:mangrove/utils/translations.dart';

/// 翻译工程详情页：工程卡 → 翻译工作室画布之间的过渡页。
///
/// 背景：一本漫画的**不同章节**在现有流程里会被拆成多个 `bt_<hash>` 工程卡
/// （每章一个 `imgtrans_*.json`，各自算出一个 hash id），分散在本地库 / 主页 /
/// 工作室列表里，只能用卡片上的彩色章节标签区分。本页把**同一本漫画**下的所有
/// `bt_` 工程归类到一页，按章节列出，点单个工程才进工作室画布。
///
/// ## 归类键：显式归属，不是目录结构（P5）
///
/// 过去本页按 `subtitle` 归类，而 `subtitle` 取的是工程 json 的**祖父目录名**
/// （见 `BtProjectManager._registerLocal`）。可工程布局是
/// `<projectsRoot>/<漫画名>-<章节名>/imgtrans_*.json` —— 祖父目录**永远是**
/// `projectsRoot` 自己（"projects"）。于是：
///
/// * "同一本漫画的多个工程归到一页"实际变成了"同一个 root 下的**所有**工程
///   归到一页"；
/// * 页标题显示成 "projects" 而不是漫画名。
///
/// 现在改用**显式归属**：工程创建那一刻写一份边车 `mangrove_project.json`
/// （`StudioProjectMeta`），里面记着来源漫画的 `cid` + `sourceKey`。本页按
/// `cid@sourceKey` 归类，边车缺失时回落到绑定表（阅读器开关那条链路写的
/// `originScope`），再缺才回落到 `subtitle`。三档回落的键格式**刻意统一**
/// （都走 [glossaryScopeOf]），所以一个工程从"没有边车"变成"有边车"时，同一本
/// 漫画的其它工程不会被拆散到另一页。
class TranslationProjectDetailPage extends StatefulWidget {
  final String comicId;

  const TranslationProjectDetailPage({super.key, required this.comicId});

  /// 统一入口：传入一张 bt_ 工程卡的 id 即可，页面会自行归类到所属漫画。
  static void openFor(BuildContext context, String comicId) {
    context.to(() => TranslationProjectDetailPage(comicId: comicId));
  }

  @override
  State<TranslationProjectDetailPage> createState() =>
      _TranslationProjectDetailPageState();
}

class _TranslationProjectDetailPageState
    extends State<TranslationProjectDetailPage> {
  List<LocalComic> _projects = [];
  String _comicName = '';
  String _sourceComicId = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 确保磁盘上的 bt_ 工程已登记进内存与 LocalComic 表。
    await BtProjectManager().scan();
    final self = LocalManager().find(widget.comicId, ComicType.local);
    final scope = _scopeOf(self);
    final all = LocalManager().getComics(LocalSortType.defaultSort);
    // 归类：同一本漫画（同一个 scope）的所有 bt_ 工程。
    final matched = all
        .where((c) =>
            BtProjectManager.isBtComic(c.id) && _scopeOf(c) == scope)
        .toList();
    matched.sort((a, b) => a.title.compareTo(b.title));
    if (!mounted) return;
    setState(() {
      _comicName = _nameOf(self);
      _sourceComicId = _sourceIdOf(self);
      _projects = matched;
      _loading = false;
    });
  }

  /// 这个工程卡属于**哪一本漫画**（归类键）。
  ///
  /// 🔴 优先级：边车 → 绑定表 → `subtitle`。见类注释里"归类键"那一段。
  String _scopeOf(LocalComic? comic) {
    if (comic == null) return '';
    final project = BtProjectManager().projectFor(comic.id);
    if (project != null) {
      final meta = BtProjectManager.associationFor(project);
      if (meta != null) {
        return glossaryScopeOf(cid: meta.comicId, sourceKey: meta.sourceKey);
      }
      final origin = StudioReaderStore.originForProject(project.jsonFile.path);
      final scope = origin?.$1 ?? '';
      if (scope.isNotEmpty) return scope;
    }
    // 最后的兜底：没有任何归属信息的老工程。按 `subtitle` 分组是错的（会把同一
    // root 下的所有工程并成一页），但**只列自己这一张**是对的 —— 宁可少列，
    // 不可把不相关的工程误并进来。
    return 'self:${comic.id}';
  }

  /// 这一组的展示名（来源漫画名）。
  String _nameOf(LocalComic? comic) {
    if (comic == null) return '';
    final project = BtProjectManager().projectFor(comic.id);
    if (project != null) {
      final meta = BtProjectManager.associationFor(project);
      if (meta != null && meta.comicTitle.isNotEmpty) return meta.comicTitle;
    }
    // 没有边车时 `_registerLocal` 已经把副标题换成了漫画名（若有边车），
    // 老工程则仍是祖父目录名 —— 两种都比空串强。
    return comic.subtitle;
  }

  /// 来源漫画在本地库里的 id（"再建一个工程"要拿它当预选）。
  ///
  /// 🔴 只认**边车**里的 `comicId`：绑定表只存 `cid@sourceKey`，而 `cid` 自身
  /// 是否含 `@` 是未定的，从 scope 里反解 `cid` 会有歧义。拿不到就不预选 ——
  /// 向导会从第 1 步开始，让用户自己挑那一本。
  String _sourceIdOf(LocalComic? comic) {
    if (comic == null) return '';
    final project = BtProjectManager().projectFor(comic.id);
    if (project == null) return '';
    final meta = BtProjectManager.associationFor(project);
    return meta?.comicId ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_comicName.isEmpty ? '翻译工程'.tl : _comicName),
        actions: [
          // 🔴 新建流程的**第三个入口**（另两个：本地库工程段卡、工作室菜单）。
          // 三处都走同一个 `createStudioProject`，所以行为不可能漂移。
          IconButton(
            tooltip: 'Create translation project'.tl,
            icon: const Icon(Icons.add),
            onPressed: _loading
                ? null
                : () async {
                    final outcome = await createStudioProject(
                      context,
                      presetComicId:
                          _sourceComicId.isEmpty ? null : _sourceComicId,
                    );
                    // 建完刷新：新建的工程要立刻出现在这一页的列表里。
                    if (outcome != null && mounted) _load();
                  },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _projects.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '该漫画下还没有翻译工程'.tl,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: _projects.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) =>
                      _ProjectTile(comic: _projects[index]),
                ),
    );
  }
}

class _ProjectTile extends StatelessWidget {
  final LocalComic comic;

  const _ProjectTile({required this.comic});

  @override
  Widget build(BuildContext context) {
    final pageCount = comic.downloadedChapters.length;
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.to(
          () => TranslationStudioPage(comicId: comic.id),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.menu_book_outlined, size: 36),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      comic.title.isEmpty ? '未命名章节'.tl : comic.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '@pageCount 页 · 翻译工程'.tlParams(
                        {'pageCount': pageCount},
                      ),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: context.colorScheme.outline),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
