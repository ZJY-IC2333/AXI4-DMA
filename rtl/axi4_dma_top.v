// ============================================================
// 模块名  : axi4_dma_top
// 功能    : AXI4 DMA 控制器顶层模块
//           实例化并连接所有子模块：
//             - dma_reg_ctrl  : 寄存器控制
//             - dma_xfer_ctrl : 传输控制（含内部数据缓冲）
//             - dma_axi_rd_ch : AXI4 读通道
//             - dma_axi_wr_ch : AXI4 写通道
//             - dma_intr_gen  : 中断生成
//
// 【模块框图】
//
//  reg_addr/wr_en/rd_en/wr_data ──► dma_reg_ctrl ──► dma_start
//                                         │              │
//                                  src/dst/len           ▼
//                                         └──────► dma_xfer_ctrl
//                                                      │     │
//                                             rd_req   │     │  wr_req
//                                                  ▼   │     ▼
//                                           dma_axi_rd_ch  dma_axi_wr_ch
//                                                  │             │
//                                            AXI4 AR/R     AXI4 AW/W/B
//
// 接口信号说明（均为主机视角，连接到AXI4从机/存储器）：
//   ar*  : 读地址通道（DMA 作为主机发出）
//   r*   : 读数据通道（从机发回给 DMA）
//   aw*  : 写地址通道
//   w*   : 写数据通道
//   b*   : 写响应通道（从机响应 DMA）
// ============================================================
`timescale 1ns/1ps

module axi4_dma_top (
    input  wire        clk,
    input  wire        rst_n,

    // ===== 寄存器配置接口 =====
    input  wire [3:0]  reg_addr,    // 字地址（字节地址 >> 2，范围 0~4）
    input  wire        reg_wr_en,   // 写使能
    input  wire        reg_rd_en,   // 读使能
    input  wire [31:0] reg_wr_data, // 写数据
    output wire [31:0] reg_rd_data, // 读数据

    // ===== AXI4 读地址通道（AR）=====
    output wire [0:0]  arid,
    output wire [31:0] araddr,
    output wire [7:0]  arlen,
    output wire [2:0]  arsize,
    output wire [1:0]  arburst,
    output wire        arvalid,
    input  wire        arready,

    // ===== AXI4 读数据通道（R）=====
    input  wire [0:0]  rid,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,

    // ===== AXI4 写地址通道（AW）=====
    output wire [0:0]  awid,
    output wire [31:0] awaddr,
    output wire [7:0]  awlen,
    output wire [2:0]  awsize,
    output wire [1:0]  awburst,
    output wire        awvalid,
    input  wire        awready,

    // ===== AXI4 写数据通道（W）=====
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,

    // ===== AXI4 写响应通道（B）=====
    input  wire [0:0]  bid,
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready,

    // ===== 中断输出 =====
    output wire        dma_intr
);

    // -------------------------------------------------------
    // 内部连线：寄存器控制 → 传输控制
    // -------------------------------------------------------
    wire        dma_start;
    wire        dma_dir;
    wire        intr_done_en;
    wire        intr_err_en;
    wire [31:0] src_addr;
    wire [31:0] dst_addr;
    wire [31:0] xfer_len;
    wire        done_status;
    wire        err_status;

    // -------------------------------------------------------
    // 内部连线：传输控制 ↔ 寄存器控制（状态反馈）
    // -------------------------------------------------------
    wire        xfer_busy;
    wire        xfer_done;
    wire        xfer_err;

    // -------------------------------------------------------
    // 内部连线：传输控制 → 读通道
    // -------------------------------------------------------
    wire        rd_req;
    wire [31:0] rd_addr_w;
    wire [3:0]  rd_len_w;

    // -------------------------------------------------------
    // 内部连线：读通道 → 传输控制（缓冲写端口）
    // -------------------------------------------------------
    wire        rd_buf_wen;
    wire [3:0]  rd_buf_waddr;
    wire [31:0] rd_buf_wdata;
    wire        rd_done;
    wire        rd_err;

    // -------------------------------------------------------
    // 内部连线：传输控制 → 写通道
    // -------------------------------------------------------
    wire        wr_req;
    wire [31:0] wr_addr_w;
    wire [3:0]  wr_len_w;

    // -------------------------------------------------------
    // 内部连线：写通道 ↔ 传输控制（缓冲读端口）
    // -------------------------------------------------------
    wire [3:0]  wr_buf_raddr;
    wire [31:0] wr_buf_rdata;
    wire        wr_done;
    wire        wr_err;

    // -------------------------------------------------------
    // 子模块例化
    // -------------------------------------------------------

    // ---- 寄存器控制 ----
    dma_reg_ctrl u_reg_ctrl (
        .clk         (clk),
        .rst_n       (rst_n),
        .reg_addr    (reg_addr),
        .reg_wr_en   (reg_wr_en),
        .reg_rd_en   (reg_rd_en),
        .reg_wr_data (reg_wr_data),
        .reg_rd_data (reg_rd_data),
        .dma_start   (dma_start),
        .dma_dir     (dma_dir),
        .intr_done_en(intr_done_en),
        .intr_err_en (intr_err_en),
        .src_addr    (src_addr),
        .dst_addr    (dst_addr),
        .xfer_len    (xfer_len),
        .done_status (done_status),
        .err_status  (err_status),
        .xfer_busy   (xfer_busy),
        .xfer_done   (xfer_done),
        .xfer_err    (xfer_err)
    );

    // ---- 传输控制（含数据缓冲）----
    dma_xfer_ctrl u_xfer_ctrl (
        .clk          (clk),
        .rst_n        (rst_n),
        .dma_start    (dma_start),
        .src_addr     (src_addr),
        .dst_addr     (dst_addr),
        .xfer_len     (xfer_len),
        .xfer_busy    (xfer_busy),
        .xfer_done    (xfer_done),
        .xfer_err     (xfer_err),
        .rd_req       (rd_req),
        .rd_addr      (rd_addr_w),
        .rd_len       (rd_len_w),
        .rd_buf_wen   (rd_buf_wen),
        .rd_buf_waddr (rd_buf_waddr),
        .rd_buf_wdata (rd_buf_wdata),
        .rd_done      (rd_done),
        .rd_err       (rd_err),
        .wr_req       (wr_req),
        .wr_addr      (wr_addr_w),
        .wr_len       (wr_len_w),
        .wr_buf_raddr (wr_buf_raddr),
        .wr_buf_rdata (wr_buf_rdata),
        .wr_done      (wr_done),
        .wr_err       (wr_err)
    );

    // ---- AXI4 读通道 ----
    dma_axi_rd_ch u_axi_rd (
        .clk          (clk),
        .rst_n        (rst_n),
        .arid         (arid),
        .araddr       (araddr),
        .arlen        (arlen),
        .arsize       (arsize),
        .arburst      (arburst),
        .arvalid      (arvalid),
        .arready      (arready),
        .rid          (rid),
        .rdata        (rdata),
        .rresp        (rresp),
        .rlast        (rlast),
        .rvalid       (rvalid),
        .rready       (rready),
        .rd_req       (rd_req),
        .rd_addr      (rd_addr_w),
        .rd_len       (rd_len_w),
        .rd_buf_wen   (rd_buf_wen),
        .rd_buf_waddr (rd_buf_waddr),
        .rd_buf_wdata (rd_buf_wdata),
        .rd_done      (rd_done),
        .rd_err       (rd_err)
    );

    // ---- AXI4 写通道 ----
    dma_axi_wr_ch u_axi_wr (
        .clk          (clk),
        .rst_n        (rst_n),
        .awid         (awid),
        .awaddr       (awaddr),
        .awlen        (awlen),
        .awsize       (awsize),
        .awburst      (awburst),
        .awvalid      (awvalid),
        .awready      (awready),
        .wdata        (wdata),
        .wstrb        (wstrb),
        .wlast        (wlast),
        .wvalid       (wvalid),
        .wready       (wready),
        .bid          (bid),
        .bresp        (bresp),
        .bvalid       (bvalid),
        .bready       (bready),
        .wr_req       (wr_req),
        .wr_addr      (wr_addr_w),
        .wr_len       (wr_len_w),
        .wr_buf_raddr (wr_buf_raddr),
        .wr_buf_rdata (wr_buf_rdata),
        .wr_done      (wr_done),
        .wr_err       (wr_err)
    );

    // ---- 中断生成 ----
    dma_intr_gen u_intr_gen (
        .done_status  (done_status),
        .err_status   (err_status),
        .intr_done_en (intr_done_en),
        .intr_err_en  (intr_err_en),
        .dma_intr     (dma_intr)
    );

endmodule
