# test-materials/ —— 测试素材与记录的唯一去处

> 建于 **2026-10-26**（P48 七轮）。人工验收原话："你刚才的测试产生了太多乱七八糟的文件……
> 你做测试的素材和记录都放在统一的测试材料文件夹里面。"
>
> 本目录**整体被 `.gitignore` 排除**，不进版本库。

## 一、三条铁律

1. **测试产物一律落这里**，不许再往 `builds/` 根、工程根、`Mangrove/` 根丢图片/截图/临时 json。
2. `builds/` 只留**工装正在读写的文件**（`build.log`、`step_*.log`、`headless.out`、`_inner_probe.txt`、`mangrove/`）。
3. 一次验证一个子目录，目录名自带"什么时候 + 哪一轮 + 验的是什么"。

## 二、目录布局

```
test-materials/
├── README.md                  ← 本文件
├── runs/                      ← headless 断言的输出（--json 默认落点）
│   ├── block_ops_check.json   ← 块操作断言集（最近一次）
│   ├── bootstrap_check.json
│   ├── glossary_check.json
│   ├── run_plan_check.json
│   └── portable_paths_check.json
├── inpaint/                   ← 修图/去水印的对照图（按轮次分）
│   ├── 2026-10-26-p48-r5-lama/      五轮：LaMa 接入 + 纹理/结构两档
│   ├── 2026-10-26-p48-r6-route/     六轮：路线拆分 + 长边上下文 + 多轮增强
│   └── 2026-10-26-p48-r7-shape/     七轮：椭圆形状 + 语言导向 + session 复用
└── legacy/                    ← 2026-10-25 及更早的一次性输出
```

## 三、命名规则（新产物照此命名）

| 前缀 | 含义 | 例 |
|---|---|---|
| `cmp_` | **对照图**（左右/上下拼一张，人工验收用） | `cmp_p33_wm.png` |
| `v{轮}_` | 第 {轮} 次尝试的**整页**输出 | `v6_p33ai.png` |
| `zoom_` | 局部放大 | `zoom_p7.png` |
| `crop_` | 送进模型的**上下文裁剪框** | `crop_p33_577x411.png` |
| `mask_` | 掩膜可视化 | `mask_p33.png` |
| `chk_` | 断言/探针的辅助图 | `chk_layout.png` |

页面编号沿用工程里的键（`003` / `007` / `010` / `011` / `033`），不写 `p3` 这种会与"第 3 页 vs 003.webp"混淆的简写 —— 历史文件保留了旧名，新文件一律用三位编号。

## 四、清理策略

- `runs/*.json`：每次跑断言覆盖同名文件，**不需要备份**（结果在对话里也已汇报）。
- `inpaint/<轮次>/`：同一轮的中间尝试可以随时删，**只保留 `cmp_` 对照图和最终 `v{轮}_` 输出**。
- 整轮结论已经写进 `.agent/documents/worklog/<日期>.md` 的，图片可以在下一轮验收后整体删除。

## 五、为什么当初会乱

`builds/` 里堆了 100 个文件，是因为**每次实测都把图直接写到 `builds/`**（headless 的 `--out` 默认落在
`Directory.current`，而命令都在 `builds/` 下跑）。现在两边都钉死了：

- 代码侧：`--headless block-ops-check` 等命令的 `--json` **默认值**改到 `test-materials/runs/`；
- 流程侧：所有 `--out` 显式写成 `test-materials/inpaint/<轮次>/xxx.png`。
