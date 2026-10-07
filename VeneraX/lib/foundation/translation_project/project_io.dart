import 'dart:convert';
import 'dart:io';

import 'json_codec.dart';
import 'project.dart';

/// Reading and writing of `imgtrans_*.json`, FT-compatible at the byte level.
///
/// Everything here is deliberately free of Flutter imports so it can run under
/// a plain `dart run` — that is how `tools/s6_project_roundtrip.dart` proves the
/// round-trip against real projects without launching the app.
///
/// ## The write contract
///
/// FT saves with
/// `open(tmp, 'w', encoding='utf-8')` + `json.dumps(..., ensure_ascii=False)`
/// and then `os.replace(tmp, target)` (`proj_imgtrans.py:1004`). We reproduce
/// all three parts:
///
/// * [PyJson.encode] matches `json.dumps` byte for byte (see `json_codec.dart`),
/// * UTF-8 with no BOM,
/// * a temporary file moved over the target, so a crash mid-write cannot leave
///   a truncated project behind.
///
/// The result is the property the studio depends on: **read a project and write
/// it back without edits and the file is unchanged, byte for byte.** Any
/// difference after that is a real edit, never formatting noise.
class TranslationProjectIo {
  const TranslationProjectIo._();

  /// Loads the project stored in [file].
  ///
  /// Throws [FormatException] when the file is not an FT project.
  static Future<TranslationProject> load(File file) async {
    final source = await file.readAsString(encoding: utf8);
    return parse(source, file);
  }

  /// Parses [source] (the file's text) as a project located at [file].
  ///
  /// Split from [load] so tests and probes can feed fixtures.
  static TranslationProject parse(String source, File file) {
    final decoded = PyJson.decode(source);
    if (decoded is! Map) {
      throw const FormatException(
        'Not an FT project: top level is not an object',
      );
    }
    final raw = <String, Object?>{};
    decoded.forEach((key, value) => raw[key.toString()] = value);
    return TranslationProject.buildFrom(raw, file);
  }

  /// Serialises [project] exactly as FT would write it.
  static String encode(TranslationProject project) =>
      PyJson.encode(project.raw);

  /// Writes [project] to [target] atomically, creating parent folders.
  ///
  /// Returns the number of bytes written, so callers can report or verify size.
  static Future<int> writeAtomically(
    File target,
    TranslationProject project, {
    bool keepBackup = false,
  }) async {
    final text = encode(project);
    final bytes = utf8.encode(text);

    final parent = target.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }

    // Same temporary-then-replace dance FT uses, so an interrupted save leaves
    // the previous project intact instead of a half-written file. The pid keeps
    // two overlapping saves (autosave + explicit, or two studio windows) from
    // sharing one temporary path and renaming each other's partial file.
    final temporary = File('${target.path}.$pid.tmp');
    await temporary.writeAsBytes(bytes, flush: true);

    if (keepBackup && target.existsSync()) {
      final backup = File('${target.path}.backup');
      if (backup.existsSync()) await backup.delete();
      await target.rename(backup.path);
    }
    await _replace(temporary, target);
    return bytes.length;
  }

  /// Moves [source] onto [target], replacing it.
  ///
  /// `File.rename` maps to `MoveFileEx` with replace-on-existing on Windows, so
  /// the usual path is a single atomic step. The copy fallback exists because a
  /// rename can still fail when the target is briefly held open (an editor, an
  /// indexer, or the reader mid-render), and losing a save to that would be far
  /// worse than an extra copy.
  ///
  /// 🔴 The fallback is NOT atomic: a crash during the copy leaves [target]
  /// truncated. It is reported because from the user's side "my page silently
  /// half-wrote" is indistinguishable from data loss, and they deserve to know
  /// which of the two happened.
  ///
  /// Deliberately writes to stderr instead of [Log]: this file stays free of
  /// Flutter imports so `tools/s6_project_roundtrip.dart` can run it under a
  /// plain `dart run`.
  static Future<void> _replace(File source, File target) async {
    try {
      await source.rename(target.path);
      return;
    } on FileSystemException catch (e) {
      stderr.writeln(
        '[TranslationProjectIo] rename failed for ${target.path} ($e); '
        'falling back to a non-atomic copy. A crash now would truncate it.',
      );
    }
    await source.copy(target.path);
    await source.delete();
  }

  /// Writes [bytes] to [target] atomically, creating parent folders.
  ///
  /// Same contract as [writeAtomically] but for raw bytes, which is what the
  /// `result/` product pages need (they are PNGs produced by the renderer, not
  /// json). Before this existed they were written with a bare `writeAsBytes`,
  /// so a crash mid-render left a **truncated PNG that `existsSync()` happily
  /// reported as a finished page** — the publish step would then ship a
  /// half-image as the translated product.
  static Future<void> writeBytesAtomically(File target, List<int> bytes) async {
    final parent = target.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    // 🔴 The temporary name carries the pid: a fixed `.tmp` collides when two
    // saves overlap (autosave + explicit save, or two studio windows), and the
    // slower writer would then rename the *other* one's partial file into place.
    final temporary = File('${target.path}.${pid}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await _replace(temporary, target);
  }

  /// Writes [project] to [target], returning the written byte count.
  ///
  /// Convenience wrapper for callers that already know the destination file.
  static Future<int> save(TranslationProject project, {File? target}) {
    return writeAtomically(target ?? project.jsonFile, project);
  }
}
