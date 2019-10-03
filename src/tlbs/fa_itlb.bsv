/*
Copyright (c) 2019, IIT Madras All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions
  and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice, this list of
  conditions and the following disclaimer in the documentation and/or other materials provided
  with the distribution.
* Neither the name of IIT Madras  nor the names of its contributors may be used to endorse or
  promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--------------------------------------------------------------------------------------------------

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package fa_itlb;
  `include "Logger.bsv"
  `include "cache.defines"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import Vector :: * ;
  import cache_types :: * ;
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

    interface Put#(ITLB_core_request#(`vaddr)) core_request;
    interface Get#(ITLB_core_response#(`paddr)) core_response;

    interface Get#(PTWalk_tlb_request#(`vaddr)) request_to_ptw;
    interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) response_frm_ptw;

    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(`vaddr) s);

    /*doc:method: method to recieve the current privilege mode of operation*/
    method Action ma_curr_priv (Bit#(2) c);

  `ifdef pmp
    /*doc:method: */
    method Action ma_pmp_cfg ( Vector#(`PMPSIZE, Bit#(8)) pmpcfg) ;
    /*doc:method: */
    method Action ma_pmp_addr ( Vector#(`PMPSIZE, Bit#(`paddr)) pmpaddr);
  `endif
  `ifdef perfmonitors
    method Bit#(1) mv_perf_counters;
  `endif
  endinterface

  /*doc:module: */
  (*synthesize*)
  module mkfa_itlb#(parameter Bit#(`vaddr) hartid) (Ifc_fa_itlb);

    Vector#( `itlbsize, Reg#(VPNTag) ) v_vpn_tag <- replicateM(mkReg(unpack(0))) ;

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

  `ifdef pmp
    Vector#(`PMPSIZE, Wire#(Bit#(8))) wr_pmp_cfg <- replicateM(mkWire());
    Vector#(`PMPSIZE, Wire#(Bit#(`paddr))) wr_pmp_addr <- replicateM(mkWire());
  `endif
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

    interface core_request = interface Put
      method Action put (ITLB_core_request#(`vaddr) req) if(!rg_sfence && !rg_tlb_miss);

        `logLevel( tlb, 0, $format("core id:%2d ", hartid,"ITLB: received req: ",fshow(req)))

        Bit#(12) page_offset = req.address[11 : 0];
        Bit#(`vpnsize) fullvpn = truncate(req.address >> 12);

        /*doc:func: */
        function Bool fn_vtag_match (VPNTag t);
          return t.permissions.v && (({'1,t.pagemask} & fullvpn) == t.vpn)
                                 && (t.asid == satp_asid || t.permissions.g);
        endfunction

        Bit#(TLog#(`itlbsize)) tagmatch = 0;
        if(req.sfence)begin
          `logLevel( itlb, 0, $format("ITLB: SFence received"))
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
            `logLevel( itlb, 0, $format("ITLB : Transparent Translation. PhyAddr: %h",coreresp))
          end
          else if (hit_entry matches tagged Valid .pte) begin
            `logLevel( itlb, 0, $format("ITLB: Hit in TLB:",fshow(pte)))
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

            `logLevel( itlb, 0, $format("mask:%h",mask))
            `logLevel( itlb, 0, $format("lower_ppn:%h",lower_ppn))
            `logLevel( itlb, 0, $format("lower_vpn:%h",lower_vpn))
            `logLevel( itlb, 0, $format("lower_pa:%h",lower_pa))
            `logLevel( itlb, 0, $format("highest_ppn:%h",highest_ppn))

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
            `logLevel( itlb, 0, $format("ITLB: Sending PA:%h Trap:%b", physicaladdress, page_fault))
            ff_core_respone.enq(ITLB_core_response{address  : truncate(physicaladdress),
                                                   trap     : page_fault,
                                                   cause    : `Inst_pagefault });
          end
          else begin
            // Send virtual - address and indicate it is an instruction access to the PTW
            `logLevel( itlb, 0, $format("ITLB : TLBMiss. Sending Address to PTW:%h",req.address))
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

    interface response_frm_ptw = interface Put
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
          `logLevel( itlb, 0, $format("ITLB: Allocating index:%d for Tag:", rg_replace, fshow(tag)))
          v_vpn_tag[rg_replace] <= tag;
          rg_replace <= rg_replace + 1;
        end

        rg_tlb_miss <= False;
      endmethod
    endinterface;

    interface core_response = toGet(ff_core_respone);

    interface request_to_ptw = toGet(ff_request_to_ptw);

    method Action ma_satp_from_csr (Bit#(`vaddr) s);
      wr_satp <= s;
    endmethod

    method Action ma_curr_priv (Bit#(2) c);
        wr_priv <= c;
    endmethod

  `ifdef pmp
    method Action ma_pmp_cfg (Vector#(`PMPSIZE, Bit#(8)) pmpcfg);
      for(Integer i = 0;i<valueOf(`PMPSIZE) ;i = i+1)
        wr_pmp_cfg[i] <= pmpcfg[i];
    endmethod
    method Action ma_pmp_addr(Vector#(`PMPSIZE, Bit#(`paddr)) pmpadr);
      for(Integer i = 0;i<valueOf(`PMPSIZE) ;i = i+1)
        wr_pmp_addr[i] <= pmpadr[i];
    endmethod
  `endif
  `ifdef perfmonitors
    method mv_perf_counters = wr_count_misses;
  `endif
  endmodule

endpackage

