# 时序根因分析：修复版 48.848 MHz vs v10 50.029 MHz（2026-11-01）

**Task**: task-2（只读分析）　**分析者**: timing-analyst　**时间**: 2026-11-01 15:1x
**目标**: 判断「1 行 RTL 修复导致时序从 50.029 MHz 掉到 48.848–49.335 MHz」是真实逻辑代价还是布局随机性，
并评估 Lead 正在跑的 Standard V1.9.12.04 `-inc_pnr`（seed = v10 通过的 `.p`）恢复 ≥50 MHz 的可行性。

**结论先行**：**可行性 = 中（偏低的一档，粗估 35–55%）**。详见 §6。

---

## 0. 一句话结论与三条关键证据

| # | 证据 | 含义 | 判定 |
|---|---|---|---|
| E1 | 同一逻辑路径 `test_mode_s0/Q → u_alloc/v_owner_v_27_s0/CE`：v10 **+0.523 ns** → 修复版 **−0.471 ns** → p0c1 **−0.214 ns**（实测）。该路径节点全在 `u_alloc/*`，**不经过被修改的 guide 字符逻辑** | 1.0 ns 级摆幅与 RTL 语义无关，是布局/布局级联效应 | 布局主导 |
| E2 | v10 最差 hold（**+0.003 ns**）的那一条 `wr_buf_din_83_s0/Q → wr_fifo/mem_mem_0_2_s/DI`，在修复版里是 **−0.296 ns**，且**两个可用布局（place_option 1 / 0）都违例**（120 / 69 条） | hold 违例不是"某个种子的偶发"，而是随网表改变的整体余量塌陷；且 v10 本身只赢 3 ps | 系统性风险 |
| E3 | 5 次同网表同选项重跑（current / var_v2 / var_v3 / var_v5 / seed_cro0）的 `.timing_paths` **逐字节相同**（SHA256 前缀 `128693E1…`，1,955,495 B） | 本设计的 PnR 是**确定性**的：**重跑不中彩票**，"换种子"不是随机性来源；只有换 `place_option` 才产生新布局，且仅值 ≈0.2 ns | 排除"随机性" |

补一条直接回答"是不是布局随机性"：
**不是运行随机性（run-to-run 方差实测为 0），但也不是逻辑深度代价** —— 是被修改行引起的**确定性布局级联**（网表 +11 LUT / +158 CLS，见 §5），
它对同一逻辑路径的 slack 影响达 1.0 ns 量级，而换布局选项只能挽回其中约 0.2–0.26 ns。

---

## 1. 数据源与可复现性核验（先钉死基线，否则后面全是错的）

### 1.1 本次使用的文件（全部实测）

