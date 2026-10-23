# comix 章节列表采集与分组下拉工作日志

> 主题：完整采集 comix.to 详情页章节列表，并厘清"翻译组分组"维度与翻页行为。
> 时间：2026-10 中旬多轮（consolidated 于 2026-10-17）。
> 结论已沉淀进 `A07b-comix章节列表采集与分组.md`；本日志记录 AI 当时的分析路线。

## 1. 目标与假设

- **目标**：把一部漫画的全部章节（含各翻译组版本）采集进 Mangrove 的版本化章节矩阵。
- **假设**：详情页章节区是一个扁平长列表，直接翻页到底即可；分组只是展示标签。

## 2. 工具与方法（AI 分析路线）

1. **CDP 直连**：复用 `C:\Temp\comix_profile`（VSS 影子副本拷出的带会话 profile，
   绕过 ABE / Chrome 155 锁文件），`--disable-blink-features=AutomationControlled` + remote debug port。
2. **DOM 探针**（`comix_client.dart:_chaptersProbeJs`）：读 `SECTION.mpage__chapters` 内
   `li.mchap-item` 的 `a.mchap-row__primary`（href / 话号）与 `a.mchap-row__group span`（组名）。
3. **分组下拉探查**：打开 `button.ubtn`（"All groups"）转储 `.fdrop__pop--menu` 内的 `.fdrop__item`，
   确认切组 URL 形如 `?group_id=N`（`N=0` = "Unknown group"）。
4. **逐组计数**：对每个 `group_id` 过滤后读计数文案 `Showing X to Y of Z items`，得到各组真实条目数。

## 3. 观察与数据（以 503jz 为例）

- **分组下拉真实可用**：共 **14 个选项**（All groups / Unknown group / EZManga / Lua Comic /
  Luna Toons / MagusManga / Nuviatoon / Nyx Scans / Reset Scans / RinkoComics / Rokari Comics /
  UToon / Valir Scans / Violet Scans）。
- **各组真实条目数**：Lua Comic=38、MagusManga=37、Valir=37、Nyx=37、Rokari=37、EZManga=34、
  Luna=34、Rinko=34、Nuviatoon=32、Violet=25、UToon=21、Reset=4、Unknown=1、All=371。
- **翻页卡顿实锤**：
  - 用户实测：章节列表翻到第 **21 页**卡住，手动点一下才脱离。
  - 代码 `comix_client.dart:_fetchChaptersByDom`（L1784）点 `button.npager__num` 翻页，
    轮询首行 href 是否变化（最多 8s）；站方加密解密慢 → `DOM: page $p not effective after wait, stopping`
    → **直接 break**，只采到部分页（线上日志实证 `page 2 not effective`）。

## 4. 结论

- ✅ 分组下拉**不是装饰**：`?group_id=N` 切组后列表大幅变短。
- ✅ **先切组再翻页**，可彻底绕开"长列表翻页卡顿"（用户建议，已验证有效）。
- ✅ 源站**无组内重复**（Lua Comic 仅 38 章，dupes=[]）。

## 5. 反向验证（不虚报）

- 所有计数来自程序化读取（DOM 计数文案 / 行数），截图仅作复核，不凭截图下结论（呼应 A02）。
- 章节 API `/api/v1/manga/{hid}/chapters` 直接调返回 `403 Invalid token`（token 绑定完整 query，
  不可复用）；SPA 自发的 API 在当前 headless 环境未触发 → 改用 DOM/DB 交叉取证。

## 6. 遗留 / 未决

- 翻页卡顿的根因（残缺采集 → 合并累加脏数据）在 `mangrove-同组重复bug根因取证.md` 中闭环。
- "Unknown group" 标签误导（真组名在 uploader 字段 = NUVIATOON）见 A07b §5。
