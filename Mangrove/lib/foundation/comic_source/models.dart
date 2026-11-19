part of 'comic_source.dart';

class Comment {
  final String userName;
  final String? avatar;
  final String content;
  final String? time;
  final int? replyCount;
  final String? id;
  int? score;
  final bool? isLiked;
  int? voteStatus; // 1: upvote, -1: downvote, 0: none

  static String? parseTime(dynamic value) {
    if (value == null) return null;
    if (value is int) {
      if (value < 10000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value * 1000)
            .toString()
            .substring(0, 19);
      } else {
        return DateTime.fromMillisecondsSinceEpoch(value)
            .toString()
            .substring(0, 19);
      }
    }
    return value.toString();
  }

  Comment.fromJson(Map<String, dynamic> json)
      : userName = json["userName"],
        avatar = json["avatar"],
        content = json["content"],
        time = parseTime(json["time"]),
        replyCount = json["replyCount"],
        id = json["id"].toString(),
        score = json["score"],
        isLiked = json["isLiked"],
        voteStatus = json["voteStatus"];
}

class Comic {
  final String title;

  final String cover;

  final String id;

  final String? subtitle;

  final List<String>? tags;

  final String description;

  final String sourceKey;

  final int? maxPage;

  final String? language;

  final String? favoriteId;

  /// 0-5
  final double? stars;

  const Comic(
    this.title,
    this.cover,
    this.id,
    this.subtitle,
    this.tags,
    this.description,
    this.sourceKey,
    this.maxPage,
    this.language,
  )   : favoriteId = null,
        stars = null;

  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "maxPage": maxPage,
      "language": language,
      "favoriteId": favoriteId,
    };
  }

  Comic.fromJson(Map<String, dynamic> json, this.sourceKey)
      : title = json["title"],
        subtitle = json["subtitle"] ?? json["subTitle"] ?? "",
        cover = json["cover"],
        id = json["id"],
        tags = List<String>.from(json["tags"] ?? []),
        description = json["description"] ?? "",
        maxPage = json["maxPage"],
        language = json["language"],
        favoriteId = json["favoriteId"],
        stars = (json["stars"] as num?)?.toDouble();

  @override
  bool operator ==(Object other) {
    if (other is! Comic) return false;
    return other.id == id && other.sourceKey == sourceKey;
  }

  @override
  int get hashCode => id.hashCode ^ sourceKey.hashCode;

  @override
  toString() => "$sourceKey@$id";
}

class ComicID {
  final ComicType type;

  final String id;

  const ComicID(this.type, this.id);

  @override
  bool operator ==(Object other) {
    if (other is! ComicID) return false;
    return other.type == type && other.id == id;
  }

  @override
  int get hashCode => type.hashCode ^ id.hashCode;

  @override
  String toString() => "$type@$id";
}

class ComicDetails with HistoryMixin {
  @override
  final String title;

  @override
  final String? subTitle;

  @override
  final String cover;

  final String? description;

  final Map<String, List<String>> tags;

  /// id-name
  final ComicChapters? chapters;

  final List<String>? thumbnails;

  final List<Comic>? recommend;

  final String sourceKey;

  final String comicId;

  final bool? isFavorite;

  final String? subId;

  final bool? isLiked;

  final int? likesCount;

  final int? commentCount;

  final String? uploader;

  final String? uploadTime;

  final String? updateTime;

  final String? url;

  final double? stars;

  @override
  final int? maxPage;

  final List<Comment>? comments;

  static Map<String, List<String>> _generateMap(Map<dynamic, dynamic> map) {
    var res = <String, List<String>>{};
    map.forEach((key, value) {
      if (value is List) {
        res[key] = List<String>.from(value);
      }
    });
    return res;
  }

  /// Lossless constructor.
  ///
  /// [fromJson] cannot be used to rebuild a `ComicDetails` that already exists:
  /// it only accepts maps, and [toJson] drops `recommend` (hard-coded null),
  /// spells `subtitle` as `subTitle` and `commentCount` as `commentsCount`, and
  /// omits `stars` / `maxPage` / `comments` entirely. Anything that needs to
  /// derive one details object from two — such as enriching a downloaded comic
  /// with online metadata **without** replacing its local chapter list — has to
  /// go through here.
  const ComicDetails.raw({
    required this.title,
    required this.cover,
    required this.sourceKey,
    required this.comicId,
    this.subTitle,
    this.description,
    this.tags = const {},
    this.chapters,
    this.thumbnails,
    this.recommend,
    this.isFavorite,
    this.subId,
    this.isLiked,
    this.likesCount,
    this.commentCount,
    this.uploader,
    this.uploadTime,
    this.updateTime,
    this.url,
    this.stars,
    this.maxPage,
    this.comments,
  });

