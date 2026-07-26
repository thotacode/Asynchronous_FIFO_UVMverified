`timescale 1ns/1ps

package fifo_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  parameter DW = 8;
  parameter DEPTH = 16;

  `uvm_analysis_imp_decl(_wr)
  `uvm_analysis_imp_decl(_rd)

  // ---------------- Sequence items ----------------
  class wr_item extends uvm_sequence_item;
    rand bit [DW-1:0] data;
    rand int unsigned delay;
    constraint c_delay { soft delay inside {[0:3]}; }
    `uvm_object_utils_begin(wr_item)
      `uvm_field_int(data, UVM_ALL_ON)
      `uvm_field_int(delay, UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name="wr_item"); super.new(name); endfunction
  endclass

  class rd_item extends uvm_sequence_item;
    rand int unsigned delay;
    bit [DW-1:0] data;
    constraint c_delay { soft delay inside {[0:3]}; }
    `uvm_object_utils_begin(rd_item)
      `uvm_field_int(data, UVM_ALL_ON)
      `uvm_field_int(delay, UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name="rd_item"); super.new(name); endfunction
  endclass

  // ---------------- Baseline sequences ----------------
  class wr_seq extends uvm_sequence #(wr_item);
    `uvm_object_utils(wr_seq)
    int num = 50;
    function new(string name="wr_seq"); super.new(name); endfunction
    task body();
      wr_item it;
      repeat (num) begin
        it = wr_item::type_id::create("it");
        start_item(it);
        assert(it.randomize());
        finish_item(it);
      end
    endtask
  endclass

  class rd_seq extends uvm_sequence #(rd_item);
    `uvm_object_utils(rd_seq)
    int num = 50;
    function new(string name="rd_seq"); super.new(name); endfunction
    task body();
      rd_item it;
      repeat (num) begin
        it = rd_item::type_id::create("it");
        start_item(it);
        assert(it.randomize());
        finish_item(it);
      end
    endtask
  endclass

  // ---------------- Stress sequences: weighted toward boundary conditions ----------------
  class wr_burst_seq extends uvm_sequence #(wr_item);
    `uvm_object_utils(wr_burst_seq)
    int num = 200;
    function new(string name="wr_burst_seq"); super.new(name); endfunction
    task body();
      wr_item it;
      repeat (num) begin
        it = wr_item::type_id::create("it");
        start_item(it);
        assert(it.randomize() with {
          delay dist { 0 := 6, [1:2] := 3, [3:5] := 1 };
        });
        finish_item(it);
      end
    endtask
  endclass

  class rd_slow_seq extends uvm_sequence #(rd_item);
    `uvm_object_utils(rd_slow_seq)
    int num = 200;
    function new(string name="rd_slow_seq"); super.new(name); endfunction
    task body();
      rd_item it;
      repeat (num) begin
        it = rd_item::type_id::create("it");
        start_item(it);
        assert(it.randomize() with { delay inside {[4:8]}; });
        finish_item(it);
      end
    endtask
  endclass

  class wr_slow_seq extends uvm_sequence #(wr_item);
    `uvm_object_utils(wr_slow_seq)
    int num = 200;
    function new(string name="wr_slow_seq"); super.new(name); endfunction
    task body();
      wr_item it;
      repeat (num) begin
        it = wr_item::type_id::create("it");
        start_item(it);
        assert(it.randomize() with { delay inside {[4:8]}; });
        finish_item(it);
      end
    endtask
  endclass

  class rd_burst_seq extends uvm_sequence #(rd_item);
    `uvm_object_utils(rd_burst_seq)
    int num = 200;
    function new(string name="rd_burst_seq"); super.new(name); endfunction
    task body();
      rd_item it;
      repeat (num) begin
        it = rd_item::type_id::create("it");
        start_item(it);
        assert(it.randomize() with {
          delay dist { 0 := 6, [1:2] := 3, [3:5] := 1 };
        });
        finish_item(it);
      end
    endtask
  endclass

  // Fully deterministic zero-delay sequences - no randomization on delay at all,
  // used specifically to maximize the chance of catching simultaneous
  // write+read exactly at the full/empty boundary once clocks are aligned/skewed.
  class wr_zero_seq extends uvm_sequence #(wr_item);
    `uvm_object_utils(wr_zero_seq)
    int num = 2000;
    function new(string name="wr_zero_seq"); super.new(name); endfunction
    task body();
      wr_item it;
      repeat (num) begin
        it = wr_item::type_id::create("it");
        start_item(it);
        assert(it.randomize() with { delay == 0; });
        finish_item(it);
      end
    endtask
  endclass

  class rd_zero_seq extends uvm_sequence #(rd_item);
    `uvm_object_utils(rd_zero_seq)
    int num = 2000;
    function new(string name="rd_zero_seq"); super.new(name); endfunction
    task body();
      rd_item it;
      repeat (num) begin
        it = rd_item::type_id::create("it");
        start_item(it);
        assert(it.randomize() with { delay == 0; });
        finish_item(it);
      end
    endtask
  endclass

  // ---------------- Write side driver/monitor ----------------
  class wr_driver extends uvm_driver #(wr_item);
    `uvm_component_utils(wr_driver)
    virtual wr_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual wr_if)::get(this, "", "wr_vif", vif))
        `uvm_fatal("NOVIF","wr_vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      vif.wr_en <= 0;
      wait (vif.wr_rst_n === 1'b1);
      forever begin
        wr_item it;
        seq_item_port.get_next_item(it);
        repeat (it.delay) @(posedge vif.wr_clk);
        if (!vif.full) begin
          vif.wr_en   <= 1;
          vif.wr_data <= it.data;
        end else begin
          vif.wr_en <= 0;
        end
        @(posedge vif.wr_clk);
        vif.wr_en <= 0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class wr_monitor extends uvm_monitor;
    `uvm_component_utils(wr_monitor)
    virtual wr_if vif;
    uvm_analysis_port #(wr_item) ap;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual wr_if)::get(this, "", "wr_vif", vif))
        `uvm_fatal("NOVIF","wr_vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      forever begin
        @(posedge vif.wr_clk);
        if (vif.wr_en && !vif.full) begin
          wr_item it = wr_item::type_id::create("it");
          it.data = vif.wr_data;
          ap.write(it);
        end
      end
    endtask
  endclass

  // ---------------- Read side driver/monitor ----------------
  class rd_driver extends uvm_driver #(rd_item);
    `uvm_component_utils(rd_driver)
    virtual rd_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual rd_if)::get(this, "", "rd_vif", vif))
        `uvm_fatal("NOVIF","rd_vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      vif.rd_en <= 0;
      wait (vif.rd_rst_n === 1'b1);
      forever begin
        rd_item it;
        seq_item_port.get_next_item(it);
        repeat (it.delay) @(posedge vif.rd_clk);
        vif.rd_en <= !vif.empty;
        @(posedge vif.rd_clk);
        vif.rd_en <= 0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class rd_monitor extends uvm_monitor;
    `uvm_component_utils(rd_monitor)
    virtual rd_if vif;
    uvm_analysis_port #(rd_item) ap;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual rd_if)::get(this, "", "rd_vif", vif))
        `uvm_fatal("NOVIF","rd_vif not set")
    endfunction
    task run_phase(uvm_phase phase);
      bit pending;
      pending = 0;
      forever begin
        @(posedge vif.rd_clk);
        if (pending) begin
          rd_item it = rd_item::type_id::create("it");
          it.data = vif.rd_data;
          ap.write(it);
        end
        pending = (vif.rd_en && !vif.empty);
      end
    endtask
  endclass

  // ---------------- Scoreboard + occupancy/simultaneous-access coverage ----------------
  class fifo_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(fifo_scoreboard)
    uvm_analysis_imp_wr #(wr_item, fifo_scoreboard) wr_imp;
    uvm_analysis_imp_rd #(rd_item, fifo_scoreboard) rd_imp;
    bit [DW-1:0] exp_q[$];
    int match_cnt = 0, err_cnt = 0;
    int occ;

    // Direct interface access so coverage can be sampled independently of
    // the transaction-level scoreboard updates, at real clock-edge resolution.
    virtual wr_if wr_vif;
    virtual rd_if rd_vif;
    bit simul_access;

    covergroup occ_cg;
      option.per_instance = 1;
      option.at_least = 10;   // a bin must be hit 10+ times to count as covered,
                              // not just once - a real closure bar instead of the default.

      cp_occ: coverpoint occ {
        bins empty_b     = {0};
        bins near_empty  = {[1:2]};
        bins mid         = {[3:DEPTH-4]};
        bins near_full   = {[DEPTH-3:DEPTH-1]};
        bins full_b      = {DEPTH};
      }

      cp_simul: coverpoint simul_access {
        bins no_simul = {0};
        bins simul    = {1};
      }

      // Does the design ever see a simultaneous write+read attempt at each
      // occupancy level? The full_b x simul and empty_b x simul bins are the
      // genuinely rare, high-value corners for a CDC FIFO.
      cross_occ_simul: cross cp_occ, cp_simul;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      wr_imp = new("wr_imp", this);
      rd_imp = new("rd_imp", this);
      occ_cg = new();
    endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual wr_if)::get(this, "", "wr_vif", wr_vif))
        `uvm_fatal("NOVIF","wr_vif not set in scoreboard")
      if (!uvm_config_db#(virtual rd_if)::get(this, "", "rd_vif", rd_vif))
        `uvm_fatal("NOVIF","rd_vif not set in scoreboard")
    endfunction

    // Samples on every clock edge in either domain - this is what gives the
    // covergroup enough samples per bin to make option.at_least meaningful,
    // rather than relying on a handful of transaction-level events.
    task run_phase(uvm_phase phase);
      forever begin
        @(wr_vif.wr_clk or rd_vif.rd_clk);
        simul_access = (wr_vif.wr_en && !wr_vif.full) && (rd_vif.rd_en && !rd_vif.empty);
        occ_cg.sample();
      end
    endtask

    function void write_wr(wr_item t);
      exp_q.push_back(t.data);
      occ = exp_q.size();
    endfunction

    function void write_rd(rd_item t);
      if (exp_q.size() == 0) begin
        err_cnt++;
        `uvm_error("SB", "Read data with empty expected queue!")
      end else begin
        bit [DW-1:0] e = exp_q.pop_front();
        if (e !== t.data) begin
          err_cnt++;
          `uvm_error("SB", $sformatf("MISMATCH exp=%0h got=%0h", e, t.data))
        end else begin
          match_cnt++;
        end
      end
      occ = exp_q.size();
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("SB", $sformatf("Matches=%0d Errors=%0d Remaining=%0d Coverage=%0.2f%%",
                 match_cnt, err_cnt, exp_q.size(), occ_cg.get_coverage()), UVM_LOW)
    endfunction
  endclass

  // ---------------- Agents ----------------
  class wr_agent extends uvm_agent;
    `uvm_component_utils(wr_agent)
    wr_driver    drv;
    uvm_sequencer #(wr_item) sqr;
    wr_monitor   mon;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      drv = wr_driver::type_id::create("drv", this);
      sqr = uvm_sequencer#(wr_item)::type_id::create("sqr", this);
      mon = wr_monitor::type_id::create("mon", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  class rd_agent extends uvm_agent;
    `uvm_component_utils(rd_agent)
    rd_driver    drv;
    uvm_sequencer #(rd_item) sqr;
    rd_monitor   mon;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      drv = rd_driver::type_id::create("drv", this);
      sqr = uvm_sequencer#(rd_item)::type_id::create("sqr", this);
      mon = rd_monitor::type_id::create("mon", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // ---------------- Env ----------------
  class fifo_env extends uvm_env;
    `uvm_component_utils(fifo_env)
    wr_agent wr_ag;
    rd_agent rd_ag;
    fifo_scoreboard sb;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      wr_ag = wr_agent::type_id::create("wr_ag", this);
      rd_ag = rd_agent::type_id::create("rd_ag", this);
      sb    = fifo_scoreboard::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      wr_ag.mon.ap.connect(sb.wr_imp);
      rd_ag.mon.ap.connect(sb.rd_imp);
    endfunction
  endclass

  // ---------------- Tests ----------------
  class async_fifo_basic_test extends uvm_test;
    `uvm_component_utils(async_fifo_basic_test)
    fifo_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = fifo_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
      wr_seq wseq = wr_seq::type_id::create("wseq");
      rd_seq rseq = rd_seq::type_id::create("rseq");
      phase.raise_objection(this);
      fork
        wseq.start(env.wr_ag.sqr);
        rseq.start(env.rd_ag.sqr);
      join
      #200;
      phase.drop_objection(this);
    endtask
  endclass

  // Drive writer fast, reader slow -> repeatedly hits FULL
  class fifo_full_pressure_test extends uvm_test;
    `uvm_component_utils(fifo_full_pressure_test)
    fifo_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = fifo_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
      wr_burst_seq wseq = wr_burst_seq::type_id::create("wseq");
      rd_slow_seq  rseq = rd_slow_seq::type_id::create("rseq");
      wseq.num = 300; rseq.num = 300;
      phase.raise_objection(this);
      fork
        wseq.start(env.wr_ag.sqr);
        rseq.start(env.rd_ag.sqr);
      join
      #500;
      phase.drop_objection(this);
    endtask
  endclass

  // Drive reader fast, writer slow -> repeatedly hits EMPTY
  class fifo_empty_pressure_test extends uvm_test;
    `uvm_component_utils(fifo_empty_pressure_test)
    fifo_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = fifo_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
      wr_slow_seq  wseq = wr_slow_seq::type_id::create("wseq");
      rd_burst_seq rseq = rd_burst_seq::type_id::create("rseq");
      wseq.num = 300; rseq.num = 300;
      phase.raise_objection(this);
      fork
        wseq.start(env.wr_ag.sqr);
        rseq.start(env.rd_ag.sqr);
      join
      #500;
      phase.drop_objection(this);
    endtask
  endclass

  // Long constrained-random regression, both sides bursty
  class fifo_random_stress_test extends uvm_test;
    `uvm_component_utils(fifo_random_stress_test)
    fifo_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = fifo_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
      wr_burst_seq wseq = wr_burst_seq::type_id::create("wseq");
      rd_burst_seq rseq = rd_burst_seq::type_id::create("rseq");
      wseq.num = 1000; rseq.num = 1000;
      phase.raise_objection(this);
      fork
        wseq.start(env.wr_ag.sqr);
        rseq.start(env.rd_ag.sqr);
      join
      #1000;
      phase.drop_objection(this);
    endtask
  endclass

  // Combined regression: runs all four stimulus profiles back-to-back
  // in one env instance, so occupancy coverage accumulates across all of them.
  class fifo_regression_test extends uvm_test;
    `uvm_component_utils(fifo_regression_test)
    fifo_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = fifo_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
      wr_seq wseq; rd_seq rseq;
      wr_burst_seq wbseq; rd_slow_seq rsseq;
      wr_slow_seq wsseq; rd_burst_seq rbseq;
      wr_burst_seq wbseq2; rd_burst_seq rbseq2;
      phase.raise_objection(this);

      wseq = wr_seq::type_id::create("wseq");
      rseq = rd_seq::type_id::create("rseq");
      fork wseq.start(env.wr_ag.sqr); rseq.start(env.rd_ag.sqr); join
      #200;

      wbseq = wr_burst_seq::type_id::create("wbseq");
      rsseq = rd_slow_seq::type_id::create("rsseq");
      wbseq.num = 300; rsseq.num = 300;
      fork wbseq.start(env.wr_ag.sqr); rsseq.start(env.rd_ag.sqr); join
      #500;

      wsseq = wr_slow_seq::type_id::create("wsseq");
      rbseq = rd_burst_seq::type_id::create("rbseq");
      wsseq.num = 300; rbseq.num = 300;
      fork wsseq.start(env.wr_ag.sqr); rbseq.start(env.rd_ag.sqr); join
      #500;

      wbseq2 = wr_burst_seq::type_id::create("wbseq2");
      rbseq2 = rd_burst_seq::type_id::create("rbseq2");
      wbseq2.num = 1000; rbseq2.num = 1000;
      fork wbseq2.start(env.wr_ag.sqr); rbseq2.start(env.rd_ag.sqr); join
      #1000;

      phase.drop_objection(this);
    endtask
  endclass

  // Directed boundary test: maximally aggressive zero-delay traffic on both
  // sides, intended to be run with a steep clock skew (e.g. WR_PERIOD=3
  // RD_PERIOD=17) - gives the best chance of catching a simultaneous
  // write+read exactly when occupancy is at full or empty. This is the test
  // that found the a_full_empty_mutex CDC race documented in README.md sec.4.
  class fifo_simul_boundary_test extends uvm_test;
    `uvm_component_utils(fifo_simul_boundary_test)
    fifo_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      env = fifo_env::type_id::create("env", this);
    endfunction
    task run_phase(uvm_phase phase);
      wr_zero_seq wseq = wr_zero_seq::type_id::create("wseq");
      rd_zero_seq rseq = rd_zero_seq::type_id::create("rseq");
      phase.raise_objection(this);
      fork
        wseq.start(env.wr_ag.sqr);
        rseq.start(env.rd_ag.sqr);
      join
      #500;
      phase.drop_objection(this);
    endtask
  endclass

endpackage : fifo_pkg


// ---------------- Interfaces (outside package) ----------------
interface wr_if(input bit wr_clk);
  logic wr_rst_n, wr_en, full;
  logic [fifo_pkg::DW-1:0] wr_data;
endinterface

interface rd_if(input bit rd_clk);
  logic rd_rst_n, rd_en, empty;
  logic [fifo_pkg::DW-1:0] rd_data;
endinterface


// ---------------- Top ----------------
module tb_top;
  import uvm_pkg::*;
  import fifo_pkg::*;

  int wr_period, rd_period;
  initial begin
    if (!$value$plusargs("WR_PERIOD=%d", wr_period)) wr_period = 5;
    if (!$value$plusargs("RD_PERIOD=%d", rd_period)) rd_period = 7;
  end

  bit wr_clk = 0, rd_clk = 0;
  always #(wr_period) wr_clk = ~wr_clk;
  always #(rd_period) rd_clk = ~rd_clk;

  wr_if wif(wr_clk);
  rd_if rif(rd_clk);

  async_fifo #(.DW(DW), .DEPTH(DEPTH)) dut (
    .wr_clk(wr_clk), .wr_rst_n(wif.wr_rst_n), .wr_en(wif.wr_en),
    .wr_data(wif.wr_data), .full(wif.full),
    .rd_clk(rd_clk), .rd_rst_n(rif.rd_rst_n), .rd_en(rif.rd_en),
    .rd_data(rif.rd_data), .empty(rif.empty)
  );

  initial begin
    uvm_config_db#(virtual wr_if)::set(null, "*", "wr_vif", wif);
    uvm_config_db#(virtual rd_if)::set(null, "*", "rd_vif", rif);
  end

  initial begin
    wif.wr_en = 0; rif.rd_en = 0;
    wif.wr_rst_n = 0; rif.rd_rst_n = 0;
    #20;
    wif.wr_rst_n = 1;
    #23;
    rif.rd_rst_n = 1;
  end

  initial begin
    run_test();
  end

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_top);
  end
endmodule
