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
package imem;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import GetPut::*;
  import Connectable::*;

  import icache_types::*;
//  import globals::*;
  import io_func::*;
  `include "icache.defines"
`ifdef icache
  import icache :: *;
`else
  import null_icache :: *;
`endif
`ifdef supervisor
  import fa_itlb :: * ;
  import common_tlb_types :: * ;
`endif

  (*synthesize*)
  module mkicache_inst(Ifc_icache#(`iwords, `iblocks, `isets, `iways, `paddr, `vaddr,
                                                      `ifbsize, `iesize ,
                              `ifdef ECC `vaddr, 1, `endif `idbanks, `itbanks, `ibuswidth ));
    let ifc();
  `ifdef icache
    mkicache#(isIO,"RROBIN",0) _temp(ifc);
  `else
    mknull_icache _temp(ifc);
  `endif
    return (ifc);
  endmodule
  interface Ifc_imem;
      // -------------------- Cache related interfaces ------------//
    interface Put#(IMem_core_request#(`vaddr, `iesize )) core_req;
    interface Get#(IMem_core_response#(TMul#(`iwords, 8), `iesize )) core_resp;
    method Action cache_enable(Bool c);
    interface Get#(ICache_mem_readreq#(`paddr)) read_mem_req;
    interface Put#(ICache_mem_readresp#(`ibuswidth)) read_mem_resp;
    method Bool cache_available;
      // ---------------------------------------------------------//
      // - ---------------- TLB interfaces ---------------------- //
  `ifdef supervisor
    interface Get#(PTWalk_tlb_request#(`vaddr)) req_to_ptw;
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
  `endif

`ifdef perfmonitors
  `ifdef icache
    method Bit#(3) mv_icache_perf_counters;
  `endif
  `ifdef supervisor
    method Bit#(1) mv_itlb_perf_counters ;
  `endif
`endif
      // ---------------------------------------------------------//
  endinterface

  function ICache_core_request#(`vaddr, `iesize ) get_cache_packet
                                    (IMem_core_request#(`vaddr, `iesize) req);
          return ICache_core_request{ address   : req.address,
                                      fence     : req.fence,
                                    epochs    : req.epochs};
  endfunction
`ifdef supervisor
  function ITLB_core_request#(`vaddr) get_tlb_packet
                                    (IMem_core_request#(`vaddr, `iesize) req);
          return ITLB_core_request{   address   : req.address,
                                      sfence    : req.sfence
                                      };
  endfunction
`endif

  (*synthesize*)
  module mkimem(Ifc_imem);
    let icache <- mkicache_inst;
  `ifdef supervisor
    Ifc_fa_itlb itlb <- mkfa_itlb(0);
    mkConnection(itlb.core_response, icache.mav_pa_from_tlb);
  `endif
    interface core_req = interface Put
      method Action put (IMem_core_request#(`vaddr, `iesize ) r);
      `ifdef supervisor
        if(!r.sfence)
            icache.core_req.put(get_cache_packet(r));
        if(!r.fence)
            itlb.core_request.put(get_tlb_packet(r));
      `else
        icache.core_req.put(get_cache_packet(r));
      `endif
      endmethod
    endinterface;
    interface core_resp = icache.core_resp;
    interface read_mem_req = icache.read_mem_req;
    interface read_mem_resp = icache.read_mem_resp;
    method Action cache_enable (Bool c);
      icache.ma_cache_enable(c);
    endmethod
      method cache_available = icache.mv_cache_available;
`ifdef supervisor
    interface req_to_ptw = itlb.request_to_ptw;
    method ma_satp_from_csr = itlb.ma_satp_from_csr;
    method ma_curr_priv = itlb.ma_curr_priv;
    `ifdef pmp
      method ma_pmp_cfg = itlb.ma_pmp_cfg;
      method ma_pmp_addr = itlb.ma_pmp_addr;
    `endif
`endif
`ifdef perfmonitors
  `ifdef icache
    method mv_icache_perf_counters = icache.perf_counters;
  `endif
  `ifdef supervisor
    method mv_itlb_perf_counters = itlb.mv_perf_counters;
  `endif
`endif
  endmodule
endpackage

