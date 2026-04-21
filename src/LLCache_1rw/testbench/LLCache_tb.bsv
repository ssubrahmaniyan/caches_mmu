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
  typedef LLCache_CA_response_t#(LLCLineBits, `paddr, `ncores) TB_LLCResp_t;

  (* synthesize *)
  module mkLLCTestbench(Empty);

    Integer c_log_depth = 64;
    Reg#(UInt#(8)) rg_test_state <- mkReg(0);
    Reg#(UInt#(16)) rg_cycles <- mkReg(0);
    Reg#(UInt#(8)) rg_miss_count <- mkReg(0);
    Reg#(UInt#(8)) rg_resp_count <- mkReg(0);

    Reg#(UInt#(8)) rg_miss_ref <- mkReg(0);
    Reg#(UInt#(8)) rg_resp_ref <- mkReg(0);

    Reg#(Bit#(`paddr)) rg_cur_addr <- mkReg(0);
    Reg#(Bit#(LLCLineBits)) rg_cur_data <- mkReg(0);
    Reg#(Bit#(TLog#(`llcways))) rg_cur_way <- mkReg(0);

    Reg#(UInt#(4)) rg_fill_idx <- mkReg(0);
    Reg#(UInt#(4)) rg_train_idx <- mkReg(0);
    Reg#(Bit#(TSub#(`llcways, 1))) rg_model_tree <- mkReg(0);
    Reg#(Bit#(TLog#(`llcways))) rg_pred_victim <- mkReg(0);
    Reg#(Bit#(TLog#(`llcways))) rg_keep_way <- mkReg(0);
    Reg#(UInt#(4)) rg_probe_idx <- mkReg(0);
    Reg#(Bool) rg_has_retained <- mkReg(False);
    Reg#(Bit#(`paddr)) rg_retained_addr <- mkReg(0);
    Reg#(Bit#(LLCLineBits)) rg_retained_data <- mkReg(0);

    Vector#(64, Reg#(Bit#(`paddr))) v_miss_addr_log <- replicateM(mkReg(0));
    Vector#(64, Reg#(TB_LLCResp_t)) v_resp_log <- replicateM(mkReg(unpack(0)));

    Ifc_LLCache dut <- mkLLCache;

    function Bit#(TLog#(`ncores)) fn_test_hart();
      return 0;
    endfunction

    function Bit#(`paddr) fn_same_set_addr(Bit#(8) tag);
      Bit#(`paddr) set_base = 'h0C0;
      return ((zeroExtend(tag)) << 12) | set_base;
    endfunction

    function Bit#(LLCLineBits) fn_data_for_tag(Bit#(8) tag);
      return zeroExtend({tag, 24'h00ABCD});
    endfunction

    function Bit#(`paddr) fn_nb_addr_a();
      return fn_same_set_addr('h01);
    endfunction

    function Bit#(`paddr) fn_nb_addr_b();
      return fn_same_set_addr('h02);
    endfunction

    function Bit#(LLCLineBits) fn_nb_data_a();
      return fn_data_for_tag('h01);
    endfunction

    function Bit#(LLCLineBits) fn_nb_data_b();
      return fn_data_for_tag('h02);
    endfunction

    function Bit#(`paddr) fn_plru_fill_addr(UInt#(4) idx);
      Bit#(8) tag = 8'h10 + zeroExtend(pack(idx));
      return fn_same_set_addr(tag);
    endfunction

    function Bit#(LLCLineBits) fn_plru_fill_data(UInt#(4) idx);
      Bit#(8) tag = 8'h10 + zeroExtend(pack(idx));
      return fn_data_for_tag(tag);
    endfunction

    function Bit#(`paddr) fn_addr_for_way(Bit#(TLog#(`llcways)) way);
      Bit#(8) tag = 8'h10 + (fromInteger(valueOf(`llcways) - 1) - zeroExtend(way));
      return fn_same_set_addr(tag);
    endfunction

    function Bit#(LLCLineBits) fn_data_for_way(Bit#(TLog#(`llcways)) way);
      Bit#(8) tag = 8'h10 + (fromInteger(valueOf(`llcways) - 1) - zeroExtend(way));
      return fn_data_for_tag(tag);
    endfunction

    function Bit#(`paddr) fn_plru_new_addr();
      return fn_same_set_addr('h20);
    endfunction

    function Bit#(LLCLineBits) fn_plru_new_data();
      return fn_data_for_tag('h20);
    endfunction

    function Bit#(`paddr) fn_plru_expected_victim_addr();
      return fn_same_set_addr('h15);
    endfunction

    function Bit#(LLCLineBits) fn_plru_expected_victim_data();
      return fn_data_for_tag('h15);
    endfunction

    function Bit#(`paddr) fn_plru_expected_keep_addr();
      return fn_same_set_addr('h14);
    endfunction

    function Bit#(LLCLineBits) fn_plru_expected_keep_data();
      return fn_data_for_tag('h14);
    endfunction

    function Bit#(`paddr) fn_addr_for_way_current(Bit#(TLog#(`llcways)) way);
      case (way)
        0: return fn_same_set_addr('h15);
        1: return fn_same_set_addr('h14);
        2: return fn_same_set_addr('h13);
        3: return fn_same_set_addr('h12);
        4: return fn_same_set_addr('h11);
        5: return fn_same_set_addr('h10);
        6: return fn_same_set_addr('h02);
        default: return fn_same_set_addr('h01);
      endcase
    endfunction

    function Bit#(LLCLineBits) fn_data_for_way_current(Bit#(TLog#(`llcways)) way);
      case (way)
        0: return fn_data_for_tag('h15);
        1: return fn_data_for_tag('h14);
        2: return fn_data_for_tag('h13);
        3: return fn_data_for_tag('h12);
        4: return fn_data_for_tag('h11);
        5: return fn_data_for_tag('h10);
        6: return fn_data_for_tag('h02);
        default: return fn_data_for_tag('h01);
      endcase
    endfunction

    function Bit#(`paddr) fn_probe_addr(UInt#(4) idx);
      case (idx)
        0: return fn_same_set_addr('h15);
        1: return fn_same_set_addr('h14);
        2: return fn_same_set_addr('h13);
        3: return fn_same_set_addr('h12);
        4: return fn_same_set_addr('h11);
        5: return fn_same_set_addr('h10);
        6: return fn_same_set_addr('h02);
        default: return fn_same_set_addr('h01);
      endcase
    endfunction

    function Bit#(LLCLineBits) fn_probe_data(UInt#(4) idx);
      case (idx)
        0: return fn_data_for_tag('h15);
        1: return fn_data_for_tag('h14);
        2: return fn_data_for_tag('h13);
        3: return fn_data_for_tag('h12);
        4: return fn_data_for_tag('h11);
        5: return fn_data_for_tag('h10);
        6: return fn_data_for_tag('h02);
        default: return fn_data_for_tag('h01);
      endcase
    endfunction

    function Bit#(TLog#(`llcways)) fn_train_way(UInt#(4) idx);
      case (idx)
        0: return 0;
        1: return 1;
        2: return 2;
        3: return 3;
        4: return 4;
        5: return 5;
        default: return 6;
      endcase
    endfunction

    function Bit#(TSub#(`llcways, 1)) fn_plru_update(
      Bit#(TSub#(`llcways, 1)) tree,
      Bit#(TLog#(`llcways)) accessed_way
    );
      Bit#(TSub#(`llcways, 1)) t = tree;
      Bit#(TLog#(`llcways)) node = 0;
      Integer levels = valueOf(TLog#(`llcways));
      for (Integer i = 0; i < levels; i = i + 1) begin
        Bit#(1) dir = accessed_way[fromInteger(levels - 1 - i)];
        t[node] = ~dir;
        node = (node << 1) + 1 + zeroExtend(dir);
      end
      return t;
    endfunction

    function Bit#(TLog#(`llcways)) fn_plru_victim(Bit#(TSub#(`llcways, 1)) tree);
      Bit#(TLog#(`llcways)) node = 0;
      Bit#(TLog#(`llcways)) victim = 0;
      Integer levels = valueOf(TLog#(`llcways));
      for (Integer i = 0; i < levels; i = i + 1) begin
        Bit#(1) dir = tree[node];
        victim[fromInteger(levels - 1 - i)] = dir;
        node = (node << 1) + 1 + zeroExtend(dir);
      end
      return victim;
    endfunction

    function Bool fn_resp_match(
      TB_LLCResp_t resp,
      Bit#(`paddr) addr,
      Bit#(LLCLineBits) data,
      Bit#(TLog#(`ncores)) hart
    );
      return ((resp.address == addr) && (resp.data == data) && (resp.hart_id == hart));
    endfunction

    function Fmt fn_core_req_fmt(TB_CAReq_t req);
      return $format("[CORE->LLC REQ] Addr: %h Access: %0d Data: %h Hart: %0d",
                     req.address, req.access, req.data, req.hart_id);
    endfunction

    function Fmt fn_core_resp_fmt(TB_LLCResp_t resp);
      return $format("[LLC->CORE RESP] Addr: %h Data: %h Hart: %0d",
                     resp.address, resp.data, resp.hart_id);
    endfunction

    function Fmt fn_info(Fmt msg);
      return $format("\033[90m") + msg + $format("\033[0m");
    endfunction

    function Fmt fn_pass(Fmt msg);
      return $format("\033[32m") + msg + $format("\033[0m");
    endfunction

    function Fmt fn_fail(Fmt msg);
      return $format("\033[31m") + msg + $format("\033[0m");
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

    rule rl_capture_miss;
      let miss_req <- dut.llcache_ca_req.get();
      `logLevel(llctb, 1, fn_info($format("[CA MOCK] Received memory fetch request. Address: %h Access: %0d",
                              miss_req.address, miss_req.access)))

      if (miss_req.access != Read) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] LLC miss request had non-read access")))
        $finish;
      end

      if (rg_miss_count >= fromInteger(c_log_depth)) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] Miss log overflow")))
        $finish;
      end

      Bit#(6) lv_idx = truncate(pack(rg_miss_count));
      v_miss_addr_log[lv_idx] <= miss_req.address;
      rg_miss_count <= rg_miss_count + 1;
    endrule

    rule rl_capture_response;
      let resp <- dut.llcache_ca_resp.get();
      `logLevel(llctb, 1, fn_info(fn_core_resp_fmt(resp)))

      if (rg_resp_count >= fromInteger(c_log_depth)) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] Response log overflow")))
        $finish;
      end

      Bit#(6) lv_idx = truncate(pack(rg_resp_count));
      v_resp_log[lv_idx] <= resp;
      rg_resp_count <= rg_resp_count + 1;
    endrule

    // -------------------------
    // Test 1: sequenced hit/miss and non-blocking behavior
    // -------------------------
    rule state_0_send_read_a(rg_test_state == 0);
      `logLevel(llctb, 1, fn_info($format("[TB] TEST1 start: non-blocking miss/hit sequencing")))
      let req = fn_mk_read_req(fn_nb_addr_a(), fn_test_hart());
      `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
      dut.ca_llcache_req.put(req);
      rg_test_state <= 1;
    endrule

    rule state_1_send_read_b(rg_test_state == 1);
      let req = fn_mk_read_req(fn_nb_addr_b(), fn_test_hart());
      `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
      dut.ca_llcache_req.put(req);
      rg_test_state <= 2;
    endrule

    rule state_2_wait_two_misses(rg_test_state == 2 && rg_miss_count >= 2);
      if (v_miss_addr_log[0] != fn_nb_addr_a()) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST1 miss[0] mismatch. Got %h Expected %h",
                                v_miss_addr_log[0], fn_nb_addr_a())))
        $finish;
      end
      if (v_miss_addr_log[1] != fn_nb_addr_b()) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST1 miss[1] mismatch. Got %h Expected %h",
                                v_miss_addr_log[1], fn_nb_addr_b())))
        $finish;
      end
      dut.ca_llcache_resp.put(fn_mk_fill_resp(fn_nb_addr_a(), fn_nb_data_a(), fn_test_hart()));
      rg_test_state <= 3;
    endrule

    rule state_3_wait_resp_a_fill(rg_test_state == 3 && rg_resp_count >= 1);
      if (!fn_resp_match(v_resp_log[0], fn_nb_addr_a(), fn_nb_data_a(), fn_test_hart())) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST1 fill response A mismatch")))
        $finish;
      end
      rg_miss_ref <= rg_miss_count;
      let req = fn_mk_read_req(fn_nb_addr_a(), fn_test_hart());
      `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
      dut.ca_llcache_req.put(req);
      rg_test_state <= 4;
    endrule

    rule state_4_wait_resp_a_hit(rg_test_state == 4 && rg_resp_count >= 2);
      if (!fn_resp_match(v_resp_log[1], fn_nb_addr_a(), fn_nb_data_a(), fn_test_hart())) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST1 hit response A mismatch")))
        $finish;
      end
      if (rg_miss_count != rg_miss_ref) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST1 unexpected miss while B miss is pending")))
        $finish;
      end
      dut.ca_llcache_resp.put(fn_mk_fill_resp(fn_nb_addr_b(), fn_nb_data_b(), fn_test_hart()));
      rg_test_state <= 5;
    endrule

    rule state_5_wait_resp_b_fill(rg_test_state == 5 && rg_resp_count >= 3);
      if (!fn_resp_match(v_resp_log[2], fn_nb_addr_b(), fn_nb_data_b(), fn_test_hart())) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST1 fill response B mismatch")))
        $finish;
      end
      rg_miss_ref <= rg_miss_count;
      let req = fn_mk_read_req(fn_nb_addr_b(), fn_test_hart());
      `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
      dut.ca_llcache_req.put(req);
      rg_test_state <= 6;
    endrule

    rule state_6_wait_resp_b_hit(rg_test_state == 6 && rg_resp_count >= 4);
      if (!fn_resp_match(v_resp_log[3], fn_nb_addr_b(), fn_nb_data_b(), fn_test_hart())) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST1 hit response B mismatch")))
        $finish;
      end
      if (rg_miss_count != rg_miss_ref) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST1 unexpected miss on B hit")))
        $finish;
      end
      `logLevel(llctb, 2, fn_pass($format("[TB][PASS] TEST1 non-blocking miss/hit sequencing verified")))

      rg_fill_idx <= 0;
      rg_miss_ref <= rg_miss_count;
      rg_resp_ref <= rg_resp_count;
      rg_test_state <= 10;
    endrule

    // -------------------------
    // Test 2: full-set fill + pLRU-driven eviction check
    // -------------------------
    rule state_10_fill_set_send_read(rg_test_state == 10);
      if (rg_fill_idx < fromInteger(valueOf(`llcways) - 2)) begin
        rg_cur_addr <= fn_plru_fill_addr(rg_fill_idx);
        rg_cur_data <= fn_plru_fill_data(rg_fill_idx);
        let req = fn_mk_read_req(fn_plru_fill_addr(rg_fill_idx), fn_test_hart());
        `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
        dut.ca_llcache_req.put(req);
        rg_test_state <= 11;
      end
      else begin
        rg_miss_ref <= rg_miss_count;
        rg_resp_ref <= rg_resp_count;
        rg_cur_addr <= fn_plru_new_addr();
        rg_cur_data <= fn_plru_new_data();
        let req = fn_mk_read_req(fn_plru_new_addr(), fn_test_hart());
        `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
        dut.ca_llcache_req.put(req);
        rg_test_state <= 30;
      end
    endrule

    rule state_11_fill_wait_miss(rg_test_state == 11 && rg_miss_count >= (rg_miss_ref + 1));
      Bit#(6) idx = truncate(pack(rg_miss_ref));
      if (v_miss_addr_log[idx] != rg_cur_addr) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 set fill miss mismatch. Got %h Expected %h",
                                v_miss_addr_log[idx], rg_cur_addr)))
        $finish;
      end
      dut.ca_llcache_resp.put(fn_mk_fill_resp(rg_cur_addr, rg_cur_data, fn_test_hart()));
      rg_test_state <= 12;
    endrule

    rule state_12_fill_wait_resp(rg_test_state == 12 && rg_resp_count >= (rg_resp_ref + 1));
      Bit#(6) idx = truncate(pack(rg_resp_ref));
      if (!fn_resp_match(v_resp_log[idx], rg_cur_addr, rg_cur_data, fn_test_hart())) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 set fill response mismatch")))
        $finish;
      end
      rg_miss_ref <= rg_miss_ref + 1;
      rg_resp_ref <= rg_resp_ref + 1;
      rg_fill_idx <= rg_fill_idx + 1;
      rg_test_state <= 10;
    endrule

    rule state_30_wait_newline_miss(rg_test_state == 30 && rg_miss_count >= (rg_miss_ref + 1));
      Bit#(6) idx = truncate(pack(rg_miss_ref));
      if (v_miss_addr_log[idx] != rg_cur_addr) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 pLRU miss for new line mismatch. Got %h Expected %h",
                                v_miss_addr_log[idx], rg_cur_addr)))
        $finish;
      end
      dut.ca_llcache_resp.put(fn_mk_fill_resp(rg_cur_addr, rg_cur_data, fn_test_hart()));
      rg_test_state <= 31;
    endrule

    rule state_31_wait_newline_resp(rg_test_state == 31 && rg_resp_count >= (rg_resp_ref + 1));
      Bit#(6) idx = truncate(pack(rg_resp_ref));
      if (!fn_resp_match(v_resp_log[idx], rg_cur_addr, rg_cur_data, fn_test_hart())) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 pLRU response for new line mismatch")))
        $finish;
      end
      rg_resp_ref <= rg_resp_ref + 1;
      rg_probe_idx <= 0;
      rg_has_retained <= False;
      rg_cur_addr <= fn_probe_addr(0);
      rg_cur_data <= fn_probe_data(0);
      rg_miss_ref <= rg_miss_count;
      let req = fn_mk_read_req(fn_probe_addr(0), fn_test_hart());
      `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
      dut.ca_llcache_req.put(req);
      rg_test_state <= 32;
    endrule

    rule state_32_probe_eviction_on_miss(rg_test_state == 32 && rg_miss_count >= (rg_miss_ref + 1));
      Bit#(6) idx = truncate(pack(rg_miss_ref));
      if (v_miss_addr_log[idx] != rg_cur_addr) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 miss address mismatch during victim probe. Got %h Expected %h",
                                v_miss_addr_log[idx], rg_cur_addr)))
        $finish;
      end
      dut.ca_llcache_resp.put(fn_mk_fill_resp(rg_cur_addr, rg_cur_data, fn_test_hart()));
      rg_test_state <= 33;
    endrule

    rule state_32_probe_eviction_on_hit(rg_test_state == 32 && rg_miss_count == rg_miss_ref && rg_resp_count >= (rg_resp_ref + 1));
      Bit#(6) idx = truncate(pack(rg_resp_ref));
      if (!fn_resp_match(v_resp_log[idx], rg_cur_addr, rg_cur_data, fn_test_hart())) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 probe hit response mismatch")))
        $finish;
      end

      if (!rg_has_retained) begin
        rg_has_retained <= True;
        rg_retained_addr <= rg_cur_addr;
        rg_retained_data <= rg_cur_data;
      end

      if (rg_probe_idx == 7) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 could not identify an evicted line after set replacement")))
        $finish;
      end

      let next_idx = rg_probe_idx + 1;
      rg_probe_idx <= next_idx;
      rg_resp_ref <= rg_resp_ref + 1;
      rg_cur_addr <= fn_probe_addr(next_idx);
      rg_cur_data <= fn_probe_data(next_idx);
      rg_miss_ref <= rg_miss_count;
      let req = fn_mk_read_req(fn_probe_addr(next_idx), fn_test_hart());
      `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
      dut.ca_llcache_req.put(req);
    endrule

    rule state_33_wait_victim_refill_resp(rg_test_state == 33 && rg_resp_count >= (rg_resp_ref + 1));
      Bit#(6) idx = truncate(pack(rg_resp_ref));
      if (!fn_resp_match(v_resp_log[idx], rg_cur_addr, rg_cur_data, fn_test_hart())) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 victim refill response mismatch")))
        $finish;
      end
      rg_resp_ref <= rg_resp_ref + 1;
      if (!rg_has_retained) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 no retained line available for final hit check")))
        $finish;
      end
      rg_cur_addr <= rg_retained_addr;
      rg_cur_data <= rg_retained_data;
      rg_miss_ref <= rg_miss_count;
      let req = fn_mk_read_req(rg_retained_addr, fn_test_hart());
      `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
      dut.ca_llcache_req.put(req);
      rg_test_state <= 34;
    endrule

    rule state_34_wait_keep_hit(rg_test_state == 34 && rg_resp_count >= (rg_resp_ref + 1));
      Bit#(6) idx = truncate(pack(rg_resp_ref));
      if (!fn_resp_match(v_resp_log[idx], rg_cur_addr, rg_cur_data, fn_test_hart())) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 non-evicted line response mismatch")))
        $finish;
      end
      if (rg_miss_count != rg_miss_ref) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] TEST2 non-evicted line unexpectedly missed")))
        $finish;
      end
      `logLevel(llctb, 2, fn_pass($format("[TB][PASS] TEST2 full-set fill and pLRU eviction behavior verified")))
      `logLevel(llctb, 2, fn_pass($format("[TB][PASS] All requested LLCache tests passed")))
      $finish;
    endrule

    rule rl_timeout(rg_cycles > 3000);
      `logLevel(llctb, 3, fn_fail($format("[TB][FAIL] Timeout waiting for LLC behavior (state=%0d miss=%0d resp=%0d miss_ref=%0d resp_ref=%0d)",
                              rg_test_state, rg_miss_count, rg_resp_count, rg_miss_ref, rg_resp_ref)))
      $finish;
    endrule

  endmodule: mkLLCTestbench

endpackage: LLCache_tb
