/// Reversible edit commands plus an undo/redo history for the translation
/// studio (P6 S8).
///
/// ## Why per-block snapshots instead of a whole-project one
///
/// The obvious way to make edits undoable is "deep-copy the project before
/// every change". `TranslationProject.copy()` copies the entire decoded JSON,
/// and the real `imgtrans_Manhwa.json` sample has **831 page keys** — so that
/// design would copy the whole tree on every keystroke and make a typing burst
/// quadratic in project size. The S8 pre-work盘点 flagged exactly this as the
/// blocking architecture decision (P8.0 §5.2 item 5: "命令式逆操作 vs 差量
/// patch"), and it rules out the snapshot-the-project approach.
///
/// The unit of change here is therefore **one block's raw map** (23 keys,
/// ~1 KB), which is cheap to copy and is exactly the granularity the UI edits
/// at. A command stores the block's full before/after JSON, so a compound
/// change (e.g. `translation` + `rich_text` + several `fontformat` keys) reverts
/// as a single step without having to model each key individually.
///
/// Page-level operations (delete a block) use [BlockListEditCommand], which
/// snapshots one page's block list rather than the whole project.
library;

/// Deep-copies a decoded JSON value. Mirrors `TranslationProject._deepCopy` so
/// that both layers agree on what "a copy" means.
Object? deepCopyJson(Object? value) {
  if (value is Map) {
    final result = <String, Object?>{};
    value.forEach((key, entry) => result[key.toString()] = deepCopyJson(entry));
    return result;
  }
  if (value is List) return [for (final entry in value) deepCopyJson(entry)];
  return value;
}

/// Deep-copies a string-keyed JSON object.
Map<String, Object?> deepCopyJsonMap(Map<String, Object?> source) {
  final result = <String, Object?>{};
  source.forEach((key, value) => result[key] = deepCopyJson(value));
  return result;
}

/// Structural equality for decoded JSON, used to drop no-op commands.
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// One reversible change to a project's in-memory JSON.
///
/// Commands are **not** applied by [EditHistory.push] — the caller has already
/// landed the change on the live JSON (the studio mutates through the model's
/// own setters). `apply()` therefore means "redo": it forcibly restores the
/// post-edit state, which is what makes redo correct after an undo.
///
/// 🔴 [pageKey] is what makes **dirty-page tracking** possible (P9.1 §2.1): the
/// command knows which page it touched, so [EditHistory.dirtyPages] can answer
/// "which pages must be re-lettered?" without scanning the whole project. It is
/// **required** rather than optional on purpose — a command that forgets its
/// page would silently drop out of the dirty set and leave `result/` stale on
/// disk while the JSON says otherwise, which is exactly the silent-divergence
/// bug class this repository keeps hitting (see the `add()` /
/// `INSERT OR REPLACE` notes in `local.dart`).
abstract class ProjectEditCommand {
  /// Human-readable name, surfaced on the undo tooltip.
  String get label;

  /// Key of the page this command mutated (`TranslationProject.pages[pageKey]`).
  String get pageKey;

  /// True when the command would not change anything; such commands are
  /// dropped instead of being pushed.
  bool get isEmpty;

  /// Restores the post-edit state.
  void apply();

  /// Restores the pre-edit state.
  void revert();
}

/// A snapshot pair around one text block's JSON object.
///
/// `before` / `after` are deep copies taken by [captureBlockEdit] around the
/// mutation, so the command is self-contained and needs no knowledge of which
/// keys the edit touched.
class BlockEditCommand extends ProjectEditCommand {
  BlockEditCommand({
    required this.pageKey,
    required this.block,
    required this.before,
    required this.after,
    this.label = 'Edit',
  });

  @override
  final String pageKey;

  /// The live JSON object inside the page's block list.
  final Map<String, Object?> block;

  /// Block JSON as it was before the edit.
  final Map<String, Object?> before;

  /// Block JSON as it was after the edit.
  final Map<String, Object?> after;

  @override
  final String label;

  @override
  bool get isEmpty => jsonEquals(before, after);

  @override
  void apply() => _replaceMap(block, after);

  @override
  void revert() => _replaceMap(block, before);

  /// Replaces [target]'s contents in place, preserving map identity so every
  /// live `TextBlock` view over it keeps working.
  static void _replaceMap(
    Map<String, Object?> target,
    Map<String, Object?> content,
  ) {
    target
      ..clear()
      ..addAll(deepCopyJsonMap(content));
  }
}

/// A snapshot pair around one page's block **list** (add / delete).
class BlockListEditCommand extends ProjectEditCommand {
  BlockListEditCommand({
    required this.pageKey,
    required this.rawBlocks,
    required this.before,
    required this.after,
    this.label = 'Edit',
  });

  @override
  final String pageKey;

  /// The live JSON array inside `pages[key]`.
  final List<Object?> rawBlocks;

  final List<Object?> before;
  final List<Object?> after;

  @override
  final String label;

  @override
  bool get isEmpty => jsonEquals(before, after);

  @override
  void apply() => _replaceList(rawBlocks, after);

  @override
  void revert() => _replaceList(rawBlocks, before);

  static void _replaceList(List<Object?> target, List<Object?> content) {
    target
      ..clear()
      ..addAll([for (final entry in content) deepCopyJson(entry)]);
  }
}

