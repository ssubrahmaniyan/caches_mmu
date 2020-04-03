/*
see LICENSE.incore
see LICENSE.iitm

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

  import dcache_types::*;
  import io_func::*;
  `include "dcache.defines"
`ifdef dcache
  `ifdef dcache_dualport
    import dcache2rw :: *;
  `else
    import dcache1rw :: *;
  `endif
`else
  import null_dcache :: *;
`endif
`ifdef supervisor
  import fa_dtlb :: * ;
  import common_tlb_types :: * ;
`endif

  interface Ifc_dmem;
      // -------------------- Cache related interfaces ------------//
    interface Put#(DMem_request#(`vaddr, TMul#( `dwords, 8),`desize )) put_core_req;
    interface Get#(DMem_core_response#(TMul#(`dwords, 8), `desize )) get_core_resp;
    method Bool mv_storebuffer_empty;
    method Action ma_perform_store(Bit#(`desize ) currepoch);
  `ifdef dcache
    method DCache_mem_writereq#(`paddr, TMul#(`dblocks, TMul#(`dwords, 8))) mv_write_mem_req_rd;
    interface Put#(DCache_mem_writeresp) put_write_mem_resp;
  `else
    method DCache_mem_writereq#(`paddr, TMul#(`dwords, 8)) mv_write_mem_req_rd;
  `endif
    method Action ma_write_mem_req_deq;
    method Action ma_cache_enable(Bool c);
    interface Get#(DCache_mem_readreq#(`paddr)) get_read_mem_req;
    interface Put#(DCache_mem_readresp#(`dbuswidth)) put_read_mem_resp;
    method Bool mv_cacheable_store;
    method Bool mv_cache_available;
    method Bool mv_commit_store_ready;
    (*always_ready, always_enabled*)
    /*doc:method: method to recieve the current privilege mode of operation*/
    method Action ma_curr_priv (Bit#(2) c);
      // ---------------------------------------------------------//
      // - ---------------- TLB interfaces ---------------------- //
  `ifdef supervisor
    interface Get#(DMem_core_response#(TMul#(`dwords, 8), `desize)) get_ptw_resp;
    interface Get#(PTWalk_tlb_request#(`vaddr)) get_req_to_ptw;
    interface Put#(PTWalk_tlb_response#(`ifdef RV64 54, 3 `else 32, 2 `endif )) put_resp_from_ptw;
    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(`vaddr) s);

    /*doc:method: method to receive the current values of the mstatus register*/
    method Action ma_mstatus_from_csr (Bit#(`vaddr) m);
    interface Get#(DCache_core_request#(`vaddr, TMul#(`dwords, 8), `desize)) get_hold_req;
  `endif
`ifdef perfmonitors
  `ifdef dcache
    method Bit#(13) mv_dcache_perf_counters;
  `endif
  `ifdef supervisor
    method Bit#(1) mv_dtlb_perf_counters ;
  `endif
`endif
  `ifdef dcache_ecc
    method Maybe#(ECC_dcache_data#(`paddr, `dways, `dblocks)) mv_ded_data;
    method Maybe#(ECC_dcache_data#(`paddr, `dways, `dblocks)) mv_sed_data;
    method Maybe#(ECC_dcache_tag#(`paddr, `dways)) mv_ded_tag;
    method Maybe#(ECC_dcache_tag#(`paddr, `dways)) mv_sed_tag;
    method Action ma_ram_request(DRamAccess access);
    method Bit#(`respwidth) mv_ram_response;
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
  module mkdmem#(parameter Bit#(32) id
    `ifdef pmp ,
        Vector#(`pmpsize, Bit#(8)) pmp_cfg, 
        Vector#(`pmpsize, Bit#(TSub#(`paddr,`pmp_grainbits))) pmp_addr `endif
    )(Ifc_dmem);

    let dcache <- mkdcache(id `ifdef pmp ,pmp_cfg, pmp_addr `endif );
  `ifdef supervisor
    Ifc_fa_dtlb dtlb <- mkfa_dtlb(id);
    mkConnection(dtlb.get_core_response, dcache.put_pa_from_tlb);
  `endif
    interface put_core_req = interface Put
      method Action put (DMem_request#(`vaddr, TMul#( `dwords, 8),`desize ) r);
      `ifdef supervisor
        if(r.ptwalk_req || !r.sfence)
            dcache.put_core_req.put(get_cache_packet(r));
        if(!r.fence)
            dtlb.put_core_request.put(get_tlb_packet(r));
      `else
        dcache.put_core_req.put(get_cache_packet(r));
      `endif
      endmethod
    endinterface;
    interface get_core_resp = dcache.get_core_resp;
    interface get_read_mem_req = dcache.get_read_mem_req;
    interface put_read_mem_resp = dcache.put_read_mem_resp;
    method ma_cache_enable =  dcache.ma_cache_enable;
    method mv_write_mem_req_rd = dcache.mv_write_mem_req;
`ifdef dcache
    interface put_write_mem_resp = dcache.put_write_mem_resp;
`endif
    method ma_write_mem_req_deq = dcache.ma_write_mem_req_deq;
    method ma_perform_store = dcache.ma_perform_store;
    method mv_cacheable_store    =dcache.mv_cacheable_store;
    method mv_cache_available    =dcache.mv_cache_available `ifdef supervisor && dtlb.mv_tlb_available `endif ;
    method mv_commit_store_ready = `ifdef dcache dcache.mv_commit_store_ready `else True `endif ;
    method mv_storebuffer_empty  =dcache.mv_storebuffer_empty;
    method Action ma_curr_priv (Bit#(2) c);
    `ifdef supervisor
      dtlb.ma_curr_priv(c);
    `endif
      dcache.ma_curr_priv(c);
    endmethod
  `ifdef supervisor
    interface get_ptw_resp = dcache.get_ptw_resp;
    interface get_req_to_ptw = dtlb.get_request_to_ptw;
    interface put_resp_from_ptw = dtlb.put_response_frm_ptw;
    method ma_satp_from_csr = dtlb.ma_satp_from_csr;
    method ma_mstatus_from_csr = dtlb.ma_mstatus_from_csr;
    interface get_hold_req = dcache.get_hold_req;
  `endif
`ifdef perfmonitors
  `ifdef dcache
    method mv_dcache_perf_counters = dcache.mv_perf_counters;
  `endif
  `ifdef supervisor
    method mv_dtlb_perf_counters = dtlb.mv_perf_counters;
  `endif
`endif
  `ifdef dcache_ecc
    method mv_ded_data = dcache.mv_ded_data;
    method mv_sed_data = dcache.mv_sed_data;
    method mv_ded_tag = dcache.mv_ded_tag;
    method mv_sed_tag = dcache.mv_sed_tag;
    method ma_ram_request = dcache.ma_ram_request;
    method mv_ram_response = dcache.mv_ram_response;
`endif
  endmodule
endpackage

