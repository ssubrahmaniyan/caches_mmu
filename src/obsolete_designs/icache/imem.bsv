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

  import globals::*;
  import cache_types::*;
  import io_func::*;
  `include "cache.defines"
  `ifdef supervisor
    import fa_itlb :: * ;
  `endif
  `ifdef icache
    `ifdef supervisor
      import l1icache_vipt :: *;
    `else
      import l1icache :: *;
    `endif
  `else
    import null_icache :: *;
  `endif

  (*synthesize*)
  module mkicache(Ifc_l1icache#(`iwords, `iblocks, `isets, `iways, `paddr, `vaddr, 
                                         `ifbsize, `iesize, 
                                     `ifdef ECC 32, 1, `endif 
                                     `ifdef itim `itim_banks, `endif
                                        `idbanks, `itbanks, `ibuswidth));
    let ifc();
  `ifdef icache
    mkl1icache#(isIO,"RROBIN") _temp(ifc);
  `else
    mknull_cache _temp(ifc);
  `endif
    return (ifc);
  endmodule

`ifdef supervisor
  (*synthesize*)
    module mkitlb(Ifc_fa_itlb);
      let ifc();
      mkfa_itlb#(0) _temp(ifc);
      return (ifc);
    endmodule
`endif
  interface Ifc_imem;
      // -------------------- Cache related interfaces - -----------//
    interface Put#(ICache_request#(`vaddr ,`iesize)) core_req;
    interface Get#(FetchResponse#(TMul#(`iwords, 8),`iesize)) core_resp;
    method Action cache_enable(Bool c);
    interface Get#(ICache_mem_request#(`paddr)) read_mem_req;
    interface Put#(ICache_mem_response#(`ibuswidth)) read_mem_resp; 
  `ifdef icache
    interface Get#(ICache_mem_request#(`paddr)) nc_read_req;
    interface Put#(ICache_mem_response#(TMul#(`iwords, 8))) nc_read_resp;
  `endif
      // ---------------------------------------------------------//
      // - ---------------- TLB interfaces - --------------------- //
  `ifdef supervisor
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
  `endif
`ifdef perfmonitors
  `ifdef icache
    method Bit#(5) mv_icache_perf_counters;
  `endif
  `ifdef supervisor
    method Bit#(1) mv_itlb_perf_counters;
  `endif
`endif
  `ifdef itim
    interface Put#(ITIM_mem_req#(`paddr,TMul#(`iwords,8))) mem_itim_req;
    interface Get#(ITIM_mem_resp#(TMul#(`iwords,8))) mem_read_itim_resp;
    interface Get#(Bool) mem_write_itim_resp;
    /*doc:method: */
    method Action ma_itim_memory_map (Bit#(`paddr) base, Bit#(`paddr) bound);
  `endif
      // ---------------------------------------------------------//
  endinterface

  (*synthesize*)
  module mkimem(Ifc_imem);
    let icache <- mkicache;
  `ifdef supervisor
    let itlb <- mkitlb;
    mkConnection(itlb.core_response, icache.pa_from_tlb);
  `endif
    interface core_req = interface Put
      method Action put (ICache_request#(`vaddr ,`iesize) req);
      `ifdef supervisor
        if(!req.sfence)
      `endif
          icache.core_req.put(req);

      `ifdef supervisor
        `ifdef ifence
          if(!req.fence)
        `endif
          itlb.core_request.put(ITLB_core_request{address : req.address, sfence : req.sfence});
      `endif
      endmethod
    endinterface;
    interface core_resp = icache.core_resp;
    interface read_mem_req = icache.read_mem_req;
    interface read_mem_resp = icache.read_mem_resp;
    method Action cache_enable (Bool c);
      icache.cache_enable(c);
    endmethod
  `ifdef icache
    interface nc_read_req = icache.nc_read_req;
    interface nc_read_resp = icache.nc_read_resp;
  `endif
  `ifdef supervisor
    interface request_to_ptw = itlb.request_to_ptw;
    interface response_frm_ptw = itlb.response_frm_ptw;
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
  `ifdef itim
    interface mem_itim_req = icache.mem_itim_req;
    interface mem_read_itim_resp = icache.mem_read_itim_resp;
    interface mem_write_itim_resp = icache.mem_write_itim_resp;
    /*doc:method: */
    method ma_itim_memory_map = icache.ma_itim_memory_map;
  `endif
  endmodule
endpackage

