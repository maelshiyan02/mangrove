import 'dart:convert';

import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/domain_database.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/source_platform.dart';

/// 章节列表的显示模式。
///
/// P11（2026-10-24）之前这是**全局开关**（`appdata.settings[
/// 'comicDisplayLocalMode']`），语义只是「章节列表要不要隐藏未下载的」。
/// 但用户实际需求是「这本我看本地、那本我看网络」，全局开关做不到，
/// 所以升级成 **每本漫画独立**，全局值退化为「没设过时的默认值」。
enum ComicDisplayMode {
  /// 网络模式：显示全部章节，未下载的也在列表里（可点开联网阅读）。
  network('network'),

  /// 本地模式：隐藏未下载的章节，只看磁盘上真有的。
  local('local');

  const ComicDisplayMode(this.key);

  final String key;

  /// 宽松解析：接受 `ComicDisplayMode`、`network`/`local`、`true`/`false`。
  ///
  /// `true`/`false` 是为了吃下早期版本可能误存成布尔值的记录——宁可多兼容
  /// 一种写法，也不要让用户的一次切换因为历史脏数据静默失效。
  static ComicDisplayMode? tryParse(Object? raw) {
    if (raw is ComicDisplayMode) return raw;
    if (raw is bool) return raw ? ComicDisplayMode.local : ComicDisplayMode.network;
    final text = raw?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) return null;
    if (text == 'true' || text == 'local') return ComicDisplayMode.local;
    if (text == 'false' || text == 'network') return ComicDisplayMode.network;
    return null;
  }

  ComicDisplayMode get toggled => this == ComicDisplayMode.local
      ? ComicDisplayMode.network
      : ComicDisplayMode.local;
}

/// 单本漫画的「本地覆盖」层。
///
/// ## 它解决什么
///
/// `comics` 表存的是**网络同步来的字段**。用户在详情页改名、换封面、改简介，
/// 如果直接回写 `comics`，下一次刷新元数据就被网络值冲掉（本地改动凭空消失）。
/// 所以覆盖值单独存 KV 表 `comic_field_overrides`，读取时三层合并：
///
/// ```
/// 覆盖值（用户亲手改的）  >  网络值（comics 表）  >  兜底（目录名/空串）
/// ```
///
/// ## 为什么是 KV 而不是每类信息一张专表
///
/// 需要覆盖的字段会随阶段推进不断变多（P12 封面、P13 章节命名策略、后面还有
/// 阅读偏好）。每加一个字段就建一张表 + 写一次迁移，成本远超收益。KV 一张表
/// 加一个常量 key 就够，且旧库不需要迁移。
///
/// ## 缓存策略
///
/// 章节列表每帧都会问「这本是什么模式」，直接查库太浪费，所以按 comicId 整表
/// 缓存。写入时同步更新缓存，外部写入（网络刷新等）需显式 [invalidate]。
class ComicOverrideStore {
  ComicOverrideStore._();

  static final ComicOverrideStore instance = ComicOverrideStore._();

  static const tableName = 'comic_field_overrides';

  /// 把 `(sourceKey, sourceComicId)` 换算成覆盖表主键（= 域库 `comic_id`）。
  ///
  /// UI 层手里通常只有 `comic.id`（= 源的 sourceComicId），拿不到域库主键；
  /// 而覆盖行必须挂在域库主键上——同一作品在不同平台是不同 `comic_id`，
  /// 各自的覆盖互不干扰，这正是"每本源站独立"的语义。
  static String comicIdOf(String sourceKey, String sourceComicId) =>
      DomainDatabase.comicIdFor(
        SourcePlatformResolver.fromSourceKey(sourceKey),
        sourceComicId,
      );

  /// 章节列表显示模式（`ComicDisplayMode` 的 key）。
  static const fieldDisplayMode = 'display_mode';

  /// 以下字段名与 `comics` 表列名对齐，方便合并层直接按列名取值。
  static const fieldTitle = 'title';
  static const fieldSubtitle = 'subtitle';
  static const fieldDescription = 'description';
  static const fieldAuthor = 'author';
  static const fieldStatus = 'status';
  static const fieldLanguage = 'language';
  static const fieldCoverUri = 'cover_uri';
  static const fieldTags = 'tags';
  static const fieldPageCount = 'page_count';

