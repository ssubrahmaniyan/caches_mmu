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
  `include "cache.defines"
`ifdef supervisor
  import l1dcache_vipt::*;
  `ifdef RV64
    import dtlb_rv64_array::*;
  `elsif RV32
    import dtlb_rv32_array::*;
  `endif
`else
  import l1dcache::*;
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
  module mkdcache(Ifc_l1dcache#(`dwords, `dblocks, `dsets, `dways, `paddr, `vaddr,`dfbsize, 
                                                      `dsbsize, `desize, `ddbanks, `dtbanks ));
    let ifc();
    mkl1dcache#(isIO,"RROBIN") _temp(ifc);
    return (ifc);
  endmodule

`ifdef supervisor
  (*synthesize*)
  (*conflict_free="resp_from_ptw_put, core_req_put"*)
`ifdef RV64
  module mkdtlb(Ifc_dtlb_rv64_array#(`paddr, 8,8, 8,1, 1,1,`asidwidth));
    let ifc();
    mkdtlb_rv64_array#("RANDOM", "RANDOM") _temp(ifc);
    return (ifc);
  endmodule
`else
  module mkdtlb(Ifc_dtlb_rv32_array#(`paddr, 8,8, 1,1,`asidwidth));
    let ifc();
    mkdtlb_rv32_array#("RANDOM", "RANDOM") _temp(ifc);
    return (ifc);
  endmodule
`endif
`endif
  interface Ifc_dmem;
      // -------------------- Cache related interfaces ------------//
    interface Put#(DMem_request#(`vaddr, TMul#( `dwords, 8),`desize )) core_req;
    interface Get#(DMem_core_response#(TMul#(`dwords, 8), `desize )) core_resp;
    interface Get#(DMem_core_response#(TMul#(`dwords, 8), `desize)) ptw_resp;
    interface Get#(DCache_mem_readreq#(`paddr)) read_mem_req;
    interface Put#(DCache_mem_readresp#(TMul#(`dwords, 8))) read_mem_resp;
    interface Get#(DCache_mem_readreq#(`paddr)) nc_read_req;
    interface Put#(DCache_mem_readresp#(TMul#(`dwords, 8))) nc_read_resp;
    method Action cache_enable(Bool c);
    method DCache_mem_writereq#(`paddr, TMul#(`dblocks, TMul#(`dwords, 8))) write_mem_req_rd;
    method Action write_mem_req_deq;
    interface Put#(DCache_mem_writeresp) write_mem_resp;
    interface Get#(DCache_mem_writereq#(`paddr, TMul#( `dwords, 8))) nc_write_req;
    method Action perform_store(Bit#(`desize ) currepoch);
    method Bool cacheable_store;
    method Bool cache_available;
    method Bool storebuffer_empty;
    interface Get#(DCache_core_request#(`vaddr, TMul#(`dwords, 8), `desize)) hold_req;
      // ---------------------------------------------------------//
      // - ---------------- TLB interfaces ---------------------- //
  `ifdef supervisor
    interface Get#(PTWalk_tlb_request#(`vaddr)) req_to_ptw;
    interface Put#(PTWalk_tlb_response#(`ifdef RV64 54, 3 `else 32, 2 `endif )) resp_from_ptw;
    interface Put#(Bit#(`vaddr )) satp_from_csr;
    interface Put#(Bit#(2)) curr_priv;
    interface Put#(Bit#(`vaddr )) mstatus_from_csr;
  `ifdef pmp
    method Action pmp_cfg (Vector#(`PMPSIZE, Bit#(8)) pmpcfg);
    method Action pmp_addr(Vector#(`PMPSIZE, Bit#(`paddr )) pmpadr);
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
  
  function DTLB_core_request#(`vaddr) get_tlb_packet
                                    (DMem_request#(`vaddr, TMul#(`dwords, 8), `desize) req);
          return DTLB_core_request{   address   : req.address,
                                      access    : req.access,
                                      cause     : truncate(req.writedata),
                                      ptwalk_req: req.ptwalk_req,
                                      ptwalk_trap: req.ptwalk_trap,
                                      sfence    : req.sfence
                                      };
  endfunction

  (*synthesize*)
  module mkdmem(Ifc_dmem);
    let dcache <- mkdcache;
  `ifdef supervisor
    let dtlb <- mkdtlb;
    mkConnection(dtlb.core_resp, dcache.pa_from_tlb);
  `endif
    interface core_req = interface Put
      method Action put (DMem_request#(`vaddr, TMul#( `dwords, 8),`desize ) r);
      `ifdef supervisor
        if(r.ptwalk_req || !r.sfence)
            dcache.core_req.put(get_cache_packet(r));
        if(!r.fence)
            dtlb.core_req.put(get_tlb_packet(r));
      `else
        dcache.core_req.put(get_cache_packet(r));
      `endif
      endmethod
    endinterface;
    interface core_resp = dcache.core_resp;
    interface ptw_resp = dcache.ptw_resp;
    interface read_mem_req = dcache.read_mem_req;
    interface read_mem_resp = dcache.read_mem_resp;
    interface nc_read_req = dcache.nc_read_req;
    interface nc_read_resp = dcache.nc_read_resp;
    method Action cache_enable (Bool c);
      dcache.cache_enable(c);
    endmethod
    method write_mem_req_rd = dcache.write_mem_req_rd;
    method write_mem_req_deq = dcache.write_mem_req_deq;
    interface write_mem_resp = dcache.write_mem_resp;
    interface nc_write_req = dcache.nc_write_req;
    method Action perform_store(Bit#(`desize ) currepoch);
      dcache.perform_store(currepoch);
    endmethod
    method cacheable_store    =dcache.cacheable_store;
      method cache_available    =dcache.cache_available `ifdef supervisor && dtlb.tlb_available `endif ;
    method storebuffer_empty  =dcache.storebuffer_empty;
`ifdef supervisor
    interface req_to_ptw = dtlb.req_to_ptw;
    interface resp_from_ptw = dtlb.resp_from_ptw;
    interface satp_from_csr = dtlb.satp_from_csr;
    interface curr_priv = dtlb.curr_priv;
    interface mstatus_from_csr = dtlb.mstatus_from_csr;
  `ifdef pmp
    method Action pmp_cfg (Vector#(`PMPSIZE, Bit#(8)) pmpcfg);
      dtlb.pmp_cfg(pmpcfg);
    endmethod
    method Action pmp_addr(Vector#(`PMPSIZE, Bit#( `paddr )) pmpadr);
      dtlb.pmp_addr(pmpadr);
    endmethod
  `endif
`endif
    interface hold_req = dcache.hold_req;
  endmodule
endpackage

