# .agent · 多 agent 共享工作区

> **这是本仓库所有 AI agent 相关数据的唯一真身。**
> `.workbuddy/`、`.trae/`、`<项目根>/docs` 里的同名目录都是**指向本目录的 Windows 目录联接（junction）** ——
> 它们不是副本。**改哪条路都是改同一份文件。**

## 目录职责

| 路径 | 放什么 |
|---|---|
| `memory/MEMORY.md` | **主记忆（唯一被自动注入的文件，≤3K 字符）**：框架 + 索引 + 三条底线 |
| `memory/appendices/` | 编号附录 `A01~A08`（项目事实）+ `W00`（工作日志编号索引） |
| `memory/YYYY-MM-DD.md` | 每日工作日志（**只追加**） |
| `documents/worklog/` | 42 篇历史工作日志本体（= 项目根的 `docs/`） |
| `documents/plans/` | 计划类文档 |
| `skills/` | 技能（如 `venera-windows-build`） |
| `specs/` | 规格 |
| `kb/` | **跨项目可复用**的知识库（当前：`methodology/` M01~M07） |

**分工**：`memory/` = 本项目的事实；`kb/` = 能带走的方法。

## 给 AI agent 的读取顺序

1. 先读 **`memory/MEMORY.md`**（框架 + 索引 + 底线）。
2. 需要动手前，按索引里的「触发时机」读对应附录 `memory/appendices/A0x`。
3. 要做**设计/验证/交接**类决策时，读 **`kb/INDEX.md`** 挑对应方法论。
4. 要查历史决策的来龙去脉时，看 **`memory/appendices/W00-工作日志索引.md`**。

## 🔴 两条纪律

1. **绝不写绝对路径。** 项目根目录**将来会改名**。用相对路径；脚本必须由**自身位置**推导根目录。
2. **不要再手动同步。** 过去那套「写完 `.workbuddy` 再拷回 `.trae`」已作废 —— 联接已经保证是同一份。

## 接入新的 AI agent

1. 查清它默认读哪些目录/文件名；
2. 给它需要的子目录建**目录联接**：
   ```powershell
   New-Item -ItemType Junction -Path '<根>\.新工具\memory' -Target '<根>\.agent\memory'
   ```
3. 如果它需要"规则/入口"文件，**只写一个薄指针**（指向 `kb/INDEX.md` 与 `memory/MEMORY.md`）；
4. 跑一次 `python tools/agent_links_check.py` 确认联接都在。

> 完整方法论见 `kb/methodology/M07-多agent共享工作区.md`。

## 体检

```bash
python tools/agent_links_check.py
```

检查：9 条联接是否存在且指向正确、主记忆是否超限、关键文件是否齐全、有无残留的重复副本。
