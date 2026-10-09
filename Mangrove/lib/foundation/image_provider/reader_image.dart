import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/js_engine.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';
import 'package:mangrove/network/images.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/translations.dart';
import 'base_image_provider.dart';
import 'reader_image.dart' as image_provider;
import 'package:mangrove/foundation/appdata.dart';

/// S9.5-b · 阅读器不再有"读时即时翻译"这条路。
///
/// ## 消失了什么
///
/// 这里原本是 `resolveReaderTranslation(renderStored:, isEngineReady:, schedule:)`：
/// 先读旧引擎的文本缓存，读不到就**当场** `schedule()` 一次翻译并先显示原图。
/// 那是"打开开关 = 读时翻译"的开关语义。
///
/// ## 换成了什么
///
/// 开关改成"**该章入队工作室管线**"（`P6 §S9.5` 交付 1/2），阅读侧只读**工程
/// 产物**（[StudioReaderRenderer]）。于是阅读路径上不再有任何"翻译"动作 ——
/// 它要么有产物可显示，要么显示原图，**不会**在翻页时开始一次网络请求。
///
/// ## 引擎层原样保留
///
/// `ImageTranslationService` / `image_translation/` 一个文件都没删：它们仍是
/// 工作室管线（`StudioPagePipeline`）的检测/OCR/翻译腿，也仍是
/// `PreTranslationTaskManager` 的后端。退出的只是**阅读器的进入点**。
class ReaderImageProvider
    extends BaseImageProvider<image_provider.ReaderImageProvider> {
  /// Image provider for normal image.
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.enableResize = false,
    this.studioJsonPath,
    this.studioComicDirectory,
    this.studioRevision = 0,
    this.btProjectDir,
  });

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  /// `imgtrans_*.json` of the studio project this page's translation lives in.
  ///
  /// Non-null = 「这本素材漫画的这一章绑定了工作室工程，且开关打开」。阅读时
  /// 由 [StudioReaderRenderer] 决定读 `result/` 还是拿 `inpainted/` 现绘，读不到
  /// 就回落到原图（S9.5-b）。
  final String? studioJsonPath;

  /// 素材原图根（`downloads/<漫画>`）。工程页键是相对**这个**根的路径，与
  /// 工程的 `directory`（`source/` 副本根）不同 —— 见
  /// `studio_reader.dart` 的 [relativePageKey]。
  final String? studioComicDirectory;

  /// 产物变更计数（`StudioReaderStore.revision`）。
  ///
  /// 🔴 只为了改**图片缓存键**：工作室重生成完 `result/` 之后，同一条阅读路径
  /// 必须拿到一个新的 provider，否则 Flutter 的 imageCache 会一直显示旧图。
  final int studioRevision;

  /// Path of the imgtrans_*.json of the BallonsTranslator project this page
  /// belongs to. Non-null marks BT mode: the page is rendered from BT's
  /// inpainted image + stored translations instead of the raw original.
  ///
  /// 🔴 它与 [studioJsonPath] 是**两条不同的路**，别合并：
  /// BT 模式的 `imageKey` **已经**在工程的 `directory` 里（`BtProjectManager
  /// .getImages` 就用 `displayPath` 出图），而素材漫画的 `imageKey` 在
  /// `downloads/` 下，要靠"同一个相对页键"映射过去。
  final String? btProjectDir;

  @override
  final bool enableResize;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    Uint8List? imageBytes;
    if (imageKey.startsWith('file://')) {
      var file = File(imageKey);
      if (await file.exists()) {
        imageBytes = await readLocalPage(file);
      } else {
        throw "Error: File not found.";
      }
    } else {
      await for (var event in ImageDownloader.loadComicImage(
        imageKey,
        sourceKey,
        cid,
        eid,
      )) {
        checkStop();
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.currentBytes,
            expectedTotalBytes: event.totalBytes,
          ),
        );
        if (event.imageBytes != null) {
          imageBytes = event.imageBytes;
          break;
        }
      }
    }
    if (imageBytes == null) {
      throw "Error: Empty response body.";
    }
    if (btProjectDir != null) {
      // BT mode: draw the project's stored translations over BT's inpainted
      // page. Any failure or a page without translations falls back to the
      // raw page bytes.
      try {
        final rendered = await BtProjectManager().renderBtPage(cid, imageKey);
        if (rendered != null) {
          return rendered;
        }
      } catch (e, s) {
        Log.error('BT Project', e, s);
      }
    }
    if (studioJsonPath != null) {
      // 素材漫画：译文来自**工程产物**（`result/` 优先，其次 `inpainted/` + 块
      // 现绘），不再是"读时即时翻译"。取不到就落到下面的原图分支 —— 阅读路径
      // 上不再有任何"翻译"动作，翻页永远不会触发一次网络请求。
      try {
        final rendered = await StudioReaderRenderer.render(
          jsonPath: studioJsonPath!,
          imagePath: imageKey,
          comicDirectory: studioComicDirectory ?? '',
        );
        if (rendered != null) return rendered;
      } catch (e, s) {
        Log.error('Studio Reader', e, s);
      }
    }
    if (appdata.settings['enableCustomImageProcessing']) {
      var script = appdata.settings['customImageProcessing'].toString();
      if (!script.contains('function processImage')) {
        return imageBytes;
      }
      var func = JsEngine().runCode('''
        (() => {
          $script
          return processImage;
        })()
      ''');
      if (func is JSInvokable) {
        var autoFreeFunc = JSAutoFreeFunction(func);
        var result = autoFreeFunc([imageBytes, cid, eid, page, sourceKey]);
        if (result is Uint8List) {
          imageBytes = result;
        } else if (result is Future) {
          var futureResult = await result;
          if (futureResult is Uint8List) {
            imageBytes = futureResult;
          }
        } else if (result is Map) {
          var image = result['image'];
          if (image is Uint8List) {
            imageBytes = image;
          } else if (image is Future) {
            JSAutoFreeFunction? onCancel;
            if (result['onCancel'] is JSInvokable) {
              onCancel = JSAutoFreeFunction(result['onCancel']);
            }
            if (onCancel == null) {
              var futureImage = await image;
              if (futureImage is Uint8List) {
                imageBytes = futureImage;
              }
            } else {
              dynamic futureImage;
              image.then((value) {
                futureImage = value;
                futureImage ??= Uint8List(0);
              });
              while (futureImage == null) {
                try {
                  checkStop();
                } catch (e) {
                  onCancel([]);
                  rethrow;
                }
                await Future.delayed(Duration(milliseconds: 50));
              }
              if (futureImage is Uint8List) {
                imageBytes = futureImage;
              }
            }
          }
        }
      }
    }
    return imageBytes!;
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key =>
      "$imageKey@$sourceKey@$cid@$eid@$enableResize"
      // 工作室产物重生成完（`result/` 落地）之后必须换一个新 provider，否则
      // Flutter 的 imageCache 会一直把旧图还回来 —— 这就是 [studioRevision]
      // 存在的唯一理由（V3：工作室改一个字，阅读器该页立刻变）。
      "${studioJsonPath == null ? '' : '@studio:${studioJsonPath!}@$studioRevision'}"
      // The json mtime changes on every BT save, so a project edit evicts the
      // cached render without touching unrelated pages.
      "${btProjectDir == null ? '' : '@bt:${BtProjectManager().jsonMtimeMs(cid)}'}";

  /// [key] carries resize/translation state that never reaches the disk entry,
  /// so it cannot double as the eviction key.
  @override
  String get diskCacheKey =>
      ImageDownloader.imageCacheKey(imageKey, sourceKey, cid, eid);

  /// A page drawn from the project's own artifacts is produced **locally**, so a
  /// decode failure there says nothing about how the server encoded the
  /// original — there is no second encoding to ask for, and recording one would
  /// poison the URL for the pages that really do come from the network.
  ///
  /// 所以只在「这一章绑定了工作室工程」时抑制回落；开关关掉时
  /// [studioJsonPath] 为 null，原图的 avif 回落照旧生效（V2）。
  ///
  /// （BT 模式不在此列：它的 `imageKey` 本来就是工程目录里的 `file://` 路径，
  /// 而 `_onFrameDecodeFailed` 对非网络 URL 直接跳过 —— 抑制与否没有区别。）
  @override
  String? get fallbackUrl => studioJsonPath == null ? imageKey : null;
}

/// Reads one page file from the local library.
///
/// Zero bytes does not mean the page is blank: on Android, a library kept in a
/// folder granted through the system file picker reports a failed read as zero
/// bytes rather than as an error. Retry first — that clears the transient
/// failures — then let the file's own size decide whether it is truly blank.
Future<Uint8List> readLocalPage(File file) async {
  const attempts = 3;
  for (var i = 0; i < attempts; i++) {
    if (i > 0) {
      await Future.delayed(Duration(milliseconds: 50 * i));
    }
    var bytes = await file.readAsBytes();
    if (bytes.isNotEmpty) {
      return bytes;
    }
  }
  int size;
  try {
    size = await file.length();
  } catch (_) {
    size = -1; // unknown: treat as a failed read, not as a blank file
  }
  if (size == 0) {
    throw ImageLoadingPermanentException(
      "${"Image file is empty".tl}: ${file.name}",
    );
  }
  throw "${"Failed to read image file".tl}: ${file.name}";
}
