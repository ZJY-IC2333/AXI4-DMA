# ============================================================
# 综合约束文件：axi4_dma.sdc
# 工具：Design Compiler 2018.06-SP1
# 设计：axi4_dma_top
# 工艺：假设 100MHz 工作频率（10ns 时钟周期）
# ============================================================

# ============================================================
# 一、时钟约束
# ============================================================
# 主时钟：100MHz，占空比 50%，从 clk 引脚驱动
create_clock -name "clk" \
    -period 10.0         \
    -waveform {0 5.0}    \
    [get_ports clk]

# 设置时钟不确定性（时钟抖动 + 偏斜裕量）
# jitter：150ps（典型 PLL 抖动），skew：100ps（板级走线偏斜）
set_clock_uncertainty -setup 0.25 [get_clocks clk]
set_clock_uncertainty -hold  0.10 [get_clocks clk]

# 设置时钟转换时间（输入时钟边沿斜率）
set_clock_transition 0.1 [get_clocks clk]

# ============================================================
# 二、复位约束（异步低电平复位，不参与时序分析）
# ============================================================
set_false_path -from [get_ports rst_n]

# ============================================================
# 三、输入延迟约束
# 假设外部逻辑距离本模块的最大延迟为时钟周期的 40%（4ns），
# 最小延迟为 0.5ns（保持时间裕量）
# ============================================================

# 寄存器配置接口输入
set_input_delay -clock clk -max 4.0 [get_ports {reg_addr reg_wr_en reg_rd_en reg_wr_data}]
set_input_delay -clock clk -min 0.5 [get_ports {reg_addr reg_wr_en reg_rd_en reg_wr_data}]

# AXI4 从机响应信号（读通道）
set_input_delay -clock clk -max 4.0 [get_ports {arready}]
set_input_delay -clock clk -min 0.5 [get_ports {arready}]

set_input_delay -clock clk -max 4.0 [get_ports {rid rdata rresp rlast rvalid}]
set_input_delay -clock clk -min 0.5 [get_ports {rid rdata rresp rlast rvalid}]

# AXI4 从机响应信号（写通道）
set_input_delay -clock clk -max 4.0 [get_ports {awready}]
set_input_delay -clock clk -min 0.5 [get_ports {awready}]

set_input_delay -clock clk -max 4.0 [get_ports {wready}]
set_input_delay -clock clk -min 0.5 [get_ports {wready}]

set_input_delay -clock clk -max 4.0 [get_ports {bid bresp bvalid}]
set_input_delay -clock clk -min 0.5 [get_ports {bid bresp bvalid}]

# ============================================================
# 四、输出延迟约束
# 假设下游逻辑需要在时钟周期后 40%（4ns）之前稳定，
# 最短输出延迟（保持时间）为 0.5ns
# ============================================================

# 寄存器读数据输出
set_output_delay -clock clk -max 4.0 [get_ports {reg_rd_data}]
set_output_delay -clock clk -min 0.5 [get_ports {reg_rd_data}]

# AXI4 读地址通道输出
set_output_delay -clock clk -max 4.0 [get_ports {arid araddr arlen arsize arburst arvalid}]
set_output_delay -clock clk -min 0.5 [get_ports {arid araddr arlen arsize arburst arvalid}]

# AXI4 读数据通道输出
set_output_delay -clock clk -max 4.0 [get_ports {rready}]
set_output_delay -clock clk -min 0.5 [get_ports {rready}]

# AXI4 写地址通道输出
set_output_delay -clock clk -max 4.0 [get_ports {awid awaddr awlen awsize awburst awvalid}]
set_output_delay -clock clk -min 0.5 [get_ports {awid awaddr awlen awsize awburst awvalid}]

# AXI4 写数据通道输出（wdata 为组合逻辑，使用更宽松约束）
set_output_delay -clock clk -max 5.0 [get_ports {wdata wstrb wlast wvalid}]
set_output_delay -clock clk -min 0.5 [get_ports {wdata wstrb wlast wvalid}]

# AXI4 写响应通道输出
set_output_delay -clock clk -max 4.0 [get_ports {bready}]
set_output_delay -clock clk -min 0.5 [get_ports {bready}]

# 中断输出（时序要求相对宽松）
set_output_delay -clock clk -max 5.0 [get_ports {dma_intr}]
set_output_delay -clock clk -min 0.5 [get_ports {dma_intr}]

# ============================================================
# 五、面积与功耗约束（可选，根据目标工艺调整）
# ============================================================
# 最大面积约束（0 = 尽量最小化）
# set_max_area 0

# ============================================================
# 六、综合优化目标
# ============================================================
# 设置设计规则：最大扇出
set_max_fanout 20 [current_design]

# 设置驱动强度（输入端口等效驱动）
set_driving_cell -lib_cell <YOUR_LIBRARY_BUFFER_CELL> [all_inputs]

# 设置负载（输出端口等效负载）
set_load 0.05 [all_outputs]

# ============================================================
# 注意事项：
#   1. <YOUR_LIBRARY_BUFFER_CELL> 需替换为实际工艺库中的
#      缓冲器单元名（如 BUFX1、BUF_X1 等）
#   2. 工艺库相关参数（如 set_driving_cell, set_load）
#      需根据目标工艺库调整
#   3. 时序约束已考虑 100MHz 工作频率，如需更高频率
#      请相应收紧 set_clock_uncertainty 和延迟约束
# ============================================================
