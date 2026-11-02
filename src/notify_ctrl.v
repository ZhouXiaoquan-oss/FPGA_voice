// ============================================================================
// [p2_synth] Ported VERBATIM from the AX515 project:
//     trae\p1_audio_bringup\rtl\notify_ctrl.v
// Only this ASCII provenance header was added; the module body is unchanged
// (its original Chinese comments are preserved as-is).
// Phase-2 target: Tang Mega 60K (GW5AT-60B), PT8211 I2S master, NVOICE=32.
// ============================================================================
// ============================================================================
// 模块 7: notify_ctrl — AI 提醒音时序控制
// 功能: 收到触发脉冲后播放一串短音, 复用现有 ADSR 包络 (note_on/off 事件
//       脉冲驱动), 避免直接开关音频导致的咔哒声。
// 时序 (每声): note_on ──220ms── note_off ──180ms── ... ──50ms 尾延时── IDLE
//   0x01 → 2 声 (任务完成)   0x02 → 3 声 (需要用户操作, 更急促)
//   ADSR 参数 (A=10ms, D=50ms→sustain 0.6, R=200ms) 下, 每声听感约 340ms。
// 命令: cmd=0x01 → tone_sel=0 (880Hz)  cmd=0x02 → tone_sel=1 (1318Hz)
// 忙碌时新的触发被忽略 (丢弃策略, 时长 ≤ 1.1s)。
// ============================================================================
module notify_ctrl #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer BEEP_MS = 220,   // 每声发声时长
    parameter integer GAP_MS  = 180,   // 声与声之间静音时长
    parameter integer TAIL_MS = 50     // 最后一声 note_off 后的收尾延时
)(
    input  wire       clk,        // 50MHz
    input  wire       rst_n,
    input  wire       trig,       // 1 周期触发脉冲 (来自 uart_rx rx_done 且命令有效)
    input  wire [7:0] cmd,        // 与 trig 同周期的命令字节
    output reg        note_on,    // 1 周期事件脉冲 → ADSR
    output reg        note_off,   // 1 周期事件脉冲 → ADSR
    output wire       tone_sel,   // 0=880Hz 1=1318Hz (序列期间保持)
    output wire       busy        // 序列进行中 (用于频率选择/音量加重)
);

    localparam integer MS_CYC   = CLK_HZ / 1000;       // 50_000
    localparam integer BEEP_CYC = BEEP_MS * MS_CYC;    // 11_000_000
    localparam integer GAP_CYC  = GAP_MS  * MS_CYC;    // 9_000_000
    localparam integer TAIL_CYC = TAIL_MS * MS_CYC;    // 2_500_000
    // 最大计数 11M 需要 24bit
    localparam [2:0] S_IDLE = 3'd0,
                     S_BEEP = 3'd1,
                     S_GAP  = 3'd2,
                     S_TAIL = 3'd3;

    reg [2:0]  state;
    reg [23:0] cnt;
    reg        tone_r;
    reg [1:0]  beats_left;    // 剩余发声次数 (0x01=2 声, 0x02=3 声)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            cnt        <= 24'd0;
            tone_r     <= 1'b0;
            beats_left <= 2'd0;
            note_on    <= 1'b0;
            note_off   <= 1'b0;
        end else begin
            note_on  <= 1'b0;    // 默认单周期脉冲
            note_off <= 1'b0;
            case (state)
                S_IDLE:
                    // 仅接受有效命令; 忙碌期间的触发自然被忽略 (不在 IDLE)
                    if (trig && (cmd == 8'h01 || cmd == 8'h02)) begin
                        tone_r     <= (cmd == 8'h02);
                        beats_left <= (cmd == 8'h02) ? 2'd2 : 2'd1; // 首声已起, 记剩余
                        note_on    <= 1'b1;
                        cnt        <= 24'd0;
                        state      <= S_BEEP;
                    end
                S_BEEP:
                    if (cnt >= BEEP_CYC - 1) begin
                        note_off <= 1'b1;
                        cnt      <= 24'd0;
                        state    <= (beats_left == 2'd0) ? S_TAIL : S_GAP;
                        if (beats_left != 2'd0)
                            beats_left <= beats_left - 2'd1;
                    end else
                        cnt <= cnt + 24'd1;
                S_GAP:
                    if (cnt >= GAP_CYC - 1) begin
                        note_on <= 1'b1;
                        cnt     <= 24'd0;
                        state   <= S_BEEP;
                    end else
                        cnt <= cnt + 24'd1;
                S_TAIL:
                    if (cnt >= TAIL_CYC - 1)
                        state <= S_IDLE;
                    else
                        cnt <= cnt + 24'd1;
                default:
                    state <= S_IDLE;
            endcase
        end
    end

    assign tone_sel = tone_r;
    assign busy     = (state != S_IDLE);

endmodule
