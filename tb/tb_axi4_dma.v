// ============================================================
// 文件名  : tb_axi4_dma.v
// 功能    : AXI4 DMA 控制器仿真测试平台
//           覆盖测试场景：
//             1. 简单模式 M2M 传输（4字节，1拍）
//             2. 多突发 M2M 传输（128字节，2×16拍突发，验证突发分割）
//             3. 非对齐源地址报错
//             4. 传输长度非对齐报错
//             5. AXI SLVERR 总线错误中断
//
// 测试环境：
//   - 内嵌 AXI4 从机模型（4KB 内存，字节寻址）
//   - 100MHz 时钟，异步低电平复位
//
// AXI4 从机模型设计说明：
//   读通道（AR+R）：
//     - AR 接受时立即锁存地址并预装第0拍数据（rdata=mem[base]，rvalid=1）
//     - 每次 rvalid & rready 握手后预装下一拍（rdata=mem[base+next]，rlast更新）
//     - 最后一拍握手后撤销 rvalid
//   写通道（AW+W+B）：
//     - AW 接受后每周期置 wready=1
//     - 每次 wvalid & wready 写入内存，wlast 后发 B 响应
// ============================================================
`timescale 1ns/1ps

module tb_axi4_dma;

    // -------------------------------------------------------
    // 参数
    // -------------------------------------------------------
    parameter CLK_PERIOD = 10;   // 100MHz
    parameter MEM_DEPTH  = 1024; // 字数（4KB / 4B）

    // -------------------------------------------------------
    // 时钟与复位
    // -------------------------------------------------------
    reg clk;
    reg rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------
    // 寄存器配置接口
    // -------------------------------------------------------
    reg  [3:0]  reg_addr;
    reg         reg_wr_en;
    reg         reg_rd_en;
    reg  [31:0] reg_wr_data;
    wire [31:0] reg_rd_data;

    // -------------------------------------------------------
    // AXI4 读地址通道
    // -------------------------------------------------------
    wire [0:0]  arid;
    wire [31:0] araddr;
    wire [7:0]  arlen;
    wire [2:0]  arsize;
    wire [1:0]  arburst;
    wire        arvalid;
    reg         arready;

    // -------------------------------------------------------
    // AXI4 读数据通道
    // -------------------------------------------------------
    reg  [0:0]  rid;
    reg  [31:0] rdata;
    reg  [1:0]  rresp;
    reg         rlast;
    reg         rvalid;
    wire        rready;

    // -------------------------------------------------------
    // AXI4 写地址通道
    // -------------------------------------------------------
    wire [0:0]  awid;
    wire [31:0] awaddr;
    wire [7:0]  awlen;
    wire [2:0]  awsize;
    wire [1:0]  awburst;
    wire        awvalid;
    reg         awready;

    // -------------------------------------------------------
    // AXI4 写数据通道
    // -------------------------------------------------------
    wire [31:0] wdata;
    wire [3:0]  wstrb;
    wire        wlast;
    wire        wvalid;
    reg         wready;

    // -------------------------------------------------------
    // AXI4 写响应通道
    // -------------------------------------------------------
    reg  [0:0]  bid;
    reg  [1:0]  bresp;
    reg         bvalid;
    wire        bready;

    // -------------------------------------------------------
    // 中断
    // -------------------------------------------------------
    wire dma_intr;

    // -------------------------------------------------------
    // DUT 例化
    // -------------------------------------------------------
    axi4_dma_top dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .reg_addr    (reg_addr),
        .reg_wr_en   (reg_wr_en),
        .reg_rd_en   (reg_rd_en),
        .reg_wr_data (reg_wr_data),
        .reg_rd_data (reg_rd_data),
        .arid        (arid),
        .araddr      (araddr),
        .arlen       (arlen),
        .arsize      (arsize),
        .arburst     (arburst),
        .arvalid     (arvalid),
        .arready     (arready),
        .rid         (rid),
        .rdata       (rdata),
        .rresp       (rresp),
        .rlast       (rlast),
        .rvalid      (rvalid),
        .rready      (rready),
        .awid        (awid),
        .awaddr      (awaddr),
        .awlen       (awlen),
        .awsize      (awsize),
        .awburst     (awburst),
        .awvalid     (awvalid),
        .awready     (awready),
        .wdata       (wdata),
        .wstrb       (wstrb),
        .wlast       (wlast),
        .wvalid      (wvalid),
        .wready      (wready),
        .bid         (bid),
        .bresp       (bresp),
        .bvalid      (bvalid),
        .bready      (bready),
        .dma_intr    (dma_intr)
    );

    // -------------------------------------------------------
    // 简单 AXI4 从机内存（4KB）
    // -------------------------------------------------------
    reg [31:0] mem [0:MEM_DEPTH-1]; // 字地址索引

    integer idx;
    initial begin
        for (idx = 0; idx < MEM_DEPTH; idx = idx + 1)
            mem[idx] = 32'hDEAD_0000 + idx;
    end

    // -------------------------------------------------------
    // 错误注入标志（测试场景5使用）
    // -------------------------------------------------------
    reg force_slverr;

    // -------------------------------------------------------
    // AXI4 读从机模型（AR + R 通道）
    //
    // 【设计要点】
    //   采用"预装载"策略：
    //   ① AR 接受的同一拍内，立即装入 beat-0 的数据并置 rvalid=1
    //   ② 每次 rvalid & rready 握手（当前拍被接受）后，
    //      立即装入下一拍（beat+1）的数据；若为最后一拍则撤销 rvalid
    //   这样保证 rdata 始终超前当前握手一拍，满足 AXI4 时序要求。
    // -------------------------------------------------------
    reg [31:0] rd_base_addr;
    reg [7:0]  rd_burst_len;
    reg [7:0]  rd_beat_cnt;
    reg        rd_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready      <= 1'b0;
            rd_active    <= 1'b0;
            rd_base_addr <= 32'b0;
            rd_burst_len <= 8'b0;
            rd_beat_cnt  <= 8'b0;
            rvalid       <= 1'b0;
            rdata        <= 32'b0;
            rresp        <= 2'b00;
            rlast        <= 1'b0;
            rid          <= 1'b0;
        end else begin
            arready <= 1'b0; // 每周期默认拉低

            // ---- AR 通道：接受地址，预装 beat-0 数据 ----
            if (arvalid && !rd_active) begin
                arready      <= 1'b1;
                rd_base_addr <= araddr;
                rd_burst_len <= arlen;
                rd_beat_cnt  <= 8'b0;
                rd_active    <= 1'b1;
                // 立即预装第0拍数据，置 rvalid=1
                rvalid <= 1'b1;
                rdata  <= force_slverr ? 32'hBAD_BEEF : mem[araddr >> 2];
                rresp  <= force_slverr ? 2'b10 : 2'b00;
                rlast  <= (arlen == 8'b0); // 若只有1拍，直接置 rlast
                rid    <= 1'b0;
            end

            // ---- R 通道：握手后预装下一拍 ----
            // 注意：AR 和 R 两个分支互斥（rd_active 条件保证）
            if (rvalid && rready) begin
                if (rlast) begin
                    // 最后一拍被接受，本次突发结束
                    rvalid    <= 1'b0;
                    rd_active <= 1'b0;
                end else begin
                    // 预装下一拍：beat_cnt 递增，更新 rdata/rlast
                    rd_beat_cnt <= rd_beat_cnt + 8'd1;
                    rdata  <= force_slverr ? 32'hBAD_BEEF :
                              mem[(rd_base_addr >> 2) + rd_beat_cnt + 8'd1];
                    rresp  <= force_slverr ? 2'b10 : 2'b00;
                    rlast  <= (rd_beat_cnt + 8'd1 == rd_burst_len);
                end
            end
        end
    end

    // -------------------------------------------------------
    // AXI4 写从机模型（AW + W + B 通道）
    // -------------------------------------------------------
    reg [31:0] wr_base_addr;
    reg [7:0]  wr_beat_cnt;
    reg        wr_addr_rcvd;
    reg        wr_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awready      <= 1'b0;
            wready       <= 1'b0;
            bvalid       <= 1'b0;
            bresp        <= 2'b00;
            bid          <= 1'b0;
            wr_base_addr <= 32'b0;
            wr_beat_cnt  <= 8'b0;
            wr_addr_rcvd <= 1'b0;
            wr_active    <= 1'b0;
        end else begin
            awready <= 1'b0; // 每周期默认拉低

            // ---- AW 通道握手 ----
            if (awvalid && !wr_addr_rcvd && !wr_active) begin
                awready      <= 1'b1;
                wr_base_addr <= awaddr;
                wr_beat_cnt  <= 8'b0;
                wr_addr_rcvd <= 1'b1;
            end

            // ---- W 通道数据接收 ----
            if (wr_addr_rcvd) begin
                wready    <= 1'b1;
                wr_active <= 1'b1;
                if (wvalid && wready) begin
                    mem[(wr_base_addr >> 2) + wr_beat_cnt] <= wdata;
                    if (wlast) begin
                        // 最后一拍：撤销 wready，发送写响应
                        wready       <= 1'b0;
                        wr_addr_rcvd <= 1'b0;
                        wr_active    <= 1'b0;
                        bvalid       <= 1'b1;
                        bresp        <= 2'b00;
                        bid          <= 1'b0;
                    end else begin
                        wr_beat_cnt <= wr_beat_cnt + 8'd1;
                    end
                end
            end

            // ---- B 通道握手 ----
            if (bvalid && bready) begin
                bvalid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------
    // 任务：写寄存器（在下降沿驱动，上升沿采样）
    // -------------------------------------------------------
    task reg_write;
        input [3:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            reg_addr    = addr;
            reg_wr_en   = 1'b1;
            reg_wr_data = data;
            @(negedge clk);
            reg_wr_en   = 1'b0;
        end
    endtask

    // -------------------------------------------------------
    // 任务：读寄存器（同步读，需等待一个时钟）
    // -------------------------------------------------------
    task reg_read;
        input  [3:0]  addr;
        output [31:0] data;
        begin
            @(negedge clk);
            reg_addr  = addr;
            reg_rd_en = 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            data      = reg_rd_data;
            reg_rd_en = 1'b0;
        end
    endtask

    // -------------------------------------------------------
    // Verdi/VPD 波形导出
    // -------------------------------------------------------
    initial begin
`ifdef VERDI
        $fsdbDumpfile("tb_axi4_dma.fsdb");
        $fsdbDumpvars(0, tb_axi4_dma);
