# SWEEP_GATE_RESULT_20261101 — 三支布局扫描 PnR 门禁结果（最终版）

- 生成时间: 2026-11-01 15:59 (Asia/Shanghai)；16:07 更新（补 §7 串行锚点 + §7.1 重跑脚本说明）；16:12 收尾（补 ★ Lead 最终裁定：不再重跑）
- 工具: Gowin V1.9.11.03 Education x64 (`E:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe`)
- 器件: GW5AT-LV60PG484AC1/I0 (GW5AT-60, Device Version B)
- 门禁脚本: `F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_pnr\parse_pnr_gates.py`（只读输入，输出写 `<树>\impl\pnr\gates_summary.json`）
- RTL: 三支均为修复版 RTL（`top_touch_ddr.v` SHA256 前缀 099e734c，229401 字节；本报告采信 Lead 侦察值，未重算）
- 数据来源: 各树 `impl\pnr\gates_summary.json`（脚本实测）、`impl\pnr\d2_screen_pnr.rpt.txt`、`impl\pnr\d2_screen_pnr.log`、`build_screen_pnr_sweep_*.log(.raw)`、gw_sh 进程 CPU 采样、Windows 事件日志
- 判定口径: 数字均为**实测**；推测处显式标注「推测」

## ★ Lead 最终裁定（2026-11-01 16:12）

**决定：不再重跑 route1 / p4c1 布局扫描；串行重跑计划取消（`run_sweep_rerun_serial.ps1` 保留归档，不执行）。**

三支扫描结论（均为实测，细节见 §1–§3）:

| 树 | 配方 p/r/cro | 结论 | 关键实测 |
|---|---|---|---|
| p3c0 | 3/2/0 | **FAIL** | PR0004「0 unrouted 仍中止」，exit 1；无 timing analysis、无 bitstream |
| route1 | 1/2/1 | **ABORTED by OOM**（15:52:08 被 OS 杀） | 无 rpt.txt / timing_paths / .fs，无任何门禁数据 |
| p4c1 | 4/2/1 | **ABORTED by OOM**（15:52:08 被 OS 杀） | 无 rpt.txt / timing_paths / .fs，无任何门禁数据 |

裁定理由（Lead 决策，2026-11-01 16:12）:
1. 修复版 RTL 的所有已测布局（主树 48.848 MHz、p0c1 49.335 MHz）**都不过 50 MHz 门禁**；且 timing-analyst 实测 **hold 违例是系统性的**（58 条 (from,to) 在多个修复版树里都违例），多铺布局种子的期望收益很低。
2. 跟弹灯属于竞赛**拓展项**（视听反馈 / 脱机曲目指引），不是基础评分项；**v10 位流（50.029 MHz，9/9 门禁 PASS）已满足基础与核心评分要求，且已烧 Flash**。
3. 比赛 2026 年 11 月初结束（今天 11-01），时间应投入演示准备、技术报告与自举验证，不再投入 PnR。

若赛后继续（优先级）:
1. **优先 p4c1**（place_option 4，唯一没跑成的更强布局选项，需串行单跑）；
2. 其次 **place_option 2 / 5 新种子**；
3. **route1 价值最低**（与主树 `build_screen_pnr_v10_full.tcl` 同配方、`.gprj` 逐行相同，主树 815.3 s 已跑完并给出 48.848 MHz，重复它几乎没有信息增量）。

约束继承：本报告只写这一个 md；`run_sweep_rerun_serial.ps1` 保留归档、**不执行**；未改动 `src/`、`*.vg`、`*.tcl`。

## 0. 结论速览

| 树 | 配方 place/route/cro | 状态 | 判定 |
|---|---|---|---|
| d2_screen_sweep_p3c0 | 3 / 2 / 0 | 已结束（15:13:58，exit 1），PR0004 中止，无 bitstream | **FAIL** |
| d2_screen_sweep_route1 | 1 / 2 / 1 | **ABORTED by OOM（15:52:08 被 OS 杀，无产物，需重跑）** | **无结果** |
| d2_screen_sweep_p4c1 | 4 / 2 / 1 | **ABORTED by OOM（15:52:08 被 OS 杀，无产物，需重跑）** | **无结果** |

