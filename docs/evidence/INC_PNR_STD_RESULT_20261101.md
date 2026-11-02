# Standard 增量 PnR 实验结果（INC_PNR / Standard V1.9.12.04）

- **日期**：2026-11-01
- **状态**：**ABORTED BY LEAD DECISION**（按竞赛需求优先级取舍：跟弹灯属拓展项，v10 已满足基础/核心评分 → 停止投入）
- **树**：`F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_inc_pnr_std_20261101_1512`
- **Tcl**：`build_inc_std_from_edu_netlist.tcl`（skip syn，直接用 Education 网表 + v10 的 `.p` 做增量）
- **结论一句话**：增量选项**确实被 Standard 接受并生效**（`-inc_pnr` + seed `.p` 解析成功），但两次运行都**没越过 placement 早期阶段**（停在 `[10%] Placement Phase 0 completed`），**零 PnR 产物、零时序数据**；因此 **9 项门禁无法评估**，"hold violated 是否仍非 0" **本次无实测答案**。

---

## 1. 判决摘要

| 项目 | 结果 |
|---|---|
| 运行是否完成 | **否**（两次均中止，见 §2） |
| 是否工具报错失败 | **否**：一次被 Windows 内存耗尽（OOM）连带杀掉，一次被 Lead 主动停止 |
| PnR 产物 | **无**：`.fs` / `.rpt.txt` / `.timing_paths` / `.p` / `.bin` / `.db` **全部不存在**（`impl\pnr` 仅剩 4 个文件：`cmd.do`、`device.cfg`、`d2_screen_pnr.log`、`seed_v10_pass.p`） |
| 门禁（9 项） | **不可评估**：`parse_pnr_gates.py` 的输入（`.rpt.txt` + `.timing_paths`）不存在，脚本未运行 |
| 增量选项是否生效 | **是（已验证）**：`cmd.do` 的 `-inc_pnr`、`process_config.json` 的 `INCREMENTAL_PLACE_AND_ROUTING`、日志 `Reading pr file` + `Parsing ... completed` |
| 增量是否真的"复用"了 v10 布局 | **未验证**（日志无 `incremental`/`reuse` 字样，且未进入 Phase 1，无法区分"复用"与"仅读入"） |
| 能否作为下一版烧录候选 | **不能**（无位流；且按已有证据 hold 大概率仍挂，见 §5） |

---

## 2. 运行时间线（两次运行）

### 2.1 运行 A：pid 22940（OOM 终结）

| 时刻 | 事件 |
|---|---|
| 15:31:50 | gw_sh.exe pid 22940 启动，Standard **V1.9.12.04**，tcl = `build_inc_std_from_edu_netlist.tcl`；`impl\pnr\cmd.do` 生成（含 `-inc_pnr .../seed_v10_pass.p`） |
| 15:32:35 | 网表 `impl\gwsynthesis\d2_screen_pnr.vg` 解析完成 → CST 解析完成 → `Reading pr file: .../seed_v10_pass.p` → `Parsing file ... completed` → `Running placement......` → `[10%] Placement Phase 0 completed`（**最后一次日志更新**） |
| 15:44（Lead 采样） | CPU 885 s，WS 7.6 GB，free 0.6 GB，另有 2 支 Education 扫描 PnR（pids 22600/22252） |
| 15:47:58（本机采样） | CPU **954.6 s**，WS **8256 MB**，free **294 MB** |
| 15:52:08 | **Windows Resource-Exhaustion-Detector**：虚拟内存不足。`gw_sh.exe (22940)` 提交 **17,238,274,048 B ≈ 16.05 GiB**；`gw_sh.exe (22600)` 2,164,318,208 B；`gw_sh.exe (22252)` 1,524,039,680 B → 3 个 gw_sh 全部被系统杀掉 |
| 15:52:19 | CPU **1143.1 s**，WS 5626 MB，free **78 MB**（进程仍在，杀灭发生在之后） |
| 15:52:36 | CPU **1147.8 s**，WS 5467 MB，free 81 MB（最后一次观测到存活） |
| ~15:52:36–15:56:15 | 进程消失 |
| **合计** | 存活 **20 min 18 s**，消耗 CPU **≈1148 s**，**产物 0** |

