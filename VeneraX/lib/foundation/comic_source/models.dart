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
      title: json['title'] as String,
      chapterKey: json['key'] as String,
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
  static int _compareChapterNumbersAsc(String a, String b) {
    final na = double.tryParse(a);
    final nb = double.tryParse(b);
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
  ComicChapters mergedWith(ComicChapters? other) {
    if (other == null || !other.isVersioned) return this;
    // 扁平/分组的本地漫画不参与合并：两种模式混起来会把章节列表搞乱。
    if (!isVersioned) return this;
    final merged = <String, List<ComicChapterVersion>>{};
    for (final entry in _versionedChapters!.entries) {
      merged[entry.key] = List<ComicChapterVersion>.of(entry.value);
    }
    for (final entry in other._versionedChapters!.entries) {
      final target =
          merged.putIfAbsent(entry.key, () => <ComicChapterVersion>[]);
      final known = {for (final v in target) v.chapterKey};
      for (final version in entry.value) {
        if (known.add(version.chapterKey)) target.add(version);
      }
    }
    return ComicChapters.versioned(merged);
  }

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
