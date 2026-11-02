// ============================================================================
// [p2_synth] Ported VERBATIM from the AX515 project:
//     trae\p1_audio_bringup\rtl\adsr_envelope.v
// Only this ASCII provenance header was added; the module body is unchanged
// (its original Chinese comments are preserved as-is).
// Phase-2 target: Tang Mega 60K (GW5AT-60B), PT8211 I2S master, NVOICE=32.
// ============================================================================
// ============================================================================
// 模块 5: adsr_envelope — ADSR 包络发生器 v3 (P5 瘦身版: 常数乘法 → 移位加法)
// 功能: 逐样本(48kHz)输出 0..1024 的增益包络, 与正弦样本相乘得到音符的
//       音量轮廓。三段 (attack/decay/release) 均为"向目标指数逼近":
//         每样本 gap *= (1 - λ), 即 acc += gap×λ>>15 (gap = 到目标的余量)
//       指数形态比线性更接近真实乐器 (快起慢收), 重触发起音更有颗粒感。
//       各段时长与线性版保持一致 (对外部时序无影响, 仅形状不同)。
// 状态机: IDLE → ATTACK → DECAY → SUSTAIN → RELEASE → IDLE
//   note_on  → 从当前电平进入 ATTACK (重触发不回零, 防咔哒);
//              DECAY/SUSTAIN 中换音重触发同样回到 ATTACK
//   note_off → ATTACK/DECAY/SUSTAIN 立即转 RELEASE
// 定点表示: acc 为 Q10 (低 10 位小数), env = acc>>10, 1024 = 满幅
//   分数累加无整数量化停滞; 每段在距目标 1 LSB 内吸附到目标值
// 时长推导 (rate = -ln(1-λ/32768), 到达 1 LSB 需 n = ln(gap0)/rate):
//   ATTACK  λ=470: gap0=1024, n = ln(1024)/0.014455  =  480 样本 =  10.0ms
//   DECAY   λ= 82: gap0=410,  n = ln(410) /0.0025055 = 2401 样本 =  50.0ms
//   RELEASE λ= 36: gap0=614,  n = ln(614) /0.0010992 = 5840 样本 = 121.7ms
//                  (满幅出发 n = 6306 = 131ms; 从 sustain 出发与线性版 120ms 一致,
//                   兼容 notify_ctrl 提醒音的 50ms 收尾时序)
// 事件接口: note_on/off 是单周期脉冲, 可能落在两个采样脉冲之间,
//   用 pending 锁存到下一个 sample_pulse 消费 (边沿直达时用 ev_on 直通) —— 不丢失
//
// ----------------------------------------------------------------------------
// v3 变更 (P5 复音扩声部的前置条件): 三处 32bit×常数乘法 → 移位加法
//   WHY: 原写法每声部吃 10 个 9bit DSP (包络 8 + 增益 2), AX515 只有 112 个,
//        复音上限被 DSP 墙卡在 ~11 声部。改成移位加法后包络 DSP = 0,
//        每声部只剩增益那 2 个 → 声部上限改由 LE/BRAM 决定。
//   正确性: 与乘法**逐位等值**, 不是近似。做法是先把 λ/2^15 约分成最简形式:
//        470/2^15 = 235/2^14  (235 = 256-16-4-1, 4 项)
//         82/2^15 =  41/2^14  ( 41 =  32+ 8+1, 3 项)
//         36/2^15 =   9/2^13  (  9 =   8+ 1,   2 项)
//        分子分母同除 2 比值不变 (两边皆偶数, 整除无损), 项数从 6+3+2 降到
//        4+3+2 且移位档位低一档 → 加法器更窄更少, LE 更省。
//        舍入常数同步缩小: 16384(2^14) → 8192(2^13) / 4096(2^12),
//        因 (2N)>>15 ≡ N>>14 (N = gap×235 + 8192), 舍入行为完全一致。
//   位宽: acc 满幅 = 2^20, 故 acc/gap 都是 21bit (原 32bit 是浪费, 比较器也白宽);
//        移位前零扩展到"移位不丢位"的宽度 (Verilog 中 x<<n 的结果宽度 = x 的宽度,
//        不加宽会静默丢高位)。各中间量最大值:
//          p_a = 235×2^20 = 246,415,360 < 2^28  (29bit 装得下)
//          p_d =  41×2^21 =  85,983,232 < 2^27  (27bit, 含 gap_d 下溢时的回绕值)
//          p_r =   9×2^20 =   9,437,184 < 2^24  (24bit)
//        d_a/d_d/d_r 最大 15041/5250/1152, 21bit 足够且与 acc 同宽 (无截断警告)。
//   不变量 (保证 21bit 无符号不下溢): d_a ≤ gap_a、d_d ≤ gap_d、d_r ≤ acc
//        (λ/2^15 ≪ 1, 且各段都在距目标 1 LSB 处吸附), acc ≤ FULL = 2^20。
//   注: gap_d = acc - SUSTAINQ 在非 DECAY 段会下溢回绕 (与 v2 的 32bit 乘法
//       同样发生), 但 d_d 只在 S_DEC 被消费, 而 S_DEC 中 acc ≥ SUSTAINQ 恒成立,
//        故回绕值永不参与运算 —— 行为与 v2 完全一致。
// ============================================================================
module adsr_envelope #(
    parameter [20:0] SUSTAIN_LEVEL = 21'd614   // 0.6 × 1024 (P3 力度调控的入口)
)(
    input  wire        clk,          // 50MHz
    input  wire        rst_n,        // 复位, 低有效
    input  wire        sample_pulse, // 48kHz 采样节拍 (LRCLK 边沿脉冲)
    input  wire        note_on,      // 按下事件脉冲
    input  wire        note_off,     // 松开事件脉冲
    output wire [10:0] env,          // 包络增益 0..1024 (Q10)
    output wire        active        // 非 IDLE 指示 (调试/P6 可视化预留)
);

    localparam [2:0] S_IDLE = 3'd0,
                     S_ATK  = 3'd1,
                     S_DEC  = 3'd2,
                     S_SUS  = 3'd3,
                     S_REL  = 3'd4;

    localparam [20:0] FULL     = 21'd1024 << 10;          // 满幅 1.0 (Q10) = 1048576
    // SUSTAIN_LEVEL 声明成 21bit 参数: 移位在 21bit 内完成, 不会触发 10230 截断警告
    localparam [20:0] SUSTAINQ = SUSTAIN_LEVEL << 10;     // sustain 电平 (Q10)

    reg [2:0]  state;
    reg [20:0] acc;              // Q10 包络累加器, env = acc >> 10 (满幅 2^20, 21bit 足够)
    reg        on_pending, off_pending;

    // ---- 事件锁存: 脉冲可能落在两个采样节拍之间, 锁存待消费 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            on_pending  <= 1'b0;
            off_pending <= 1'b0;
        end else begin
            if (note_on)  on_pending  <= 1'b1;
            if (note_off) off_pending <= 1'b1;
            if (sample_pulse) begin    // 状态机本拍消费, 清锁存
                on_pending  <= 1'b0;
                off_pending <= 1'b0;
            end
        end
    end

    // 同拍直达: 事件脉冲与 sample_pulse 同一时钟沿到来时不经锁存直接生效
    wire ev_on  = on_pending  | note_on;
    wire ev_off = off_pending | note_off;

    // ---- 指数步进: delta = round(gap × λ / 2^15) (Q10), 移位加法实现 ----
    // +半 LSB 舍入中心化: 纯 floor 会有系统性负偏差 (每步丢 ~0.5),
    //   λ 越小尾巴爬行越明显 (decay 实测 +4%, release +9%)
    wire [20:0] gap_a = FULL - acc;          // ATTACK: 到满幅的余量 (恒 ≥ 0)
    wire [20:0] gap_d = acc - SUSTAINQ;      // DECAY: 到 sustain 的余量 (仅 S_DEC 使用)
    wire [20:0] gap_r = acc;                 // RELEASE: 到 0 的余量 = acc 本身

    // 零扩展: 移位结果宽度 = 操作数宽度, 先加宽再移位才不会丢高位
    wire [28:0] gx_a = {8'd0,  gap_a};       // 29bit (x<<8 ≤ 2^28)
    wire [26:0] gx_d = {6'd0,  gap_d};       // 27bit (x<<5 ≤ 2^26)
    wire [23:0] gx_r = {3'd0,  gap_r};       // 24bit (x<<3 ≤ 2^23)

    wire [28:0] p_a = (gx_a << 8) - (gx_a << 4) - (gx_a << 2) - gx_a;  // ×235
    wire [26:0] p_d = (gx_d << 5) + (gx_d << 3) + gx_d;                // ×41
    wire [23:0] p_r = (gx_r << 3) + gx_r;                              // ×9

    // 舍入 + 右移: 中间量按表达式宽度声明, 再显式取低 21 位
    //   (显式位选而非隐式截断 —— 后者会触发 Quartus 10230 警告;
    //    值域已推导: 三者分别 ≤ 15041 / 5250 / 1152, 取低 21 位不丢任何有效位)
    wire [28:0] q_a = (p_a + 29'd8192) >> 14;   // round(gap_a × 470 / 2^15)
    wire [26:0] q_d = (p_d + 27'd8192) >> 14;   // round(gap_d ×  82 / 2^15)
    wire [23:0] q_r = (p_r + 24'd4096) >> 13;   // round(acc   ×  36 / 2^15)

    wire [20:0] d_a = q_a[20:0];
    wire [20:0] d_d = q_d[20:0];
    wire [20:0] d_r = q_r[20:0];

    // ---- 包络状态机 (每采样节拍推进一步) ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            acc   <= 21'd0;
        end else if (sample_pulse) begin
            case (state)
                S_IDLE:
                    if (ev_on)
                        state <= S_ATK;            // acc 保持当前值 (IDLE=0)
                S_ATK:
                    if (ev_off)
                        state <= S_REL;            // 起音中松手 → 从当前电平释放
                    else if (gap_a <= 21'd1024) begin
                        acc   <= FULL;             // 1 LSB 内吸附, 精确 480 样本
                        state <= S_DEC;
                    end else
                        acc <= acc + d_a;
                S_DEC:
                    if (ev_on)
                        state <= S_ATK;            // 换音重触发 → 重新起音
                    else if (ev_off)
                        state <= S_REL;
                    else if (gap_d <= 21'd1024) begin
                        acc   <= SUSTAINQ;         // 吸附到 sustain 电平
                        state <= S_SUS;
                    end else
                        acc <= acc - d_d;
                S_SUS:
                    if (ev_on)
                        state <= S_ATK;            // 换音重触发
                    else if (ev_off)
                        state <= S_REL;            // 电平保持不变
                S_REL:
                    if (ev_on)
                        state <= S_ATK;            // 释放中重按 → 从当前电平再起音
                    else if (acc <= 21'd1024) begin
                        acc   <= 21'd0;            // 吸附到 0
                        state <= S_IDLE;
                    end else
                        acc <= acc - d_r;
                default:
                    state <= S_IDLE;
            endcase
        end
    end

    assign env    = acc[20:10];
    assign active = (state != S_IDLE);

endmodule