一句总结: 本批 3 支里只有 p3c0 走到 PnR 结束但被 PR0004 中止（FAIL）；route1/p4c1 被 Windows 虚拟内存耗尽事件连带杀掉，**没有任何时序/bitstream 产物**。p0c1（49.335 MHz / setup 39 / hold 69）仍是本批唯一有完整门禁数字的对照。

---

## 1. d2_screen_sweep_p3c0 — FAIL (PR0004 abort, no bitstream)

树: `F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_sweep_p3c0`
配方（实测读 `build_screen_pnr_v10_seed.tcl`）: `-place_option 3`、`-route_option 2`、`-clock_route_order 0`、`-route_maxfan 100`、`-bit_compress 1`、`-vccx 1.8`
tcl 流程: `run syn` → `run pnr` → `exit`（10 行/11 行）

| 项 | 值 | 来源 |
|---|---|---|
| 启动 | 2026-11-01 14:15:18 | wrapper `.log` 的 `start` |
| PnR 报告生成时间 | 2026-11-01 15:13:58 | rpt.txt `<Created Time>` |
| 墙钟耗时 | 3524.5 s = 58m44.5s | wrapper `.log` 的 `elapsed_s` |
| exit code | **1** | wrapper `.log` 的 `exit_code` |
| Placement P0/P1/P2/P3 | 22s / 14m40s / 1m53s / 3m10s（合计 20m5s） | rpt.txt §2 |
| Routing P0/P1/P2/P3 | 0.015s / **36m11s** / 0s / 0s | rpt.txt §2 |
| 总 PnR CPU=墙钟 | 56m16s，峰值内存 1344MB | rpt.txt §2 |
| clk Fmax | **未生成** | — |
| Setup violated endpoints | **未生成** | — |
| Hold violated endpoints | **未生成** | — |
| Recovery min slack | **未生成** | — |
| Removal min slack | **未生成** | — |
| unrouted nets | 日志报 `ERROR (PR0004) : There are total 0 unrouted nets`（计数 0 仍按 ERROR 中止） | rpt.txt / log.raw |
| CLS | 25442 / 29952 (85%) | rpt.txt §3 |
| Logic / Register | 46887/59904 (79%) / 14258/60780 (24%) | rpt.txt §3 |
| BSRAM / DSP / I-O Port | 89/118 (76%) / 61/118 (52%) / 65/297 (22%) | rpt.txt §3 |
| .fs bitstream | **未生成** | 目录实测 |
| usercode / checksum | **未生成** | — |
| `.timing_paths` / `_tr_content.html` / `power.html` | **均未生成** | 目录实测 |

已生成产物: `impl\pnr\d2_screen_pnr.rpt.txt`、`.rpt.html`、`.pin.html`、`.p`、`.db`、`d2_screen_pnr.log`。

失败原因（实测日志末尾，15:13:58）:
```
[90%] Routing Phase 3 completed
ERROR  (PR0004) : There are total 0 unrouted nets
...
    while executing
"run pnr"
    (file "...\build_screen_pnr_v10_seed.tcl" line 10)
```
即 `run pnr` 在路由完成后因 PR0004 抛错中止，未进入 timing analysis / bitstream generation；tcl 第 11 行 `exit` 未执行 → 进程 exit code 1。Lead 记录该签名与 10-31 v1 attempt1/2 相同（Gowin「0 unrouted 仍中止」已知怪癖）。