  /// 章节级语言标注：`{ 源章节 id: BCP 47 语言标签 }`。
  ///
  /// 为什么还要有"记录表侧"的标注，明明目录名里已经有 `[zh-Hans]` 了：
  /// 目录名是**约定**，不是**所有权**。有些源（或其镜像）的目录我们不拥有
  /// —— 改它会断翻译工程（工程目录按章节名建）、断别的设备已经记下的
  /// 认知、下一次下载还会被源侧原样覆盖回来。所以语言必须有第二个落点：
  /// 这本漫画自己的记录。读取顺序 **记录表 > 目录名**。
  static const fieldChapterLanguages = 'chapter_languages';

  /// 章节级**展示标签**：`{ 源章节 id: "英文 · Asura Scans · comix.to" }`。
  ///
  /// 为什么还要这个：扁平章节的 key 只是一个数字（`"152"`），组名和站点
  /// 只存在于**目录名**里，而目录名要靠 `chapterDirectoryName` 反算 ——
  /// 扁平 map 没有 scanlationGroup，算出来还是光秃秃的数字。跨源补进来的
  /// 那几话就永远显示不出"谁翻的、从哪来的"。
  /// 所以给一个人工/脚本可写的展示标签，优先级最高。
  static const fieldChapterLabels = 'chapter_labels';

  final Map<String, Map<String, Object?>> _cache = {};

  /// 读一本漫画的全部覆盖值（无覆盖返回空 Map，绝不返回 null）。
  Map<String, Object?> valuesOf(String comicId) {
    if (comicId.isEmpty) return const {};
    final cached = _cache[comicId];
    if (cached != null) return cached;
    final loaded = _loadFromDb(comicId);
    _cache[comicId] = loaded;
    return loaded;
  }

  /// 取单个覆盖值；没设过返回 null（注意：覆盖成 null 也表示"清除"，见 [setField]）。
  Object? valueOf(String comicId, String fieldKey) =>
      valuesOf(comicId)[fieldKey];

  /// 该字段是否被用户覆盖过。
  bool hasOverride(String comicId, String fieldKey) =>
      valuesOf(comicId).containsKey(fieldKey);

  /// 写一个覆盖值；[value] 传 null 等价于清除该覆盖。
  void setField(String comicId, String fieldKey, Object? value) {
    if (comicId.isEmpty || fieldKey.isEmpty) return;
    final values = Map<String, Object?>.from(valuesOf(comicId));
    if (value == null) {
      values.remove(fieldKey);
      _deleteRow(comicId, fieldKey);
    } else {
      values[fieldKey] = value;
      _upsertRow(comicId, fieldKey, value);
    }
    _cache[comicId] = values;
  }

  /// 批量写入，一次事务（用于「保存」按钮一次提交多个字段）。
  void setFields(String comicId, Map<String, Object?> fields) {
    if (comicId.isEmpty || fields.isEmpty) return;
    final values = Map<String, Object?>.from(valuesOf(comicId));
    values.removeWhere((key, _) => fields.containsKey(key));
    fields.forEach((key, value) {
      if (value != null) values[key] = value;
    });
    try {
      final db = DomainDatabase().db;
      db.execute('BEGIN;');
      try {
        fields.forEach((key, value) {
          if (value == null) {
            db.execute(
              'DELETE FROM $tableName WHERE comic_id = ? AND field_key = ?;',
              [comicId, key],
            );
          } else {
            _upsertRow(comicId, key, value, inTransaction: true);
          }
        });
        db.execute('COMMIT;');
      } catch (_) {
        db.execute('ROLLBACK;');
        rethrow;
      }
    } catch (error) {
      Log.error('ComicOverride', 'save $comicId failed: $error');
    }
    _cache[comicId] = values;
  }

