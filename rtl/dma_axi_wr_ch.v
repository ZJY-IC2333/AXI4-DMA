// ============================================================
// 模块名  : dma_axi_wr_ch
// 功能    : AXI4 写通道控制器
//           负责发起 AXI4 写地址事务（AW 通道）、发送写数据
//           （W 通道）并等待写响应（B 通道）。
//
// 【AXI4 握手机制说明】
//   AW 通道：主机置 awvalid=1，从机应答 awready=1，
//            握手完成后写地址信息被接受。
//   W  通道：主机置 wvalid=1，从机应答 wready=1，
//            握手完成后当前拍数据被接受。最后一拍必须
//            同时置 wlast=1。
//   B  通道：从机置 bvalid=1，主机应答 bready=1，
//            握手完成后写响应被接受，事务结束。
//
// 【wdata 时序说明】
//   wdata 通过组合逻辑直接连接到外部缓冲（wr_buf_rdata），
//   wr_buf_raddr（拍计数器）在每次握手后递增，由于它是
//   寄存器信号，在两个时钟沿之间保持稳定，满足 AXI4
//   "wvalid 期间 wdata 必须稳定"的要求。
// ============================================================
`timescale 1ns/1ps

module dma_axi_wr_ch (
    input  wire        clk,
    input  wire        rst_n,

    // ===== AXI4 写地址通道（AW）=====
    output reg  [0:0]  awid,     // 事务 ID（固定为 0）
    output reg  [31:0] awaddr,   // 写起始地址
    output reg  [7:0]  awlen,    // 突发长度 - 1（0~15）
    output reg  [2:0]  awsize,   // 数据宽度：3'b010 = 4字节
    output reg  [1:0]  awburst,  // 突发类型：2'b01 = INCR
    output reg         awvalid,  // 地址有效
    input  wire        awready,  // 从机就绪

    // ===== AXI4 写数据通道（W）=====
    output wire [31:0] wdata,    // 写数据（组合逻辑，来自缓冲）
    output reg  [3:0]  wstrb,    // 字节选通（全1 = 所有字节有效）
    output reg         wlast,    // 突发最后一拍标志
    output reg         wvalid,   // 数据有效
    input  wire        wready,   // 从机就绪

    // ===== AXI4 写响应通道（B）=====
    input  wire [0:0]  bid,      // 响应 ID（忽略）
    input  wire [1:0]  bresp,    // 响应状态（00=OKAY）
    input  wire        bvalid,   // 响应有效
    output reg         bready,   // 主机就绪

    // ===== 控制接口（来自 dma_xfer_ctrl）=====
    input  wire        wr_req,   // 写请求脉冲（单周期）
    input  wire [31:0] wr_addr,  // 写起始地址
    input  wire [3:0]  wr_len,   // 突发拍数 - 1（0~15）

    // ===== 外部缓冲读接口（读自 dma_xfer_ctrl 的 xfer_buf）=====
    output reg  [3:0]  wr_buf_raddr, // 缓冲读地址（beat 索引 0~15）
    input  wire [31:0] wr_buf_rdata, // 缓冲读数据（组合逻辑输出）

    // ===== 状态输出（到 dma_xfer_ctrl）=====
    output reg         wr_done,  // 写完成脉冲（单周期）
    output reg         wr_err    // 写错误脉冲（单周期）
);

    // -------------------------------------------------------
    // 【重点理解】状态机编码
    //   ST_IDLE : 等待 wr_req
    //   ST_AW   : 发送写地址，等待 awready
    //   ST_W    : 发送写数据拍，直到 wlast 被接受
    //   ST_B    : 等待写响应
    // -------------------------------------------------------
    localparam ST_IDLE = 2'b00;
    localparam ST_AW   = 2'b01;
    localparam ST_W    = 2'b10;
    localparam ST_B    = 2'b11;

    reg [1:0] state;
    reg [3:0] wr_len_r; // 锁存的突发长度参数（0~15）

    // -------------------------------------------------------
    // wdata 组合逻辑连接：直接来自外部缓冲，
    // 由 wr_buf_raddr（寄存器）稳定驱动
    // -------------------------------------------------------
    assign wdata = wr_buf_rdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            wr_len_r     <= 4'b0;
            awid         <= 1'b0;
            awaddr       <= 32'b0;
            awlen        <= 8'b0;
            awsize       <= 3'b010;
            awburst      <= 2'b01;
            awvalid      <= 1'b0;
            wstrb        <= 4'b1111;
            wlast        <= 1'b0;
            wvalid       <= 1'b0;
            bready       <= 1'b0;
            wr_buf_raddr <= 4'b0;
            wr_done      <= 1'b0;
            wr_err       <= 1'b0;
        end else begin
            // 每周期默认清除单周期脉冲
            wr_done <= 1'b0;
            wr_err  <= 1'b0;

            case (state)
                // ------------------------------------------
                // 空闲态：等待传输控制模块发出 wr_req
                // ------------------------------------------
                ST_IDLE: begin
                    if (wr_req) begin
                        // 锁存请求参数，发起 AW 通道事务
                        awaddr       <= wr_addr;
                        awlen        <= {4'b0, wr_len}; // wr_len 与 awlen 同为 beats-1 编码，直接赋值
                        awsize       <= 3'b010;           // 每拍 4 字节
                        awburst      <= 2'b01;             // INCR 递增突发
                        awid         <= 1'b0;
                        awvalid      <= 1'b1;              // AW 通道握手开始
                        wr_len_r     <= wr_len;
                        wr_buf_raddr <= 4'b0;              // 从缓冲头部开始读
                        state        <= ST_AW;
                    end
                end

                // ------------------------------------------
                // AW 阶段：保持 awvalid=1 直到 awready=1
                // ------------------------------------------
                ST_AW: begin
                    if (awvalid && awready) begin
                        // 写地址握手完成，开始发送数据
                        awvalid <= 1'b0;
                        wvalid  <= 1'b1;
                        wstrb   <= 4'b1111;                  // 4 字节全有效
                        // 若只有一拍，立即置 wlast
                        wlast   <= (wr_len_r == 4'b0) ? 1'b1 : 1'b0;
                        state   <= ST_W;
                    end
                end

                // ------------------------------------------
                // W 阶段：逐拍发送数据
                //   - wr_buf_raddr 递增驱动组合逻辑 wdata
                //   - wlast 在进入最后一拍前置位
                // ------------------------------------------
                ST_W: begin
                    if (wvalid && wready) begin
                        if (wlast) begin
                            // 最后一拍握手完成，等待写响应
                            wvalid <= 1'b0;
                            bready <= 1'b1;
                            state  <= ST_B;
                        end else begin
                            // 当前拍接受，推进到下一拍
                            wr_buf_raddr <= wr_buf_raddr + 4'b1;
                            // 当下一拍编号 == wr_len_r 时，预置 wlast
                            wlast <= ((wr_buf_raddr + 4'b1) == wr_len_r) ? 1'b1 : 1'b0;
                        end
                    end
                end

                // ------------------------------------------
                // B 阶段：等待从机发出写响应
                // ------------------------------------------
                ST_B: begin
                    if (bvalid && bready) begin
                        bready <= 1'b0;
                        state  <= ST_IDLE;
                        // 检查响应码
                        if (bresp[1] == 1'b0) begin
                            wr_done <= 1'b1; // OKAY 或 EXOKAY
                        end else begin
                            wr_err <= 1'b1;  // SLVERR 或 DECERR
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