门禁 JSON（脚本实测）: `F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_sweep_p3c0\impl\pnr\gates_summary.json`
- `clk_fmax_ge_50MHz` = FAIL（无数据）
- `global_setup_violated_endpoints_zero` = PASS — **空数据假 PASS**（无 timing 表 → endpoint 计数 0）
- `global_hold_violated_endpoints_zero` = PASS — **同上，空数据假 PASS**
- `recovery_all_slacks_ge_0` = FAIL、`removal_all_slacks_ge_0` = FAIL（无数据）
- `no_unrouted` = FAIL（PR0004 出现，且 pnr/timing/bitstream 三项 completed 均为 false）
- `cls_within_29952` = PASS(25442)、`constraints_retained` = PASS
- `build_exit_zero` = FAIL(exit=1)
- `ALL_GATES_PASS=False`

**结论: FAIL — PR0004 中止，无时序分析、无 bitstream；本支没有 Fmax/setup/hold/recovery/removal 可用数据。**

---

## 2. d2_screen_sweep_route1 — ABORTED by OOM（无产物，需重跑）

树: `F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_sweep_route1`
配方: `-place_option 1`、`-route_option 2`、`-clock_route_order 1`、`-route_maxfan 100`、`-bit_compress 1`、`-vccx 1.8`
pid 22600，启动 14:26:17；15:52:08 随 OOM 事件被杀（非正常退出，无 exit code 记录）。

| 项 | 值 | 来源 |
|---|---|---|
| 运行时长 | 14:26:17 → 15:52:08 = **85m51s**（含 syn 约 2 min + placement 约 3 min + routing ≥80 min） | 启动时间 + 事件日志时间 |
| 进程结束方式 | **被 OS 杀死（OOM 连带）**，wrapper `run_build.ps1` 未执行完 → **无 `build_screen_pnr_sweep_*.log`（非 raw）→ 无 exit_code/elapsed_s** | 目录实测 |
| 被杀时提交内存 | 2,164,318,208 B ≈ 2.02 GiB | 事件 2004 报文 |
| 结束前 CPU 时间 | 4,875 s（15:49:29 采样，连续 +297s/300s ≈ 0.99 核，**无 stall 迹象**） | Get-Process 采样 |
| clk Fmax / Setup / Hold / Recovery / Removal | **未生成** | — |
| unrouted | **无结论**（未进入报告阶段） | — |
| CLS | **未生成** | — |
| .fs / usercode / checksum | **未生成** | — |
| 已有产物 | 仅 `impl\pnr\device.cfg`、`cmd.do`、`d2_screen_pnr.db`(1,233,860B, 14:31:05)、`d2_screen_pnr.p`(5,149,630B, 14:31:05)、`d2_screen_pnr.log`(635B, 14:32:05)；`impl\gwsynthesis\d2_screen_pnr.vg`(16,755,691B, 14:28:16) 综合已完成 | 目录实测 |
| 缺失产物 | `d2_screen_pnr.rpt.txt`、`.rpt.html`、`.pin.html`、`.timing_paths`、`_tr_content.html`、`.fs`、`.bin` | 目录实测 |

`impl\pnr\d2_screen_pnr.log` 全文止于（635 B，14:32:05）:
```
Running placement......
[10%] Placement Phase 0 completed
[20%] Placement Phase 1 completed
[30%] Placement Phase 2 completed
[50%] Placement Phase 3 completed
Running routing......
[60%] Routing Phase 0 completed
```
即 placement 已在 14:31 完成，routing 从 14:32 起持续约 80 分钟未打印 Phase 1 完成行，随后进程被杀。

**结论: ABORTED — 无门禁数据，需串行重跑。**

> 备注（实测 + 推测）: 本支配方（place1/route2/cro1）与主树 `d2_screen_pnr` 13:03:25 那次全流程（`build_screen_pnr_v10_full.tcl`，同配方）**完全一致**，且两树 `d2_screen_pnr.gprj` 逐行相同（均 2386 B / 39 行，`Compare-Object` 无差异），而主树那次 `elapsed_s=815.3`（13m35s，exit 0）就完成了。→ 同配方在主树 13.6 分钟跑完、在本支 85+ 分钟未跑完，**推测**是 14:26 起 3~4 个 gw_sh 并发 + 16 GB 机器内存/页面文件争用导致的严重拖慢（该推测未做受控实验验证）。