  /// 清掉某本漫画（或某个字段）的缓存，让下一次读取重新查库。
  void invalidate(String comicId, {String? fieldKey}) {
    if (fieldKey == null) {
      _cache.remove(comicId);
      return;
    }
    final cached = _cache[comicId];
    if (cached == null) return;
    cached.remove(fieldKey);
  }

  /// 漫画被删除时清掉它的覆盖行（`comics` 表无外键级联，见 schema 注释）。
  void dropComic(String comicId) {
    if (comicId.isEmpty) return;
    try {
      DomainDatabase().db.execute(
        'DELETE FROM $tableName WHERE comic_id = ?;',
        [comicId],
      );
    } catch (error) {
      Log.error('ComicOverride', 'drop $comicId failed: $error');
    }
    _cache.remove(comicId);
  }

  // ---------------------------------------------------------------------
  // 显示模式：per-comic，全局开关退化为默认值
  // ---------------------------------------------------------------------

  /// 这本漫画**显式设置**的模式；从未设置过返回 null。
  ComicDisplayMode? explicitDisplayMode(String comicId) =>
      ComicDisplayMode.tryParse(valueOf(comicId, fieldDisplayMode));

  /// 全局默认（旧键 `comicDisplayLocalMode`，默认 false = 网络模式）。
  ComicDisplayMode get defaultDisplayMode =>
      appdata.settings['comicDisplayLocalMode'] == true
      ? ComicDisplayMode.local
      : ComicDisplayMode.network;

  /// 这本漫画**最终生效**的模式：自己的设置优先，否则用全局默认。
  ComicDisplayMode displayModeFor(String comicId) =>
      explicitDisplayMode(comicId) ?? defaultDisplayMode;

  void setDisplayMode(String comicId, ComicDisplayMode mode) {
    setField(comicId, fieldDisplayMode, mode.key);
  }

  /// 直接切换（网络 ⇄ 本地）。
  ComicDisplayMode toggleDisplayMode(String comicId) {
    final next = displayModeFor(comicId).toggled;
    setDisplayMode(comicId, next);
    return next;
  }

  // ---------------------------------------------------------------------
  // 章节级语言标注（记录表侧的"第二落点"，见 [fieldChapterLanguages]）
  // ---------------------------------------------------------------------

  /// 这本漫画声明的「章节 id → 语言」映射；没标过返回空 Map。
  Map<String, String> chapterLanguagesOf(String comicId) {
    final raw = valueOf(comicId, fieldChapterLanguages);
    if (raw is Map) {
      final result = <String, String>{};
      raw.forEach((key, value) {
        if (key == null || value == null) return;
        final text = value.toString().trim();
        if (text.isEmpty) return;
        result[key.toString()] = text;
      });
      return result;
    }
    return const {};
  }

