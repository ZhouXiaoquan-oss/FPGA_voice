// ============================================================================
// [p2_synth] Ported VERBATIM from the AX515 project:
//     trae\p1_audio_bringup\rtl\sine_gen.v
// Only this ASCII provenance header was added; the module body is unchanged
// (its original Chinese comments are preserved as-is).
// Phase-2 target: Tang Mega 60K (GW5AT-60B), PT8211 I2S master, NVOICE=32.
// ============================================================================
// ============================================================================
// 模块 2: sine_gen — DDS 正弦波源
// 功能: 每来一个 LRCLK 边沿(sample_pulse), 计算一个正弦波样本(16bit 有符号)
// 原理: 24bit 相位累加器, 每次采样加 fcw, 取高 10bit 查 1024 点波表
// 频率: fout = fcw * fs / 2^24 (fcw 为运行时输入, 由顶层按键/提醒音选择)
//       fs = 48kHz 精确值: WM8731 主模式下由模块晶振分频得到 (教程第十七部分)
//       换算: fcw = fout * 2^24 / 48000 = fout * 349.5253
// 波表: 1024 x 16bit 有符号, 用 $readmemh 从 mem/sine_lut.mem 初始化
// ============================================================================
module sine_gen #(
    parameter PHASE_W  = 24,     // 相位累加器位宽
    parameter ADDR_W   = 10,     // 波表地址位宽 (1024 点)
    parameter DATA_W   = 16      // 输出样本位宽
)(
    input  wire               clk,           // 50MHz (或音频主时钟)
    input  wire               rst_n,
    input  wire               sample_pulse,  // LRCLK 边沿脉冲, 触发新样本
    input  wire [PHASE_W-1:0] fcw,           // 频率控制字 (运行时可选音高)
    output wire [DATA_W-1:0]  sample_out     // 16bit 有符号正弦样本
);

    // ---- 波表 ROM (1024 x 16bit) ----
    // ramstyle 属性: 强制用 M9K 块实现只读 ROM (消除 RAM 端口无驱动警告)
    (* ramstyle = "M9K" *) reg [DATA_W-1:0] lut [0:(1<<ADDR_W)-1];
    initial begin
        $readmemh("mem/sine_lut.mem", lut);
    end

    // ---- 相位累加器 ----
    reg [PHASE_W-1:0] phase_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            phase_acc <= {PHASE_W{1'b0}};
        else if (sample_pulse)
            phase_acc <= phase_acc + fcw[PHASE_W-1:0];
    end

    // ---- 查表输出 (寄存器输出, 打一拍更稳) ----
    reg [DATA_W-1:0] sample_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample_r <= {DATA_W{1'b0}};
        else
            sample_r <= lut[phase_acc[PHASE_W-1 -: ADDR_W]];
    end

    assign sample_out = sample_r;

endmodule
