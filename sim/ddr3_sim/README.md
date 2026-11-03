# DDR3 真实 IP 仿真环境

这个目录解决一个具体问题：**用厂商真实 DDR3 IP 做功能仿真**，而不是只用桩。

## 背景：为什么一开始以为做不到

`ipcore/ddr3_test/rtl/**/*.vp` 是 Synplify 加密的**综合**模型，Questa 没有 Pango 私钥，
报 `syntax error in protected region`。于是最初的 S0 顶层仿真用了端口完全一致的桩。

后来发现厂商还提供了一套**仿真专用**模型，两者不是一回事：

| 来源 | 用途 | Questa 能否编译 |
|---|---|---|
| `ipcore/ddr3_test/rtl/**/*.vp` | 综合模型（Synplify 加密） | **不能** |
| `ipcore/ddr3_test/rtl/**/*.v` | 明文 Verilog（40 个文件） | 能 |
| `ipcore/ddr3_test/sim_lib/**` | 仿真模型（Pango 加密，77 个文件） | **能** |
| `arch/vendor/pango/verilog/simulation/*.v` | Pango 原语行为模型（319 个） | 能 |
| `arch/vendor/pango/verilog/bsim/modelsim10.2c/*_source_codes/*.vp` | 原语内部行为模型 | 能（需补齐） |

正确的组合是 **`rtl/**/*.v` + `sim_lib/**` + 原语库**，而不是 `rtl/**/*.vp`。

## 踩过的 5 个坑

1. **`ddr3.v` 的 include 路径是相对 cwd 的**
   `\`include "../../example_design/bench/mem/ddr3_parameters.vh"` 只有在
   `ipcore/ddr3_test/sim/modelsim` 下编译才解析得到。
   → `prepare_mem_model.ps1` 把内存模型复制到 `mem/` 并把 include 改成同目录文件名。
   **厂商原文件不动。**

2. **原语库缺两组**
   `dll_e2_source_codes`（7 个）和 `iserdes_e2_source_codes`（10 个）需要补进
   `sim/lib/pango_sim`，否则 elaboration 报 `dll_e2_*` / `iserdes_e2_iolhr_il_*` 未定义。

3. **`ddr3_parameters.vh` 需要密度宏**
   `TRFC_MIN` 只在 `ifdef den512Mb/den1024Mb/...` 里定义，不定义就报未声明。
   → 编译加 `+define+den4096Mb`（对应文件头注释里的 4Gb 时序表）。

4. **位宽宏要按板子选**
   板子是 4 条 x8 器件（`MEM_DQS_WIDTH=4`、`MEM_DM_WIDTH=4`、32 位 DQ），
   → 加 `+define+x8`。不加会默认 x16，内存模型端口对不上。

5. **厂商 bench 模型有 SystemVerilog 语法**
   （寄存器出现在连续赋值左侧）→ vlog 必须加 `-sv`。

## 怎么跑

```powershell
# 1. 生成内存模型副本（厂商 IP 重新生成后要再跑一次）
powershell -NoProfile -File sim\ddr3_sim\prepare_mem_model.ps1

# 2. 编译 + 仿真
powershell -NoProfile -File sim\ddr3_sim\run.ps1
```

`tb_ddr3_native.v` 做四件事：

| 用例 | 内容 |
|---|---|
| D1 | 等 `ddr_init_done` 真实拉高 |
| D2 | 原生写突发 8 拍（每拍 32 字节，地址单位 4 字节） |
| D3 | 原生读突发读回 |
| D4 | 逐字节比对，同时验证 lane 顺序 |

## 关于"跑得久"

**不要用 CPU 心跳判断是否卡死。** 实测：

- `run 1us` → 5 秒墙钟（含约 4 秒加载）
- 完整初始化 + 读写需要几百微秒的仿真时间 → **几分钟墙钟**

tb 里每 20 µs 打印一行进度（`TEST_INFO: t=... init_done=...`），
所以判断依据应该是**进度行是否在推进**，而不是跑了几分钟。

另一个容易误判的现象：厂商 PHY 模型在 Time: 0 会刷出成千上万条
`vsim-3015` 端口位宽警告，看起来像卡在加载阶段。这些是噪声，
用 `-suppress 3015 -suppress 3009 -suppress 2241` 关掉即可。

## 当前状态（2026-10-21 实测）

已经确认的部分：

- 编译：0 error
- elaboration：通过
- `run 1us`：5 秒完成，设计加载正常
- `pll_lock`：会拉高（**前提是 `resetn` 已释放**）

尚未打通的部分：

- `ddr_init_done` 到 **342 µs 仍未拉高**，同时 `ddrphy_cpd_lock = 0`
- PHY 一旦进入活动状态，仿真速率从"1 µs/秒"掉到约 **0.43 µs/秒**，
  而且会出现 CPU 时间几乎不增长的长尾（10 分钟只涨十几秒 CPU）

已经排除的假设：

- **不是"复位释放太早"**。我试过把 `resetn` 推迟到 `pll_lock` 之后再释放，
  结果 `pll_lock` 永远不拉高——说明 DDR 内部 PLL 需要 `resetn` 先释放，
  参考顶层"上电后固定延时释放"的做法才是对的。这个反向实验排除了该假设。

结论：DDR3 真实 IP 的功能仿真路径是通的（能编译、能例化、能跑），但
PHY 的校准（CPD/DLL）在这个 Questa + 这套仿真模型的组合下没有走完。
继续深挖属于调厂商模型，成本高且收益不确定。

因此 S2 的协议验证采用**双轨**：

- **行为级 DDR 模型**：验证 `ddr_fetch` 的信用预留、4 KiB 拆分、`rlast`
  早到/迟到检查，秒级反馈，作为日常回归；
- **真实 IP 仿真**：作为里程碑确认，留待有条件时继续（需要连跑几十分钟，
  且要先弄清 CPD 为什么不锁）。

任何"DDR 已仿真验证"的结论在 CPD 打通之前都不能声称。

## 对 S2 的影响

`ddr_fetch` 的协议正确性（信用预留、4 KiB 拆分、`rlast` 检查）可以先用**行为级 DDR 模型**
快速迭代验证；真实 IP 仿真作为**最终确认**，因为它每次要跑几分钟。
两条路都要走，不能只走一条。
