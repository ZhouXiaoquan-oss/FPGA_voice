// ============================================================================
// [p2_synth] Ported VERBATIM from the AX515 project:
//     trae\p1_audio_bringup\rtl\uart_rx.v
// Only this ASCII provenance header was added; the module body is unchanged
// (its original Chinese comments are preserved as-is).
// Phase-2 target: Tang Mega 60K (GW5AT-60B), PT8211 I2S master, NVOICE=32.
// ============================================================================
// ============================================================================
// 模块 6: uart_rx — UART 接收器 (AI 提醒触发通道)
// 功能: 接收 PC 通过外接 FT2232H 通道B (COM6) 发来的单字节命令,
//       收到完整字节后产生一个 clk 周期的 rx_done 脉冲并给出 rx_data。
// 参数: 115200 8N1, 无流控。50MHz 主时钟, 位中心采样。
//   位周期 = 50MHz / 115200 = 434 个时钟 (8.68us), 半位 = 217
// 协议约定 (与 PC 端 fpga_beep.ps1 一致):
//   0x01 = 低音滴滴 (任务完成)   0x02 = 高音滴滴 (需要用户操作)
//   其他字节收到但被上层忽略 (rx_done 照常产生)
// 帧错误处理: 停止位为 0 时不产生 rx_done, 丢弃该帧重新同步
// ============================================================================
module uart_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,       // 50MHz
    input  wire       rst_n,     // 复位, 低有效
    input  wire       rxd,       // 串行输入, 空闲为高 (来自 FT2232H 通道B (COM6) TXD, 引脚 G7)
    output reg  [7:0] rx_data,   // 接收到的字节
    output reg        rx_done    // 1 周期脉冲: 一个字节接收完成
);

    localparam integer BIT_CYC = CLK_HZ / BAUD;   // 434 @ 50MHz/115200
    localparam integer HALF_CYC = BIT_CYC / 2;    // 217, 起始位中心

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    // ---- 输入两级同步 (亚稳态防护) ----
    reg [1:0] rxd_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rxd_sync <= 2'b11;    // 空闲电平为高
        else
            rxd_sync <= {rxd_sync[0], rxd};
    end
    wire rxd_s = rxd_sync[1];

    reg [1:0]  state;
    reg [15:0] cnt;               // 位/半位周期计数 (BIT_CYC=434, 16bit 足够)
    reg [2:0]  bit_idx;           // 数据位序号 0..7 (LSB first)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            cnt     <= 16'd0;
            bit_idx <= 3'd0;
            rx_data <= 8'd0;
            rx_done <= 1'b0;
        end else begin
            rx_done <= 1'b0;      // 默认单周期脉冲
            case (state)
                S_IDLE:
                    if (rxd_s == 1'b0) begin   // 起始位下降沿
                        state <= S_START;
                        cnt   <= 16'd0;
                    end
                S_START:
                    if (cnt >= HALF_CYC - 1) begin
                        cnt <= 16'd0;
                        if (rxd_s == 1'b0) begin   // 位中心仍在低电平, 确认起始位
                            state   <= S_DATA;
                            bit_idx <= 3'd0;
                        end else
                            state <= S_IDLE;       // 毛刺, 重新等待
                    end else
                        cnt <= cnt + 16'd1;
                S_DATA:
                    if (cnt >= BIT_CYC - 1) begin
                        cnt       <= 16'd0;
                        rx_data   <= {rxd_s, rx_data[7:1]};  // LSB first 移入
                        if (bit_idx == 3'd7)
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 3'd1;
                    end else
                        cnt <= cnt + 16'd1;
                S_STOP:
                    if (cnt >= BIT_CYC - 1) begin
                        if (rxd_s == 1'b1)   // 停止位有效, 字节完成
                            rx_done <= 1'b1;
                        // 停止位为 0 (帧错误): 不产生 done, 静默丢弃重新同步
                        state <= S_IDLE;
                        cnt   <= 16'd0;
                    end else
                        cnt <= cnt + 16'd1;
                default:
                    state <= S_IDLE;
            endcase
        end
    end

endmodule
