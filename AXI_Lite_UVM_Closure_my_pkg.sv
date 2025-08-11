// AXI_Lite_UVM_Closure_my_pkg.sv
`include "uvm_macros.svh"
package my_pkg;
  import uvm_pkg::*;

  // ------------------------------------------------------------
  // Types
  // ------------------------------------------------------------
  typedef enum {READ, WRITE} axi_cmd_e;

  // ------------------------------------------------------------
  // 3.1 Sequence Item
  // ------------------------------------------------------------
  class axi_seq_item extends uvm_sequence_item;
    rand bit is_write;  
    rand bit [31:0] addr;
    rand bit [31:0] wdata;
    rand bit [3:0]  wstrb;
    rand int unsigned rready_hold;
    rand axi_cmd_e  cmd;
    rand int unsigned aw_lead; // AW 比 W 提前的拍数
    rand int unsigned w_lead;  // W 比 AW 提前的拍数
    logic [31:0] rdata;
    
     // 读时先把 rready 拉低的拍数，默认0
      // -------- 约束 --------
    constraint c_cmd_mirror { cmd == (is_write ? WRITE : READ); }
    constraint c_wstrb      { wstrb inside {4'h1, 4'h3, 4'hC, 4'hF}; }
    constraint c_rhold      { rready_hold inside {[0:64]}; }
    constraint lead_exclusive { (aw_lead == 0) || (w_lead == 0); } // 不同时为正
    constraint lead_range     { aw_lead inside {[0:3]}; w_lead inside {[0:3]}; }

    // -------- 工厂注册 + 字段注册（只用 begin/end，一种宏就够）--------
    `uvm_object_utils_begin(axi_seq_item)
      `uvm_field_int   (is_write,     UVM_ALL_ON)
      `uvm_field_int   (addr,         UVM_ALL_ON)
      `uvm_field_int   (wdata,        UVM_ALL_ON)
      `uvm_field_int   (wstrb,        UVM_ALL_ON)
      `uvm_field_int   (rready_hold,  UVM_ALL_ON)
      `uvm_field_enum  (axi_cmd_e, cmd, UVM_ALL_ON)
      `uvm_field_int   (rdata,        UVM_ALL_ON | UVM_NOPRINT)
    `uvm_object_utils_end
    

    function new(string name="axi_seq_item");
      super.new(name); 
      wstrb       = 4'hF;
      rready_hold = 0;
    endfunction
  endclass

  // ------------------------------------------------------------
  // 3.2 Driver  —— 采用 negedge+阻塞赋值，电平等待不丢拍
  // ------------------------------------------------------------
  class axi_driver extends uvm_driver #(axi_seq_item);
    `uvm_component_utils(axi_driver)
    virtual axi_if vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "No virtual interface for driver")
    endfunction

    task drive_write(axi_seq_item tr);
      // 提前半拍准备信号（阻塞赋值避免 NBA 竞态）

        // 情况 A：AW 先行
      if (tr.aw_lead > 0 && tr.w_lead == 0) begin
        // 先拉 AW
        vif.awaddr  <= tr.addr;
        vif.awvalid <= 1'b1;
        repeat (tr.aw_lead) @(posedge vif.clk);  // 这几拍内 aw=1, w=0 → 命中 cross(1,0)

        // 再拉 W
        vif.wdata   <= tr.wdata;
        vif.wstrb   <= tr.wstrb;
        vif.wvalid  <= 1'b1;
      end

        // 情况 B：W 先行
      else if (tr.w_lead > 0 && tr.aw_lead == 0) begin
        // 先拉 W
        vif.wdata   <= tr.wdata;
        vif.wstrb   <= tr.wstrb;
        vif.wvalid  <= 1'b1;
        repeat (tr.w_lead) @(posedge vif.clk);   // 这几拍内 aw=0, w=1 → 命中 cross(0,1)

        // 再拉 AW
        vif.awaddr  <= tr.addr;
        vif.awvalid <= 1'b1;
      end

        // 情况 C：同时
      else begin
        vif.awaddr  <= tr.addr;
        vif.wdata   <= tr.wdata;
        vif.wstrb   <= tr.wstrb;
        vif.awvalid <= 1'b1;
        vif.wvalid  <= 1'b1;
      end

        // 等待 AW/W 各自握手并拉低
      do @(posedge vif.clk); while (!vif.awready);
      vif.awvalid <= 1'b0;

      do @(posedge vif.clk); while (!vif.wready);
      vif.wvalid  <= 1'b0;

      // 写响应
      vif.bready <= 1'b1;
      do @(posedge vif.clk); while (!vif.bvalid);
      @(posedge vif.clk);
      vif.bready <= 1'b0;

    endtask

    task drive_read(axi_seq_item tr);
      int unsigned hold = (tr.rready_hold === '0) ? 0 : tr.rready_hold;
      // 提前半拍准备地址与 rready
      vif.araddr  = tr.addr;
      vif.arvalid = 1'b1;

      // DUT 在下个 posedge 采到 ARVALID=1
      do@(posedge vif.clk); while (!vif.arready);
      vif.arvalid <=1'b0;

      // 收尾拉低 ARVALID
      vif.rready <= 1'b0;
      repeat (hold)@(negedge vif.clk); // 等待 hold 拍（如果 hold=0 则不等待）

      do@(posedge vif.clk); while (!vif.rvalid); // 等待 rvalid=1

      vif.rready <= 1'b1; // 拉高 rready，准备取数
      @(negedge vif.clk); // 等待 rready=1 的采样沿
      vif.rready <= 1'b0; // 拉低 rready，结束读操作

    endtask

    task run_phase(uvm_phase phase);
      axi_seq_item tr;
      vif.drive_defaults();
      @(posedge vif.clk);
      wait (vif.rst_n == 1);
      @(posedge vif.clk);
      vif.bready <= 1'b0;
      vif.rready <= 1'b0;
      forever begin
        `uvm_info("DRV", "waiting get_next_item...", UVM_LOW)
        seq_item_port.get_next_item(tr);
        `uvm_info("DRV", $sformatf("got item: cmd=%0d addr=%h", tr.cmd, tr.addr), UVM_LOW)
        if (tr.is_write) drive_write(tr);
        else                 drive_read(tr);
        seq_item_port.item_done();
      end
    endtask
  endclass

  // ------------------------------------------------------------
  // 3.3 Monitor
  // ------------------------------------------------------------
  class axi_monitor extends uvm_monitor;
    `uvm_component_utils(axi_monitor)
    virtual axi_if vif;
    uvm_analysis_port #(axi_seq_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "No virtual interface for monitor")
    endfunction

    task run_phase(uvm_phase phase);
      fork
        collect_write();
        collect_read();
      join_none
    endtask

    task collect_write();
      axi_seq_item tr;
      forever begin
        @(posedge vif.clk);
        if (vif.awvalid && vif.awready && vif.wvalid && vif.wready) begin
          tr = axi_seq_item::type_id::create("wr_tr", this);
          tr.cmd   = WRITE;
          tr.addr  = vif.awaddr;
          tr.wdata = vif.wdata;
          tr.wstrb = vif.wstrb;
          ap.write(tr);
        end
      end
    endtask

    task collect_read();
      axi_seq_item tr;
      forever begin
        @(posedge vif.clk);
        if (vif.arvalid && vif.arready) begin
          tr = axi_seq_item::type_id::create("rd_req", this);
          tr.cmd   = READ;
          tr.addr  = vif.araddr;
          tr.rdata = 'x;
          ap.write(tr);
        end
        if (vif.rvalid && vif.rready) begin
          tr = axi_seq_item::type_id::create("rd_rsp", this);
          tr.cmd   = READ;
          tr.rdata = vif.rdata;
          ap.write(tr);
        end
      end
    endtask
  endclass

  // ------------------------------------------------------------
  // 3.4 Scoreboard（黄金参考模型）
  // ------------------------------------------------------------
  class axi_scoreboard extends uvm_component;
    `uvm_component_utils(axi_scoreboard)
    uvm_analysis_imp #(axi_seq_item, axi_scoreboard) imp;

    bit [31:0] ref_mem [int unsigned];// 256 x 32-bit 寄存器模型,黄金参考模型：镜像内存，key=字地址（无符号 int）
    mailbox #(bit [31:0]) rd_addr_mbx;//读请求地址的邮箱（先进先出），配对读响应

      // NEW: 只在 READ OK 时采样的覆盖（正确性联动）
    covergroup cg_scb_ok;                                       //定义一个覆盖组，用来统计“读回正确”的情形
      option.per_instance = 1;                                  // 每个 scoreboard 实例单独统计
      cp_addr_ok  : coverpoint last_ok_addr[9:2] {              // 覆盖点：最近一次涉及的字地址（用高位段/低位段分桶）
      bins lo={[0:63]}; bins hi={[64:255]};                   // lo 桶 0~63，hi 桶 64~255
      }                                                         // 
      cp_wstrb_ok : coverpoint last_ok_wstrb {                  // 覆盖点：最近一次写的字节掩码
        bins mask[] = {4'h1,4'h3,4'hC,4'hF};                    //列表 bins：1、3、C、F 四种
      }                                                         // NEW
      x_ok : cross cp_addr_ok, cp_wstrb_ok;                     //  交叉：地址段 × 掩码
    endgroup
                                                     // NEW
    bit [31:0] last_ok_addr;                                    //缓存“最近一次写”的地址（供 READ OK 时采样）
    bit [3:0]  last_ok_wstrb;                                   // 缓存“最近一次写”的 wstrb（供 READ OK 时采样）

    function new(string name, uvm_component parent);
      super.new(name, parent);
      imp = new("imp", this);//创建 analysis_imp（连接 ap -> imp 的端点）
      rd_addr_mbx = new();//创建邮箱（读请求地址队列）
      cg_scb_ok = new();                                        // 实例化覆盖组（否则不能采样）
    endfunction

    function void build_phase(uvm_phase phase);                 // NEW
      super.build_phase(phase);                                 // NEW
    endfunction                                                 // NEW

    // 修好 else/end 配对
    function void write(axi_seq_item tr);//analysis_imp 回调：每来一个事务（tr）就会被调用
      bit [31:0] newval, addr_q, exp_val;//局部变量：newval=合成的新值，addr_q=配对的读地址，exp_val=期望值

      if (tr.cmd == WRITE) begin//如果是写事务
        newval = ref_mem.exists(tr.addr[9:2]) ? ref_mem[tr.addr[9:2]] : '0;//若参考内存已有该字地址，则取出原值，否则从 0 开始
        if (tr.wstrb[0]) newval[ 7: 0] = tr.wdata[ 7: 0];// 如果 wstrb[0] 有效，则更新低字节
        if (tr.wstrb[1]) newval[15: 8] = tr.wdata[15: 8];// 如果 wstrb[1] 有效，则更新次低字节
        if (tr.wstrb[2]) newval[23:16] = tr.wdata[23:16];// 如果 wstrb[2] 有效，则更新次高字节
        if (tr.wstrb[3]) newval[31:24] = tr.wdata[31:24];// 如果 wstrb[3] 有效，则更新高字节
        ref_mem[tr.addr[9:2]] = newval;// 更新参考内存（镜像内存）中的值,写回参考内存
        last_ok_addr  = tr.addr;                                //记录这次写的地址（用于后续 READ OK 的覆盖采样）
        last_ok_wstrb = tr.wstrb;                               //记录这次写的 wstrb（用于后续 READ OK 的覆盖采样）
      end
      else begin//如果是读事务
        if (tr.rdata === 'x) begin//如果读数据是 x（未定义）
          void'(rd_addr_mbx.try_put(tr.addr)); // 读请求入队
        end
        else begin//如果读数据是已定义的
          if (!rd_addr_mbx.try_get(addr_q)) begin// 尝试从邮箱获取配对的读地址
            `uvm_warning("SCB", "Read response without queued address, skipping compare")//如果邮箱中没有配对的读地址，则发出警告并跳过比较
            return;
          end
          exp_val = ref_mem.exists(addr_q[9:2]) ? ref_mem[addr_q[9:2]] : '0;// 期望值：参考内存中对应地址的值（如果没有则为 0）
          if (tr.rdata !== exp_val)// 如果读数据与期望值不匹配
            `uvm_error("SCB", $sformatf("READ MISMATCH @%0h: got=%0h exp=%0h", addr_q, tr.rdata, exp_val))//发出错误信息
          else begin// 如果读数据与期望值匹配
            `uvm_info("SCB", $sformatf("READ OK @%0h = %0h", addr_q, tr.rdata), UVM_LOW)//发出信息
            cg_scb_ok.sample();// NEW: 采样覆盖组（仅在 READ OK 时采样）
          end
        end
      end
    endfunction
  endclass

  // ------------------------------------------------------------
  // 3.5 Agent
  // ------------------------------------------------------------
  class axi_agent extends uvm_agent;
    `uvm_component_utils(axi_agent)
    virtual axi_if vif;
    uvm_sequencer #(axi_seq_item) sqr;
    axi_driver   drv;
    axi_monitor  mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "No virtual interface for agent")
      sqr = uvm_sequencer#(axi_seq_item)::type_id::create("sqr", this);
      drv = axi_driver::type_id::create("drv", this);
      mon = axi_monitor::type_id::create("mon", this);
      uvm_config_db#(virtual axi_if)::set(this, "drv", "vif", vif);
      uvm_config_db#(virtual axi_if)::set(this, "mon", "vif", vif);
    endfunction

    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // ------------------------------------------------------------
  // 3.6 Env
  // ------------------------------------------------------------
  class axi_env extends uvm_env;
    `uvm_component_utils(axi_env)
    axi_agent      agent;
    axi_scoreboard scb;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent = axi_agent     ::type_id::create("agent", this);
      scb   = axi_scoreboard::type_id::create("scb"  , this);
    endfunction

    function void connect_phase(uvm_phase phase);
      agent.mon.ap.connect(scb.imp);
    endfunction
  endclass

  // ------------------------------------------------------------
  // 3.7 Sequences
  // ------------------------------------------------------------
  class axi_smoke_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_smoke_seq)
    function new(string name="axi_smoke_seq"); super.new(name); endfunction

    task body();
      axi_seq_item tr;

      // wr 0x0 = A5A5_0001
      tr = axi_seq_item::type_id::create("wr0");
      start_item(tr); tr.cmd=WRITE; tr.addr='h0; tr.wdata='hA5A5_0001; tr.wstrb=4'hF; finish_item(tr);

      // rd 0x0
      tr = axi_seq_item::type_id::create("rd0");
      start_item(tr); tr.cmd=READ;  tr.addr='h0;                        finish_item(tr);

      // wr 0x4 = DEAD_BEEF
      tr = axi_seq_item::type_id::create("wr1");
      start_item(tr); tr.cmd=WRITE; tr.addr='h4; tr.wdata='hDEAD_BEEF; tr.wstrb=4'hF; finish_item(tr);

      // rd 0x4
      tr = axi_seq_item::type_id::create("rd1");
      start_item(tr); tr.cmd=READ;  tr.addr='h4;                        finish_item(tr);
    endtask
  endclass

  class axi_cov_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_cov_seq)
    function new(string name="axi_cov_seq"); super.new(name); endfunction

    task body();
      axi_seq_item tr;
      bit [31:0] addrs[4] = '{32'h0000_0000, 32'h0000_0004, 32'h0000_0008, 32'h0000_0010};
      bit [31:0] wvals[3] = '{32'h0000_0011, 32'h0000_00AA, 32'h0000_FF00};

      foreach (addrs[i]) begin
        foreach (wvals[k]) begin
          tr = axi_seq_item::type_id::create($sformatf("wr_%0d_%0d", i, k));
          start_item(tr);
            tr.cmd   = WRITE;
            tr.addr  = addrs[i];
            tr.wdata = wvals[k];
            tr.wstrb = (k==0)?4'h1 : (k==1)?4'h3 : 4'hF;
          finish_item(tr);
        end
        tr = axi_seq_item::type_id::create($sformatf("rd_%0d", i));
        start_item(tr);
          tr.cmd  = READ;
          tr.addr = addrs[i];
        finish_item(tr);
      end
    endtask
  endclass

  // ------------------------------------------------------------
  // 3.8 Tests
  // ------------------------------------------------------------
  class axi_base_test extends uvm_test;
    `uvm_component_utils(axi_base_test)
    axi_env m_env;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      m_env = axi_env::type_id::create("m_env", this);
    endfunction

    function void final_phase(uvm_phase phase);
      real cov;
      int  fd;
      cov = m_env.agent.vif.u_cg_axi.get_inst_coverage(); // 0~100
      `uvm_info("COV", $sformatf("Functional coverage (cg_axi) = %0.2f%%", cov), UVM_NONE)
      fd = $fopen("fcov.txt", "w");
      if (fd==0)begin
        `uvm_warning("COV","$fopen fcov.txt failed");
      end
      else begin
        $fdisplay(fd, "cg_axi = %0.2f%%", cov);
        $fclose(fd);
      end
    endfunction

  endclass

  class axi_smoke_test extends axi_base_test;
    `uvm_component_utils(axi_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
      axi_smoke_seq seq;
      `uvm_info("TEST", "axi_smoke_test BEGIN", UVM_LOW)
      phase.raise_objection(this);
        seq = axi_smoke_seq::type_id::create("seq");
        seq.start(m_env.agent.sqr);
      phase.drop_objection(this);
      `uvm_info("TEST", "axi_smoke_test END", UVM_LOW)
    endtask
  endclass

  class axi_cov_fill_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_cov_fill_seq)

    function new(string name="axi_cov_fill_seq");
      super.new(name);
    endfunction

    task body();
      axi_seq_item tr;

      // 命中 cross(1,0)：AW 先行 2 拍
      tr = axi_seq_item::type_id::create("wr_aw_first");
      start_item(tr);
        tr.is_write = 1;
        tr.addr     = 32'h0000_0100;     // 落在 high bins
        tr.wdata    = 32'h1234_5678;     // large 档（>=256）
        tr.wstrb    = 4'hC;              // 命中掩码 bins
        tr.aw_lead   = 2;               // 关键：AW 提前
        tr.w_lead    = 0;
      finish_item(tr);

      // 命中 cross(0,1)：W 先行 2 拍
      tr = axi_seq_item::type_id::create("wr_w_first");
      start_item(tr);
        tr.is_write  = 1;
        tr.addr      = 32'h0000_0008;
        tr.wdata     = 32'h0000_0090;   // medium 桶
        tr.wstrb     = 4'h3;
        tr.aw_lead   = 0;
        tr.w_lead    = 2;   
      finish_item(tr);

      // small 桶再补一条（同时）
      tr = axi_seq_item::type_id::create("wr_small");
      start_item(tr);
        tr.is_write  = 1;
        tr.addr      = 32'h0000_0004;
        tr.wdata     = 32'h0000_0020;   // small
        tr.wstrb     = 4'h1;
        tr.aw_lead   = 0;
        tr.w_lead    = 0;
      finish_item(tr);

      // 读回 + rready_hold 命中 cp_r_wait（如果你保留了 cg_axi_hs）
      tr = axi_seq_item::type_id::create("rd_back_high_wait");
      start_item(tr);
        tr.is_write      = 0;
        tr.addr          = 32'h0000_0100;
        tr.rready_hold   = 8;            // 让 rready 先低 8 拍，命中 cp_r_wait 的 m 桶
      finish_item(tr);

    endtask
  endclass

  class axi_cov_test extends axi_base_test;
    `uvm_component_utils(axi_cov_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      axi_cov_fill_seq covseq;
      phase.raise_objection(this);
        covseq = axi_cov_fill_seq::type_id::create("covseq", this); // 创建
        covseq.start(m_env.agent.sqr);                              // 启动
      phase.drop_objection(this);
    endtask
  endclass

endpackage
