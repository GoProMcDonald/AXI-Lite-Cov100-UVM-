目标与成果
项目目标

用 UVM 搭起一个最小可运行的 AXI-Lite 验证环境（agent/env/testbench）。
在 DUT（简化 AXI-Lite 从设备：寄存器阵列）上完成断言与功能覆盖。
通过定制序列，把关键覆盖点全部命中，cg_axi = 100%。
最终结果
仿真日志：Functional coverage (cg_axi) = 100.00%
关键覆盖项全部命中：
awaddr 低/高段
wdata small / medium / large 桶
WSTRB 1 / 3 / C / F
cross awvalid, wvalid 的 00 / 01 / 10 / 11（通过“AW 先行 / W 先行 / 同步发送”生成）
断言覆盖（cover property）均有命中（aw/w/ar→ready、b/r 出现等）
可重复生成 URG 报告（HTML/文本）

.
├─ design.sv                              # 顶层把 DUT + 接口连起来（你的 testbench 顶层）
├─ AXI_Lite_UVM_Closure_axi_if.sv        # interface + SVA + covergroups (cg_axi)
├─ AXI_Lite_UVM_Closure_axi_lite_slave_regs.sv  # 简化 AXI-Lite 从设备 (ready 恒 1)
├─ AXI_Lite_UVM_Closure_my_pkg.sv        # 所有 UVM 类都在这里（见下）
└─ testbench.sv                          # run_test(...)、接口实例化、vif 注入路径
覆盖与断言设计
功能覆盖（在 axi_if 的 cg_axi）
awvalid, wvalid, arvalid 单 bit 覆盖

awaddr：[0:255]（low）/ [256:4095]（high）

wdata：small={0:127} / medium={128:255} / large={256:32'hFFFF_FFFF}

WSTRB：1 / 3 / C / F

cross awvalid, wvalid：00 / 01 / 10 / 11

其中 01 与 10 由 axi_cov_fill_seq 控制 aw_lead / w_lead 打出：

aw_lead=2, w_lead=0 → AW 先行 → (1,0)

aw_lead=0, w_lead=2 → W 先行 → (0,1)

断言与断言覆盖（SVA）
p_valid_stays_high：VALID 拉起到握手前必须保持

p_stable_when_wait：等待握手时地址/数据稳定

cover property：aw/w/ar 之后 eventually ready；aw&w 之后出现 bvalid；ar 之后出现 rvalid

关键实现点
同步关系覆盖的“错相发送”

在 axi_seq_item 加 aw_lead/w_lead。

axi_driver::drive_write() 分三种路径（AW 先、W 先、同步）。

驱动分支正确性

axi_driver 用 is_write 决定写/读分支（避免 cmd 未赋值导致全当读）。

默认电平/复位处理

vif.drive_defaults() + 复位后把 bready/rready 拉成已知值，避免等待死锁。

vif 注入路径

顶层：

systemverilog
Copy
Edit
uvm_config_db#(virtual axi_if)::set(null, "uvm_test_top.m_env.agent", "vif", vif);
确保这只 vif 就是连到 DUT 的那只（ready 恒 1）。

scoreboard 覆盖（可选）

仅在 READ OK 采样 cg_scb_ok（地址段 × 掩码），展示“正确性联动覆盖”的写法。

如何编译与运行
以 VCS 为例（适配你当前环境：UVM-1.2 / VCS-MX 2023.03-SP2）：

bash
Copy
Edit
# 1) 编译
vcs -full64 -sverilog -timescale=1ns/1ns \
  +incdir+. \
  AXI_Lite_UVM_Closure_axi_if.sv \
  AXI_Lite_UVM_Closure_axi_lite_slave_regs.sv \
  AXI_Lite_UVM_Closure_my_pkg.sv \
  design.sv testbench.sv \
  -ntb_opts uvm-1.2 -l comp.log

# 2) 运行（收尾拉满覆盖）
./simv +UVM_TESTNAME=axi_cov_test +UVM_VERBOSITY=UVM_MEDIUM -l sim.log

# 3) 生成覆盖报告（可选）
urg -dir simv.vdb -format both -report cov_html
切回冒烟：

bash
Copy
Edit
./simv +UVM_TESTNAME=axi_smoke_test
<img width="1844" height="794" alt="image" src="https://github.com/user-attachments/assets/7e039953-0617-46d1-8dba-9b9628480fe4" />
<img width="1184" height="745" alt="image" src="https://github.com/user-attachments/assets/719ff9ac-f54b-4edc-bb7e-976779c0675f" />

