# Mangrove 文档索引（.agent/documents）

> 本文件是 `documents/` 的唯一导航入口，由整理脚本自动生成的映射表。
> 命名规范：`P{编号}-{TYPE}-{主题}-{YYYYMMDD}.md`，TYPE ∈ WORKLOG / PLAN / ANALYSIS / HANDOFF / OPENER / TEST。
> 阶段目录按工程实际推进顺序编号；`P0.x` = 奠基前史，`P00` = 跨阶段工程治理。
> 编号跨阶段重复属正常（例：P17 在 05 为管线收口、在 10 为本地库），以目录区分。

## 1. 工作日志阶段导航

| 目录 | 阶段 | 覆盖内容 |
|---|---|---|
| `worklog/01-奠基P1-P6-20260927_20260930` | S0 奠基 | 环境、Git 仓库、BT 直读、comix.to 源起步、Venera 前史 |
| `worklog/02-下载基础S1-S4-20261005` | S1~S4 下载基础 | 下载进度可视化、缺失页记录表、不完整标识、补救下载 |
| `worklog/03-翻译工作室S5-S9-20261005_20261009` | S5~S9 翻译工作室 | 工程模型、只读/可编辑画布、检测 OCR 翻译管线、S9.5a 验证 |
| `worklog/04-BT对照P10-20261008` | P10 BT 对照 | BallonTranslator 能力对照、S-N1/S-N3 交付、整合度基线 |
| `worklog/05-管线收口与修图P11-P20-20261009_20261010` | P11~P20 管线收口 | 旧链路退出、第四段修图、单块修图复原、跨页计划书 |
| `worklog/06-跨页拼接S10-P21-P32-20261010_20261011` | S10 跨页拼接 | P21~P32：缝发现、文字块小组、投影片段、长画布缺页与缩放 |
| `worklog/07-字体取色与下载源P33-P45-20261011_20261012` | ⑦⑧ 字体取色与下载源 | P33~P45：系统字体、原图取色、包子/comix/拷贝三源适配 |
| `worklog/08-路径便携与阅读器P46-P47-20261013_20261015` | P46~P47 路径与阅读器 | PathRoots 搬家自愈；阅读器 R1~R5（页轨/配色/缩放/设置/竖工具栏） |
| `worklog/09-下载管理P-DL-20261014_20261017` | P-DL 下载管理 | P-DL1~P-DL8：缺页修复、四队列、漫画信息更新、数据位置迁移 |
| `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024` | P-DL9 与本地库 | comix 内置浏览器；本地库 LC-P1~P19（模式权限/封面池/命名规范） |
| `worklog/11-水印与文字块P48-20261025_20261026` | P48 水印与文字块 | 去水印前置、文字块分类、ONNX LaMa、语言与椭圆块 |
| `worklog/12-收尾P51-P54-20261027` | P51~P54 收尾 | 包子最新章修复、拆书合集、拷贝乱码、两级布局、双版本地化 |

## 2. 其他目录

| 目录 | 放什么 |
|---|---|
| `plans/` | 实施计划、修改计划（PLAN） |
| `analysis/` | 调研、可行性分析、根因分析（ANALYSIS） |
| `handoff/` | 换 agent 开场白与交接词（HANDOFF / OPENER） |
| `testing/` | 可复跑的 GUI/自动化复测脚本（TEST） |

## 3. 新旧文件名对照（全量）