### 2.2 运行 B：pid 19204（Lead 手动停止）

| 时刻 | 事件 |
|---|---|
| 15:52:08 | OOM 事件后，两支 Education 扫描 PnR 也一并被杀（未重启）→ 本机 free RAM 恢复到 ≈9 GB |
| 15:56:15 | 重启，**pid 19204**，同一 tcl、同一树、**单独运行**；`cmd.do`/`device.cfg` 于 15:56:16 重新生成（`-inc_pnr` 标志保留） |
| 15:56:54 | 网表/CST/seed `.p` 解析全部完成 → `Running placement......` → `[10%] Placement Phase 0 completed`（**最后一次日志更新**） |
| 16:01:33 | CPU **312.8 s**，WS 6694 MB，free 3266 MB（CPU 利用率 ≈98%，说明在算，非卡死） |
| 16:05:41 | CPU **557.1 s**，WS 1467 MB（阶段切换释放内存），free 9620 MB |
| **16:09** | **Lead 决策停止**（kill pid 19204）：12.5 min 内未出现 `Placement Phase 1`，判为病态慢；Standard 单进程虚拟提交 16–17 GB，16 GB 机器无法承受 |
| 16:10:18 | 本机采样确认 `pid19204 GONE`；`gw_sh.exe` 进程数 = **0** |
| **合计** | 运行 **12.5 min**，CPU **737 s**（Lead 记录；本机 16:05:41 实测 557.1 s，与"16:09 止于 737 s"一致），**产物 0** |

> 两次运行共同点：都在 **39 s 内**走完 网表→约束→种子 `.p`→placement 启动，然后**再没有任何日志推进**；CPU 持续满核增长 → 属"慢"而非"死"，但 12.5–20 min 内连 `Phase 1` 都没到，已超出可接受成本。

---

## 3. 已证实的事实（带证据）

### E1 增量选项确实被工具接受（Standard-only）
- `impl\pnr\cmd.do`（15:56:16 重生成）含：`-inc_pnr F:/.../seed_v10_pass.p`，同时 `-place_option 1 -route_option 2 -correct_hold 1 -global_freq 100.000`
- `impl\d2_screen_pnr_process_config.json` **L36**：`"INCREMENTAL_PLACE_AND_ROUTING": "F:/.../impl/pnr/seed_v10_pass.p"`
- 工具能力探测对照：
  - `probe_inc_pnr.log` L3 → **`PROBE_INC_PNR_OK`**（Standard 接受 `set_option -inc_pnr`）
  - `probe_inc_edu.log` L3 → **`unknown option: -inc_pnr`**（Education V1.9.11.03 **不接受**该选项 → 增量 PnR 是 Standard 独有能力）
- 两次运行日志均有 `Reading pr file: .../seed_v10_pass.p` + `Parsing file ... completed`，无相关 PA 报错

### E2 种子 `.p` 有效且与 v10 通过态同源
- `impl\pnr\seed_v10_pass.p`，**5,149,264 B**，SHA256 = `F1872F1F407C629A1508A5705E5AC12A573ECA9AC03FF93ED221D41B0632034E`
- 来源：v10 通过态（50.029 MHz / 9-9 门禁 PASS / UserCode `0x0000B149`）的 PnR 结果

### E3 网表 WRITE_MODE 补丁
- `impl\gwsynthesis\d2_screen_pnr.vg`，**13,046,800 B**，SHA256 前缀 `AFDC02D67D9C866F`
- `WRITE_MODE` 共出现 **10** 处，其中 **`WRITE_MODE = 2'b10` 计数 = 0**（已全部改为原语默认 `2'b00`，与 Education 1.9.11.03 默认一致、与 v10 硬件行为一致）
- 原始 Standard 网表留存：`impl\gwsynthesis\d2_screen_pnr.std1191204.vg`（同尺寸 13,046,800 B）

