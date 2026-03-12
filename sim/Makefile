# ============================================================
# Makefile：AXI4 DMA 仿真脚本（VCS 2018.09-SP2 + Verdi）
#
# 使用方法：
#   make compile   - 编译 RTL 和 testbench
#   make sim       - 运行仿真（命令行输出）
#   make verdi     - 启动 Verdi 查看波形（需要先运行 sim）
#   make all       - 编译 + 运行仿真
#   make clean     - 清理编译产物
#
# 波形格式：
#   - 带 VERDI 宏：生成 .fsdb 波形（推荐，Verdi 原生格式）
#   - 不带 VERDI 宏：生成 .vcd 波形（通用格式）
# ============================================================

# ---- 工具路径（根据实际安装路径修改）----
VCS    = vcs
VERDI  = verdi

# ---- 设计顶层和 Testbench ----
TOP_MODULE  = tb_axi4_dma
RTL_TOP     = axi4_dma_top

# ---- 源文件列表 ----
RTL_FILES = \
    ../rtl/dma_reg_ctrl.v  \
    ../rtl/dma_axi_rd_ch.v \
    ../rtl/dma_axi_wr_ch.v \
    ../rtl/dma_xfer_ctrl.v \
    ../rtl/dma_intr_gen.v  \
    ../rtl/axi4_dma_top.v

TB_FILES  = ../tb/tb_axi4_dma.v

# ---- VCS 编译选项 ----
# -full64     : 64位模式
# -sverilog   : 支持 SystemVerilog（兼容 Verilog-2001）
# -timescale  : 默认时间单位/精度
# -debug_acc  : 使能调试访问（Verdi 需要）
# -kdb        : 生成 Verdi KDB 数据库
# +define+VERDI : 启用 fsdbDumpfile（Verdi 波形）
VCS_COMPILE_OPTS = \
    -full64                \
    -sverilog              \
    -timescale=1ns/1ps     \
    -debug_acc+all         \
    -kdb                   \
    +define+VERDI          \
    +v2k                   \
    -notice                \
    -l compile.log

# ---- 不带 Verdi 的编译选项（生成 VCD）----
VCS_COMPILE_OPTS_VCD = \
    -full64            \
    -sverilog          \
    -timescale=1ns/1ps \
    -notice            \
    -l compile.log

# ---- 仿真运行选项 ----
SIM_OPTS = \
    -l sim.log

# ---- 默认目标 ----
.PHONY: all compile sim verdi clean

all: compile sim

# ---- 编译目标（带 Verdi FSDB 支持）----
compile:
	$(VCS) $(VCS_COMPILE_OPTS) \
	    -o simv                \
	    $(RTL_FILES)           \
	    $(TB_FILES)
	@echo "=== 编译完成，可执行文件：simv ==="

# ---- 编译目标（仅 VCD，不需要 Verdi license）----
compile_vcd:
	$(VCS) $(VCS_COMPILE_OPTS_VCD) \
	    -o simv                    \
	    $(RTL_FILES)               \
	    $(TB_FILES)
	@echo "=== VCD 模式编译完成 ==="

# ---- 仿真运行 ----
sim: simv
	./simv $(SIM_OPTS)
	@echo "=== 仿真完成，日志：sim.log ==="

# ---- 启动 Verdi 查看波形 ----
verdi:
	$(VERDI)                                     \
	    -dbdir simv.daidir                       \
	    -ssf tb_axi4_dma.fsdb                    \
	    -top $(TOP_MODULE)                       \
	    $(RTL_FILES)                             \
	    $(TB_FILES)                              \
	    &

# ---- 清理 ----
clean:
	rm -rf simv simv.daidir csrc
	rm -f  *.log *.fsdb *.vcd *.key
	rm -f  ucli.key vc_hdrs.h
	@echo "=== 清理完成 ==="
