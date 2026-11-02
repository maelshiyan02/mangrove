# P18 · 封面按「卷」补齐 + `vol(N)` 命名（2026-10-24）

> 起因：P17 只按"季"找封面，渣男只拿到一张韩文封面。用户指出**应该用韩文原名（配英文名）去搜**，
> 并给了 comix.to 的页面截图，说那里能找到最新封面。照做之后确认：原来的判断漏了一整个维度。

## 1. 结论先行

**comix.to 上的「最新封面」= 韩文原版单行本第 4 卷封面**。它不是"新的一季"，是同一季连载到第 4 卷
时换过的单行本封面。所以真正缺的不是"季"，是"卷"。

像素比对（缩到 64×64 灰度算平均差，**不靠肉眼**）：

| 对比 | 平均差 | 判定 |
|---|---|---|
| 现有 `[KR][cover]season(1)` vs MangaDex vol1 | 1.1 | **同一张**（原命名就是 vol1） |
| vs vol2 / vol3 / vol4 | 100.7 / 98.3 / 105.0 | 不同图 |
| comix 现行主视觉 vs MangaDex vol4 | 17.8 | **同一张**（comix 加了 DAON 角标、裁切不同） |

所以 P17 拿的 AniList 封面是 vol1，comix 的是 vol4，中间还漏了 vol2、vol3。

## 2. 数据结果

| 漫画 | 封面池 | 默认封面 | 说明 |
|---|---|---|---|
| 扔掉的渣男，绝不再捡！ | `[CN]season(1)` + `[KR]vol(1..4)` | `[KR]vol(4)` | 133 章；韩文四卷来自 MangaDex，vol4 与 comix 现行主视觉同图（用 MangaDex 的 827×1200，比 comix 400×600 大） |
| 黑幕男主的限时保姆 | `[KR]vol(1..5)` | `[KR]vol(5)` | 原 `season(1)` 实测就是 vol5，已合并去重 |
| 做个恶女好安逸 | `[KR]vol(1..3)` | `[KR]vol(3)` | 原 `season(1)` 实测就是 vol3 |
| The Runaway Extra… | `[KR]season(1)(2)` | `season(1)` | MangaDex 只有 1 张；两张 season 是同季两张海报（P17 已判） |
| 回声错误 / 龙女友回归 | `[KR]season(1)` | 同名 | MangaDex 各只 1 张 |
| 我要救爸爸 | `[EN]season(1)` | 同名 | MangaDex 未收录（韩文名与英文名都查过，总 0 命中） |

**来源**：`api.mangadex.org`（`/manga?title=<韩文原名>` → `/cover?manga[]=<id>&order[volume]=asc`），
`locale=ko` 的才是韩文原版封面。

## 3. 命名规则扩展：`vol(N)`

原来只有 `season(N)`。这次补第二维：

```
[KR][cover]season(1).jpg   ← 按季换的网络版主视觉
[KR][cover]vol(4).jpg      ← 纸质单行本第 4 卷封面
```

**为什么不写成 `season(5)`**：`season` 是"第几季连载"，`vol` 是"第几本单行本"，两者不是一条时间轴上的
同一刻度。真按 season 编号写，等这本书真开第二季时，`season(2)` 和 `vol(5)` 谁更新就没法判断了。

排序改成**一维**：

```dart
int? coverVersionOf(String name) => max(coverSeasonOf(name), coverVolumeOf(name));
```

先比这个数（大的在前），**相等才比语言** `KR > CN > EN > JP`。

若继续按"先比 season、没 season 的排最后"来排，`[CN][cover]season(1)` 会永远压住 `[KR][cover]vol(4)`——
读者看到的是旧的无字插画，而不是最新的单行本封面。

改动点：
- `foundation/chapter_directory.dart`：新增 `coverVolumeOf()` / `coverVersionOf()`
- `utils/cover_pool.dart`：`_compareCover()` 改用 `coverVersionOf()`
- `pages/cover_picker_dialog.dart`：空池提示文案补上 vol 命名法

## 4. 没拿到的：快看正版竖版封面

再试过一轮，仍然是死路：

- 详情页 `<img class="imgCover" vw="338">` **没有 src 属性**，由前端 JS 从带签名的接口注入
- `og:image` = `f2.kkmh.com/image/260330/LiiEjjGbo.webp-w750.jpg`，实测 **750×469 横版分享图**
- 给同一个 id 加 `-w338` / `-w540` 尺寸后缀一律 **404**；`webp` 原图 1280×800，也是横版
- 页面里另外 11 个 `f2.kkmh.com` 图全是站内其他作品的推荐位（逐张看过）
- Bing 图搜中文名翻了 4 个 query × 3 页共 161 个 URL，筛出 59 张竖版，**没有一张是本作**

所以 `[CN]` 仍是那张无字插画（中文站自己在用）。要拿真封面得逆向 `X-Signature` 或用有登录态的浏览器。

## 5. 一个操作上的坑

`curl "https://api.mangadex.org/cover?manga[]=..."` 里的 `[]` 会被 curl 当 **glob** 展开，请求直接失败
（文件没生成、Python 报 FileNotFoundError）。必须加 `-g` / `--globoff`。

## 6. 验收点

1. 打开《扔掉的渣男，绝不再捡！》→ 封面是**蓝天白云、蓝发男主靠在黑发女主肩上**那张（vol4，即 comix 现行主视觉）
2. 编辑信息 → 换封面 → 该本有 **5 张**候选：1 张 `[CN]` 无字插画 + 4 张 `[KR]vol(1..4)`，按 vol 从新到旧排
3. 《黑幕男主的限时保姆》5 张、《做个恶女好安逸》3 张，默认都是序号最大的那一卷
4. 其余各本封面不应有变化（仍是原来那张）

构建 `BUILD_OK`，`flutter analyze` rc=0，`builds/mangrove/data/app.so` 21:58。
