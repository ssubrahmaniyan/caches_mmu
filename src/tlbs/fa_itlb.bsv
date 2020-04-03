/*
see LICENSE.incore
see LICENSE.iitm
Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package fa_itlb;
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

  interface Ifc_fa_itlb;

    interface Put#(ITLB_core_request#(`vaddr)) put_core_request;
    interface Get#(ITLB_core_response#(`paddr)) get_core_response;

    interface Get#(PTWalk_tlb_request#(`vaddr)) get_request_to_ptw;
    interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) put_response_frm_ptw;

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
  module mkfa_itlb#(parameter Bit#(32) hartid) (Ifc_fa_itlb);

    Vector#( `itlbsize , Reg#(VPNTag) ) v_vpn_tag <- replicateM(mkReg(unpack(0))) ;

    /*doc:reg: register to indicate which entry need to be filled/replaced*/
    Reg#(Bit#(TLog#(`itlbsize))) rg_replace <- mkReg(0);
    /*doc:wire: wire holding the latest value of the satp csr*/
    Wire#(Bit#(`vaddr)) wr_satp <- mkWire();
    /*doc:wire: wire holds the current privilege mode of the core*/
    Wire#(Bit#(2)) wr_priv <- mkWire();

    Reg#(Bit#(`vaddr)) rg_miss_queue <- mkReg(0);
    FIFOF#(PTWalk_tlb_request#(`vaddr)) ff_request_to_ptw <- mkSizedFIFOF(2);
    FIFOF#(ITLB_core_response#(`paddr)) ff_core_respone <- mkSizedFIFOF(2);

    // global variables based on the above wires
    Bit#(`ppnsize) satp_ppn = truncate(wr_satp);
    Bit#(`asidwidth) satp_asid = wr_satp[`asidwidth - 1 + `ppnsize : `ppnsize ];
  `ifdef sv32
    Bit#(1) satp_mode = truncateLSB(wr_satp);
  `else
    Bit#(4) satp_mode = truncateLSB(wr_satp);
  `endif

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
    rule rl_fence(rg_sfence);
      for (Integer i = 0; i < `itlbsize; i = i + 1) begin
        v_vpn_tag[i] <= unpack(0);
      end
      rg_sfence <= False;
      rg_tlb_miss <= False;
      rg_replace <= 0;
    endrule

    interface put_core_request = interface Put
      method Action put (ITLB_core_request#(`vaddr) req) if(!rg_sfence && !rg_tlb_miss);

        `logLevel( tlb, 0, $format("[%2d]ITLB: received req: ",hartid,fshow(req)))

        Bit#(12) page_offset = req.address[11 : 0];
        Bit#(`vpnsize) fullvpn = truncate(req.address >> 12);

        /*doc:func: */
        function Bool fn_vtag_match (VPNTag t);
          return t.permissions.v && (({'1,t.pagemask} & fullvpn) == t.vpn)
                                 && (t.asid == satp_asid || t.permissions.g);
        endfunction

        Bit#(TLog#(`itlbsize)) tagmatch = 0;
        if(req.sfence)begin
          `logLevel( itlb, 0, $format("[%2d]ITLB: SFence received",hartid))
          rg_sfence <= True;
        end
        else begin
          let hit_entry = find(fn_vtag_match, readVReg(v_vpn_tag));
          Bool page_fault = False;
          Bit#(TSub#(`vaddr, `maxvaddr)) unused_va = req.address[`vaddr - 1 : `maxvaddr];
          // transparent translation
          if(satp_mode == 0 || wr_priv == 3)begin
            Bit#(`paddr) coreresp = truncate(req.address);
            Bit#(TSub#(`vaddr, `paddr)) upper_bits = truncateLSB(req.address);
            Bool trap = |upper_bits == 1;
            ff_core_respone.enq(ITLB_core_response{address  : signExtend(coreresp),
                                                   trap     : trap,
                                                   cause    : `Inst_access_fault});
            `logLevel( itlb, 0, $format("[%2d]ITLB : Transparent Translation. PhyAddr: %h",hartid,coreresp))
          end
          else if (hit_entry matches tagged Valid .pte) begin
            `logLevel( itlb, 0, $format("[%2d]ITLB: Hit in TLB:",hartid,fshow(pte)))
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

            `logLevel( itlb, 0, $format("[%2d]mask:%h",hartid,mask))
            `logLevel( itlb, 0, $format("[%2d]lower_ppn:%h",hartid,lower_ppn))
            `logLevel( itlb, 0, $format("[%2d]lower_vpn:%h",hartid,lower_vpn))
            `logLevel( itlb, 0, $format("[%2d]lower_pa:%h",hartid,lower_pa))
            `logLevel( itlb, 0, $format("[%2d]highest_ppn:%h",hartid,highest_ppn))

            // check for permission faults
          `ifndef sv32
            if(unused_va != signExtend(req.address[`maxvaddr-1]))begin
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
            `logLevel( itlb, 0, $format("[%2d]ITLB: Sending PA:%h Trap:%b", hartid,physicaladdress, page_fault))
            ff_core_respone.enq(ITLB_core_response{address  : truncate(physicaladdress),
                                                   trap     : page_fault,
                                                   cause    : `Inst_pagefault });
          end
          else begin
            // Send virtual - address and indicate it is an instruction access to the PTW
            `logLevel( itlb, 0, $format("[%2d]ITLB : TLBMiss. Sending Address to PTW:%h", hartid,req.address))
            rg_tlb_miss <= True;
          `ifdef perfmonitors
            wr_count_misses <= 1;
          `endif
            rg_miss_queue <= req.address;
            ff_request_to_ptw.enq(PTWalk_tlb_request{address : req.address, access : 3 });
          end
        end
      endmethod
    endinterface;

    interface put_response_frm_ptw = interface Put
      method Action put(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) resp) if(rg_tlb_miss && !rg_sfence);
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

        ff_core_respone.enq(ITLB_core_response{ address: truncate(physicaladdress),
                                                trap: resp.trap,
                                                cause: resp.cause});

        let tag = VPNTag{ permissions: unpack(truncate(resp.pte)),
                          vpn: {'1,mask} & fullvpn,
                          asid: satp_asid,
                          pagemask: mask,
                          ppn: fullppn };
        if(!resp.trap) begin
          `logLevel( itlb, 0, $format("[%2d]ITLB: Allocating index:%d for Tag:", hartid,rg_replace, fshow(tag)))
          v_vpn_tag[rg_replace] <= tag;
          rg_replace <= rg_replace + 1;
        end
        else begin
          `logLevel( itlb, 0, $format("[%2d]ITLB: Got an Error from PTW",hartid))
        end

        rg_tlb_miss <= False;
      endmethod
    endinterface;

    interface get_core_response = toGet(ff_core_respone);

    interface get_request_to_ptw = toGet(ff_request_to_ptw);

    method Action ma_satp_from_csr (Bit#(`vaddr) s);
      wr_satp <= s;
    endmethod

    method Action ma_curr_priv (Bit#(2) c);
        wr_priv <= c;
    endmethod

  `ifdef perfmonitors
    method mv_perf_counters = wr_count_misses;
  `endif
  endmodule

endpackage

