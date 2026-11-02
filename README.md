# Mangrove

**漫画阅读 + AI 汉化工作台** —— 一条从「抓取生肉」到「导出熟肉」的完整桌面流水线。

> 名字取自 *manga* + *grove*：一册册作品连成林。

工程主体在 [Mangrove/](Mangrove/)（Flutter Windows 应用，包名 `package:mangrove`，fork 自 VeneraX）。
中文/英文应用说明见 [Mangrove/README.md](Mangrove/README.md) 与 [Mangrove/README_EN.md](Mangrove/README_EN.md)。

## 它做什么

```
漫画源加载 → 章节枚举 → 下载落盘 → 阅读渲染 → 文字检测/OCR/翻译 → 擦除排版 → 导出
```

阅读是外壳，主体是「翻译」；下载与本地库是喂给翻译的入口。

## 核心能力

- **漫画源引擎** —— JS 脚本源（`loadInfo` / `loadEp`），运行时优先读 `<dataPath>/comic_source`，
  回落项目内 `comic_source/`（便携目录）；同名 key 以 dataPath 为准。
- **整章分页修复** —— 包子漫画源 v1.2.9：`loadEp` 逐页自愈（首图残缺检测、按 URL 去重保序、
  追加失败即停），阅读器与下载器共用同一份分页结果，不再出现「只下一半」。
- **网络 / 本地双显示模式** —— 同一部作品可切网络源与本地库；本地目录按 `<话号> [组] [站点]`
  命名，读取时做兼容解析。
- **下载管理 + 缺页自动修复** —— 滚动窗口并发、多轮渐进超时；失败页落 `missing_pages.json`，
  后续 `repair_download` 按缺页表补抓。
- **本地漫画管理与章节编辑** —— 自建本地漫画、加章/删章/换封面、刷新章节去重、登记未入册目录。
- **翻译工作室** —— 可视化编辑每个文本块：字形、字号、描边、竖排、位置，所见即所得，带完整撤销。
- **工程互读** —— 与 BallonTranslator 的 `.json` 工程保持**零字节往返**兼容，两边可以互相打开。
- **应用数据可迁移** —— 数据目录由 exe 同级 `data/` 决定，可整体搬走；便携根探测最多向上 6 级。

## 构建与验证

只用仓库内工装，不直接跑 `flutter` / `dart`：

```bash
python tools/run_build_task.py      # 发布构建；通过判据是 builds/build.log 出现 BUILD_OK
python tools/run_headless_task.py   # 无渲染表面验证；看 [CLI PRINT] {"status":...}
```

`flutter analyze` 作静态闸门（沙盒内不跑 `flutter test`）。

## 版本

以 `Mangrove/pubspec.yaml` 的 `version` 为唯一权威，base-10 三段式递增（每段 0~9、满 10 进位），
每完成一批施工 +1 小版本，build 号单调 +1。当前 `3.1.0+274`。

## 许可

待定。
