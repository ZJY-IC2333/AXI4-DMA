// ============================================================
// 模块名  : dma_intr_gen
// 功能    : DMA 中断生成模块
//           根据状态位和使能位生成电平触发中断信号
//
// 【中断生成条件与时序说明】
//   1. 完成中断：状态寄存器 done_status=1 且 intr_done_en=1
//   2. 错误中断：状态寄存器 err_status=1  且 intr_err_en=1
//   3. dma_intr 为电平信号，持续有效直到对应状态位被清除
//      （用户向状态寄存器写 1 清零对应位，中断随即撤销）
//   4. 中断信号的建立延迟：xfer_done/xfer_err 脉冲到达后，
//      寄存器控制模块在下一个时钟上升沿锁存 done/err 状态位，
//      dma_intr 在该时钟沿后的组合逻辑传播延迟内变为有效。
// ============================================================
`timescale 1ns/1ps

module dma_intr_gen (
    // ===== 状态位输入（来自 dma_reg_ctrl）=====
    input  wire done_status,   // 传输完成状态位
    input  wire err_status,    // 总线错误状态位

    // ===== 中断使能输入（来自 dma_reg_ctrl）=====
    input  wire intr_done_en,  // 完成中断使能
    input  wire intr_err_en,   // 错误中断使能

    // ===== 中断输出 =====
    output wire dma_intr       // 中断输出（高电平有效，电平触发）
);

    // -------------------------------------------------------
    // 组合逻辑：任意一路有效中断均置高 dma_intr
    // -------------------------------------------------------
    assign dma_intr = (done_status & intr_done_en) |
                      (err_status  & intr_err_en);

endmodule