### E4 同树前置实验中被工具拦截两次（记录错误码）
| 日志 | 错误码 | 内容 |
|---|---|---|
| `build_inc_std_edu_20261101_152148.log.raw` L4-L6 | **PA2085** | 用 **Education 综合的网表** 喂 Standard：`No 'RAM16S4' resource in current device or using a conflict keyword 'RAM16S4' from the primitive library`（`.vg:229110`），`Parsing netlist ... completed with errors` |
| `probe_std_noinc.log` L5-L14 | **PA2122 ×10** | `Not support 'u_fx_reverb/c4_mem_...'(SP) WRITE_MODE = 2'b10, please change write mode WRITE_MODE = 2'b00 or 2'b01` → 即 E3 补丁的动因 |

### E5 增量"复用"未得到证据
日志中**没有** `incremental` / `incremental place` / `reuse` / `reusing placement from` 一类字样；只有 `Reading pr file` / `Parsing file`。运行从未进入 `Placement Phase 1`，因此**无法判断** Standard 是把 v10 布局当作起点复用，还是仅仅"读入后被丢弃、从零开始铺"。→ 记为**未验证**。

---

## 4. 9 项门禁：**不可评估**

`parse_pnr_gates.py` 依赖 `impl\pnr\d2_screen_pnr.rpt.txt`（资源 + PnR 消息）与 `d2_screen_pnr.timing_paths`；本树**两者都不存在**（`impl\pnr` 只有 `cmd.do` / `device.cfg` / `d2_screen_pnr.log` / `seed_v10_pass.p`）。按 Lead「本轮只写这一个 md」的约束，脚本未运行（若运行也只会产出 `rpt_present: false` 的空壳 summary，无门禁意义）。

| # | 门禁项 | 门限 | 本次实测 | 判定 |
|---|---|---|---|---|
| 1 | clk Fmax | ≥ 50 MHz | 无数据 | **未评估** |
| 2 | setup violated endpoints | = 0 | 无数据 | **未评估** |
| 3 | hold violated endpoints | = 0 | 无数据 | **未评估（本次核心问题）** |
| 4 | recovery min slack | ≥ 0（2000 条） | 无数据 | **未评估** |
| 5 | removal min slack | ≥ 0（2000 条） | 无数据 | **未评估** |
| 6 | unrouted | 0 | 无数据 | **未评估** |
| 7 | CLS | ≤ 29,952 | 无数据 | **未评估** |
| 8 | 约束保留 | CST/SDC 生效 | 无数据（仅见 CST 解析完成） | **未评估** |
| 9 | build exit | 0 | **非 0 / 未完成**（OOM 杀灭 & 人工停止） | **FAIL/未完成** |

其他位流身份字段（`usercode`、`bitstream sha256`、`checksum`）：**位流不存在 → 无身份**。

---

## 5. 交叉对照：v10 通过态 / p0c1 / 主树 lastbuild / 本次

| 树或运行 | 工具 | clk Fmax | setup viol | hold viol | recovery min | removal min | unrouted | CLS | exit | UserCode | 结论 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **v10 通过态**（已烧 Flash） | Education V1.9.11.03 | **50.029 MHz** | **0**（min +0.012） | **0**（min +0.003） | **+0.137** | **+0.357** | 0 | 25,553/29,952 | 0 | **0x0000B149** / 0xB149 | **9/9 PASS** |
| **p0c1**（place_option 0） | Education V1.9.11.03 | 49.335 MHz | **39**（TNS −5.377） | **69**（TNS −9.534） | +0.137 | +0.532 | 0 | 25,678/29,952 | 0 | 0x000031E3 | **FAIL** |
| 主树 lastbuild（13:16 Education 重跑） | Education V1.9.11.03 | 48.848 MHz | **35** | **120** | −0.889（4 条违例） | +0.601 | 0 | 25,711/29,952 | 0 | 0x000013BE | **FAIL** |
| **本次 Standard 增量 PnR** | **Standard V1.9.12.04** | — | — | — | — | — | — | — | 未完成 | — | **ABORTED，无数据** |

数据来源：v10 = `evidence\v10_RELEASE_finalmap_20261101_1219\pnr\gates_summary.json`（另有 `v10_burned_GUIDE_BUG_20261101_1241`、`impl\pnr\stale_state_v10b` 三份同值副本）；p0c1 = `impl\pnr\gates_summary_p0r2.json` 及 `SWEEP_GATE_RESULT_20261101.md`；主树 lastbuild = `impl\pnr\gates_summary.json`（13:16:49）。**v10 的三项 `.fs` 哈希互不相同但门禁数字完全一致（同一张时序表的不同封装产物）。**