  ComicDetails.fromJson(Map<String, dynamic> json)
      : title = json["title"],
        subTitle = json["subtitle"],
        cover = json["cover"],
        description = json["description"],
        tags = _generateMap(json["tags"]),
        chapters = ComicChapters.fromJsonOrNull(json["chapters"]),
        sourceKey = json["sourceKey"],
        comicId = json["comicId"],
        thumbnails = ListOrNull.from(json["thumbnails"]),
        recommend = (json["recommend"] as List?)
            ?.map((e) => Comic.fromJson(e, json["sourceKey"]))
            .toList(),
        isFavorite = json["isFavorite"],
        subId = json["subId"],
        likesCount = json["likesCount"],
        isLiked = json["isLiked"],
        commentCount = json["commentCount"],
        uploader = json["uploader"],
        uploadTime = json["uploadTime"],
        updateTime = json["updateTime"],
        url = json["url"],
        stars = (json["stars"] as num?)?.toDouble(),
        maxPage = json["maxPage"],
        comments = (json["comments"] as List?)
            ?.map((e) => Comment.fromJson(e))
            .toList();

  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "subTitle": subTitle,
      "cover": cover,
      "description": description,
      "tags": tags,
      "chapters": chapters?.toJson(),
      "thumbnails": thumbnails,
      "recommend": null,
      "sourceKey": sourceKey,
      "comicId": comicId,
      "isFavorite": isFavorite,
      "subId": subId,
      "isLiked": isLiked,
      "likesCount": likesCount,
      "commentsCount": commentCount,
      "uploader": uploader,
      "uploadTime": uploadTime,
      "updateTime": updateTime,
      "url": url,
    };
  }

  /// Field-by-field copy. Only the arguments passed are replaced, so a caller
  /// can enrich a details object without touching the parts it owns.
  ComicDetails copyWith({
    String? title,
    String? subTitle,
    String? cover,
    String? description,
    Map<String, List<String>>? tags,
    ComicChapters? chapters,
    List<String>? thumbnails,
    List<Comic>? recommend,
    String? sourceKey,
    String? comicId,
    bool? isFavorite,
    Object? subId = _unset,
    bool? isLiked,
    int? likesCount,
    int? commentCount,
    Object? uploader = _unset,
    Object? uploadTime = _unset,
    Object? updateTime = _unset,
    Object? url = _unset,
    Object? stars = _unset,
    int? maxPage,
    List<Comment>? comments,
  }) {
    return ComicDetails.raw(
      title: title ?? this.title,
      subTitle: subTitle ?? this.subTitle,
      cover: cover ?? this.cover,
      description: description ?? this.description,
      tags: tags ?? this.tags,
      chapters: chapters ?? this.chapters,
      thumbnails: thumbnails ?? this.thumbnails,
      recommend: recommend ?? this.recommend,
      sourceKey: sourceKey ?? this.sourceKey,
      comicId: comicId ?? this.comicId,
      isFavorite: isFavorite ?? this.isFavorite,
      subId: subId == _unset ? this.subId : subId as String?,
      isLiked: isLiked ?? this.isLiked,
      likesCount: likesCount ?? this.likesCount,
      commentCount: commentCount ?? this.commentCount,
      uploader: uploader == _unset ? this.uploader : uploader as String?,
      uploadTime: uploadTime == _unset ? this.uploadTime : uploadTime as String?,
      updateTime: updateTime == _unset ? this.updateTime : updateTime as String?,
      url: url == _unset ? this.url : url as String?,
      stars: stars == _unset ? this.stars : stars as double?,
      maxPage: maxPage ?? this.maxPage,
      comments: comments ?? this.comments,
    );
  }

  /// Sentinel distinguishing "not passed" from an explicit `null`.
  static const Object _unset = Object();

  /// Must agree with [comicType]: history is written under this type and looked
  /// up under [comicType]. `'local'.hashCode` is not the canonical local type,
  /// so hashing the key here left local comics unable to resume (issue #277).
  @override
  HistoryType get historyType => comicType;

  @override
  String get id => comicId;

  ComicType get comicType => ComicType.fromKey(sourceKey);

  /// Convert tags map to plain list
  List<String> get plainTags {
    var res = <String>[];
    tags.forEach((key, value) {
      res.addAll(value.map((e) => "$key:$e"));
    });
    return res;
  }

  /// Find the first author tag
  String? findAuthor() {
    var authorNamespaces = [
      "author",
      "authors",
      "artist",
      "artists",
      "作者",
      "画师"
    ];
    for (var entry in tags.entries) {
      if (authorNamespaces.contains(entry.key.toLowerCase()) &&
          entry.value.isNotEmpty) {
        return entry.value.join(', ');
      }
    }
    return null;
  }

  String? _validateUpdateTime(String time) {
    time = time.split(" ").first;
    var segments = time.split("-");
    if (segments.length != 3) return null;
    var year = int.tryParse(segments[0]);
    var month = int.tryParse(segments[1]);
    var day = int.tryParse(segments[2]);
    if (year == null || month == null || day == null) return null;
    if (year < 2000 || year > 3000) return null;
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    return "$year-$month-$day";
  }

  String? findUpdateTime() {
    if (updateTime != null) {
      return _validateUpdateTime(updateTime!);
    }
    const acceptedNamespaces = [
      "更新",
      "最後更新",
      "最后更新",
      "update",
      "last update",
    ];
    for (var entry in tags.entries) {
      if (acceptedNamespaces.contains(entry.key.toLowerCase()) &&
          entry.value.isNotEmpty) {
        var value = entry.value.first;
        return _validateUpdateTime(value);
      }
    }
    return null;
  }
}

class ArchiveInfo {
  final String title;
  final String description;
  final String id;

  ArchiveInfo.fromJson(Map<String, dynamic> json)
      : title = json["title"],
        description = json["description"],
        id = json["id"];
}

/// A single version of a chapter, potentially from a specific scanlation
/// group and/or language. Multiple versions can exist for the same chapter
/// number when different groups translate the same chapter.
class ComicChapterVersion {
  final String? scanlationGroup;
  final String? language;
  final String title;
  final String chapterKey;

  /// When this version was uploaded to the source site. Null if the source
  /// does not expose upload time — callers must degrade gracefully.
  final DateTime? uploadedAt;

  const ComicChapterVersion({
    this.scanlationGroup,
    this.language,
    required this.title,
    required this.chapterKey,
    this.uploadedAt,
  });

  factory ComicChapterVersion.fromJson(Map<String, dynamic> json) {
    final ts = json['uploadedAt'];
    return ComicChapterVersion(
      scanlationGroup: json['group'] as String?,
      language: json['lang'] as String?,
      title: json['title'] as String? ?? '',
      chapterKey: json['key'] as String? ?? '',
      uploadedAt: ts == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((ts as num).toInt()),
    );
  }

  Map<String, dynamic> toJson() => {
        if (scanlationGroup != null) 'group': scanlationGroup,
        if (language != null) 'lang': language,
        'title': title,
        'key': chapterKey,
        if (uploadedAt != null)
          'uploadedAt': uploadedAt!.millisecondsSinceEpoch,
      };

  @override
  String toString() =>
      'ComicChapterVersion(group=$scanlationGroup, lang=$language, title=$title, key=$chapterKey)';
}

/// 章节矩阵的三种形态，对应 `ComicChapters` 的三个构造函数。
///
/// 同一个站点/同一本书在不同写入路径下会落成不同形态，这不是异常而是常态：
/// - **versioned**：`{话号: [{group, lang, title, key}, …]}`。comix.to 这类
///   多翻译组源天然是它；P52 手工重建过的本地库矩阵也是它。
/// - **grouped**：`{组名: {章节 key: 标题}}`。拷贝漫画（App 接口与网页端）的
///   `chapters` 就是单组「默認」，组内 key 是**章节 UUID**（`230c97f8-…`），
///   标题才是「第01话」。
/// - **flat**：`{章节 key: 标题}`。只有一个版本、没有组概念的源，或早期落库的
///   老记录（key 形如 `1 [HiveToons] [comix.to]`）。
///
/// 见 [ComicChapters.mergedWith]：跨形态合并按「话号 + 组」规范化后再落回本地形态。
enum ChapterMatrixMode { flat, grouped, versioned }

/// 合并用的**规范格**：把三种形态压成同一件事。
///
/// 为什么需要它：三种形态的关键信息位置不同 —— 版本化把话号放在外层键、组名放在
/// 版本对象里；分组式把组名放在外层键、话号藏在章节 key 或标题里；扁平式只有 key。
/// 直接两两写合并分支会 O(3×3) 爆炸且容易漏，先把两边都摊平成"一格一章"再并集，
/// 只留一个落盘方向。
///
/// - [bucketKey]：原始桶键，落盘时原样写回（版本化=外层话号键，其余=章节 key）。
/// - [numberKey]：归一话号（`1`），判断"是不是同一话"用。
/// - [group]：归一翻译组；「默認/默认/default」视为无组（见 [_normalizeChapterGroup]）。
typedef _ChapterCell = ({
  String bucketKey,
  String? numberKey,
  String? group,
  ComicChapterVersion version,
});

