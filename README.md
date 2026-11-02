# TangMega-60K 实时多音色合成电子乐器引擎（FPGA 吉他音源器）

> 选题二《基于 FPGA 的实时多音色合成电子乐器引擎》· 交付版本 **v10**
> 平台：高云 **Tang Mega 60K**（GW5AT-LV60PG484AC1/I0 / GW5AT-60B）
> 本仓库只收录 **最终成品版本（v10）** 的 RTL、约束、工程、仿真与位流；历史版本与实验树不在此仓库内。

---

## 1. 交付状态（v10 · 2026-11-01）

| 项 | 值（实测） |
|---|---|
| 位流文件 | GitHub Release **[v10](https://github.com/ZhouXiaoquan-oss/FPGA_voice/releases/tag/v10)** 资产 `d2_screen_pnr.fs`（仓库内不存二进制，仅保留 SHA256 身份文件） |
| 大小 / SHA256 | **14,104,161 B** / `2E2978AE25CD2975F5EFECCAB73A461627EB3633A8045EBB52310CDB12D72962` |
| UserCode / CheckSum | **`0x0000B149`** / `0xB149` |
| PnR 门禁 | **9/9 PASS**：clk **Fmax 50.029 MHz**（约束 50.0）；setup violated **0**（min +0.012 ns）；hold violated **0**（min +0.003 ns）；recovery min +0.137 ns；removal min +0.357 ns；**无 unrouted**；CLS 25,553/29,952 |
| 资源占用 | LUT 30,867 · ALU 15,986 · FF 14,247 · BSRAM 89/118 · DSP 61/118 · I/O 65/297 |
| 烧录 | op2 烧 SRAM 成功（9.05 s，op73 回读 `0x0000B149` ✅）；op69 烧外部 Flash 成功（380.88 s） |
| 断电自举 | **待验证**（SW2=`100001` → 真断电 5 s → 上电 → `burn_v10.ps1 -VerifyOnly` 应回读 `0x0000B149`） |
| 工具链 | Gowin **V1.9.11.03 Education**（81398） |

构建配方（与定选位流一致）：`place1 / route2 / cro1 / correct_hold1（工程默认）/ maxfan100 / bit_compress1 / vccx 1.8`，CST/SDC 未改。

---

## 2. 功能一览

**信号链**：MPR121 电容键 ×12 + 板载键 ×3 → 消抖 → 32 声部并行 DDS 合成 → 混音 → 延迟 → 混响 → I2S(PT8211) → 喇叭/耳机。全链路**单时钟 50 MHz**、**零预录音、零软核、零外部 DSP**。

| 功能 | 说明 |
|---|---|
| 32 路复音 | 32 × `synth_voice` 并行（各自独立 24 bit 相位 DDS + 1024×16 波表 + ADSR），8 组×4 语音时分复用（TSMUX） |
| 3 种音色 | 正弦 / 古筝 / 笛子 |
| ADSR 包络 | 指数包络，Q10 定点，λ 移位加实现（0 DSP） |
| 4 档颤音 / 4 档滑音 | `fx_tremolo` / glide（PC `0x0F`） |
| 4 档延迟 | 30 / 45 / 60 / 150 ms 延迟线（1 块 BSRAM） |
| 混响 | 3 房间 × 4 阻尼（4 梳状 + 2 全通，6 条延迟线，0 DSP） |
| 合唱 | 0x11 开关 / 0x12 干湿 |
| DDR3 单抽头回声 | 0.5 / 1 / 2 / 4 s（`ddr3_ui_engine` + `ddr_audio_service` + `fx_ddr_echo`） |
| 串口屏 HMI | 115200 8N1，page0/page1 触摸帧解码，灯色命令按控件名称寻址 |
| 琴键灯 | MPR121 物理键 → 屏上虚拟键点亮（`key_light`，绿 2016 / 灰 33808） |
| 曲目 ROM | `song_rom` + `keys_note_ctl` 自动演奏与跟弹提示 |
| PC 串口控制 | 115200，音色/效果参数、测试模式（32 峰）等 |

### 串口屏 HMI 映射（最终版，用户 2026-11-01 确认）

- **屏 → FPGA** 触摸帧 `65 <page> <obj> 01 FF FF FF`，`<obj>` = 控件**组件 ID**
  - page1：3 滑音 4 震音 5 合唱 6 32 音测试 7 REV 8 VIB 10 音色 11 降八度 12 高八度 13 效果器 14 延迟 15 跟弹 16 选曲
  - page0：4 回声开关 5 回声换挡
- **FPGA → 屏** 灯色 `bt<k>.bco=`：12 个琴键**名称固定 `bt0..bt11`**（TJC 不能按 ID 寻址）

---

## 3. 目录结构

```
tang60k-guitar-synth/
├─ d2_screen_pnr.gprj        Gowin 工程（器件/文件清单，相对路径 src/）
├─ build.tcl                 一键构建脚本（syn + pnr 同一 gw_sh 会话）
├─ src/                      RTL + 约束（30 个文件，v10 冻结版）
│  ├─ top_touch_ddr.v        顶层（模块名 top_touch）
│  ├─ synth_voice.v sine_gen.v adsr_envelope.v voice_alloc.v keys_note_ctl.v
│  ├─ fx_delay.v fx_reverb.v fx_tremolo.v fx_chorus.v fx_ddr_echo.v
│  ├─ ddr_audio_service.v ddr3_ui_engine.v audio_cache.v audio_tap_stream.v
│  ├─ ddr_pll.v ddr3_pll_ctrl.v pll_mDRP_intf.v
│  ├─ DDR3MI_16b/DDR3MI_16b.v  DDR3 控制器 IP 源码
│  ├─ mpr121.v i2c_master.v key_light.v ui_evt_rx.v uart_rx.v uart_tx.v
│  ├─ notify_ctrl.v song_rom.v pt8211_i2s_tx.v
│  └─ d2.cst d2.sdc          引脚约束 / 时序约束
├─ mem/sine_lut.mem          1024×16 正弦波表（$readmemh 相对路径读取）
├─ sim/unit/                 v10 最终映射单元 TB + 通过日志
├─ build/                    原始 v10 构建脚本（syn / pnr / full / cmd.do / device.cfg）
├─ tools/                    burn_v10.ps1（烧录）、parse_pnr_gates.py（门禁解析）、validate_project.tcl
├─ bitstream/SHA256.txt      交付位流的身份文件（位流本体见 Release v10）
└─ docs/                     版本锚点 RTL_FROZEN.txt、交付报告 SCREEN_FPGA_RESULT.md
   └─ evidence/              门禁汇总、PnR 报告、烧录记录、建流分析
```

---

## 4. 复现构建

1. 安装 **Gowin V1.9.11.03 Education**（其他版本未验证）。
2. **在仓库根目录**执行（必须：`src/sine_gen.v` 用相对路径 `mem/sine_lut.mem`）：

```bat
"<Gowin 安装目录>\IDE\bin\gw_sh.exe" build.tcl
```

`build.tcl` 等价于原始 `build/build_screen_pnr_v10_full.tcl`，但把绝对路径改成了相对路径，并保持 syn+pnr 同一会话、同一套 PnR 参数。

3. 产物在 `impl/pnr/d2_screen_pnr.fs`（已被 `.gitignore` 忽略）。

---

## 5. 仿真验证（ModelSim ASE 10.5b）

| TB | 期望结果 | 日志 |
|---|---|---|
| `sim/unit/tb_finalmap_ui_evt.sv` | **`FINALMAP_UI_PASS`**：23 帧有效、15 个动作计数逐个正确；page1 obj2/9/17 与 page0 obj0/7/18 静默；200 ms 同键吞并；mix/room/damp = 0 | `sim/unit/finalmap_ui_evt.log` |
| `sim/unit/tb_finalmap_key_light.sv` | **`FINALMAP_KL_PASS`**：bt0/bt5/bt10/bt11，绿 2016 / 灰 33808，逐字节一致（15/16/16/17 B） | `sim/unit/finalmap_key_light.log` |

> 说明：v3 时代的集成 TB（69/69 断言）、回归（D1 17/17、650k 旁路、18,013 帧）证据保存在交付归档中，未随本仓库发布；v10 上未重跑这些用例。

---

## 6. 烧录与自举验证

```powershell
# 烧 SRAM + 外部 Flash（需 Gowin Programmer + GAO-Bridge，脚本内为原测试架绝对路径，按需修改）
powershell -File tools\burn_v10.ps1 -Execute
# 只回读校验
powershell -File tools\burn_v10.ps1 -VerifyOnly
```

- op2 → SRAM，op73 回读应为 `0x0000B149`；op69 → 外部 Flash（`Program and Verify flash successfully.`）。
- 烧后 op73 读到 `0x00000000` 属正常（GAO-Bridge 在 SRAM）。
- **自举**：SW2 设为 `100001` → 真正断开 DC 电源 5 s → 上电 → `-VerifyOnly` 回读 `0x0000B149`。

---

## 7. 版本锚点与证据

- `docs/RTL_FROZEN.txt`：v10 冻结清单与逐文件 SHA256（**判断"代码是否被改过"以它为准**）
- `docs/SCREEN_FPGA_RESULT.md`：交付报告（位流身份、门禁、HMI 映射、烧录记录）
- `docs/evidence/`：`gates_summary.json`、`d2_screen_pnr.rpt.txt`、`V10_BURN_RESULT.txt`、建流/扫描/时序分析报告
- `bitstream/SHA256.txt`：位流身份

当前 `src/` 的 5 个关键文件哈希与 `RTL_FROZEN.txt` 一致：

```
top_touch_ddr.v  229366 B  187023D6BEF2553351B48CE7F7E10B1A5C70B67D30437B4FAEB690230C6B228C
ui_evt_rx.v       15846 B  9F82377FB2841A24986205B2FF29DF6751954EAFB55C055CC8E66FFE4A7327D6
key_light.v       11486 B  7C839D6BD362F2A4ED958A8E2D26E8982AC42CDC6CF0EA04AEFBC529AAAA31A5
d2.cst            14303 B  DA1A0934E35386E0B2A40516DB60E7089848B8F7C8514321606FB088AAD8428D
d2.sdc             4509 B  B98FE342D7346FB33BCD08EE5924BB632B26427324D039BB16944B1BE6F17D2A
```

---

## 8. 已知限制

- **跟弹灯 0–9 号键名称**：v10 屏侧仍存在键名问题（`'` / `a`…`i`），屏侧规避方案待实测。
- **v10 上未复跑**：v3 时代的集成 TB（69/69）、回归（D1 17/17、650k 旁路、18,013 帧）。
- **断电自举**：见 §6，待执行确认。
- 合唱 / 滑音 / DDR3 回声在 v10 板上由用户听感确认可用，但**缺仪器/录音级证据**。

---

## 9. 说明

- 本仓库仅含 **v10 成品**；`impl/`、构建日志、实验树、历史版本（v3/v7/v9/v10a 等）均未收录。
- `.gitattributes` 关闭了行尾转换，保证源码与 `RTL_FROZEN.txt` 的 SHA256 可核对。
- 许可证：**MIT**（见 `LICENSE`，最大开放程度：可自由使用 / 修改 / 分发 / 商用，只需保留版权与许可声明）。
