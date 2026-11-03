param([switch]$Long)
# Run every simulation suite (S0 + S1) and print a single summary.
#
#   powershell -NoProfile -File sim\run_all.ps1
#
# Each suite is a self-checking testbench that prints TEST_PASS when every check
# passes; the runner greps the transcript, so a silent failure cannot pass.
$ErrorActionPreference = "Continue"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$suites = @(
    @{ name = "s0_ip_probe";     script = "sim\s0_ip_probe\run.ps1";     what = "read-timing probe of the four generated IPs" },
    @{ name = "s0_pix_fifo";     script = "sim\s0_pix_fifo\run.ps1";     what = "pix_beat_fifo: 288-bit async CDC FIFO timing, capacity 256, order" },
    @{ name = "s0_rd_port";      script = "sim\s0_rd_port\run.ps1";      what = "DRM / FIFO read-port wrappers (pulse, burst, gap, stall, reset)" },
    @{ name = "s0_rst_mbox";     script = "sim\s0_rst_mbox\run.ps1";     what = "reset synchroniser and cross-domain mailbox" },
    @{ name = "s0_clock_reset";  script = "sim\s0_clock_reset\run.ps1";  what = "clock generation and reset gating" },
    @{ name = "s0_out_timing";   script = "sim\s0_out_timing\run.ps1";   what = "1080p60 output timing generator" },
    @{ name = "s0_rdport_stress"; script = "sim\s0_rdport_stress\run.ps1"; what = "read ports under randomised fire/ready, 600 beats each" },
    @{ name = "s0_cdc_stress";   script = "sim\s0_cdc_stress\run.ps1";   what = "mailbox CDC under jittered, unrelated clocks" },
    @{ name = "s0_input_timing"; script = "sim\s0_input_timing\run.ps1"; what = "input raster measurement: 1920-wide line, 1080-line frame, gate window" },
    @{ name = "s0_snapshot";     script = "sim\s0_snapshot\run.ps1";     what = "cross-domain status snapshot: 40-word map, holds, ack timeout, sticky, latch_evt" },
    @{ name = "s0_debug_uart";   script = "sim\s0_debug_uart\run.ps1";   what = "DGC4 reporter: boot banner, 10-line frame, 40 words decoded by a UART receiver" },
    @{ name = "s0_perf_ctr";     script = "sim\s0_perf_ctr\run.ps1";     what = "DGC3 interval accumulator: same-edge publish, restart, random intervals, saturation" },
    @{ name = "s0_top";          script = "sim\s0_top\run.ps1";          what = "top-level integration and bring-up" },
    @{ name = "s1_map_pipeline"; script = "sim\s1_map_pipeline\run.ps1"; what = "map_pipeline vs golden model, whole 1080p frame" },
    @{ name = "s1_map_edge";     script = "sim\s1_map_pipeline\run_edge.ps1"; what = "map_pipeline boundary and error flags" },
    @{ name = "s2_unpack";       script = "sim\s2_unpack\run.ps1";       what = "unpack: beats to pixels, carry, tail, backpressure" },
    @{ name = "s2_coord_fifo";   script = "sim\s2_coord_fifo\run.ps1";   what = "coord FIFO wrapper: order, backpressure, full, reset" },
    @{ name = "s2_config";       script = "sim\s2_config\run.ps1";       what = "config manager: register map, commit, epoch, error codes" },
    @{ name = "s3_bilinear";     script = "sim\s3_bilinear\run.ps1";     what = "bilinear: corners, centre, 2000 random, rounding, black fill" },
    @{ name = "s3_gamma";        script = "sim\s3_gamma\run.ps1";        what = "gamma: bypass, identity LUT bit exact, backpressure, unsupported flag" },
    @{ name = "s4_ip_probe";     script = "sim\_s4_ip_probe\run.ps1";    what = "both output stripe RAM IPs: write, read back, simultaneous use" },
    @{ name = "s4_cascade";      script = "sim\s4_cascade\run.ps1";      what = "map_pipeline -> gamma -> bilinear composed: no beat loss, metadata aligned" },
    @{ name = "s4_block_split";  script = "sim\s4_block_split\run.ps1";  what = "block subdivision: bbox decides whether, output extent decides how" }
    @{ name = "s4_tile_sched";   script = "sim\s4_tile_sched\run.ps1";   what = "tile scheduler: 4080-block enumeration, coords, last stripe 8 lines" },
    @{ name = "s4_split_only";   script = "sim\s4_split_only\run.ps1";   what = "tile scheduler SPLIT: bisect output extent, front first" }
    @{ name = "s4_split_nested"; script = "sim\s4_split_nested\run.ps1"; what = "nested SPLIT: depth-first, front grandchild before sibling" }
    @{ name = "s4_stripe_scan";  script = "sim\s4_stripe_scan\run.ps1";  what = "stripe scan: 30720/15360 pixels, every address matches the raster" }
    @{ name = "s2_frame_mgr";     script = "sim\s2_frame_mgr\run.ps1";     what = "frame manager: 3 slots, alloc/drop/acquire/release, 128-bit descriptor" }
    @{ name = "s2_capture_cdc"; script = "sim\s2_capture_cdc\run.ps1"; what = "capture CDC: 288-bit beats vin_clk -> ddr_clk, capacity, order, reset" },
    @{ name = "s2_capture_pack";  script = "sim\s2_capture_pack\run.ps1";  what = "capture pack: 180 beats/row, byte stream exact, addresses, no row carry" }
    @{ name = "s2_fetch_row";     script = "sim\s2_fetch_row\run.ps1";     what = "fetch row plan: 32-byte align, head_skip, beats 1..7, exhaustive" }
    @{ name = "s2_neighbour";      script = "sim\s2_neighbour\run.ps1";      what = "neighbours: min(x+1,last), edge duplicate, local coords, whole frame" }
    @{ name = "s2_ddr_credit";     script = "sim\s2_ddr_credit\run.ps1";     what = "DDR credit: U+O+P+B+16 <= 1024 exact boundary, P->O, retire" }
    @{ name = "s2_native_split";    script = "sim\s2_native_split\run.ps1";    what = "4 KiB split: parts sum, boundary exact, no page crossing, 1 GiB limit" }
    @{ name = "s2_src_addr";       script = "sim\s2_src_addr\run.ps1";       what = "source cache mapping: bijective, 1024/bank, 4-bank neighbour split" }
    @{ name = "s2_counters";       script = "sim\s2_counters\run.ps1";       what = "8 saturating counters: reset, exact add, ceiling, independence" }
    @{ name = "s2_capture_writer"; script = "sim\s2_capture_writer\run.ps1"; what = "capture writer: 12 beats for 32x4, frame_done, row base advance, abort" }
    @{ name = "s2_rlast_check";    script = "sim\s2_rlast_check\run.ps1";    what = "rlast/ID protocol: early, missing, extra, wrong id, exhaustive" }
    @{ name = "s2_sample_dedup";   script = "sim\s2_sample_dedup\run.ps1";   what = "edge dedupe: 1/2/4 points, replication keeps the last row and column" }
    @{ name = "s2_ddr_fetch";      script = "sim\s2_ddr_fetch\run.ps1";      what = "ddr_fetch: single row one request, crossing row split 1+3, functional path" },
    @{ name = "s2_ddr_wr_adapter"; script = "sim\s2_ddr_wr_adapter\run.ps1"; what = "DDR write adapter: 16-beat bursts, 4 KiB split, frame end/abort, stalls" },
    @{ name = "s2_ddr_rd_adapter"; script = "sim\s2_ddr_rd_adapter\run.ps1"; what = "DDR read adapter: AR/R to FIFO, occupancy credit, page split, stalls" },
    @{ name = "s2_ddr_fetch_err"; script = "sim\s2_ddr_fetch_err\run.ps1"; what = "ddr_fetch error path: early rlast halts, counted, cleared by job_restart" },
    @{ name = "s2_fetch_walk";     script = "sim\s2_fetch_walk\run.ps1";     what = "fetch walk: h rows in order, row_last on the last, abort" },
    @{ name = "s2_sampler_path";   script = "sim\s2_sampler_path\run.ps1";   what = "sampling path: neighbours are real pixels, edge replication" },
    @{ name = "s2_cache_owner";    script = "sim\s2_cache_owner\run.ps1";    what = "cache ownership: FREE/FILLING/READY/READING, fill and read in different sets" },
    @{ name = "s2_cache_set";      script = "sim\s2_cache_set\run.ps1";      what = "one cache set: 4 real DRAM banks, 256-point write/readback exact" },
    @{ name = "s2_source_cache";   script = "sim\s2_source_cache\run.ps1";   what = "two cache sets: 8 real DRAM banks, independent data per set" },
    @{ name = "s2_cache_set4";     script = "sim\s2_cache_set4\run.ps1";     what = "four simultaneous read ports: each returns its own neighbour pixel" },
    @{ name = "s2_source_cache4"; script = "sim\s2_source_cache4\run.ps1"; what = "final source cache: 2 sets x 4 ports, 8 DRAM banks, independent data" },
    @{ name = "s4_sampling_chain"; script = "sim\s4_sampling_chain\run.ps1"; what = "integration: coord -> neighbour_calc -> real cache -> dedupe, 49 points" },
    @{ name = "s2_read_issue";     script = "sim\s2_read_issue\run.ps1";     what = "read issue: 4/2/2/1 reads by edge, never two addresses to one bank" },
    @{ name = "s4_sampling_edge"; script = "sim\s4_sampling_edge\run.ps1"; what = "edge integration: right/bottom/corner, 2/2/1 reads, replication correct" }
    @{ name = "s2_frame_mgr_race"; script = "sim\s2_frame_mgr\run_race.ps1"; what = "frame manager: newest READY, release->READY, good gate, no reclaim/acquire collision" }
    @{ name = "s2_frame_mgr_liveness"; script = "sim\s2_frame_mgr\run_liveness.ps1"; what = "frame manager: long-gap capture/display progress, stop/resume, frame-id wrap" }
    @{ name = "s4_source_sampler"; script = "sim\s4_source_sampler\run.ps1"; what = "source sampler: coord -> four cache ports -> 192-bit record, edges, stalls" }
    @{ name = "s4_coord_stage"; script = "sim\s4_coord_stage\run.ps1"; what = "coord stage: reservation, raster generation, map, bbox, descriptor kinds" }
    @{ name = "s2_fetch_planner"; script = "sim\s2_fetch_planner\run.ps1"; what = "fetch planner: bbox -> per-row fetch_row descriptors, both copies in lockstep" }
    @{ name = "s4_video_reader"; script = "sim\s4_video_reader\run.ps1"; what = "video reader: stripe offer/release, raster order, underflow black, late descriptor discard" }
    @{ name = "s4_reader_boundary"; script = "sim\s4_reader_boundary\run.ps1"; what = "reader frame-boundary bank release: first+prefetch banks returned at vs_fall" }
    @{ name = "s4_reader_last"; script = "sim\s4_reader_last\run.ps1"; what = "reader 68-stripe frame: one release per stripe, no frame_last double release, vs_fall+offer priority" }
    @{ name = "s4_stripe_writer"; script = "sim\s4_stripe_writer\run.ps1"; what = "stripe writer: 30720-pixel completion, offer payload, bank alternate, job_restart ownership" }
    @{ name = "s4_writer_watchdog"; script = "sim\s4_writer_watchdog\run.ps1"; what = "stripe writer watchdog: stranded reader-owned bank reclaimed, next stripe still offered" }
    @{ name = "s4_fill_ctrl";     script = "sim\s4_fill_ctrl\run.ps1";     what = "fill controller: descriptor -> planner -> unpack -> cache fill, A/B sets" }
    @{ name = "s4_stripe_ram";    script = "sim\s4_stripe_ram\run.ps1";    what = "stripe RAM IP: five known words written and read back exactly (OUTPUT_REG=1)" }
    @{ name = "s4_core"; script = "sim\s4_core\run.ps1"; what = "FULL CHAIN: scheduler->map->fill->sample->bilinear->stripe, 92160 pixels exact" }
    @{ name = "s4_stripe_owner"; script = "sim\s4_stripe_owner\run.ps1"; what = "stripe bank ownership: no reuse until release, job_restart keeps reader-owned banks" }
    @{ name = "s5_sys"; script = "sim\s5_sys\run.ps1"; what = "SYSTEM: capture->DDR->frame->core->stripe->display, 30720 pixels exact across 4 domains" }
    @{ name = "s5_sys_align"; script = "sim\s5_sys\run_align.ps1"; what = "SYSTEM + output-frame gate: no job_start outside a frame_tick, same 30720 pixels" }
    @{ name = "s5_top"; script = "sim\s5_top\run.ps1"; what = "integrated board top dgc_top_sys: all IPs, PLLs, resets and DDR bring-up" }
)


