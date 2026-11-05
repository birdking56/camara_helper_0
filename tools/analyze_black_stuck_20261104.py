"""Summarize the read-only 30-second capture; preserve its matching STA report."""
from pathlib import Path
from collections import Counter
from datetime import datetime, timezone, timedelta
import json
import re
import shutil

import dgc3_decode as decoder

root = Path(__file__).resolve().parents[1]
log = root / 'tools/uart_black_stuck_20261104.log'
snaps, lines = decoder.parse(log)
assert len(snaps) == 30 and lines == 330

def values(label, word):
    return [s.w(label, word) for s in snaps]

def span(items):
    return {'min': min(items), 'max': max(items)}

def deltas(label, word):
    a = values(label, word)
    return [(y-x) & 65535 for x, y in zip(a, a[1:])]

proc_period_ns = 5.842
frame_us = 2200*1125*6.727/1000
k1 = values('K', 1)
result = {
    'snapshots': len(snaps),
    'capture_delta_per_report': dict(Counter(deltas('S', 2))),
    'jobs_delta_per_report': dict(Counter(deltas('J', 0))),
    'underflow_delta_per_report': dict(Counter(deltas('G', 2))),
    'source_fid_delta_per_report': dict(Counter(deltas('M', 0))),
    'source_age_frames': span([(s.w('M',1)-s.w('M',0)) & 65535 for s in snaps]),
    'capture_aborts': span(values('S', 3)),
    'write_aborts': span(values('W', 1)),
    'alloc_drops': span(values('M', 3)),
    'tick_skip': span(values('G', 1)),
    'job_max_raw_us_counter': span(k1),
    'job_max_us_scaled_to_report_clock': span([x*171*proc_period_ns/1000 for x in k1]),
    'display_frame_us_from_report_clock': frame_us,
    'latched_last_starvation_stripe': span([s.w('V',2) & 127 for s in snaps]),
    'latched_first_line_miss_snapshots': sum(bool(s.w('V',2)&128) for s in snaps),
    'latched_midframe_starvation_stripe': span([s.w('V',2)&127 for s in snaps if not (s.w('V',2)&128)]),
    'offers_per_report': span(values('V',0)),
    'discards_per_report': span(values('V',1)),
    'releases_per_report': span(values('V',3)),
    'writer_stall_counter': span(values('Q',2)),
    'fill_active_ms_per_report': span([x*4096*proc_period_ns/1e6 for x in values('P',0)]),
    'fill_wait_beat_ms_per_report': span([x*4096*proc_period_ns/1e6 for x in values('P',1)]),
    'reader_black_snapshots': sum(bool(s.w('G',3)&1024) for s in snaps),
    'writer_watchdog_sticky_snapshots': sum(bool(s.w('K',3)&1024) for s in snaps),
    'output_sum_distinct_values': len(set(values('W',3))),
}
archive = root / 'archive/board_stuck_20261104_1755'
archive.mkdir(parents=True, exist_ok=True)
for rel in ('report_timing/dgc_top_sys.rtr', 'tools/uart_black_stuck_20261104.log',
            'tools/black_stuck_decode_20261104.txt'):
    dest = archive / Path(rel).name
    if not dest.exists():
        shutil.copy2(root / rel, dest)