### 5.1 重点回答：**hold violated 是否仍非 0？**

**本次无实测数据（无位流、无 timing_paths）→ 该问题本次实验未能回答。**

但按已有实测证据，**预期仍非 0，且是系统性违例**：

1. v10 通过态 hold viol = 0（min **+0.003 ns**）——是**擦边通过**，余量仅 3 ps 级，对布局极其敏感。
2. 修复版 RTL 的**每一个**已测完整布局都 hold 非 0：主树 48.848 MHz → **hold 120**；p0c1 49.335 MHz → **hold 69**；且主树 hold 最差路径落在 **`clk_x1`（DDR 域）**：`u_ddr3/gw3_top/u_gwmc_top/gw_wr_data0/wr_buf_din_133_s0/Q → .../wr_fifo/gowin_add_SDPX9B_mem_mem_0_3_s/DI[7]`，relation `0.500 ns`，skew −0.197，data_delay 0.195，min slack **−0.539 ns**。
3. `TIMING_DELTA_ANALYSIS_20261101.md`（timing-analyst）：**58 条 (from,to) 组合在多个修复版布局里都违例** → 不是布局随机性，而是修复版 RTL 付出的真实代价（集中在 `clk_x1`/DDR 域，与 DDR 复位/写数据路径的改动相关）。
4. 推理：即便增量 PnR 把 setup 拉回 50 MHz（p0c1 的 setup 39 条、TNS −5.377 说明"铺得好就能大幅改善 setup"），**hold 的 58 条系统性违例不会因为换布局而消失**（p0c1 与主树在两种不同布局下 hold 违例数分别为 69 与 120，方向一致、均非 0）。→ **增量 PnR 成功的最乐观情形下，hold 门禁仍大概率 FAIL。**

---

## 6. "未验证"清单（明确不做结论的部分）

1. **增量是否真的复用了 v10 布局** —— 日志无任何 incremental/reuse 措辞，且未到 Phase 1；`-inc_pnr` 只证明选项被接受。（**未验证**）
2. 修复版 RTL 在 Standard 1.9.12.04 下的 **fmax / setup / hold / recovery / removal / unrouted / CLS** —— 全部未测。
3. Standard 1.9.12.04 能否产出**可用位流**（`.fs`）—— 两次都没进 Phase 1，连一次完整 PnR 都未发生。
4. Standard 与 Education 对同一 RTL/网表的**时序口径是否等价**（EDIF/原语映射差异是否会引入额外优化差异）—— 无对照组。
5. Standard 单进程**峰值提交内存**到底多少 —— 只观测到运行 A 的 16.05 GiB（且已 OOM）；运行 B 运行 12.5 min 的峰值 WS 6.7 GB，但提交量未单独采样，**峰值未知**。
6. 跟弹灯功能本身的硬件行为 —— 未烧录、未验证（本实验只涉及 PnR 可行性）。

---

## 7. 后续若仍要做，建议路线

1. **首选：放弃 Standard，改在 Education 已通过的 v10 网表/布局上做"2 位手术"** —— 即只在 v10 的 `.p`/网表层面替换跟弹灯相关的最小网表块，而不是换整个工具链。v10 的门禁是 9/9 PASS、且已烧 Flash，任何"换工具"都等于把 9 项门禁全部重新赌一遍。
2. **不要指望增量 PnR 提速**：本次没有任何"复用布局"的证据（连 Phase 1 都没到）；Standard 的 placement 在本设计（49k LUT / 89 BSRAM / 86% CLS 的高占用）上明显病态慢（20 min 才到 Phase 0 结束）。
3. 若坚持 Standard：先在 ≥32 GB 内存机器上**单进程**跑，预留 ≥20 GiB 提交空间；并把 BSRAM 的 `WRITE_MODE` 在 **RTL 级**写成 Standard 原生 `2'b00` 风格（避免 PA2122 补丁 + 避免 Education 网表的 PA2085/`RAM16S4` 冲突两笔技术债）。
4. **优先级判断（采纳 Lead）**：跟弹灯属竞赛**拓展项**（拓展 3 视听反馈 / 拓展 4 脱机曲目指引），非基础评分项；v10（50.029 MHz / 9-9 PASS / 已烧 Flash）已满足基础与核心评分（32 振荡器 × 48.828 kHz 吞吐、ADSR、效果器、延迟、频谱验证）。**本实验的沉没成本到此为止，不烧新位流。**

