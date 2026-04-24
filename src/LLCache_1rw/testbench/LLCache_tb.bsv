/*
Author: Sanjeev Subrahmaniyan
E-mail: subrahmaniyansanjeev@gmail.com
*/

package LLCache_tb;

  import Vector   :: *;
  import GetPut   :: *;
  import FIFOF    :: *;
  import RegFile  :: *;
  `include "Logger.bsv"

  import LLCache       :: *;
  import LLCache_types :: *;
  `include "LLCache.defines"

  typedef TMul#(`llcblocks, TMul#(`llcwords, 8)) LLCLineBits;
  typedef CA_LLCache_request_t#(`paddr, LLCLineBits, `ncores) TB_CAReq_t;
  typedef CA_LLCache_response_t#(`paddr, LLCLineBits, `ncores) TB_CAResp_t;
  typedef LLCache_CA_response_t#(LLCLineBits, `paddr, `ncores) TB_LLCResp_t;
  typedef Bit#(TAdd#(`paddr, 32)) TB_Command_t;

  (* synthesize *)
  module mkLLCTestbench(Empty);

    Reg#(UInt#(16)) rg_pc <- mkReg(0);
    Reg#(UInt#(32)) rg_cycles <- mkReg(0);
    Reg#(UInt#(16)) rg_miss_count <- mkReg(0);
    Reg#(UInt#(16)) rg_resp_count <- mkReg(0);
    Reg#(Bool) rg_done <- mkReg(False);

    Reg#(Bool) rg_no_miss_active <- mkReg(False);
    Reg#(UInt#(16)) rg_no_miss_left <- mkReg(0);
    Reg#(UInt#(16)) rg_no_miss_start <- mkReg(0);

    RegFile#(Bit#(10), TB_Command_t) rg_stim <- mkRegFileFullLoad("test.mem");
    FIFOF#(Bit#(`paddr)) ff_miss_addr <- mkSizedFIFOF(16);
    FIFOF#(TB_LLCResp_t) ff_resp <- mkSizedFIFOF(16);

    Ifc_LLCache dut <- mkLLCache;

    function Bit#(TLog#(`ncores)) fn_test_hart();
      return 0;
    endfunction

    function Bit#(LLCLineBits) fn_data_for_tag(Bit#(8) tag);
      return zeroExtend({tag, 24'h00ABCD});
    endfunction

    function Bit#(8) fn_data_tag_from_addr(Bit#(`paddr) addr);
      return truncate(addr >> 12);
    endfunction

    function Bit#(LLCLineBits) fn_data_for_addr(Bit#(`paddr) addr);
      return fn_data_for_tag(fn_data_tag_from_addr(addr));
    endfunction

    function Bit#(8) fn_cmd_opcode(TB_Command_t cmd);
      return truncate(cmd >> (`paddr + 24));
    endfunction

    function Bit#(16) fn_cmd_arg(TB_Command_t cmd);
      return truncate(cmd >> `paddr);
    endfunction

    function Bit#(`paddr) fn_cmd_addr(TB_Command_t cmd);
      return truncate(cmd);
    endfunction

    function UInt#(16) fn_nonzero_cycles(Bit#(16) arg);
      UInt#(16) x = unpack(arg);
      return (x == 0) ? 1 : x;
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

    rule rl_tick(!rg_done);
      rg_cycles <= rg_cycles + 1;
    endrule

    rule rl_capture_miss(!rg_done);
      let miss_req <- dut.llcache_ca_req.get();
      `logLevel(llctb, 1, fn_info($format("[MISS] Addr: %h Access: %0d",
                              miss_req.address, miss_req.access)))

      if (miss_req.access != Read) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL][CONFLICT] Miss request had non-read access")))
        $finish(1);
      end

      ff_miss_addr.enq(miss_req.address);
      rg_miss_count <= rg_miss_count + 1;
    endrule

    rule rl_capture_resp(!rg_done);
      let resp <- dut.llcache_ca_resp.get();
      `logLevel(llctb, 1, fn_info(fn_core_resp_fmt(resp)))
      ff_resp.enq(resp);
      rg_resp_count <= rg_resp_count + 1;
    endrule

    rule rl_no_miss_guard(rg_no_miss_active && !rg_done);
      if (rg_miss_count != rg_no_miss_start) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL][CONFLICT] Expected no new miss, but miss_count changed from %0d to %0d",
                                rg_no_miss_start, rg_miss_count)))
        $finish(1);
      end
      else if (rg_no_miss_left == 1) begin
        rg_no_miss_active <= False;
        rg_pc <= rg_pc + 1;
      end
      else begin
        rg_no_miss_left <= rg_no_miss_left - 1;
      end
    endrule

    rule rl_op_end(!rg_done && !rg_no_miss_active &&
                   fn_cmd_opcode(rg_stim.sub(truncate(pack(rg_pc)))) == 8'h00);
      `logLevel(llctb, 2, fn_pass($format("[TB][PASS]")))
      rg_done <= True;
      $finish(0);
    endrule

    rule rl_op_send_req(!rg_done && !rg_no_miss_active &&
                        fn_cmd_opcode(rg_stim.sub(truncate(pack(rg_pc)))) == 8'h01);
      TB_Command_t cmd = rg_stim.sub(truncate(pack(rg_pc)));
      Bit#(`paddr) addr = fn_cmd_addr(cmd);
      Bit#(TLog#(`ncores)) hart = truncate(fn_cmd_arg(cmd));
      let req = fn_mk_read_req(addr, hart);
      `logLevel(llctb, 1, fn_info(fn_core_req_fmt(req)))
      dut.ca_llcache_req.put(req);
      rg_pc <= rg_pc + 1;
    endrule

    rule rl_op_expect_miss(!rg_done && !rg_no_miss_active &&
                           fn_cmd_opcode(rg_stim.sub(truncate(pack(rg_pc)))) == 8'h02 &&
                           ff_miss_addr.notEmpty);
      TB_Command_t cmd = rg_stim.sub(truncate(pack(rg_pc)));
      Bit#(`paddr) addr = fn_cmd_addr(cmd);
      let got = ff_miss_addr.first;
      ff_miss_addr.deq();
      if (got != addr) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL][CONFLICT] Miss mismatch. Got %h Expected %h", got, addr)))
        $finish(1);
      end
      rg_pc <= rg_pc + 1;
    endrule

    rule rl_op_send_fill(!rg_done && !rg_no_miss_active &&
                         fn_cmd_opcode(rg_stim.sub(truncate(pack(rg_pc)))) == 8'h03);
      TB_Command_t cmd = rg_stim.sub(truncate(pack(rg_pc)));
      Bit#(`paddr) addr = fn_cmd_addr(cmd);
      Bit#(TLog#(`ncores)) hart = truncate(fn_cmd_arg(cmd));
      Bit#(LLCLineBits) expected_data = fn_data_for_addr(addr);
      let fill = fn_mk_fill_resp(addr, expected_data, hart);
      `logLevel(llctb, 1, fn_info($format("[FILL] Addr: %h Data: %h Hart: %0d",
                              fill.address, fill.data, fill.hart_id)))
      dut.ca_llcache_resp.put(fill);
      rg_pc <= rg_pc + 1;
    endrule

    rule rl_op_expect_resp(!rg_done && !rg_no_miss_active &&
                           fn_cmd_opcode(rg_stim.sub(truncate(pack(rg_pc)))) == 8'h04 &&
                           ff_resp.notEmpty);
      TB_Command_t cmd = rg_stim.sub(truncate(pack(rg_pc)));
      Bit#(`paddr) addr = fn_cmd_addr(cmd);
      Bit#(TLog#(`ncores)) hart = truncate(fn_cmd_arg(cmd));
      Bit#(LLCLineBits) expected_data = fn_data_for_addr(addr);
      let got = ff_resp.first;
      ff_resp.deq();
      if (!fn_resp_match(got, addr, expected_data, hart)) begin
        `logLevel(llctb, 3, fn_fail($format("[TB][FAIL][CONFLICT] Response mismatch. Got(addr=%h data=%h hart=%0d) Expected(addr=%h data=%h hart=%0d)",
                                got.address, got.data, got.hart_id, addr, expected_data, hart)))
        $finish(1);
      end
      rg_pc <= rg_pc + 1;
    endrule

    rule rl_op_expect_no_miss(!rg_done && !rg_no_miss_active &&
                              fn_cmd_opcode(rg_stim.sub(truncate(pack(rg_pc)))) == 8'h05);
      TB_Command_t cmd = rg_stim.sub(truncate(pack(rg_pc)));
      Bit#(16) arg = fn_cmd_arg(cmd);
      rg_no_miss_active <= True;
      rg_no_miss_left <= fn_nonzero_cycles(arg);
      rg_no_miss_start <= rg_miss_count;
    endrule

    rule rl_op_pass(!rg_done && !rg_no_miss_active &&
                    fn_cmd_opcode(rg_stim.sub(truncate(pack(rg_pc)))) == 8'h06);
      rg_pc <= rg_pc + 1;
    endrule

    rule rl_op_unknown(!rg_done && !rg_no_miss_active &&
                       fn_cmd_opcode(rg_stim.sub(truncate(pack(rg_pc)))) > 8'h06);
      TB_Command_t cmd = rg_stim.sub(truncate(pack(rg_pc)));
      Bit#(8) op = fn_cmd_opcode(cmd);
      `logLevel(llctb, 3, fn_fail($format("[TB][FAIL][CONFLICT] Unknown opcode %0d at pc=%0d", op, rg_pc)))
      $finish(1);
    endrule

    rule rl_timeout(!rg_done && (rg_cycles > 5000));
      `logLevel(llctb, 3, fn_fail($format("[TB][FAIL][CONFLICT] Timeout waiting for LLCache behavior (pc=%0d miss=%0d resp=%0d)",
                              rg_pc, rg_miss_count, rg_resp_count)))
      $finish(1);
    endrule

  endmodule: mkLLCTestbench

endpackage: LLCache_tb
