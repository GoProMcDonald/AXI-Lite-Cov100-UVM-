// axi_if.sv
interface axi_if(
  input  logic clk,
  input  logic rst_n
);

  // =========================
  // AXI-Lite 信号定义（原有）
  // =========================
  // Write address channel
  logic [31:0] awaddr;
  logic        awvalid;
  logic        awready;

  // Write data channel
  logic [31:0] wdata;
  logic  [3:0] wstrb;
  logic        wvalid;
  logic        wready;

  // Write response channel
  logic  [1:0] bresp;
  logic        bvalid;
  logic        bready;

  // Read address channel
  logic [31:0] araddr;
  logic        arvalid;
  logic        arready;

  // Read data channel
  logic [31:0] rdata;
  logic  [1:0] rresp;
  logic        rvalid;
  logic        rready;

  // 默认驱动，复位后把 master 侧清零（原有）
  task automatic drive_defaults();
    awaddr  <= '0; awvalid <= 0;
    wdata   <= '0; wstrb   <= 4'hF; wvalid <= 0;
    bready  <= 0;
    araddr  <= '0; arvalid <= 0;
    rready  <= 0;
  endtask


  // =========================
  // SVA（断言）——原有基础
  // =========================
  `define DISABLE_IF disable iff(!rst_n)

  // 1) VALID 必须保持到 READY
  property p_valid_stays_high(valid, ready);//定义一个属性：valid 必须保持直到 ready
    @(posedge clk) `DISABLE_IF (valid && !ready) |=> valid;//如果 valid 为 1 且 ready 为 0，则在下一个时钟周期 valid 仍然为 1
  endproperty
  a_awvalid_hold: assert property (p_valid_stays_high(awvalid, awready));//对 awvalid 应用该属性
  a_wvalid_hold : assert property (p_valid_stays_high(wvalid,  wready));//对 wvalid 应用该属性
  a_arvalid_hold: assert property (p_valid_stays_high(arvalid, arready));//对 arvalid 应用该属性
  a_rvalid_hold : assert property (p_valid_stays_high(rvalid,  rready));//对 rvalid 应用该属性
  a_bvalid_hold : assert property (p_valid_stays_high(bvalid,  bready));//对 bvalid 应用该属性

  // 2) 等待握手期间，地址/数据保持稳定
  property p_stable_when_wait(valid, ready, sig);//定义一个属性：在 valid 为 1 且 ready 为 0 时，sig 必须保持稳定
    @(posedge clk) `DISABLE_IF (valid && !ready) |=> $stable(sig);//如果 valid 为 1 且 ready 为 0，则在下一个时钟周期 sig 必须保持稳定
  endproperty
  a_awaddr_stable: assert property (p_stable_when_wait(awvalid, awready, awaddr));// 对 awaddr 应用该属性
  a_araddr_stable: assert property (p_stable_when_wait(arvalid, arready, araddr));// 对 araddr 应用该属性
  a_wdata_stable : assert property (p_stable_when_wait(wvalid,  wready,  wdata));// 对 wdata 应用该属性


  // =========================
  // （新增）断言覆盖 + 联动采样
  // =========================

  // NEW: 单拍握手脉冲（作为“有效事务”的采样使能）
  logic aw_hs, w_hs, ar_hs, r_hs;                   // NEW, 定义 4 个“握手成功”的单拍脉冲信号
  assign aw_hs = awvalid && awready;                // NEW 写地址握手成功条件
  assign w_hs  = wvalid  && wready;                 // NEW 写数据握手成功条件
  assign ar_hs = arvalid && arready;                // NEW 读地址握手成功条件
  assign r_hs  = rvalid  && rready;                 // NEW 读数据握手成功条件

  // NEW: VALID→READY 的等待拍数统计（衡量 backpressure 强度）
  int aw_wait, w_wait, ar_wait, r_wait;             // NEW 等待拍数计数器：记录 valid 拉起后等了多少拍才 ready/rready
  always @(posedge clk or negedge rst_n) begin      // NEW  
    if (!rst_n) begin                               // NEW
      aw_wait <= 0; w_wait <= 0; ar_wait <= 0; r_wait <= 0; //所有等待计数清零
    end else begin                                  // NEW
      // AW：拉高但未 ready 就计数；握手或取消则清零        // NEW
      if (awvalid && !awready) aw_wait <= aw_wait + 1;  // NEW 如果 valid=1 且 ready=0，等待+1
      else if (aw_hs)          aw_wait <= 0;            // NEW 完成握手时清零
      else if (!awvalid)       aw_wait <= 0;            // NEW valid 拉低也清零

      // W                                                   // NEW
      if (wvalid && !wready) w_wait <= w_wait + 1;         // NEW
      else if (w_hs)         w_wait <= 0;                  // NEW
      else if (!wvalid)      w_wait <= 0;                  // NEW

      // AR                                                  // NEW
      if (arvalid && !arready) ar_wait <= ar_wait + 1;     // NEW
      else if (ar_hs)          ar_wait <= 0;               // NEW
      else if (!arvalid)       ar_wait <= 0;               // NEW

      // R：更多表示“响应延迟”，rvalid 拉起但 rready=0 时累加 // NEW
      if (rvalid && !rready) r_wait <= r_wait + 1;         // NEW r：这边统计的是 rvalid 已出但主机没接收（rready=0）的等待
      else if (r_hs)         r_wait <= 0;                  // NEW 一旦 rvalid&rready 同拍握手成功就清零
      else if (!rvalid)      r_wait <= 0;                  // NEW rvalid 拉低也清零
    end
  end

  // NEW: 断言覆盖（cover property）——这些会进 URG 的 Assertion Coverage
  cover_aw_eventually_ready: cover property (@(posedge clk) `DISABLE_IF awvalid |-> ##[0:$] awready);  //有 awvalid 后最终出现过 awready
  cover_w_eventually_ready : cover property (@(posedge clk) `DISABLE_IF wvalid  |-> ##[0:$] wready );  //有 wvalid 后最终出现过 wready
  cover_ar_eventually_ready: cover property (@(posedge clk) `DISABLE_IF arvalid |-> ##[0:$] arready);  //有 arvalid 后最终出现过 arready
  cover_b_after_aw_w       : cover property (@(posedge clk) `DISABLE_IF                                        // 写地址+写数据都握手后
                                            (awvalid && awready) ##[0:$] (wvalid && wready) ##[0:$] bvalid);  //最终出现过 bvalid
  cover_r_after_ar         : cover property (@(posedge clk) `DISABLE_IF                                        //读地址握手之后
                                            (arvalid && arready) ##[0:$] rvalid);                              //最终出现过 rvalid


  // =========================
  // 功能覆盖（原有 + 新增联动版）
  // =========================

  // 原有：简化版（保留也可以）
  covergroup cg_axi @(posedge clk);
    option.per_instance = 1;
    coverpoint awvalid iff (rst_n) { bins awv0 = {0}; bins awv1 = {1}; }
    coverpoint wvalid  iff (rst_n) { bins wv0  = {0}; bins wv1  = {1}; }
    coverpoint arvalid iff (rst_n) { bins arv0 = {0}; bins arv1 = {1}; }
    coverpoint awaddr  iff (rst_n) { bins low  = {[0:255]}; bins high = {[256:4095]}; }
    // 修：把 large 拉到 32bit 上限，避免大数据不计入任何 bin
    coverpoint wdata   iff (rst_n) { //写数据分桶
      bins bin_small  = {[0:127]}; //小数值
      bins bin_medium = {[128:255]}; //中等数值
      bins bin_large  = {[256:32'hFFFF_FFFF]}; //大数值
    }
    cross awvalid, wvalid;//交叉：观察 awvalid 和 wvalid 的组合
  endgroup
  cg_axi u_cg_axi = new();//实例化覆盖组

  // NEW：联动版功能覆盖——仅在“握手成功”的那个时刻采样
  covergroup cg_axi_hs @(posedge clk);
    option.per_instance = 1;
    option.goal = 100; // 目标 100%

    // 等待拍数：由于 aw/w/ar 通道 ready 恒为 1，>0 的等待不可达，标为 ignore
    cp_aw_wait : coverpoint aw_wait iff (rst_n && aw_hs) {
      bins z = {0};
      ignore_bins unreachable = {[1:$]};
    }

    cp_w_wait  : coverpoint w_wait  iff (rst_n && w_hs) {
      bins z = {0};
      ignore_bins unreachable = {[1:$]};
    }

    cp_ar_wait : coverpoint ar_wait iff (rst_n && ar_hs) {
      bins z = {0};
      ignore_bins unreachable = {[1:$]};
    }

    // R 通道我们可通过拉低 rready 制造等待 → 保留分桶
    cp_r_wait  : coverpoint r_wait  iff (rst_n && r_hs) {
      bins z = {0};
      bins s = {[1:3]};
      bins m = {[4:15]};
      bins l = {[16:$]};
    }

    // 取值覆盖（在握手成功时采样，确保都是有效事务）
    cp_awaddr  : coverpoint awaddr iff (rst_n && aw_hs) {
      bins low  = {[0:255]};
      bins high = {[256:4095]};
    }

    cp_wstrb   : coverpoint wstrb  iff (rst_n && w_hs) {
      bins mask[] = {4'h1, 4'h3, 4'hC, 4'hF};
    }

    cp_wdata   : coverpoint wdata  iff (rst_n && w_hs) {
      bins b_small  = {[0:127]};
      bins b_medium = {[128:255]};
      bins b_large  = {[256:$]};
    }

    // 有意义的交叉：背压（可控的 r_wait） × WSTRB
    x_rwait_wstrb : cross cp_r_wait, cp_wstrb;
  endgroup
  cg_axi_hs u_cg_axi_hs = new();                                                 // 实例化联动版覆盖组

endinterface : axi_if