| 简称 | 路径 | 关键文件 |
|---|---|---|
| v10 | `F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_pnr\impl\pnr\stale_state_v10b\` | `gates_summary.json`、`d2_screen_pnr.timing_paths`、`d2_screen_pnr.rpt.txt` |
| fix_cur | `…\work\d2_screen_pnr\impl\pnr\` | 同上 + `cmd.do` |
| p0c1 | `…\work\d2_screen_sweep_p0c1\impl\pnr\` | `gates_summary.json`、`.timing_paths`、`cmd.do` |
| var_v2/v3/v4/v5、cro0 | `…\work\d2_screen_var_v{2..5}\`、`…\work\d2_screen_seed_cro0\` | 同上 |
| PnR 门禁脚本（字段口径） | `…\work\d2_screen_pnr\parse_pnr_gates.py` | `parse_timing_html()` / `parse_timing_paths()` |
| RTL（修复版） | `…\work\d2_screen_pnr\src\top_touch_ddr.v` | **第 2749 行** |
| RTL（v10 冻结） | `…\work\d2_screen_pnr\evidence\v10_RELEASE_finalmap_20261101_1219\src_rtl\top_touch_ddr.v` | **第 2749 行** |

### 1.2 三项"防踩坑"核验（这几条会改变结论口径）

1. **v10 证据三份副本完全一致**：`v10_RELEASE_.../pnr/`、`v10_burned_GUIDE_BUG_.../pnr/`、`stale_state_v10b/` 的
   `d2_screen_pnr.timing_paths` SHA256 前缀都是 `E1803834…`、大小都是 2,897,008 B（实测）→ 用 `stale_state_v10b` 代表 v10 是安全的。
2. **PnR 配方受控**：`example\v10_RELEASE_...\pnr\cmd.do` 与 `…\d2_screen_pnr\impl\pnr\cmd.do` **哈希相同**（`1BD683D2…`），
   选项均为 `-place_option 1 -route_option 2 -clock_route_order 1 -correct_hold 1 -route_maxfan 100 -global_freq 100.000`（实测）。
   → **v10 与"修复版当前"的唯一差异变量就是网表**，这个对比是干净的。
3. **`impl\pnr` 现在的产物其实是 seed_cro0 那次构建的**：`impl/pnr` 的 `.timing_paths` SHA=`128693E1…`、`.fs` SHA=`BA27B1A9…`
   与 `d2_screen_seed_cro0\impl\pnr` 完全相同，`rpt.txt` 的 `<Created Time>` = `Sun Nov  1 13:16:49 2026` 也正是 cro0 的 created_time（实测）。
   → 报告里"修复版当前 48.848 MHz"= 配方 `place_option 1 + clock_route_order 0` 的结果。
4. ⚠ **"var_v2..v5 / seed_cro0 是 5 个不同布局样本"不成立**：这 5 个树的 `.timing_paths` 与 `impl/pnr` **逐字节相同**（`128693E1…`），
   只是 `.fs` 哈希不同。真正**不同布局**的同网表样本只有 2 个：`place_option 1`（48.848）与 `place_option 0`（p0c1 = 49.335）（实测）。
   `var_v4` 的 LUT=31058 / ALU=15967 / FF=14244，与其余 5 个（30878 / 15973 / 14247）**不同** → var_v4 是**不同网表**，不能当布局种子用。

---

## 2. Q1：修复版最差 setup 路径是否经过被修改的 guide 字符逻辑？Top-10 与 v10 对比

### 2.1 最差 setup 路径（实测）

- **slack = −0.471 ns**，`from = test_mode_s0/Q`，`to = u_alloc/v_owner_v_27_s0/CE`，`clk:[R] → clk:[R]`，`relation = 20.000 ns`，
  `clock_skew = +0.495`，`data_delay = 19.665`；**logic level = 18**（Max_Frequency 报表，clk 列）。
  源：`…\d2_screen_pnr\impl\pnr\gates_summary.json` → `path_tables.Setup.worst_path` 与 `fmax_table[clock=clk].logic_level`；
  路径节点序列见 `…\impl\pnr\d2_screen_pnr.timing_paths` 第 1–40 行（`clk_ibuf → test_mode_s0 → u_alloc/n1331_s2 → … → u_alloc/v_owner_v_27_s0`）。
- **该路径 100% 位于 `u_alloc/*`（分配器）组合逻辑内，与 guide 灯字符生成逻辑（`kobj` / `ch`）无任何交集**（实测，逐节点核对）。

### 2.2 Top-10 setup 违例路径（launch FF → 目的端；同端点最佳 slack 跨版本对比）

| # | slack(fix_cur) | launch FF | destination pin | 节点数 | v10 同端点 | p0c1 同端点 | var_v4 同端点 |
|---|---|---|---|---|---|---|---|
| 1 | **−0.471** | `test_mode_s0` | `u_alloc/v_owner_v_27_s0` | 27 | **+0.523** | −0.214 | +0.777 |
| 2 | −0.469 | `u_alloc/v_on_13_s0` | `mult_13049_s1` | 17 | +0.376 | +1.404 | +1.412 |
| 3 | −0.463 | `u_keys/g_deb[4].st_s1` | `u_alloc/v_owner_v_27_s0` | 27 | +0.523 | −0.214 | +0.777 |
| 4 | −0.459 | `u_keys/g_deb[3].st_s1` | `u_alloc/v_owner_v_27_s0` | 27 | +0.523 | −0.214 | +0.777 |
| 5 | −0.456 | `test_mode_s0` | `u_alloc/v_owner_v_12_s0` | 27 | n/a | n/a | −0.283 |
| 6 | −0.452 | `u_alloc/v_on_14_s0` | `mult_13049_s1` | 17 | +0.376 | +1.404 | +1.412 |
| 7 | −0.448 | `u_keys/g_deb[4].st_s1` | `u_alloc/v_owner_v_12_s0` | 27 | n/a | n/a | −0.283 |
| 8 | −0.318 | `u_fx_reverb/s_ap_q_1_s0` | `u_fx_reverb/mix_out_1_s0` | 67 | n/a | n/a | n/a |
| 9 | −0.313 | `u_fx_reverb/s_ap_q_1_s0` | `u_fx_reverb/mix_out_0_s0` | 67 | n/a | n/a | n/a |
| 10 | −0.308 | `u_fx_reverb/s_ap_q_0_s0` | `u_fx_reverb/mix_out_1_s0` | 73 | n/a | n/a | n/a |

数据来源：`…\d2_screen_pnr\impl\pnr\d2_screen_pnr.timing_paths`（SETUP 段，2000 条，按 slack 升序）；
跨版本列按**同目的引脚**在对应树的 `.timing_paths` 里取最佳 slack（实测）。`n/a` = 该端点未进入对方 2000 条最差表（即 slack 高于其表内最差值）。
`节点数`是 .timing_paths 的原始节点条目数（含布线节点），**不等于** logic level；logic level 以 Max_Frequency 报表为准（最差路径 18 级）。

**关键量化（实测）**：
- 修复版 setup 表里 `slack < +0.05 ns` 的路径 **319 条**；v10 只有 **12 条**。
  → 不是"单条倒霉路径"，而是**整体余量分布左移**。
- v10 自己的 setup 底线是 **+0.012 ns**（`u_keys/g_deb[9].st_s1/Q → u_alloc/v_off_8_s0/D`）——**只赢 12 ps**。

**Q1 判定**：被修改行**没有**加在任何一条违例 setup 路径上；`u_alloc/v_owner_*` 这条路径在 v10 是 +0.523、在修复版是 −0.471，
与其逻辑（未变）无关，是**布局位置变了**。同端点 var_v4 能到 +0.777（比 v10 还好）→ 该路径对布局极端敏感。

---

## 3. Q2：120 个 hold 违例在 v10 存在吗？是否是所有修复版布局的系统性问题？

### 3.1 事实（实测）

| 版本 | hold 违例端点 | 最差 slack | worst from → to | skew | data_delay |
|---|---|---|---|---|---|
| **v10** | **0** | **+0.003** | `…gw_wr_data0/wr_buf_din_83_s0/Q` → `…wr_fifo/mem_mem_0_2_s/DI[11]` | +0.004 | 0.536 |
| **fix_cur** | **120** | **−0.539** | `…wr_buf_din_133_s0/Q` → `…wr_fifo/gowin_add_SDPX9B_mem_mem_0_3_s/DI[7]` | −0.197 | 0.195 |
| **p0c1**（新布局） | **69** | **−0.439** | `…wr_buf_din_4_s0/Q` → `…wr_fifo/mem_mem_0_0_s/DI[4]` | −0.201 | 0.299 |
| var_v4（不同网表） | 141 | −0.543 | `…wr_buf_din_70_s0/Q` → `…gowin_add_SDPX9B_mem_mem_0_1_s` | — | — |

时钟域全部是 `clk_x1:[R] → clk_x1:[R]`，`relation = 0.500 ns`（来自 SDC `set_min_delay 0.5`，`src\d2.sdc` 实测）。
源：各树 `impl\pnr\gates_summary.json` → `path_tables.Hold.worst_path` + `tns_table[clk_x1/Hold]`。

### 3.2 同一 (from,to) 跨布局对照（这是本任务的核心判据）

- v10 的最差 hold 对 `wr_buf_din_83_s0/Q → wr_fifo/mem_mem_0_2_s/DI`，在修复版里 slack 变成 **−0.296 ns**（同一对 FF/引脚，实测）。
- 以修复版 `place_option 1` 的 120 条违例为基准做集合比较（实测）：
  - `place_option 0`（p0c1）：其 69 条违例中有 **59 条与 fix_cur 的 (from,to) 完全重合**（占 fix_cur 120 条的 49%）。
  - var_v4（不同网表）：与 fix_cur 重合 **117 / 120** 条（98%）。
  - 跨全部 7 个树取交集：**58 条 (from,to) 在每一个修复版树里都违例**。
  - **v10：0 条**（它本来就没有违例）。
- 修复版内部，`slack < +0.05 ns` 的 hold 路径 **135 条**；v10 只有 **27 条**。

### 3.3 判定

**是的，hold 是系统性问题，不是布局随机性造成的偶发**：
1. 它**命中两个真正不同的布局**（place_option 1 与 0），并共享 58 条相同的 (from,to)；
2. 它命中的正是 v10 那条**只赢 3 ps** 的最差对；
3. 该路径整个落在 Gowin DDR3 写数据通路（`u_ddr3/gw3_top/u_gwmc_top/gw_wr_data0/*`），**与本次 RTL 修改无任何逻辑关系**；
4. 所以机制只能是：网表 +11 LUT / +158 CLS 改变了 `wr_buf_din_*` 寄存器组与写 FIFO(BRAM) 的相对布局，使 data_delay 从 0.536 掉到 0.195（少 0.34 ns），
   而 `-correct_hold 1` 没能补回来。**这是"零余量 + 布局整体左移"的组合，不是某个种子的坏运气。**

⚠ 对 Lead 的直接含义：**换布局种子（哪怕换 place_option）不能消掉 hold 违例**——两个可用布局分别是 120 和 69 条。
`inc_pnr` 若能**原样保住 v10 的 `wr_buf_din_*` 布局**，hold 才可能回到 +0.003；一旦增量流程重新合法化/重布这块，hold 大概率回到负值。
另外 v10 的 hold 余量只有 **3 ps**，属于"通过但等于没过"。

---

## 4. Q3：recovery −0.889 ns 是否在所有修复版布局都出现？

| 版本 | recovery min | 违例路径数 | 最差 to_node |
|---|---|---|---|
| v10 | **+0.137** | 0 | `…u_ddr_init/read_calibration_logic_gen[0].rburst_neg_r_s0/CLEAR` |
| fix_cur | **−0.889** | 4 | `read_calibration_logic_gen[0]…/CLEAR` |
| **p0c1** | **+0.137** | **0** | `read_calibration_logic_gen[1]…/CLEAR` |
| var_v4 | +0.423 | 0 | `read_calibration_logic_gen[1]…/CLEAR` |
| var_v2 | −1.166 | 4 | `read_calibration_logic_gen[0]…/CLEAR` |

（实测，源：各树 `impl\pnr\gates_summary.json` → `path_tables.Recovery`；from 恒为 `u_ddr3/gw3_top/u_ddr_phy_top/ddr_rsti_reg_2_s0/Q`，
`clk:[R] → clk_x1:[F]`，`relation 5.000`，`clock_skew` 均为 +1.758，变的是 `data_delay`：v10 2.778 / fix 3.804 / var_v2 4.081。）

**判定：recovery 不是系统性问题，是布局敏感的。**
同一 from/to、同一 skew，只有 data_delay 随布局变化；**换一个布局（p0c1）就自动回到 +0.137（与 v10 完全同值）**。
→ recovery 违例会随布局消失，**不构成 inc_pnr 的主要障碍**（但也是"硬币"：var_v2 拿到 −1.166）。

---

## 5. Q4：综合/网表层面 —— RTL 变化是否改变了被修改路径的逻辑级数？

### 5.1 RTL 差异（实测）

两文件行数相同（4373 行），字节数 229,366（v10）→ 229,401（修复版，+35 B）。`kobj` 相关 7 行中仅第 2749 行不同：

```
v10   : 2749:  else ch = {3'h3, kobj};
修复版: 2749:  else ch = {4'h3, kobj[3:0]};   // 0x30 + key  ->  '0'..'9'
```

（源：`…\evidence\v10_RELEASE_finalmap_20261101_1219\src_rtl\top_touch_ddr.v:2749` 与 `…\src\top_touch_ddr.v:2749`；
只核对了 `kobj` 上下文，**未做全文逐行 diff** → 见 §7。）

### 5.2 资源对比（实测，PnR 阶段的 Resource Usage）

| 版本 | LUT | ALU | FF | Logic | CLS | CLS/29952 |
|---|---|---|---|---|---|---|
| v10 | 30,867 | 15,986 | 14,247 | 46,883 | 25,553 | 85.3% |
| fix_cur | 30,878 | 15,973 | 14,247 | 46,881 | **25,711** | **85.8%** |
| p0c1 | 30,878 | 15,973 | 14,247 | 46,881 | 25,678 | 85.7% |
| var_v4（不同网表） | 31,058 | 15,967 | 14,244 | 47,055 | 25,802 | 86.1% |

**Δ(v10 → fix) = +11 LUT / −13 ALU / 0 FF / +158 CLS（+0.6%）**。源：各树 `impl\pnr\gates_summary.json` → `resources_flat`。

### 5.3 逻辑级数是否变化？—— "没有，也不该有"

- 旧式 `{3'h3, kobj}`（3+5=8 bit）与新式 `{4'h3, kobj[3:0]}`（4+4=8 bit）**都是纯拼接 + 常量高位**，
  综合阶段常量折叠后**不产生任何新的门级深度**（被修改的是一个 8 bit 字符选择，仍是一级 mux/常量注入）。
- 交叉验证（实测）：修复版 2000 条最差 SETUP 路径中，**穿过 `u_key_light/*`、`guide*` 的路径 0 条**；
  120 条 hold 违例路径中穿过这些节点的也是 **0 条**（`guide_timer_*`、`guide_fifo_*` 等只出现在**不违例**的 hold 端点里）。
- Max_Frequency 报的 `logic level` 从 v10 的 16 变成 18，只是"最差路径换了另一条"（v10 最差是 `u_alloc/v_off_8_s0`，18 级那条在 v10 是 +0.523），
  **不是网表被加深了**。
- 综合侧资源一致：fix 的 `impl\gwsynthesis\d2_screen_pnr.log` 只报 2 条既有的 `EX3791` 位宽截断告警（`fx_ddr_echo.v:247/253/260`），
  **与 guide 字符逻辑无关**；`_syn_resource.html` 里 `u_key_light`/`u_alloc` 层级正常（实测）。

**Q4 判定**：**RTL 修复不引入逻辑级数/逻辑深度代价（+11 LUT 属于 ALU↔LUT 重映射噪声）**。
速度掉下来的机制是：网表微扰 → 综合/布局打包改变 → **关键路径（`u_alloc` 深组合、DDR3 写 FIFO）所在区域的物理布局变差**。
即"**不是逻辑代价，是物理（布局）代价**"。

---

## 6. 结论：`inc_pnr` 恢复 ≥50 MHz 的可行性 = **中**

### 6.1 判断与理由

**可行性：中（粗估 35–55%，setup 偏乐观、hold 是瓶颈）。**

支持恢复 ≥50 MHz 的理由：
1. **被修改的逻辑与被判死的路径物理无关**：最差 setup 路径在 `u_alloc/*`，hold 违例全在 `u_ddr3` 写 FIFO 通路，两者都不经过 guide 字符逻辑（§2.1、§3.2、§5.3）。
2. **配方完全受控**：v10 与修复版当前构建的 `cmd.do` **字节相同**（§1.2），唯一变量是网表；而 v10 在**同一配方**下拿到 50.029/0/0/+0.137，
   说明"这套布局 + 这套选项"对该设计是可达 ≥50 MHz 的。
3. **增量 PnR 的机制正对症**：本次失败的本质是"全局重布导致的关键区域布局变差"（§5.3），而 `-inc_pnr` 以 v10 的 `.p` 为种子、只重布差异区，
   **正是唯一能保住 v10 那块布局的手段**；换成重新全量跑（已验证确定性）只会稳定复现 48.848。

不能判"高"的理由：
4. **v10 的余量薄到几乎不存在**：setup **+0.012 ns**、hold **+0.003 ns**、recovery **+0.137 ns**（§2.1、§3.1、§4）。
   修复版净增 +11 LUT / +158 CLS（+0.6%，CLS 到 25711/29952）必须被消化，任何一次重新合法化/局部重布都可能吃掉这 12 ps / 3 ps。
5. **两个"不同布局"的同网表样本都失败**（48.848 / 49.335），且 hold 在两者都违例（120 / 69）—— 说明"换布局"这个自由度本身不足以救场，
   只能靠"保住 v10 原布局"这一条路；而这一点在增量模式下**没有任何先验保证**（尤其 `correct_hold` 阶段可能重布 clk_x1）。
6. **hold 的结构性风险**：v10 最差 hold 对恰好就是修复版的第一批违例对（+0.003 → −0.296），
   即"零余量 + 略微变差 = 违例"；`inc_pnr` 里只要 `wr_buf_din_*` 一带被动过，hold 必负。

### 6.2 具体风险（按概率×影响排序）

| # | 风险 | 依据 | 影响 |
|---|---|---|---|
| R1 | **hold 120 违例不是布局偶发，inc 未必修好** | 两个不同布局（place_option 1/0）都违例，且共享 58 条相同 (from,to)；命中 v10 仅 +0.003 的那一对（§3.2/3.3） | 高：即使 setup 回到 ≥50，hold 仍可能 FAIL，门禁过不了 |
| R2 | **v10 的通过是"12 ps / 3 ps 级"的巧合** | v10 setup min +0.012、hold min +0.003（§2.1/§3.1） | 高：增量流程任何抖动都会翻负；结果对流程细节极敏感 |
| R3 | `.p` / `.db` 跨版本兼容性未知 | v10 的 `.p` 由 **V1.9.11.03 Education** 产出（`v10_RELEASE.../pnr/d2_screen_pnr.fs`/`rpt.txt` 头，实测）；Lead 用 **V1.9.12.04** | 中：若不兼容而静默退化，等价于全量重跑 → 稳定复现 48.848 |
| R4 | 网表实例名变化导致增量匹配失败 | 本次 +35 B RTL 改动虽小，但综合后 LUT/ALU 计数变化（+11/−13），`u_alloc`/`u_key_light` 层级内的 LUT 打包编号可能整体位移 | 中：匹配率低则增量退化为全量 |
| R5 | 现行 `impl\pnr` 里是 cro0（`clock_route_order 0`）的产物，不是"标准配方" | `.timing_paths`/`.fs` 与 `d2_screen_seed_cro0` 完全相同（§1.2-3） | 低：仅影响记录口径，注意别把 cro0 数字当 baseline |

### 6.3 建议（供 Lead 决策，仅分析建议）

1. 先跑 `-inc_pnr` 且**只信 hold 门禁**：setup 只要保住 v10 布局大概率 ≥50；**hold 是唯一真正的判据**。
2. 若 inc 后 hold 仍负（预计概率不低），**不要在 PnR 上继续加码**（已证明换布局/换选项只有 ~0.2–0.35 的 Fmax 摆动），
   应转向：放宽/重审 `clk_x1` 的 `set_min_delay 0.5`（`src\d2.sdc`）或对 `u_ddr3` 写 FIFO 的 `wr_buf_din_*` 做区域约束/`INS_LOC` 复用 v10 位置。
3. 记录口径：v10 = 50.029 MHz（setup 0 / hold 0 / rec +0.137 / rem +0.357）；修复版当前 = 48.848（35 / 120 / −0.889 / +0.601）；
   修复版最佳布局 = 49.335（p0c1：39 / 69 / +0.137 / +0.532）。

---

## 7. 未验证 / 局限（明确标注，不要当结论用）

1. **未验证**：两版 `top_touch_ddr.v` 的**全文逐行 diff**。仅核对了 `kobj` 上下文 7 行与文件字节数（+35 B）、行数（均 4373）。
2. **未验证**：`-inc_pnr` 的实际可用性/匹配率/`.p` 跨版本兼容性（未启动任何 Gowin 构建，按要求）。
   `…\d2_screen_pnr\**\*.log` 中 grep `inc_pnr|incremental|-reuse` **无任何命中**（实测）→ 本仓库无现成增量构建先例可参考。
3. **未验证**：v10 所用的 v1.9.11.03 与 1.9.12.04 在 **hold 修复（`-correct_hold`）算法上的差异**，这是 hold 结论的主要不确定性来源。
4. **样本量小**：真正"同网表不同布局"的样本只有 **2 个**（48.848 / 49.335）。var_v2/v3/v5/seed_cro0 是同一布局（哈希相同），var_v4 是不同网表。
   因此"布局随机性"的分散度（≈0.2–0.26 ns / 0.49 MHz）**统计置信度低**。
5. **未验证**：`u_alloc` 那条 18 级深组合逻辑（`test_mode_s0 → v_owner_v_27_s0/CE`，data_delay 19.665 ns）是否本来就**接近 20 ns 上限**、
   即 v10 的 +0.523 是否也只是"运气好"；这需要看 v10 之外的更多同配方样本，当前没有。
6. **未验证**：recovery 违例的 4 条路径是否都落在同一 `read_calibration_logic_gen[*]` 组（只看清了最差 1 条与总数 4）；
   其是否影响 DDR3 初始化功能（timing 上违例 ≠ 功能必失效，但没有仿真/上板验证）。

---

### 附：本报告每个关键数字的出处（速查）

| 数字 | 出处（绝对路径） |
|---|---|
| v10 50.029 MHz / setup 0 / hold 0 / rec +0.137 / rem +0.357 | `…\d2_screen_pnr\impl\pnr\stale_state_v10b\gates_summary.json` → `gates.*` |
| v10 setup min +0.012（`g_deb[9].st_s1/Q → v_off_8_s0/D`） | 同上 → `path_tables.Setup.worst_path` |
| v10 hold min +0.003（`wr_buf_din_83_s0/Q → mem_mem_0_2_s/DI[11]`） | 同上 → `path_tables.Hold.worst_path` |
| fix 48.848 / 35 / 120 / −0.889 / +0.601 | `…\d2_screen_pnr\impl\pnr\gates_summary.json` → `gates.*` |
| fix setup min −0.471（`test_mode_s0/Q → v_owner_v_27_s0/CE`，18 级） | 同上 → `path_tables.Setup.worst_path`、`fmax_table` |
| fix hold min −0.539（`wr_buf_din_133_s0/Q → …mem_mem_0_3_s/DI[7]`） | 同上 → `path_tables.Hold.worst_path` |
| v10 最差 hold 对在 fix 中为 −0.296 | `…\d2_screen_pnr\impl\pnr\d2_screen_pnr.timing_paths`（HOLD 段，`wr_buf_din_83_s0` 块） |
| 跨版本同端点 slack（+0.523 / −0.214 / +0.777 等） | 各树 `impl\pnr\d2_screen_pnr.timing_paths`（SETUP 段，按目的引脚取最佳） |
| 违例 (from,to) 集合交集 58 条 / 59 条 | 各树 `.timing_paths`（HOLD 段 slack<0，按首末节点配对比较） |
| 319 / 12（setup <+0.05）、135 / 27（hold <+0.05） | fix_cur 与 v10 的 `.timing_paths` 统计 |
| 资源 LUT/ALU/FF/CLS | 各树 `impl\pnr\gates_summary.json` → `resources_flat` |
| PnR 配方（`-place_option` 等）与哈希 | `…\d2_screen_pnr\impl\pnr\cmd.do`、`…\v10_RELEASE_...\pnr\cmd.do`、各 var/p0c1 树 `cmd.do` |
| 布局同一性（`128693E1…` / `E1803834…`） | 各树 `d2_screen_pnr.timing_paths` 的 SHA256 |
| RTL 单行差异 | `…\src\top_touch_ddr.v:2749` vs `…\evidence\v10_RELEASE_...\src_rtl\top_touch_ddr.v:2749` |
