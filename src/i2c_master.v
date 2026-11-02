// ============================================================================
// [p6_touch] i2c_master.v
// 单字节事务 I2C 主机 (Verilog-2001, 可仿真)
// ----------------------------------------------------------------------------
// 事务序列 (本模块支持的全部事务):
//   写: S + Addr+W + ACK + Reg + ACK + Data + ACK + P
//   读: S + Addr+W + ACK + Reg + ACK + Sr + Addr+R + ACK + Data + NACK + P
//   地址字节 = {cmd_addr[6:0], rw}, rw: 0=W, 1=R
// ----------------------------------------------------------------------------
// 命令接口:
//   cmd_start 为 1 周期脉冲; 仅在 S_IDLE 受理, 事务期间自动忽略 (busy 门控)。
//   cmd_op/cmd_addr/cmd_reg/cmd_wdata 在 cmd_start 当拍被锁存, 上层无需保持。
//   cmd_done 为 1 周期脉冲; cmd_ack_err 与 cmd_done 同周期有效 (本事务出现过 NACK)。
//   事务中任何 NACK 只置位 ack_err_latch, 不中断流程, 一律走完 STOP。
// ----------------------------------------------------------------------------
// 物理层:
//   scl 推挽输出, 空闲为高; 事务内 SCL 周期恒定 = DIV 个 clk (无时钟拉伸)。
//   sda 开漏: 全模块只有一行 assign 驱动 sda, 且只输出 1'b0 / 1'bz。
// ----------------------------------------------------------------------------
// 时序网格 (hcnt 为半位计数器, 每 HCNT_STEP 个 clk 走一步):
//   hcnt ∈ [0 , 124] → scl = 1
//   hcnt ∈ [125, 249] → scl = 0
//   hcnt == H_SDA_CHG    (185) → 数据位改 SDA (SCL 低电平中心)
//   hcnt == H_SDA_SAMPLE (60)  → 采样 SDA   (SCL 高电平中心)
//   hcnt 走满一圈 = HALF * HCNT_STEP = DIV = 500 clk = 一个 SCL 周期 (100kHz@50MHz)
//
//   START / Sr / STOP 的本质是"SCL 高电平期间 SDA 跳变", 因此这三个条件的 SDA
//   边沿落在 SCL 高电平相位点 H_SDA_SAMPLE(60) 上 (同一张网格), 其余数据位一律
//   落在 H_SDA_CHG(185) 上。这样 SCL 全程连续, 相邻上升沿恒为 500 clk。
//     START : SCL 高时 SDA 1→0  (S_START_SETUP)
//     Sr    : 同上, 复用 S_START_SETUP; 且先放完 ACK 位的 SCL 下降沿 (S_RS_START)
//     STOP  : SCL 低时 SDA 拉低建立 (hcnt==185), SCL 高时 SDA 0→1 (hcnt==60)
// ----------------------------------------------------------------------------
// 位序: **MSB first** —— I2C 规范硬性要求 (NXP UM10204; MPR121 Rev4 §5.1):
//   地址字节按 A6..A0 再 R/W 的顺序高位先发; 收/发一律以 bit_idx=0 对应字节最高位。
//   (L2 第 1 次评审裁定: 原工单 "LSB first" 系笔误, 更正为 MSB first。)
// ============================================================================
`default_nettype none

module i2c_master #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer I2C_HZ = 100_000
)(
    input  wire       clk,          // 50MHz
    input  wire       rst_n,        // 异步复位, 低有效
    // 命令接口 (cmd_start 为 1 周期脉冲, 事务期间 cmd_start 将被忽略)
    input  wire       cmd_start,
    input  wire       cmd_op,       // 0=写, 1=读
    input  wire [6:0] cmd_addr,     // 7位从机地址
    input  wire [7:0] cmd_reg,      // 寄存器地址 (8位子地址)
    input  wire [7:0] cmd_wdata,    // 写数据
    output reg  [7:0] rx_data,      // 读事务收到的字节
    output reg        cmd_done,     // 1 周期脉冲: 事务结束 (含 ACK 错误结束)
    output reg        cmd_ack_err,  // cmd_done 同周期有效: 事务中出现过 NACK
    // I2C 物理层
    output reg        scl,          // 推挽输出
    inout  wire       sda           // 开漏: 内部只驱动 1'b0 或 1'bz
);

    // ------------------------------------------------------------------
    // 位定时参数 (只由 CLK_HZ / I2C_HZ 推导)
    // ------------------------------------------------------------------
    localparam integer DIV       = CLK_HZ / I2C_HZ;   // 500: 一个 SCL 周期的 clk 数
    localparam integer HALF      = DIV / 2;           // 250: 半个 SCL 周期的 clk 数
    localparam integer HCNT_MAX  = HALF - 1;          // 249: hcnt 计数上限
    localparam integer HCNT_STEP = DIV / HALF;        // 2  : hcnt 每步占用的 clk 数

    // SCL 相位网格 (hcnt 单位)
    localparam integer SCL_HIGH_STEPS = HALF / 2;                                     // 125: [0,124] 为高
    localparam integer H_MARGIN       = 2;                                            // 相位中心再偏左的裕量
    localparam integer H_SDA_SAMPLE   = (SCL_HIGH_STEPS / 2) - H_MARGIN;              // 60 : 采样点
    localparam integer H_SDA_CHG      = ((SCL_HIGH_STEPS + HCNT_MAX) / 2) - H_MARGIN; // 185: 改 SDA 点

    // ------------------------------------------------------------------
    // 状态编码 (Moore, localparam)
    // ------------------------------------------------------------------
    localparam [3:0] S_IDLE        = 4'd0,
                     S_START_SETUP = 4'd1,
                     S_ADDR_WR     = 4'd2,
                     S_ADDR_WR_ACK = 4'd3,
                     S_REG         = 4'd4,
                     S_REG_ACK     = 4'd5,
                     S_DATA        = 4'd6,
                     S_DATA_ACK    = 4'd7,
                     S_RS_START    = 4'd8,
                     S_ADDR_RD     = 4'd9,
                     S_ADDR_RD_ACK = 4'd10,
                     S_RX_DATA     = 4'd11,
                     S_RX_NACK     = 4'd12,
                     S_STOP_SETUP  = 4'd13,
                     S_STOP_HOLD   = 4'd14;

    // ------------------------------------------------------------------
    // SDA 开漏驱动 (全模块唯一驱动 sda 的地方)
    // ------------------------------------------------------------------
    reg sda_drive_low;
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    // ------------------------------------------------------------------
    // SDA 输入两级同步 (亚稳态防护, 写法同 uart_rx.v)
    // ------------------------------------------------------------------
    reg [1:0] sda_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sda_sync <= 2'b11;                  // 空闲电平为高
        else
            sda_sync <= {sda_sync[0], sda};
    end

    wire sda_s = sda_sync[1];

    // ------------------------------------------------------------------
    // 内部寄存器
    // ------------------------------------------------------------------
    reg [3:0]  state;          // 当前状态
    reg [8:0]  hcnt;           // 半位计数器 0..HCNT_MAX
    reg        pre;            // HCNT_STEP 预分频
    reg [3:0]  bit_idx;        // 字节位序号 0..7, 8 = 释放/ACK 槽
    reg [7:0]  tx_byte;        // 当前要发送的字节
    reg        ack_err_latch;  // 本事务出现过 NACK
    reg        stop_sda_low;   // STOP 的 SDA 已拉低 (建立完成)
    reg [15:0] hold_cnt;       // S_STOP_HOLD 计时
    reg        start_req;      // 已收到命令, 等待总线释放
    reg        second_start;   // 1 = 当前 START 是重复起始 Sr
    reg        op_r;           // 锁存的 cmd_op
    reg [6:0]  addr_r;         // 锁存的 cmd_addr
    reg [7:0]  reg_r;          // 锁存的 cmd_reg
    reg [7:0]  wdata_r;        // 锁存的 cmd_wdata

    // ------------------------------------------------------------------
    // 网格事件
    // hcnt 每个值停留 HCNT_STEP 个 clk, 用 pre 限定保证每个网格点只动作一次
    // ------------------------------------------------------------------
    wire tick_chg = (hcnt == H_SDA_CHG)    && (pre == 1'b1);   // 185: 改 SDA (SCL 低)
    wire tick_smp = (hcnt == H_SDA_SAMPLE) && (pre == 1'b1);   // 60 : 采 SDA / START / STOP
    wire tick_zer = (hcnt == 9'd0)         && (pre == 1'b1);   // 相位起点

    // ------------------------------------------------------------------
    // SCL 输出 (Moore): 全模块只有这一处决定 scl 的下一拍取值,
    // 避免同一拍对 scl 多次赋值 (否则 VCD 会记出假的 0/1 抖动)
    //   S_IDLE / S_START_SETUP / S_STOP_HOLD → 强制高 (空闲 / START / 停止保持)
    //   其余状态 → 按相位网格
    // ------------------------------------------------------------------
    reg scl_moore;

    always @(*) begin
        case (state)
            S_IDLE, S_START_SETUP, S_STOP_HOLD: scl_moore = 1'b1;
            default:                            scl_moore = (hcnt < SCL_HIGH_STEPS) ? 1'b1 : 1'b0;
        endcase
    end

    // ------------------------------------------------------------------
    // 主状态机
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            hcnt          <= 9'd0;
            pre           <= 1'b0;
            bit_idx       <= 4'd0;
            tx_byte       <= 8'd0;
            ack_err_latch <= 1'b0;
            stop_sda_low  <= 1'b0;
            hold_cnt      <= 16'd0;
            start_req     <= 1'b0;
            second_start  <= 1'b0;
            op_r          <= 1'b0;
            addr_r        <= 7'd0;
            reg_r         <= 8'd0;
            wdata_r       <= 8'd0;
            sda_drive_low <= 1'b0;
            scl           <= 1'b1;
            rx_data       <= 8'd0;
            cmd_done      <= 1'b0;
            cmd_ack_err   <= 1'b0;
        end else begin
            // ---- 默认输出 ----
            cmd_done    <= 1'b0;                    // 默认单周期脉冲
            cmd_ack_err <= 1'b0;

            // ---- 预分频 / hcnt ----
            pre <= ~pre;
            if (pre == 1'b1)
                hcnt <= (hcnt == HCNT_MAX) ? 9'd0 : (hcnt + 9'd1);

            // ---- SCL: Moore 输出, 单一赋值 ----
            scl <= scl_moore;

            case (state)

                // ---------------- 空闲 ----------------
                S_IDLE: begin
                    hcnt          <= 9'd0;      // 空闲清零, 保证 START 建立时间确定
                    sda_drive_low <= 1'b0;
                    stop_sda_low  <= 1'b0;
                    hold_cnt      <= 16'd0;
                    bit_idx       <= 4'd0;
                    // 命令锁存
                    if (cmd_start == 1'b1) begin
                        op_r          <= cmd_op;
                        addr_r        <= cmd_addr;
                        reg_r         <= cmd_reg;
                        wdata_r       <= cmd_wdata;
                        start_req     <= 1'b1;
                        second_start  <= 1'b0;
                        ack_err_latch <= 1'b0;  // 新事务清除错误标志
                    end
                    // 上拉等待: SDA 释放为高后才发 START (超时不管)
                    if ((start_req == 1'b1) && (sda_s == 1'b1)) begin
                        start_req <= 1'b0;
                        state     <= S_START_SETUP;
                    end
                end

                // ---------------- START / Sr ----------------
                // SCL 保持高, 在 hcnt==60 拉低 SDA → START (Sr 复用本状态);
                // 随后 SCL 在 hcnt==125 正常下降, 新字节首位在 hcnt==185 建立
                S_START_SETUP: begin
                    if (tick_smp == 1'b1) begin
                        sda_drive_low <= 1'b1;                       // SCL 高时 SDA 下降 = START/Sr
                        tx_byte       <= second_start ? {addr_r, 1'b1} : {addr_r, 1'b0};
                        bit_idx       <= 4'd0;
                        state         <= second_start ? S_ADDR_RD : S_ADDR_WR;
                    end
                end

                // ---------------- 字节发送 (写字节态公共位引擎) ----------------
                // 每一位: hcnt==185 驱动, 下一周期 SCL 上升沿由从机采样;
                // 8 位发完后的下一个 hcnt==185 释放 SDA, 交出第 9 位给从机 ACK
                S_ADDR_WR, S_ADDR_RD, S_REG, S_DATA: begin
                    if (tick_chg == 1'b1) begin
                        if (bit_idx == 4'd8) begin
                            sda_drive_low <= 1'b0;                   // 释放 SDA, 从机回 ACK
                            bit_idx       <= 4'd0;
                            case (state)
                                S_ADDR_WR: state <= S_ADDR_WR_ACK;
                                S_ADDR_RD: state <= S_ADDR_RD_ACK;
                                S_REG:     state <= S_REG_ACK;
                                S_DATA:    state <= S_DATA_ACK;
                                default:   state <= S_IDLE;
                            endcase
                        end else begin
                            sda_drive_low <= ~tx_byte[4'd7 - bit_idx];  // MSB first: 0 → 拉低
                            bit_idx       <= bit_idx + 4'd1;
                        end
                    end
                end

                // ---------------- ACK 采样 ----------------
                // 第 9 个时钟的高电平中心采样: 0=ACK, 1=NACK
                S_ADDR_WR_ACK, S_REG_ACK, S_DATA_ACK, S_ADDR_RD_ACK: begin
                    if (tick_smp == 1'b1) begin
                        if (sda_s == 1'b1)
                            ack_err_latch <= 1'b1;                   // NACK: 记录但不中断
                        case (state)
                            // 子地址字节: 装载 cmd_reg
                            S_ADDR_WR_ACK: begin
                                tx_byte <= reg_r;
                                state   <= S_REG;
                            end
                            // 写: 装载 cmd_wdata; 读: 转重复起始
                            S_REG_ACK: begin
                                if (op_r == 1'b1) begin
                                    state <= S_RS_START;
                                end else begin
                                    tx_byte <= wdata_r;
                                    state   <= S_DATA;
                                end
                            end
                            S_DATA_ACK:    state <= S_STOP_SETUP;
                            S_ADDR_RD_ACK: state <= S_RX_DATA;
                            default:       state <= S_STOP_SETUP;
                        endcase
                    end
                end

                // ---------------- 重复起始准备 ----------------
                // 先让 ACK 位的 SCL 下降沿走完 (从机在此释放 SDA 为高),
                // 下一周期再由 S_START_SETUP 发 Sr, 保证总线上有真实的 SDA 下降沿
                S_RS_START: begin
                    if (tick_zer == 1'b1) begin
                        second_start <= 1'b1;
                        bit_idx      <= 4'd0;
                        state        <= S_START_SETUP;
                    end
                end

                // ---------------- 读数据采样 ----------------
                // 主机释放 SDA, 8 位 MSB first 在高电平中心采样
                S_RX_DATA: begin
                    sda_drive_low <= 1'b0;
                    if (tick_smp == 1'b1) begin
                        rx_data[4'd7 - bit_idx] <= sda_s;
                        if (bit_idx == 4'd7) begin
                            bit_idx <= 4'd0;
                            state   <= S_RX_NACK;
                        end else begin
                            bit_idx <= bit_idx + 4'd1;
                        end
                    end
                end

                // ---------------- 读末位 NACK ----------------
                // 第 9 个时钟主机保持 SDA 高 (释放) = NACK
                S_RX_NACK: begin
                    sda_drive_low <= 1'b0;
                    if (tick_smp == 1'b1)
                        state <= S_STOP_SETUP;
                end

                // ---------------- STOP 建立 ----------------
                // hcnt==185 (SCL 低) 拉低 SDA 建立; 下一周期 hcnt==60 (SCL 高) 释放 SDA = STOP
                S_STOP_SETUP: begin
                    if (tick_chg == 1'b1) begin
                        sda_drive_low <= 1'b1;                       // SCL 低: 拉低 SDA (建立)
                        stop_sda_low  <= 1'b1;
                    end else if ((tick_smp == 1'b1) && (stop_sda_low == 1'b1)) begin
                        sda_drive_low <= 1'b0;                       // SCL 高: SDA 0→1 = STOP
                        hold_cnt      <= 16'd0;
                        state         <= S_STOP_HOLD;
                    end
                end

                // ---------------- STOP 保持 / 收尾 ----------------
                S_STOP_HOLD: begin
                    sda_drive_low <= 1'b0;
                    if (hold_cnt >= (DIV - 1)) begin
                        state       <= S_IDLE;
                        cmd_done    <= 1'b1;                         // 1 周期脉冲
                        cmd_ack_err <= ack_err_latch;                // 与 cmd_done 同周期
                    end else begin
                        hold_cnt <= hold_cnt + 16'd1;
                    end
                end

                // ---------------- 兜底 ----------------
                default: begin
                    state         <= S_IDLE;
                    sda_drive_low <= 1'b0;
                end

            endcase
        end
    end

endmodule

`default_nettype wire
