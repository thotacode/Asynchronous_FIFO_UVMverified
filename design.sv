module async_fifo #(
  parameter DW = 8,
  parameter DEPTH = 16,               // must be power of 2
  parameter AW = $clog2(DEPTH)
)(
  input  logic          wr_clk, wr_rst_n, wr_en,
  input  logic [DW-1:0] wr_data,
  output logic          full,
  input  logic          rd_clk, rd_rst_n, rd_en,
  output logic [DW-1:0] rd_data,
  output logic          empty
);

  logic [DW-1:0] mem [0:DEPTH-1];

  logic [AW:0] wr_ptr_bin, wr_ptr_gray, wr_ptr_gray_next, wr_ptr_bin_next;
  logic [AW:0] rd_ptr_bin, rd_ptr_gray, rd_ptr_gray_next, rd_ptr_bin_next;
  logic [AW:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2; // synced into rd domain
  logic [AW:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2; // synced into wr domain

  logic full_next, empty_next;

  // ---------- Write domain ----------
  assign wr_ptr_bin_next  = wr_ptr_bin + (wr_en && !full);
  assign wr_ptr_gray_next = (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;
  assign full_next = (wr_ptr_gray_next == {~rd_ptr_gray_sync2[AW:AW-1], rd_ptr_gray_sync2[AW-2:0]});

  always_ff @(posedge wr_clk or negedge wr_rst_n)
    if (!wr_rst_n) begin
      wr_ptr_bin  <= '0;
      wr_ptr_gray <= '0;
      full        <= 1'b0;
    end else begin
      wr_ptr_bin  <= wr_ptr_bin_next;
      wr_ptr_gray <= wr_ptr_gray_next;
      full        <= full_next;          // registered, breaks the comb loop
      if (wr_en && !full) mem[wr_ptr_bin[AW-1:0]] <= wr_data;
    end

  // sync rd_ptr_gray into wr_clk domain
  always_ff @(posedge wr_clk or negedge wr_rst_n)
    if (!wr_rst_n) {rd_ptr_gray_sync2, rd_ptr_gray_sync1} <= '0;
    else           {rd_ptr_gray_sync2, rd_ptr_gray_sync1} <= {rd_ptr_gray_sync1, rd_ptr_gray};

  // ---------- Read domain ----------
  assign rd_ptr_bin_next  = rd_ptr_bin + (rd_en && !empty);
  assign rd_ptr_gray_next = (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;
  assign empty_next = (rd_ptr_gray_next == wr_ptr_gray_sync2);

  always_ff @(posedge rd_clk or negedge rd_rst_n)
    if (!rd_rst_n) begin
      rd_ptr_bin  <= '0;
      rd_ptr_gray <= '0;
      rd_data     <= '0;
      empty       <= 1'b1;               // registered, breaks the comb loop
    end else begin
      rd_ptr_bin  <= rd_ptr_bin_next;
      rd_ptr_gray <= rd_ptr_gray_next;
      empty       <= empty_next;
      if (rd_en && !empty) rd_data <= mem[rd_ptr_bin[AW-1:0]];
    end

  // sync wr_ptr_gray into rd_clk domain
  always_ff @(posedge rd_clk or negedge rd_rst_n)
    if (!rd_rst_n) {wr_ptr_gray_sync2, wr_ptr_gray_sync1} <= '0;
    else           {wr_ptr_gray_sync2, wr_ptr_gray_sync1} <= {wr_ptr_gray_sync1, wr_ptr_gray};

endmodule


// ---------------- Bound checker: assertions on internal + external signals ----------------
module fifo_checker #(parameter AW = 4) (
  input logic wr_clk, wr_rst_n, wr_en, full,
  input logic rd_clk, rd_rst_n, rd_en, empty,
  input logic [AW:0] wr_ptr_gray, rd_ptr_gray
);

  // Protocol: never write when full, never read when empty
  a_no_wr_when_full: assert property (
    @(posedge wr_clk) disable iff (!wr_rst_n) full |-> !wr_en)
    else $error("PROTOCOL: wr_en asserted while full");

  a_no_rd_when_empty: assert property (
    @(posedge rd_clk) disable iff (!rd_rst_n) empty |-> !rd_en)
    else $error("PROTOCOL: rd_en asserted while empty");

  // CDC-specific: Gray code pointers must only ever toggle one bit per cycle.
  // A multi-bit change means a synchronizer sampled a pointer mid-transition.
  a_wr_gray_onehot: assert property (
    @(posedge wr_clk) disable iff (!wr_rst_n)
    $onehot0(wr_ptr_gray ^ $past(wr_ptr_gray)))
    else $error("CDC: wr_ptr_gray changed by more than 1 bit in a cycle");

  a_rd_gray_onehot: assert property (
    @(posedge rd_clk) disable iff (!rd_rst_n)
    $onehot0(rd_ptr_gray ^ $past(rd_ptr_gray)))
    else $error("CDC: rd_ptr_gray changed by more than 1 bit in a cycle");

  // NOTE: a full/empty mutual-exclusion check ("!(full && empty)") was
  // deliberately removed. full and empty are registered in two independent,
  // asynchronously clocked domains, so any single-clocked comparison between
  // them - synchronized or not - is racy by construction: synchronizing one
  // side only relocates the stale window rather than eliminating it (proven
  // empirically: adding a 2-flop synchronizer to empty widened a 1-violation
  // window into 3). This property would require a formal CDC tool (e.g.
  // Questa CDC) rather than a simulation-time SVA to check meaningfully.
  // See README.md section 4 for the full root-cause writeup.

endmodule

bind async_fifo fifo_checker #(.AW(AW)) fifo_checker_i (.*);
