# P-DL5a 工作日志：拷贝漫画《第一次告白》"少一话"诊断（2026-10-16）

## 现象
软件内搜索拷贝漫画源《第一次告白》(dycgb)：显示 **62 话 / 更新期 2026-9-30**；
拷贝漫画网站 (https://www.copy4000.com/comic/dycgb) 实际 **63 话 / 最近更新 2026-10-11**。

## 结论（先说答案）
**漫画源配置 `copy_manga(5).js` 不需要升级。** 网络链路完全正常，数据是新鲜的。
显示旧数据的原因是：**这本漫画在本地库中（下载过第 62 话），详情页 local-first
优先渲染本地记录，而 P-DL5 新落地"本地模式=只读本地、不联网刷新"（总开关开也不刷），
于是页面永远定格在本地记录的快照（62 话 / 9-30）**。

## 证据链（全部实测）
| # | 证据 | 结果 |
|---|------|------|
| 1 | 网站实时抓取 copy4000.com/comic/dycgb（SSR HTML） | 63 话，第 63 话 uuid `4a726d4f-c57f-11f1-91ef-fa163e02432f`，更新 2026-10-11 ✅ 与用户所述一致 |
| 2 | API 详情接口实测（Python 复刻签名头，HMAC-SHA256，secret=`M2Fm...aNTM=`）：`api.copy202601.com`、`api.copy5000.com` 的 `/api/v3/comic2/dycgb` | 均返回 `datetime_updated=2026-10-11` —— **API 镜像数据新鲜** |
| 3 | `details_cache.db`（网络详情缓存，写入于 **2026-10-13 18:08**） | **63 话全 + 更新 2026-10-11** —— 源配置某次成功刷新已拉到最新 |
| 4 | `local.db` comics 表 dycgb 行 | **62 话、无第 63 话 uuid、tags 更新=2026-09-30**，`created_at=2026-10-11 17:41`（下载第 62 话时刻，第 63 话当天稍晚上架），`downloadedChapters=["2860aaf9..."]=第62话` |
| 5 | 截图比对 | 截图显示"更新期 2026-9-30 / 62 话 / 第 62 话高亮（阅读进度）" 与 local.db 记录**逐字段一致**，与 details_cache 不一致 → 渲染来源=本地记录 |
| 6 | 章节 App-API `/api/v3/comic/{uuid}/group/default/chapters` 实测 | 保存的 `_deviceinfo=5489938V-8145` **在源自己的 `_blocked_deviceinfos` 黑名单里**；换全新随机指纹仍 210 → 章节接口风控严格（IP/签名维度），但详情接口宽松。此为次要点，与本问题无因果 |

## 代码路径复盘
`comic_page.dart loadData()`：
- 本漫画 `localComic != null`（下载过）→ 走 local-first 分支（L552），渲染 `_localDetails(localComic)`（62 话/9-30）；
- P-DL5 本地模式判定 `_autoRefreshComicInfoOnOpen(isLocalLibrary: true)` = `comicInfoAutoUpdate && !isLocalLibrary` = **恒 false** → 不联网刷新（L571-575，2026-10-16 新增）；
- 截图右上角下拉显示「自动」（`comicInfoAutoUpdate=true`）也无效——本地分支设计上就不刷；
- 网络缓存里那份 63 话的数据（10-13 写入）因此永远不会被展示。

时间线还原：
1. 10-11 17:41 用户下载第 62 话 → 本地记录生成（当时最新话=62，datetime_updated=9-30）；
2. 10-11 稍晚 第 63 话上架；
3. 10-13 18:08 某次网络路径成功刷新 → details_cache 更新为 63 话/10-11（旧版本会无条件后台刷新）；
4. 10-16 安装 P-DL5 新版后打开 → local-first 只读本地 → 永远 62 话/9-30。

## 处置选项（待用户拍板）
- **A. 保持现状**：手动点详情页 ↻ 刷新——`_refreshComicDetails` 对网络源漫画走
  `_refreshNetworkDetails`，成功后 `_persistEnrichedChapters`「只增不减」并回本地库，
  本地记录立即补到 63 话。已可用，无需改码。
- **B. 启用双规则的"本地规则"**：本地库打开时若检测到本地记录落后（网络缓存更新时间
  更新 / 章节数变多），后台自动 enrich 一次。等于把原需求里"本地默认关"改为可开。
- **C. 轻提示**：本地打开时若网络缓存比本地新，显示「有新章节，点击更新」徽标，
  不自动联网。

## 附带观察（不影响本问题，留档）
- `_deviceinfo` 处于自维护黑名单 + 章节接口 210 严风控 → 后续做章节批量操作时可能
  频繁触发「210：章节列表访问过于频繁」，可考虑设置里的"重置设备指纹池"。
- `copy_manga.data`：`_api_host=api.copy202601.com`（10-16 14:55 验证通过），候选
  api.copy5000.com / api.copy-manga.com（后者超时），默认 api.copy2000.online（210）。