---

## 3. d2_screen_sweep_p4c1 — ABORTED by OOM（无产物，需重跑）

树: `F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_sweep_p4c1`
配方: `-place_option 4`、`-route_option 2`、`-clock_route_order 1`、`-route_maxfan 100`、`-bit_compress 1`、`-vccx 1.8`
pid 22252，启动 14:26:17；15:52:08 随 OOM 事件被杀。

| 项 | 值 | 来源 |
|---|---|---|
| 运行时长 | 14:26:17 → 15:52:08 = **85m51s**（routing ≥62 min） | 启动时间 + 事件日志时间 |
| 进程结束方式 | **被 OS 杀死（OOM 连带）**，无 wrapper `.log` → **无 exit_code/elapsed_s** | 目录实测 |
| 被杀时提交内存 | 1,524,039,680 B ≈ 1.42 GiB | 事件 2004 报文 |
| 结束前 CPU 时间 | 4,878 s（15:49:29 采样，连续 +297s/300s ≈ 0.99 核，**无 stall 迹象**） | Get-Process 采样 |
| clk Fmax / Setup / Hold / Recovery / Removal / CLS / unrouted | **全部未生成** | — |
| .fs / usercode / checksum | **未生成** | — |
| 已有产物 | `device.cfg`、`cmd.do`、`.db`(1,233,860B, 14:48:48)、`.p`(5,148,720B, 14:48:49)、`d2_screen_pnr.log`(629B, 14:49:32)；`impl\gwsynthesis\d2_screen_pnr.vg`(16,755,635B, 14:28:17) 综合已完成 | 目录实测 |
| 缺失产物 | `.rpt.txt`、`.rpt.html`、`.pin.html`、`.timing_paths`、`_tr_content.html`、`.fs`、`.bin` | 目录实测 |

`impl\pnr\d2_screen_pnr.log` 全文止于（629 B，14:49:32）同样的 `[60%] Routing Phase 0 completed`。

**结论: ABORTED — 无门禁数据，需串行重跑。**

---

## 4. 对照表（p3c0 / route1 / p4c1 / p0c1 / 主树 / v10 参考）

数值优先取自各自 `impl\pnr\gates_summary.json`（脚本实测）。

| 树 | 配方 p/r/cro | 状态 | clk Fmax (MHz) | Setup viol EP | Hold viol EP | Recovery min (ns) | Removal min (ns) | unrouted | CLS | exit | .fs / usercode | 判定 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **p3c0** | 3/2/0 | PnR 中止 | 未生成 | 未生成 | 未生成 | 未生成 | 未生成 | PR0004 报 0 但中止 | 25442/29952 | 1 | 无 | **FAIL** |
| **route1** | 1/2/1 | OOM 被杀 | 未生成 | 未生成 | 未生成 | 未生成 | 未生成 | 未进入报告 | 未生成 | 未记录(被杀) | 无 | **ABORTED** |
| **p4c1** | 4/2/1 | OOM 被杀 | 未生成 | 未生成 | 未生成 | 未生成 | 未生成 | 未进入报告 | 未生成 | 未记录(被杀) | 无 | **ABORTED** |
| p0c1（对照，已完成） | 0/2/1 | 完成 | **49.335** | **39**（clk Setup，TNS -5.377） | **69**（clk_x1 Hold，TNS -9.534） | **+0.137** | **+0.532** | 0 | 25678/29952 | 0 | 有，**0x000031E3** | FAIL（fmax/setup/hold 未达门限） |
| 主树 d2_screen_pnr（对照，已完成） | 1/2/1 | 完成 | **48.848** | **35**（clk 33 + clk_x1 2） | **120**（clk_x1） | **-0.889**（4 条违例） | **+0.601** | 0 | 25711/29952 | 0 | 有，0x000013BE | FAIL |
| v10 历史参考 | — | 完成 | 50.029 | — | — | — | — | — | — | 0 | — | 参考值（非本次实测） |

