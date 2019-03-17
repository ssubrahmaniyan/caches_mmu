/* 
Copyright (c) 2018, IIT Madras All rights reserved.

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
package imem;
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
  `include "cache.defines"
  `ifdef supervisor
    import l1icache_vipt::*;
    `ifdef RV64
      import itlb_rv64_array::*;
    `elsif RV32
      import itlb_rv32_array::*;
    `endif
  `else
    import l1icache::*;
  `endif

    function Bool isIO(Bit#(`paddr) addr, Bool cacheable);
	    if(!cacheable)
	  	  return True;
      else if(addr<'h80000000)
        return True;
	    else
	  	  return False;
    endfunction

  (*synthesize*)
  module mkicache(Ifc_l1icache#(`iwords, `iblocks, `isets, `iways, `paddr, `vaddr, 
                                         `ifbsize, `iesize, `idbanks, `itbanks, `ibuswidth));
    let ifc();
    mkl1icache#(isIO,"RROBIN") _temp(ifc);
    return (ifc);
  endmodule

`ifdef supervisor
  (*synthesize*)
`ifdef RV64
  module mkitlb(Ifc_itlb_rv64_array#(`paddr,8,8,8,1,1,1,`asidwidth));
    let ifc();
    mkitlb_rv64_array#("RANDOM", "RANDOM") _temp(ifc);
    return (ifc);
  endmodule
`else
  module mkitlb(Ifc_itlb_rv32_array#(`paddr,8,8,1,1,`asidwidth));
    let ifc();
    mkitlb_rv32_array#("RANDOM", "RANDOM") _temp(ifc);
    return (ifc);
  endmodule
`endif
`endif
  interface Ifc_imem;
      // -------------------- Cache related interfaces ------------//
    interface Put#(ICache_request#(`vaddr ,`iesize)) core_req;
    interface Get#(FetchResponse#(TMul#(`iwords,8),`iesize)) core_resp;
    interface Get#(ICache_mem_request#(`paddr)) read_mem_req;
    interface Put#(ICache_mem_response#(`ibuswidth)) read_mem_resp; 
    interface Get#(ICache_mem_request#(`paddr)) nc_read_req;
    interface Put#(ICache_mem_response#(TMul#(`iwords, 8))) nc_read_resp;
    method Action cache_enable(Bool c);
      // ---------------------------------------------------------//
      // - ---------------- TLB interfaces ---------------------- //
  `ifdef supervisor
    interface Get#(PTWalk_tlb_request#(64)) req_to_ptw;
    interface Put#(PTWalk_tlb_response#(`ifdef RV64 54, 3 `else 32, 2 `endif )) resp_from_ptw;
    interface Put#(Bit#(`vaddr )) satp_from_csr;
    interface Put#(Bit#(2)) curr_priv;
  `ifdef pmp
    method Action pmp_cfg (Vector#(`PMPSIZE, Bit#(8)) pmpcfg);
    method Action pmp_addr(Vector#(`PMPSIZE, Bit#(`paddr )) pmpadr);
  `endif
  `endif
      // ---------------------------------------------------------//
  endinterface

  (*synthesize*)
  module mkimem(Ifc_imem);
    let icache<-mkicache;
  `ifdef supervisor
    let itlb <- mkitlb;
    mkConnection(itlb.core_resp,icache.pa_from_tlb);
  `endif
    interface core_req = interface Put
      method Action put (ICache_request#(`vaddr ,`iesize) req);
      `ifdef supervisor
        if(!req.sfence)
      `endif
          icache.core_req.put(req);

      `ifdef supervisor
        if(!req.fence)
          itlb.core_req.put(ITLB_core_request{address:req.address, sfence:req.sfence});
      `endif
      endmethod
    endinterface;
    interface core_resp = icache.core_resp;
    interface read_mem_req= icache.read_mem_req;
    interface read_mem_resp = icache.read_mem_resp;
    interface nc_read_req = icache.nc_read_req;
    interface nc_read_resp = icache.nc_read_resp;
    method Action cache_enable (Bool c);
      icache.cache_enable(c);
    endmethod
`ifdef supervisor
    interface req_to_ptw = itlb.req_to_ptw;
    interface resp_from_ptw = itlb.resp_from_ptw;
    interface satp_from_csr = itlb.satp_from_csr;
    interface curr_priv = itlb.curr_priv;
  `ifdef pmp
    method Action pmp_cfg (Vector#(`PMPSIZE, Bit#(8)) pmpcfg);
      itlb.pmp_cfg(pmpcfg);
    endmethod
    method Action pmp_addr(Vector#(`PMPSIZE, Bit#( `paddr )) pmpadr);
      itlb.pmp_addr(pmpadr);
    endmethod
  `endif
`endif
  endmodule
endpackage

