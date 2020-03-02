/*
Copyright (c) 2018, IIT Madras All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions
  and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice, this list of
  conditions and the following disclaimer in the documentation and / or other materials provided
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

Author : Neel Gala
Email id : neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package dmem;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import GetPut::*;
  import Connectable::*;

  import cache_types::*;
  import globals::*;
  import io_func::*;
  `include "cache.defines"
  `ifdef coherency
    import coherence_types :: *;
    `include "coherence.defines"
  `endif
`ifdef dcache
  import dcache :: *;
`else
  import null_dcache :: *;
`endif
`ifdef supervisor
  import fa_dtlb :: * ;
  import common_tlb_types :: * ;
`endif

  (*synthesize*)
  module mkdcache_inst#(parameter Bit#(32) id) (Ifc_dcache#(`dwords, `dblocks, `dsets, `dways, `paddr, `vaddr,
                                                      `dsbsize, `dfbsize, `desize ,
                              `ifdef ECC `vaddr, 1, `endif `ddbanks, `dtbanks, `dbuswidth ));
    let ifc();
  `ifdef dcache
    mkdcache#(isIO,"RROBIN",id) _temp(ifc);
  `else
    mknull_dcache _temp(ifc);
  `endif
    return (ifc);
  endmodule
  interface Ifc_dmem;
      // -------------------- Cache related interfaces ------------//
    interface Put#(DMem_request#(`vaddr, TMul#( `dwords, 8),`desize )) core_req;
    interface Get#(DMem_core_response#(TMul#(`dwords, 8), `desize )) core_resp;
    method Bool storebuffer_empty;
    method Action perform_store(Bit#(`desize ) currepoch);
  `ifdef coherency
    interface Get#(Message#(`paddr,TMul#(`dwords,`dblocks))) mv_request_to_fabric;
    interface Get#(NCAccess#(`paddr, TMul#(`dwords,8))) mv_io_request_to_fabric;
    interface Get#(Message#(`paddr,TMul#(`dwords,`dblocks))) mv_response_to_fabric;
    interface Get#(Message#(`paddr,TMul#(`dwords,`dblocks))) mv_response2_to_fabric;
    interface Put#(Message#(`paddr,TMul#(`dwords,`dblocks))) mv_response_from_fabric;
  `else
    `ifdef dcache
      method DCache_mem_writereq#(`paddr, TMul#(`dblocks, TMul#(`dwords, 8))) write_mem_req_rd;
      interface Put#(DCache_mem_writeresp) write_mem_resp;
    `else
      method DCache_mem_writereq#(`paddr, TMul#(`dwords, 8)) write_mem_req_rd;
    `endif
      method Action write_mem_req_deq;
    interface Get#(DCache_mem_readreq#(`paddr)) read_mem_req;
    interface Put#(DCache_mem_readresp#(`dbuswidth)) read_mem_resp;
  `endif
    method Action cache_enable(Bool c);
    method Bool cacheable_store;
    method Bool cache_available;
    method Bool mv_commit_store_ready;
      // ---------------------------------------------------------//
      // - ---------------- TLB interfaces ---------------------- //
  `ifdef supervisor
    interface Get#(DMem_core_response#(TMul#(`dwords, 8), `desize)) ptw_resp;
    interface Get#(PTWalk_tlb_request#(`vaddr)) req_to_ptw;
    interface Put#(PTWalk_tlb_response#(`ifdef RV64 54, 3 `else 32, 2 `endif )) resp_from_ptw;
    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(`vaddr) s);

    /*doc:method: method to recieve the current privilege mode of operation*/
    method Action ma_curr_priv (Bit#(2) c);

    /*doc:method: method to receive the current values of the mstatus register*/
    method Action ma_mstatus_from_csr (Bit#(`vaddr) m);
    `ifdef pmp
      /*doc:method: */
      method Action ma_pmp_cfg ( Vector#(`PMPSIZE, Bit#(8)) pmpcfg) ;
      /*doc:method: */
      method Action ma_pmp_addr ( Vector#(`PMPSIZE, Bit#(`paddr)) pmpaddr);
    `endif
    interface Get#(DCache_core_request#(`vaddr, TMul#(`dwords, 8), `desize)) hold_req;
  `endif

`ifdef perfmonitors
  `ifdef dcache
    method Bit#(9) mv_dcache_perf_counters;
  `endif
  `ifdef supervisor
    method Bit#(1) mv_dtlb_perf_counters ;
  `endif
`endif
      // ---------------------------------------------------------//
  endinterface

  function DCache_core_request#(`vaddr, TMul#(`dwords,8), `desize ) get_cache_packet
                                    (DMem_request#(`vaddr, TMul#(`dwords, 8), `desize) req);
          return DCache_core_request{ address   : req.address,
                                      fence     : req.fence,
                                      epochs    : req.epochs,
                                      access    : req.access,
                                      size      : req.size,
                                      data      : req.writedata
                                    `ifdef atomic
                                      ,atomic_op : req.atomic_op
                                    `endif
                                    `ifdef supervisor
                                      ,ptwalk_req: req.ptwalk_req
                                    `endif };
  endfunction
`ifdef supervisor
  function DTLB_core_request#(`vaddr) get_tlb_packet
                                    (DMem_request#(`vaddr, TMul#(`dwords, 8), `desize) req);
          return DTLB_core_request{   address   : req.address,
                                      access    : req.access,
                                      cause     : truncate(req.writedata),
                                      ptwalk_trap: req.ptwalk_trap,
                                      ptwalk_req: req.ptwalk_req,
                                      sfence    : req.sfence
                                      };
  endfunction
`endif

  (*synthesize*)
  module mkdmem#(parameter Bit#(32) id)(Ifc_dmem);
    let dcache <- mkdcache_inst(id);
  `ifdef supervisor
    Ifc_fa_dtlb dtlb <- mkfa_dtlb(id);
    mkConnection(dtlb.core_response, dcache.mav_pa_from_tlb);
  `endif
    interface core_req = interface Put
      method Action put (DMem_request#(`vaddr, TMul#( `dwords, 8),`desize ) r);
      `ifdef supervisor
        if(r.ptwalk_req || !r.sfence)
            dcache.core_req.put(get_cache_packet(r));
        if(!r.fence)
            dtlb.core_request.put(get_tlb_packet(r));
      `else
        dcache.core_req.put(get_cache_packet(r));
      `endif
      endmethod
    endinterface;
    interface core_resp = dcache.core_resp;
  `ifdef coherency
    interface mv_request_to_fabric = dcache.mv_request_to_fabric;
    interface mv_io_request_to_fabric = dcache.mv_io_request_to_fabric;
    interface mv_response_to_fabric = dcache.mv_response_to_fabric;
    interface mv_response2_to_fabric = dcache.mv_response2_to_fabric;
    interface mv_response_from_fabric = dcache.mv_response_from_fabric;
  `else
    interface read_mem_req = dcache.read_mem_req;
    interface read_mem_resp = dcache.read_mem_resp;
    method write_mem_req_rd = dcache.write_mem_req;
    method write_mem_req_deq = dcache.write_mem_req_deq;
    `ifdef dcache
      interface write_mem_resp = dcache.write_mem_resp;
    `endif
  `endif
    method Action cache_enable (Bool c);
      dcache.ma_cache_enable(c);
    endmethod
    method Action perform_store(Bit#(`desize ) currepoch);
      dcache.ma_perform_store(currepoch);
    endmethod
    method cacheable_store    =dcache.mv_cacheable_store;
    method cache_available    =dcache.mv_cache_available `ifdef supervisor && dtlb.mv_tlb_available `endif ;
    method mv_commit_store_ready = dcache.mv_commit_store_ready;
    method storebuffer_empty  =dcache.mv_storebuffer_empty;
`ifdef supervisor
    interface ptw_resp = dcache.ptw_resp;
    interface req_to_ptw = dtlb.request_to_ptw;
    interface resp_from_ptw = dtlb.response_frm_ptw;
    method ma_satp_from_csr = dtlb.ma_satp_from_csr;
    method ma_curr_priv = dtlb.ma_curr_priv;
    method ma_mstatus_from_csr = dtlb.ma_mstatus_from_csr;
    `ifdef pmp
      method ma_pmp_cfg = dtlb.ma_pmp_cfg;
      method ma_pmp_addr = dtlb.ma_pmp_addr;
    `endif
    interface hold_req = dcache.hold_req;
`endif
`ifdef perfmonitors
  `ifdef dcache
    method mv_dcache_perf_counters = dcache.perf_counters;
  `endif
  `ifdef supervisor
    method mv_dtlb_perf_counters = dtlb.mv_perf_counters;
  `endif
`endif
  endmodule
endpackage

