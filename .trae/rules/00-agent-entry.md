# 00 · Agent 入口（Trae 项目规则）

> 薄入口。权威内容不在本文件，请按顺序去读。

## 读取顺序

1. **`.agent/memory/MEMORY.md`** —— 主记忆：框架 + 索引 + **三条不能违反的底线**。
2. `.agent/memory/appendices/A0x-*.md` —— 项目事实，按 MEMORY.md 索引的「触发时机」按需读。
3. `.agent/kb/INDEX.md` —— 跨项目方法论 M01~M07。
4. `.agent/memory/appendices/W00-工作日志索引.md` —— 历史决策的来龙去脉（W01~W42）。

## 🔴 两条硬约束

1. **目录唯一真身 = `.agent/`**。
   本仓库的 `.trae/{memory,documents,skills,specs}` 是**指向 `.agent/` 的目录联接（junction）**，
   不是副本 ⇒ **不要再做「两边同步」**；改哪条路都是改同一份文件。
2. **绝不写绝对路径**（项目根目录将来会改名）。
   一律相对路径；工具脚本必须由**自身位置**推导根目录（`%~dp0` / `__file__`）。

## 环境要点（详见 `A01`）

- 构建：`python tools/run_build_task.py`（用托管 venv python），看 `builds/build.log` 的 `BUILD_OK`。
- headless：`python tools/run_headless_task.py <命令…>`，输出在 `builds/headless.out`。
- ⚠️ **本环境没有渲染表面**：凡涉及图像解码/渲染的操作只能在用户登录的 GUI 会话做。
- 体检目录联接：`python tools/agent_links_check.py`。
