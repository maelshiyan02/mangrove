part of 'reader.dart';

/// P47 R4 设置补项的**纯逻辑层**。
///
/// 这里只放不依赖 [BuildContext] 的判断与取值，目的有二：
/// 1. widget/gesture 侧的调用点只做一件事（把设置读进来、把结果用出去）；
/// 2. 断言可以直接打在这一层，不必起 Flutter binding 也能验证边界值。
///
/// 颜色/矩阵这类需要 `dart:ui` 的常量也放这里，供 scaffold 的滤镜层复用。

// ---------------------------------------------------------------------------
// R4-1 顶栏章节胶囊
// ---------------------------------------------------------------------------

bool readerChapterCapsuleEnabled(dynamic raw) => raw == true;

/// 胶囊需要的窗口宽度下限。低于此宽度退回双行标题 —— 顶栏右侧还有翻译控件、
/// 更多菜单、设置三个按钮组，窄窗留给胶囊会把它们挤掉。
const double kChapterCapsuleMinWidth = 560.0;

// ---------------------------------------------------------------------------
// R4-2 一键灰度
// ---------------------------------------------------------------------------

bool readerGreyscaleEnabled(dynamic raw) => raw == true;

/// ITU-R BT.709 亮度权重，与 Flutter 官方 `ColorFilter.matrix` 灰度示例一致。
/// 保留 alpha 通道原样（第四行 0 0 0 1 0），避免透明区域被染色。
///
/// 矩阵单独拎成常量：`ColorFilter` 不对外暴露 matrix 字段，断言只能打在源数组上。
const List<double> kReaderGreyscaleMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
];

final ColorFilter kReaderGreyscaleFilter = ColorFilter.matrix(
  kReaderGreyscaleMatrix,
);

// ---------------------------------------------------------------------------
// R4-3 压暗
// ---------------------------------------------------------------------------

/// 压暗强度上限。与夜间遮罩（`readerNightModeIntensity` 上限 0.85）刻意拉开：
/// 压暗是"降亮不换色"的轻量档，超过 0.4 就等同于蒙一层黑，没必要两套设置。
const double kReaderDimStrengthMax = 0.4;

double readerDimStrength(dynamic raw) {
  final value = (raw as num?)?.toDouble() ?? 0.0;
  if (value.isNaN) return 0.0;
  return value.clamp(0.0, kReaderDimStrengthMax);
}

// ---------------------------------------------------------------------------
// R4-4 控件显隐触发策略（P57.x 已整体退役）
// ---------------------------------------------------------------------------
//
// 顶/底工具栏在 P57.x 被彻底删除后，「单击/双击切换栏显隐」不再存在，
// `readerChromeHideTrigger` 的三个档位全部失去语义：
//   * `singleTapAnywhere` 原本「独占单击、不翻页」——工具栏没了之后等于让
//     单击彻底无反应；
//   * `doubleTap` 原本「双击切显隐」——现在只会把每次单击翻页拖慢 200ms。
// 因此手势层不再读取该设置（见 `gesture.dart` 的 `onTap` / `_detectDoubleTap`），
// 设置界面也移除了这个开关。`appdata` 里保留旧的默认值只为兼容已落盘的配置，
// 不再参与任何判定。

// ---------------------------------------------------------------------------
// R4-5 自动播放：按页计时 / 匀速滚动
// ---------------------------------------------------------------------------

enum ReaderAutoPlayMode {
  /// 既有行为：每 `autoPageTurningInterval` 秒翻一页（`autoPageTurning`）。
  page('page'),

  /// 新增：按 `autoScrollSpeed` px/s 匀速滚动，仅 continuous 可用。
  scroll('scroll');

  final String key;

  const ReaderAutoPlayMode(this.key);

  static ReaderAutoPlayMode fromKey(String? key) {
    for (final value in values) {
      if (value.key == key) return value;
    }
    return page;
  }
}

ReaderAutoPlayMode resolveReaderAutoPlayMode(dynamic raw) =>
    ReaderAutoPlayMode.fromKey(raw is String ? raw : null);

/// 匀速滚动的合法区间（px/s）。下限 20 防止慢到看不出在动，上限 1200 防止
/// 一屏一屏地跳、失去"匀速"的意义。
const double kReaderAutoScrollSpeedMin = 20.0;
const double kReaderAutoScrollSpeedMax = 1200.0;

double readerAutoScrollSpeed(dynamic raw) {
  final value = (raw as num?)?.toDouble() ?? 150.0;
  if (value.isNaN) return 150.0;
  return value.clamp(kReaderAutoScrollSpeedMin, kReaderAutoScrollSpeedMax);
}

/// 匀速滚动的驱动步长。100ms 一次 → 每秒 10 次；再快只是白烧 CPU，
/// 再慢则肉眼可见台阶。
const Duration kReaderAutoScrollTick = Duration(milliseconds: 100);
