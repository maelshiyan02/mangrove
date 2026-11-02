# P-DL9 开场白 — Trae 新对话交接（2026-10-17）

> 用法：将下方「开场白正文」整段复制到 Trae 新对话作为首条消息。
> 本文件是交接底稿，Trae 侧完成 P-DL9 后应在其工作记录中注明来源。

---

## 开场白正文

【Mangrove 项目开发交接 · P-DL9：comix.to 章节采集失败诊断与高级过滤器搜索】

你是接手 Mangrove 项目下一阶段（P-DL9）开发的 AI Agent（Trae）。上一轮由 WorkBuddy 会话完成到 P-DL8，本项目采用「主记忆 + 附录 + 工作日志」的多 Agent 范式，跨 Agent 交接以 `.agent` 目录为唯一权威。开工前请先完成「必读清单」，再进入任务。

### 一、项目身份与文件位置
- 项目：**Mangrove** —— Windows/Flutter 漫画 AI 汉化阅读器（fork 自上游 Venera 2.3.4，2026-10-08 由 VeneraX 改名独立计数）。
- 仓库根：`D:\AI Coding Project Management\Mangrove\`
  - Flutter 工程：`Mangrove\Mangrove\`（`pubspec.yaml` 当前 `2.8.4+248`，About 页读 `V${App.version}`）
  - 构建/审计工具：上一级 `tools\`（`run_build_task.py`、`run_mangrove_check.bat`、`run_headless_task.py`、`tl_key_audit.py`）
  - 工程日志：`.agent\documents\worklog\`（P-DL1 ~ P-DL8；最新 `../worklog/09-下载管理P-DL-20261014_20261017/P-DL8-WORKLOG-收藏页未登录引导修复-20261017.md`，验收已通过）
  - 运行时数据：`data\`（含 `comic_source\comix_to.js`、`comix_to.data`、`baozi.js` 等；软件调试日志 `data\logs.txt`）
- 上一级共享记忆（跨项目）：`D:\AI Coding Project Management\.workbuddy\memory\`（`MEMORY.md` 长期事实 + `2026-10-17.md` 当日记录）。
- 技能/环境/知识库共享：**暂未建设**，环境与工具知识全部固化在 `.agent` 附录中，以下方附录为准。

### 二、必读清单（按顺序）
1. `.agent\memory\MEMORY.md` —— 项目主记忆 + 附录索引表。本轮重点附录：
   - **A01 环境通道** / **A02 硬规矩与断言纪律**（构建纪律，不可违反）
   - **A07 comix源**（comix.to 源专项档案：WAF/TLS 指纹/签名 token/CDN 轮换历史）
   - **A09 网络与代理** / **A11 下载源适配档案**（多轮超时策略、包子源迁移、节点实测）
   - **A15 版本号规则** / **A16 运营坑与取证工具**（含"agent-browser 卡 Chromium 改 curl 兜底"、"Not login 是框架拦截"）
2. `.agent\memory\appendices\W00-工作日志索引.md` —— 全部工作日志索引（含 W00a/b/c 分卷）。
3. 最新日志 `P-DL8-…20261017.md` 与本轮相关的 `../worklog/07-字体取色与下载源P33-P45-20261011_20261012/P45-WORKLOG-comix挑战页快速失败与节点实测-20261012.md`、`../worklog/07-字体取色与下载源P33-P45-20261011_20261012/P38-WORKLOG-下载源回归诊断与comix加固-20261011.md`。
4. 写任何修改计划前，先读 `data\logs.txt` 软件调试日志取证（证据先行）。

### 三、硬规矩（不可违反）
- **构建**：只能 `python tools/run_build_task.py`，且必须用已装 pywin32 的 venv：
  `C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe`；
  `builds\build.log` 出现 `BUILD_OK` 才算通过（内含 analyze 闸门）。**禁止直接跑 flutter/dart 构建**。
- **测试**：`flutter test` 在沙盒不可用（WebSocket 握手失败），渲染/解码类验证只能在用户 GUI 会话进行；本机静态校验用 `run_mangrove_check.bat`（flutter analyze）。
- **i18n**：新增 `.tl`/`.tlParams` 键必须同步 `assets/translation.json` 的 zh_CN + zh_TW，审计 `TOTAL MISSING=0`。
- **git**：改动只进本地 git，攒批统一 push（push 由用户拍板）；汇报一律中文、结构化条目化。
- **版本号**（A15）：base-10 三段式 `大.小A.小B`（满 10 进位），每批施工类日志 = 1 小版本，权威落点 `pubspec.yaml`。当前 `2.8.4+248`；**P-DL8 已交付尚未定版，push 前按规则 +1（→ 2.8.5）**。
- **验收**：任何"已完成"必须有故障注入断言真的 FAIL 作证据；空结果判 FAIL。

### 四、本轮任务（P-DL9）
**背景**：漫画《I will save my father》（来源 comix.to）章节信息更新失败（超过 60 秒无法采集到章节信息），并衍生出两个连锁问题：主页搜索栏 comix.to 源搜索失败、comix.to 漫画无法下载。

1. **诊断章节采集失败根因**：以《I will save my father》为例，判断超过 60 秒采不到章节信息的原因；区分到底是**网络连接问题**，还是 **comix.to 防火墙/反爬又升级了**（对照 A07/A11 档案中的历史 WAF、TLS 指纹拦截、签名 token、CDN 轮换记录，注意 comix_to.js 现有超时预算：阅读 30s / 下载 30s×3 / onImageLoad 90s）。
2. **用 Trae 内置浏览器自动操作**检测网络连接与站点现状（站点可达性、接口行为、是否触发挑战页）。
3. **浏览器取证注意事项**：comix.to 有**透明广告页面**，需点击弹出一次才会关闭；且页面超过一定时间不动，广告会重新生成——自动化脚本须处理这两点，避免误判为站点故障。
4. **代理**：comix.to 访问受代理影响，若内置浏览器访问失败，尝试更换 **ikuuu VPN 的代理节点**后重测（对照 A09）。
5. **修复章节信息采集**（问题 1 的落地）。
6. **主页搜索栏 comix.to 搜索失败修复 + 高级过滤器**：comix.to 网站内置「ADVANCED FILTERS」高级过滤器（实测字段：`Sort by`（默认 Latest Update）、`Content Rating`、`Types`（如 Manhwa）、`Genres`、`Demographic`、`Release Status`、`Minimum Chapter`、`Release Year`（From–To）、`Authors`、`Artists`、`Reset Filters`、`I'm Feeling Lucky`；结果计数如 15,479 items，另有列表/网格视图切换）。请升级 Mangrove 搜索栏的 comix.to 搜索逻辑，接入该高级过滤器能力（API query 参数映射参考 comix_to.js 现有 `_comixBrowse` 的 query 组装：`query.types`/`query.statuses` 等已存在）。
7. **中文适配**：过滤器字段多为英文，接入前做好中文翻译（zh_CN + zh_TW 双语）；功能名不必直译 "Advanced Filters"，可选更符合中文用户习惯的命名（如「高级筛选」），定名后在日志中说明理由。
8. **修复连锁的 comix.to 漫画无法下载问题**（与章节采集失败同源或独立，需分别下结论）。
9. **comix.to 登录功能检查与修复**：网站本身有账号登录。**已知线索**：`data\comic_source\comix_to.js` 第 232-237 行注释明确「不定义 favorites——收藏需站内账号登录，未实现登录前不提供，避免 Not login 报错」，且 `account = {}`、`settings = {}` 均为空配置——即"登录被禁用"实为**源配置从未实现登录**（设计取舍），并非运行时开关。请查明当时取舍上下文（见相关 P4x 日志），评估实现 signin 接口接入的可行性并尝试修复；若维持禁用，给出明确理由。
10. **收尾规范**：完成后写 P-DL9 工作日志（含修复过程、验收点、人工反馈预留区）+ 更新 W00 索引 + 回写附录（新坑进 A16，comix 结论更新 A07）+ `.workbuddy\memory` 当日记录；受控构建 BUILD_OK 后交用户人工验收，push 待用户拍板。

### 五、验收标准
- 《I will save my father》章节信息可在 60 秒内采集成功（给出前后对比证据）。
- 搜索栏 comix.to 高级过滤器可用、字段中文化、双语齐全。
- comix.to 漫画下载恢复。
- comix.to 登录：可用，或给出"为何不可用/为何维持禁用"的明确结论。
- `run_build_task.py` BUILD_OK、analyze 0 error、i18n 0 缺失。

### 六、开场动作
1. 按第二节读完整记忆（不要只读 MEMORY.md 正文，附录才是细节）。
2. 读 `data\logs.txt` 中 comix_to 相关报错取证。
3. 输出你对 P-DL9 的执行计划（含任务拆分与判定标准），经用户确认后再动代码。
