// 下载波浪进度条 —— 「下载管理」四个队列与下载中弹窗共用的动效。
//
// ## 动效纪律（用户需求 #4，2026-10-14）
//
// * **暂停即静止**：`running == false` 时相位冻结，波浪一根线都不动 ——
//   "暂停了还在晃"会让人以为它还在偷偷下载。
// * **启动阶段才允许明显漂移**：`progress == null`（收集图片列表 / 拉取
//   漫画信息等无法计算进度的阶段）且运行中，波形带缓慢横移，给出"活着"
//   的信号。
// * **正常传输阶段克制**：相位一个周期 3.2s、振幅 ~2px，只提供质感，
//   不提供频闪 —— 旧版 `LinearProgressIndicator` 的不确定态在高速度下
//   晃眼睛，就是被替换的原因。
//
// 纯绘制组件，不依赖下载栈（Color 参数显式传入，测试可离线构造）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class DownloadWaveProgress extends StatefulWidget {
  const DownloadWaveProgress({
    super.key,
    this.progress,
    required this.running,
    this.height = 6,
    this.color,
    this.backgroundColor,
  });

  /// 0..1；null = 未知进度（启动阶段），整条以低透明度填充并漂移。
  final double? progress;

  /// false 时波浪完全静止（暂停 / 待命 / 问题任务）。
  final bool running;

  final double height;

  final Color? color;

  final Color? backgroundColor;

  @override
  State<DownloadWaveProgress> createState() => _DownloadWaveProgressState();
}

class _DownloadWaveProgressState extends State<DownloadWaveProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      // 两个模式共用一条时间轴，切换时相位连续，不会跳变。
      duration: const Duration(milliseconds: 3200),
    );
    if (widget.running) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant DownloadWaveProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.running && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.running && _controller.isAnimating) {
      // stop() 保留当前 value：恢复播放时从暂停那一刻的波形继续，
      // 而不是弹回起点。
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final background =
        widget.backgroundColor ??
        color.withValues(alpha: 0.14);
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.height / 2),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _WavePainter(
              progress: widget.progress,
              phase: _controller.value,
              color: color,
              background: background,
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.progress,
    required this.phase,
    required this.color,
    required this.background,
  });

  final double? progress;
  final double phase;
  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    // 底槽。
    canvas.drawRect(Offset.zero & size, paint..color = background);

    final p = progress?.clamp(0.0, 1.0);
    if (p != null && p >= 1.0) {
      // 已完成：满条纯色，不再画波峰（避免完成态还在"呼吸"）。
      canvas.drawRect(Offset.zero & size, paint..color = color);
      return;
    }

    final fillRatio = p ?? 1.0;
    final amp = p == null ? 2.6 : 1.8;
    // 波长固定约 64px，相位随动画推进；待命/暂停时 phase 冻结。
    final wavelength = math.max(48.0, size.width / 5);
    final baseY = size.height * (1 - fillRatio);
    // 启动阶段：波形带整体横移（可见但缓慢，一个相位 3.2s）；
    // 正常传输：相位只做 ±振幅级别的微小起伏，不做整条平移。
    final drift = p == null ? phase * wavelength : phase * 2 * math.pi;

    /// 画一条"从波面向下填满"的波形；[yShift] 与 [phaseShift] 造层次。
    void drawWave(double yShift, double phaseShift, Color c) {
      final path = Path()..moveTo(-wavelength, size.height);
      for (double x = -wavelength; x <= size.width + wavelength; x += 4) {
        final dx = x + drift + phaseShift;
        final y =
            baseY + yShift + math.sin(2 * math.pi * (dx / wavelength)) * amp;
        path.lineTo(x, y);
      }
      path.lineTo(size.width + wavelength, size.height);
      path.close();
      canvas.drawPath(path, paint..color = c);
    }

    // 副波（低透明度、略高、相位错开）先画，主波盖在上面形成层次。
    drawWave(-1.2, wavelength * 0.3, color.withValues(alpha: 0.35));
    drawWave(0, 0, color);
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.progress != progress ||
      old.phase != phase ||
      old.color != color ||
      old.background != background;
}
