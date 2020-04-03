/*
see LICENSE.incore
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package fa_dtlb;
  `include "Logger.bsv"
  `include "common_tlb.defines"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import Vector :: * ;
  import common_tlb_types:: * ;
  import GetPut :: * ;

  // structure of the virtual tag for fully-associative look-up
  typedef struct{
    TLB_permissions permissions;
    Bit#(`vpnsize) vpn;
    Bit#(`asidwidth) asid;
    Bit#(TMul#(TSub#(`varpages,1), `subvpn)) pagemask;
    Bit#(`ppnsize) ppn;
  } VPNTag deriving(Bits, FShow, Eq);

  typedef struct{
    Bool trap;
    Bit#(`causesize) cause;
    Bool tlbmiss;
    Bool translation_done;
    Bit#(`vaddr) va;
    VPNTag pte;
    Bit#(2) access;
  } LookUpResult deriving(Bits, FShow, Eq);

  interface Ifc_fa_dtlb;

    interface Put#(DTLB_core_request#(`vaddr)) put_core_request;
    interface Get#(DTLB_core_response#(`paddr)) get_core_response;

    interface Get#(PTWalk_tlb_request#(`vaddr)) get_request_to_ptw;
    interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) put_response_frm_ptw;

    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(`vaddr) s);

    /*doc:method: method to recieve the current privilege mode of operation*/
    method Action ma_curr_priv (Bit#(2) c);

    /*doc:method: method to receive the current values of the mstatus register*/
    method Action ma_mstatus_from_csr (Bit#(`vaddr) m);

    /*doc:method: */
    method Bool mv_tlb_available;
  `ifdef perfmonitors
    method Bit#(1) mv_perf_counters;
  `endif
  endinterface

  /*doc:module: */
  (*synthesize*)
  (*conflict_free="put_response_frm_ptw_put, put_core_request_put"*)
  module mkfa_dtlb#(parameter Bit#(32) hartid) (Ifc_fa_dtlb);

    Vector#( `dtlbsize, Reg#(VPNTag) ) v_vpn_tag <- replicateM(mkReg(unpack(0))) ;

    /*doc:reg: register to indicate which entry need to be filled/replaced*/
    Reg#(Bit#(TLog#(`dtlbsize))) rg_replace <- mkReg(0);
    /*doc:wire: wire holding the latest value of the satp csr*/
    Wire#(Bit#(`vaddr)) wr_satp <- mkWire();
    /*doc:wire: wire holds the current privilege mode of the core*/
    Wire#(Bit#(2)) wr_priv <- mkWire();
    /*doc:wire: wire holding the current values of mstatus fields*/
    Wire#(Bit#(`vaddr)) wr_mstatus <- mkWire();

    /*doc:reg: */
    Reg#(Bit#(`vaddr)) rg_miss_queue <- mkReg(0);
    FIFOF#(PTWalk_tlb_request#(`vaddr)) ff_request_to_ptw <- mkSizedFIFOF(2);
    FIFOF#(LookUpResult) ff_lookup_result <- mkSizedFIFOF(2);
    FIFOF#(DTLB_core_response#(`paddr)) ff_core_response <- mkBypassFIFOF();

    // global variables based on the above wires
    Bit#(`ppnsize) satp_ppn = truncate(wr_satp);
    Bit#(`asidwidth) satp_asid = wr_satp[`asidwidth - 1 + `ppnsize : `ppnsize ];
  `ifdef sv32
    Bit#(1) satp_mode = truncateLSB(wr_satp);
  `else
    Bit#(4) satp_mode = truncateLSB(wr_satp);
  `endif
    Bit#(1) mxr = wr_mstatus[19];
    Bit#(1) sum = wr_mstatus[18];
    Bit#(2) mpp = wr_mstatus[12 : 11];
    Bit#(1) mprv = wr_mstatus[17];

    /*doc:reg: register to indicate that a tlb miss is in progress*/
    Reg#(Bool) rg_tlb_miss <- mkReg(False);

    /*doc:reg: register to indicate the tlb is undergoing an sfence*/
    Reg#(Bool) rg_sfence <- mkReg(False);

  `ifdef perfmonitors
    /*doc:wire: */
    Wire#(Bit#(1)) wr_count_misses <- mkDWire(0);
  `endif

    /*doc:rule: this rule is fired when the core requests a sfence. This rule will simply invalidate
     all the tlb entries*/
    rule rl_fence(rg_sfence && !rg_tlb_miss && !ff_lookup_result.notEmpty);
      for (Integer i = 0; i < `dtlbsize; i = i + 1) begin
        v_vpn_tag[i] <= unpack(0);
      end
      rg_sfence <= False;
      rg_replace <= 0;
      `logLevel( dtlb, 1, $format("DTLB[%2d]: SFencing Now",hartid))
    endrule

    /*doc:rule: */
    rule rl_send_response(!rg_sfence);
      let lookup = ff_lookup_result.first;
      ff_lookup_result.deq;
      Bit#(12) page_offset = lookup.va[11 : 0];
      Bit#(`vpnsize) fullvpn = truncate(lookup.va >> 12);
      Bit#(2) priv = mprv == 0?wr_priv : mpp;
      `logLevel( dtlb, 1, $format("DTLB[%2d]: LookupResult: ",hartid,fshow(lookup)))
      if(lookup.translation_done)begin
        ff_core_response.enq(DTLB_core_response{address: truncate(lookup.va),
                                             trap: lookup.trap,
                                             cause: lookup.cause,
                                             tlbmiss: False});
      end
      else begin
        Bool page_fault = False;
        Bit#(`causesize) cause = lookup.access == 0 ?`Load_pagefault : `Store_pagefault;
        let pte = lookup.pte  ;
        Bit#(TSub#(`vaddr, `maxvaddr)) unused_va = lookup.va[`vaddr - 1 : `maxvaddr];
        let permissions = pte.permissions;
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = truncate(pte.pagemask);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte.ppn);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa =(mask&lower_ppn)|(~mask&lower_vpn);
        Bit#(`lastppnsize) highest_ppn = truncateLSB(pte.ppn);
      `ifdef sv32
        Bit#(`vaddr) physicaladdress = truncate({highest_ppn, lower_pa, page_offset});
      `else
        Bit#(`vaddr) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});
      `endif

        `logLevel( dtlb, 2, $format("DTLB[%2d]: mask:%h",hartid,mask))
        `logLevel( dtlb, 2, $format("DTLB[%2d]: lower_ppn:%h",hartid,lower_ppn))
        `logLevel( dtlb, 2, $format("DTLB[%2d]: lower_vpn:%h",hartid,lower_vpn))
        `logLevel( dtlb, 2, $format("DTLB[%2d]: lower_pa:%h",hartid,lower_pa))
        `logLevel( dtlb, 2, $format("DTLB[%2d]: highest_ppn:%h",hartid,highest_ppn))

        // check for permission faults
      `ifndef sv32
        if(unused_va != signExtend(lookup.va[`maxvaddr-1]))begin
          page_fault = True;
        end
      `endif
        // pte.a == 0 || pte.d == 0 and access != Load
        if(!permissions.a || (!permissions.d && lookup.access != 0))begin
          page_fault = True;
        end
        if(lookup.access == 0 && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
          page_fault = True;
        end
        if(priv == 1 && permissions.u && sum == 0)begin // supervisor accessing user
          page_fault = True;
        end
        if(!permissions.u && priv == 0)begin
          page_fault = True;
        end

        // for Store access
        if(lookup.access != 0 && !permissions.w)begin // if not readable and not mxr  executable
          page_fault = True;
        end
        if(lookup.tlbmiss)begin
          rg_miss_queue <= lookup.va;
          ff_request_to_ptw.enq(PTWalk_tlb_request{address : lookup.va, access : lookup.access });
          ff_core_response.enq(DTLB_core_response{address  : ?,
                                                 trap     : False,
                                                 cause    : ?,
                                                 tlbmiss  : True});
        end
        else begin
          `logLevel( dtlb, 0, $format("DTLB[%2d]: Sending PA:%h Trap:%b",hartid, physicaladdress, page_fault))
          `logLevel( dtlb, 0, $format("DTLB[%2d]: Hit in TLB:",hartid,fshow(pte)))
          ff_core_response.enq(DTLB_core_response{address  : truncate(physicaladdress),
                                               trap     : page_fault,
                                               cause    : cause,
                                               tlbmiss  : False});
        end
      end
    endrule

    interface put_core_request = interface Put
      method Action put (DTLB_core_request#(`vaddr) req) if(!rg_sfence);

        `logLevel( dtlb, 0, $format("DTLB[%2d]: received req: ",hartid,fshow(req)))

        Bit#(12) page_offset = req.address[11 : 0];
        Bit#(`vpnsize) fullvpn = truncate(req.address >> 12);

        /*doc:func: */
        function Bool fn_vtag_match (VPNTag t);
          return t.permissions.v && (({'1,t.pagemask} & fullvpn) == t.vpn)
                                 && (t.asid == satp_asid || t.permissions.g);
        endfunction

        Bit#(`vaddr) va = req.address;
        Bit#(`causesize) cause = req.cause;
        Bool trap = req.ptwalk_trap;
        Bool translation_done = False;
        let hit_entry = find(fn_vtag_match, readVReg(v_vpn_tag));
        Bool tlbmiss = !isValid(hit_entry);
        VPNTag pte = fromMaybe(?,hit_entry);
        Bit#(TSub#(`vaddr, `paddr)) upper_bits = truncateLSB(req.address);
        Bit#(2) priv = mprv == 0?wr_priv : mpp;
        translation_done = (satp_mode == 0 || priv == 3 || req.ptwalk_req || req.ptwalk_trap);
        if(!trap && translation_done)begin
           trap = |upper_bits == 1;
           cause = req.access == 0? `Load_access_fault: `Store_access_fault;
        end

        if(req.sfence && !req.ptwalk_req)begin
          rg_sfence <= True;
        end
        else begin
          ff_lookup_result.enq(LookUpResult{va: va, trap: trap, cause: cause,
                                            translation_done: translation_done,
                                            tlbmiss: tlbmiss, pte: pte, access: req.access});
        end

        if(req.sfence)
          rg_tlb_miss <= False;
        else if(rg_tlb_miss && req.ptwalk_trap)
          rg_tlb_miss <= False;
        else if(!translation_done && !req.ptwalk_req) begin
          rg_tlb_miss <= tlbmiss;
        `ifdef perfmonitors
          wr_count_misses <= pack(tlbmiss);
        `endif
        end

      endmethod
    endinterface;

    interface put_response_frm_ptw = interface Put
      method Action put(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) resp) if(rg_tlb_miss && !rg_sfence);
        let core_req = rg_miss_queue ;
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

        let tag = VPNTag{ permissions: unpack(truncate(resp.pte)),
                          vpn: {'1,mask} & fullvpn,
                          asid: satp_asid,
                          pagemask: mask,
                          ppn: fullppn };
        if(!resp.trap) begin
          `logLevel( dtlb, 0, $format("DTLB[%2d]: Allocating index:%d for Tag:",hartid, rg_replace, fshow(tag)))
          v_vpn_tag[rg_replace] <= tag;
          rg_replace <= rg_replace + 1;
        end

      endmethod
    endinterface;

    interface get_core_response = toGet(ff_core_response);

    interface get_request_to_ptw = toGet(ff_request_to_ptw);

    method Action ma_satp_from_csr (Bit#(`vaddr) s);
      wr_satp <= s;
    endmethod

    method Action ma_curr_priv (Bit#(2) c);
      wr_priv <= c;
    endmethod

    /*doc:method: */
    method Action ma_mstatus_from_csr (Bit#(`vaddr) m);
      wr_mstatus <= m;
    endmethod

    /*doc:method: */
    method mv_tlb_available = !rg_tlb_miss && ff_lookup_result.notFull;
  
  `ifdef perfmonitors
    method mv_perf_counters = wr_count_misses;
  `endif

  endmodule

endpackage

