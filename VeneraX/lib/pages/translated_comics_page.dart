import 'package:flutter/material.dart';

import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/bt_project/bt_project_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/translations.dart';

import 'translation_studio/studio_page.dart';

/// Entry point of the translation studio (P6 §2.9(e)①, revised in S7R).
///
/// It replaced the old "translation library" grid, which showed the products of
/// the retired in-reader AI pipeline. What belongs on the home page now is the
/// list of **FT projects** — the things you actually edit — and tapping one
/// opens the read-only canvas.
///
/// The list is sourced from the local-comic database rather than from the
/// manager's private registry on purpose: [BtProjectManager] already writes one
/// `bt_`-prefixed row per project (title, cover, chapters), so reading it back
/// keeps this page consistent with the reader's own view of the same project.
class TranslationStudioLauncherPage extends StatefulWidget {
  const TranslationStudioLauncherPage({super.key});

  @override
  State<TranslationStudioLauncherPage> createState() =>
      _TranslationStudioLauncherPageState();
}

class _TranslationStudioLauncherPageState
    extends State<TranslationStudioLauncherPage> {
  LocalManager? _manager;
  String _error = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    // The manager registers projects during startup; a scan here covers the
    // case where the user opened this page from the home section before the
    // background scan finished, or just changed the workspace root.
    await BtProjectManager().ensureReady();
    if (!mounted) return;
    setState(() {
      _manager = LocalManager();
      _error = _manager!.isInitialized ? '' : 'Local library is not ready yet.'.tl;
    });
  }

  List<LocalComic> _projects() {
    final manager = _manager;
    if (manager == null || !manager.isInitialized) return const [];
    return manager
        .getComics(LocalSortType.defaultSort)
        .where((comic) => BtProjectManager.isBtComic(comic.id))
        .toList();
  }

  Comic _asComic(LocalComic comic) => Comic(
        comic.title,
        comic.cover,
        comic.id,
        null,
        const [],
        '',
        comic.sourceKey,
        null,
        null,
      );

  @override
  Widget build(BuildContext context) {
    final projects = _projects();
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('Translation Studio'.tl)),
          if (_error.isNotEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text(_error, style: ts.s16)),
            )
          else if (projects.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'No translation project found.\n'
                    'Set the studio workspace root in Settings, then add an '
                    'imgtrans_*.json under it.'.tl,
                    textAlign: TextAlign.center,
                    style: ts.s16,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              sliver: SliverGridComics(
                comics: [for (final comic in projects) _asComic(comic)],
                enableHero: false,
                onTap: (comic, _) => context.to(
                  () => TranslationStudioPage(comicId: comic.id),
                ),
                menuBuilder: (comic) => [
                  MenuEntry(
                    icon: Icons.open_in_new,
                    text: 'Open studio'.tl,
                    onClick: () => context.to(
                      () => TranslationStudioPage(comicId: comic.id),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Kept for callers that still hold the old page class name.
typedef TranslatedComicsPage = TranslationStudioLauncherPage;