  /// 单个章节的标注语言；没标过返回 null（调用方自行回落到目录名）。
  String? chapterLanguageOf(String comicId, String chapterKey) {
    final text = chapterLanguagesOf(comicId)[chapterKey]?.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// 这本漫画声明的「章节 id → 展示标签」映射；没标过返回空 Map。
  Map<String, String> chapterLabelsOf(String comicId) {
    final raw = valueOf(comicId, fieldChapterLabels);
    if (raw is Map) {
      final result = <String, String>{};
      raw.forEach((key, value) {
        if (key == null || value == null) return;
        final text = value.toString().trim();
        if (text.isEmpty) return;
        result[key.toString()] = text;
      });
      return result;
    }
    return const {};
  }

  /// 单个章节的展示标签（`英文 · Asura Scans · comix.to`）；没标过返回 null。
  String? chapterLabelOf(String comicId, String chapterKey) {
    final text = chapterLabelsOf(comicId)[chapterKey]?.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// 给单个章节写展示标签；[label] 传空串等价于清除。
  void setChapterLabel(String comicId, String chapterKey, String? label) {
    final map = Map<String, String>.from(chapterLabelsOf(comicId));
    final text = label?.trim() ?? '';
    if (text.isEmpty) {
      if (!map.containsKey(chapterKey)) return;
      map.remove(chapterKey);
    } else {
      if (map[chapterKey] == text) return;
      map[chapterKey] = text;
    }
    setField(comicId, fieldChapterLabels, map.isEmpty ? null : map);
  }

  /// 给单个章节标语言；[language] 传空串等价于清除标注。
  void setChapterLanguage(
    String comicId,
    String chapterKey,
    String? language,
  ) {
    final map = Map<String, String>.from(chapterLanguagesOf(comicId));
    final text = language?.trim() ?? '';
    if (text.isEmpty) {
      if (!map.containsKey(chapterKey)) return;
      map.remove(chapterKey);
    } else {
      if (map[chapterKey] == text) return;
      map[chapterKey] = text;
    }
    setField(comicId, fieldChapterLanguages, map.isEmpty ? null : map);
  }

  /// 让这本漫画回到"跟随全局默认"。
  void clearDisplayMode(String comicId) =>
      setField(comicId, fieldDisplayMode, null);

  // ---------------------------------------------------------------------
  // 三层合并读取
  // ---------------------------------------------------------------------

  /// 覆盖优先的字符串取值。
  String resolveText(String comicId, String fieldKey, String? networkValue) {
    final override = valueOf(comicId, fieldKey);
    if (override is String && override.isNotEmpty) return override;
    return networkValue ?? '';
  }

  /// 覆盖优先的可空字符串取值。
  String? resolveNullableText(
    String comicId,
    String fieldKey,
    String? networkValue,
  ) {
    if (hasOverride(comicId, fieldKey)) {
      final override = valueOf(comicId, fieldKey);
      if (override == null) return null;
      final text = override.toString();
      return text.isEmpty ? null : text;
    }
    return networkValue;
  }

  /// 覆盖优先的列表取值（标签等）。
  List<String> resolveList(
    String comicId,
    String fieldKey,
    List<String> networkValue,
  ) {
    final override = valueOf(comicId, fieldKey);
    if (override is List) {
      return [
        for (final item in override)
          if (item != null && item.toString().isNotEmpty) item.toString(),
      ];
    }
    return networkValue;
  }

  // ---------------------------------------------------------------------
  // 底层读写
  // ---------------------------------------------------------------------

  Map<String, Object?> _loadFromDb(String comicId) {
    try {
      final rows = DomainDatabase().db.select(
        'SELECT field_key, value_json FROM $tableName WHERE comic_id = ?;',
        [comicId],
      );
      final result = <String, Object?>{};
      for (final row in rows) {
        final key = row['field_key'];
        if (key is! String || key.isEmpty) continue;
        result[key] = _decode(row['value_json']);
      }
      return result;
    } catch (error) {
      // 库未初始化（极早期启动）或表缺失：当作"没有任何覆盖"，不抛给 UI。
      Log.error('ComicOverride', 'load $comicId failed: $error');
      return {};
    }
  }

  void _upsertRow(
    String comicId,
    String fieldKey,
    Object value, {
    bool inTransaction = false,
  }) {
    try {
      DomainDatabase().db.execute(
        'INSERT INTO $tableName (comic_id, field_key, value_json, updated_at) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(comic_id, field_key) DO UPDATE SET '
        'value_json = excluded.value_json, updated_at = excluded.updated_at;',
        [comicId, fieldKey, jsonEncode(value), _nowMillis()],
      );
    } catch (error) {
      Log.error('ComicOverride', 'write $comicId/$fieldKey failed: $error');
      if (inTransaction) rethrow;
    }
  }

  void _deleteRow(String comicId, String fieldKey) {
    try {
      DomainDatabase().db.execute(
        'DELETE FROM $tableName WHERE comic_id = ? AND field_key = ?;',
        [comicId, fieldKey],
      );
    } catch (error) {
      Log.error('ComicOverride', 'delete $comicId/$fieldKey failed: $error');
    }
  }

  static int _nowMillis() => DateTime.now().millisecondsSinceEpoch;

  static Object? _decode(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      // 历史脏数据（非 JSON）按原样返回，别让一条坏记录毁掉整本漫画的覆盖层。
      return text;
    }
  }
}