补充（实测）:
- p0c1 的 worst-path slack: Setup -0.269 ns（2000 条中违例 288）、Hold -0.439 ns（违例 69）。
- p0c1 其他时钟: `clk_x1` Fmax 114.95 MHz（约束 100）、`mem_clk` 2016.128 MHz（约束 400）。
- 主树其他时钟: `clk_x1` Fmax 99.812 MHz（约束 100，Setup 违例 2 endpoints）。
- 门限定义（脚本内）: clk Fmax ≥ 50.0 MHz、全局 setup/hold violated endpoints = 0、recovery/removal 全部 slack ≥ 0、unrouted = 0 且 pnr+timing+bitstream 全完成、CLS ≤ 29952、约束保留、exit = 0。

---

## 5. OOM 事件（实测证据）

- 事件源: `Microsoft-Windows-Resource-Exhaustion-Detector`，**Event ID 2004**，时间 **2026-11-01 15:52:08**（System 日志）
- 原文（节选）: 「Windows 成功诊断出虚拟内存不足的情况。以下程序使用了大部分虚拟内存: gw_sh.exe (22940) 使用了 17238274048 字节；gw_sh.exe (22600) 使用了 2164318208 字节；gw_sh.exe (22252) 使用了 1524039680 字节。」
- 本机内存（实测）: TotalPhysicalMemory = 15.84 GiB（MS-Challenger H610M）；页面文件 16,384 MB 已分配，`PeakUsage = 16,383 MB`（**峰值打满**）；commit limit 31.84 GiB（事件后 15:57 采样已回落到 used 12.68 GiB）
- 归因（实测 + 标注）:
  - 最大占用者 **pid 22940 使用 17.24 GB**（≈16.05 GiB）。该 pid 不是本任务三支之一；Lead 15:56:15 的重启脚本自述文字「restart alone after OOM (gw_sh 22940 killed at ~15:52, virtual mem 16GB)」证实它是 **Standard V1.9.12.04 增量 PnR** 的 gw_sh 实例。—— 事实
  - 本任务两支（route1 2.02 GiB + p4c1 1.42 GiB = 3.69 GiB）是**叠加项**，与 17.24 GB 的 Standard 流程并发后把 31.84 GiB 的 commit limit 顶穿。—— 事实（加总）
  - 因此「OOM 由 Standard 增量 PnR 主导、两支 sweep 为连带受害者」是**由上述实测数字推出的判断**；三支 sweep 单独串行运行所需内存实测仅 1.3~2.2 GB/支（p3c0 峰值 1344 MB），串行不构成内存风险。
- **结论（与 Lead 一致）: 本机 16 GB 内存 + 3~4 个 PnR 并发 = 不可行；后续必须串行（一次只跑一支，且不与 17 GB 级 Standard 流程同时跑）。**

---

## 6. 未验证清单

- route1 / p4c1 的 Fmax、setup/hold 违例、recovery/removal min、CLS、unrouted、exit code、.fs/usercode —— **全部未验证（进程被杀，无产物）**。
- route1 / p4c1 的真实 exit code —— **未记录**（`run_build.ps1` 未执行完，`.log`/`exit_code`/`elapsed_s` 未落盘）；「被 OS 杀死」是由 15:52:08 事件 + 进程消失 + 无产物推断。
- p3c0 的 Fmax/时序类数值 —— **未生成**（不是「未测」，而是流程中止在 timing analysis 之前）。
- p3c0 的 usercode/checksum —— 无 .fs，**未生成**。
- 三支的板级/Flash 结果 —— 按约束**未执行、未验证**。
- 三支 RTL 一致性仅采信 Lead 提供的 `top_touch_ddr.v` SHA256 前缀 099e734c / 229401 字节，本次**未重算**三支的 RTL 哈希。
- 同配方下主树 13.6 分钟 vs route1 85+ 分钟未完成的差异，**只用「并发争用」解释，未做受控实验**（推测）。
- route1 / p4c1 采用 place_option 1 / 4 时的真实单支耗时 —— **无实测锚点**（本次都在并发下被杀）。

