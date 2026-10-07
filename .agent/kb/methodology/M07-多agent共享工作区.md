# M07 · 多 agent 共享工作区约定

> **什么时候读**：接入一个新的 AI 编码工具（agent）；整理项目的"agent 相关目录"；换机器 / 改项目根目录名之前。
> 上级：`../INDEX.md` ｜ 相关：`M04`（交接）、`M05`（产物）

---

## 问题

每个 AI 工具都自带一套约定目录（记忆、文档、技能、规格），名字还不一样：

| 工具 | 它默认会找的目录 |
|---|---|
| WorkBuddy | `.workbuddy/{memory,documents,skills,specs}` |
| Trae | `.trae/{memory,documents,skills,specs}` |
| 其他 / 未来新增 | 各自一套 |

一开始的解法是"写完 A 再拷回 B" —— **这是错的**：迟早忘记同步，于是产生 `M03` 形态 1/7（同名异义、静默分叉）。

## 方案：一个真身 + N 个入口

```
<项目根>/
├── .agent/              ← 🔴 唯一真身（真实文件都在这里）
│   ├── memory/          记忆（MEMORY.md + appendices/ + YYYY-MM-DD.md）
│   ├── documents/       文档（worklog/ plans/ …）
│   ├── skills/          技能
│   ├── specs/           规格
│   └── kb/              跨项目知识库（方法论/技术要点）
├── .workbuddy/
│   └── memory → ../.agent/memory        ← 目录联接（junction）
│   └── documents/skills/specs → …       ← 同理
├── .trae/
│   └── memory/documents/skills/specs → …← 同理
└── docs → .agent/documents/worklog      ← 同理（保住所有既有相对引用）
```

**要点**：

1. **真实文件只存在一份**，在 `.agent/`。
2. 其余路径都是**目录联接（junction）** → 对文件 API **完全透明**，各工具读写的都是同一份。
3. 老引用（`docs/xxx.md`）**不用改**：`docs` 仍然可解析。
4. **新增 agent** = 给它需要的子目录建一条 junction（或直接告诉它读 `.agent/`）。

### Windows 目录联接（junction）实操

```powershell
# 建立（无需管理员权限；目录联接只能在同一卷内）
New-Item -ItemType Junction -Path '<项目根>\.trae\memory' -Target '<项目根>\.agent\memory'

# 校验（看 LinkType / Target）
Get-Item '<项目根>\.trae\memory' -Force | Select-Object Name, LinkType, Target

# 删除联接本身（不会删目标内容！）
cmd /c rmdir "<项目根>\.trae\memory"
```

⚠️ **注意**：
- **`rm -rf` / 递归删除工具可能跟随联接**，从而删掉**目标目录的内容**。删除联接请用 `rmdir`（指向目录联接时只移除链接）。
- 目录联接**不能跨卷**；需要跨卷时改用符号链接（需管理员或开发者模式）。
- 备份工具可能**跟随联接**造成重复备份 —— 备份时明确排除或明确包含一次。
- 若某个工具会"删掉并重建"自己的子目录，联接会被打断 → 建议配一个**巡检脚本**（检查 `LinkType` 是否为 Junction，坏了就重建）。

**巡检脚本**：`tools/agent_links_check.py`（本仓库提供；无参数运行即体检）。

## 目录职责

| 目录 | 放什么 | 不放什么 |
|---|---|---|
| `.agent/memory/` | 记忆主文件（**小**，只放框架与索引）、编号附录、每日日志 | 大段正文（拆成附录） |
| `.agent/documents/` | 工作日志（编号）、计划、交接文档 | 记忆（那是 memory 的活） |
| `.agent/kb/` | **可迁移**的方法论/技术要点 | 项目专有事实 |
| `.agent/skills/` `.agent/specs/` | 各工具的技能与规格 | 临时产物 |

## 🔴 两条衍生纪律

1. **绝不写绝对路径。**
   项目根目录**迟早会改名/搬迁**。所有引用用**相对路径**；脚本必须**由自身位置推导根目录**：
   ```python
   ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # tools/x.py → 项目根
   ```
   ```bat
   cd /d "%~dp0.."          :: 批处理：切到脚本所在目录的上一级
   ```
2. **主记忆文件必须小。**
   自动注入的记忆文件通常有**字符上限，且超限是"静默截断尾部"**（不是报错）。
   ⇒ 主文件只放**框架 + 索引 + 三条底线**，正文全部拆成编号附录；索引里写清
   **"做什么之前该读哪一篇"**。

## 接入新 agent 的检查清单

- [ ] 它默认读哪些目录/文件名？（记忆、规则、技能）
- [ ] 已经用 junction 指向 `.agent/` 了吗？
- [ ] 有没有一个**薄入口文件**（如 `AGENTS.md`）告诉它"先读 `kb/INDEX.md` 与 `memory/MEMORY.md`"？
- [ ] 该工具会不会重建自己的目录（会 → 加巡检）？
- [ ] 备份/清理流程有没有把联接当普通目录处理（会 → 危险）？