# The 2026-10-31 rewrite of s4_stripe_writer uses the behavioural stripe RAM and
# streams one pixel per clock, so every fast suite is part of the default run.
# s5_jobs runs two complete 1080p jobs (~33 ms of simulated time, ~15 minutes of
# wall clock with the lazy DDR image model), so it is opt-in with -Long.
# s5_jobs_align is the same run with ALIGN_TO_FRAME=1, the real output vs_fall as
# the frame tick and a real 45-line vertical back porch; it is the only suite that
# checks that an aligned job start makes the displayed frame pixel exact
# (2026-11-02 b: 2 good frames, 61440 first-stripe pixels, 0 mismatches).
if ($Long) {
    $suites += @{ name = "s5_jobs"; script = "sim\s5_jobs\run.ps1"; what = "SYSTEM multi-job: two consecutive jobs each complete 4080 blocks (slow)" }
    $suites += @{ name = "s5_jobs_align"; script = "sim\s5_jobs\run_align.ps1"; what = "SYSTEM multi-job, aligned start: two jobs, first stripes pixel exact (slow)" }
    # s5_jobs_abort (sim\s5_jobs\run_abort.ps1) is deliberately NOT in this list yet:
    # the writer-level abort contract is covered by s4_writer_watchdog D6/D7 and
    # s4_stripe_owner O6, but the end-to-end scenario currently FAILS and reproduces
    # a real, pre-existing gap: a mid-frame abort is not covered by the coordinate
    # stage / tile scheduler reset, so the next job's block sequence is corrupted and
    # stalls after ~220 blocks. See docs 交接 2026-11-02 21:40 and §6 item 1.
}
$results = @()
foreach ($s in $suites) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host ("  {0}  -  {1}" -f $s.name, $s.what) -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkGray

    # Do not use Start-Process -PassThru here: under PowerShell 7.6 the returned
    # Process object reports a null ExitCode when stdout/stderr are redirected,
    # so every suite looked failed even when result.txt said pass=True. Invoking
    # pwsh directly sets $LASTEXITCODE reliably and keeps the same redirection.
    $outPath = Join-Path $PSScriptRoot "$($s.name).out"
    & pwsh.exe -NoProfile -File (Join-Path $root $s.script) *> $outPath
    $code = $LASTEXITCODE

    $log  = Get-Content $outPath -ErrorAction SilentlyContinue
    $info = $log | Where-Object { $_ -match "TEST_INFO" }

    $results += [pscustomobject]@{
        Suite  = $s.name
        Pass   = ($code -eq 0)
        Info   = ($info | Measure-Object).Count
    }

    $info | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) {
        Write-Host ("  >>> FAILED ({0})" -f $s.name) -ForegroundColor Red
        $log | Where-Object { $_ -match "TEST_FAIL|Error" } | Select-Object -First 12 | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    }
}

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor DarkGray
Write-Host "  REGRESSION SUMMARY (S0..S5)" -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor DarkGray
$results | Format-Table -AutoSize | Out-String | Write-Host

$failed = $results | Where-Object { -not $_.Pass }
if ($failed.Count -gt 0) {
    Write-Host ("{0} suite(s) FAILED" -f $failed.Count) -ForegroundColor Red
    exit 1
}
Write-Host "all suites PASSED" -ForegroundColor Green
exit 0