---

## 7. 附录 A — 重跑计划【**已取消**：Lead 2026-11-01 16:12 裁定不再重跑，见 ★ 节；以下内容仅作赛后参考归档】

前置条件（每次重跑前都要确认）:
1. `Get-CimInstance Win32_Process -Filter "Name='gw_sh.exe'"` 无 Standard/其他 gw_sh 在跑（尤其 17 GB 级增量 PnR）。
2. 一次只跑一支，跑完再跑下一支（串行，避免再次 OOM）。

命令模板（把 `<TAG>` 换成 route1 或 p4c1）:
```powershell
$d = 'F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_sweep_<TAG>'
# 可选清理：移除陈旧半成品（只删 impl\pnr 内 .db/.p，保留 src 与综合网表）
Remove-Item "$d\impl\pnr\d2_screen_pnr.db","$d\impl\pnr\d2_screen_pnr.p" -Force -ErrorAction SilentlyContinue
cd $d
powershell -NoProfile -ExecutionPolicy Bypass -File .\run_build.ps1 -Tcl .\build_screen_pnr_v10_seed.tcl -Log "$d\build_screen_pnr_sweep_<TAG>_$(Get-Date -Format yyyyMMdd_HHmmss).log"
# 结束后跑门禁：
D:\Python\python.exe -X utf8 F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_pnr\parse_pnr_gates.py --root $d --proj d2_screen_pnr
```
- 网表已存在（route1: `impl\gwsynthesis\d2_screen_pnr.vg` 16,755,691B；p4c1: 16,755,635B），如只想跑 PnR 可复制一支 `run pnr` only 的 tcl（同选项），省去 ~2 min 综合。
- 预计耗时（**实测锚点**）:
  - 主树同配方 place1/route2/cro1 全流程: **815.3 s ≈ 13m35s**（13:03→13:17，exit 0，无并发）→ route1 串行预期 **≈15 分钟级**（含 syn）。
  - p0c1 place0/route2/cro1: **1300.4 s ≈ 21m40s**。
  - p3c0 place3/route2/cro0: **3524.5 s ≈ 58m44s**（且在 PR0004 处中止）。
  - p4c1 place4 无实测锚点 → 按 place3 的 58m44s 推断，**预计 25~60 分钟**（**推测**）。
  - **串行重跑的主要锚点（Lead 指示补充）**: route1 配方（place_option 1 / route_option 2 / clock_route_order 1）与主树 `d2_screen_pnr` 13:03:25 那次 `build_screen_pnr_v10_full.tcl` **完全同配方**，且两树 `d2_screen_pnr.gprj` 逐行相同（均 2386 B / 39 行）；主树那次 `elapsed_s=815.3`（13m35s，**exit 0、有 `.fs`**）→ **单独串行跑 route1 预计 14~20 分钟就能出位流**。route1 本次 85m51s 未跑完属并发争用下的异常，不代表该配方的正常耗时。
- 风险: route1 本次同配方在并发下走了 85+ min 仍未到 routing Phase 1 完成，串行是否恢复到 ~15 分钟级**未验证**；若串行仍远超预期，需考虑 place_option 1 在该树上的实际行为差异（tree 与主树 gprj 已比对为逐行相同，故只剩「并发/缓存/机器状态」或「RTL 版本细微差异」两类解释，均未验证）。

### 7.1 执行脚本（已写好，**默认 dry-run，尚未执行**）

