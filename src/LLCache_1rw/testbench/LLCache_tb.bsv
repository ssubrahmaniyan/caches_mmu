/*
Author: Sanjeev Subrahmaniyan
E-mail: subrahmaniyansanjeev@gmail.com
*/

package LLCache_tb;

  // BSV Library Imports
  import Vector   ::  *;
  import GetPut   ::  *;
  `include "Logger.bsv"
  
  // Project Lib Imports 
  import LLCache  ::  *;
  import LLCache_types :: *;
  `include "LLCache.defines"

  typedef TMul#(`llcblocks, TMul#(`llcwords, 8)) LLCLineBits;
  typedef CA_LLCache_request_t#(`paddr, LLCLineBits, `ncores) TB_CAReq_t;
  typedef CA_LLCache_response_t#(`paddr, LLCLineBits, `ncores) TB_CAResp_t;

  (* synthesize *)
  module mkLLCTestbench(Empty);

    Reg#(Bit#(4)) rg_test_state <- mkReg(0);
    Reg#(UInt#(16)) rg_cycles <- mkReg(0);

    Reg#(Bool) rg_first_miss_seen <- mkReg(False);
    Reg#(UInt#(2)) rg_resp_count <- mkReg(0);

    Reg#(Bit#(`paddr)) rg_first_resp_addr <- mkReg(0);
    Reg#(Bit#(TLog#(`ncores))) rg_first_resp_hart <- mkReg(0);
    Reg#(Bit#(LLCLineBits)) rg_first_resp_data <- mkReg(0);

    Reg#(Bit#(`paddr)) rg_second_resp_addr <- mkReg(0);
    Reg#(Bit#(TLog#(`ncores))) rg_second_resp_hart <- mkReg(0);
    Reg#(Bit#(LLCLineBits)) rg_second_resp_data <- mkReg(0);

    Ifc_LLCache dut <- mkLLCache;

    function Bit#(`paddr) fn_test_addr();
      return 'h1000;
    endfunction

    function Bit#(TLog#(`ncores)) fn_test_hart();
      return 0;
    endfunction

    function Bit#(LLCLineBits) fn_fill_data();
      return 'hABCD_1234_ABCD_1234;
    endfunction

    function TB_CAReq_t fn_mk_read_req(Bit#(`paddr) addr, Bit#(TLog#(`ncores)) hart);
      return CA_LLCache_request_t{
        address: addr,
        access: Read,
        data: 0,
        hart_id: hart
      };
    endfunction

    function TB_CAResp_t fn_mk_fill_resp(
      Bit#(`paddr) addr,
      Bit#(LLCLineBits) data,
      Bit#(TLog#(`ncores)) hart
    );
      return CA_LLCache_response_t{
        address: addr,
        data: data,
        hart_id: hart
      };
    endfunction

    rule rl_tick;
      rg_cycles <= rg_cycles + 1;
    endrule

    // read the miss response from CA to LLC
    rule rl_mock_ca_receive_miss;
      let miss_req <- dut.llcache_ca_req.get();
      $display(
        "%0t: [CA MOCK] Received memory fetch request. Address: %h Access: %0d",
        $time, miss_req.address, miss_req.access
      );

      if (miss_req.access != Read) begin
        $display("%0t: [TB][FAIL] LLC miss request had non-read access", $time);
        $finish;
      end

      if (!rg_first_miss_seen) begin
        rg_first_miss_seen <= True;
      end
      else begin
        $display("%0t: [TB][FAIL] Unexpected second miss request", $time);
        $finish;
      end
    endrule

    // read the response coming out of cache
    rule rl_monitor_llc_response;
      let resp <- dut.llcache_ca_resp.get();
      $display("%0t: [LLC] Received Cache Response! Data: %h, Address: %h, Hart: %d", 
                $time, resp.data, resp.address, resp.hart_id);

      if (rg_resp_count == 0) begin
        rg_first_resp_addr <= resp.address;
        rg_first_resp_hart <= resp.hart_id;
        rg_first_resp_data <= resp.data;
      end
      else if (rg_resp_count == 1) begin
        rg_second_resp_addr <= resp.address;
        rg_second_resp_hart <= resp.hart_id;
        rg_second_resp_data <= resp.data;
      end
      else begin
        $display("%0t: [TB][FAIL] Unexpected extra cache response", $time);
        $finish;
      end

      rg_resp_count <= rg_resp_count + 1;
    endrule

    rule state_0_start(rg_test_state == 0);
      $display("%0t: [TB] Starting LLCache test", $time);
      dut.ca_llcache_req.put(fn_mk_read_req(fn_test_addr(), fn_test_hart()));
      $display("%0t: [TB] Sent first read request to %h (expected miss)", $time, fn_test_addr());
      rg_test_state <= 4'd1;
    endrule

    rule state_1_wait_first_miss(rg_test_state == 4'd1 && rg_first_miss_seen);
      $display("%0t: [TB] Observed miss request. Returning fill data to LLC", $time);
      rg_test_state <= 4'd2;
    endrule

    rule state_2_mock_fill(rg_test_state == 4'd2);
      dut.ca_llcache_resp.put(fn_mk_fill_resp(fn_test_addr(), fn_fill_data(), fn_test_hart()));
      $display("%0t: [TB] Sent fill response for Addr %h", $time, fn_test_addr());
      rg_test_state <= 4'd3;
    endrule

    rule state_3_wait_fill_response(rg_test_state == 4'd3 && rg_resp_count >= 1);
      if (rg_first_resp_addr != fn_test_addr()) begin
        $display("%0t: [TB][FAIL] Fill response address mismatch. Got %h Expected %h",
                 $time, rg_first_resp_addr, fn_test_addr());
        $finish;
      end
      if (rg_first_resp_hart != fn_test_hart()) begin
        $display("%0t: [TB][FAIL] Fill response hart mismatch. Got %0d Expected %0d",
                 $time, rg_first_resp_hart, fn_test_hart());
        $finish;
      end
      if (rg_first_resp_data != fn_fill_data()) begin
        $display("%0t: [TB][FAIL] Fill response data mismatch. Got %h Expected %h",
                 $time, rg_first_resp_data, fn_fill_data());
        $finish;
      end
      $display("%0t: [TB] Observed returned fill data before issuing next request", $time);
      rg_test_state <= 4'd4;
    endrule

    rule state_4_send_second_read(rg_test_state == 4'd4);
      dut.ca_llcache_req.put(fn_mk_read_req(fn_test_addr(), fn_test_hart()));
      $display("%0t: [TB] Sent second read request to %h (expected hit)", $time, fn_test_addr());
      rg_test_state <= 4'd5;
    endrule

    rule state_5_wait_second_response(rg_test_state == 4'd5 && rg_resp_count >= 2);
      if (rg_second_resp_addr != fn_test_addr()) begin
        $display("%0t: [TB][FAIL] Hit response address mismatch. Got %h Expected %h",
                 $time, rg_second_resp_addr, fn_test_addr());
        $finish;
      end
      if (rg_second_resp_hart != fn_test_hart()) begin
        $display("%0t: [TB][FAIL] Hit response hart mismatch. Got %0d Expected %0d",
                 $time, rg_second_resp_hart, fn_test_hart());
        $finish;
      end
      if (rg_second_resp_data != fn_fill_data()) begin
        $display("%0t: [TB][FAIL] Hit response data mismatch. Got %h Expected %h",
                 $time, rg_second_resp_data, fn_fill_data());
        $finish;
      end
      $display("%0t: [TB][PASS] LLCache miss->fill->response->hit flow verified", $time);
      $finish;
    endrule

    rule rl_timeout(rg_cycles > 400);
      $display("%0t: [TB][FAIL] Timeout waiting for LLC behavior", $time);
      $finish;
    endrule

  endmodule: mkLLCTestbench

endpackage: LLCache_tb
