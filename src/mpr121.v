// ============================================================================
// [p6_touch] mpr121.v
// MPR121 电容触摸控制器驱动: 上电初始化 + 12 电极 5ms 轮询
// ----------------------------------------------------------------------------
// 层次结构:
//   mpr121 (本模块 = 编排层)  --例化-->  i2c_master (物理层 / 单字节事务)
//   本模块只做 "发一拍 cmd_start  ->  等 cmd_done  ->  取 rx_data/cmd_ack_err"
//   的编排, 不产生任何 I2C 时序 (SCL/SDA 全部由 i2c_master 驱动)。
// ----------------------------------------------------------------------------
// 依赖接口契约 (SubTask-002-A, 见 i2c_master.v):
//   cmd_start  1 周期脉冲; 仅在 i2c_master 空闲时受理
//   cmd_op     0=写 / 1=读
//   cmd_addr   7 位从机地址
//   cmd_reg    8 位子地址 (寄存器地址)
//   cmd_wdata  写数据
//   cmd_done   1 周期脉冲 (事务结束)
//   cmd_ack_err 与 cmd_done 同周期有效 (本事务出现过 NACK)
//   rx_data    读事务收到的字节
//
// ★ 绑定的依赖基线 (L2 裁决单已钉住, 不得漂移):
//   i2c_master.v  sha256 = 7D63677B48AD5E48F6140FEC4101AE78483BB3A7288E315A061B771F824AC3CD
//   该版本收发均为 MSB first (I2C 合规)。已由独立总线探针实测确认:
//     无 slave 时首字节线上位序 = 1,0,1,1,0,1,0,0, 按 MSB first 解出 0xB4 = {7'h5A,1'b0};
//     ACK 槽 = 1 = NACK。
//   本模块 + 本模块的 smoke TB 都以 MSB first 为前提。若 i2c_master 被回退成 LSB first
//   (例如 .workbuddy\revert\ 下的 72E52FD1 版本), TB 内 MSB first 从机模型会全地址
//   NACK, 初始化必然 init_fail -> T1 判据直接 FAIL (自证式版本守卫)。
// ----------------------------------------------------------------------------
// 初始化序列 (工单步骤 1~8):
//   1) 扫地址 0x5A/0x5B/0x5C/0x5D -> 找首个 ACK -> 锁存 dev_addr
//   2) 软复位 写 0x80 <- 0x63, 之后延时 >= 1ms
//   3) 校验   读 0x5C 期望 0x10; 读 0x5D 期望 0x24 (任一不符 -> init_fail)
//   4)~6) 36 项配置写 (清单见下)
//   7) 进 Run 写 0x5E <- 0x8C (本序列最后一次写)
//   8) 轮询   每 5ms 读 0x00、0x01 -> touch[11:0] = {ts01[3:0] & 4'hF, ts00}
// ----------------------------------------------------------------------------
// 硬约束 (事实卡 §5, 逐条落实):
//   - 步骤 4~6 的写全部在 Stop Mode 下发出 (此刻 ECR=0, 天然满足);
//     ECR(0x5E) 是本序列最后一次写。
//   - 不做 AUTO-CONFIG: 0x7B~0x7F 一律不写 (复位默认 ACE=0, 永不运行)。
//   - 0x01 的 bit7(OVCF) 与 bit4(ELEPROX) 都不进入 touch (右端显式掩码)。
// ----------------------------------------------------------------------------
// 16 进制常量 = "0x" 前缀; 全部时序常数为手写十进制字面量 (按 CLK_HZ=50MHz 推导,
//   禁 $clog2 / 禁运行时除法):
//     轮询周期 250_000 clk (5.000ms, 18bit 计数)
//     复位后等待 50_000 clk (1.000ms, 16bit 计数)
//     扫描失败重试间隔 50_000 clk (1.000ms, 16bit 计数)
// ----------------------------------------------------------------------------
// ★ L3 实现选择 (工单未指定, 已在 36 项之外单独标注, 供 L2 复核/否决):
//   M_SCAN 的地址探测采用 **读事务**: 读只读寄存器 0x00 (触摸状态)。
//   理由: 读事务的首字节同为 Addr+W, 满足工单 "各发一次 Addr+W 找首个 ACK" 判据;
//         且读 0x00 无任何副作用 (手册 §5.1: 寄存器读可在 Run/Stop 任意时刻进行),
//         而写探测会留下寄存器副作用。器件地址 NACK 时 cmd_ack_err=1, 判据等价。
// ----------------------------------------------------------------------------
// W5 (Task-017, 2026-10-23): SubTask-012-A 的 ELE5 力度采集已整段删除。
//   删除内容: 每轮的 0x0E / 0x0F / 0x23 三笔读、M_POLL_FLO / M_POLL_FHI /
//   M_POLL_BASE / M_FORCE_EVAL 四个状态、force / force_sat / force_valid 三个
//   端口、守卫与提交逻辑。012 已由 L1 关闭且没有生产力度曲线, 这些输出在交付
//   配置下本就无人使用; 删除后每轮轮询恢复为最初的 0x00 / 0x01 两笔读。
// ============================================================================
`default_nettype none

module mpr121 #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer I2C_HZ = 100_000
)(
    input  wire        clk,        // 50MHz
    input  wire        rst_n,      // 异步复位, 低有效
    output reg  [11:0] touch,      // 高有效电平: touch[7:0]=ELE0..ELE7, touch[11:8]=ELE8..ELE11
    output reg         init_ok,    // 电平: 初始化完成后置 1, 保持 (sticky)
    output reg         init_fail,  // 电平: 初始化失败后置 1, 保持 (sticky); 同时进入重扫
    output wire        scl,        // I2C 时钟 (由 i2c_master 推挽驱动)
    inout  wire        sda         // I2C 数据 (开漏)
);

    // ========================================================================
    // 初始化配置表 (36 项)
    //   L2 2026-10-09 裁决单更正: 滤波 11 + 去抖 1 + 阈值 24 = 36, cfg_idx 0..35。
    //   (原工单 "滤波9 / 共34项 / cfg_idx 0..30" 系计数笔误; 地址与数值未变。)
    //   来源: MPR121 Rev4 手册 §5.5 (0x2B~0x35) / §5.7 (0x5B) / §5.6 (0x41~0x5A)
    //         + AN3892 P7 去抖示例; 数值由 L2 核定, L3 照抄, 未自行查改。
    //
    //   idx  addr  data   含义 (手册字段名)
    //   ---  ----  ----   ------------------------------------------------------
    //     0  0x2B  0x01   MHD_R  上升最大半量
    //     1  0x2C  0x01   NHD_R  上升噪声半量
    //     2  0x2D  0x00   NCL_R  上升噪声计数限
    //     3  0x2E  0x00   FDL_R  上升滤波延迟计数限
    //     4  0x2F  0x01   MHD_F  下降最大半量
    //     5  0x30  0x01   NHD_F  下降噪声半量
    //     6  0x31  0x24   NCL_F  下降噪声计数限
    //     7  0x32  0x24   FDL_F  下降滤波延迟计数限
    //     8  0x33  0x01   NHD_T  触发态噪声半量 (触发态无 MHD_T)
    //     9  0x34  0x00   NCL_T  触发态噪声计数限
    //    10  0x35  0x00   FDL_T  触发态滤波延迟计数限
    //    11  0x5B  0x21   去抖 DR=4 / DT=1   (W1b: DT 2->1, 触摸更快生效)
    //    12  0x41  0x0F   ELE0_T  触发阈值
    //    13  0x42  0x0A   ELE0_R  释放阈值
    //    ...  (每电极 2 项: 奇序号=Touch=0x0F, 偶序号=Release=0x0A)
    //    34  0x57  0x0F   ELE11_T 触发阈值
    //    35  0x58  0x0A   ELE11_R 释放阈值
    //
    //   idx 12..35: addr = 0x41 + (idx-12);  data = idx 偶 ? 0x0F : 0x0A
    //   注: ELEPROX 阈值 0x59/0x5A 不写 (ECR=0x8C 中 ELEPROX_EN=00, 接近检测关闭)。
    // ========================================================================

    // ------------------------------------------------------------------
    // 时序常数 (手写, 禁 $clog2)
    // ------------------------------------------------------------------
    localparam [17:0] POLL_DIV   = 18'd250_000;   // 轮询周期 5.000ms @50MHz (18bit)
    localparam [15:0] RESET_WAIT = 16'd50_000;    // 软复位后延时 1.000ms @50MHz (16bit)
    localparam [15:0] RETRY_WAIT = 16'd50_000;    // 扫描失败重试间隔 1.000ms (16bit)

    // 配置项数 / 扫描地址数
    localparam [5:0]  CFG_LAST   = 6'd35;         // 36 项: cfg_idx 0..35
    localparam [1:0]  SCAN_LAST  = 2'd3;          // 0x5A..0x5D 共 4 个候选

    // ------------------------------------------------------------------
    // 寄存器地址 / 期望值 (全部取自工单核定表与手册)
    // ------------------------------------------------------------------
    localparam [7:0] REG_TS1     = 8'h00;   // 触摸状态低: ELE0..ELE7
    localparam [7:0] REG_TS2     = 8'h01;   // 触摸状态高: (OVCF)(-)(-)(ELEPROX)ELE11..ELE8
    localparam [7:0] REG_SRST    = 8'h80;   // 软复位寄存器
    localparam [7:0] SRST_KEY    = 8'h63;   // 软复位写入值
    localparam [7:0] REG_AFE1    = 8'h5C;   // Filter/Global CDC 配置 (复位默认 0x10)
    localparam [7:0] REG_AFE2    = 8'h5D;   // Filter/Global CDT 配置 (复位默认 0x24)
    localparam [7:0] REG_ECR     = 8'h5E;   // 电极配置寄存器 (Run/Stop)
    localparam [7:0] AFE1_EXP    = 8'h10;   // 0x5C 期望读回值
    localparam [7:0] AFE2_EXP    = 8'h24;   // 0x5D 期望读回值
    localparam [7:0] ECR_RUN_VAL = 8'h8C;   // CL=10, ELEPROX_EN=00, ELE_EN=1100 (12 电极 Run)
    localparam [6:0] ADDR_BASE   = 7'h5A;   // ADDR 接 VSS 时的默认地址

    // ------------------------------------------------------------------
    // 状态编码 (Moore, localparam)
    // ------------------------------------------------------------------
    localparam [4:0] M_SCAN         = 5'd0,
                     M_SCAN_WAIT    = 5'd1,
                     M_RESET        = 5'd2,
                     M_RESET_WAIT   = 5'd3,
                     M_RD_AFE1      = 5'd4,
                     M_RD_AFE1_WAIT = 5'd5,
                     M_RD_AFE2      = 5'd6,
                     M_RD_AFE2_WAIT = 5'd7,
                     M_CFG_WRITE    = 5'd8,
                     M_ECR_RUN      = 5'd9,
                     M_POLL_WAIT    = 5'd10,
                     M_POLL_LO      = 5'd11,
                     M_POLL_HI      = 5'd12,
                     M_FAIL_WAIT    = 5'd13;

    // ------------------------------------------------------------------
    // 发给 i2c_master 的命令
    // ------------------------------------------------------------------
    reg        cmd_start;
    reg        cmd_op;
    reg  [6:0] cmd_addr;
    reg  [7:0] cmd_reg;
    reg  [7:0] cmd_wdata;

    // i2c_master 回读
    wire [7:0] rx_data;
    wire       cmd_done;
    wire       cmd_ack_err;

    // ------------------------------------------------------------------
    // 内部寄存器
    // ------------------------------------------------------------------
    reg  [4:0]  state;       // 当前状态
    reg  [6:0]  dev_addr;    // 扫描命中后锁存的 7 位从机地址
    reg  [1:0]  scan_idx;    // 扫描候选序号 0..3 -> 0x5A..0x5D
    reg  [5:0]  cfg_idx;     // 配置项序号 0..35
    reg         cmd_phase;   // 多拍命令(配置/ECR/轮询)子步: 0=发命令 1=等 cmd_done
    reg         rst_dly;     // M_RESET_WAIT 子步: 0=等事务完成 1=延时 1ms
    reg  [17:0] poll_cnt;    // 轮询节拍计数 (18bit)
    reg  [15:0] wait_cnt;    // 复位后延时 / 重试延时计数 (16bit)
    reg  [7:0]  ts_lo;       // 0x00 读回值 (暂存)
    reg  [7:0]  ts_hi;       // 0x01 读回值 (暂存, 供调试观测)

    // 扫描候选地址 (组合)
    wire [6:0] scan_addr = ADDR_BASE + {5'd0, scan_idx};

    // ------------------------------------------------------------------
    // 配置表 ROM: case (cfg_idx) 纯组合逻辑出 {reg_addr, wdata}
    // (Verilog-2001 无数组式 localparam ROM, 故用 case; 36 项逐条对齐工单表)
    // ------------------------------------------------------------------
    reg [7:0] cfg_addr;
    reg [7:0] cfg_data;

    always @(*) begin
        case (cfg_idx)
            // ---- 基线滤波 (12 电极共用, 手册 §5.5: 0x2B~0x35) ----
            6'd0:  begin cfg_addr = 8'h2B; cfg_data = 8'h01; end  // MHD_R
            6'd1:  begin cfg_addr = 8'h2C; cfg_data = 8'h01; end  // NHD_R
            6'd2:  begin cfg_addr = 8'h2D; cfg_data = 8'h00; end  // NCL_R
            6'd3:  begin cfg_addr = 8'h2E; cfg_data = 8'h00; end  // FDL_R
            6'd4:  begin cfg_addr = 8'h2F; cfg_data = 8'h01; end  // MHD_F
            6'd5:  begin cfg_addr = 8'h30; cfg_data = 8'h01; end  // NHD_F
            6'd6:  begin cfg_addr = 8'h31; cfg_data = 8'h24; end  // NCL_F
            6'd7:  begin cfg_addr = 8'h32; cfg_data = 8'h24; end  // FDL_F
            6'd8:  begin cfg_addr = 8'h33; cfg_data = 8'h01; end  // NHD_T
            6'd9:  begin cfg_addr = 8'h34; cfg_data = 8'h00; end  // NCL_T
            6'd10: begin cfg_addr = 8'h35; cfg_data = 8'h00; end  // FDL_T
            // ---- 去抖 (AN3892 P7 示例) ----
            6'd11: begin cfg_addr = 8'h5B; cfg_data = 8'h21; end  // DR=4 / DT=1 (位[2:0]=DT, 位[5:3]=DR)
            // ---- 触摸/释放阈值 (0x41~0x58, 12 电极; ELEPROX 不写) ----
            6'd12: begin cfg_addr = 8'h41; cfg_data = 8'h08; end  // ELE0_T
            6'd13: begin cfg_addr = 8'h42; cfg_data = 8'h04; end  // ELE0_R
            6'd14: begin cfg_addr = 8'h43; cfg_data = 8'h08; end  // ELE1_T
            6'd15: begin cfg_addr = 8'h44; cfg_data = 8'h04; end  // ELE1_R
            6'd16: begin cfg_addr = 8'h45; cfg_data = 8'h08; end  // ELE2_T
            6'd17: begin cfg_addr = 8'h46; cfg_data = 8'h04; end  // ELE2_R
            6'd18: begin cfg_addr = 8'h47; cfg_data = 8'h08; end  // ELE3_T
            6'd19: begin cfg_addr = 8'h48; cfg_data = 8'h04; end  // ELE3_R
            6'd20: begin cfg_addr = 8'h49; cfg_data = 8'h08; end  // ELE4_T
            6'd21: begin cfg_addr = 8'h4A; cfg_data = 8'h04; end  // ELE4_R
            6'd22: begin cfg_addr = 8'h4B; cfg_data = 8'h08; end  // ELE5_T
            6'd23: begin cfg_addr = 8'h4C; cfg_data = 8'h04; end  // ELE5_R
            6'd24: begin cfg_addr = 8'h4D; cfg_data = 8'h08; end  // ELE6_T
            6'd25: begin cfg_addr = 8'h4E; cfg_data = 8'h04; end  // ELE6_R
            6'd26: begin cfg_addr = 8'h4F; cfg_data = 8'h08; end  // ELE7_T
            6'd27: begin cfg_addr = 8'h50; cfg_data = 8'h04; end  // ELE7_R
            6'd28: begin cfg_addr = 8'h51; cfg_data = 8'h08; end  // ELE8_T
            6'd29: begin cfg_addr = 8'h52; cfg_data = 8'h04; end  // ELE8_R
            6'd30: begin cfg_addr = 8'h53; cfg_data = 8'h08; end  // ELE9_T
            6'd31: begin cfg_addr = 8'h54; cfg_data = 8'h04; end  // ELE9_R
            6'd32: begin cfg_addr = 8'h55; cfg_data = 8'h08; end  // ELE10_T
            6'd33: begin cfg_addr = 8'h56; cfg_data = 8'h04; end  // ELE10_R
            6'd34: begin cfg_addr = 8'h57; cfg_data = 8'h08; end  // ELE11_T
            6'd35: begin cfg_addr = 8'h58; cfg_data = 8'h04; end  // ELE11_R
            // ---- 兜底: cfg_idx 越界时给安全值 (正常流程不会命中) ----
            default: begin cfg_addr = 8'h00; cfg_data = 8'h00; end
        endcase
    end

    // ------------------------------------------------------------------
    // 主状态机 (编排层: 只发命令 / 等完成 / 判 ACK / 进下一状态)
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= M_SCAN;
            dev_addr  <= ADDR_BASE;
            scan_idx  <= 2'd0;
            cfg_idx   <= 6'd0;
            cmd_phase <= 1'b0;
            rst_dly   <= 1'b0;
            poll_cnt  <= 18'd0;
            wait_cnt  <= 16'd0;
            ts_lo     <= 8'd0;
            ts_hi     <= 8'd0;
            cmd_start <= 1'b0;
            cmd_op    <= 1'b0;
            cmd_addr  <= ADDR_BASE;
            cmd_reg   <= 8'd0;
            cmd_wdata <= 8'd0;
            touch     <= 12'd0;
            init_ok   <= 1'b0;      // sticky, 复位清 0
            init_fail <= 1'b0;      // sticky, 复位清 0
        end else begin
            // 默认: cmd_start 只持续 1 拍
            cmd_start <= 1'b0;

            case (state)

                // ---------------- 步骤 1: 地址扫描 ----------------
                M_SCAN: begin
                    cmd_op    <= 1'b1;          // 读事务 (首字节同为 Addr+W)
                    cmd_addr  <= scan_addr;
                    cmd_reg   <= REG_TS1;       // 读只读寄存器 0x00, 无副作用
                    cmd_wdata <= 8'd0;
                    cmd_start <= 1'b1;
                    state     <= M_SCAN_WAIT;
                end

                M_SCAN_WAIT: begin
                    if (cmd_done == 1'b1) begin
                        if (cmd_ack_err == 1'b0) begin
                            // 首个 ACK -> 锁定地址
                            dev_addr <= scan_addr;
                            scan_idx <= 2'd0;
                            state    <= M_RESET;
                        end else if (scan_idx == SCAN_LAST) begin
                            // 0x5A..0x5D 全 NACK -> 失败 (延时后重扫)
                            init_fail <= 1'b1;
                            scan_idx  <= 2'd0;
                            wait_cnt  <= 16'd0;
                            state     <= M_FAIL_WAIT;
                        end else begin
                            scan_idx <= scan_idx + 2'd1;
                            state    <= M_SCAN;
                        end
                    end
                end

                // ---------------- 步骤 2: 软复位 0x80 <- 0x63 ----------------
                M_RESET: begin
                    cmd_op    <= 1'b0;
                    cmd_addr  <= dev_addr;
                    cmd_reg   <= REG_SRST;
                    cmd_wdata <= SRST_KEY;
                    cmd_start <= 1'b1;
                    rst_dly   <= 1'b0;
                    wait_cnt  <= 16'd0;
                    state     <= M_RESET_WAIT;
                end

                M_RESET_WAIT: begin
                    if (rst_dly == 1'b0) begin
                        // 子步 1: 等事务完成
                        if (cmd_done == 1'b1) begin
                            if (cmd_ack_err == 1'b1) begin
                                init_fail <= 1'b1;
                                wait_cnt  <= 16'd0;
                                state     <= M_FAIL_WAIT;
                            end else begin
                                wait_cnt <= 16'd0;
                                rst_dly  <= 1'b1;   // 转发子步 2
                            end
                        end
                    end else begin
                        // 子步 2: 写后延时 >= 1ms (50_000 clk)
                        if (wait_cnt >= (RESET_WAIT - 16'd1)) begin
                            rst_dly <= 1'b0;
                            state   <= M_RD_AFE1;
                        end else begin
                            wait_cnt <= wait_cnt + 16'd1;
                        end
                    end
                end

                // ---------------- 步骤 3: 校验 0x5C / 0x5D ----------------
                M_RD_AFE1: begin
                    cmd_op    <= 1'b1;
                    cmd_addr  <= dev_addr;
                    cmd_reg   <= REG_AFE1;
                    cmd_wdata <= 8'd0;
                    cmd_start <= 1'b1;
                    state     <= M_RD_AFE1_WAIT;
                end

                M_RD_AFE1_WAIT: begin
                    if (cmd_done == 1'b1) begin
                        if ((cmd_ack_err == 1'b1) || (rx_data != AFE1_EXP)) begin
                            init_fail <= 1'b1;      // NACK 或校验值不符
                            wait_cnt  <= 16'd0;
                            state     <= M_FAIL_WAIT;
                        end else begin
                            state <= M_RD_AFE2;
                        end
                    end
                end

                M_RD_AFE2: begin
                    cmd_op    <= 1'b1;
                    cmd_addr  <= dev_addr;
                    cmd_reg   <= REG_AFE2;
                    cmd_wdata <= 8'd0;
                    cmd_start <= 1'b1;
                    state     <= M_RD_AFE2_WAIT;
                end

                M_RD_AFE2_WAIT: begin
                    if (cmd_done == 1'b1) begin
                        if ((cmd_ack_err == 1'b1) || (rx_data != AFE2_EXP)) begin
                            init_fail <= 1'b1;
                            wait_cnt  <= 16'd0;
                            state     <= M_FAIL_WAIT;
                        end else begin
                            cfg_idx   <= 6'd0;
                            cmd_phase <= 1'b0;
                            state     <= M_CFG_WRITE;
                        end
                    end
                end

                // ---------------- 步骤 4~6: 36 项配置写 ----------------
                // 全部在此刻 ECR=0 (Stop Mode) 下发出; 每项打一拍 cmd_start
                M_CFG_WRITE: begin
                    if (cmd_phase == 1'b0) begin
                        cmd_op    <= 1'b0;          // 写
                        cmd_addr  <= dev_addr;
                        cmd_reg   <= cfg_addr;      // 组合 ROM
                        cmd_wdata <= cfg_data;
                        cmd_start <= 1'b1;
                        cmd_phase <= 1'b1;
                    end else if (cmd_done == 1'b1) begin
                        cmd_phase <= 1'b0;
                        if (cmd_ack_err == 1'b1) begin
                            init_fail <= 1'b1;      // 配置写被 NACK -> 失败
                            wait_cnt  <= 16'd0;
                            state     <= M_FAIL_WAIT;
                        end else if (cfg_idx == CFG_LAST) begin
                            cfg_idx <= 6'd0;
                            state   <= M_ECR_RUN;
                        end else begin
                            cfg_idx <= cfg_idx + 6'd1;
                        end
                    end
                end

                // ---------------- 步骤 7: 进 Run Mode (本序列最后一次写) ----------------
                M_ECR_RUN: begin
                    if (cmd_phase == 1'b0) begin
                        cmd_op    <= 1'b0;
                        cmd_addr  <= dev_addr;
                        cmd_reg   <= REG_ECR;
                        cmd_wdata <= ECR_RUN_VAL;
                        cmd_start <= 1'b1;
                        cmd_phase <= 1'b1;
                    end else if (cmd_done == 1'b1) begin
                        cmd_phase <= 1'b0;
                        if (cmd_ack_err == 1'b1) begin
                            init_fail <= 1'b1;
                            wait_cnt  <= 16'd0;
                            state     <= M_FAIL_WAIT;
                        end else begin
                            init_ok  <= 1'b1;       // sticky: 初始化成功
                            poll_cnt <= 18'd0;
                            state    <= M_POLL_WAIT;
                        end
                    end
                end

                // ---------------- 步骤 8: 5ms 轮询 ----------------
                // poll_cnt 在每次发出 0x00 读的那一拍清零, 因此
                // "0x00 读 -> 下一次 0x00 读" 恒为 POLL_DIV 个 clk (start-to-start)。
                M_POLL_WAIT: begin
                    if (poll_cnt >= (POLL_DIV - 18'd1)) begin
                        poll_cnt  <= 18'd0;
                        cmd_phase <= 1'b0;
                        state     <= M_POLL_LO;
                    end else begin
                        poll_cnt <= poll_cnt + 18'd1;
                    end
                end

                M_POLL_LO: begin
                    poll_cnt <= poll_cnt + 18'd1;
                    if (cmd_phase == 1'b0) begin
                        cmd_op    <= 1'b1;
                        cmd_addr  <= dev_addr;
                        cmd_reg   <= REG_TS1;       // 读 0x00
                        cmd_wdata <= 8'd0;
                        cmd_start <= 1'b1;
                        cmd_phase <= 1'b1;
                    end else if (cmd_done == 1'b1) begin
                        cmd_phase <= 1'b0;
                        if (cmd_ack_err == 1'b1) begin
                            // 总线异常: 本轮作废, 不更新 touch
                            state <= M_POLL_WAIT;
                        end else begin
                            ts_lo <= rx_data;       // 先暂存低 8 位
                            state <= M_POLL_HI;
                        end
                    end
                end

                M_POLL_HI: begin
                    poll_cnt <= poll_cnt + 18'd1;
                    if (cmd_phase == 1'b0) begin
                        cmd_op    <= 1'b1;
                        cmd_addr  <= dev_addr;
                        cmd_reg   <= REG_TS2;       // 读 0x01
                        cmd_wdata <= 8'd0;
                        cmd_start <= 1'b1;
                        cmd_phase <= 1'b1;
                    end else if (cmd_done == 1'b1) begin
                        cmd_phase <= 1'b0;
                        if (cmd_ack_err == 1'b1) begin
                            // 总线异常: 本轮作废, 不更新 touch
                            state <= M_POLL_WAIT;
                        end else begin
                            ts_hi <= rx_data;
                            // 仅在 0x01 读回后更新 touch;
                            // 右端显式掩码: 取 0x01 的 bit3..bit0 = ELE11..ELE8,
                            // 掩掉 bit7(OVCF) 与 bit4(ELEPROX)。
                            touch <= {rx_data[3:0] & 4'hF, ts_lo};
                            state <= M_POLL_WAIT;   // 两笔读完成, 本轮结束
                        end
                    end
                end

                // ---------------- 失败重试 (不允许停在死状态) ----------------
                M_FAIL_WAIT: begin
                    if (wait_cnt >= (RETRY_WAIT - 16'd1)) begin
                        wait_cnt <= 16'd0;
                        scan_idx <= 2'd0;
                        state    <= M_SCAN;         // 1ms 后重新扫描
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                    end
                end

                // ---------------- 兜底 ----------------
                default: begin
                    state <= M_SCAN;
                end

            endcase
        end
    end

    // ------------------------------------------------------------------
    // i2c_master 例化 (物理层; 本模块不产生任何 SCL/SDA 时序)
    //   基线: sha256 7D63677B48AD5E48F6140FEC4101AE78483BB3A7288E315A061B771F824AC3CD
    // ------------------------------------------------------------------
    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .I2C_HZ (I2C_HZ)
    ) u_i2c_master (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_start   (cmd_start),
        .cmd_op      (cmd_op),
        .cmd_addr    (cmd_addr),
        .cmd_reg     (cmd_reg),
        .cmd_wdata   (cmd_wdata),
        .rx_data     (rx_data),
        .cmd_done    (cmd_done),
        .cmd_ack_err (cmd_ack_err),
        .scl         (scl),
        .sda         (sda)
    );

endmodule

`default_nettype wire
