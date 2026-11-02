# SCREEN_FPGA_RESULT — 串口屏 FPGA 侧按键解码（v10 = 最终 HMI obj 映射）

## 0. 最终交付（RELEASE · v10 · 2026-11-01 12:14）

**v10 = 最终 HMI 对象映射（用户 2026-11-01 确认） + v3/v7 全部功能 + W21b「MPR121 物理键 → 屏上虚拟键点亮」。**
本版是**唯一按最终 HMI 映射重建并通过全部门禁的位流**；v9 起的前一版映射（page1 2–8/11–15/18/19、键灯 bt7..bt18）已作废归档。

| 项 | 值（实测，9/9 门禁 PASS） |
|---|---|
| 位流 | `impl\pnr\d2_screen_pnr.fs` |
| 大小 | **14,104,161 字节** |
| SHA256 | **`2E2978AE25CD2975F5EFECCAB73A461627EB3633A8045EBB52310CDB12D72962`** |
| UserCode / CheckSum | **`0x0000B149` / `0xB149`**（与 v7 的 `0x0000881C` **不同** → 烧后 `op73` 回读可直接区分 v10/v7） |
| 门禁 | **9/9 PASS**：clk Fmax **50.029 MHz**；setup violated **0**（min **+0.012 ns**）；hold violated **0**（min **+0.003 ns**）；recovery min **+0.137 ns**（2000 条全 ≥0）；removal min **+0.357 ns**（2000 条全 ≥0）；无 unrouted；CLS **25,553/29,952**；约束保留；build exit 0 |
| 资源 | LUT **30,867**、ALU 15,986、FF **14,247**、BSRAM **89/118**、DSP **61/118**、I/O 65/297 |
| 配方 | **place1 / route2 / cro1 / correct_hold1（工程默认）/ maxfan100 / bit_compress1 / vccx 1.8**，**CST/SDC 未改**（哈希同基线） |
| 构建 | `build_screen_pnr_v10_full.tcl`（syn+pnr 同一会话，与 v7 成功时同一流程），PnR elapsed 1604 s |
| 证据 | `evidence\v10_RELEASE_finalmap_20261101_1219\`（fs / rpt.txt / timing_paths / gates_summary.json / cmd.do / 构建日志 / TB 源码与日志 / 冻结 RTL 副本） |

**最终 HMI 映射（屏侧要设的是「组件 ID」，灯命令用的是「控件名称」）**

| 方向 | 用什么 | 值 |
|---|---|---|
| 屏 → FPGA 触摸帧 `65 <page> <obj> 01 FF FF FF` | 控件**组件 ID** | page1：3滑音 4震音 5合唱 6 32音测试 7REV 8VIB 10音色 11降八度 12高八度 13效果器 14延迟 15跟弹 16选曲；page0：4回声开关 5回声换挡 |
| FPGA → 屏 灯色 `bt<k>.bco=` | 控件**名称** | 12 个琴键名称保持 **bt0..bt11**（TJC 不能按 ID 寻址）；琴键不勾「发送组件 ID」 |

**烧录与自举（实测）**
- **op2 烧 SRAM：12:23:59 成功**（exit 0，9.05 s，op2 输出内 UserCode `0x0000B149`）✅
- **op73 回读：12:23:59 `0x0000B149` = 期望值** ✅
- **op69 烧外部 Flash：12:23:59–12:30:20 成功**（exit 0，380.88 s，`Program and Verify flash successfully.`）✅
- 烧后 `op73` 读 `0x00000000`（GAO-Bridge 在 SRAM）属正常
- 烧录记录：`V10_BURN_RESULT.txt`、`v10_burn.log`、脚本 `burn_v10.ps1`
- **断电自举验证（待执行）**：SW2→`100001` → **真断开 DC 电源 5 s** → 上电 → 跑 `burn_v10.ps1 -VerifyOnly`，`op73` 应回读 **`0x0000B149`**

**v7 历史（同功能、旧 obj 编号，已被 v10 取代）**：14,412,289 B / `6A1D5EF8…` / UserCode `0x0000881C` / clk 50.025 MHz / CLS 25,597；已 op2+op69 烧录成功（`V7_BURN_RESULT.txt`、`v7_burn.log`）。

状态：**最终交付 = v10 位流（9/9 门禁 PASS）+ 最终 HMI obj 映射；FPGA 侧 15/16 与 v9 中间映射均已归档**
日期：2026-11-01（Asia/Shanghai）
工作树：`F:\fiehuo\ddr_audio_v1_20261030\work\d2_screen_pnr`

> **历史说明**：以下第 1–10 节保留 2026-10-31 13:00–15:24 的 15/16 FPGA 侧实验记录（最终未采用）；**实际交付以本节 §0 为准**。

> 数字标注口径：**实测** = 本次仿真/工具直接得到；**推算** = 依据实测推导；**目标** = 任务门禁要求；**未验证** = 本次未做或做不到。

---

## 1. 结论速览

| 项 | 结果 | 性质 |
|---|---|---|
| page1 最终 13 个 obj（3–8 / 10–16）解码 | **已实现并仿真通过**（单拍脉冲，逐 obj 一对一） | 实测 |
| page0 obj 4/5（回声开关 / 回声换挡）解码 | **已实现并仿真通过** | 实测 |
| cho_mix / rv_room / rv_damp 屏键 | 最终 HMI 无对应按键 → `ev_*` 恒 0，保留 PC 0x12/0x0D/0x0E 路径 | 实测 |
| 键灯 / 引导灯 `bt<k>` 名称 | **bt0..bt11**（`KEY_BASE=0`），仿真逐字节验证 | 实测 |
| 单元 TB（最终映射，新增） | **`FINALMAP_UI_PASS`**（23 帧、15 个动作计数全对，mix/room/damp=0）+ **`FINALMAP_KL_PASS`**（bt0/bt5/bt10/bt11 绿 2016/灰 33808，15/16/16/17 B） | 实测 |
| 旧单元 TB（v3 映射） | v3：`UNIT_TB_PASS`；v10 换了 obj 常量后该 TB 未重跑（已被上面的最终映射 TB 取代） | 实测 / 未重跑 |
| 集成 TB（屏帧 vs PC 单字节等价） | v3 FINAL：69/69 断言 PASS、0 mismatch；v10 未重跑 | 实测 / 未验证 |
| 回归 D1 / 650k 旁路 / 300ms 颤音滑音 | v3：17/17 PASS、0/650,000、0/18,013（轨迹 SHA256 与冻结件全同）；v10 未重跑 | 实测 / 未验证 |
| **PnR（v10 最终 RTL）** | **9/9 门禁 PASS**：clk 50.029 MHz、setup/hold violated 0（+0.012/+0.003）、recovery +0.137、removal +0.357、无 unrouted、CLS 25,553 | 实测 |
| PnR 失败中间态（v10a，bt7..bt18 字符串 + 旧 impl 状态） | **门禁 FAIL**：clk 41.544 MHz、setup 652 端点、hold 105 端点（已归档，未采用） | 实测 |
| 板级烧录 | **op2 SRAM + op69 Flash 均成功**（12:23:59 / 12:30:20，op73 回读 `0x0000B149`） | 实测 |
| 板级自举 | SW2=100001 + 真断电 5 s 后 op73 应回读 `0x0000B149` | **待执行** |

---

## 2. 屏侧帧规格与 obj 映射

帧格式（仅处理按下 0x01）：`65 <page> <obj> 01 FF FF FF`，7 字节，115200 8N1。
不变项：0x65 头、FF FF FF 尾校验、event==0x01、200 ms 同 (page,obj) 去抖、1 ms 帧内超时、`in_frame` 门控。
obj 是**页内独立编号**：page0 的 obj4/5 与 page1 的 obj4/5 互不冲突。

> **「对象编号」到底指什么（用户 2026-11-01 确认）**
> - **屏 → FPGA**（触摸帧 `65 <page> <obj> ...`）：第 3 字节是控件的 **组件 ID（obj 数字）**，与控件名称无关。设置页/回声键必须在 HMI 里把「组件 ID」设成下表数字，并勾「发送组件 ID / 触摸返回」（或直接 `printh 65 01 03 01 FF FF FF` 手写字节）。
> - **FPGA → 屏**（灯色命令 `bt<k>.bco=2016/33808`）：TJC 命令按**控件名称**寻址，不能按 ID；因此 12 个琴键的**名称保持 `bt0..bt11`**（用户确认，HMI 不用改名），琴键的组件 ID（7..18）不参与灯命令，也不发触摸帧。


### 2.1 page 1（设置页）—— 最终 HMI 映射（用户 2026-11-01 确认）

| obj(ID) | 控件 | 返回帧 | FPGA 动作 | 对应 PC 命令 |
|---:|---|---|---|---|
| 3 | 滑音 | `65 01 03 01 FF FF FF` | 滑音档 0→1→2→3→0 | 0x0F |
| 4 | 震音 | `65 01 04 01 FF FF FF` | 震音档 0→1→2→3→0 | 0x10 |
| 5 | 合唱 | `65 01 05 01 FF FF FF` | 合唱开/关 | 0x11 |
| 6 | 32音测试 | `65 01 06 01 FF FF FF` | 32 音测试开/关（单键 toggle） | 0x03 开 / 0x04 关 |
| 7 | REV | `65 01 07 01 FF FF FF` | 混响 OFF→R0→R1→R2→OFF | 0x0C |
| 8 | VIB | `65 01 08 01 FF FF FF` | 颤音深度 0→1→2→3→0 | 0x0B |
| 10 | 音色 | `65 01 0A 01 FF FF FF` | timbre 循环 | 0x05 |
| 11 | 降八度 | `65 01 0B 01 FF FF FF` | 八度 -1 | 板载 KEY1 |
| 12 | 高八度 | `65 01 0C 01 FF FF FF` | 八度 +1 | 板载 KEY2 |
| 13 | 效果器开关 | `65 01 0D 01 FF FF FF` | fx 总开关 | 0x06 |
| 14 | 延迟档位 | `65 01 0E 01 FF FF FF` | 延迟档 | 0x07 |
| 15 | 跟弹开关 | `65 01 0F 01 FF FF FF` | 跟弹开关 | 0x08 |
| 16 | 选曲 | `65 01 10 01 FF FF FF` | 选曲 | 0x09 |

- page1 obj 2 / 9 / 17 在 FPGA 侧无动作（`ev_valid` 照常置位，所有动作脉冲保持低）。
- 合唱混合（PC 0x12）、混响 room/damp（PC 0x0D/0x0E）在本版 HMI 上**没有对应按键**，仅保留 PC 命令路径；`ev_cho_mix/ev_rv_room/ev_rv_damp` 端口恒 0。

### 2.2 page 0（演奏页）

| obj(ID) | 控件 | 返回帧 | FPGA 动作 | 对应 PC 命令 |
|---:|---|---|---|---|
| **4** | 回声开关 | `65 00 04 01 FF FF FF` | echo 开/关 toggle | 0x13 |
| **5** | 回声换挡 | `65 00 05 01 FF FF FF` | 0.5→1→2→4→0.5 s 循环 | 0x14 |

- 12 个琴键：FPGA 只**发**灯色命令，地址用控件**名称** `bt0..bt11`（`bt<k>.bco=2016` 绿 / `33808` 灰）；琴键不勾「发送组件 ID」，其组件 ID（7..18）不参与任何 FPGA 逻辑。
- 若以后要改琴键名称 → 只改 `src/key_light.v` 的 `KEY_BASE`（默认 0）+ `top_touch_ddr.v` 引导灯两处 `kobj` 的基址，再重建 PnR；不要改屏布局。


---

## 3. FPGA 修改点（v10 = 最终 HMI 映射；只动 3 个文件）

### 3.1 `src/ui_evt_rx.v`（基线 11,701 B → v10 15,846 B）

- 端口：`ev_p32 / ev_glide / ev_trem / ev_chorus`（page1）、`ev_echo / ev_echo_dly`（page0）、`ev_cho_mix / ev_rv_room / ev_rv_damp`（保留但**恒 0**，最终 HMI 无对应按键）。
- localparam 全部按最终 HMI 重排：page1 `OBJ_GLIDE=3 / OBJ_TREM=4 / OBJ_CHORUS=5 / OBJ_TEST=6 / OBJ_REV=7 / OBJ_VIB=8 / OBJ_TIMBRE=10 / OBJ_OCT_DN=11 / OBJ_OCT_UP=12 / OBJ_FX=13 / OBJ_DLY=14 / OBJ_GUIDE=15 / OBJ_SONG=16`；page0 `OBJ_P0_ECHO=4 / OBJ_P0_ECHO_LEN=5`。
- page1 `case (obj_r)` 13 个 arm 全部换成上表；page0 仍是**独立** `if (page_r == 8'd0)` 块（不能写成 `else if`，见 §5.2）。
- 复位块与「每拍清脉冲」块各 19 个清零不变。

**未改**：字节索引/7 字节状态机、0x65 头识别、FF FF FF 尾校验、`evt_r == 0x01`、`dbn_block` 200 ms 去抖、`tmo` 1 ms 超时、`in_frame` 门控、`tail_bad` 处理。

### 3.2 `src/top_touch_ddr.v`

| 位置 | 改动 |
|---|---|
| `ev_*` 声明 / `u_ui_evt` 例化 | 新增 `ev_p32/ev_glide/ev_trem/ev_chorus/ev_echo/ev_echo_dly/ev_cho_mix/ev_rv_room/ev_rv_damp` 9 根 wire 与端口连接 |
| `test_mode` always 块 | 追加 `else if (ev_p32) test_mode <= ~test_mode;`（在 0x03/0x04 之后、优先级更低） |
| `uart_glide/trem/chorus` | `(rx_done_eff && 0x0F/0x10/0x11) \|\| ev_glide/trem/chorus` |
| `uart_echo_toggle / uart_echo_dly` | `(rx_done_eff && 0x13/0x14) \|\| ev_echo/ev_echo_dly` |
| `uart_cho_mix` / `uart_rev_room` / `uart_rev_damp` | 三源 mux 保留，但 `ev_*` 恒 0 → 实际只剩 PC 0x12 / 0x0D / 0x0E |
| `guide_frame_len_f` / `guide_frame_char_f` | 引导灯 `bt<k>` 的**名称后缀**=`key` 本身（`kobj = key + 5'd0`，bt0..bt11）；数字位数判据随之改（0..9 一位、10..11 两位） |

**未改**：`fx_ddr_echo` 算法/延迟档/CAP_SLOT/FADE_LEN、音频链路、采样率、时间复用槽位、DDR 服务、echo 混合公式、`d2.cst`、`d2.sdc`。

### 3.3 `src/key_light.v`（新增到工程，来自既有 W21b 实现）

- 自由演奏按键灯：`bt<k>.bco=2016`（绿）/ `bt<k>.bco=33808`（灰）+ FF FF FF。
- v10 关键点：`KEY_BASE = 0`，即灯命令后缀就是键序号 0..11（**名称 bt0..bt11**）；帧长 15/16 B（k≤9）、16/17 B（k=10/11）。
- `d2_screen_pnr.gprj` 文件列表加入 `src/key_light.v`。

### 3.4 冻结哈希（`RTL_FROZEN.txt`，UTF-8 无 BOM）

| 文件 | SHA256（v10 最终） | 基线 SHA256 |
|---|---|---|
| `ui_evt_rx.v` | **`9F82377FB2841A24986205B2FF29DF6751954EAFB55C055CC8E66FFE4A7327D6`** | `CB46C163…8CDFEA` |
| `top_touch_ddr.v` | **`187023D6BEF2553351B48CE7F7E10B1A5C70B67D30437B4FAEB690230C6B228C`** | `0A190DD2…B7728` |
| `key_light.v` | **`7C839D6BD362F2A4ED958A8E2D26E8982AC42CDC6CF0EA04AEFBC529AAAA31A5`** | 基线无此文件（W21b 引入） |
| `d2.cst` | `DA1A0934E35386E0B2A40516DB60E7089848B8F7C8514321606FB088AAD8428D` | 同（未改） |
| `d2.sdc` | `B98FE342D7346FB33BCD08EE5924BB632B26427324D039BB16944B1BE6F17D2A` | 同（未改） |

历史哈希（追溯用）：v1 `E40C76F1…`；v2 `8D55F9F5…`；v3 `8B89D8B5…`（page0 16/17，已出位流）；v4 `CEDA03F3…`（未重建）；v7 `8B89D8B5…`+key_light（bt0..bt11，已出位流并烧录）；v9/v10a 中间态（page1 2–8/11–15/18/19 + bt7..bt18，未通过门禁，已归档）。
其余 `src/*.v` 与基线逐字节相同（`reg\v3\source_sha256.txt`，实测）。

---

## 4. 测试

### 4.1 单元 TB（`tb_unit\tb_ui_evt_rx_newkeys.sv`，日志 `tb_unit\unit_tb.log`）

真实时序参数：CLK=50 MHz、`FRAME_TIMEOUT_US=1000`、`DEBOUNCE_US=200_000`、`DO_DEBOUNCE=1`。
覆盖组（同一 TB，page0 编号在 v4 中已改为 15/16）：旧帧 02–08/0A/0B、新帧 0C–0F 单拍、page0 无 page1 脉冲、错误 event、坏尾可恢复、200 ms 同键吞/异键立收/窗口到期、1 ms 超时恢复、`ev_valid/page/obj` 字段、page0 15/16 单拍 + 其他 obj（含旧号 17）静默 + page1 obj15 仅 CHORUS/obj16 静默。

**v3 实测：`UNIT_TB_PASS`，errors=0**；脉冲计数 `legacy timbre=1 oct_dn=1 oct_up=1 fx=1 dly=1 guide=1 song=1 vib=1 rev=2`、`new p32=3 glide=5 trem=3 chorus=3 echo=1 echo_dly=2 valid=32`；仿真 203,267,040 ns / 约 32 s。
**v4（15/16）状态：TB 源码已同步改号，按用户要求未重跑（未验证）。**

### 4.2 集成 TB（`tb_int\`，报告 `tb_int\SIM_INT_REPORT.md`）

方法：ModelSim ASE 全顶层（`+define+MERGED`，DDR3MI/DDR_PLL/pll_mDRP 用行为 stub），屏帧注 `uart_rxd2`、PC 单字节注 `uart_rxd`，同时间骨架双跑后逐行比对内部状态（`test_mode / glide_sel / trem_sel / cho_en / u_fx_ddr_echo.want_on / delay_req`）。

**v3 FINAL（实测，`SIM_INT_REPORT.md` §11）：69/69 断言，0 FAIL，全部 vsim Errors: 0 / Warnings: 0。**

| 检查（v3，page0 用 16/17 编号） | 结果 |
|---|---|
| page0 ECHO 单按开/再按关，等价 PC 0x13 | PASS；`want_on` 0→1→0，SCREEN vs PC 状态序列 **0/22** |
| page0 ECHO 真实 >200 ms 复按 | PASS：@4,608,350 ns 开；**205.35 ms** 后同键再按 → 关（窗口内那次被吞） |
| page0 ECHO LEN 四按 0.5→1→2→4→0.5 s | PASS：`delay_req` 0→1→2→3→0，与 PC 0x14 **0/22** |
| page0 其他 obj（2/5/9/13） | PASS：无动作、状态不变 |
| page0 同键 200 ms 去抖 / 异键立收 | PASS |
| page1 obj12–15 + 旧 obj2–11 + PC 0x01–0x14 不变 | PASS：SCREEN 39/39；LEGACY v3 vs 基线 **0/34**（事件 **0/28**）；v3 vs v2 **0/22**（证明结构改写行为等价） |

运行：screen3 39/39（29.41 ms）、pc3 22/22（7.09 ms）、legacy3、slowp0c 8/8（**211.78 ms** 真实时间/9 分 34 秒）。
**v4（15/16）状态：未重跑（未验证）；逻辑与 v3 同构，仅比较常量变化。**

### 4.3 回归（`reg\SIM_REG_REPORT.md` v3=FINAL、`reg\sim_reg_summary.json`）

| 回归 | 门禁 | v3 实测 | 证据 |
|---|---|---|---|
| D1 DDR3 音频服务 | 17/17 | **17/17 PASS**（case 清单与 5 个输入 SHA256 同冻结件；263 s） | `reg\v3\d1\evidence\sim_summary.json` |
| D2 旁路等价 | 650,000 拍 0 mismatch | **0 / 650,000**，trace SHA256 = `b4be68b4…375c`（与冻结 `hp_cs1.txt` 全同；48 s） | `reg\v3\diff_hp.txt` |
| 颤音/滑音 300 ms | 18,013 帧 0 mismatch | **0 / 18,013**，trace SHA256 = `c87d5740…b28ef`（与发布包 `vib_long_cs1.txt` 全同；16m35s） | `reg\v3\diff_vib.txt` |

结论：屏侧解码改动**没有改变任何音频/服务行为**——三条轨迹与 v1/v2/发布版逐字节相同。
v1/v2 同类结果保留在 `reg\`（§1–8）与 `reg\v2\`。**v4 未重跑（未验证）。**

---

## 5. PnR（已用 v3 网表完成；v4 需重建）

### 5.1 尝试记录（实测）

| 尝试 | 网表 | 配方 | 结果 |
|---|---|---|---|
| attempt1 | v1 | place1/route2/cro1 | Routing Phase1 13m36s 后 `ERROR (PR0004): 0 unrouted nets` 中止；无 timing/位流 |
| attempt2 | v1 | 同上（PnR-only 重跑） | **完全相同的确定性与中止**（资源表逐项相同） |
| attempt3 | v1 | place1/route2/cro2 | 诊断用，人工终止 |
| attempt4 | v2 | place1/route2/cro1 | Routing Phase1 **25 分钟无进展**（stall），人工终止 |
| attempt5 | v2 | place1/route2/cro2 | 诊断用，人工终止 |
| **attempt6** | **v3**（T_Lut 28,963，比基线小） | **place1/route2/cro1（任务指定配方，零偏离）** | ✅ **一次成功**：Routing Phase1 4m53s → PR1014 → timing → bitstream；全部门禁 PASS |

attempt1/2 资源实测：Logic 46,364 / FF 14,193 / CLS 25,444（85%）/ BSRAM 89 / DSP 61 —— **不是容量溢出**。

### 5.2 根因与修正（关键经验）

- v2 把 page0 写成 `end else if (page_r == 8'd0)` → GowinSyn 顶层胶合 **T_Lut 31,017**（基线 30,529）→ 布线无法收敛（PR0004 / 25 min stall）；
- 改成**两个互斥的独立 `if`** → **T_Lut 28,963**（比基线小 1,566）→ 同一配方 **4m53 收敛**，复现基线 PR1014 签名。
- 因此最终**没有任何 PnR 配方偏离、没有改 CST/SDC、没有 false path/multicycle**。
- 备用阶梯（未用到）：cro2 → p0/r2 → p1/r2/mf50 → p2/r2 → p1/r2/cro0；route_option 1 不采用（基线历史从未跑完）；增量 PnR 对本器件不可用（`rtlplacerouteoptions5at.xml` 里 PNR23 整段注释，实测 `-inc_pnr` 只传字面量 1）。

### 5.3 v3 门禁与位流（实测，全部 PASS）

| 门禁 | 目标 | v3 实测 | 基线（对照） |
|---|---|---|---|
| `clk` Fmax | ≥ 50 MHz | **51.521 MHz** | 52.787 MHz |
| 全局 Setup violated endpoints | 0 | **0**（最差 slack +0.591 ns / 2000 路径） | 0 |
| 全局 Hold violated endpoints | 0 | **0**（最差 slack **+0.006 ns**） | 0（+0.004 ns） |
| Recovery 所有路径 | ≥ 0 | **2000 条，最小 +0.423 ns** | 2000 条 / +0.422 ns |
| Removal 所有路径 | ≥ 0 | **2000 条，最小 +1.027 ns** | 2000 条 / +0.516 ns |
| 无 unrouted | 0 | **0**（PR0004 未出现；PR1014 与基线同签名） | 0 |
| CLS | ≤ 29,952 | **25,408 / 29,952（85%）——比基线低 250** | 25,658（86%） |
| Logic / FF / BSRAM / DSP | 参考 | 44,892（75%）/ 14,186 logic FF + 11 IO FF / 89 / 61 | 46,452 / 14,186+11 / 89 / 61 |
| 约束保留 | 保留 | CST `INS_LOC ddr_rsti R53C57[0][B]` ✓；SDC S1 false path、2 条 hold-only、`set_min_delay 0.5`、4×`report_timing 2000` ✓ | — |

| 位流项 | v3 值（**注意：obj 常量为 16/17，不能直接用于 15/16 HMI**） |
|---|---|
| 文件 / 大小 | `impl\pnr\d2_screen_pnr.fs` / **14,070,353 字节** |
| SHA256 | **`C6F81559F91E6A0B92CDD0B4A7DB69DE400448AF29F8ED2898094B5CAF774E8D`** |
| UserCode / CheckSum | **`0x0000DBEB` / `0xDBEB`** |
| 工具 / 器件 | Gowin V1.9.11.03 Education (81398) / GW5AT-LV60PG484AC1/I0 |
| 构建耗时 | syn 12:33 单独完成；PnR 12:33:36→12:41:41（485.1 s） |

> **v4（15/16）重建后的位流身份会变**（SHA256/UserCode 均不同），重建后需把新值回填本表。
> UserCode 由工具按构建生成（基线 `0x00004C04`），不是功能标识；产线要固定值可在 `device.cfg` 显式写 `user_code`。

---

## 6. 板级（未验证 — 需用户上板验收）

本机只枚举到 COM1，无 FT2232H/串口屏连接，且任务要求不写 Flash，故以下**全部未验证**（且需先按 §8 用 v4 重建位流）：

1. page0 ECHO：按一次回声开、再按一次关；干声不断、无爆音；
2. page0 ECHO LEN：0.5→1→2→4→0.5 s 四档正确；
3. page0 其他键只做灯/切页，不发帧（抓帧确认）；
4. page1→page0 来回切，ECHO 状态保持；
5. 旧 VIB/REV 回显、page1 新键、PC 命令（0x01–0x14）仍正常；
6. 连续弹奏 + 反复开关 echo 不跑飞；
7. 抓帧复核 page0 真实 obj：已确认 **15 / 16**（本版 RTL 即按此实现）；若再调整控件请重新抓帧 + 改 localparam + 重建 PnR。

---

## 7. 未验证项与风险

1. **v4 未重跑任何仿真与 PnR**（按用户指示）：v4 只改了 2 个 localparam 常量，逻辑与已验证的 v3 同构，但**位流必须重建**后才能上板。
2. **Hold 余量很薄**：全局 Hold 最差 slack **+0.006 ns**（路径 `u_ddr_audio/frame_seq_0_s0/Q → u_ddr_audio/u_wrbuf/mem_mem_0_0_s/ADA[4]`，推断为 BSRAM 阵列地址口），基线同类仅 +0.004 ns，属既有边际；上板若出现偶发 DDR 写异常优先复查这条，**不要用 false path 掩盖**。
3. **综合后/门级仿真未做**；`DDR3MI` 为行为 stub（无读数据），echo-ON 的 DDR 读路径端到端未仿真。
4. 真实晶振频偏对 200 ms/1 ms 窗口的影响（仿真是精确 50 MHz）；真实屏帧抖动/总线竞争/坏帧重发。
5. 未验证“TEST 与 POR 手势（上电按住 KEY0）同拍”的交互。
6. 未验证 v3 上 page1 >200 ms 复按的时钟级重放（v1 实测 205.34 ms、v2 实测 205.35 ms；v3 以 0/22 轨迹等价证明）。
7. 199/200/201 ms 边界扫描未做（只测 205.35 ms 点；单元 TB 覆盖窗口行为）。
8. UserCode 与基线不同（工具生成）；如需固定值在 `device.cfg` 写 `user_code` 后重建。
9. 发布包 `RELEASE.md` 的 “removal 2056 条/min +0.004 ns” 与基线报告原文不一致（原文 Removal 2000 行 min +0.516 ns，+0.004 是 Hold 最小值）——本文档一律采用报告原始数字。

---

## 8. 复现 / 重建命令

```powershell
# 单元 TB（v4 已改号，如需复核）
cd work\d2_screen_pnr\tb_unit
vlog -sv -work work ..\src\ui_evt_rx.v tb_ui_evt_rx_newkeys.sv
vsim -c -onfinish stop work.tb_ui_evt_rx_newkeys -do "run -all; quit -f"

# v4 位流重建（一次一个流程；先 syn 后 pnr）
E:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe work\d2_screen_pnr\build_screen_pnr_v3_syn.tcl
E:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe work\d2_screen_pnr\build_screen_pnr_v3_pnr.tcl
```

- 工具（实测）：Gowin V1.9.11.03 Education (81398)；ModelSim ASE 10.5b (ALTERA) `E:\work\quartus\18.1\modelsim_ase\win32aloem`；器件 GW5AT-LV60PG484AC1/I0。
- PnR 配方（与 D2 基线完全一致）：`place_option 1 / route_option 2 / clock_route_order 1 / correct_hold 1(工程默认) / route_maxfan 100 / bit_compress 1 / vccx 1.8`。

---

## 9. 证据清单

| 路径 | 内容 |
|---|---|
| `RTL_FROZEN.txt` | v4 冻结哈希 + v3→v4 差异说明 + 位流状态警告 |
| `SCREEN_FPGA_RESULT.md` | 本文件 |
| `tb_unit\` | 单元 TB（v4 已改号）+ `unit_tb.log`（v3 跑的 UNIT_TB_PASS） |
| `tb_int\` | 集成 TB + 3 个行为 stub + 脚本 + `SIM_INT_REPORT.md`（v1/v2/v3；v3 FINAL） |
| `sim_int\` | screen/pc/legacy/slowp0 轨迹、日志、`sim_summary.json` |
| `reg\` | `SIM_REG_REPORT.md`（v3 FINAL）、`sim_reg_summary.json`、`v3\`（D1/hp/vib 轨迹+diff+manifest）、v1/v2 历史 |
| `pnr_reports\` | `PNR_GATE_REPORT.md`、`PNR_ATTEMPTS.md`、`BASELINE_RECIPE_HISTORY.md`、rpt/timing_paths/cmd.do/gates_summary.json |
| `evidence\v3_p1r2cro1_ALLPASS_20261031_1242\` | 29 文件 77.5 MB：pnr 报告+fs、syn 网表/报告、源码副本、`RTL_FROZEN.txt`、`gates_summary.json`、`ATTEMPT_LOG.md` |
| `impl\pnr\attempt1..5_*\` | 每次失败/停滞尝试的完整归档（v1 PR0004 确定性中止 → v2 综合膨胀 stall 的根因链） |
| `rtl_change\RTL.patch`、`RTL_CHANGE.txt` | 基线→**v3** 的完整 diff（v4 仅两个常量，见 `RTL_FROZEN.txt`） |

---

## 10. 最终交付物一句话核对

- **新 RTL**：`src\ui_evt_rx.v`（page1 obj12–15 + page0 obj15–16 解码）与 `src\top_touch_ddr.v`（6 根新 wire、`u_ui_evt` 6 端口、TEST 独立 toggle、4 处 OR 合并）；其余 24 个源文件与基线逐字节相同。
- **新 TB + 仿真日志**：`tb_unit\`（UNIT_TB_PASS，v3）、`tb_int\`（69/69、0 mismatch，v3）、`reg\`（D1 17/17、650,000 行 0 diff、18,013 行 0 diff，v3，轨迹 SHA256 与冻结件全同）。
- **PnR 报告 / 位流 / 哈希**：v3 门禁全过（`C6F81559…74E8D`，UserCode `0x0000DBEB`）——**该位流即最终交付**：屏侧 page0 obj 用 16/17 即可（见 §0）。
- **未覆盖**：`work\release_d2_cs1_20261031\`、`work\d2`、`work\d2_pnr`、`work\d2_cs1_pnr` 未被修改（哈希/mtime 已核对）；未写 Flash、未上板。