| 旧路径 | 新路径 |
|---|---|
| `D01-多agent工作区迁移记录-20261007.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.9-WORKLOG-多agent共享工作区迁移-20261007.md` |
| `D02-下一轮开场白-20261007.md` | `handoff/P10.0-OPENER-下一轮开场白-S10跨页与术语-20261007.md` |
| `D03-下一轮开场白-20261009.md` | `handoff/P11.0-OPENER-下一轮开场白-单块修图与跨页拼接-20261009.md` |
| `D04-下一轮开场白-20261011.md` | `handoff/P33.0-OPENER-下一轮开场白-字体取色与下载源-20261011.md` |
| `D05-下一轮开场白-20261012.md` | `handoff/P44.0-OPENER-下一轮开场白-comix网络与全量图-20261012.md` |
| `P10.10.1-新对话开场白.md` | `handoff/P10.10.1-OPENER-自定义翻译脚本-20261008.md` |
| `handoff/P-DL9-开场白-Trae下一轮任务-20261017.md` | `handoff/P-DL9-OPENER-Trae下一轮任务-20261017.md` |
| `plans/P2-C-多汉化组实施计划.md` | `plans/P2-PLAN-多汉化组实施-20260928.md` |
| `plans/P2-封面与章节名实施计划.md` | `plans/P2-PLAN-封面与章节名实施-20260928.md` |
| `plans/P47-阅读器优化实施计划-20261014.md` | `plans/P47-PLAN-阅读器优化实施-20261014.md` |
| `plans/comic_library_paths_and_local_nmt_plan.md` | `plans/P6.9-PLAN-ComicLibrary路径统一与多本地NMT与成品导出-20261005.md` |
| `plans/comix-to与mangrove阅读器对比分析.md` | `analysis/P47.0-ANALYSIS-comix-to与Mangrove阅读器对比-20261014.md` |
| `plans/cross_page_stitch_plan.md` | `plans/P20-PLAN-跨页拼接-v1-20261009.md` |
| `plans/mangrove阅读器样式修改计划.md` | `plans/P47.1-PLAN-阅读器样式修改-20261014.md` |
| `plans/retranslate_button_plan.md` | `plans/P6.8-PLAN-单文本框重译按钮-20261005.md` |
| `plans/studio_ui_and_cross_page_stitch_plan.md` | `plans/P21-PLAN-工作室UI优化与跨页拼接-v2-20261010.md` |
| `worklog/2026-10-25.md` | `worklog/11-水印与文字块P48-20261025_20261026/P48.1-WORKLOG-水印前置与文字块分类-20261025.md` |
| `worklog/2026-10-26.md` | `worklog/11-水印与文字块P48-20261025_20261026/P48.2-WORKLOG-水印整体语义与ONNX-LaMa接入-20261026.md` |
| `worklog/2026-10-27.md` | `worklog/12-收尾P51-P54-20261027/P51.1-WORKLOG-包子最新章修复与全书重下-20261027.md` |
| `worklog/Flutter桌面开发环境与Git仓库规划分析日志.md` | `analysis/P0.4-ANALYSIS-Flutter桌面开发环境与Git仓库规划-20260927.md` |
| `worklog/P-DL1-下载安全暂停与缺页修复工作日志.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL1-WORKLOG-下载安全暂停与缺页修复-20261014.md` |
| `worklog/P-DL2-下载管理分区与四队列管理工作日志.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL2-WORKLOG-下载管理分区与四队列管理-20261016.md` |
| `worklog/P-DL2.1-下载管理GUI验收修复-20261016.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL2.1-WORKLOG-下载管理GUI验收修复-20261016.md` |
| `worklog/P-DL3-自动缺页修复与设置拆分-20261016.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL3-WORKLOG-自动缺页修复与设置拆分-20261016.md` |
| `worklog/P-DL4-对话经验汇总与下一任务交接-20261016.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL4-WORKLOG-对话经验汇总与下一任务交接-20261016.md` |
| `worklog/P-DL5-漫画信息自动更新模式-20261016.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL5-WORKLOG-漫画信息自动更新模式-20261016.md` |
| `worklog/P-DL5a-拷贝漫画少一话诊断-20261016.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL5a-WORKLOG-拷贝漫画少一话诊断-20261016.md` |
| `worklog/P-DL6-漫画管理重构与网络本地显示模式-20261016.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL6-WORKLOG-漫画管理重构与网络本地显示模式-20261016.md` |
| `worklog/P-DL6.1-漫画管理三处GUI修复-20261016.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL6.1-WORKLOG-漫画管理三处GUI修复-20261016.md` |
| `worklog/P-DL7-应用数据存储位置与缓存迁移-20261017.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL7-WORKLOG-应用数据存储位置与缓存迁移-20261017.md` |
| `worklog/P-DL8-收藏页未登录引导修复-20261017.md` | `worklog/09-下载管理P-DL-20261014_20261017/P-DL8-WORKLOG-收藏页未登录引导修复-20261017.md` |
| `worklog/P1-BT工程直读完成交接日志-20260927.md` | `worklog/01-奠基P1-P6-20260927_20260930/P1-WORKLOG-BT工程直读完成交接-20260927.md` |
| `worklog/P10.10-改名切割详细计划-含v2.3.5可借鉴项-20261008.md` | `plans/P10.10-PLAN-改名切割详细计划-含v2.3.5可借鉴项-20261008.md` |
| `worklog/P10.11-BT三张替换表的语义确认-20261008.md` | `analysis/P10.11-ANALYSIS-BT三张替换表语义确认-20261008.md` |
| `worklog/P10.12-BT与Mangrove整合度全量对照-20261008.md` | `analysis/P10.12-ANALYSIS-BT与Mangrove整合度全量对照-20261008.md` |
| `worklog/P10.13-上游v2.3.5吸取进度与六项现状分析-20261008.md` | `analysis/P10.13-ANALYSIS-上游v2.3.5吸取进度与六项现状-20261008.md` |
| `worklog/P10.14-S9.5-a与S9.5-b人工验收需求-20261008.md` | `plans/P10.14-PLAN-S9.5a与S9.5b人工验收需求-20261008.md` |
| `worklog/P10.15-S9.5a验收结论核对与设计决策-20261008.md` | `worklog/04-BT对照P10-20261008/P10.15-WORKLOG-S9.5a验收结论核对与设计决策-20261008.md` |
| `worklog/P10.16-工作日志-序1到序6施工.md` | `worklog/04-BT对照P10-20261008/P10.16-WORKLOG-序1到序6施工-20261008.md` |
| `worklog/P10.5-BallonTranslator能力对照与移植清单-20261008.md` | `analysis/P10.5-ANALYSIS-BT能力对照与移植清单-20261008.md` |
| `worklog/P10.6-嵌字能力缺口-BT对照与实施方案-20261008.md` | `analysis/P10.6-ANALYSIS-嵌字能力缺口与BT对照方案-20261008.md` |
| `worklog/P10.7-SN1-SN3交付与v2.3.5对照及改名切割方案-20261008.md` | `worklog/04-BT对照P10-20261008/P10.7-WORKLOG-SN1-SN3交付与改名切割方案-20261008.md` |
| `worklog/P10.8-SN1-可复用的识别翻译按钮-20261008.md` | `worklog/04-BT对照P10-20261008/P10.8-WORKLOG-SN1可复用识别翻译按钮-20261008.md` |
| `worklog/P10.9-SN3-mask生产与抹字复原-20261008.md` | `worklog/04-BT对照P10-20261008/P10.9-WORKLOG-SN3-mask生产与抹字复原-20261008.md` |
| `worklog/P11-AI翻译整合与阶段盘点-20261009.md` | `analysis/P11-ANALYSIS-AI翻译整合与阶段盘点-20261009.md` |
| `worklog/P12-翻译工作室界面分区优化方向.md` | `plans/P12-PLAN-翻译工作室界面分区优化方向-20261009.md` |
| `worklog/P13-空状态卡片与死代码清理-20261009.md` | `worklog/05-管线收口与修图P11-P20-20261009_20261010/P13-WORKLOG-空状态卡片与死代码清理-20261009.md` |
| `worklog/P14-工程id分隔符与封面解析-20261009.md` | `worklog/05-管线收口与修图P11-P20-20261009_20261010/P14-WORKLOG-工程id分隔符与封面解析-20261009.md` |
| `worklog/P15-工作室字号上限-20261009.md` | `worklog/05-管线收口与修图P11-P20-20261009_20261010/P15-WORKLOG-工作室字号上限-20261009.md` |
| `worklog/P16-扫描器误认对账表为工程-20261009.md` | `worklog/05-管线收口与修图P11-P20-20261009_20261010/P16-WORKLOG-扫描器误认对账表为工程-20261009.md` |
| `worklog/P17-章节已翻译判据半迁移-20261009.md` | `worklog/05-管线收口与修图P11-P20-20261009_20261010/P17-WORKLOG-章节已翻译判据半迁移-20261009.md` |
| `worklog/P17-翻译组UI恢复与封面语言标识-20261024.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P17-WORKLOG-翻译组UI恢复与封面语言标识-20261024.md` |
| `worklog/P18-封面按卷补齐与vol命名-20261024.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P18-WORKLOG-封面按卷补齐与vol命名-20261024.md` |
| `worklog/P18-第四段修图与自动产物生成下线-20261009.md` | `worklog/05-管线收口与修图P11-P20-20261009_20261010/P18-WORKLOG-第四段修图与自动产物生成下线-20261009.md` |
| `worklog/P19-单块修图与复原+计划书+入口清理-20261009.md` | `worklog/05-管线收口与修图P11-P20-20261009_20261010/P19-WORKLOG-单块修图与复原及计划书与入口清理-20261009.md` |
| `worklog/P19-封面season-vol-event三制与贺图-20261024.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P19-WORKLOG-封面三制与贺图甄别-20261024.md` |
| `worklog/P2-封面与章节显示需求分析-20260928.md` | `analysis/P2-ANALYSIS-封面与章节显示需求-20260928.md` |
| `worklog/P20-单块修图复原接线完成+BT答案-20261010.md` | `worklog/05-管线收口与修图P11-P20-20261009_20261010/P20-WORKLOG-单块修图复原接线完成与BT答案-20261010.md` |
| `worklog/P21-工作室缩略图栏A1开工-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P21-WORKLOG-工作室缩略图栏A1开工-20261010.md` |
| `worklog/P22-缝标记B1判定与持久化层-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P22-WORKLOG-缝标记B1判定与持久化层-20261010.md` |
| `worklog/P23-缝标记B1界面接线-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P23-WORKLOG-缝标记B1界面接线-20261010.md` |
| `worklog/P24-组模型与组合翻译分配-B3B4纯逻辑-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P24-WORKLOG-组模型与组合翻译分配-B3B4纯逻辑-20261010.md` |
| `worklog/P25-跨页文本块与临时拼接-B2纯逻辑-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P25-WORKLOG-跨页文本块与临时拼接-B2纯逻辑-20261010.md` |
| `worklog/P26-跨页框选与缝线高亮-B2界面接线-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P26-WORKLOG-跨页框选与缝线高亮-B2界面接线-20261010.md` |
| `worklog/P27-跨页框选崩溃与长画布卡顿根因-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P27-WORKLOG-跨页框选崩溃与长画布卡顿根因-20261010.md` |
| `worklog/P28-跨页投影片段与长画布重绘收窄-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P28-WORKLOG-跨页投影片段与长画布重绘收窄-20261010.md` |
| `worklog/P29-跨页三任务与右栏AB完工-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P29-WORKLOG-跨页三任务与右栏AB完工-20261010.md` |
| `worklog/P3-BT-v1517-更新冲击分析-20260929.md` | `analysis/P3a-ANALYSIS-BT-v1517更新冲击-20260929.md` |
| `worklog/P3-BT-v1517-更新对比日志-20260929.md` | `worklog/01-奠基P1-P6-20260927_20260930/P3b-WORKLOG-BT-v1517更新对比与合并策略-20260929.md` |
| `worklog/P30-GUI复测五问题修复-20261010.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P30-WORKLOG-GUI复测五问题修复-20261010.md` |
| `worklog/P31-长画布缺页根治与缩放修复-20261011.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P31-WORKLOG-长画布缺页根治与缩放修复-20261011.md` |
| `worklog/P32-GUI验收反馈六问题修复-20261011.md` | `worklog/06-跨页拼接S10-P21-P32-20261010_20261011/P32-WORKLOG-GUI验收反馈六问题修复-20261011.md` |
| `worklog/P33-字体资产系统探测与双端参数统一-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P33-WORKLOG-字体资产系统探测与双端参数统一-20261011.md` |
| `worklog/P34-译文颜色跟随原图取色-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P34-WORKLOG-译文颜色跟随原图取色-20261011.md` |
| `worklog/P35-包子漫画源清理-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P35-WORKLOG-包子漫画源清理-20261011.md` |
| `worklog/P36-下载源取证脚本与RV收尾-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P36-WORKLOG-下载源取证脚本与RV收尾-20261011.md` |
| `worklog/P37-下载源取证发现与GUI复测清单-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P37-WORKLOG-下载源取证发现与GUI复测清单-20261011.md` |
| `worklog/P38-下载源回归诊断与comix加固-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P38-WORKLOG-下载源回归诊断与comix加固-20261011.md` |
| `worklog/P39-下载源根因取证与修复-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P39-WORKLOG-下载源根因取证与修复-20261011.md` |
| `worklog/P4-agent-handoff-comix-to.md` | `handoff/P4-HANDOFF-comix-to源-agent交接-20260929.md` |
| `worklog/P4-comix-to漫画源配置分析-20260929.md` | `analysis/P4a-ANALYSIS-comix-to漫画源配置-20260929.md` |
| `worklog/P4-下一步优化计划-20261005.md` | `plans/P4c-PLAN-下一步优化计划-20261005.md` |
| `worklog/P4-针对comix.to漫画源配置文件的设计与实施工程记录日志.md` | `worklog/01-奠基P1-P6-20260927_20260930/P4b-WORKLOG-comix-to源配置设计与实施-20260929.md` |
| `worklog/P40-交接总结与TraeCN开场白-20261011.md` | `handoff/P40-HANDOFF-交接总结与TraeCN开场白-20261011.md` |
| `worklog/P41-下载源真根因双站修复与门禁回归-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P41-WORKLOG-下载源真根因双站修复与门禁回归-20261011.md` |
| `worklog/P42-包子全章节分页修复与comix快失败兜底-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P42-WORKLOG-包子全章节分页修复与comix快失败兜底-20261011.md` |
| `worklog/P43-comix阅读页全量图与章节翻页修复-20261011.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P43-WORKLOG-comix阅读页全量图与章节翻页修复-20261011.md` |
| `worklog/P44-comix阅读页字段漂移取证与修复-20261012.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P44-WORKLOG-comix阅读页字段漂移取证与修复-20261012.md` |
| `worklog/P45-comix挑战页快速失败与节点实测-20261012.md` | `worklog/07-字体取色与下载源P33-P45-20261011_20261012/P45-WORKLOG-comix挑战页快速失败与节点实测-20261012.md` |
| `worklog/P46-路径便携与搬家自愈-20261013.md` | `worklog/08-路径便携与阅读器P46-P47-20261013_20261015/P46-WORKLOG-路径便携与搬家自愈-20261013.md` |
| `worklog/P47.1-工作日志-R1左侧页轨.md` | `worklog/08-路径便携与阅读器P46-P47-20261013_20261015/P47.1-WORKLOG-R1左侧页轨-20261014.md` |
| `worklog/P47.2-工作日志-R2全局多配色方案.md` | `worklog/08-路径便携与阅读器P46-P47-20261013_20261015/P47.2-WORKLOG-R2全局多配色方案-20261014.md` |
| `worklog/P47.3-工作日志-R3桌面小项批次.md` | `worklog/08-路径便携与阅读器P46-P47-20261013_20261015/P47.3-WORKLOG-R3桌面小项批次-20261014.md` |
| `worklog/P47.4-工作日志-R4设置补项批次.md` | `worklog/08-路径便携与阅读器P46-P47-20261013_20261015/P47.4-WORKLOG-R4设置补项批次-20261014.md` |
| `worklog/P47.5-工作日志-R5可选右缘竖工具栏.md` | `worklog/08-路径便携与阅读器P46-P47-20261013_20261015/P47.5-WORKLOG-R5可选右缘竖工具栏-20261016.md` |
| `worklog/P48-去水印前置与文字块分类重构计划-20261025.md` | `plans/P48-PLAN-去水印前置与文字块分类重构-20261025.md` |
| `worklog/P5-下载补救机制与进度可视化可行性分析-20261005.md` | `analysis/P5-ANALYSIS-下载补救机制与进度可视化-20261005.md` |
| `worklog/P5-分阶段实施计划-20261005.md` | `plans/P5b-PLAN-分阶段实施-20261005.md` |
| `worklog/P5-翻译工作室规划-20260929.md` | `plans/P5a-PLAN-翻译工作室规划-20260929.md` |
| `worklog/P5.1-工作日志-S1下载进度可视化.md` | `worklog/02-下载基础S1-S4-20261005/P5.1-WORKLOG-S1下载进度可视化-20261005.md` |
| `worklog/P5.2-工作日志-S2缺失页记录表.md` | `worklog/02-下载基础S1-S4-20261005/P5.2-WORKLOG-S2缺失页记录表-20261005.md` |
| `worklog/P5.3-工作日志-S3不完整标识与章节配色.md` | `worklog/02-下载基础S1-S4-20261005/P5.3-WORKLOG-S3不完整标识与章节配色-20261005.md` |
| `worklog/P5.4-工作日志-S4补救下载.md` | `worklog/02-下载基础S1-S4-20261005/P5.4-WORKLOG-S4补救下载-20261005.md` |
| `worklog/P51-拆书与合集-总结报告.md` | `worklog/12-收尾P51-P54-20261027/P51.2-WORKLOG-拆书与合集总结报告-20261027.md` |
| `worklog/P53-翻译工程两级布局与junction-P53.md` | `worklog/12-收尾P51-P54-20261027/P53-WORKLOG-翻译工程两级布局与junction-20261027.md` |
| `worklog/P54-那個大公的華麗婚姻騙局中英双版本地化-P54.md` | `worklog/12-收尾P51-P54-20261027/P54-WORKLOG-中英双版本地化-20261027.md` |
| `worklog/P6-BT-v1517提炼与术语统一-20260929.md` | `worklog/01-奠基P1-P6-20260927_20260930/P6a-WORKLOG-BT-v1517提炼与术语统一-20260929.md` |
| `worklog/P6-翻译工作室-可行性与实施计划-20261005.md` | `plans/P6-PLAN-翻译工作室可行性与实施-20261005.md` |
| `worklog/P6.1-现状探查报告.md` | `analysis/P6.1-ANALYSIS-现状探查-20261005.md` |
| `worklog/P6.2-工作日志-S6工程模型层.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P6.2-WORKLOG-S6工程模型层-20261005.md` |
| `worklog/P6.3-S7前风险分析与评估.md` | `analysis/P6.3-ANALYSIS-S7前风险与评估-20261005.md` |
| `worklog/P6.4-库布局分类与卡片统合-可行性分析.md` | `analysis/P6.4-ANALYSIS-库布局分类与卡片统合-20261005.md` |
| `worklog/P6.5-翻译组贯通与合集UI-根因分析.md` | `analysis/P6.5-ANALYSIS-翻译组贯通与合集UI根因-20261006.md` |
| `worklog/P6.6-工作日志-翻译组贯通U1U2U3.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P6.6-WORKLOG-翻译组贯通U1U2U3-20261006.md` |
| `worklog/P6.6-新会话交接词-S7U.md` | `handoff/P6.6-HANDOFF-S7U新会话交接-20261006.md` |
| `worklog/P6.7-下载策略与章节排序-修改计划.md` | `plans/P6.7-PLAN-下载策略与章节排序-20261006.md` |
| `worklog/P7.1-工作日志-S7只读画布与工作室落位.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P7.1-WORKLOG-S7只读画布与工作室落位-20261006.md` |
| `worklog/P8.0-翻译工作室修复与S8开工.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P8.0-WORKLOG-翻译工作室修复与S8开工-20261006.md` |
| `worklog/P8.1-工作日志-S8可编辑画布.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P8.1-WORKLOG-S8可编辑画布-20261006.md` |
| `worklog/P9.0-S9开工前盘点-20261007.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.0-WORKLOG-S9开工前盘点-20261007.md` |
| `worklog/P9.1-工作日志-P2-6a脏页增量.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.1-WORKLOG-P2-6a脏页增量-20261007.md` |
| `worklog/P9.2-工作日志-P2-6b未保存提示.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.2-WORKLOG-P2-6b未保存提示-20261007.md` |
| `worklog/P9.3-工作日志-验证载体与Create块.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.3-WORKLOG-验证载体与Create块-20261007.md` |
| `worklog/P9.4-工作日志-字体属性贯通.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.4-WORKLOG-字体属性贯通-20261007.md` |
| `worklog/P9.5-工作日志-fromOcr反向适配器.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.5-WORKLOG-fromOcr反向适配器-20261007.md` |
| `worklog/P9.6-工作日志-P1批次.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.6-WORKLOG-P1批次-20261007.md` |
| `worklog/P9.7-工作日志-P2批次.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.7-WORKLOG-P2批次-20261007.md` |
| `worklog/P9.8-工作日志-S9.5a端到端验证.md` | `worklog/03-翻译工作室S5-S9-20261005_20261009/P9.8-WORKLOG-S9.5a端到端验证-20261007.md` |
| `worklog/Venera 本地AI翻译引擎与ComicLibrary目录治理开发日志.md` | `worklog/01-奠基P1-P6-20260927_20260930/P0.2-WORKLOG-Venera本地AI翻译引擎与本地库治理-20260927.md` |
| `worklog/Venera 漫画源全方位、全流程开发日志.md` | `worklog/01-奠基P1-P6-20260927_20260930/P0.1-WORKLOG-Venera漫画源全流程开发-20260927.md` |
| `worklog/VeneraX-BT融合开发战略规划与复盘分析.md` | `analysis/P0.3-ANALYSIS-VeneraX与BT融合战略规划与复盘-20260927.md` |
| `worklog/comix-内置独立浏览器方案与实现.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P-DL9.5-WORKLOG-内置独立浏览器方案与实现-20261019.md` |
| `worklog/comix-创建下载任务入口写回与冲突分析.md` | `analysis/P-DL9.2-ANALYSIS-创建下载任务入口写回与冲突-20261019.md` |
| `worklog/comix-图片字节下载试验.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P-DL9.6-WORKLOG-图片字节下载试验-20261017.md` |
| `worklog/comix-换漫画下载复用验证.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P-DL9.4-WORKLOG-换漫画下载复用验证-20261017.md` |
| `worklog/comix-章节列表采集与分组下拉.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P-DL9.7-WORKLOG-章节列表采集与分组下拉-20261017.md` |
| `worklog/comix-第三方判定取证与采集链路修复.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P-DL9.3-WORKLOG-第三方判定取证与采集链路修复-20261019.md` |
| `worklog/comix采集架构与创建下载任务可行性分析.md` | `analysis/P-DL9.1-ANALYSIS-comix采集架构与创建下载任务可行性-20261019.md` |
| `worklog/dev-log-2026-09-30.md` | `worklog/01-奠基P1-P6-20260927_20260930/P0.5-WORKLOG-开发日志-comix源修复与搜索实现-20260930.md` |
| `worklog/local-comic-P1-空漫画链路修复.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P1-WORKLOG-空本地漫画链路修复-20261023.md` |
| `worklog/local-comic-P10-封面修复与详细记录表.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P10-WORKLOG-自定义封面修复与详细记录表-20261024.md` |
| `worklog/local-comic-P11-本地库重构开工与comix全量下载.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P11-WORKLOG-本地库重构开工与comix全量下载-20261024.md` |
| `worklog/local-comic-P12-模式权限内核与封面池.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P12-WORKLOG-模式权限内核与封面池-20261024.md` |
| `worklog/local-comic-P14-D1命名规范与编辑入口.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P14-WORKLOG-D1命名规范与编辑入口-20261024.md` |
| `worklog/local-comic-P15-下载实验坑总结与核验铁律-20261024.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P15-WORKLOG-下载实验坑总结与核验铁律-20261024.md` |
| `worklog/local-comic-P16-comix转本地与章节显示修复-20261024.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P16-WORKLOG-comix转本地与章节显示修复-20261024.md` |
| `worklog/local-comic-P2-刷新扫描注册.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P2-WORKLOG-刷新扫描与注册未登记文件夹-20261023.md` |
| `worklog/local-comic-P3-详情页重构.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P3-WORKLOG-本地漫画详情页重构-20261023.md` |
| `worklog/local-comic-P4-翻译工程详情页.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P4-WORKLOG-翻译工程详情页-20261023.md` |
| `worklog/local-comic-P5-翻译工程显式归属与空壳新建.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P5-WORKLOG-翻译工程显式归属与空壳新建-20261023.md` |
| `worklog/local-comic-P6-成品详情与新建适配.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P6-WORKLOG-成品详情与新建适配-20261023.md` |
| `worklog/local-comic-P8-新建入口常驻与卡片化.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P8-WORKLOG-新建入口常驻与卡片化-20261023.md` |
| `worklog/local-comic-P9-添加章节导入细化与刷新章节.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P9-WORKLOG-添加章节导入细化与刷新章节-20261024.md` |
| `worklog/local-comic-自建加章删章封封面与comix封禁.md` | `worklog/10-comix浏览器与本地库P-DL9-LC-20261017_20261024/P7-WORKLOG-自建加章删章与comix封禁-20261023.md` |
| `worklog/mangrove-同组重复bug根因取证.md` | `analysis/P-DL8.1-ANALYSIS-同组重复bug根因取证-20261017.md` |
| `worklog/mangrove-拷贝漫画章节乱码修复-P52.md` | `worklog/12-收尾P51-P54-20261027/P52-WORKLOG-拷贝漫画章节乱码修复-20261027.md` |
| `worklog/新对话开场白-P47收尾与排期整理.md` | `handoff/P47.5-OPENER-收尾与排期整理-20261014.md` |
| `worklog/新对话开场白-P52起手.md` | `handoff/P52.0-OPENER-起手-20261027.md` |
| `worklog/新对话开场白-本地库重构与模式权限升级.md` | `handoff/P11.0-OPENER-本地库重构与模式权限升级-20261023.md` |
| `新对话开场白-漫画信息自动更新模式-20261016.md` | `handoff/P-DL5.0-OPENER-漫画信息自动更新模式-20261016.md` |
| `项目清理与GitHub上传_plan.md` | `plans/P00-PLAN-项目清理与GitHub上传-20261012.md` |
| `（工作区根）P-DL9_Cloudflare_Bypass_Context.md` | `handoff/P-DL9.0a-OPENER-Cloudflare-Bypass上下文-20261017.md` |
| `（工作区根）新建对话开场白-搬迁与共享记忆库.md` | `handoff/P-DL9.0b-OPENER-comix-to反自动化-20261018.md` |

> 2026-11-02 工作区根收敛：上述两篇 P-DL9 开场白由 `D:\AI Coding Project Management` 根目录归入本目录；
> 同批把 `AI开发条件优化-可行性分析.md` 归入 `_shared/document/analysis/`、Scrollforge 的 S8 开场白归入其
> `.agent/documents/handoff/`，一次性探针脚本与过期截图已删除。
