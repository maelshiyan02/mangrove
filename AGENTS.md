# AGENTS.md · 给任何 AI agent 的入口

> 本文件是**薄入口**：只告诉你去哪里读，不重复内容。
> 适用于任何会读 `AGENTS.md` 的编码 agent（Codex / Cursor / Copilot Workspace / 其他）。

## 你要读的三个地方

| 顺序 | 路径 | 内容 |
|---|---|---|
| 1 | **`.agent/memory/MEMORY.md`** | 主记忆：框架 + 索引 + 三条不能违反的底线（**必读**） |
| 2 | **`.agent/memory/appendices/A0x-*.md`** | 项目事实（按 MEMORY.md 索引里的「触发时机」按需读） |
| 3 | **`.agent/kb/INDEX.md`** | 跨项目方法论 M01~M07（做设计/验证/交接前读） |

历史决策的来龙去脉：`.agent/memory/appendices/W00-工作日志索引.md`（W01~W42）。

## 两条硬约束

1. 🔴 **目录唯一真身是 `.agent/`**；`.workbuddy/`、`.trae/`、`docs/` 是指向它的**目录联接**。
   **不要**在其中任何一侧做"同步副本"。
2. 🔴 **绝不写绝对路径**（项目根目录会改名）。用相对路径；脚本由**自身位置**推导根目录。

## 项目速览

- Flutter Windows 漫画阅读器 / 翻译工作室（`VeneraX/`），把 BallonTranslator 的翻译管线融进来。
- 构图件：`ComicLibrary/`（三个根：`downloads` 本地库 / `projects` 工作室工程 / `translated` 成品）。
- 工具链：`tools/`（构建工装、headless 工装、反向验证、字体检查…）。
- 当前阶段与卡点：见 `.agent/memory/appendices/A08-排期与阶段现状.md`。