脚本: `F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_pnr\run_sweep_rerun_serial.ps1`（10474 B，ASCII-only，UTF-8 无 BOM，PowerShell 5.1 语法检查通过）

作用: 按 route1 → p4c1 **严格串行**重跑；每支开跑前检查 `gw_sh.exe` 为空（为空才跑，否则最多等 1800 s 且**从不 kill**）；跑完自动跑 `parse_pnr_gates.py`，并把 exit code、墙钟、Fmax、setup/hold 违例、recovery/removal、CLS、.fs/usercode、9 项门禁 PASS/FAIL 追加成本 md 的 `### RERUN <tag>` 小节。

用法:
```powershell
# 1) 干跑，只打印计划（当前默认行为，不建 bitstream、不写任何文件）
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_pnr\run_sweep_rerun_serial.ps1"
# 2) 真正跑（Lead 说「可以开扫」后才用）
powershell -NoProfile -ExecutionPolicy Bypass -File "...\run_sweep_rerun_serial.ps1" -Execute
# 3) 只补跑 p4c1
powershell -NoProfile -ExecutionPolicy Bypass -File "...\run_sweep_rerun_serial.ps1" -Execute -Tags p4c1
```

安全设计（实测验证过）:
- 预检用 `Get-CimInstance Win32_Process -Filter "Name='gw_sh.exe'"` + `Get-Process -Name gw_sh` **双路交叉验证**；两者不一致时直接抛错拒绝启动（避免把「查询失败」误判为「没有 gw_sh 在跑」，从而并发开扫再次 OOM）。
- 子进程隔离：`Start-Process powershell.exe -File run_build.ps1 ... -Wait`，避免 `run_build.ps1` 末尾的 `exit` 连带结束调度进程。
- 默认删除该树 `impl\pnr\d2_screen_pnr.db` / `.p`（上次被杀的半成品布局），可用 `-KeepStale` 保留；**不碰 `src/`、`*.tcl`、`*.gprj`、`*.vg`**。
- 2026-11-01 16:04 以 dry-run 实测：能正确识别当前在跑的 `gw_sh` pid 19204 并报告「a real run would block here until gw_sh is gone」，未产生任何构建或写入。

## 8. 附录 B — 证据文件清单（只读引用）

| 文件 | 用途 |
|---|---|
| `...\d2_screen_sweep_p3c0\impl\pnr\gates_summary.json` | p3c0 门禁 JSON（脚本生成） |
| `...\d2_screen_sweep_p3c0\impl\pnr\d2_screen_pnr.rpt.txt` | p3c0 资源/时序阶段耗时/PR0004 |
| `...\d2_screen_sweep_p3c0\build_screen_pnr_sweep_p3c0_20261101_141518.log` | p3c0 exit_code=1 / elapsed_s=3524.5 |
| `...\d2_screen_sweep_route1\impl\pnr\d2_screen_pnr.log` | route1 停在 Routing Phase 0（635 B） |
| `...\d2_screen_sweep_p4c1\impl\pnr\d2_screen_pnr.log` | p4c1 停在 Routing Phase 0（629 B） |
| `...\d2_screen_sweep_p0c1\impl\pnr\gates_summary.json` | p0c1 对照门禁 JSON |
| `...\d2_screen_pnr\impl\pnr\gates_summary.json` | 主树对照门禁 JSON |
| System 事件日志 `Microsoft-Windows-Resource-Exhaustion-Detector` ID 2004 @ 15:52:08 | OOM 证据（进程/字节数） |

> 本任务约束遵守情况: 仅写入本 md（`F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_pnr\SWEEP_GATE_RESULT_20261101.md`）与门禁脚本自动生成的 `gates_summary.json`；未修改任何 `src/`、`*.tcl`、`*.gprj`；未启动新的 Gowin 构建；未 kill 任何进程；未写 Flash；未改动 `work\d2_screen_pnr\impl` 与 evidence。
