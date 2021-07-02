/*
see LICENSE.iitm
Author: Neel Gala, Nitya Ranganathan
Email id: neelgala@gmail.com, nitya.ranganathan@gmail.com
Details: Fully associative ITLB (Instruction Translation Lookaside Buffer) for nb_icache

--------------------------------------------------------------------------------------------------
*/
package itlb;
  `include "Logger.bsv"
  `include "common_tlb.defines"
  import Vector :: * ;
  import GetPut :: * ;
  import common_tlb_types :: * ;
  import itlb_types :: * ;


  interface Ifc_itlb;
    interface Get#(PTWalk_tlb_request#(`vaddr)) get_request_to_ptw;

    method ActionValue#(ITLB_core_response#(`paddr)) translate (Bit#(`vaddr) vaddress);
    method ActionValue#(ITLB_core_response#(`paddr)) response_from_ptw(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) resp);
    method Action sfence();

    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(`vaddr) s);

    /*doc:method: method to recieve the current privilege mode of operation*/
    method Action ma_curr_priv (Bit#(2) c);

  `ifdef perfmonitors
    method Bit#(1) mv_perf_counters;
  `endif
  endinterface

  /*doc:module: */
  (*synthesize*)
  module mkitlb#(parameter Bit#(32) hartid) (Ifc_itlb);
    // TLB tag and data arrays
    Vector#( `itlbsize , Reg#(ITLB_tag) ) v_tag <- replicateM(mkReg(unpack(0)));
    Vector#( `itlbsize , Reg#(ITLB_data) ) v_data <- replicateM(mkReg(unpack(0)));
    // TODO: alternative replacement

    Reg#(Bit#(`vaddr)) rg_miss_queue <- mkReg(0);
    /*doc:reg: register to indicate that a tlb miss is in progress*/
    Reg#(Bool) rg_tlb_miss <- mkReg(False);
    /*doc:reg: register to indicate which entry need to be filled/replaced*/
    Reg#(Bit#(TLog#(`itlbsize))) rg_replace <- mkReg(0);

    Wire#(Bit#(1)) wr_tlb_miss <- mkDWire(0);
    Wire#(PTWalk_tlb_request#(`vaddr)) wr_request_to_ptw <- mkDWire(unpack(0));
    /*doc:wire: wire holding the latest value of the satp csr*/
    Wire#(Bit#(`vaddr)) wr_satp <- mkWire();
    /*doc:wire: wire holds the current privilege mode of the core*/
    Wire#(Bit#(2)) wr_priv <- mkWire();

    // global variables based on the above wires
    Bit#(`ppnsize) satp_ppn = truncate(wr_satp);
    Bit#(`asidwidth) satp_asid = wr_satp[`asidwidth - 1 + `ppnsize : `ppnsize ];
  `ifdef sv32
    Bit#(1) satp_mode = truncateLSB(wr_satp);
  `else
    Bit#(4) satp_mode = truncateLSB(wr_satp);
  `endif

  `ifdef perfmonitors
    /*doc:wire: */
    Wire#(Bit#(1)) wr_count_misses <- mkDWire(0);
  `endif

    // translate virtual addr to physical addr: blocking tlb
    method ActionValue#(ITLB_core_response#(`paddr)) translate (Bit#(`vaddr) vaddress) if (!rg_tlb_miss);
      `logLevel( tlb, 0, $format("[%2d]ITLB: received vaddr: %h", hartid, vaddress))

      Bit#(12) page_offset = vaddress[11 : 0];
      Bit#(`vpnsize) fullvpn = truncate(vaddress >> 12);
      Bit#(`itlbsize) lv_hit_mask = '0;
      Bit#(1) lv_hit = 0;
      ITLB_tag lv_hit_tag = unpack(0);
      ITLB_data lv_hit_data = unpack(0);
      ITLB_core_response#(`paddr) lv_resp = unpack(0);
      PTWalk_tlb_request#(`vaddr) lv_ptw_req = unpack(0);

      /*doc:func: */
      function Bool fn_vtag_match (ITLB_tag t);
        return t.permissions.v && (({'1,t.pagemask} & fullvpn) == t.vpn)
                               && (t.asid == satp_asid || t.permissions.g);
      endfunction

      for (Integer i = 0; i < `itlbsize; i=i+1) begin
        lv_hit_mask[i] = pack(fn_vtag_match (v_tag[i]));
        lv_hit_tag = unpack(pack(lv_hit_tag) | (signExtend(lv_hit_mask[i]) & pack(v_tag[i])));
        lv_hit_data = unpack(pack(lv_hit_data) | (signExtend(lv_hit_mask[i]) & pack(v_data[i])));
      end
      lv_hit = |lv_hit_mask;

      Bool page_fault = False;
      Bit#(TSub#(`vaddr, `maxvaddr)) unused_va = vaddress[`vaddr - 1 : `maxvaddr];

      // transparent translation
      if(satp_mode == 0 || wr_priv == 3)begin
        Bit#(`paddr) coreresp = truncate(vaddress);
        Bit#(TSub#(`vaddr, `paddr)) upper_bits = truncateLSB(vaddress);
        Bool trap = |upper_bits == 1;
        lv_resp = ITLB_core_response{hit      : True,
                                     address  : signExtend(coreresp),
                                     trap     : trap,
                                     cause    : `Inst_access_fault};
        `logLevel( itlb, 0, $format("[%2d]ITLB : Transparent Translation. PhyAddr: ", hartid, fshow(lv_resp)))
      end
      // tlb hit
      else if (lv_hit == 1) begin
        `logLevel( itlb, 0, $format("[%2d]ITLB: Hit in TLB: %h", hartid, lv_hit_data.ppn))
        let permissions = lv_hit_tag.permissions;
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = truncate(lv_hit_tag.pagemask);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(lv_hit_data.ppn);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa =(mask&lower_ppn)|(~mask&lower_vpn);
        Bit#(`lastppnsize) highest_ppn = truncateLSB(lv_hit_data.ppn);
        `ifdef sv32
          Bit#(`vaddr) physicaladdress = truncate({highest_ppn, lower_pa, page_offset});
        `else
          Bit#(`vaddr) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});
        `endif

        `logLevel( itlb, 0, $format("[%2d]mask:%h",hartid,mask))
        `logLevel( itlb, 0, $format("[%2d]lower_ppn:%h",hartid,lower_ppn))
        `logLevel( itlb, 0, $format("[%2d]lower_vpn:%h",hartid,lower_vpn))
        `logLevel( itlb, 0, $format("[%2d]lower_pa:%h",hartid,lower_pa))
        `logLevel( itlb, 0, $format("[%2d]highest_ppn:%h",hartid,highest_ppn))

        // check for permission faults
        `ifndef sv32
          if(unused_va != signExtend(vaddress[`maxvaddr-1]))begin
            page_fault = True;
          end
        `endif
        // pte.x == 0
        if(!permissions.x)
          page_fault = True;
        // pte.a == 0
        else if(!permissions.a)
          page_fault = True;
        // pte.u == 0 for user mode
        else if(!permissions.u && wr_priv == 0)
           page_fault = True;
        // pte.u = 1 for supervisor
        else if(permissions.u && wr_priv == 1)
          page_fault = True;
        `logLevel( itlb, 0, $format("[%2d]ITLB: Sending PA:%h Trap:%b", hartid, physicaladdress, page_fault))
        lv_resp = ITLB_core_response{hit      : True,
                                     address  : truncate(physicaladdress),
                                     trap     : page_fault,
                                     cause    : `Inst_pagefault};
      end
      // tlb miss
      else begin
        // Send virtual - address and indicate it is an instruction access to the PTW
        `logLevel( itlb, 0, $format("[%2d]ITLB : TLBMiss. Sending Address to PTW:%h", hartid, vaddress))
        lv_resp.hit = False;

        `ifdef perfmonitors
          wr_count_misses <= 1;
        `endif

        lv_ptw_req.address = vaddress;
        lv_ptw_req.access = 3;

        rg_tlb_miss <= True;
        rg_miss_queue <= vaddress;
        wr_tlb_miss <= 1;
        wr_request_to_ptw <= lv_ptw_req;
      end

      // return lookup result
      return lv_resp;
    endmethod // translate

    // response from ptw to tlb
    method ActionValue#(ITLB_core_response#(`paddr)) response_from_ptw(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) resp) if(rg_tlb_miss);
      let core_req = rg_miss_queue;
      Bit#(12) page_offset = core_req[11 : 0];

      Bit#(`vpnsize) fullvpn = truncate(core_req >> 12);
      Bit#(`ppnsize) fullppn = truncate(resp.pte >> 10);
      Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = '1;
      Bit#(TLog#(TMul#(TSub#(`varpages,1),`subvpn))) shiftamt = `subvpn * zeroExtend(resp.levels);
      mask = mask << shiftamt;
      Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(fullppn);
      Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(core_req >> 12);
      Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa =(mask&lower_ppn)|(~mask&lower_vpn);
      Bit#(`lastppnsize) highest_ppn = truncateLSB(fullppn);
    `ifdef sv32
      Bit#(`vaddr) physicaladdress = truncate({highest_ppn, lower_pa, page_offset});
    `else
      Bit#(`vaddr) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});
    `endif
      ITLB_tag lv_tag = unpack(0);
      ITLB_data lv_data = unpack(0);
      ITLB_core_response#(`paddr) lv_resp = unpack(0);
      Bit#(TAdd#(TLog#(`itlbsize), 1)) lv_repl_next = '0;

      lv_tag = ITLB_tag{permissions: unpack(truncate(resp.pte)),
                        vpn: {'1,mask} & fullvpn,
                        asid: satp_asid,
                        pagemask: mask};
      lv_data.ppn = fullppn;

      lv_resp = ITLB_core_response{hit      : !resp.trap,
                                   address  : truncate(physicaladdress),
                                   trap     : resp.trap,
                                   cause    : resp.cause};

      // write tag and data
      // NOTE: check tlb miss followed by sfence case (flush handling and installing previous ptw response in tlb based on asid)
      if(!resp.trap) begin
        `logLevel( itlb, 0, $format("[%2d]ITLB: Allocating index:%d for Tag:", hartid, rg_replace, fshow(lv_tag)))
        v_tag[rg_replace] <= lv_tag;
        v_data[rg_replace] <= lv_data;
        lv_repl_next = zeroExtend(rg_replace + 1);
        rg_replace <= (lv_repl_next == `itlbsize) ? '0 : (rg_replace + 1);
      end
      else begin
        `logLevel( itlb, 0, $format("[%2d]ITLB: Got an Error from PTW",hartid))
      end

      rg_tlb_miss <= False;

      // return response: cache may use the response this cycle or replay the request in the next cycle (if no ptw trap)
      return lv_resp;
    endmethod

    interface get_request_to_ptw = interface Get
      method ActionValue#(PTWalk_tlb_request#(`vaddr)) get if (wr_tlb_miss == 1);
        // return request at the end of this cycle (ptw has interface latches)
        return wr_request_to_ptw;
      endmethod
    endinterface;

    method Action ma_satp_from_csr (Bit#(`vaddr) s);
      wr_satp <= s;
    endmethod

    method Action ma_curr_priv (Bit#(2) c);
        wr_priv <= c;
    endmethod

    // Invalidate all tags on sfence
    method Action sfence () if (!rg_tlb_miss);
      for (Integer i = 0; i < `itlbsize; i = i + 1) begin
        v_tag[i] <= unpack(0);
      end

      `logLevel( itlb, 0, $format("[%2d]ITLB: SFence received",hartid))

      rg_tlb_miss <= False;
      rg_replace <= '0;
    endmethod

  `ifdef perfmonitors
    method mv_perf_counters = wr_count_misses;
  `endif
  endmodule

endpackage

