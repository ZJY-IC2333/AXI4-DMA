// ============================================================
// 模块名  : dma_reg_ctrl
// 功能    : DMA寄存器控制模块
//           管理5个32位配置/状态寄存器，提供控制信号输出，
//           接收传输状态并更新状态寄存器
//
// 寄存器映射（reg_addr = 字地址，即字节地址 >> 2）：
//   0x0（addr=0）：控制寄存器
//     bit0  : 传输启动（写1触发，自动清零）
//     bit1  : 传输方向（0 = M2M，本设计固定为0）
//     bit2  : 完成中断使能
//     bit3  : 错误中断使能
//   0x1（addr=1）：源地址寄存器（32bit）
//   0x2（addr=2）：目的地址寄存器（32bit）
//   0x3（addr=3）：传输长度寄存器（32bit，单位字节）
//   0x4（addr=4）：状态寄存器（只读，写1清零W1C）
//     bit0  : 传输忙
//     bit1  : 传输完成（W1C）
//     bit2  : 总线错误（W1C）
// ============================================================
`timescale 1ns/1ps

module dma_reg_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // ===== 寄存器配置接口 =====
    input  wire [3:0]  reg_addr,     // 字地址（bit地址 >> 2）
    input  wire        reg_wr_en,    // 写使能
    input  wire        reg_rd_en,    // 读使能
    input  wire [31:0] reg_wr_data,  // 写数据
    output reg  [31:0] reg_rd_data,  // 读数据（下一个时钟有效）

    // ===== 控制信号输出（到传输控制模块）=====
    output reg         dma_start,    // 传输启动脉冲（单周期高电平）
    output wire        dma_dir,      // 传输方向
    output wire        intr_done_en, // 完成中断使能
    output wire        intr_err_en,  // 错误中断使能
    output reg  [31:0] src_addr,     // 源地址
    output reg  [31:0] dst_addr,     // 目的地址
    output reg  [31:0] xfer_len,     // 传输长度（字节）

    // ===== 状态信号输出（到中断生成模块）=====
    output wire        done_status,  // 传输完成状态位
    output wire        err_status,   // 总线错误状态位

    // ===== 传输状态输入（来自传输控制模块）=====
    input  wire        xfer_busy,    // 传输进行中（电平）
    input  wire        xfer_done,    // 传输完成脉冲
    input  wire        xfer_err      // 总线错误脉冲
);

    // -------------------------------------------------------
    // 本地参数：寄存器字地址
    // -------------------------------------------------------
    localparam ADDR_CTRL   = 4'h0;  // 控制寄存器
    localparam ADDR_SRC    = 4'h1;  // 源地址
    localparam ADDR_DST    = 4'h2;  // 目的地址
    localparam ADDR_LEN    = 4'h3;  // 传输长度
    localparam ADDR_STATUS = 4'h4;  // 状态寄存器

    // -------------------------------------------------------
    // 内部寄存器定义
    // -------------------------------------------------------
    reg [3:0] ctrl_reg;    // 控制寄存器（bit3:0）
    reg       status_done; // 状态寄存器 bit1：完成（W1C）
    reg       status_err;  // 状态寄存器 bit2：错误（W1C）

    // -------------------------------------------------------
    // 连续赋值：控制寄存器字段解码
    // -------------------------------------------------------
    assign dma_dir      = ctrl_reg[1]; // bit1：传输方向
    assign intr_done_en = ctrl_reg[2]; // bit2：完成中断使能
    assign intr_err_en  = ctrl_reg[3]; // bit3：错误中断使能

    // -------------------------------------------------------
    // 状态信号连续输出（供中断模块使用）
    // -------------------------------------------------------
    assign done_status = status_done;
    assign err_status  = status_err;

    // -------------------------------------------------------
    // 【重点理解】控制/地址/长度寄存器写逻辑
    //   - dma_start 是单周期脉冲：每个时钟周期默认清零
    //   - 写控制寄存器 bit0=1 且 DMA 当前空闲 → 产生 start 脉冲
    //   - DMA 忙时写 start 无效（防止覆盖传输参数）
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_reg  <= 4'b0;
            src_addr  <= 32'b0;
            dst_addr  <= 32'b0;
            xfer_len  <= 32'b0;
            dma_start <= 1'b0;
        end else begin
            dma_start <= 1'b0; // 每周期默认清零，只在触发条件成立时拉高一周期

            if (reg_wr_en) begin
                case (reg_addr)
                    ADDR_CTRL: begin
                        // 只有 DMA 空闲时才能启动新传输
                        if (reg_wr_data[0] && !xfer_busy) begin
                            ctrl_reg  <= reg_wr_data[3:0];
                            dma_start <= 1'b1; // 产生启动脉冲
                        end else begin
                            ctrl_reg[3:1] <= reg_wr_data[3:1]; // 允许修改使能位
                        end
                    end
                    ADDR_SRC: src_addr <= reg_wr_data;
                    ADDR_DST: dst_addr <= reg_wr_data;
                    ADDR_LEN: xfer_len <= reg_wr_data;
                    default:  ; // 状态寄存器写操作在下方单独处理
                endcase
            end
        end
    end

    // -------------------------------------------------------
    // 状态寄存器逻辑
    //   - busy：直接反映 xfer_busy
    //   - done：传输完成时置1，用户写1清零（W1C）
    //   - err ：总线错误时置1，用户写1清零（W1C）
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status_done <= 1'b0;
            status_err  <= 1'b0;
        end else begin
            // done 位：xfer_done 脉冲置位，写1清零
            if (xfer_done)
                status_done <= 1'b1;
            else if (reg_wr_en && (reg_addr == ADDR_STATUS) && reg_wr_data[1])
                status_done <= 1'b0;

            // err 位：xfer_err 脉冲置位，写1清零
            if (xfer_err)
                status_err <= 1'b1;
            else if (reg_wr_en && (reg_addr == ADDR_STATUS) && reg_wr_data[2])
                status_err <= 1'b0;
        end
    end

    // -------------------------------------------------------
    // 寄存器读逻辑（同步读，下一周期输出）
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_rd_data <= 32'b0;
        end else if (reg_rd_en) begin
            case (reg_addr)
                ADDR_CTRL:   reg_rd_data <= {28'b0, ctrl_reg};
                ADDR_SRC:    reg_rd_data <= src_addr;
                ADDR_DST:    reg_rd_data <= dst_addr;
                ADDR_LEN:    reg_rd_data <= xfer_len;
                ADDR_STATUS: reg_rd_data <= {29'b0, status_err, status_done, xfer_busy};
                default:     reg_rd_data <= 32'b0;
            endcase
        end
    end

endmodule
