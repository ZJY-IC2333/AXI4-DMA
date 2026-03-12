// ============================================================
// 模块名  : dma_xfer_ctrl
// 功能    : DMA 传输控制模块（核心状态机）
//           协调 AXI4 读/写通道完成 M2M 数据搬移：
//             1. 接收寄存器配置的启动命令
//             2. 参数合法性校验（4字节对齐、长度范围）
//             3. 按最大16拍突发分割传输任务
//             4. 循环执行：读一段 → 写一段 → 更新地址/计数
//             5. 传输完成/错误时向寄存器控制模块报告
//
// 【DMA 传输流程说明】
//   寄存器配置完成后，用户写 ctrl[0]=1 触发 dma_start 脉冲
//   → PARAM_CHECK 校验对齐和长度
//   → 循环执行突发：CALC_BURST → RD_ISSUE → WAIT_RD
//                               → WR_ISSUE → WAIT_WR
//                               → BURST_UPDATE
//   → XFER_DONE / XFER_ERROR
//
// 【内部数据缓冲】
//   16 × 32bit 缓冲（xfer_buf），读通道向其写入，
//   写通道从其读出，两者不同时工作，无需仲裁。
// ============================================================
`timescale 1ns/1ps

module dma_xfer_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // ===== 来自寄存器控制模块 =====
    input  wire        dma_start,   // 启动脉冲（单周期）
    input  wire [31:0] src_addr,    // 源地址
    input  wire [31:0] dst_addr,    // 目的地址
    input  wire [31:0] xfer_len,    // 传输长度（字节）

    // ===== 向寄存器控制模块报告状态 =====
    output reg         xfer_busy,   // 传输进行中（电平）
    output reg         xfer_done,   // 传输完成脉冲
    output reg         xfer_err,    // 总线错误脉冲

    // ===== 读通道控制接口 =====
    output reg         rd_req,      // 读请求脉冲
    output reg  [31:0] rd_addr,     // 读起始地址
    output reg  [3:0]  rd_len,      // 突发拍数 - 1（0~15）

    // ===== 读通道缓冲写接口（来自 dma_axi_rd_ch）=====
    input  wire        rd_buf_wen,   // 缓冲写使能
    input  wire [3:0]  rd_buf_waddr, // 缓冲写地址
    input  wire [31:0] rd_buf_wdata, // 缓冲写数据

    // ===== 读通道状态输入 =====
    input  wire        rd_done,     // 读完成脉冲
    input  wire        rd_err,      // 读错误脉冲

    // ===== 写通道控制接口 =====
    output reg         wr_req,      // 写请求脉冲
    output reg  [31:0] wr_addr,     // 写起始地址
    output reg  [3:0]  wr_len,      // 突发拍数 - 1（0~15）

    // ===== 写通道缓冲读接口（到 dma_axi_wr_ch）=====
    input  wire [3:0]  wr_buf_raddr, // 缓冲读地址（来自写通道）
    output wire [31:0] wr_buf_rdata, // 缓冲读数据（组合逻辑输出）

    // ===== 写通道状态输入 =====
    input  wire        wr_done,     // 写完成脉冲
    input  wire        wr_err       // 写错误脉冲
);

    // -------------------------------------------------------
    // 【重点理解】主状态机编码（二进制）
    // -------------------------------------------------------
    localparam ST_IDLE         = 4'd0;  // 空闲，等待启动
    localparam ST_PARAM_CHECK  = 4'd1;  // 参数合法性检查
    localparam ST_CALC_BURST   = 4'd2;  // 计算本次突发长度
    localparam ST_RD_ISSUE     = 4'd3;  // 发出读请求（单周期）
    localparam ST_WAIT_RD      = 4'd4;  // 等待读通道完成
    localparam ST_WR_ISSUE     = 4'd5;  // 发出写请求（单周期）
    localparam ST_WAIT_WR      = 4'd6;  // 等待写通道完成
    localparam ST_BURST_UPDATE = 4'd7;  // 更新地址和剩余计数
    localparam ST_XFER_DONE    = 4'd8;  // 传输完成
    localparam ST_XFER_ERROR   = 4'd9;  // 传输错误

    reg [3:0] state;

    // -------------------------------------------------------
    // 传输进度跟踪寄存器
    // -------------------------------------------------------
    reg [31:0] cur_src;          // 当前突发读起始地址
    reg [31:0] cur_dst;          // 当前突发写起始地址
    reg [10:0] remaining_beats;  // 剩余传输拍数（11位可表示0~2047，设计约束最大为1024=4096/4）
    reg [3:0]  cur_burst_len;    // 当前突发长度 - 1（0~15）

    // -------------------------------------------------------
    // 16 × 32bit 内部数据缓冲（读/写通道共享，串行访问）
    // -------------------------------------------------------
    reg [31:0] xfer_buf [0:15];

    // 缓冲写端口（由读通道驱动）
    integer i;
    always @(posedge clk) begin
        if (rd_buf_wen)
            xfer_buf[rd_buf_waddr] <= rd_buf_wdata;
    end

    // 缓冲读端口：组合逻辑输出，由写通道的 wr_buf_raddr 寻址
    assign wr_buf_rdata = xfer_buf[wr_buf_raddr];

    // -------------------------------------------------------
    // 突发长度组合逻辑计算
    //   remaining_beats > 16 → 取满 16 拍（arlen=15）
    //   remaining_beats ≤ 16 → 取剩余（arlen = remaining-1）
    // -------------------------------------------------------
    wire [3:0] next_burst_len =
        (remaining_beats > 11'd16) ? 4'd15 : (remaining_beats[3:0] - 4'd1);

    // 本次突发实际传输拍数（cur_burst_len + 1，5 位防溢出）
    wire [4:0] beats_done = {1'b0, cur_burst_len} + 5'd1; // 1~16
    // 字节偏移 = 拍数 × 4（左移 2 位，7 位宽）
    wire [6:0] byte_offset = {beats_done, 2'b00};

    // -------------------------------------------------------
    // 【重点理解】主状态机
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= ST_IDLE;
            xfer_busy       <= 1'b0;
            xfer_done       <= 1'b0;
            xfer_err        <= 1'b0;
            rd_req          <= 1'b0;
            rd_addr         <= 32'b0;
            rd_len          <= 4'b0;
            wr_req          <= 1'b0;
            wr_addr         <= 32'b0;
            wr_len          <= 4'b0;
            cur_src         <= 32'b0;
            cur_dst         <= 32'b0;
            remaining_beats <= 11'b0;
            cur_burst_len   <= 4'b0;
        end else begin
            // 每周期默认清除单周期脉冲
            xfer_done <= 1'b0;
            xfer_err  <= 1'b0;
            rd_req    <= 1'b0;
            wr_req    <= 1'b0;

            case (state)
                // ==========================================
                // ST_IDLE：等待 dma_start 脉冲
                // ==========================================
                ST_IDLE: begin
                    xfer_busy <= 1'b0;
                    if (dma_start) begin
                        xfer_busy <= 1'b1;
                        state     <= ST_PARAM_CHECK;
                    end
                end

                // ==========================================
                // ST_PARAM_CHECK：参数合法性检查
                //   ① 源/目的地址必须 4 字节对齐
                //   ② 传输长度必须是 4 的倍数
                //   ③ 长度范围：1~4096 字节
                // ==========================================
                ST_PARAM_CHECK: begin
                    if ((src_addr[1:0] != 2'b00) ||    // 源地址未对齐
                        (dst_addr[1:0] != 2'b00) ||    // 目的地址未对齐
                        (xfer_len[1:0] != 2'b00) ||    // 长度未对齐
                        (xfer_len == 32'b0)        ||  // 长度为零
                        (xfer_len > 32'd4096)) begin    // 超出最大长度
                        state <= ST_XFER_ERROR;
                    end else begin
                        // 参数合法：锁存初始地址和总拍数
                        cur_src         <= src_addr;
                        cur_dst         <= dst_addr;
                        // 字节数 ÷ 4 = 拍数（右移2位）
                        remaining_beats <= xfer_len[12:2];
                        state           <= ST_CALC_BURST;
                    end
                end

                // ==========================================
                // ST_CALC_BURST：计算本次突发参数
                //   并将地址/长度预置到读通道寄存器
                // ==========================================
                ST_CALC_BURST: begin
                    cur_burst_len <= next_burst_len;
                    // 预置读通道参数（下一个周期在 ST_RD_ISSUE 置 rd_req）
                    rd_addr <= cur_src;
                    rd_len  <= next_burst_len;
                    state   <= ST_RD_ISSUE;
                end

                // ==========================================
                // ST_RD_ISSUE：向读通道发出单周期请求脉冲
                // ==========================================
                ST_RD_ISSUE: begin
                    rd_req <= 1'b1; // 单周期脉冲（下一周期默认清0）
                    state  <= ST_WAIT_RD;
                end

                // ==========================================
                // ST_WAIT_RD：等待读通道完成或报错
                // ==========================================
                ST_WAIT_RD: begin
                    if (rd_err) begin
                        state <= ST_XFER_ERROR;
                    end else if (rd_done) begin
                        // 读完成：预置写通道参数
                        wr_addr <= cur_dst;
                        wr_len  <= cur_burst_len;
                        state   <= ST_WR_ISSUE;
                    end
                end

                // ==========================================
                // ST_WR_ISSUE：向写通道发出单周期请求脉冲
                // ==========================================
                ST_WR_ISSUE: begin
                    wr_req <= 1'b1; // 单周期脉冲
                    state  <= ST_WAIT_WR;
                end

                // ==========================================
                // ST_WAIT_WR：等待写通道完成或报错
                // ==========================================
                ST_WAIT_WR: begin
                    if (wr_err) begin
                        state <= ST_XFER_ERROR;
                    end else if (wr_done) begin
                        state <= ST_BURST_UPDATE;
                    end
                end

                // ==========================================
                // ST_BURST_UPDATE：更新地址和剩余拍数
                //   cur_burst_len 是 beats-1，实际拍数 = cur_burst_len+1
                // ==========================================
                ST_BURST_UPDATE: begin
                    // 更新源/目的地址（每拍 4 字节，左移 2 位）
                    cur_src         <= cur_src + {25'b0, byte_offset};
                    cur_dst         <= cur_dst + {25'b0, byte_offset};
                    remaining_beats <= remaining_beats - {6'b0, beats_done};

                    // 判断是否还有剩余拍数未传输
                    if (remaining_beats <= {6'b0, beats_done}) begin
                        state <= ST_XFER_DONE;
                    end else begin
                        state <= ST_CALC_BURST;
                    end
                end

                // ==========================================
                // ST_XFER_DONE：传输成功完成
                // ==========================================
                ST_XFER_DONE: begin
                    xfer_done <= 1'b1; // 单周期完成脉冲
                    xfer_busy <= 1'b0;
                    state     <= ST_IDLE;
                end

                // ==========================================
                // ST_XFER_ERROR：传输出错
                // ==========================================
                ST_XFER_ERROR: begin
                    xfer_err  <= 1'b1; // 单周期错误脉冲
                    xfer_busy <= 1'b0;
                    state     <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