/// 归一翻译组名：把各源对"默认组"的不同叫法折成 null。
///
/// 拷贝漫画的 `默認` 与 comix.to 的"无组"在身份判定上必须是同一件事，否则同一话
/// 会被当成两个组各留一格（跨形态合并时表现为整本翻倍）。
String? _normalizeChapterGroup(String? group) {
  final key = normalizedChapterGroupKey(group);
  return key.isEmpty ? null : key;
}

/// 一格章节的归一话号：章节 key → 标题 → 桶键，依次尝试。
///
/// 🔴 顺序很关键。拷贝漫画分组式的 key 是 UUID（读不出话号），话号只在标题
/// 「第01话」里；P52 重建的版本化矩阵则相反 —— 外层键 `1 [copymanga]` 有号码、
/// 版本里的 key 可能是 UUID。任一位置读到即可，不要只看一个字段。
String? _cellNumberKey(String bucketKey, ComicChapterVersion v) {
  final n = chapterNumberKeyOf(v.chapterKey) ??
      chapterNumberKeyOf(v.title) ??
      chapterNumberKeyOf(bucketKey);
  return n;
}

/// 章节合并时的**身份键**：话号 + 翻译组 + 语种，**刻意忽略站点标签**。
///
/// 用于 [ComicChapters.mergedWith] 去重。本地记录里的 key 是干净话号（`1`），
/// 而目录名 key 往往带站标（`1 [baozimh]`）——两者是同一章的两种写法，判等时
/// 必须归一，否则「刷新章节」后整本翻倍（2026-11-02 用户实测：125 话变 249 格）。
///
/// - 有可解析话号 → `n:<话号>|g:<组|语种>`（站标 `[baozimh]` 已被
///   `parseChapterTitle` 视为非组名，天然不进组位）。
/// - 无话号（番外 / UUID）→ 退回 key 本身，避免把所有无话号章节挤成一格。
///
/// P69 起话号还会往**标题**与**外层桶键**回退（拷贝漫画的 key 是 UUID、话号只在
/// 「第01话」标题里）；`bucketKey` 不传时行为与旧版完全一致。
String _chapterMergeIdentity(ComicChapterVersion v, {String? bucketKey}) {
  final num = chapterNumberKeyOf(v.chapterKey) ??
      chapterNumberKeyOf(v.title) ??
      (bucketKey == null ? null : chapterNumberKeyOf(bucketKey));
  final group = normalizedChapterGroupKey(v.scanlationGroup);
  final lang = (v.language ?? '').trim().toLowerCase();
  if (num == null) return 'k:${v.chapterKey}|g:$group|l:$lang';
  return 'n:$num|g:$group|l:$lang';
}

/// 一条版本记录：章节所属话号 + 该话的某一个版本。
///
/// 用 record 而非 class，是为了让"话号 → 版本"这一对值在版本矩阵里
/// 天然成对出现，调用方不用再自己维护两个平行列表。
typedef ChapterVersionEntry = ({
  String chapterNumber,
  ComicChapterVersion version,
});

class ComicChapters {
  final Map<String, String>? _chapters;

  final Map<String, Map<String, String>>? _groupedChapters;

  /// Multi-version chapters: chapter number → list of versions (from
  /// different scanlation groups). Null when not using versioned mode.
  final Map<String, List<ComicChapterVersion>>? _versionedChapters;

  /// Create a ComicChapters object with a flat map
  const ComicChapters(Map<String, String> this._chapters)
      : _groupedChapters = null, _versionedChapters = null;

  /// Create a ComicChapters object with a grouped map
  const ComicChapters.grouped(
      Map<String, Map<String, String>> this._groupedChapters)
      : _chapters = null, _versionedChapters = null;

  /// 同 [ComicChapters.versioned]，但**不再重排**。
  ///
  /// [preferDownloaded] 需要把某个版本人工提到首位，而 [versioned] 的排序
  /// 会立刻把它按 uploadedAt/组名推回去，所以重排后的结果只能走这里。
  const ComicChapters.versionedOrdered(
    Map<String, List<ComicChapterVersion>> this._versionedChapters,
  ) : _chapters = null,
      _groupedChapters = null;

  /// Create a ComicChapters object with multi-version chapters.
  /// Each chapter number maps to one or more [ComicChapterVersion]s,
  /// allowing different scanlation groups for the same chapter.
  ///
  /// The input map is copied and sorted:
  ///   - Chapter number keys are ordered **ascending** (chapter 1 first, latest
  ///     last) using [_compareChapterNumbersAsc]. Keys that are purely numeric
  ///     sort as numbers; non-numeric keys sort after numeric ones. 这一顺序直接
  ///     决定章节列表、阅读器翻页顺序与下载顺序——用户定案要从第 1 话→最新，而非
  ///     旧的"最新→第 1 话"倒序（反人性）。
  ///   - Within each chapter, versions are ordered by [uploadedAt] descending
  ///     (newest group first) when timestamps are available, falling back to
  ///     scanlation-group name ascending so the "preferred" version picked
  ///     by [preferredVersionKey] and [allChapters] is deterministically
  ///     the newest known upload.
  ComicChapters.versioned(
      Map<String, List<ComicChapterVersion>> input)
      : _chapters = null,
        _groupedChapters = null,
        _versionedChapters = _sortVersioned(input);

  static Map<String, List<ComicChapterVersion>> _sortVersioned(
      Map<String, List<ComicChapterVersion>> input) {
    // Sort versions within each chapter: newest first by uploadedAt,
    // falling back to group name then title.
    final sorted = <String, List<ComicChapterVersion>>{};
    for (final entry in input.entries) {
      final list = List<ComicChapterVersion>.from(entry.value);
      list.sort((a, b) {
        final ta = a.uploadedAt;
        final tb = b.uploadedAt;
        if (ta != null && tb != null) {
          final cmp = tb.compareTo(ta); // newer first
          if (cmp != 0) return cmp;
        } else if (ta != null) {
          return -1; // a has timestamp, b doesn't → a (newer info) first
        } else if (tb != null) {
          return 1;
        }
        // No timestamps either → sort by group name, then title
        final ga = a.scanlationGroup ?? '';
        final gb = b.scanlationGroup ?? '';
        final gc = ga.compareTo(gb);
        if (gc != 0) return gc;
        return a.title.compareTo(b.title);
      });
      sorted[entry.key] = list;
    }
    // Sort chapter keys ascending (chapter 1 first, latest chapter last).
    final orderedKeys = sorted.keys.toList()
      ..sort(_compareChapterNumbersAsc);
    return {for (final k in orderedKeys) k: sorted[k]!};
  }

