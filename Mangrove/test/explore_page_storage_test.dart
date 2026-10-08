import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the explore-page crash:
///
///   type `_Map<String, dynamic>` is not a subtype of type `double?` in type cast
///   #0  ScrollPosition.restoreScrollOffset
///
/// A widget that persists its own state map into [PageStorage] using the
/// context-derived identifier shares that identifier with any descendant
/// [Scrollable] that lacks its own [PageStorageKey]. On creation the scrollable
/// calls `restoreScrollOffset`, reads that map and crashes casting it to
/// `double?`.
///
/// In the app this surfaced on the multi-part explore page: when the page failed
/// to load it rendered a [NetworkError] whose inner [SingleChildScrollView] had
/// no key, so it inherited the page's `[comic_list, title]` identifier under
/// which the page had stored `{loading, message, parts}`.
///
/// The fixes:
///   * [NetworkError]'s scroll view gets its own `PageStorageKey` (Fix A).
///   * the multi-part page stores its map under an explicit string identifier,
///     which can never equal a [Scrollable]'s identifier (Fix B).
///
/// [_MapStoringParent] mirrors that structure with plain framework widgets so
/// the test needs no app/translation initialization.
class _MapStoringParent extends StatefulWidget {
  const _MapStoringParent({super.key, required this.child, this.identifier});

  final Widget child;
  final Object? identifier;

  @override
  State<_MapStoringParent> createState() => _MapStoringParentState();
}

class _MapStoringParentState extends State<_MapStoringParent> {
  @override
  Widget build(BuildContext context) {
    // Same shape as _MultiPartExplorePageState.state / ComicListState.state.
    PageStorage.of(context).writeState(
      context,
      const {'loading': false, 'message': null, 'parts': null},
      identifier: widget.identifier,
    );
    return widget.child;
  }
}

Widget _wrap(Widget child) => MaterialApp(
      home: PageStorage(bucket: PageStorageBucket(), child: child),
    );

void main() {
  testWidgets(
    'an unkeyed scroll view reads the parent state map and crashes (repro)',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const _MapStoringParent(
            key: PageStorageKey('comic_list'),
            child: SingleChildScrollView(child: SizedBox(height: 2000)),
          ),
        ),
      );
      final error = tester.takeException();
      expect(error, isNotNull);
      // The crash is the Map -> double? cast inside restoreScrollOffset.
      expect(error.toString(), contains('double'));
    },
  );

  testWidgets(
    'Fix A: a scroll view with its own PageStorageKey is isolated',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const _MapStoringParent(
            key: PageStorageKey('comic_list'),
            child: SingleChildScrollView(
              key: PageStorageKey('network_error_scroll'),
              child: SizedBox(height: 2000),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Fix B: storing the state map under an explicit string identifier is safe',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          const _MapStoringParent(
            key: PageStorageKey('comic_list'),
            identifier: 'explore_multipart::source::title',
            child: SingleChildScrollView(child: SizedBox(height: 2000)),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
