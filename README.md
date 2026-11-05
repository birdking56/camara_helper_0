# camara_helper_0 · FPGA 图像几何矫正

紫光同创 Pango PDS 工程（唯一正式工程 `camara_helper_0.pds`，顶层 = `source/top/dgc_top_sys.v`）。

数据通路：HDMI 输入 → DDR3 帧缓存 → 源缓存 / 取数 → 坐标映射 + 双线性插值 → DDR3 写回 → HDMI 输出，
配套 UART 调试协议、Questa 仿真测试台与 Python 定点黄金模型。

> **项目目标**：对视频画面做实时几何矫正，最终支持随设备姿态变化的任意角度实时矫正。
> **当前进度**：只完成了基础矫正通路 —— **基于 IMU 的任意角度矫正尚未实现**，详见下一节。

## 当前状态

| 能力 | 状态 |
|---|---|
| HDMI 输入 / 输出、DDR3 帧缓存 | 已实现 |
| 整帧坐标映射 + 双线性插值 | 已实现 |
| 恒等映射、标定参数 k1/k2 的径向去畸变 | 已实现 |
| UART 调试协议（DGC5）：遥测、参数下发、状态回读 | 已实现 |
| Questa 测试台与回归脚本 | 已实现 |
| Python 定点黄金模型、误差预算、向量生成 | 已实现 |
| 姿态 / 投影变换（p1、p2、k3 等） | 接口中预留字段，**未实现** |
| **IMU 融合的任意角度实时矫正** | **未实现** |

> 按项目内部的接口冻结规范，姿态变换相关字段目前只是预留；未实现的能力必须在 capability 中标为不支持，
> 启用请求要返回错误而不是静默忽略。所以本工程**现在不具备任意角度自动矫正能力**，
> 实际可用的是固定参数的几何矫正。

## 快速开始

1. **打开工程**：PDS 打开 `camara_helper_0.pds`（不要打开 `synthesis/`、`place_route/` 等目录下的工作副本）。
2. **综合 / 布局布线 / 码流**：`impl.tcl`（PDS 流程脚本）。
3. **仿真**：`sim/run_all.ps1` 跑全部套件，或进入单个 `sim/sN_*` 目录执行 `run.ps1`（需要 Questa）。
4. **板级调试**：`tools/serial_capture.ps1` 只读采集串口 → `tools/dgc3_decode.py` 解码报文。

## 目录

| 目录 / 文件 | 内容 |
|---|---|
| `source/` | RTL 源码，按功能分 `top / capture / fetch / cache / geometry / process / display / control / debug / common / hdmi` 等子目录 |
| `constraints/` | 板级与时钟约束（FDC） |
| `ipcore/` | Pango IP（PLL、FIFO、RAM、DDR3），生成产物，不要手改 |
| `sim/` | Questa 测试台与运行脚本 |
| `model/` | Python 定点黄金模型、误差预算与向量生成 |
| `tools/` | 串口采集 / 解码等诊断脚本 |
| `camara_helper_0.pds` | PDS 工程文件（top = `dgc_top_sys`） |
| `impl.tcl` | PDS 流程脚本 |

## 关于文档与开发记录

本仓库**不包含**设计文档、开发过程日志与改动备份：接口冻结规范、串口协议、阶段验收报告、
目录结构说明、交接日志、开发日志，以及每次改动前的文件快照（`archive/`），全部只在本地维护。

仓库里只保留能直接打开、编译、仿真所需的东西：RTL 源码、约束、IP、测试台、定点模型与诊断脚本。

## 关于本仓库

综合 / 布局布线 / 码流 / 仿真构建产物、运行日志、备份文件以及全部文档与开发日志都不入库（见 `.gitignore`）。
拉下来后需要在本机用 PDS 与 Questa 自行生成构建产物。