  /// Compare two chapter-number strings ascending. Numeric keys sort as
  /// actual numbers (so "10" < "49"), non-numeric keys sort after numeric
  /// ones among themselves alphabetically.
  ///
  /// 🔴 走 [chapterNumberValueOf] 而不是裸 `double.tryParse`（P51，2026-10-27）。
  /// 本地漫画的 key 是**目录名**（`49 [Rokari Comics] [comix.to]`），
  /// `double.tryParse` 对它返回 null，于是整本退化成字典序：
  /// `0, 1, 10, 100, 101, …, 11, 110`。用户 P14、P51 两次报的都是这个。
  static int _compareChapterNumbersAsc(String a, String b) {
    final na = chapterNumberValueOf(a);
    final nb = chapterNumberValueOf(b);
    if (na != null && nb != null) {
      return na.compareTo(nb); // ascending
    }
    if (na != null) return -1; // numeric key before non-numeric
    if (nb != null) return 1;
    return a.compareTo(b); // both non-numeric: alpha
  }

  factory ComicChapters.fromJson(dynamic json) {
    if (json is! Map) throw ArgumentError("Invalid json type");
    // Check for versioned format: {chapterNumber: [{group, lang, title, key}, ...]}
    var versionedChapters = <String, List<ComicChapterVersion>>{};
    var chapters = <String, String>{};
    var groupedChapters = <String, Map<String, String>>{};
    for (var entry in json.entries) {
      var key = entry.key;
      var value = entry.value;
      if (key is! String) throw ArgumentError("Invalid key type");
      if (value is List) {
        // Versioned format: list of ComicChapterVersion maps
        versionedChapters[key] = value
            .map((e) => ComicChapterVersion.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList();
      } else if (value is Map) {
        groupedChapters[key] = Map.from(value);
      } else {
        chapters[key] = value.toString();
      }
    }
    if (versionedChapters.isNotEmpty) {
      return ComicChapters.versioned(versionedChapters);
    }
    if (groupedChapters.isNotEmpty) {
      // When both flat and grouped entries exist, wrap flat entries
      // in a default group so group tabs (番外, Online版, etc.) are preserved.
      if (chapters.isNotEmpty) {
        String defaultName = "默认";
        while (groupedChapters.containsKey(defaultName)) {
          defaultName = "$defaultName ";
        }
        groupedChapters[defaultName] = chapters;
      }
      return ComicChapters.grouped(groupedChapters);
    }
    if (chapters.isNotEmpty) {
      return ComicChapters(chapters);
    }
    return ComicChapters(chapters);
  }

  static ComicChapters? fromJsonOrNull(dynamic json) {
    if (json == null) return null;
    if (json is ComicChapters) return json;
    return ComicChapters.fromJson(json);
  }

  Map<String, dynamic> toJson() {
    if (_versionedChapters != null) {
      return _versionedChapters.map(
        (key, versions) => MapEntry(
          key,
          versions.map((v) => v.toJson()).toList(),
        ),
      );
    } else if (_chapters != null) {
      return _chapters;
    } else {
      return _groupedChapters!;
    }
  }

  /// Whether the chapters are grouped
  bool get isGrouped => _groupedChapters != null;

  /// Whether the chapters use multi-version mode
  bool get isVersioned => _versionedChapters != null;

  /// All scanlation group names across all versioned chapters.
  /// Empty for non-versioned chapters.
  Set<String> get scanlationGroups {
    if (_versionedChapters == null) return {};
    final groups = <String>{};
    for (final versions in _versionedChapters.values) {
      for (final v in versions) {
        if (v.scanlationGroup != null) groups.add(v.scanlationGroup!);
      }
    }
    return groups;
  }

  /// Scanlation-group names sorted by recency: the group whose newest
  /// chapter has the most recent [ComicChapterVersion.uploadedAt] comes
  /// first. Groups without any timestamp sort alphabetically after those
  /// that do.
  List<String> get scanlationGroupsSorted {
    if (_versionedChapters == null) return const [];
    final groupLatest = <String, DateTime>{};
    for (final versions in _versionedChapters.values) {
      for (final v in versions) {
        final g = v.scanlationGroup;
        if (g == null || v.uploadedAt == null) continue;
        final current = groupLatest[g];
        if (current == null || v.uploadedAt!.isAfter(current)) {
          groupLatest[g] = v.uploadedAt!;
        }
      }
    }
    final groups = scanlationGroups.toList();
    groups.sort((a, b) {
      final ta = groupLatest[a];
      final tb = groupLatest[b];
      if (ta != null && tb != null) return tb.compareTo(ta); // newer first
      if (ta != null) return -1;
      if (tb != null) return 1;
      return a.compareTo(b); // fallback: alphabetical
    });
    return groups;
  }

  /// Returns all versions for a given chapter number key, or null if
  /// the chapters are not versioned or the key doesn't exist.
  List<ComicChapterVersion>? versionsFor(String chapterKey) {
    if (_versionedChapters == null) return null;
    return _versionedChapters[chapterKey];
  }

  /// For versioned chapters, returns the chapterKey of the preferred
  /// scanlation group's version. Falls back to the first version.
  String? preferredVersionKey(String chapterNumber, String? preferredGroup) {
    final versions = versionsFor(chapterNumber);
    if (versions == null || versions.isEmpty) return null;
    if (preferredGroup != null) {
      for (final v in versions) {
        if (v.scanlationGroup == preferredGroup) return v.chapterKey;
      }
    }
    return versions.first.chapterKey;
  }

  /// Returns a new [ComicChapters] containing only the versions for the
  /// given [scanlationGroup]. Pass null to include all versions (equivalent
  /// to no filter). For non-versioned chapters, returns [this] unchanged.
  ///
  /// The result preserves versioned mode and re-sorts, so [allChapters],
  /// [ids], [length], and [preferredVersionKey] all work correctly on
  /// the filtered view. Returns null if [scanlationGroup] is non-null
  /// but no chapters match it.
  ComicChapters? filterForScanlationGroup(String? scanlationGroup) {
    if (_versionedChapters == null) return this;
    if (scanlationGroup == null) return this;
    final filtered = <String, List<ComicChapterVersion>>{};
    for (final entry in _versionedChapters.entries) {
      final matching = entry.value
          .where((v) => v.scanlationGroup == scanlationGroup)
          .toList();
      if (matching.isNotEmpty) {
        filtered[entry.key] = matching;
      }
    }
    if (filtered.isEmpty) return null;
    return ComicChapters.versioned(filtered);
  }

  /// 版本条目总数（话号 × 翻译组）。非版本化时为 0。
  ///
  /// 用来判断"这次写入的章节信息是不是变少了" —— 见 [mergedWith]。
  int get versionCount => _versionedChapters == null
      ? 0
      : _versionedChapters!.values.fold(0, (sum, list) => sum + list.length);

  /// 章节条目总数（各模式通用）：扁平=话数；分组=各组之和；版本化=
  /// 版本条目数。供 `enrichComicChapters` 在"是否变多"的判据上覆盖三种模式。
  int get entryCount {
    final versioned = _versionedChapters;
    if (versioned != null) {
      return versioned.values.fold(0, (sum, list) => sum + list.length);
    }
    final grouped = _groupedChapters;
    if (grouped != null) {
      return grouped.values.fold(0, (sum, m) => sum + m.length);
    }
    return _chapters?.length ?? 0;
  }

  /// 把 [other] 的版本**并入**本对象：只增不减，按 `chapterKey` 去重。
  ///
  /// 🔴 为什么需要它：库里的章节矩阵一旦被"信息更少的写入源"覆盖，丢掉的翻译组
  /// **再也回不来**。实测 `My Dragon Girlfriend Has Returned` 从"7 话 × 11 组"
  /// 退化成"6 话 × 1 组（DivaScans）"，后果有两层：
  /// 1. 详情页的翻译组 chips 需要 2+ 组才渲染 → 整个组分类 UI 凭空消失；
  /// 2. `downloadedChapters` 里那些**已被丢掉的 key**（Asura 的 7 条）再也映射
  ///    不到磁盘目录（`chapterDirectoryName` 查不到组名 → 目录名算错）→
  ///    已下载的 7 个目录变成"读不到、删不掉、缺页也查不出"的孤儿。
  ///
  /// 详情页每次刷新拿到的都是源的**完整**矩阵，据此做并集回写即可自愈。
  /// 注意**绝不能整体替换** —— "本地 `chapters` 不被网络覆盖"那条既有约定的
  /// 本意正是如此：可以变多，不可以变少（本地可能有源上已下架的旧章节）。
  ///
  /// P-DL6（2026-10-16）起支持**分组式与扁平式**：拷贝漫画等源的章节是
  /// 单组「默認」的分组矩阵，此前 `mergedWith` 只认版本化矩阵导致本地
  /// 记录永远合并不到新增章节（"第一次告白 62 话 vs 网站 63 话"的成因
  /// 之一）。同模式并集、key 相同保留本地值。
  ///
  /// P69（2026-11-18）起**跨形态也并**：两边先摊平成规范格
  /// （[_ChapterCell]）按「话号 + 组」去重，再按**本对象的形态**落盘。
  /// 旧实现在模式不同时 `return this`，于是「版本化本地记录 + 分组式源」
  /// 这类组合（拷贝漫画的库矩阵被手工重建成版本化后就会这样）永远补不到
  /// 新章节 —— 用户只能删历史重新识别，因为那条路径绕开了合并。
  ComicChapters mergedWith(ComicChapters? other) {
    if (other == null) return this;
    // P71：先把两边**各自内部**的等价键折掉再并。P70 只做了「本地 vs 源」
    // 之间的去重，库里已经写坏的 69+69=138 格仍会原样保留 —— 用户刷新后
    // 蓝标全对但章节列表翻倍、每格跑一次状态查询导致详情页卡顿。
    final left = deduplicated;
    final right = other.deduplicated;
    return left._mergeDeduplicated(right);
  }

  /// 合并已归一的矩阵；调用方必须保证左右两侧都无内部重复。
  ComicChapters _mergeDeduplicated(ComicChapters other) {
    if (isVersioned && other.isVersioned) {
      final merged = <String, List<ComicChapterVersion>>{};
      // 🔴 2026-11-02 「刷新章节后翻倍」根因修复（用户实测）：
      //   判等口径改为 **话号 + 翻译组（忽略站点标签）**。本地记录用干净 key
      //   （`1`），而磁盘目录名 key 带站标（`1 [baozimh]`）——两者是同一章，
      //   旧实现按整串 key 判等，于是各建一格 ⇒ 249 章 = 125 本地 + 124 目录名。
      //   忽略站标后 `1` 与 `1 [baozimh]` 归为同一身份 `n:1|g:`，只保留先到的
      //   那一格（本地 key），源侧的重复版本直接跳过。不同翻译组（`1 [Asura]`
      //   vs `1 [DivaScans]`）身份不同，仍各留（多组并集语义不变）。
      final identityToKey = <String, String>{};
      for (final entry in _versionedChapters!.entries) {
        merged[entry.key] = List<ComicChapterVersion>.of(entry.value);
        for (final v in entry.value) {
          identityToKey[_chapterMergeIdentity(v, bucketKey: entry.key)] =
              entry.key;
        }
      }
      for (final entry in other._versionedChapters!.entries) {
        for (final version in entry.value) {
          final identity =
              _chapterMergeIdentity(version, bucketKey: entry.key);
          // 同话同组已在本地 ⇒ 这是同一章的重复登记，跳过（绝不新建格）。
          if (identityToKey.containsKey(identity)) continue;
          final target =
              merged.putIfAbsent(entry.key, () => <ComicChapterVersion>[]);
          if (target.every((v) => v.chapterKey != version.chapterKey)) {
            target.add(version);
          }
          identityToKey[identity] = entry.key;
        }
      }
      return ComicChapters.versioned(merged);
    }
    // 分组式并入：组按名字并，组内按 key 只增不减。
    if (isGrouped && other.isGrouped) {
      final merged = <String, Map<String, String>>{};
      for (final entry in _groupedChapters!.entries) {
        merged[entry.key] = Map<String, String>.of(entry.value);
      }
      for (final entry in other._groupedChapters!.entries) {
        final target =
            merged.putIfAbsent(entry.key, () => <String, String>{});
        for (final e in entry.value.entries) {
          target.putIfAbsent(e.key, () => e.value);
        }
      }
      return ComicChapters.grouped(merged);
    }
    // 扁平式并入。
    if (!isVersioned &&
        !isGrouped &&
        !other.isVersioned &&
        !other.isGrouped) {
      final merged = Map<String, String>.of(_chapters ?? const {});
      // 🔴 2026-11-02 同版本化分支：扁平章节按**话号**去重，忽略站点标签。
      //   `1` 与 `1 [baozimh]` 是同一章，不能各留一格。
      final nums = <String>{};
      String? numOf(String key, String title) =>
          (parseChapterTitle(key).chapterNumber ??
                  parseChapterTitle(title).chapterNumber)
              ?.toString();
      for (final e in merged.entries) {
        final n = numOf(e.key, e.value);
        if (n != null) nums.add(n);
      }
      for (final e in (other._chapters ?? const {}).entries) {
        if (merged.containsKey(e.key)) continue;
        final n = numOf(e.key, e.value);
        if (n != null && nums.contains(n)) continue;
        merged[e.key] = e.value;
        if (n != null) nums.add(n);
      }
      return ComicChapters(merged);
    }
    // ---- 跨形态合并（P69）----
    //
    // 旧实现到这里就 `return this;`，把「模式不同」当成不可调和的矛盾。代价是：
    // 拷贝漫画这类**分组式**源刷新一本**版本化**本地记录（或反过来）时，新章节
    // 永远补不进来 —— 用户实测「第一次告白」本地 63 话、站点 68 话，刷新/重进
    // 详情页都停在 63，只有删历史重新识别（localComic==null，直接返回网络详情，
    // 绕开合并）才恢复。
    //
    // 现在：两边先摊平成 [_ChapterCell]，按「话号 + 组」去重后并集，再按**本地
    // 形态**落盘。保留本地形态是有意的 —— UI 的分组页签、下载目录名、阅读器下标
    // 全部按本地形态计算，换成源那边的形态会连累一票下游代码。
    final mine = _canonicalCells();
    // 扁平形态一话只能占一格（没有组维度可放第二格），所以落盘目标是扁平时分母
    // 只认话号，不认组；其余形态保留「话 + 组」维度，多组合并不丢版本。
    String identityOf(_ChapterCell c) =>
        matrixMode == ChapterMatrixMode.flat && c.numberKey != null
            ? 'n:${c.numberKey}'
            : _cellIdentity(c);
    final seen = <String>{for (final c in mine) identityOf(c)};
    final union = <_ChapterCell>[...mine];
    for (final c in other._canonicalCells()) {
      if (!seen.add(identityOf(c))) continue;
      // 版本化的外层键既是「话号」也是 `versionsFor()` 的入参：分组式源给的 key
      // 是 UUID，直接当外层键会让这本书退化成字典序、新话排到最后，所以补进来
      // 的格子按归一话号落桶。分组/扁平形态的 key 本身就是取章用的 key（UUID），
      // 必须原样保留。
      union.add(
        matrixMode == ChapterMatrixMode.versioned && c.numberKey != null
            ? (
                bucketKey: c.numberKey!,
                numberKey: c.numberKey,
                group: c.group,
                version: c.version,
              )
            : c,
      );
    }
    return _emitCells(
      union,
      matrixMode,
      defaultGroup: isGrouped && _groupedChapters!.length == 1
          ? _groupedChapters!.keys.first
          : '默認',
    );
  }

  /// 当前矩阵形态。
  ChapterMatrixMode get matrixMode {
    if (_versionedChapters != null) return ChapterMatrixMode.versioned;
    if (_groupedChapters != null) return ChapterMatrixMode.grouped;
    return ChapterMatrixMode.flat;
  }

  /// 摊平成规范格（见 [_ChapterCell]）。纯函数，不改自身。
  List<_ChapterCell> _canonicalCells() {
    final versioned = _versionedChapters;
    if (versioned != null) {
      final cells = <_ChapterCell>[];
      for (final entry in versioned.entries) {
        for (final v in entry.value) {
          cells.add((
            bucketKey: entry.key,
            numberKey: _cellNumberKey(entry.key, v),
            group: _normalizeChapterGroup(v.scanlationGroup),
            version: v,
          ));
        }
      }
      return cells;
    }
    final grouped = _groupedChapters;
    if (grouped != null) {
      final cells = <_ChapterCell>[];
      for (final g in grouped.entries) {
        for (final e in g.value.entries) {
          final v = ComicChapterVersion(
            scanlationGroup: g.key,
            title: e.value,
            chapterKey: e.key,
          );
          cells.add((
            bucketKey: e.key,
            numberKey: _cellNumberKey(e.key, v),
            group: _normalizeChapterGroup(g.key),
            version: v,
          ));
        }
      }
      return cells;
    }
    final cells = <_ChapterCell>[];
    for (final e in (_chapters ?? const <String, String>{}).entries) {
      final v = ComicChapterVersion(title: e.value, chapterKey: e.key);
      cells.add((
        bucketKey: e.key,
        numberKey: _cellNumberKey(e.key, v),
        group: null,
        version: v,
      ));
    }
    return cells;
  }

  /// 规范格的身份键：有话号按「话号 + 组」，否则按「章节 key + 组」。
  String _cellIdentity(_ChapterCell c) {
    final g = c.group ?? '';
    final n = c.numberKey;
    return n != null ? 'n:$n|g:$g' : 'k:${c.version.chapterKey}|g:$g';
  }

  /// 把规范格按 [mode] 落盘成矩阵。同桶内同 `chapterKey` 只留第一次出现的那条。
  ///
  /// [defaultGroup] 只在落成分组式且格子里没有组名时使用（拷贝漫画的「默認」）。
  ComicChapters _emitCells(
    List<_ChapterCell> cells,
    ChapterMatrixMode mode, {
    String defaultGroup = '默認',
  }) {
    switch (mode) {
      case ChapterMatrixMode.versioned:
        final out = <String, List<ComicChapterVersion>>{};
        for (final c in cells) {
          final list =
              out.putIfAbsent(c.bucketKey, () => <ComicChapterVersion>[]);
          if (list.every((v) => v.chapterKey != c.version.chapterKey)) {
            list.add(c.version);
          }
        }
        return ComicChapters.versioned(out);
      case ChapterMatrixMode.grouped:
        final out = <String, Map<String, String>>{};
        for (final c in cells) {
          final g = c.group ?? defaultGroup;
          out
              .putIfAbsent(g, () => <String, String>{})
              .putIfAbsent(c.bucketKey, () => c.version.title);
        }
        return ComicChapters.grouped(out);
      case ChapterMatrixMode.flat:
        final out = <String, String>{};
        for (final c in cells) {
          out.putIfAbsent(c.bucketKey, () => c.version.title);
        }
        return ComicChapters(out);
    }
  }

  /// 把**同一个矩阵内部**的等价键折成一格，返回落盘矩阵与旧键→规范键映射。
  ///
  /// P70 只修了「磁盘目录 → 所有等价 key」和「合并时两个来源之间去重」，
  /// 没有清理**已经写进库里**的重复矩阵。《大公的华丽婚姻騙局》因此留下了
  /// 69 个 `1 [copymanga]` 编号 key + 69 个 UUID key，共 138 个格子：
  /// 蓝标全对（P70 的功劳），但章节列表翻倍、每格都要跑一次下载状态查询，
  /// 详情页明显卡顿，阅读历史的话号也跟着错位。
  ///
  /// 规范键优先选**能读出话号的 key**（`1 [copymanga]`），而不是标题里带话号
  /// 的 UUID key。原因：本地阅读用 `chapterDirectoryName(chapters, chapterKey)`
  /// 找磁盘目录，编号 key 直接算出 `1 [copymanga]`；UUID key 会算出 UUID 本身，
  /// 读不到磁盘上的目录。多组版本按「话号 + 组 + 语种」判等，不同翻译组保留。
  ({ComicChapters chapters, Map<String, String> remap})
      deduplicatedWithRemap() {
    final cells = _canonicalCells();
    final keptByIdentity = <String, _ChapterCell>{};
    final remap = <String, String>{};
    for (final cell in cells) {
      final identity =
          _chapterMergeIdentity(cell.version, bucketKey: cell.bucketKey);
      final current = keptByIdentity[identity];
      if (current == null) {
        keptByIdentity[identity] = cell;
        continue;
      }
      final winner = _preferCanonicalCell(current, cell);
      final dropped = identical(winner, current) ? cell : current;
      keptByIdentity[identity] = winner;
      final canonicalKey = winner.version.chapterKey;
      remap.putIfAbsent(dropped.bucketKey, () => canonicalKey);
      remap.putIfAbsent(dropped.version.chapterKey, () => canonicalKey);
    }
    final chapters = _emitCells(
      keptByIdentity.values.toList(),
      matrixMode,
      defaultGroup: isGrouped && _groupedChapters!.length == 1
          ? _groupedChapters!.keys.first
          : '默認',
    );
    return (chapters: chapters, remap: remap);
  }

  /// 幂等版：无重复时原样返回 [this]，避免无谓重建与排序抖动。
  ComicChapters get deduplicated =>
      deduplicatedWithRemap().chapters;

  /// 把旧 `downloadedChapters` / `readEpisode` 里的别名 key 按迁移映射改写。
  /// 保序去重：规范 key 已在列表里时不再追加，历史顺序不受影响。
  static List<String> remapKeys(
    Iterable<String> keys,
    Map<String, String> remap,
  ) {
    final out = <String>[];
    for (final key in keys) {
      final next = remap[key] ?? key;
      if (!out.contains(next)) out.add(next);
    }
    return out;
  }

  /// 规范格打分：话号可读的 key + 目录名同形优先；同分时保留先出现的。
  int _canonicalCellScore(_ChapterCell c) {
    var score = 0;
    if (chapterNumberKeyOf(c.bucketKey) != null) score += 4;
    if (chapterNumberKeyOf(c.version.chapterKey) != null) score += 2;
    if (c.bucketKey == c.version.chapterKey) score += 1;
    if (c.version.title == c.bucketKey) score += 1;
    return score;
  }

  _ChapterCell _preferCanonicalCell(_ChapterCell a, _ChapterCell b) =>
      _canonicalCellScore(b) > _canonicalCellScore(a) ? b : a;

  /// 转成版本化矩阵（幂等）。跨形态合并、测试与一次性迁移用。
  ComicChapters toVersioned() => matrixMode == ChapterMatrixMode.versioned
      ? this
      : _emitCells(_canonicalCells(), ChapterMatrixMode.versioned);

  /// 转成分组矩阵（幂等）。无组名的版本落进 [defaultGroup]。
  ComicChapters toGrouped({String defaultGroup = '默認'}) =>
      matrixMode == ChapterMatrixMode.grouped
          ? this
          : _emitCells(
              _canonicalCells(),
              ChapterMatrixMode.grouped,
              defaultGroup: defaultGroup,
            );

  /// 转成扁平矩阵（幂等）。会丢掉组名 —— 只在下游只要「key → 标题」时用。
  ComicChapters toFlat() => matrixMode == ChapterMatrixMode.flat
      ? this
      : _emitCells(_canonicalCells(), ChapterMatrixMode.flat);

  /// For versioned chapters, returns the scanlation group name of the
  /// first version at the given 0-based index. Returns null for
  /// non-versioned chapters.
  String? scanlationGroupAt(int index) {
    if (_versionedChapters == null) return null;
    if (index < 0 || index >= _versionedChapters.length) return null;
    return _versionedChapters.values.elementAt(index).first.scanlationGroup;
  }

  /// For versioned chapters, returns the number of versions for the
  /// chapter at the given 0-based index. Returns 1 for non-versioned.
  int versionCountAt(int index) {
    if (_versionedChapters == null) return 1;
    if (index < 0 || index >= _versionedChapters.length) return 1;
    return _versionedChapters.values.elementAt(index).length;
  }

  /// 一维"版本矩阵"：话号 + 该话的某一个版本。
  ///
  /// 与 [ids]/[titles]/[allChapters] 的区别：那三个在版本化模式下
  /// **只 yield `versions.first`**（一话 N 组时丢掉 N-1 个），而这里
  /// 产出**全部**版本。顺序为话号降序（与 [ids] 一致），话内沿用
  /// versions 自身的排序（[ComicChapters.versioned] 已排好）。
  ///
  /// 非版本化时每个章节产出一个"无组名"的版本记录，使调用方无需分支。
  List<ChapterVersionEntry> get allVersions {
    final versioned = _versionedChapters;
    if (versioned != null) {
      final res = <ChapterVersionEntry>[];
      for (final entry in versioned.entries) {
        for (final v in entry.value) {
          res.add((chapterNumber: entry.key, version: v));
        }
      }
      return res;
    }
    if (isGrouped) {
      final res = <ChapterVersionEntry>[];
      for (final group in _groupedChapters!.values) {
        for (final e in group.entries) {
          res.add((
            chapterNumber: e.key,
            version: ComicChapterVersion(title: e.value, chapterKey: e.key),
          ));
        }
      }
      return res;
    }
    return [
      for (final e in (_chapters ?? const <String, String>{}).entries)
        (
          chapterNumber: e.key,
          version: ComicChapterVersion(title: e.value, chapterKey: e.key),
        ),
    ];
  }

  /// 全部版本的 chapterKey。
  ///
  /// 版本化时等价于 [allVersions] 的 key 投影（**包含每个组**）；
  /// 非版本化时与 [allChapters.keys] 完全一致。
  Iterable<String> get allVersionKeys sync* {
    for (final e in allVersions) {
      yield e.version.chapterKey;
    }
  }

  /// 把每话**已下载**的那个版本提到首位，返回一个新的 [ComicChapters]。
  ///
  /// [ids] / [titles] / [allChapters] 在版本化模式下只取每话的**首个**版本。
  /// 用户下载的是非首选组时（比如一话有 8 个组，挑了 DivaScans），一维投影
  /// 仍然落在 Asura Scans 上 —— 阅读器拿到的 key 指向一个从没下载过的目录，
  /// 打开就是空白页。把已下载的版本提前，投影就落在真正有内容的那个版本上。
  ///
  /// 只调整话内顺序，**话号顺序不变**，因此历史记录与阅读器下标依然有效。
  /// 没有命中任何已下载版本时原样返回 [this]。
  ComicChapters preferDownloaded(Set<String> downloadedKeys) {
    final versioned = _versionedChapters;
    if (versioned == null || downloadedKeys.isEmpty) return this;
    final reordered = <String, List<ComicChapterVersion>>{};
    var changed = false;
    for (final entry in versioned.entries) {
      final list = List<ComicChapterVersion>.from(entry.value);
      final index = list.indexWhere(
        (v) => downloadedKeys.contains(v.chapterKey),
      );
      if (index > 0) {
        list.insert(0, list.removeAt(index));
        changed = true;
      }
      reordered[entry.key] = list;
    }
    if (!changed) return this;
    return ComicChapters.versionedOrdered(reordered);
  }

  /// 反查 [chapterKey] 属于哪一话、哪一个版本。找不到返回 null。
  ///
  /// 章节目录名需要"话号 + 组名"，而调用方手里只有 chapterKey，靠这里还原。
  ChapterVersionEntry? versionEntryOf(String chapterKey) {
    for (final e in allVersions) {
      if (e.version.chapterKey == chapterKey) return e;
    }
    return null;
  }

  /// All group names
  Iterable<String> get groups => _groupedChapters?.keys ?? [];

  /// All chapters.
  /// If the chapters are grouped, all groups will be merged.
  /// For versioned chapters, uses the first version of each chapter number.
  Map<String, String> get allChapters {
    if (_versionedChapters != null) {
      return _versionedChapters.map(
        (key, versions) => MapEntry(
          versions.first.chapterKey,
          versions.first.title,
        ),
      );
    }
    if (_chapters != null) return _chapters;
    var res = <String, String>{};
    for (var entry in _groupedChapters!.values) {
      res.addAll(entry);
    }
    return res;
  }

  /// Get a group of chapters by name
  Map<String, String> getGroup(String group) {
    return _groupedChapters![group] ?? {};
  }

  /// Get a group of chapters by index(0-based)
  Map<String, String> getGroupByIndex(int index) {
    return _groupedChapters!.values.elementAt(index);
  }

  /// Get a group title by 1-based group number.
  String? groupTitleAt(int group) {
    if (!isGrouped || group < 1 || group > groupCount) {
      return null;
    }
    return _groupedChapters!.keys.elementAtOrNull(group - 1);
  }

  /// Get a group of chapters by 1-based group number.
  Map<String, String>? groupAt(int group) {
    final title = groupTitleAt(group);
    return title == null ? null : _groupedChapters![title];
  }

  /// Get a chapter title by 1-based chapter number.
  ///
  /// For grouped chapters, [group] is 1-based. When [group] is null, [ep]
  /// is treated as the flattened chapter index.
  /// For versioned chapters, uses the first version's title.
  String? titleAt(int ep, {int? group}) {
    if (ep < 1) {
      return null;
    }
    if (isVersioned) {
      return titles.elementAtOrNull(ep - 1);
    }
    if (isGrouped) {
      return group == null
          ? titles.elementAtOrNull(ep - 1)
          : groupAt(group)?.values.elementAtOrNull(ep - 1);
    }
    return _chapters!.values.elementAtOrNull(ep - 1);
  }

  /// Get total number of chapters
  int get length {
    if (isVersioned) return _versionedChapters!.length;
    return isGrouped
        ? _groupedChapters!.values.map((e) => e.length).reduce((a, b) => a + b)
        : _chapters!.length;
  }

  /// Get the number of groups
  int get groupCount => _groupedChapters?.length ?? 0;

  /// Iterate all chapter ids
  Iterable<String> get ids sync* {
    if (isVersioned) {
      for (final versions in _versionedChapters!.values) {
        yield versions.first.chapterKey;
      }
    } else if (isGrouped) {
      for (var entry in _groupedChapters!.values) {
        yield* entry.keys;
      }
    } else {
      yield* _chapters!.keys;
    }
  }

  /// Iterate all chapter titles
  Iterable<String> get titles sync* {
    if (isVersioned) {
      for (final versions in _versionedChapters!.values) {
        yield versions.first.title;
      }
    } else if (isGrouped) {
      for (var entry in _groupedChapters!.values) {
        yield* entry.values;
      }
    } else {
      yield* _chapters!.values;
    }
  }

  String? operator [](String key) {
    if (isVersioned) {
      for (final versions in _versionedChapters!.values) {
        for (final v in versions) {
          if (v.chapterKey == key) return v.title;
        }
      }
      return null;
    } else if (isGrouped) {
      for (var entry in _groupedChapters!.values) {
        if (entry.containsKey(key)) return entry[key];
      }
      return null;
    } else {
      return _chapters![key];
    }
  }
}

class PageJumpTarget {
  final String sourceKey;