`else
        $dumpfile("tb_axi4_dma.vcd");
        $dumpvars(0, tb_axi4_dma);
`endif
    end

    // -------------------------------------------------------
    // 测试主程序
    // -------------------------------------------------------
    reg [31:0] rd_val;
    integer    i_chk;
    integer    fail_cnt;

    initial begin
        // 初始化驱动信号
        rst_n        = 1'b0;
        reg_addr     = 4'b0;
        reg_wr_en    = 1'b0;
        reg_rd_en    = 1'b0;
        reg_wr_data  = 32'b0;
        force_slverr = 1'b0;

        // 复位 5 个周期（异步低电平复位）
        repeat(5) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat(3) @(posedge clk);

        // ==================================================
        // 测试1：简单 M2M 传输（4字节 = 1拍）
        //   验证：基本握手、完成状态位、中断、数据正确性
        // ==================================================
        $display("\n========== TEST1: 简单 M2M 传输（4字节）==========");
        mem[32'h100 >> 2] = 32'hA5A5_1234;
        mem[32'h200 >> 2] = 32'h0; // 清除目的地

        reg_write(4'h1, 32'h0000_0100); // 源地址 = 0x100
        reg_write(4'h2, 32'h0000_0200); // 目的地址 = 0x200
        reg_write(4'h3, 32'h0000_0004); // 长度 = 4 字节
        // ctrl: bit0=start, bit2=done_intr_en
        reg_write(4'h0, 32'h0000_0005);

        // 等待完成（轮询状态寄存器）
        repeat(200) @(posedge clk);

        reg_read(4'h4, rd_val);
        $display("TEST1 状态寄存器 = 0x%08X（期望 bit1=1）", rd_val);
        if (rd_val[1])
            $display("TEST1 PASS: 传输完成！");
        else
            $display("TEST1 FAIL: 传输未完成！");

        if (mem[32'h200 >> 2] == 32'hA5A5_1234)
            $display("TEST1 数据验证 PASS: mem[0x200]=0x%08X", mem[32'h200>>2]);
        else
            $display("TEST1 数据验证 FAIL: mem[0x200]=0x%08X（期望 0xA5A51234）",
                     mem[32'h200>>2]);

        $display("TEST1 dma_intr = %b（期望 1）", dma_intr);
        reg_write(4'h4, 32'h0000_0002); // W1C：清除 done 位
        repeat(3) @(posedge clk);
        $display("TEST1 清除后 dma_intr = %b（期望 0）", dma_intr);

        // ==================================================
        // 测试2：多突发 M2M 传输（128字节 = 32拍 = 2×16拍突发）
        //   验证：burst 分割逻辑、多轮读写、地址递增正确性
        // ==================================================
        $display("\n========== TEST2: 多突发 M2M 传输（128字节）==========");
        for (i_chk = 0; i_chk < 32; i_chk = i_chk + 1) begin
            mem[(32'h300 >> 2) + i_chk] = 32'hBEEF_0000 + i_chk;
            mem[(32'h500 >> 2) + i_chk] = 32'h0; // 清除目的地
        end

        reg_write(4'h1, 32'h0000_0300); // 源地址 = 0x300
        reg_write(4'h2, 32'h0000_0500); // 目的地址 = 0x500
        reg_write(4'h3, 32'h0000_0080); // 长度 = 128 字节
        reg_write(4'h0, 32'h0000_0005); // start + done_intr_en

        repeat(800) @(posedge clk);

        reg_read(4'h4, rd_val);
        $display("TEST2 状态寄存器 = 0x%08X", rd_val);
        if (rd_val[1])
            $display("TEST2 PASS: 多突发传输完成！");
        else
            $display("TEST2 FAIL: 多突发传输未完成！");

        fail_cnt = 0;
        for (i_chk = 0; i_chk < 32; i_chk = i_chk + 1) begin
            if (mem[(32'h500 >> 2) + i_chk] !== (32'hBEEF_0000 + i_chk)) begin
                $display("TEST2 数据[%0d] FAIL: 得到 0x%08X，期望 0x%08X",
                         i_chk, mem[(32'h500>>2)+i_chk], 32'hBEEF_0000+i_chk);
                fail_cnt = fail_cnt + 1;
            end
        end
        if (fail_cnt == 0)
            $display("TEST2 数据验证全部 PASS（32个字）");
        else
            $display("TEST2 数据验证 %0d 个字 FAIL", fail_cnt);

        reg_write(4'h4, 32'h0000_0002);

        // ==================================================
        // 测试3：源地址非4字节对齐 → 应触发错误
        // ==================================================
        $display("\n========== TEST3: 非对齐地址应触发错误 ==========");
        reg_write(4'h1, 32'h0000_0101); // 0x101：非4字节对齐
        reg_write(4'h2, 32'h0000_0200);
        reg_write(4'h3, 32'h0000_0004);
        // ctrl: bit0=start, bit3=err_intr_en
        reg_write(4'h0, 32'h0000_0009);

        repeat(20) @(posedge clk);

        reg_read(4'h4, rd_val);
        $display("TEST3 状态寄存器 = 0x%08X（期望 bit2=1）", rd_val);
        if (rd_val[2])
            $display("TEST3 PASS: 非对齐错误正确检测！");
        else
            $display("TEST3 FAIL: 非对齐错误未检测到！");

        $display("TEST3 dma_intr = %b（期望 1）", dma_intr);
        reg_write(4'h4, 32'h0000_0004);

        // ==================================================
        // 测试4：传输长度非4字节对齐 → 应触发错误
        // ==================================================
        $display("\n========== TEST4: 传输长度非对齐应报错 ==========");
        reg_write(4'h1, 32'h0000_0100);
        reg_write(4'h2, 32'h0000_0200);
        reg_write(4'h3, 32'h0000_0003); // 3字节：非4的倍数
        reg_write(4'h0, 32'h0000_0009); // start + err_intr_en

        repeat(20) @(posedge clk);

        reg_read(4'h4, rd_val);
        if (rd_val[2])
            $display("TEST4 PASS: 长度非对齐错误正确检测！");
        else
            $display("TEST4 FAIL: 长度非对齐错误未检测到！");

        reg_write(4'h4, 32'h0000_0004);

        // ==================================================
        // 测试5：AXI 总线错误（SLVERR）→ 触发错误中断
        // ==================================================
        $display("\n========== TEST5: AXI SLVERR 触发错误中断 ==========");
        force_slverr = 1'b1;

        reg_write(4'h1, 32'h0000_0100);
        reg_write(4'h2, 32'h0000_0200);
        reg_write(4'h3, 32'h0000_0004);
        reg_write(4'h0, 32'h0000_0009); // start + err_intr_en

        repeat(100) @(posedge clk);

        reg_read(4'h4, rd_val);
        $display("TEST5 状态寄存器 = 0x%08X（期望 bit2=1）", rd_val);
        if (rd_val[2])
            $display("TEST5 PASS: SLVERR 错误中断正确触发！");
        else
            $display("TEST5 FAIL: SLVERR 错误中断未触发！");

        force_slverr = 1'b0;
        reg_write(4'h4, 32'h0000_0004);

        // ==================================================
        // 仿真结束
        // ==================================================
        $display("\n========== 仿真完成 ==========");
        repeat(10) @(posedge clk);
        $finish;
    end

    // -------------------------------------------------------
    // 超时保护（1ms）
    // -------------------------------------------------------
    initial begin
        #1_000_000;
        $display("[ERROR] 仿真超时，强制终止！");
        $finish;
    end

endmodule
