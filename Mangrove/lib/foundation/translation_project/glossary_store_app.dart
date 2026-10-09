import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/translation_project/glossary_store.dart';

/// 全局术语表实例，后端是 `appdata.implicitData`。
///
/// 🔴 为什么单独一个 6 行文件：`glossary_store.dart` 刻意**不** import 任何
/// `package:flutter/*` 也不 import `appdata`（headless 断言要用一个假后端跑
/// 真实逻辑），所以"接到真实后端"这一步只能放在这里。
///
/// 🔴 为什么必须是**同一个实例**：工作室与旧引擎都用它。两份实例会各自持有
/// 自己的 implicitData 视图，一边学到的词另一边看不见 —— 那正是本次迁移要
/// 消灭的分裂。
///
/// 两者的 scope 现在也是**同一个**：`cid@sourceKey`（规则只有一处实现，
/// `glossary_scope.dart`）。工作室手里只有工程 id，所以它先经绑定表反查回来源
/// （`studio_reader_app.dart` 的 `originForProject`）。差别只剩"翻译组那一层"。
final GlossaryStore appGlossary = GlossaryStore(
  // 每次调用重新取：`appdata.implicitData` 在导入备份时是**整体替换**，
  // 缓存住引用会一直服务导入前的旧术语表。
  sink: () => appdata.implicitData,
  persist: appdata.writeImplicitData,
);
