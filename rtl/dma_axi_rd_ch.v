// ============================================================
// 模块名  : dma_axi_rd_ch
// 功能    : AXI4 读通道控制器
//           负责发起 AXI4 读地址事务（AR 通道）并接收读数据
//           （R 通道），将数据写入外部共享缓冲区。
//
// 【AXI4 握手机制说明】
//   AR 通道：主机置 arvalid=1，从机应答 arready=1，
//            握手完成（同一周期 valid & ready 均为1）后
//            地址信息被接受，主机必须保持 arvalid=1 直到
//            握手完成。
//   R  通道：从机置 rvalid=1，主机置 rready=1，
//            握手完成后数据有效，直到 rlast=1 时本次
//            突发读结束。
//
// 接口说明：
//   rd_req    : 来自传输控制模块的单周期启动脉冲
//   rd_addr   : 读起始字节地址（4字节对齐）
//   rd_len    : 突发拍数 - 1（AXI4 arlen 语义，范围 0~15）
//   rd_buf_*  : 写入外部数据缓冲（由 dma_xfer_ctrl 持有）
//   rd_done   : 单周期完成脉冲
//   rd_err    : 单周期错误脉冲（SLVERR/DECERR）
// ============================================================
`timescale 1ns/1ps

module dma_axi_rd_ch (
    input  wire        clk,
    input  wire        rst_n,

    // ===== AXI4 读地址通道（AR）=====
    output reg  [0:0]  arid,     // 事务 ID（固定为 0）
    output reg  [31:0] araddr,   // 读起始地址
    output reg  [7:0]  arlen,    // 突发长度 - 1（0~15）
    output reg  [2:0]  arsize,   // 数据宽度：3'b010 = 4字节
    output reg  [1:0]  arburst,  // 突发类型：2'b01 = INCR
    output reg         arvalid,  // 地址有效
    input  wire        arready,  // 从机就绪

    // ===== AXI4 读数据通道（R）=====
    input  wire [0:0]  rid,      // 响应 ID（忽略，单ID设计）
    input  wire [31:0] rdata,    // 读数据
    input  wire [1:0]  rresp,    // 响应状态（00=OKAY）
    input  wire        rlast,    // 突发最后一拍标志
    input  wire        rvalid,   // 数据有效
    output reg         rready,   // 主机就绪

    // ===== 控制接口（来自 dma_xfer_ctrl）=====
    input  wire        rd_req,   // 读请求脉冲（单周期）
    input  wire [31:0] rd_addr,  // 读起始地址
    input  wire [3:0]  rd_len,   // 突发拍数 - 1（0~15）

    // ===== 外部缓冲写接口（写到 dma_xfer_ctrl 的 xfer_buf）=====
    output reg         rd_buf_wen,   // 缓冲写使能
    output reg  [3:0]  rd_buf_waddr, // 缓冲写地址（beat 索引 0~15）
    output reg  [31:0] rd_buf_wdata, // 缓冲写数据

    // ===== 状态输出（到 dma_xfer_ctrl）=====
    output reg         rd_done,  // 读完成脉冲（单周期）
    output reg         rd_err    // 读错误脉冲（单周期）
);

    // -------------------------------------------------------
    // 【重点理解】状态机编码
    //   ST_IDLE : 等待 rd_req
    //   ST_AR   : 发送读地址，等待 arready
    //   ST_R    : 接收读数据，直到 rlast
    // -------------------------------------------------------
    localparam ST_IDLE = 2'b00;
    localparam ST_AR   = 2'b01;
    localparam ST_R    = 2'b10;

    reg [1:0] state;
    reg [3:0] beat_cnt; // 已接收拍数计数器（0~15）

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            beat_cnt     <= 4'b0;
            arid         <= 1'b0;
            araddr       <= 32'b0;
            arlen        <= 8'b0;
            arsize       <= 3'b010;
            arburst      <= 2'b01;
            arvalid      <= 1'b0;
            rready       <= 1'b0;
            rd_buf_wen   <= 1'b0;
            rd_buf_waddr <= 4'b0;
            rd_buf_wdata <= 32'b0;
            rd_done      <= 1'b0;
            rd_err       <= 1'b0;
        end else begin
            // 每周期默认清除单周期脉冲信号
            rd_buf_wen <= 1'b0;
            rd_done    <= 1'b0;
            rd_err     <= 1'b0;

            case (state)
                // ------------------------------------------
                // 空闲态：等待传输控制模块发出 rd_req
                // ------------------------------------------
                ST_IDLE: begin
                    if (rd_req) begin
                        // 锁存请求参数并发起 AR 通道事务
                        araddr  <= rd_addr;
                        arlen   <= {4'b0, rd_len}; // rd_len 与 arlen 同为 beats-1 编码，直接赋值
                        arsize  <= 3'b010;          // 每拍 4 字节
                        arburst <= 2'b01;            // INCR 递增突发
                        arid    <= 1'b0;
                        arvalid <= 1'b1;             // AR 通道握手开始
                        beat_cnt <= 4'b0;
                        state   <= ST_AR;
                    end
                end

                // ------------------------------------------
                // AR 阶段：保持 arvalid=1 直到 arready=1
                // AXI4 规则：arvalid 一旦置位必须保持到握手完成
                // ------------------------------------------
                ST_AR: begin
                    if (arvalid && arready) begin
                        // 握手完成，撤销地址有效，准备接收数据
                        arvalid <= 1'b0;
                        rready  <= 1'b1; // 表明主机已准备好接收数据
                        state   <= ST_R;
                    end
                end

                // ------------------------------------------
                // R 阶段：接收数据拍，写入共享缓冲
                // 每次 rvalid & rready 同时为高时，当前拍数据有效
                // rlast=1 表示本次突发的最后一拍
                // ------------------------------------------
                ST_R: begin
                    if (rvalid && rready) begin
                        // 将当前拍数据写入缓冲区对应位置
                        rd_buf_wen   <= 1'b1;
                        rd_buf_waddr <= beat_cnt;
                        rd_buf_wdata <= rdata;

                        if (rlast) begin
                            // 最后一拍：结束读事务
                            rready <= 1'b0;
                            state  <= ST_IDLE;
                            // 检查响应码：00=OKAY，01=EXOKAY 均视为正常
                            if (rresp[1] == 1'b0) begin
                                rd_done <= 1'b1;
                            end else begin
                                // 10=SLVERR，11=DECERR 报告错误
                                rd_err <= 1'b1;
                            end
                        end else begin
                            beat_cnt <= beat_cnt + 4'b1;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
