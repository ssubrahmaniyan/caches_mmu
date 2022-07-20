/*
see LICENSE.iitm

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
  import io_func::*;
  `include "icache.defines"
`ifdef icache
  import icache :: *;
`else
  import null_icache :: *;
`endif
`ifdef hypervisor
  `include "common_tlb.defines"
  import fa_itlb_hypervisor :: * ;
  import common_tlb_types :: * ;
`elsif supervisor
  `include "common_tlb.defines"
  `ifndef iclass
    import fa_itlb :: * ;
  `else
    import itlb :: * ;
    import itlb_types :: * ;
  `endif
  import common_tlb_types :: * ;
`endif

  interface Ifc_imem;
      // -------------------- Cache related interfaces ------------//
    interface Put#(IMem_core_request#(`vaddr, `iesize )) put_core_req;
    interface Get#(IMem_core_response#(TMul#(`iwords, 8), `iesize )) get_core_resp;
    method Action ma_cache_enable(Bool c);
    interface Get#(ICache_mem_readreq#(`paddr)) get_read_mem_req;
    interface Put#(ICache_mem_readresp#(`ibuswidth)) put_read_mem_resp;
  `ifdef icache
    method Bool mv_cache_available;
  `endif
    /*doc:method: method to recieve the current privilege mode of operation*/
    method Action ma_curr_priv (Bit#(2) c);
      // ---------------------------------------------------------//
      // - ---------------- TLB interfaces ---------------------- //
  `ifdef supervisor
    interface Get#(PTWalk_tlb_request#(`vaddr)) get_request_to_ptw;
    interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) put_response_frm_ptw;
    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(`vaddr) s);
  `endif

`ifdef perfmonitors
  `ifdef icache
    method Bit#(5) mv_icache_perf_counters;
  `endif
  `ifdef supervisor
    method Bit#(1) mv_itlb_perf_counters ;
  `endif
`endif
  `ifdef icache_ecc
    method Maybe#(ECC_icache_data#(`paddr, `iways, `iblocks)) mv_ded_data;
    method Maybe#(ECC_icache_data#(`paddr, `iways, `iblocks)) mv_sed_data;
    method Maybe#(ECC_icache_tag#(`paddr, `iways)) mv_ded_tag;
    method Maybe#(ECC_icache_tag#(`paddr, `iways)) mv_sed_tag;
    method Action ma_ram_request(IRamAccess access);
    method Bit#(`respwidth) mv_ram_response;
  `endif
  `ifdef hypervisor
    method Action ma_vsatp_from_csr (Bit#(`vaddr) vsatp);	//For VS-stage translation (if v = 1)
	  method Action ma_vs_mode (Bit#(1) v);			//Virt. mode, to enable 2-stage address translation
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
                                    `ifdef hypervisor
                                      , hfence    : req.hfence
                                    `endif
                                      };
  endfunction
`endif

  (*synthesize*)
  module mkimem#(parameter Bit#(32) id
    `ifdef pmp ,
        Vector#(`pmpentries, Bit#(8)) pmp_cfg , 
        Vector#(`pmpentries, Bit#(`paddr)) pmp_addr `endif
    )(Ifc_imem);
    let icache <- mkicache(id `ifdef pmp ,pmp_cfg, pmp_addr `endif );
  `ifdef supervisor
    `ifndef iclass
      Ifc_fa_itlb itlb <- mkfa_itlb(id);
      mkConnection(itlb.get_core_response, icache.put_pa_from_tlb);
    `else
      Ifc_itlb itlb <- mkitlb(id);
    `endif
  `endif

    `ifdef iclass
      FIFOF#(ITLB_core_response#(`paddr)) ff_tlb_response <- mkSizedFIFOF(2);
      Wire#(Bit#(1)) wr_ptw_response_valid <- mkDWire(0);


      `ifdef supervisor
        rule rl_send_tlb_response;
          let lv_resp = ff_tlb_response.first;
          let lv_resp_to_cache = common_tlb_types :: ITLB_core_response {address  : lv_resp.address,
                                                                         trap     : lv_resp.trap,
                                                                         cause    : lv_resp.cause};
          icache.put_pa_from_tlb.put(lv_resp_to_cache);
          ff_tlb_response.deq;
        endrule
      `endif
    `endif // iclass

    `ifndef iclass
      interface put_core_req = interface Put
        method Action put (IMem_core_request#(`vaddr, `iesize ) r);
        `ifdef supervisor
          if(!r.sfence `ifdef hypervisor && !r.hfence `endif )
              icache.put_core_req.put(get_cache_packet(r));
          if(!r.fence)
              itlb.put_core_request.put(get_tlb_packet(r));
        `else
          icache.put_core_req.put(get_cache_packet(r));
        `endif
        endmethod
      endinterface;

    `else
      interface put_core_req = interface Put
        method Action put (IMem_core_request#(`vaddr, `iesize ) r) if (wr_ptw_response_valid == 0);
        ITLB_core_response#(`paddr) lv_response = unpack(0);

        `ifdef supervisor
          if (r.sfence)
            itlb.sfence();
          else begin
              icache.put_core_req.put(get_cache_packet(r));
            if(!r.fence) begin
              lv_response <- itlb.translate(r.address);
              if (lv_response.hit) begin
                ff_tlb_response.enq(lv_response);
              end
            end
          end
        `else
          icache.put_core_req.put(get_cache_packet(r));
        `endif
        endmethod
      endinterface;
    `endif // iclass

    interface get_core_resp = icache.get_core_resp;
    interface get_read_mem_req = icache.get_read_mem_req;
    interface put_read_mem_resp = icache.put_read_mem_resp;
    method ma_cache_enable =  icache.ma_cache_enable;

  `ifdef icache
    `ifndef iclass
      method mv_cache_available    =icache.mv_cache_available ;
    `else
      method mv_cache_available = icache.mv_cache_available && !itlb.mv_tlb_busy;
    `endif
  `endif

    method Action ma_curr_priv (Bit#(2) c);
    `ifdef supervisor
      itlb.ma_curr_priv(c);
    `endif
      icache.ma_curr_priv(c);
    endmethod

`ifdef supervisor
    interface get_request_to_ptw = itlb.get_request_to_ptw;

    `ifndef iclass
      interface put_response_frm_ptw = itlb.put_response_frm_ptw;
    `else
      interface put_response_frm_ptw = interface Put
        method Action put(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) resp);
          ITLB_core_response#(`paddr) lv_response = unpack(0);

          lv_response <- itlb.response_from_ptw(resp);
          ff_tlb_response.enq(lv_response);
          wr_ptw_response_valid <= 1;
        endmethod
      endinterface;
    `endif

    method ma_satp_from_csr = itlb.ma_satp_from_csr;
`endif
`ifdef perfmonitors
  `ifdef icache
    method mv_icache_perf_counters = icache.mv_perf_counters;
  `endif
  `ifdef supervisor
    method mv_itlb_perf_counters = itlb.mv_perf_counters;
  `endif
`endif
  `ifdef icache_ecc
    method mv_ded_data = icache.mv_ded_data;
    method mv_sed_data = icache.mv_sed_data;
    method mv_ded_tag = icache.mv_ded_tag;
    method mv_sed_tag = icache.mv_sed_tag;
    method ma_ram_request = icache.ma_ram_request;
    method mv_ram_response = icache.mv_ram_response;
  `endif
  `ifdef hypervisor
    method ma_vsatp_from_csr = itlb.ma_vsatp_from_csr;
	  method ma_vs_mode = itlb.ma_vs_mode;
  `endif
  endmodule
endpackage