/// Runs [mutate] and returns the [BlockEditCommand] describing what it did.
///
/// The copy is taken **before** the mutation so reverting is exact even when
/// the edit adds or removes nested keys.
BlockEditCommand captureBlockEdit(
  Map<String, Object?> block,
  void Function() mutate, {
  required String pageKey,
  String label = 'Edit',
}) {
  final before = deepCopyJsonMap(block);
  mutate();
  final after = deepCopyJsonMap(block);
  return BlockEditCommand(
    pageKey: pageKey,
    block: block,
    before: before,
    after: after,
    label: label,
  );
}

/// Runs [mutate] and returns the [BlockListEditCommand] describing what it did.
BlockListEditCommand captureBlockListEdit(
  List<Object?> rawBlocks,
  void Function() mutate, {
  required String pageKey,
  String label = 'Edit',
}) {
  List<Object?> copy() => [for (final entry in rawBlocks) deepCopyJson(entry)];
  final before = copy();
  mutate();
  final after = copy();
  return BlockListEditCommand(
    pageKey: pageKey,
    rawBlocks: rawBlocks,
    before: before,
    after: after,
    label: label,
  );
}

/// Undo/redo history over [ProjectEditCommand]s.
///
/// Dirty tracking uses a "saved index" into the undo stack rather than a plain
/// boolean, so undoing back to the saved state reports clean again — which is
/// what a user editing a project on disk expects, and what a "discard changes?"
/// prompt needs to be honest.
class EditHistory {
  EditHistory({this.limit = 200});

  /// Maximum number of retained undo steps; the oldest is dropped past this.
  final int limit;

  final List<ProjectEditCommand> _undo = [];
  final List<ProjectEditCommand> _redo = [];

  /// Undo-stack depth at the last [markSaved]. Starts at 0, so a freshly loaded
  /// project is reported clean before anything is saved.
  int _savedIndex = 0;

  bool get canUndo => _undo.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  int get undoDepth => _undo.length;

  int get redoDepth => _redo.length;

  /// True when the project differs from the last saved state.
  bool get isDirty => _undo.length != _savedIndex;

  /// Records [command]. No-op commands are ignored.
  void push(ProjectEditCommand command) {
    if (command.isEmpty) return;
    _undo.add(command);
    if (_undo.length > limit) {
      _undo.removeAt(0);
      // Keep the saved marker pointing at the same edit once the oldest step
      // falls off the end (a negative value would mean "never saved").
      if (_savedIndex > 0) _savedIndex--;
    }
    _redo.clear();
  }

  /// Reverts the most recent command. Returns false when there is nothing left.
  bool undo() {
    if (_undo.isEmpty) return false;
    final command = _undo.removeLast();
    command.revert();
    _redo.add(command);
    return true;
  }

  /// Re-applies the most recently undone command.
  bool redo() {
    if (_redo.isEmpty) return false;
    final command = _redo.removeLast();
    command.apply();
    _undo.add(command);
    return true;
  }

  /// Marks the current state as persisted, so [isDirty] becomes false.
  void markSaved() {
    _savedIndex = _undo.length;
    _redo.clear();
  }

  /// Drops all history (e.g. after reloading a different project).
  void clear() {
    _undo.clear();
    _redo.clear();
    _savedIndex = 0;
  }

  /// 🔴 **Which pages need re-lettering** (P9.1 §2.1).
  ///
  /// The answer is derived by **replaying the saved-state boundary**, not by
  /// maintaining a set incrementally:
  ///
  /// - **Undo stack, from `_savedIndex` onward** — everything past the save
  ///   marker is unsaved by definition, and dirties its own `pageKey`.
  /// - **Redo stack** — an undone command is unsaved work the user threw away.
  ///   If a page has nothing unsaved left on the undo stack, then undoing that
  ///   command put the page *back* into its saved state, so the page is clean
  ///   again and must **not** be re-rendered.
  ///
  /// Recomputing this way (instead of add-on-push / remove-on-undo) is what
  /// makes "edit page 1 → save → undo" collapse to *zero* dirty pages, i.e.
  /// saving after undoing back to a saved state does no background work at all.
  /// An incremental set would have to special-case every undo/redo/limit-trim
  /// path, and any miss shows up as a silently stale `result/` bitmap.
  ///
  /// 🔴 **Known limitation**: a page whose *net* unsaved change is nil (edit a
  /// field, then set it back within unsaved edits) stays in the set. That costs
  /// one redundant page render and is deliberately preferred over the
  /// alternative — comparing full page JSON per save to shrink the set would
  /// cost more than the render it saves.
  Set<String> get dirtyPages {
    final dirty = <String>{};
    // Pages that still carry unsaved edits on the undo stack.
    final unsavedPages = <String>{};
    for (var i = _savedIndex; i < _undo.length; i++) {
      final command = _undo[i];
      dirty.add(command.pageKey);
      unsavedPages.add(command.pageKey);
    }
    // A redo entry means "the user undid work here". That only matters when the
    // page still has unsaved edits left: undoing the last unsaved command on a
    // page restores its saved content, so the page is clean again and must not
    // be re-rendered.
    for (final command in _redo) {
      if (!unsavedPages.contains(command.pageKey)) continue;
      dirty.add(command.pageKey);
    }
    return dirty;
  }
}