(archive / 'summary.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
print(json.dumps(result, indent=2))

stamp = datetime.now(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M')
doc = root / 'docs/交接_20261030重启.md'
text = doc.read_text(encoding='utf-8')
status = f'''## 1. 当前状态（更新到 {stamp}）

**最新布局已全部收敛；用户上板报告显示器黑屏卡住。只读 30 秒串口显示输入/任务/源帧号持续推进，但显示读端每帧欠载。尚未证明显示器端 HDMI 链路正常。**

本地最新 report_timing 日期 2026-11-04 17:55:59，`All Constraints Met`：proc setup +0.013 ns、recovery +0.667，
DDR setup +0.100，vout setup +0.966；setup/hold/recovery/removal 均无失败端点。上一轮长 CECO/RSCO 控制路径优化已通过这次物理报告。
本轮仅 COM3 115200 8N1 只读，DTR/RTS=false，未复位、重配或修改生产 RTL。

`tools/uart_black_stuck_20261104.log`：30 个完整 DGC5 快照（330 行）。29 个窗口差分中，输入 +60 有 27 次、+59 有 2 次；
job +40 有 28 次、+41 有 1 次；欠载 **全部 +60/窗口**。源 fid 每窗口 +59~61，源帧龄 1~3，采集/写入 abort 和 alloc_drop 均 0。
K1 每窗口最大完整任务计数 16740~16748（171 拍/计数），按报告 proc 周期约 **16.723~16.731 ms**，
而 2200×1125 的显示帧周期按报告时钟约 **16.649 ms**。任务已可完整结束，供给仍略慢于显示；不能把约 40 job/s 直接归为 acquire/pend 丢失。
K0 约 40 请求/应答，G1=0；V0≈V3≈2720/窗口（约 40×68），V1=1722~1794；30 个快照 reader.frame_black 均为 1。
最近一次欠载位置：26 个快照为中途 stripe {result['latched_midframe_starvation_stripe']['min']}~{result['latched_midframe_starvation_stripe']['max']}，4 个快照锁存首条带未赶上。
V2 仅是最近事件位置，不等于窗口内全部事件的分布。输出 RGB 滚动和 30 次均变化，说明内部仍有像素活动，不能据此证明显示器接收到了正常画面。

fill 活跃约 640~660 ms/窗口，等 beat 76.7~78.9 ms；缓存写口仍是 fill 主体。
这些量给出实时供给/逐条带截止时间的问题，不足以仅凭总耗时断定唯一瓶颈是 DDR 带宽，也不能代替物理 HDMI 观察。
本轮未更改算法/生产 RTL；证据、17:55 报告与汇总已保存在 `archive/board_stuck_20261104_1755/`。
解码器去掉了“acquire 达到 40 就断定 pend/start 故障”的过强结论；6 项解码器测试通过。

'''
start = text.index('## 1. 当前状态')
end = text.index('### 冻结修复基线', start)
text = text[:start] + status + text[end:]
start = text.index('## 6. 下一步')
end = text.index('## 7. 常用判据', start)
text = text[:start] + f'''## 6. 下一步（更新到 {stamp}）

1. 已保存收敛报告和黑屏串口基线。不要把本轮约 40 job/s 与旧 acquire 拒绝/源帧冻结混为一谈；完整任务可结束、源 fid 正常前进。
2. 继续诊断真实 fill/DDR/采集写竞争与每条带 ready 截止时间，建立能复现 stripe 中途欠载的板速仿真；现有理想 DDR 模型两帧通过并未覆盖本次板上行为。
3. 同时保留显示器侧问题：内部输出 RGB 和仍活动，但用户看到整屏黑；串口不直接测 TMDS 接收/显示器锁定。
4. 本轮只完成串口与报告分析，未改生产 RTL，未触发新构建或烧录；构建仍由用户执行。

''' + text[end:]
text = text.replace('最新未上板布局未收敛（proc setup −0.572 / recovery −0.716，vout −0.494，DDR −0.065）',
                    '17:55 STA 全部通过（proc +0.013），板上约 40 job/s、每帧欠载')
heading = f'### {stamp}：黑屏只读串口——STA 已过，完整任务约 16.73 ms、显示每帧欠载'
entry = f'''{heading}

用户报告“显示器黑屏卡死”，要求读串口。只读 COM3 30 秒，330 行/30 快照；FPGA 保持开机，没有复位/重配。
原始 `tools/uart_black_stuck_20261104.log`，解码 `tools/black_stuck_decode_20261104.txt`；
`tools/analyze_black_stuck_20261104.py` 统计所有快照，证据与报告归档 `archive/board_stuck_20261104_1755/`。

**状态变化**：本地 17:55:59 报告 All Constraints Met，proc setup +0.013/recovery +0.667、DDR +0.100、vout +0.966，全部端点通过。
板上输入 59~60/窗口，0 capture/write abort，0 alloc_drop；job 40~41/窗口，K1=16740~16748，源 fid +59~61、源帧龄 1~3。
与上一版 K1=0/30 job/s 不同，当前能记录完整 job，源帧没有停止更新。
G2 在 29 个连续窗口均 +60，G1=0；V0/V3 约 2720，V1=1722~1794，全部快照 frame_black=1。
V2 26 次锁存中途 stripe {result['latched_midframe_starvation_stripe']['min']}~{result['latched_midframe_starvation_stripe']['max']}，4 次锁存 first-line miss；不能把这当作逐事件位置直方图。
writer 读占用 watchdog sticky 始终 0；输出 RGB 和每个快照都变化。

**预算**：K1 为每窗口最长完成任务的 171-proc-cycle 计数，不能直接当精确 µs。按报告 5.842 ns 周期换算 16.723~16.731 ms；
显示按 6.727 ns、2200×1125 换算 16.649 ms。最长任务比一个显示周期多约 74~82 µs，
结合 20000 拍（约117 µs）late-start 窗口，与“两个任务后错过下一边界、约40/s”的模式相符；尚需逐 job 的 start/done 波形确认这一具体节奏。
即便总时间只差数十微秒，中间条带的最晚到达时间也必须逐条满足，不能只增大启动窗口就宣称 60 fps 成立。

**结论与限制**：内部在运行，当前有明确的实时供给欠载；还不能仅凭这些快照证明唯一瓶颈为 DDR 带宽，或排除显示器端 HDMI 链路问题。
本轮不改生产 RTL。解码器原本在 acq_got>=40 时武断归因 pend/start，已改为提示核对 runtime/display deadlines，6 项单测 PASS。

'''
if re.search(r'^### 2026-11-04 .*：黑屏只读串口', text, re.M):
    text = re.sub(r'^### 2026-11-04 .*：黑屏只读串口[\s\S]*\Z', entry, text, flags=re.M)
else:
    text = text.rstrip() + '\n\n' + entry
doc.write_text(text, encoding='utf-8')
print('Log line:', text[:text.index(heading)].count('\n') + 1)
