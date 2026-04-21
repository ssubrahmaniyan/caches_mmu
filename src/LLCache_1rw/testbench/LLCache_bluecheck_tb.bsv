package LLCache_bluecheck_tb;

  import BlueCheck :: *;
  import GetPut :: *;
  import StmtFSM :: *;
  import LLCache :: *;
  import LLCache_types :: *;
  `include "LLCache.defines"

  typedef TMul#(`llcblocks, TMul#(`llcwords, 8)) LLCLineBits;
  typedef CA_LLCache_request_t#(`paddr, LLCLineBits, `ncores) TB_CAReq_t;
  typedef CA_LLCache_response_t#(`paddr, LLCLineBits, `ncores) TB_CAResp_t;
  typedef LLCache_CA_response_t#(LLCLineBits, `paddr, `ncores) TB_LLCResp_t;

  module [BlueCheck] mkLLCacheBlueCheckSpec();
    Ifc_LLCache dut <- mkLLCache;
    Ifc_LLCache dut_nb <- mkLLCache;
    Ifc_LLCache dut_plru <- mkLLCache;
    EnsureMsg ensure <- getEnsureMsg;

    Reg#(UInt#(16)) rg_core_req_count <- mkReg(0);
    Reg#(UInt#(16)) rg_core_resp_count <- mkReg(0);
    Reg#(UInt#(16)) rg_mem_req_count <- mkReg(0);
    Reg#(Bool) rg_nb_done <- mkReg(False);
    Reg#(Bool) rg_plru_done <- mkReg(False);

    function Bit#(`paddr) fn_test_addr();
      return 'h1000;
    endfunction

    function Bit#(`paddr) fn_same_set_addr(Bit#(8) tag);
      Bit#(`paddr) set_base = 'h0C0;
      return (zeroExtend(tag) << 12) | set_base;
    endfunction

    function Bit#(LLCLineBits) fn_data_for_tag(Bit#(8) tag);
      return zeroExtend({tag, 24'h00ABCD});
    endfunction

    function Bit#(TLog#(`ncores)) fn_test_hart();
      return 0;
    endfunction

    function TB_CAReq_t fn_mk_core_req(AccessType_t access, Bit#(LLCLineBits) data);
      return CA_LLCache_request_t{
        address: fn_test_addr(),
        access: access,
        data: data,
        hart_id: fn_test_hart()
      };
    endfunction

    function TB_CAReq_t fn_mk_read_req(Bit#(`paddr) addr);
      return CA_LLCache_request_t{
        address: addr,
        access: Read,
        data: 0,
        hart_id: fn_test_hart()
      };
    endfunction

    function TB_CAResp_t fn_mk_fill_resp_addr(Bit#(`paddr) addr, Bit#(LLCLineBits) data);
      return CA_LLCache_response_t{
        address: addr,
        data: data,
        hart_id: fn_test_hart()
      };
    endfunction

    function TB_CAResp_t fn_mk_fill_resp(Bit#(LLCLineBits) data);
      return CA_LLCache_response_t{
        address: fn_test_addr(),
        data: data,
        hart_id: fn_test_hart()
      };
    endfunction

    function Action issueRead();
      action
        dut.ca_llcache_req.put(fn_mk_core_req(Read, 0));
        rg_core_req_count <= rg_core_req_count + 1;
      endaction
    endfunction

    function Action issueWrite(Bit#(LLCLineBits) data);
      action
        dut.ca_llcache_req.put(fn_mk_core_req(Write, data));
        rg_core_req_count <= rg_core_req_count + 1;
      endaction
    endfunction

    function Action serviceMemory(Bit#(LLCLineBits) fillData);
      action
        let missReq <- dut.llcache_ca_req.get();
        ensure((missReq.address == fn_test_addr()) && (missReq.access == Read),
               $format("[BlueCheck][FAIL] Miss request mismatch. Addr: %h Access: %0d",
                       missReq.address, missReq.access));
        dut.ca_llcache_resp.put(fn_mk_fill_resp(fillData));
        rg_mem_req_count <= rg_mem_req_count + 1;
      endaction
    endfunction

    function Action consumeCoreResponse();
      action
        let resp <- dut.llcache_ca_resp.get();
        ensure((resp.address == fn_test_addr()) && (resp.hart_id == fn_test_hart()),
               $format("[BlueCheck][FAIL] Core response mismatch. Addr: %h Hart: %0d",
                       resp.address, resp.hart_id));
        rg_core_resp_count <= rg_core_resp_count + 1;
      endaction
    endfunction

    function Action dir_issue_read(Ifc_LLCache x, Bit#(`paddr) addr);
      action
        x.ca_llcache_req.put(fn_mk_read_req(addr));
      endaction
    endfunction

    function Action dir_service_miss(Ifc_LLCache x, Bit#(`paddr) expAddr, Bit#(LLCLineBits) fillData);
      action
        let missReq <- x.llcache_ca_req.get();
        ensure((missReq.address == expAddr) && (missReq.access == Read),
               $format("[BlueCheck][FAIL] Miss mismatch. Got addr=%h access=%0d expected addr=%h",
                       missReq.address, missReq.access, expAddr));
        x.ca_llcache_resp.put(fn_mk_fill_resp_addr(expAddr, fillData));
      endaction
    endfunction

    function Action dir_consume_resp(Ifc_LLCache x, Bit#(`paddr) expAddr, Bit#(LLCLineBits) expData);
      action
        let resp <- x.llcache_ca_resp.get();
        ensure((resp.address == expAddr) && (resp.hart_id == fn_test_hart()) && (resp.data == expData),
               $format("[BlueCheck][FAIL] Resp mismatch. Got addr=%h hart=%0d data=%h expected addr=%h data=%h",
                       resp.address, resp.hart_id, resp.data, expAddr, expData));
      endaction
    endfunction

    Stmt nbScenario =
      seq
        action dir_issue_read(dut_nb, fn_same_set_addr('h01)); endaction
        action dir_issue_read(dut_nb, fn_same_set_addr('h02)); endaction
        action dir_service_miss(dut_nb, fn_same_set_addr('h01), fn_data_for_tag('h01)); endaction
        action dir_service_miss(dut_nb, fn_same_set_addr('h02), fn_data_for_tag('h02)); endaction
        action dir_consume_resp(dut_nb, fn_same_set_addr('h01), fn_data_for_tag('h01)); endaction
        action dir_consume_resp(dut_nb, fn_same_set_addr('h02), fn_data_for_tag('h02)); endaction
        action rg_nb_done <= True; endaction
      endseq;

    Stmt plruScenario =
      seq
        action dir_issue_read(dut_plru, fn_same_set_addr('h01)); endaction
        action dir_service_miss(dut_plru, fn_same_set_addr('h01), fn_data_for_tag('h01)); endaction
        action dir_consume_resp(dut_plru, fn_same_set_addr('h01), fn_data_for_tag('h01)); endaction

        action dir_issue_read(dut_plru, fn_same_set_addr('h02)); endaction
        action dir_service_miss(dut_plru, fn_same_set_addr('h02), fn_data_for_tag('h02)); endaction
        action dir_consume_resp(dut_plru, fn_same_set_addr('h02), fn_data_for_tag('h02)); endaction

        action dir_issue_read(dut_plru, fn_same_set_addr('h10)); endaction
        action dir_service_miss(dut_plru, fn_same_set_addr('h10), fn_data_for_tag('h10)); endaction
        action dir_consume_resp(dut_plru, fn_same_set_addr('h10), fn_data_for_tag('h10)); endaction

        action dir_issue_read(dut_plru, fn_same_set_addr('h11)); endaction
        action dir_service_miss(dut_plru, fn_same_set_addr('h11), fn_data_for_tag('h11)); endaction
        action dir_consume_resp(dut_plru, fn_same_set_addr('h11), fn_data_for_tag('h11)); endaction

        action dir_issue_read(dut_plru, fn_same_set_addr('h12)); endaction
        action dir_service_miss(dut_plru, fn_same_set_addr('h12), fn_data_for_tag('h12)); endaction
        action dir_consume_resp(dut_plru, fn_same_set_addr('h12), fn_data_for_tag('h12)); endaction

        action dir_issue_read(dut_plru, fn_same_set_addr('h13)); endaction
        action dir_service_miss(dut_plru, fn_same_set_addr('h13), fn_data_for_tag('h13)); endaction
        action dir_consume_resp(dut_plru, fn_same_set_addr('h13), fn_data_for_tag('h13)); endaction

        action dir_issue_read(dut_plru, fn_same_set_addr('h14)); endaction
        action dir_service_miss(dut_plru, fn_same_set_addr('h14), fn_data_for_tag('h14)); endaction
        action dir_consume_resp(dut_plru, fn_same_set_addr('h14), fn_data_for_tag('h14)); endaction

        action dir_issue_read(dut_plru, fn_same_set_addr('h15)); endaction
        action dir_service_miss(dut_plru, fn_same_set_addr('h15), fn_data_for_tag('h15)); endaction
        action dir_consume_resp(dut_plru, fn_same_set_addr('h15), fn_data_for_tag('h15)); endaction

        action dir_issue_read(dut_plru, fn_same_set_addr('h20)); endaction
        action dir_service_miss(dut_plru, fn_same_set_addr('h20), fn_data_for_tag('h20)); endaction
        action dir_consume_resp(dut_plru, fn_same_set_addr('h20), fn_data_for_tag('h20)); endaction
        action rg_plru_done <= True; endaction
      endseq;

    prop("respCountLeReqCount", rg_core_resp_count <= rg_core_req_count);
    prop("memReqCountLeReqCount", rg_mem_req_count <= rg_core_req_count);

    propf(8, "issueRead", issueRead);
    propf(8, "issueWrite", issueWrite);
    propf(10, "serviceMemory", serviceMemory);
    propf(10, "consumeCoreResponse", consumeCoreResponse);
    propf(1000, "nbDirectedScenario", stmtWhen(!rg_nb_done, nbScenario));
    propf(1000, "plruDirectedScenario", stmtWhen(!rg_plru_done, plruScenario));
  endmodule

  module [Module] mkLLCacheBlueCheckRunner();
    BlueCheck_Params params = bcParams;
    params.numIterations = 5000;
    Stmt s <- mkModelChecker(mkLLCacheBlueCheckSpec, params);
    mkAutoFSM(s);
  endmodule

endpackage
