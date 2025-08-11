`timescale 1ns/1ns
`include "AXI_Lite_UVM_Closure_my_pkg.sv"

import uvm_pkg::*;
import my_pkg::*;

module tb_top;

  // 1) 时钟/复位
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // 2) 接口
  axi_if vif(.clk(clk), .rst_n(rst_n));

  // 3) DUT 实例化
  axi_lite_slave_regs dut (
    .clk    (clk),
    .rst_n  (rst_n),
    // AW
    .awaddr (vif.awaddr), .awvalid(vif.awvalid), .awready(vif.awready),
    // W
    .wdata  (vif.wdata),  .wstrb  (vif.wstrb),   .wvalid (vif.wvalid), .wready(vif.wready),
    // B
    .bresp  (vif.bresp),  .bvalid (vif.bvalid),  .bready(vif.bready),
    // AR
    .araddr (vif.araddr), .arvalid(vif.arvalid), .arready(vif.arready),
    // R
    .rdata  (vif.rdata),  .rresp  (vif.rresp),   .rvalid (vif.rvalid), .rready(vif.rready)
  );

  // 2) 把“同一只 vif”塞给 agent
  initial begin
      uvm_config_db#(virtual axi_if)::set(null, "uvm_test_top.m_env.agent", "vif", vif);
  end

  // 4) 复位 + 默认驱动
  initial begin
    vif.drive_defaults();
    repeat (5) @(posedge clk);
    rst_n = 1;
  end

  // 5) 波形
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_top);
    $dumpvars(0, tb_top.dut);
  end

  // 6) UVM 启动
  initial begin
    uvm_config_db#(virtual axi_if)::set(null, "*", "vif", vif);
    uvm_root::get().finish_on_completion = 1;
    uvm_root::get().set_timeout(20us, 1); // 缩短超时，EPWave 不会过长
    run_test("axi_cov_test");            // 或 "axi_cov_test"
  end
  int cyc = 0;
  always @(posedge clk) begin
    if (cyc < 20) begin
      $display("[%0t] PROBE cyc=%0d  awv=%0b wv=%0b bvalid=%0b bready=%0b  arvv=%0b rvalid=%0b",
              $time, cyc, vif.awvalid, vif.wvalid, vif.bvalid, vif.bready, vif.arvalid, vif.rvalid);
      cyc++;
    end
  end
endmodule
