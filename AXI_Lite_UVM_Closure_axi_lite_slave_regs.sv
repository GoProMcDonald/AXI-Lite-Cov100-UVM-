// =====================================
// 简化的 AXI-Lite 从设备（寄存器阵列）
// - ready 恒 1，方便闭环打通
// - 写支持 WSTRB
// =====================================
module axi_lite_slave_regs(
  input  logic        clk,
  input  logic        rst_n,

  // AW
  input  logic [31:0] awaddr,
  input  logic        awvalid,
  output logic        awready,

  // W
  input  logic [31:0] wdata,
  input  logic  [3:0] wstrb,
  input  logic        wvalid,
  output logic        wready,

  // B
  output logic  [1:0] bresp,
  output logic        bvalid,
  input  logic        bready,

  // AR
  input  logic [31:0] araddr,
  input  logic        arvalid,
  output logic        arready,

  // R
  output logic [31:0] rdata,
  output logic  [1:0] rresp,
  output logic        rvalid,
  input  logic        rready
);

  // 256 x 32-bit
  logic [31:0] mem [0:255];

  // 就绪恒 1（smoke）
  assign awready = 1'b1;
  assign wready  = 1'b1;
  assign arready = 1'b1;

  // 写响应 & 写入
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bvalid <= 1'b0; bresp <= 2'b00;
    end else begin
      if (awvalid && wvalid) begin
        if (wstrb[0]) mem[awaddr[9:2]][ 7: 0] <= wdata[ 7: 0];
        if (wstrb[1]) mem[awaddr[9:2]][15: 8] <= wdata[15: 8];
        if (wstrb[2]) mem[awaddr[9:2]][23:16] <= wdata[23:16];
        if (wstrb[3]) mem[awaddr[9:2]][31:24] <= wdata[31:24];
        bvalid <= 1'b1; bresp <= 2'b00; // OKAY
        $display("[%0t] DUT >>> set BVALID=1 (AW/W handshake)", $time);
      end 
      else if (bvalid && bready) begin
        bvalid <= 1'b0;
        $display("[%0t] DUT >>> clear BVALID (bready=1)", $time);
      end
    end
  end

  // 读通道
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rvalid <= 1'b0; rresp <= 2'b00; rdata <= '0;
    end else begin
      if (arvalid) begin
        rdata  <= mem[araddr[9:2]];
        rresp  <= 2'b00; // OKAY
        rvalid <= 1'b1;
      end else if (rvalid && rready) begin
        rvalid <= 1'b0;
      end
    end
  end

endmodule
