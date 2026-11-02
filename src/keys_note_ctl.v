// ============================================================================
// [p2_synth] Ported VERBATIM from the AX515 project:
//     trae\p1_audio_bringup\rtl\keys_note_ctl.v
// Only this ASCII provenance header was added; the module body is unchanged
// (its original Chinese comments are preserved as-is).
// Phase-2 target: Tang Mega 60K (GW5AT-60B), PT8211 I2S master, NVOICE=32.
// ============================================================================
// ============================================================================
// 模块 6: keys_note_ctl — 按键消抖 + 每键独立音符事件 (P4 复音版)
//
// 相对 P2.5 单音版的变化 (复音的必要前提):
//   旧版做"低编号优先选音"的仲裁: 4 个键竞争**一个**振荡器, 输出单个
//   note_idx, 按住 KEY1 再按 KEY2 就变成"换音重新起音"(只有最后一个音)。
//   复音版取消仲裁 —— 每个按键各自产生按下/释放事件, 各自驱动一个独立声部,
//   因此多键同时按下 = 多个音同时发声, 互不干扰。
//
// 功能: KEY1~KEY4 (低有效) 各自消抖后输出:
//   - key_on[g]   : 该键 0→1 的单周期脉冲 (按下, 起音)
//   - key_off[g]  : 该键 1→0 的单周期脉冲 (释放, 进入 Release 淡出)
//   - key_held[g] : 消抖后电平 (1 = 该键按住)
//   - any_held    : 任一键按住 (LED 指示用)
//
// 消抖: 非对称阈值 —— 按下方向 1ms (响应快),
//   释放方向 30ms (吸收接触不良/氧化导致的瞬间断开, 旧开关必配,
//   否则按住期间接触抖断 >1ms 就触发 note_off→note_on, 听感"断断续续")
// 两级同步防亚稳态
// ============================================================================
module keys_note_ctl #(
    parameter NKEYS         = 4,
    parameter DB_ON_CYCLES  = 50_000,      // 按下判定 1ms @50MHz
    parameter DB_OFF_CYCLES = 1_500_000    // 释放判定 30ms @50MHz
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [NKEYS-1:0] key,           // 原始按键输入, 低电平=按下
    output wire [NKEYS-1:0] key_on,        // 每键按下脉冲 (起音)
    output wire [NKEYS-1:0] key_off,       // 每键释放脉冲 (淡出)
    output wire [NKEYS-1:0] key_held,      // 每键消抖后状态
    output wire             any_held       // 任一键按住
);

    // ---- 两级同步 ----
    reg [NKEYS-1:0] sync0, sync1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync0 <= {NKEYS{1'b1}};        // 空闲高 (未按下)
            sync1 <= {NKEYS{1'b1}};
        end else begin
            sync0 <= key;
            sync1 <= sync0;
        end
    end
    wire [NKEYS-1:0] key_raw = ~sync1;     // 1 = 按下

    // ---- 每键独立非对称消抖 + 边沿检测 (generate 展开) ----
    wire [NKEYS-1:0] state;
    genvar g;
    generate
        for (g = 0; g < NKEYS; g = g + 1) begin : g_deb
            reg [20:0] cnt;                // 30ms = 1.5e6 周期, 需 21bit
            reg        st;
            reg        st_d;               // 上一拍电平, 用于边沿检测
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    st   <= 1'b0;
                    st_d <= 1'b0;
                    cnt  <= 21'd0;
                end else begin
                    st_d <= st;
                    if (key_raw[g] != st) begin
                        // 需要翻转: 0→1 (按下) 用短门限, 1→0 (释放) 用长门限
                        if ((key_raw[g] && cnt >= DB_ON_CYCLES - 1) ||
                            (!key_raw[g] && cnt >= DB_OFF_CYCLES - 1)) begin
                            st  <= key_raw[g];
                            cnt <= 21'd0;
                        end else
                            cnt <= cnt + 21'd1;
                    end else
                        cnt <= 21'd0;
                end
            end
            assign state[g]   = st;
            assign key_on[g]  = st & ~st_d;    // 消抖后上升沿 = 按下
            assign key_off[g] = ~st & st_d;    // 消抖后下降沿 = 释放
        end
    endgenerate

    assign key_held = state;
    assign any_held = |state;

endmodule
