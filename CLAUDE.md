# CLAUDE.md · Claude Code 入口

> 薄入口。**权威内容不在本文件**，请按下面顺序去读。

0. **`../_shared/index.md`** —— 工作区共享层（全局规则 / 通用网络 / 共享 venv / 方法论 M01~M14）。
1. **`.agent/memory/MEMORY.md`** —— 主记忆（框架 + 索引 + 三条底线）。**先读这个。**
2. `.agent/memory/appendices/` —— 项目事实 A01~A14：`A01` 环境 / `A02` 硬规矩 / `A03` 布局 / `A04` 工作室画布 / `A05` 字体出图 / `A06` 翻译组 / `A07` comix 源 / **`A08` 现状（开工第一件事）** / `A09` 网络代理 / `A10` S10 跨页拼接 / `A11` 下载源 / `A12` S9.5 收口 / `A13` 术语表与基线 / `A14` 路径便携与搬家自愈。
3. `.agent/kb/INDEX.md` —— 项目内方法论 M01~M11（断言 / 反向验证 / 静默分歧 / 报告 / 产物一致性 / 零字节往返 / 多 agent 工作区 / 故障注入 / 批处理陷阱等；M12~M14 在共享层）。
4. `.agent/memory/appendices/W00-工作日志索引.md` —— 工作日志**总索引**，明细在 W00a~W00e 五个分卷（W01~W54 + P11~P45）。

## 🔴 两条硬约束

1. **目录唯一真身 = `.agent/`**。`.workbuddy/`、`.trae/`、`docs/` 是指向它的**目录联接**；不要在任一侧另存副本。
2. **绝不写绝对路径**（项目根目录会改名）；脚本由自身位置推导根目录。

## 三个开工前必看的答案

- 构建：`python tools/run_build_task.py` → 看 `builds/build.log` 里的 `BUILD_OK`。
- headless：`python tools/run_headless_task.py <命令…>`（输出 `builds/headless.out`）。
- ⚠️ 本环境**图像像素类操作**（解码/渲染）跑不了（没有渲染表面），只能在用户 GUI 会话做。