  final String page;

  final Map<String, dynamic>? attributes;

  const PageJumpTarget(this.sourceKey, this.page, this.attributes);

  static PageJumpTarget parse(String sourceKey, dynamic value) {
    if (value is Map) {
      if (value['page'] != null) {
        return PageJumpTarget(
          sourceKey,
          value["page"] ?? "search",
          value["attributes"],
        );
      } else if (value["action"] != null) {
        // old version `onClickTag`
        var page = value["action"];
        if (page == "search") {
          return PageJumpTarget(
            sourceKey,
            "search",
            {
              "text": value["keyword"],
            },
          );
        } else if (page == "category") {
          return PageJumpTarget(
            sourceKey,
            "category",
            {
              "category": value["keyword"],
              "param": value["param"],
            },
          );
        } else {
          return PageJumpTarget(sourceKey, page, null);
        }
      }
    } else if (value is String) {
      // old version string encoding. search: `search:keyword`, category: `category:keyword` or `category:keyword@param`
      var segments = value.split(":");
      var page = segments[0];
      if (page == "search") {
        return PageJumpTarget(
          sourceKey,
          "search",
          {
            "text": segments[1],
          },
        );
      } else if (page == "category") {
        var c = segments[1];
        if (c.contains('@')) {
          var parts = c.split('@');
          return PageJumpTarget(
            sourceKey,
            "category",
            {
              "category": parts[0],
              "param": parts[1],
            },
          );
        } else {
          return PageJumpTarget(
            sourceKey,
            "category",
            {
              "category": c,
            },
          );
        }
      } else {
        return PageJumpTarget(sourceKey, page, null);
      }
    }
    return PageJumpTarget(sourceKey, "Invalid Data", null);
  }

  void jump(BuildContext context) {
    if (page == "search") {
      context.to(
        () => SearchResultPage(
          text: attributes?["text"] ?? attributes?["keyword"] ?? "",
          sourceKey: sourceKey,
          options: List.from(attributes?["options"] ?? []),
        )
      );
    } else if (page == "category") {
      var key = ComicSource.find(sourceKey)!.categoryData!.key;
      context.to(
        () => CategoryComicsPage(
          categoryKey: key,
          category: attributes?["category"] ??
              (throw ArgumentError("Category name is required")),
          options: List.from(attributes?["options"] ?? []),
          param: attributes?["param"],
        ),
      );
    } else {
      Log.error("Page Jump", "Unknown page: $page");
    }
  }
}