---

## 8. 证据文件清单

| 路径（相对 inc 树根或绝对） | 大小 | 证明什么 |
|---|---|---|
| `build_inc_std_patched_20261101_153149.log.raw` | 912 B | 运行 A（pid 22940）全部 stdout，止于 `[10%] Placement Phase 0 completed`（mtime 15:32:35） |
| `build_inc_std_retry_20261101_155615.log.raw` | 912 B | 运行 B（pid 19204）全部 stdout，同上（mtime 15:56:54） |
| `impl\pnr\d2_screen_pnr.log` | 755 B | 运行 B 的 PnR 侧日志（被 15:56 重跑覆盖，内容=运行 B） |
| `impl\pnr\cmd.do` | 752 B | `-inc_pnr` 标志 + place/route/hold 选项 |
| `impl\d2_screen_pnr_process_config.json` L36 | 3,355 B | `INCREMENTAL_PLACE_AND_ROUTING` 持久化选项 |
| `impl\pnr\seed_v10_pass.p` | 5,149,264 B | 增量种子（SHA256 `F1872F1F…2034E`），被成功解析 |
| `impl\gwsynthesis\d2_screen_pnr.vg` | 13,046,800 B | WRITE_MODE 补丁后网表（`2'b10` 计数 0） |
| `impl\gwsynthesis\d2_screen_pnr.std1191204.vg` | 13,046,800 B | 原始 Standard 网表留存 |
| `probe_inc_pnr.log` | 352 B | `PROBE_INC_PNR_OK`（Standard 支持 `-inc_pnr`） |
| `probe_inc_edu.log` | 1,498 B | `unknown option: -inc_pnr`（Education 不支持） |
| `probe_std_noinc.log` | 4,754 B | **PA2122 ×10**（WRITE_MODE=2'b10 被拒） |
| `build_inc_std_edu_20261101_152148.log.raw` | 924 B | **PA2085**（Education 网表 `RAM16S4` 与 Standard 冲突） |
| Windows 系统事件日志 `System` @ 15:52:08 | — | `Microsoft-Windows-Resource-Exhaustion-Detector`：22940 提交 17,238,274,048 B（16.05 GiB）→ OOM |
| `..\d2_screen_pnr\impl\pnr\gates_summary.json`（13:16 主树 lastbuild） | 9,152 B | 修复版 RTL 在 Education 下的对照（48.848 MHz / setup 35 / hold 120 / recovery −0.889） |
| `..\d2_screen_pnr\evidence\v10_RELEASE_finalmap_20261101_1219\pnr\gates_summary.json` | — | v10 通过态基准（50.029 MHz / 9-9 PASS / 0x0000B149） |
| `..\d2_screen_pnr\impl\pnr\gates_summary_p0r2.json` | 9,119 B | p0c1 对照（49.335 MHz / setup 39 / hold 69） |

**本树 `impl\pnr` 最终内容（4 个文件，无任何 PnR 产物）**：`cmd.do` / `device.cfg` / `d2_screen_pnr.log` / `seed_v10_pass.p`。

---

## 9. 系统级影响备注

- 15:52:08 的 OOM 是本次实验唯一的"系统级后果"：3 个 gw_sh 同时被内核杀掉，其中包含两支 Education 扫描 PnR（pids 22600 / 22252）的中间进度 —— 即 **Standard 增量 PnR 的尝试间接导致了两支持续 90 min 的扫描任务中断**，这也是 Lead 决定止损的重要依据之一。
- 运行 B 改为单进程后内存压力显著缓解（free 从 78 MB 回到 9.6 GB），说明 **OOM 的根因是 Standard 单进程 16 GiB 级虚拟提交 × 并发**，而非本树网表/约束有缺陷。

---

*报告生成者：teammate `inc-gate`｜生成时间：2026-11-01 16:13（Asia/Shanghai）｜本报告仅记录实测，未做任何推测以外的补测；所有"未验证"项已在 §6 显式列出。*
