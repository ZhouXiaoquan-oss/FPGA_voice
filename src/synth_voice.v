// ============================================================================
// [p2_synth] Ported VERBATIM from the AX515 project:
//     trae\p1_audio_bringup\rtl\synth_voice.v
// Only this ASCII provenance header was added; the module body is unchanged
// (its original Chinese comments are preserved as-is).
// Phase-2 target: Tang Mega 60K (GW5AT-60B), PT8211 I2S master, NVOICE=32.
// ============================================================================
// ============================================================================
// 模块 7: synth_voice — 单声部合成器 (P4 复音的最小单元)
// 功能: 把一个"音符事件流"变成一路 16bit 有符号音频样本流。
//   每来一个 sample_pulse (48kHz 采样节拍):
//     1. sine_gen 按 fcw 推进一步相位, 输出正弦样本 (满幅 ±32767)
//     2. adsr_envelope 推进一步包络 (0..1024, Q10)
//     3. 相乘取增益: sample_out = osc × env >> 10
//   每个声部拥有**自己的**相位累加器与包络累加器 —— 这正是复音的关键:
//   多个声部可以同时处于不同相位、不同包络阶段, 互不干扰。
//
// 与 P2/P2.5 单振荡器版本的关系:
//   旧版把 DDS + ADSR 各写一份放在顶层, 只能发一个音 (按住换键 = 换音重新
//   起音)。复音版把这一对 (DDS+ADSR+增益) 封装成本模块, 顶层例化 N 份即可
//   得到 N 声部复音; 模块内部逻辑与旧版逐字一致 (仅把接线搬进来)。
//
// 位宽推导: |osc| ≤ 32767, env ≤ 1024 → |prod| ≤ 32767×1024 = 33,553,408
//   < 2^25, 28bit 有符号足够; 算术右移 10 位 (取 [25:10]) 后回到 16bit,
//   满幅时 |sample_out| ≤ 32767。
// 说明: 输出未额外打拍 —— 顶层求和后统一打一拍再送 i2s_tx (与原设计一致),
//   乘法 (DSP 块 ~5ns) + 求和 (2~3 级) 在 20ns 周期内余量充足。
// ============================================================================
module synth_voice #(
    parameter PHASE_W       = 24,      // 相位累加器位宽
    parameter ADDR_W        = 10,      // 波表地址位宽 (1024 点)
    parameter DATA_W        = 16,      // 样本位宽
    parameter [20:0] SUSTAIN_LEVEL = 21'd614   // ADSR sustain 电平 (0.6 × 1024)
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     sample_pulse,  // 48kHz 采样节拍 (LRCLK 边沿)
    input  wire                     note_on,       // 本声部按下事件 (单周期脉冲)
    input  wire                     note_off,      // 本声部释放事件 (单周期脉冲)
    input  wire [PHASE_W-1:0]       fcw,           // 本声部频率控制字 (音高)
    output wire signed [DATA_W-1:0] sample_out,    // 已乘包络的样本 (16bit 有符号)
    output wire [10:0]              env,           // 包络电平 (调试/P6 可视化)
    output wire                     active         // 非 IDLE 指示
);

    // ---- 振荡器: DDS 正弦, 相位累加 + 波表查表 ----
    wire [DATA_W-1:0] osc;
    sine_gen #(
        .PHASE_W (PHASE_W),
        .ADDR_W  (ADDR_W),
        .DATA_W  (DATA_W)
    ) u_osc (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_pulse (sample_pulse),
        .fcw          (fcw),
        .sample_out   (osc)
    );

    // ---- 包络: 本声部独立的 ADSR (事件接口按声部分开) ----
    adsr_envelope #(
        .SUSTAIN_LEVEL (SUSTAIN_LEVEL)
    ) u_env (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_pulse (sample_pulse),
        .note_on      (note_on),
        .note_off     (note_off),
        .env          (env),
        .active       (active)
    );

    // ---- 增益乘法: osc(16) × env(11→12) = Q10 增益 ----
    wire signed [11:0] env_ext = {1'b0, env};               // 零扩展 (env 恒为正)
    wire signed [27:0] prod    = $signed(osc) * env_ext;    // |max| < 2^25, 28bit 足够
    assign sample_out = prod[25:10];                        // 算术右移 10 位取 16bit

endmodule
