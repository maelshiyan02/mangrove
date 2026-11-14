import 'package:mangrove/foundation/appdata.dart';

/// 单本漫画的「显示译文」开关（**只服务 BT 工程漫画**）。
///
/// BT 工程的译文就是工程自身产物（`renderBtPage`），不经过工作室管线的
/// 章节绑定表，所以仍需要一条按漫画的开关。旧引擎 `ImageTranslationService`
/// 已删除；这里只保留它当年写的那条存储键，避免用户既有设置失效。
class BtTranslationSwitch {
  BtTranslationSwitch._();

  /// 与旧引擎同名，勿改：改了会让已开关过的漫画全部回落成"关"。
  static const _key = 'imageTranslationEnabledComics';

  static bool isEnabled(String cid, String sourceKey) {
    final stored = appdata.implicitData[_key];
    if (stored is! Map) return false;
    return stored['$cid@$sourceKey'] == true;
  }

  static void setEnabled(String cid, String sourceKey, bool enabled) {
    final stored = appdata.implicitData[_key];
    final map = stored is Map
        ? Map<String, dynamic>.from(stored)
        : <String, dynamic>{};
    final comicKey = '$cid@$sourceKey';
    if (enabled) {
      map[comicKey] = true;
    } else {
      map.remove(comicKey);
    }
    appdata.implicitData[_key] = map;
    appdata.writeImplicitData();
  }
}
