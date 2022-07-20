/* 
see LICENSE.iitm

Author: Arjun Menon, Nitya Ranganathan
Email id: c.arjunmenon@gmail.com, nitya.ranganathan@gmail.com
Details: Refer to the design document.

--------------------------------------------------------------------------------------------------
TODO
-DONE-1. Optimize the first stage buffer where you do not send the virtual page number to the next stage.
   Instead, when you get the physical page number, concat that with the offset address and send it to 
   the next stage.
2. Change appropriate interface parameters to module parameters
-DONE-3. Add flush logic
4. Add a mux for IO request? Currently the io requests are captured in ff_io_info. They can either
   be directly given through a separate master, or can be muxed with the existing master.
-DONE-5. Integrate TLB
6. Optimize the FIFOs by :
   6.1 Changing PipelineFIFOs to normals FIFOs
   6.2 Check if release of FB can be done one cycle earlier
7. Optimize the fill buffer logic by:
   7.1 Making rg_valid and rg_fill_buffer as CReg and then in the first cycle perform the MSHR requests.
   7.2 If the above results in the critical path, then perform stores in the subsequent cycle. Make sure that generate_masked_data and generate_masked_data_bus do not fall in the same cycle.
   7.3 Instead of rg_valid going from 1111 to 0000 and then to, let's say 0010, make it go from 1111 to 0010 directly.
8. Optimize fence logic once 7.3 is done by changing rg_fb_state!=Write_SRAMs.
9. Change hit_way to OInt type.
*/
package nb_dcache;
  import nb_dcache_types::*;          // for local cache types
  import common_tlb_types :: * ;
  import DefaultValue :: *;
  `include "Logger.bsv"           // for logging
  import FIFO::*;
  import FIFOF::*;
  import SEMF_FIFO::*;
  import SESFMI_FIFO::*;
  import ConfigReg::*;
  import Vector::*;
  import DReg::*;
  import DefaultValue :: *;
  import GetPut::*;
  import mem_config_nb::*;
  import SpecialFIFOs ::*;
  import BUtils::*;
  import mshr::*;
  import fill_buffer::*;
  import fa_dtlb::*;
  import replacement_dcache::*;
  import Assert  :: * ;
  import io_func::*;
  `include "parameters.bsv"
  `include "nb_dcache.defines"

  String dcache=""; // defined for Logger
   
  interface Ifc_nbdcache#(numeric type wordsize,        //size of data in bytes 
                          numeric type linesize,        //number of words in a cache line
                          numeric type setsize,         //number of sets
                          numeric type ways,            //number of ways
                          numeric type paddr,           //physical address width in bits
                          numeric type vaddr,           //virtual address width in bits
                          numeric type dsram,           //no. of bits in a row of SRAM cells for the data array
                          numeric type tsram,           //no. of bits in a row of SRAM cells for the tag array
                          numeric type prf_index,       //no. of bits to index the prf
                          numeric type id_bits,         //no. of bits of the bus transaction id
                          numeric type mshrsize,        //no. of fully associative entries in the mshr
                          numeric type mshrfifo_depth,  //depth of FIFO corresponding to each MSHR
                          numeric type buswidth,        //width of the bus in bits
                          numeric type rob_index,       //Log of number of ROB entries
                          numeric type lsq_index);      //Log of number of LSQ entries
    interface Put#(Req_from_core#(vaddr, TMul#(wordsize,8), rob_index, prf_index, lsq_index))  subifc_req_from_core;
    interface Get#(Resp_to_core#(TMul#(wordsize,8), prf_index, rob_index))                     subifc_resp_to_core;
    `ifdef store_early_ack
      interface Get#(Tuple2#(Bit#(1), Resp_to_core#(TMul#(wordsize,8), prf_index, rob_index)))  subifc_early_resp_to_core;
    `endif
    interface Get#(Req_from_core#(vaddr, TMul#(wordsize,8), rob_index, prf_index, lsq_index))  subifc_req_to_ptw;
    interface Ifc_ptw_meta#(vaddr)                                                             subifc_ptw_meta;
    interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages))                        subifc_response_frm_ptw;
    interface Get#(Read_req_to_mem#(paddr, id_bits))                                           subifc_read_req_to_mem;
    interface Put#(Read_resp_from_mem#(buswidth, id_bits))                                     subifc_read_resp_from_mem;
    interface Get#(Write_req_to_mem#(paddr, TMul#(TMul#(wordsize,8), linesize)))               subifc_write_req_to_mem;
    interface Put#(Bool)                                                                       subifc_write_resp_from_mem;
    interface Get#(IO_Req#(paddr, TMul#(wordsize,8)))                                          subifc_IO_req;
    interface Put#(IO_Resp#(TMul#(wordsize,8)))                                                subifc_IO_resp;
    method Action flush(Bit#(rob_index) head, Bit#(rob_index) flush_rob);
    method Action load_drop(Bit#(rob_index) load_rob);
    method Bool cache_busy;
`ifdef supervisor
    method Tuple3#(Bit#(1), Bit#(1), Bit#(1)) dtlb_early_lookup(Bit#(vaddr) vaddr, Bit#(1) is_store);
`endif
`ifdef pref
  method Tuple3#(Bit#(1), Bit#(1), Bit#(TSub#(paddr, TAdd#(TLog#(wordsize), TLog#(linesize))))) fill_response_info(); // (paddr - 6) bits for line address
`endif
`ifdef perfmonitors
    method DCACHE_cntrs mv_dcache_perf_counters();
`endif
`ifdef simulate
  `ifdef fesvr_sim
    `ifndef baremetal_sim
        method Action debug_print();
    `endif
  `endif
`endif
  endinterface

  (*preempts = "rl_MSHR_req_to_fill_buffer, rl_stage2_req_to_fb"*)
  (*preempts = "rl_MSHR_resp_to_core, rl_stage2_fb_resp_to_core"*)
  (*preempts = "rl_MSHR_resp_to_core, rl_sram_resp_to_core"*)
  (*conflict_free = "rl_stage2_fb_resp_to_core, rl_sram_resp_to_core"*)
  (*preempts = "rl_release_fb_cycle1, rl_handle_req_from_core"*)
  (*preempts = "rl_release_fb_cycle2, rl_tag_and_data_array_read_response"*)
  (*preempts = "rl_release_fb_cycle2, rl_stage2_req_to_fb"*)  // NOTE: req must have entered stage2 at least 1 cycle earlier and that means the check for release stall failed
  `ifdef atomic
    (*preempts = "rl_release_fb_cycle2, rl_core_resp_for_atomic"*)
  `endif 
  (*execution_order = "rl_tag_and_data_array_read_response, rl_stage2_req_to_fb"*)
  `ifndef iclass    //  Fixed cache controller for i-class, simple 2-stage (170122)
    (*conflict_free = "rl_enq_ff_second_stage, rl_fb_enq_ff_second_stage"*)
  `endif
  `ifdef atomic
    (*preempts= "rl_initialize, (rl_handle_req_from_core, rl_tag_and_data_array_read_response, `ifndef iclass rl_access_MSHRs, `endif rl_MSHR_req_to_fill_buffer, rl_release_fb_cycle1, rl_release_fb_cycle2, `ifndef iclass rl_release_eviction_buffer, `endif rl_fence_cache, rl_core_resp_for_atomic)"*)
  `else
    (*preempts= "rl_initialize, (rl_handle_req_from_core, rl_tag_and_data_array_read_response, `ifndef iclass rl_access_MSHRs, `endif rl_MSHR_req_to_fill_buffer, rl_release_fb_cycle1, rl_release_fb_cycle2, `ifndef iclass rl_release_eviction_buffer, `endif rl_fence_cache)"*)
  `endif
  (*conflict_free="rl_MSHR_req_to_fill_buffer, mshr.rl_deq_ff"*)
  (*preempts="rl_sram_resp_to_core, rl_access_fault_response_to_core"*)
  (*preempts="rl_stage2_fb_resp_to_core, rl_access_fault_response_to_core"*)
`ifndef iclass
  (*preempts="rl_fence_fb, rl_fence_cache"*)
`endif
`ifdef atomic
  (*preempts="rl_core_resp_for_atomic, rl_fence_cache"*)
  (*preempts = "rl_MSHR_resp_to_core, rl_sc_fail_response_to_core"*)
  (*preempts = "rl_sram_resp_to_core, rl_sc_fail_response_to_core"*)
  (*preempts = "rl_stage2_fb_resp_to_core, rl_sc_fail_response_to_core"*)
  (*preempts = "rl_access_fault_response_to_core, rl_sc_fail_response_to_core"*)
  (*preempts = "rl_sc_fail_response_to_core, rl_receive_IO_resp"*)
 `endif
  (*preempts = "(rl_stage2_fb_resp_to_core, rl_sram_resp_to_core, rl_MSHR_resp_to_core, rl_access_fault_response_to_core), rl_receive_IO_resp"*)
  (*preempts = "rl_stall_for_load_after_store_to_same_word, rl_handle_req_from_core"*)
  (*preempts = "rl_stall_for_set_conflict, rl_handle_req_from_core"*)
  (*preempts = "rl_SRAM_and_MSHR_done_fencing, rl_MSHR_resp_to_core"*)  //TODO does this order matter?
  (*preempts = "rl_flush_ff_req_from_core, rl_handle_req_from_core"*)
  `ifdef atomic
    (*preempts = "rl_flush_ff_first_stage, (rl_tag_and_data_array_read_response, rl_core_resp_for_atomic)"*)
  `else
    (*preempts = "rl_flush_ff_first_stage, rl_tag_and_data_array_read_response"*)
  `endif

  module mknb_dcache#(parameter String alg)
  //                  8,        8,      128,     4,    32,    32,    32,    32,      6,         4,       4,          3,           128,        7          5
    (Ifc_nbdcache#(wordsize, linesize, setsize, ways, paddr, vaddr, dsram, tsram, prf_index, id_bits, mshrsize, mshrfifo_depth, buswidth, rob_index, lsq_index))
    provisos(
      Log#(wordsize, wordbits),
      Mul#(wordsize, 8, datawidth),          //64 datawidth is the total bits in a word
      Mul#(linesize, datawidth, linewidth),  //512 linewidth is the total bits in a cache line
      Add#(wordbits, TLog#(linesize), lineoffset),  //6 lineoffset is no. of bits to indicate byte offset within a line
      Log#(setsize, setbits),                //7 setbits is the no. of bits used as index in BRAMs
      //Add#(, a__, id_bits),                // id_bits should be greater than Log(mshrsize+2)
      Add#(a__, vaddr, datawidth),           // In case of exception, sending address back to core as resp data
      Add#(lineoffset, setbits, tagpos),     //13 tagpos total bits for index + offset, 
      Add#(tagbits, tagpos, paddr),          //19 tagbits = paddr - (lineoffset + setbits)
      Log#(TDiv#(buswidth, 8), busoffset),   //4 busoffset is no. of bits to indicate a byte offset within a buswidth data 
      Div#(linewidth, buswidth, evict_iter), //4 evict_iter is the burst length while evicting a cache line
      Add#(b__, prf_index, datawidth),       //Load responses after stage2 will have prf encoded in the payload field
      //Add#(c__, lineoffset, TLog#(TAdd#(ways, 1))),  //check again
      Add#(d__, TLog#(ways), TLog#(TAdd#(ways, 1))),      //Bluespec cribs
      Add#(e__, TLog#(mshrsize), id_bits),
      Add#(f__, paddr, vaddr),
      Mul#(g__, buswidth, linewidth),
      Add#(h__, buswidth, linewidth),
      Add#(i__, datawidth, linewidth),
      Add#(j__, lineoffset,  paddr),
      Add#(l__, TLog#(ways), 4),            //required by the mkreplace module
      Mul#(m__, 8, linewidth),            //for generate_masked_data fn in FB
      Mul#(n__, 16, linewidth),            //for generate_masked_data fn in FB
      Mul#(o__, 32, linewidth),            //for generate_masked_data fn in FB
      Add#(mshrfifo_depth, 0, `Mshrfifo_depth),
      Add#(TLog#(evict_iter), p__, lineoffset),  //In fill buffer while generating fb_index corresponding to first mem_response
      //------FA TLB-------//
     Add#(TMul#(TSub#(`varpages,1),`subvpn), v__, vaddr),
    `ifdef sv32
      Add#(q__, 22, vaddr),
      Add#(r__, 20, vaddr),
      Add#(s__, vaddr, 34),
      Add#(t__, 1, vaddr)
    `else
      `ifdef sv39
        Add#(q__, 40, vaddr),
        Add#(r__, 27, vaddr),
      `else
        Add#(q__, 49, vaddr),
        Add#(r__, 36, vaddr),
      `endif
      Add#(s__, 44, vaddr),
      Add#(t__, 56, vaddr),
      Add#(u__, 4, vaddr),
    Add#(aa_, 8, datawidth),
    Add#(bb_, 16, datawidth),
    Add#(cc_, 32, datawidth)
    `endif
    `ifdef atomic
      , Add#(w__, 32, datawidth)
    `endif
    `ifdef iclass
      , Add#(buswidth, TAdd#(buswidth, buswidth), h__),
        Mul#(8, y__, buswidth),
        Mul#(16, x__, buswidth),
        Mul#(32, k__, buswidth),
        Mul#(datawidth, c__, buswidth),
        Add#(z__, datawidth, buswidth),
        Add#(aa__, buswidth, 128)
    `endif
    //----------------------//
    );

    let ways_val= valueOf(ways);
    let paddr_val= valueOf(paddr);
    let datawidth_val= valueOf(datawidth);
    let buswidth_val= valueOf(buswidth);
    let busoffset_val= valueOf(busoffset);
    let lineoffset_val= valueOf(lineoffset);
    let setbits_val= valueOf(setbits);
    let tagbits_val= valueOf(tagbits);
    let tagpos_val= valueOf(tagpos);
    let evict_iter_val= valueOf(evict_iter);

    function Bit#(TSub#(paddr,lineoffset)) get_line_addr(Bit#(paddr) addr);
      return addr[paddr_val-1:lineoffset_val];
    endfunction

    Ifc_mem_config1r1w#(setsize, linewidth, dsram) data_arr [ways_val];         // data array
    //TODO Make sure that for now (tagbits+2)/tsram is an integer. Will have to edit mem_config.
    Ifc_mem_config1r1w#(setsize, TAdd#(tagbits, 2), tsram) tag_arr [ways_val]; // extra valid and dirty bits
    Ifc_fa_dtlb#(vaddr, paddr) dtlb <-mkfa_dtlb;
    Ifc_fill_buffer#(paddr, datawidth, buswidth, linewidth, lineoffset, wordsize, prf_index, rob_index) fill_buffer <-mkfill_buffer;
    Ifc_mshr#(paddr, lineoffset, datawidth, mshrsize, mshrfifo_depth, rob_index, prf_index) mshr <- mkmshr;
    Ifc_replace#(setsize, ways) repl <- mkreplace(alg);

    for(Integer i = 0;i<ways_val;i = i+1)begin
      data_arr[i] <- mkmem_config1r1w(False, "data");
      tag_arr[i] <- mkmem_config1r1w(False, "tag");
    end

    ////////////////////////////// Interface signals ///////////////////////////////////////////////
    //These handle the interface signals
    `ifdef iclass
      // only pipeline latch (at input) for simpler flush logic and timing
      FIFOF#(Req_from_core#(vaddr, datawidth, rob_index, prf_index, lsq_index)) ff_req_from_core <- mkPipelineFIFOF;
    `else
      FIFOF#(Req_from_core#(vaddr, datawidth, rob_index, prf_index, lsq_index)) ff_req_from_core <- mkBypassFIFOF;
    `endif
    Wire#(Resp_to_core#(datawidth, prf_index, rob_index)) wr_resp_to_core <- mkWire;
    
    //If a req is a miss in the TLB, that request would be sent to the PTW module. PTW module will
    //store this req and also start performing the PTW. Once PTW is done, it again sends this req
    //to the cache. Now, this request will be a hit in the TLB. This FIFO is used to send the req to
    //the PTW module
    Wire#(Req_from_core#(vaddr, datawidth, rob_index, prf_index, lsq_index)) wr_req_to_ptw <- mkWire;
    FIFOF#(Read_req_to_mem#(paddr, id_bits)) ff_read_req_to_mem <- mkSizedFIFOF(4);
    Wire#(Read_resp_from_mem#(buswidth, id_bits)) wr_read_resp_from_mem <- mkDWire(defaultValue);
    `ifdef iclass
      FIFOF#(Write_req_to_mem#(paddr, linewidth)) ff_write_req_to_mem <- mkPipelineFIFOF; // conservative and simple eviction check; TODO: multi-entry queue
      Reg#(Bool) rg_wait_for_write_response <- mkReg(False);
      Reg#(Bool) rg_write_resp_from_mem <- mkDReg(False);
    `else
      FIFOF#(Write_req_to_mem#(paddr, linewidth)) ff_write_req_to_mem <- mkBypassFIFOF;
      Wire#(Bool) wr_write_resp_from_mem <- mkDWire(False);
    `endif

    FIFO#(IO_Req#(paddr, datawidth)) ff_io_req <- mkSizedFIFO(1);
    FIFO#(IO_Resp#(datawidth)) ff_io_resp <- mkSizedFIFO(1);


    ///////////////////////////// Module signals ///////////////////////////////////////////////////
    FIFOF#(Req_from_core#(paddr, datawidth, rob_index, prf_index, lsq_index)) ff_first_stage <- mkPipelineFIFOF;
    FIFO#(Bit#(TAdd#(tagbits,2))) ff_first_stage_tag[ways_val];
    for(Integer i=0; i<ways_val; i=i+1)
      ff_first_stage_tag[i]<- mkBypassFIFO;

    // NOTE: Only single entry FIFO in 2nd stage is allowed (was 2 entry guarded FIFO + custom FIFOs earlier) in the current controller design (260921)
    //       On a tag mismatch and FB miss, a max. of 1 request is allowed to wait in the 2nd stage latch.
    //       This is because we need to look at the waiting request and poll the FB every cycle to check for possible conflict with the FB address and stall FB release on a match.
    //       This request, if stalled, waits because the MSHR is not ready yet or because the previous request to memory/L2 is still waiting.
    //       See note from 150121.
    `ifndef iclass    //  Fixed cache controller for i-class, simple 2-stage (170122)
      FIFOF#(Cache_req#(paddr, datawidth, rob_index, prf_index)) ff_second_stage <- mkPipelineFIFOF;
      Ifc_SESFMI_FIFO#(1, Bool) cff_second_stage_valid <- mkSESFMI_second_stage_inst;
      Ifc_SEMF_FIFO#(1, Tuple2#(Bit#(rob_index), Bool)) cff_second_stage_rob_id <- mkSEMF_FIFO(?);
    `endif
    FIFO#(Req_from_core#(paddr, datawidth, rob_index, prf_index, lsq_index)) ff_io_info <- mkFIFO;

    Reg#(Bool) rg_cache_busy <- mkConfigReg(True);  //TODO has to be reset depending upon when the leaf page is received
                                                    //or when PTW walk indicates so

    Reg#(FB_state) rg_fb_state <- mkReg(defaultValue);
    Reg#(Bit#(setbits)) rg_initialize_index <- mkReg(0);
    Reg#(Bool) rg_initialize_done <- mkReg(False);
    Reg#(Flush_type#(rob_index)) rg_flush <- mkDReg(defaultValue);
    Reg#(Bool) rg_fence <- mkReg(False);
    Reg#(Bit#(setbits)) rg_fence_set_index <- mkConfigReg(0);
    Reg#(Bool) rg_SRAM_fence[2] <- mkCReg(2, False);
    Reg#(Bit#(2)) rg_fence_state <- mkReg(0);
    Vector#(ways, Reg#(Bit#(linewidth))) rg_fdataline <- replicateM(mkReg(0));
    Vector#(ways, Reg#(Bit#(TAdd#(tagbits, 2)))) rg_ftag <- replicateM(mkReg(0));
    Vector#(ways, Reg#(Bit#(1))) rg_fvalid <- replicateM(mkReg(0));
    Vector#(ways, Reg#(Bit#(1))) rg_fdirty <- replicateM(mkReg(0));
    Reg#(Tuple4#(DCache_exception, Bit#(prf_index), Bit#(rob_index), Bit#(vaddr))) rg_access_fault_response <- mkReg(tuple4(defaultValue, ?, ?, ?));
`ifdef supervisor
    Reg#(Bool) rg_leaf_page_response <- mkReg(False);
    Reg#(Bool) rg_page_fault <- mkReg(False);
`endif
    Reg#(Bool) rg_io_req_sent <- mkReg(False);
    Reg#(Tuple2#(Bool, Bit#(TSub#(vaddr,wordbits)))) rg_prev_req_info <- mkReg(tuple2(False, ?));
    Reg#(Bit#(rob_index)) rg_fence_rob <- mkRegU;
    Reg#(Bool) rg_fence_wait_for_ff_first_stage_empty <- mkConfigReg(False);
    Reg#(Bool) rg_fence_fb_release <- mkDReg(False);
    // Not used currently
    //Reg#(Bit#(TSub#(paddr,lineoffset))) rg_prev_second_stage_line_addr <- mkReg(0);
`ifdef iclass
    Wire#(Bit#(TSub#(paddr, lineoffset))) wr_eviction_addr <- mkDWire(0);
    Wire#(Bit#(1)) wr_eviction_addr_valid <- mkDWire(0);
`else
    Reg#(Bool) rg_evict_lineaddr_valid[2] <- mkCReg(2,False);
    Reg#(Bit#(TSub#(paddr,lineoffset))) rg_evict_lineaddr <- mkReg(?);
`endif

  `ifdef atomic
    Reg#(Maybe#(Tuple2#(Bit#(TLog#(ways)), Bit#(datawidth)))) rg_atomic_hit_info <- mkReg(tagged Invalid);
    Reg#(Tuple3#(Bool, Bit#(paddr), Bit#(rob_index))) rg_lr_info <- mkReg(tuple3(False, ?, ?));
    Reg#(Bool) rg_sc_fail <- mkReg(False);
  `endif

    Wire#(Maybe#(MSHR_Req#(paddr, datawidth, prf_index, rob_index))) wr_mshr_req_to_fb <- mkDWire(tagged Invalid);
    Wire#(Bool) wr_stage2_check_fb <-mkWire;
    Wire#(Bool) wr_is_mshr_resp_to_core <- mkDWire(False);
    Wire#(Bool) wr_stage2_req_to_fb <- mkWire;
    Wire#(Resp_to_core#(datawidth, prf_index, rob_index)) wr_mshr_resp_to_core <- mkWire;
    Wire#(Resp_to_core#(datawidth, prf_index, rob_index)) wr_sram_resp_to_core <- mkWire();
    Wire#(Resp_to_core#(datawidth, prf_index, rob_index)) wr_stage2_fb_resp_to_core <- mkWire();
    `ifdef store_early_ack
      Wire#(Bit#(1)) wr_early_resp_to_core_valid <- mkDWire(0);
      Wire#(Resp_to_core#(datawidth, prf_index, rob_index)) wr_early_resp_to_core <- mkDWire(unpack(0));
    `endif
    Wire#(Bool) wr_stage1_deq <- mkDWire(False);
    Wire#(Bool) wr_stage1_deq_enq <- mkDWire(False);
    Wire#(Bool) wr_stage1_fb_deq <- mkDWire(False);
    Wire#(Bool) wr_stage1_fb_deq_enq <- mkDWire(False);
    Wire#(Cache_req#(paddr, datawidth, rob_index, prf_index)) wr_stage2_enq <- mkWire;
    Wire#(Cache_req#(paddr, datawidth, rob_index, prf_index)) wr_stage2_fb_enq <- mkWire;
    Wire#(Bool) wr_ff_first_stage_req_to_curr_fb <- mkDWire(False);
    `ifndef iclass    //  Fixed cache controller for i-class, simple 2-stage (170122)
      Wire#(Bool) wr_ff_second_stage_req_to_curr_fb <- mkDWire(False);
    `endif
    Wire#(Bool) wr_stall_fb_release <- mkDWire(False);
    Wire#(Bit#(1)) wr_tag_ram_write_valid <- mkDWire(0);
    Wire#(Bit#(setbits)) wr_tag_ram_write_index <- mkDWire(0);
    `ifdef iclass
      Wire#(Bool) wr_fill_request_valid <- mkDWire(False);
      Wire#(Bit#(TLog#(mshrsize))) wr_fill_request_id <- mkDWire(0);
    `endif
    Wire#(Bool) wr_ff_first_stage_not_empty <- mkDWire(False);

    Wire#(Bool) wr_load_drop_valid <- mkDWire(False);
    Wire#(Bit#(rob_index)) wr_load_drop_robid <- mkDWire(0);

  `ifdef pref
    Reg#(Bit#(1)) rg_fill_response_valid <- mkDReg(0);
    Reg#(Bit#(1)) rg_fill_response_demand <- mkReg(0);
    Reg#(Bit#(TSub#(paddr, lineoffset))) rg_fill_response_address <- mkReg(0);
  `endif

  `ifdef perfmonitors
    Wire#(Bit#(1)) wr_request_total <- mkDWire(0);
    Wire#(Bit#(1)) wr_request_io <- mkDWire(0);
    Wire#(Bit#(1)) wr_request_fence <- mkDWire(0);
    Wire#(Bit#(1)) wr_load_hit_cache <- mkDWire(0);
    Wire#(Bit#(1)) wr_store_hit_cache <- mkDWire(0);
    Wire#(Bit#(1)) wr_ptw_hit_cache <- mkDWire(0);
    Wire#(Bit#(1)) wr_load_hit_lfb <- mkDWire(0);
    Wire#(Bit#(1)) wr_store_hit_lfb <- mkDWire(0);
    Wire#(Bit#(1)) wr_ptw_hit_lfb <- mkDWire(0);
    Wire#(Bit#(1)) wr_load_dropped_input <- mkDWire(0);
    Wire#(Bit#(1)) wr_load_dropped_stage1 <- mkDWire(0);
    Wire#(Bit#(1)) wr_fill_request <- mkDWire(0);
    Wire#(Bit#(1)) wr_prefetch_mshr_allocated <- mkDWire(0);
    Wire#(Bit#(1)) wr_dtlb_miss <- mkDWire(0);
  `endif
    
`ifdef simulate
  `ifdef fesvr_sim
    `ifndef baremetal_sim
        Wire#(Bit#(1)) rg_debug_print <- mkReg(0);
        Wire#(Bit#(1)) wr_debug_print <- mkDWire(0);
    `endif
  `endif
`endif


  `ifdef iclass
    function Bit#(linewidth) generate_masked_data(Bit#(linewidth) sram_data, Bit#(datawidth) core_data, Bit#(lineoffset) line_offset, Bit#(3) size);
      Bit#(buswidth) lv_cmask = '0;
      Bit#(linewidth) lv_lmask = '0;

      Bit#(datawidth) temp = size[1 : 0] == 0?'hFF : 
                             size[1 : 0] == 1?'hFFFF : 
                             size[1 : 0] == 2?'hFFFFFFFF : '1;
      Bit#(linewidth) data_to_mask= size=='d0? duplicate(core_data[7:0])  :
                                    size=='d1? duplicate(core_data[15:0]) :
                                    size=='d2? duplicate(core_data[31:0]) :
                                               duplicate(core_data);
      lv_cmask = zeroExtend(temp);
      lv_cmask = lv_cmask << {line_offset[3:0], 3'd0};
      lv_lmask = zeroExtend(lv_cmask);
      lv_lmask = (line_offset[5:4] == 2'b11) ? (lv_lmask << 'd384)
                  : ((line_offset[5:4] == 2'b10) ? (lv_lmask << 'd256)
                      : ((line_offset[5:4] == 2'b01) ? (lv_lmask << 'd128) : lv_lmask));

      Bit#(linewidth) writedata= (lv_lmask & data_to_mask) | (~lv_lmask & sram_data);
      return writedata;
    endfunction

  `else
    function Bit#(linewidth) generate_masked_data(Bit#(linewidth) sram_data, Bit#(datawidth) core_data, Bit#(lineoffset) line_offset, Bit#(3) size);
      Bit#(datawidth) temp = size[1 : 0] == 0?'hFF : 
                             size[1 : 0] == 1?'hFFFF : 
                             size[1 : 0] == 2?'hFFFFFFFF : '1;
      Bit#(linewidth) data_to_mask= size=='d0? duplicate(core_data[7:0])  :
                                    size=='d1? duplicate(core_data[15:0]) :
                                    size=='d2? duplicate(core_data[31:0]) :
                                               duplicate(core_data);
      Bit#(linewidth) mask = zeroExtend(temp);
      mask = mask<<{line_offset,3'd0};
      Bit#(linewidth) writedata= (mask & data_to_mask) | (~mask & sram_data);
      return writedata;
    endfunction
  `endif

  `ifdef iclass
    function Bit#(datawidth) fn_extract_data(Bit#(linewidth) line, Bit#(lineoffset) line_offset, Bit#(3) size);
      Bit#(buswidth) lv_chunk = '0;

      lv_chunk = (line_offset[5:4] == 2'b11) ? truncate(line[511:384])
                  : ((line_offset[5:4] == 2'b10) ? truncate(line[383:256])
                      : ((line_offset[5:4] == 2'b01) ? truncate(line[255:128]) : truncate(line[127:0])));

      lv_chunk = lv_chunk >> {line_offset[3:0], 3'd0};
      Bit#(datawidth) readdata= truncate(lv_chunk);
      Bit#(datawidth) mask = size[1 : 0] == 0?'hFF : 
                             size[1 : 0] == 1?'hFFFF : 
                             size[1 : 0] == 2?'hFFFFFFFF : '1;
      if(size[2]==0) begin
        readdata = size[1 : 0] == 0? signExtend(readdata[7:0]): 
                   size[1 : 0] == 1? signExtend(readdata[15:0]): 
                   size[1 : 0] == 2? signExtend(readdata[31:0]) : readdata;
      end
      else begin
        readdata = readdata & mask;
      end
      return readdata;
    endfunction

  `else
    function Bit#(datawidth) fn_extract_data(Bit#(linewidth) line, Bit#(lineoffset) line_offset, Bit#(3) size);
      line = line>>{line_offset,3'd0};
      Bit#(datawidth) readdata= truncate(line);
      Bit#(datawidth) mask = size[1 : 0] == 0?'hFF : 
                             size[1 : 0] == 1?'hFFFF : 
                             size[1 : 0] == 2?'hFFFFFFFF : '1;
      if(size[2]==0) begin
        readdata = size[1 : 0] == 0? signExtend(readdata[7:0]): 
                   size[1 : 0] == 1? signExtend(readdata[15:0]): 
                   size[1 : 0] == 2? signExtend(readdata[31:0]) : readdata;
      end
      else begin
        readdata = readdata & mask;
      end
      return readdata;
    endfunction
  `endif

    function Cache_req#(paddr, datawidth, rob_index, prf_index) convert_to_Cache_req(Req_from_core#(paddr, datawidth, rob_index, prf_index, lsq_index) req);
      Bit#(datawidth) lv_payload= req.origin==Store_commit? req.data : zeroExtend(req.prf_index);
      return Cache_req { addr: req.addr,
                         access_size: req.access_size,
                         payload: lv_payload,
                         origin: req.origin,
                         prf_index: req.prf_index,
                         dest_type: req.dest_type,
                         rob: req.rob
                       `ifdef atomic
                         , is_atomic: req.is_atomic
                         , atomic_fn: req.atomic_fn
                       `endif };
    endfunction

    function MSHR_Req#(addrwidth, datawidth, prf_index, rob_index) convert_to_MSHR_Req(Req_from_core#(addrwidth, datawidth, rob_index, prf_index, lsq_index) req);
      return MSHR_Req { addr: req.addr,
                        access_size: req.access_size,
                        payload: req.data,
                        origin: req.origin,
                        prf_index: req.prf_index,
                        dest_type: req.dest_type,
                        rob: req.rob
                        `ifdef atomic
                        , atomic_fn: req.atomic_fn
                        , is_atomic: req.is_atomic
                        `endif };
    endfunction

    function Bool should_flush(Bit#(rob_index) head, Bit#(rob_index) flush_rob, Bit#(rob_index) rob);
      Bool lv_should_flush= False;
      Bool cond1= (rob>=(flush_rob));
      Bool cond2= (rob<head && head!=0);

      if(head<=flush_rob) begin
        if( cond1 || cond2 ) begin
          lv_should_flush= True;
        end
      end
      else if(cond1 && cond2) begin
        lv_should_flush= True;
      end

      return lv_should_flush;
    endfunction

    function Cache_DTLB_request#(vaddr) convert_core_to_tlb_req(Req_from_core#(vaddr, datawidth, rob_index, prf_index, lsq_index) core_req);
      `ifdef atomic
        // Load or Prefetch or LR: read else write
        Bit#(2) access= ((core_req.origin == Store_commit) && (core_req.atomic_fn != 'h5) && (core_req.atomic_fn != 'h15)) ? 2'b01 : 2'b00;
      `else
        Bit#(2) access= core_req.origin==Store_commit ? 2'b01 : 2'b00;
      `endif

      Cache_DTLB_request#(vaddr) dtlb_req= Cache_DTLB_request { address: core_req.addr,
                                                             access: access,
                                                             ptwalk_trap: core_req.ptwalk_trap,
                                                             ptwalk_req: (core_req.origin==PTW),
                                                             sfence: core_req.sfence };
      return dtlb_req;
    endfunction

//    function Bool is_IO(Bit#(vaddr) addr);
//      if(addr < 'h1000) begin
//        return True;
//      end
//      else begin
//        return False;
//      end
//    endfunction
//
//    function Bool is_IO(Bit#(vaddr) addr); //TODO remove this dummy is_IO function
//      if( addr>='h1000 && addr<'h2000) begin
//        return False;
//      end
//      else if(addr >= 'h80000000 && addr < 'h90000000) begin
//        return False;
//      end
//      else begin
//        return True;
//      end
//    endfunction

    rule rl_initialize(!rg_initialize_done);
      `logTimeLevel( dcache, 1, $format("DCACHE : Clearing valid bit of set_index: %d", rg_initialize_index))
      for(Integer i=0; i<ways_val; i=i+1) begin
        tag_arr[i].write(rg_initialize_index, 'd0);
      end
      rg_initialize_index<= rg_initialize_index+1;
      if(rg_initialize_index==fromInteger(valueOf(setsize)-1)) begin
        rg_initialize_done<= True;
        rg_cache_busy<= False;
      end
    endrule

    /*
    TODO
    What if when flush is happening and rg_lr_info is set. If the lr instruction is flushed, then even this
    register should be cleared. But currently, both the rules, rl_handle_req_from_core and rl_flush_mshr
    update this register. How to solve? Likewise, for rg_sc_fail.
    One possible solution is to give this more priority than mshr_resp to core. But that would result
    in much complex conditions for rest of the rules.
    */

    let core_req= ff_req_from_core.first;
    //if prev req was store, and current req is load (or from PTW), and the word address matches, then stall
    rule rl_stall_d(tpl_1(rg_prev_req_info));
      `logTimeLevel( dcache, 1, $format("DCACHE_INFO : Core_req: ", fshow(core_req)))
      `logTimeLevel( dcache, 1, $format("DCACHE_INFO : rg_prev_req_info: ", fshow(rg_prev_req_info)))
      Bit#(TSub#(vaddr,wordbits)) lv_prev_addr= truncateLSB(tpl_2(rg_prev_req_info));
      Bit#(TSub#(vaddr,wordbits)) lv_curr_addr= truncateLSB(core_req.addr);
      `logTimeLevel( dcache, 1, $format("DCACHE_INFO : prev_addr: %h curr_addr: %h", lv_prev_addr, lv_curr_addr))
    endrule

    // TODO: check if this is still needed (with changes in the controller)
    rule rl_stall_for_load_after_store_to_same_word(tpl_1(rg_prev_req_info) &&
    (core_req.origin==Load_buffer || core_req.origin==PTW) &&
    tpl_2(rg_prev_req_info)==truncateLSB(core_req.addr));
      rg_prev_req_info<= tuple2(False, ?);
      `logTimeLevel( dcache, 1, $format("DCACHE : Stalling req from core as prev was store. Core_req: ", fshow(core_req)))
    endrule

    // NOTE: Tag and Data RAM implementation changed to BRAM (1R1W): was register file (with hack to delay read to 2nd cycle) earlier
    //       If read and write are to the same index, without bypass, we would read the old tags (070621)
    //       Need to delay the read until the write is performed.
    Bit#(set_bits) stage1_set_index = core_req.addr[setbits_val + lineoffset_val - 1 : lineoffset_val];
    rule rl_stall_for_set_conflict((wr_tag_ram_write_valid == 1) && (stage1_set_index == wr_tag_ram_write_index));
      `logTimeLevel( dcache, 1, $format("DCACHE : Stalling req from core as write is being performed to same set. Core_req: ", fshow(core_req)))
    endrule

    rule rl_check_ff_first_stage;
      wr_ff_first_stage_not_empty <= ff_first_stage.notEmpty;
    endrule

    `ifdef iclass
    Bool stall_for_fence = core_req.sfence && (wr_ff_first_stage_not_empty || mshr.not_empty); // conservative fence (no fence fb): first stage and MSHR should be empty
    `endif
`ifdef supervisor
    // cache busy only for lsu/prefetcher
    Bool lv_cache_busy = (core_req.origin == PTW) ? False : rg_cache_busy;
    // conservatively adding stall for atomic if mshr is not empty (alternatively, arbitrate amongst responses)
    // TODO: requests in 1st/2nd stage
    `ifdef atomic
    Bool stall_atomic_mshr_not_empty = core_req.is_atomic && mshr.not_empty;
    `endif
    rule rl_handle_req_from_core(!lv_cache_busy && !rg_fence `ifdef atomic && !rg_sc_fail && !stall_atomic_mshr_not_empty `endif
                                 && !rg_fence_wait_for_ff_first_stage_empty `ifdef iclass && !stall_for_fence `endif );
`else
    rule rl_handle_req_from_core(!rg_cache_busy && !rg_fence `ifdef atomic && !rg_sc_fail `endif
                                 && !rg_fence_wait_for_ff_first_stage_empty `ifdef iclass && !stall_for_fence `endif );
`endif
      DTLB_Cache_response#(paddr) resp_from_tlb = unpack(0);

      let core_req= ff_req_from_core.first;
      ff_req_from_core.deq;
      Bool is_actual_store= (core_req.origin == Store_commit);
      //if(!rg_flush.valid || is_actual_store || !should_flush(rg_flush.head, rg_flush.flush_rob, core_req.rob)) begin
        rg_prev_req_info<= tuple2(is_actual_store, truncateLSB(core_req.addr));
        Bit#(setbits) set_index;
        //For a fence instruction, start from cache index 0.
        if(core_req.sfence) begin
          set_index= rg_fence_set_index;
          `ifdef ASSERT
            dynamicAssert(rg_fence_set_index==0,"Fence starting with index!=0");
          `endif
        end
        else begin
          set_index= core_req.addr[setbits_val + lineoffset_val - 1 : lineoffset_val];
        end
        `logTimeLevel( dcache, 1, $format("DCACHE : Stage 1 Core_req: ", fshow(core_req), "set_index: %d", set_index))
        
        for(Integer i = 0;i<ways_val;i = i+1) begin
          data_arr[i].read(set_index);
          tag_arr[i].read(set_index);
        end

        `ifdef dcache_side_prefetch
            if (core_req.origin != Store_buffer) begin
              resp_from_tlb <- dtlb.translate(convert_core_to_tlb_req(core_req));
            end
            else begin  // prefetcher sends physical addr
              resp_from_tlb = (DTLB_Cache_response{address: truncate(core_req.addr),
                                                   trap: False,
                                                   exception: No_exception,
                                                   tlbmiss: False});
            end
        `else
            resp_from_tlb <- dtlb.translate(convert_core_to_tlb_req(core_req));
        `endif
        Req_from_core#(paddr, datawidth, rob_index, prf_index, lsq_index) req= Req_from_core{ addr: resp_from_tlb.address,
                                                                                              access_size: core_req.access_size,
                                                                                              data: core_req.data,
                                                                                              origin: core_req.origin,
                                                                                              sfence: core_req.sfence,
                                                                                              ptwalk_trap: core_req.ptwalk_trap,
                                                                                              lsq_id: core_req.lsq_id,
                                                                                              rob: core_req.rob,
                                                                                              prf_index: core_req.prf_index,
                                                                                              dest_type: core_req.dest_type
                                                                                              `ifdef atomic
                                                                                              , is_atomic: core_req.is_atomic
                                                                                              , atomic_fn: core_req.atomic_fn
                                                                                              `endif };
        Bool is_IO_access= isIO(resp_from_tlb.address[`paddr-1:0], True);

        if(core_req.sfence) begin
          `ifndef iclass
            mshr.fence;
          `endif
          //rg_fence<= True;
          rg_fence_rob<= core_req.rob;
          rg_SRAM_fence[0]<= True;
          rg_fence_wait_for_ff_first_stage_empty<= True;
          rg_cache_busy<= True;
          `logTimeLevel( dcache, 1, $format("DCACHE : Fence instruction received."))
          `ifdef perfmonitors
            wr_request_fence <= 1;
          `endif
        end

        // drop load on directive from core (TODO: optimize tlb lookup/side-band)
        else if ((req.origin == Load_buffer) && wr_load_drop_valid && (wr_load_drop_robid == req.rob)) begin
          `logTimeLevel( dcache, 1, $format("DCACHE : Load (early) with robid %d dropped in stage1.", req.rob))
          `ifdef perfmonitors
            wr_load_dropped_stage1 <= 1;
          `endif
        end

`ifdef supervisor
        else if(!resp_from_tlb.tlbmiss) begin      //Hit in the TLB
`else
        else if(!resp_from_tlb.tlbmiss || is_IO_access) begin      //Hit in the TLB or is an IO operation
`endif
          `logTimeLevel( dcache, 1, $format("DCACHE : Hit in the TLB"))
          if(resp_from_tlb.trap) begin  //Access fault
            if (req.origin != Store_buffer) begin
              rg_cache_busy<= True;
              `logTimeLevel( dcache, 1, $format("DCACHE : TLB Access fault"))
              rg_access_fault_response<= tuple4(resp_from_tlb.exception, core_req.prf_index, core_req.rob, core_req.addr);
            end
            else begin
              `logTimeLevel( dcache, 1, $format("DCACHE : Access fault on prefetch request address: dropping."))
            end
          end
          else begin  //Access is valid
            Bool lv_sc_pass= True;
          `ifdef atomic
            if(core_req.is_atomic) begin
              if((core_req.atomic_fn=='h5 || core_req.atomic_fn=='h15) && !tpl_1(rg_lr_info)) //(LR.W or LR.D) and rg_lr_info is false
                rg_lr_info<= tuple3(True, resp_from_tlb.address, core_req.rob);
              else
                rg_lr_info<= tuple3(False, ?, ?);

              if(core_req.atomic_fn=='h7 || core_req.atomic_fn=='h17) begin   //SC.W or SC.D
                Bit#(TSub#(paddr,3)) lv_reserved_addr= tpl_2(rg_lr_info)[paddr_val-1:3];
                if(!(tpl_1(rg_lr_info) && lv_reserved_addr==resp_from_tlb.address[paddr_val-1:3]))
                  lv_sc_pass= False;
              end
            end
            else 
              rg_lr_info<= tuple3(False, ?, ?);
          `endif

            // Send early response for cacheable (regular) stores if 1) TLB hit 2) permissions are fine
            `ifdef store_early_ack
              if (!is_IO_access && (req.origin == Store_commit) && !req.sfence `ifdef atomic && !req.is_atomic `endif ) begin
                `logTimeLevel( dcache, 1, $format("DCACHE : Regular store, sending early response: rob: %h prf: %h", req.rob, req.prf_index))
                wr_early_resp_to_core_valid <= 1;
                wr_early_resp_to_core <= Resp_to_core { data: '0,
                                                        prf_index: req.prf_index,
                                                        rob: req.rob,
                                                        exception: No_exception
                                                        `ifdef atomic
                                                        `ifdef simulate
                                                           ,  atomic_result: 0
                                                        `endif
                                                        `endif };
              end
            `endif // store_early_ack

            if(is_IO_access) begin  //IO operation
              if (req.origin != Store_buffer) begin
                //Enqueue into a separate FIFO that handles IO Requests
                `logTimeLevel( dcache, 1, $format("DCACHE : IO request sent to Stage2"))
                `ifdef ASSERT
                  dynamicAssert(req.origin==Store_commit || req.origin==Load_buffer,"DCACHE: Origin wrong for IO request.");
                `endif
                ff_io_info.enq(req);
                rg_access_fault_response<= tuple4(defaultValue, ?, ?, core_req.addr);
                rg_cache_busy<= True;
                `ifdef perfmonitors
                  wr_request_io <= 1;
                `endif
              end
              else begin
                `logTimeLevel( dcache, 1, $format("DCACHE : Prefetch request sent for an IO address: dropping."))
              end
            end
            else if(lv_sc_pass) begin  //Else it's a cacheable request. Enqueue in the first stage FIFO.
              `logTimeLevel( dcache, 1, $format("DCACHE : Sending req ", fshow(req), " to Stage2"))
              ff_first_stage.enq(req);
            end
          `ifdef atomic
            else begin
              rg_sc_fail<= True;
              rg_access_fault_response<= tuple4(defaultValue, core_req.prf_index, core_req.rob, ?);
              rg_cache_busy<= True;
              `logTimeLevel( dcache, 1, $format("DCACHE : Atomic failed"))
            end
          `endif
          end // no trap
        end // TLB hit
        else begin    //Miss in the TLB and not IO or fence operation
          if (core_req.origin != Store_buffer) begin
            `logTimeLevel( dcache, 1, $format("DCACHE : Miss in the TLB"))
            wr_req_to_ptw<= core_req;    //TODO PTW will store the req and send it again, once PTW is done.
            rg_cache_busy<= True;
          end
          else begin
            `logTimeLevel( dcache, 1, $format("DCACHE : Miss in the TLB for prefetch request: dropping."))
          end
          `ifdef perfmonitors
            wr_dtlb_miss <= 1;
          `endif
        end
        `logTimeLevel( dcache, 1, $format("DCACHE : Physical addr from TLB: %h", req.addr))

        `ifdef perfmonitors
          wr_request_total <= 1;
        `endif
      //end
    endrule

    rule rl_access_fault_response_to_core(!wr_is_mshr_resp_to_core &&
    tpl_1(rg_access_fault_response)!=defaultValue && rg_cache_busy);
      `logTimeLevel( dcache, 1, $format("DCACHE : Access fault! ", fshow(rg_access_fault_response)))
      wr_resp_to_core<= Resp_to_core {data: zeroExtend(tpl_4(rg_access_fault_response)),
                                      rob: tpl_3(rg_access_fault_response),
                                      prf_index: tpl_2(rg_access_fault_response),
                                      exception: tpl_1(rg_access_fault_response)
                                      `ifdef atomic
                                        `ifdef simulate
                                        ,  atomic_result: 0
                                        `endif
                                      `endif };
      rg_cache_busy<= False;
      rg_access_fault_response<= tuple4(defaultValue, ?, ?, ?);
    endrule

  `ifdef atomic
    rule rl_sc_fail_response_to_core(!wr_is_mshr_resp_to_core && rg_sc_fail && !rg_fence && rg_cache_busy);
      `logTimeLevel( dcache, 1, $format("DCACHE : SC failed for prf: %h rob: %h", tpl_2(rg_access_fault_response), tpl_3(rg_access_fault_response)))
      wr_resp_to_core<= Resp_to_core {data: 'd1,
                                      prf_index: tpl_2(rg_access_fault_response),
                                      rob: tpl_3(rg_access_fault_response),
                                      exception: defaultValue
                                      `ifdef atomic
                                        `ifdef simulate
                                        ,  atomic_result: 0
                                        `endif
                                      `endif };
      rg_sc_fail<= False;
      rg_cache_busy<= False;
    endrule
  `endif

  `ifdef supervisor
    rule rl_page_fault_response_to_core(!wr_is_mshr_resp_to_core && (rg_page_fault || rg_leaf_page_response) && rg_cache_busy);
      // TODO: page fault response
      if (rg_page_fault)
        `logTimeLevel( dcache, 1, $format("DCACHE : Page fault!"))
      else
        `logTimeLevel( dcache, 1, $format("DCACHE : Leaf page found!"))
      rg_page_fault <= False;
      rg_leaf_page_response <= False;
      rg_cache_busy <= False;
    endrule
  `endif

    //In case we cannot enqueue into ff_second_stage, the second stage would stall. After some clock
    //cycles when we can enqueue into ff_second_stage, the correct values of tag will not be 
    //available as the first stage is not repeated in this cycle. Hence, an intermediate BypassFIFO
    //is required to store the tag bits. For the case, when there is no stall, since it's a BypassFIFO
    //the value enqueued can be read in the same cycle, and does not result in any stalls. On the other
    //hand when there is a stall, this FIFO will hold the value of the tag until data can be enqueued
    //into ff_second_stage.
    rule rl_read_tag_response(ff_first_stage.notEmpty);
      for(Integer i = 0; i<ways_val; i = i+1) begin
        let temp = tag_arr[i].read_response;
        `logTimeLevel( dcache, 1, $format("DCACHE : Stage2 tag[%d] read: %h", i, temp))
        ff_first_stage_tag[i].enq(temp);
      end
    endrule

`ifdef iclass
    rule rl_read_eviction_buffer;
      wr_eviction_addr <= get_line_addr(ff_write_req_to_mem.first.addr);
      wr_eviction_addr_valid <= 1;
    endrule

    // Check for registered eviction address match at the start of stage 2. An eviction happening 
    // in the current cycle (fb release cycle 2) would not conflict as 
    //    1) the request in stage 2 has to be a request that has been here for over a cycle (request can't arrive this cycle due to stage1/fb read/read conflict)
    //    2) if the request in stage 2 is a hit but response isn't sent yet due to mshr response's higher priority, it will be sent the cycle the fb decides to release
    //       => eviction line matching hit line is fine
    //    3) the request in stage 2 is a miss => miss line address can't match eviction line address
    // TODO: multiple entry FIFO
    Bool stall_due_to_eviction_buf_release = (wr_eviction_addr_valid == 1) && (get_line_addr(ff_first_stage.first.addr) == wr_eviction_addr);
`else
    Bool stall_due_to_eviction_buf_release= rg_evict_lineaddr_valid[0] && (get_line_addr(ff_first_stage.first.addr) == rg_evict_lineaddr);
`endif
    //This rule matches the tag and checks if it was a hit in the cache; and if it is, sends a response
    //to the core (in case no request from MSHR is sending a response to the core). If it's a miss in the
    //cache, then the request is sent to the fill buffer.
    //This rule fires only if the request is not to the line that is present in the eviction buffer.
    rule rl_tag_and_data_array_read_response(!rg_SRAM_fence[0] `ifdef atomic &&& rg_atomic_hit_info matches tagged Invalid `endif
    &&& !stall_due_to_eviction_buf_release);
      let req= ff_first_stage.first;
      `logTimeLevel( dcache, 1, $format("DCACHE : Stage2 req: ", fshow(req)))

      Bit#(linewidth) dataline [ways_val];
      Bit#(TAdd#(tagbits,2)) tag;
      Bit#(TLog#(TAdd#(ways,1))) way_num='d-1;
      Bit#(tagbits) req_tag= req.addr[paddr_val-1: tagpos_val];
      Bool send_resp= req.origin!=Store_buffer;

      for(Integer i = 0; i<ways_val; i = i+1) begin
        let tempdata= data_arr[i].read_response;
        dataline[i] = tempdata;
        tag = ff_first_stage_tag[i].first;
        //If a tag in the SRAMs is valid and is equal to the tag of the request, it's a hit in the cache
        if(tag[tagbits_val]==1 && tag[tagbits_val-1:0]== req_tag) begin    
          `logTimeLevel( dcache, 1, $format("DCACHE : Hit at way num: %d tag: %h req_tag: %h", i, tag, req_tag ))
          way_num= fromInteger(i);  //Store the index of the tag match
        end
      end

      if(way_num!='1) begin                                    //It's a line hit
        Bit#(TLog#(ways)) hit_way= truncate(way_num);
        Bit#(setbits) set_index = req.addr[setbits_val + lineoffset_val - 1 : lineoffset_val];
        let hit_line= dataline[hit_way];  //TODO change this to OInt type
        let hit_tag= tag_arr[hit_way].read_response;
        `logTimeLevel( dcache, 1, $format("DCACHE : Hit in the dcache", fshow(req)))
        `logTimeLevel( dcache, 1, $format("DCACHE : Hit at set_index: %d way_num: %d line: %h tag: %h", set_index, hit_way, hit_line, hit_tag))

        Bit#(datawidth) data_to_core= fn_extract_data(hit_line, truncate(req.addr), req.access_size);  //TODO Make UniqueWrapper for this fn

        // NaN Boxing for sp loads (FLW)
        if ((req.access_size == 3'b010) && (req.dest_type == FPRF)) begin
          data_to_core = data_to_core | 'hffffffff00000000;
        end

        //If MSHR req is not sending response, the current hit response can be sent to the processor.
        //Hence, deq ff_first_stage. Also, for Store_buffer requests, no response needs to be sent,
        //and therfore, ff_first_stage can be dequeued.
        if((!wr_is_mshr_resp_to_core `ifdef atomic && !req.is_atomic `endif ) || req.origin==Store_buffer) begin
          wr_stage1_deq<= True;
        end

        //If MSHR req is not sending response, then this stage can send a response for hit.
        if(send_resp && !wr_is_mshr_resp_to_core `ifdef atomic && !req.is_atomic `endif ) begin

          // TODO: check counters
          `ifdef perfmonitors
            if (req.origin == Load_buffer) begin
              wr_load_hit_cache <= 1;
            end
            else if (req.origin == Store_commit) begin
              wr_store_hit_cache <= 1;
            end
            else if (req.origin == PTW) begin
              wr_ptw_hit_cache <= 1;
            end
          `endif

          `ifdef store_early_ack
            if ((req.origin == Store_commit) && !req.sfence `ifdef atomic && !req.is_atomic `endif ) begin
              send_resp = False;
            end
          `endif // store_early_ack
          if (send_resp) begin
            wr_sram_resp_to_core<= Resp_to_core { data: data_to_core,
                                                  prf_index: req.prf_index,
                                                  rob: req.rob,
                                                  exception: No_exception
                                                  `ifdef atomic
                                                    `ifdef simulate
                                                      ,  atomic_result: 0
                                                    `endif
                                                  `endif };
          end
          repl.update_set(set_index, hit_way);  //Update the replacement bits on a hit
          `logTimeLevel( dcache, 1, $format("DCACHE : Hit response to proc. data: %h prf_index: %h", data_to_core, req.prf_index))
        
          //For a store instruction, update the appropriate data and tag bits in the SRAM.
          //TODO If MSHR is sending response in a cycle, should the store happen in that or
          //     should it wait for a free cycle where this stage can send a response?
          if(req.origin==Store_commit) begin
            Bit#(lineoffset) line_offset= req.addr[lineoffset_val-1:0];
            let write_data= generate_masked_data(hit_line, req.data, line_offset, req.access_size);
            data_arr[hit_way].write(set_index, write_data);
            tag_arr[hit_way].write(set_index, {1'b1, hit_tag[tagbits_val:0]}); //Setting the dirty bit
            wr_tag_ram_write_valid <= 1;
            wr_tag_ram_write_index <= set_index;
            `logTimeLevel( dcache, 1, $format("DCACHE : Hit for store. Writing: %h", write_data))
          end
        end // send_resp and mshr not sending
        `ifdef atomic
        else if(req.is_atomic) begin
          //let data= perform_atomic_op(data_to_core, req.data, req.atomic_fn);
          wr_stall_fb_release<= True;
          rg_atomic_hit_info<= tagged Valid tuple2(hit_way, data_to_core);
        end
        `endif
      end
      //MSHR is sending a req to FB and the curr line addr of FB = ff_first_stage request's line addr
      //TODO 14082020. Can we check if MSHR is not full and ff_second_stage is Empty, and if so, forward the req to MSHR?
      else if(isValid(wr_mshr_req_to_fb) && fill_buffer.line_addr == get_line_addr(req.addr)) begin
        `logTimeLevel( dcache, 1, $format("DCACHE : MSHR polling FB and MSHR sending resp to core. Hence stalling req: ", fshow(req)))
        //if(req.origin!=Store_commit || !wr_is_mshr_resp_to_core) begin
        //  `logTimeLevel( dcache, 1, $format("DCACHE : MSHR polling FB. Miss in the dcache. Sending req: ", fshow(req), "to ff_second_stage"))
        //  wr_stage2_enq<= convert_to_Cache_req(req);
        //  if(req.origin==Store_commit `ifdef atomic && !req.is_atomic `endif ) begin
        //    wr_sram_resp_to_core<= Resp_to_core { data: ?,
        //                                          prf_index: req.prf_index,
        //                                          rob: req.rob,
        //                                          exception: No_exception };
        //  end
        //end
        //else begin
        //end
      end

      `ifndef iclass
        // NOTE: load/store/ptw address matches fb line, no request from mshr but 2nd stage ff also holds request to same line (080621)
        else if((req.origin != Store_buffer) && (fill_buffer.line_addr == get_line_addr(req.addr)) && (wr_ff_second_stage_req_to_curr_fb)) begin
          `logTimeLevel( dcache, 1, $format("DCACHE : FB fill to same line, 2nd stage ff stalled. Hence stalling req: ", fshow(req)))
        end
      `endif // !iclass

      else begin  //Line miss; send req to FB since MSHR is not sending
        wr_stage2_req_to_fb<= True;
        `logTimeLevel( dcache, 1, $format("DCACHE : RAM miss, checking FB for Stage2 req ", fshow(req)))
      end
    endrule

  `ifdef atomic
    rule rl_core_resp_for_atomic(rg_atomic_hit_info matches tagged Valid .atomic_hit_info 
    &&& !stall_due_to_eviction_buf_release);
      let req= ff_first_stage.first;
      let atomic_fn= req.atomic_fn;
      match {.hit_way, .cache_data}= atomic_hit_info;
      let atomic_result= fn_atomic_op(atomic_fn, req.data, cache_data);
      Bit#(lineoffset) line_offset= req.addr[lineoffset_val-1:0];
      let cache_line= data_arr[hit_way].read_response;
      let write_data= generate_masked_data(cache_line, atomic_result, line_offset, req.access_size); //TODO make UniqueWrapper
      `logLevel( dcache, 3, $format("DCACHE : Atomic cache_data: %h cache_line: %h atomic_result: %h line_offset: %h access_size: %d fn: %b write_data: %h", cache_data, cache_line, atomic_result, line_offset, req.access_size, atomic_fn, write_data))
      wr_stage1_deq<= True;
      rg_atomic_hit_info<= tagged Invalid;
      Bit#(setbits) set_index = req.addr[setbits_val + lineoffset_val - 1 : lineoffset_val];

      Bit#(tagbits) req_tag= req.addr[paddr_val-1: tagpos_val];
      data_arr[hit_way].write(set_index, write_data);
      tag_arr[hit_way].write(set_index, {1'b1, 1'b1, req_tag}); //Setting the valid (which is already 1) and dirty bit
      wr_tag_ram_write_valid <= 1;
      wr_tag_ram_write_index <= set_index;
      if(atomic_fn=='h7 || atomic_fn=='h17) begin  //if SC.W or SC.D
        cache_data= 'd0;
      end
      Resp_to_core#(datawidth, prf_index, rob_index) resp= Resp_to_core { data: cache_data, //TODO check if correct for atomics
                                                                          prf_index: req.prf_index,
                                                                          rob: req.rob,
                                                                          exception: No_exception
                                                                          `ifdef atomic
                                                                            `ifdef simulate
                                                                            ,  atomic_result: atomic_result
                                                                            `endif
                                                                          `endif };

      // TODO: check counters
      `ifdef perfmonitors
        wr_store_hit_cache <= 1;
      `endif

      `logTimeLevel( dcache, 1, $format("DCACHE : Stage 2 atomics hit req: ", fshow(req)))
      `logTimeLevel( dcache, 1, $format("DCACHE : Stage 2 atomics hit resp: ", fshow(resp)))
      wr_sram_resp_to_core<= resp;
    endrule
  `endif // atomic

    //This rule fires in the same cycle as rl_tag_and_data_array_read_response if tag match returned a miss.
    //This rule sends a req to FB and checks if the response is a hit or not. If it's a hit, an
    //acknowledgement is sent to the core; else, the request is stored into ff_second_stage.
    // NOTE: this rule doesn't fire in a flush cycle (see note on fb release cycle1)
    rule rl_stage2_req_to_fb(wr_stage2_req_to_fb);
      let req= ff_first_stage.first;
      Maybe#(Bit#(linewidth)) fill_buffer_resp= tagged Invalid;
      Bool lv_stage1_fb_deq= False;

      //TODO for mshr response for SC, change response to 0
      `ifdef atomic
      if(!req.is_atomic) begin  //If not atomic
      `endif
        fill_buffer_resp<- fill_buffer.request(convert_to_MSHR_Req(req));       //Req and resp to/from fill buffer
      `ifdef atomic
      end
      //if atomic, then wait for FB to get the complete line and also, MSHR should not be sending response in this cycle
      else if(fill_buffer.can_release && !wr_is_mshr_resp_to_core) begin
        fill_buffer_resp<- fill_buffer.request(convert_to_MSHR_Req(req));
      end
      //else if req.addr matches fb_addr, then stall
      //else enq to next stage
      `endif

      //Fill buffer holds the data corresponding to the line (and the data is valid in the fill buffer) and
      //if a response needs to be sent (i.e. a load_buffer or a PTW request).
      //Here, fb_data is the complete fill buffer line
      `logTimeLevel( dcache, 1, $format("DCACHE : Not a hit in SRAM. Checking fill buffer for req:", fshow(req)))
      //if(req.origin==Store_commit && !wr_is_mshr_resp_to_core)  //TODO Arjun NEW.
      //  lv_stage1_fb_deq= True;

      if(fill_buffer_resp matches tagged Valid .fb_data) begin
        if(!wr_is_mshr_resp_to_core || req.origin==Store_buffer) begin
          lv_stage1_fb_deq= True;
        end
        `logTimeLevel( dcache, 1, $format("DCACHE : Fill buffer hit with data: %h for prf_index: %h",  fb_data, req.prf_index))
        Bit#(datawidth) data_to_core= fn_extract_data(fb_data, truncate(req.addr), req.access_size);
        // NaN Boxing for sp loads (FLW)
        if ((req.access_size == 3'b010) && (req.dest_type == FPRF)) begin
          data_to_core = data_to_core | 'hffffffff00000000;
        end
        Bool send_resp= req.origin!=Store_buffer;

        `ifdef store_early_ack
          if ((req.origin == Store_commit) && !req.sfence `ifdef atomic && !req.is_atomic `endif ) begin
            send_resp = False;
          end
        `endif // store_early_ack

      `ifdef atomic
        if(req.is_atomic && (req.atomic_fn=='h7 || req.atomic_fn=='h17)) begin //SC.W or SC.D
          data_to_core= 0;
        end
      `endif

        if(send_resp && !wr_is_mshr_resp_to_core) begin
          wr_stage2_fb_resp_to_core<= Resp_to_core { data: data_to_core,
                                                     prf_index: req.prf_index,
                                                     rob: req.rob,
                                                     exception: No_exception
                                                     `ifdef atomic
                                                       `ifdef simulate
                                                       ,  atomic_result: 0
                                                       `endif
                                                     `endif };

          `ifdef perfmonitors
            if (req.origin == Load_buffer) begin
              wr_load_hit_lfb <= 1;
            end
            else if (req.origin == Store_commit) begin
              wr_store_hit_lfb <= 1;
            end
            else if (req.origin == PTW) begin
              wr_ptw_hit_lfb <= 1;
            end
          `endif
        end // send_resp
        //else do nothing
      end
      else if(fill_buffer.line_addr == get_line_addr(req.addr)) begin  //Req to same line that is being filled in the FB
        // TODO: optimize based on chunk
        `logTimeLevel( dcache, 1, $format("DCACHE : Req to same line_addr: %h that is being filled in the FB. Stalling... ", fill_buffer.line_addr))
      end

  `ifdef iclass
      // flush check needed since currently mshr doesn't support enqueue in flush cycle
      else if (!rg_flush.valid) begin
        `logTimeLevel( dcache, 1, $format("DCACHE : FB miss, looking up MSHR."))

        // look up mshr
        let cache_req= convert_to_Cache_req(req);
        let {lv_mshr_status, lv_mshr_id} <- mshr.lookup(cache_req);

        // NOTE: This only works with early store response turned ON. All requests go to MSHR and no response for regular stores is returned from this stage.
        // TODO: Need to add response if store_early_ack is off

        // Primary miss and fill request fifo not full
        if ((lv_mshr_status == Not_allocated) && ff_read_req_to_mem.notFull) begin
          mshr.allocate(cache_req, lv_mshr_status, lv_mshr_id);
          wr_fill_request_valid <= True;
          wr_fill_request_id <= lv_mshr_id;
          lv_stage1_fb_deq= True;
          `logTimeLevel( dcache, 1, $format("DCACHE : Primary miss (new fill): Allocating entry %d in MSHR.", lv_mshr_id))
        end
        // Primary miss and fill req fifo full
        else if (lv_mshr_status == Not_allocated) begin
          `logTimeLevel( dcache, 1, $format("DCACHE : Primary miss (new fill): Fill request fifo full. Stalling..."))
        end
        // Secondary miss and mshr fifo available
        else if (lv_mshr_status == Allocated) begin
          mshr.allocate(cache_req, lv_mshr_status, lv_mshr_id);
          lv_stage1_fb_deq= True;
          `logTimeLevel( dcache, 1, $format("DCACHE : Secondary miss: Allocating entry %d in MSHR.", lv_mshr_id))
        end
        `ifdef prefetch_throttle
          else if (lv_mshr_status == Dropped) begin
            lv_stage1_fb_deq= True;
            `logTimeLevel( dcache, 1, $format("DCACHE : MSHR NOT allocated for prefetch req (dropped) with addr: %h", req.addr))
          end
        `endif
        // Primary or Secondary miss and entries/fifo full
        else begin
          `logTimeLevel( dcache, 1, $format("DCACHE : Primary/Secondary miss: MSHR entries/fifo full. Stalling..."))
        end
      end // !flush
      else begin
        `logTimeLevel( dcache, 1, $format("DCACHE : Miss request. Fill buffer miss, flush cycle: no enqueue to mshr for req: ", fshow(req)))
      end

  `else // !iclass
      //else if(mshr.entries_full && ff_second_stage.notEmpty)  begin
      //  //dynamicAssert(!ff_second_stage.notFull,"ff_second_stage is FULL when MSHR entries are full");
      //  `logLevel( dcache, 1, $format("DCACHE : MSHR entries are full, and ff_second_stage has one entry. Stalling... "))
      //end

      //If current req is to same line as that of the prev req that was enqueued, and it is the second
      //entry in the FIFO (which can be found by checking if ff_second_stage is Full),
      //then don't send req to fill buffer, but stall
      //else if(get_line_addr(req.addr) == rg_prev_second_stage_line_addr && !ff_second_stage.notFull) begin
      //  `logLevel( dcache, 1, $format("DCACHE : MSHR busy, ff_second_stage full, and prev req enqueued in second stage is to same line addr. Stalling... "))
      //end
      else if(mshr.entries_full || mshr.one_fifo_full) begin
        `logTimeLevel( dcache, 1, $format("DCACHE : MSHR busy. Stalling second stage... "))
      end
      else begin
        // NOTE: Turning off enqueue to 2nd stage and store response to core in flush cycle (220221)
        // For a store miss in the flush cycle, response is sent to the core, and 2nd stage enqueue happens but rl_fb_enq_ff_second_stage below
        // fires only if flush is invalid => enqueue to cff and dequeue from first stage fifo are disabled in flush cycle
        if (!rg_flush.valid) begin
          `logTimeLevel( dcache, 1, $format("DCACHE : Miss request. Fill buffer miss for req: ", fshow(req)))
          Bool is_store_instruction= (req.origin==Store_commit `ifdef atomic && !req.is_atomic `endif );

          //if store instructions, and mshr is sending response to core, then do not enqueue request into next cycle
          //For store instructions, if TLB checks pass, the response can immediately be sent. Therefore, instead of sending it to the MSHR,
          //We stall until MSHR is not sending a response to the core. This way, the ROB can move forward asap.
          //Also, this will have no impact on throughput as the same store instruction would have arrived from the store buffer
          //a couple of clock cycles before. Therefore, even if the store is a miss in the cache, a "prefetch" would
          //have already started.
          if((!is_store_instruction || !wr_is_mshr_resp_to_core) && ff_second_stage.notFull) begin
            let second_stage_req= convert_to_Cache_req(req);
            ff_second_stage.enq(second_stage_req);
            wr_stage2_fb_enq<= second_stage_req;
            `logTimeLevel( dcache, 1, $format("DCACHE : Converted to cache request"))
          end

          `ifndef store_early_ack
            if(is_store_instruction) begin
              if(wr_is_mshr_resp_to_core) begin
                `logTimeLevel( dcache, 1, $format("DCACHE : MSHR responding to core. Hence stalling Store req: ", fshow(req)))
              end
              else begin
                  `logTimeLevel( dcache, 1, $format("DCACHE : Sending store response for prf_index: %h ", req.prf_index))
                  wr_stage2_fb_resp_to_core<= Resp_to_core { data: ?,
                                                             prf_index: '0,
                                                             rob: req.rob,
                                                             exception: No_exception
                                                             `ifdef atomic
                                                               `ifdef simulate
                                                               ,  atomic_result: '0
                                                               `endif
                                                             `endif };
              end // no mshr response
            end // store
          `endif // if !store_early_ack
        end // flush invalid
        else begin
          `logTimeLevel( dcache, 1, $format("DCACHE : Miss request. Fill buffer miss, flush cycle: no enqueue to 2nd stage for req: ", fshow(req)))
        end
      end
    `endif // !iclass

      wr_stage1_fb_deq<= lv_stage1_fb_deq;
    endrule

  `ifndef iclass
    rule rl_enq_ff_second_stage(!rg_flush.valid);
    //  `logTimeLevel( dcache, 1, $format("DCACHE : ff_second_stage enq req: ", fshow(wr_stage2_enq)))
    //  wr_stage1_deq_enq<= True;
    //  ff_second_stage.enq(wr_stage2_enq);
    //  Bool can_flush= wr_stage2_enq.origin!=Store_commit;
    //  cff_second_stage_rob_id.enq(tuple2(wr_stage2_enq.rob, can_flush));
    //  cff_second_stage_valid.enq(True);
    endrule

    rule rl_fb_enq_ff_second_stage(!rg_flush.valid && cff_second_stage_valid.notFull);
      `logTimeLevel( dcache, 1, $format("DCACHE : ff_second_stage fb enq req: ", fshow(wr_stage2_fb_enq)))
      wr_stage1_fb_deq_enq<= True;
      //rg_prev_second_stage_line_addr<= get_line_addr(wr_stage2_fb_enq.addr);
      //ff_second_stage.enq(wr_stage2_fb_enq);
      Bool can_flush= (wr_stage2_fb_enq.origin!=Store_commit) && (wr_stage2_fb_enq.origin!=PTW);
      cff_second_stage_rob_id.enq(tuple2(wr_stage2_fb_enq.rob, can_flush));
      cff_second_stage_valid.enq(True);
    endrule
  `endif // !iclass

    rule rl_sram_resp_to_core;
      `logTimeLevel( dcache, 1, $format("DCACHE : SRAM response", fshow(wr_sram_resp_to_core)))
      wr_resp_to_core<= wr_sram_resp_to_core;
    endrule

    rule rl_stage2_fb_resp_to_core;
      `logTimeLevel( dcache, 1, $format("DCACHE : FB response", fshow(wr_stage2_fb_resp_to_core)))
      wr_resp_to_core<= wr_stage2_fb_resp_to_core;
    endrule

    rule rl_deq_ff_first_stage(wr_stage1_fb_deq || wr_stage1_deq || wr_stage1_fb_deq_enq || wr_stage1_deq_enq);
      `logTimeLevel( dcache, 1, $format("Deq by stage1_fb:%b stage1:%b wr_stage1_fb_deq_enq:%b stage1_deq_enq:%b ",
      wr_stage1_fb_deq, wr_stage1_deq, wr_stage1_fb_deq_enq, wr_stage1_deq_enq))

      ff_first_stage.deq;
      for(Integer i = 0; i<ways_val; i = i+1) begin
        ff_first_stage_tag[i].deq;
      end
    endrule

  `ifdef iclass
    rule rl_enqueue_fill_request(wr_fill_request_valid);
      let req= ff_first_stage.first;

      Bit#(TSub#(paddr,busoffset)) line_addr= req.addr[paddr_val-1:busoffset_val];
      Bit#(busoffset) zeros= 'd0;
      Bit#(paddr) mem_addr= {line_addr, zeros};

      `logTimeLevel( dcache, 1, $format("DCACHE : MSHR %d initiated a memory request for addr: %h", wr_fill_request_id, mem_addr))
      ff_read_req_to_mem.enq(Read_req_to_mem {addr: mem_addr,
                                              id: zeroExtend(wr_fill_request_id),
                                              is_burst: True,
                                              is_demand: (req.origin != Store_buffer) });

      `ifdef perfmonitors
        wr_fill_request <= 1;
        if (req.origin == Store_buffer) begin
          wr_prefetch_mshr_allocated <= 1;
        end
      `endif
    endrule

  `else // !iclass
    //TODO Accessing MSHRs when no flush is happening. Can be optimised by adding a should_flush fn
    // and removing check for index 0 in rl_flush_ff_second_stage.
    rule rl_access_MSHRs(!rg_flush.valid);
      let req= ff_second_stage.first;
      `logTimeLevel( dcache, 1, $format("DCACHE : Stage 3 req: ", fshow(req)))
      req.rob= tpl_1(cff_second_stage_rob_id.first);

      Bool deq_prev_fifo= False;
      //If valid (not flushed) request OR if (fence ongoing && a store request)
      //TODO check if fence and store is required here.
      if( cff_second_stage_valid.first || (rg_fence && req.origin==Store_buffer) ) begin  
        let mshr_resp<- mshr.allocate(req);
        if(tpl_1(mshr_resp)==Not_allocated) begin
          let new_mshr_id= tpl_2(mshr_resp);
          Bit#(TSub#(paddr,busoffset)) line_addr= req.addr[paddr_val-1:busoffset_val];
          Bit#(busoffset) zeros= 'd0;
          Bit#(paddr) mem_addr= {line_addr, zeros};
          `logTimeLevel( dcache, 1, $format("DCACHE : MSHR %d initiated a memory request for addr: %h",new_mshr_id, mem_addr))
          deq_prev_fifo= True;
          ff_read_req_to_mem.enq(Read_req_to_mem {addr: mem_addr,
                                                  id: zeroExtend(new_mshr_id),
                                                  is_burst: True });

          `ifdef perfmonitors
            wr_fill_request <= 1;
            if (req.origin == Store_buffer) begin
              wr_prefetch_mshr_allocated <= 1;
            end
          `endif
        end
        else if(tpl_1(mshr_resp)==Allocated) begin
          deq_prev_fifo= True;
          `logTimeLevel( dcache, 1, $format("DCACHE : MSHR already allocated for this req addr: %h", req.addr))
        end
  `ifdef prefetch_throttle
        else if (tpl_1(mshr_resp)==Dropped) begin
          deq_prev_fifo = True;
          `logTimeLevel( dcache, 1, $format("DCACHE : MSHR NOT allocated for prefetch req (dropped) with addr: %h", req.addr))
        end
  `endif
        else begin
          `logTimeLevel( dcache, 1, $format("DCACHE : MSHR is busy. Stalling Stage3."))
        end
      end
      else begin
        deq_prev_fifo= True;
        `logTimeLevel( dcache, 1, $format("DCACHE : Discarding ff_second_stage req: ", fshow(req)))
      end

      if(deq_prev_fifo) begin
        ff_second_stage.deq;
        cff_second_stage_rob_id.deq;
        cff_second_stage_valid.deq;
      end
    endrule
  `endif // !iclass

    rule rl_MSHR_req;
      let resp_from_mem= wr_read_resp_from_mem;
      Maybe#(Bit#(TLog#(mshrsize))) lv_id_to_mshr;
      // NOTE: can't have power-of-2 mshr size
      if(resp_from_mem.id=='1)
        lv_id_to_mshr= tagged Invalid;
      else
        lv_id_to_mshr= tagged Valid truncate(resp_from_mem.id);
      let maybe_req_from_mshr<- mshr.req_to_fb(lv_id_to_mshr);    //Receive the request from MSHR corresponding to the rid
      `logTimeLevel( dcache, 1, $format("DCACHE : Request from MSHR to FB: ", fshow(maybe_req_from_mshr)))
      //if(tpl_1(maybe_req_from_mshr)) begin
        wr_mshr_req_to_fb<= maybe_req_from_mshr;
      //end
    endrule

    rule rl_mshr_addr_to_fb;
      fill_buffer.addr_from_MSHR_to_fb(mshr.addr_to_fb);
    endrule


    //This will fire only in those clock cycles when MSHR wants to send a R/W req to FB
    //This rule polls the MSHR with the rid of memory response to know if any pending requests to that
    //rid exists in the MSHR FIFOs. Also, when there is no read response from memory, the MSHR sends
    //any requests that are pending corresponding to the current entry in the fill buffer.
    //These requests are then sent to the fill buffer to check if they were a hit (Note that there
    //can be a miss in the fill buffer if only the first chunk has arrived from the memory, but the
    //request is to data in the third chunk). If it's a hit, an ack is sent to the MSHR to dequeue
    //that FIFO entry, and send the next request. If it's a miss, no ack is sent, and in the subsequent
    //clock cycles, the same request is sent by the MSHR to the fill buffer.
    //Also, in the case of a hit, if it were a Load request or a PTW request, a response is sent.
    rule rl_MSHR_req_to_fill_buffer(wr_mshr_req_to_fb matches tagged Valid .req_from_mshr);
      //let req_from_mshr= wr_mshr_req_to_fb;
      `logTimeLevel( dcache, 1, $format("DCACHE :Sending  Request from MSHR to FB. "))
      let fb_addr= get_line_addr(req_from_mshr.addr);
      //Send the req to fill buffer and check if it's a hit
      let fill_buffer_resp<- fill_buffer.request(req_from_mshr);       //Send request to fill buffer
      `ifdef atomic
        //For an atomic operation, the request should be sent only when the line has been completely
        //loaded in the fill buffer. Until then, ack should not be sent to MSHR for the atomic req.
        if(req_from_mshr.is_atomic && !fill_buffer.can_release) begin
          fill_buffer_resp= tagged Invalid;
        end
      `endif
      if(fill_buffer_resp matches tagged Valid .fb_data) begin
        `logTimeLevel( dcache, 1, $format("DCACHE : Response data from FB to MSHR: %h", fb_data ))
        mshr.ack_from_fb;
        Bool send_resp= (req_from_mshr.origin==Load_buffer || req_from_mshr.origin==PTW
                         `ifdef atomic || req_from_mshr.is_atomic `endif );
        if(send_resp) begin
          Bit#(datawidth) data_to_core= fn_extract_data(fb_data, truncate(req_from_mshr.addr), req_from_mshr.access_size);
          // NaN Boxing for sp loads (FLW)
          if ((req_from_mshr.access_size == 3'b010) && (req_from_mshr.dest_type == FPRF)) begin
            data_to_core = data_to_core | 'hffffffff00000000;
          end
        `ifdef atomic
          if(req_from_mshr.is_atomic && (req_from_mshr.atomic_fn=='h7 || req_from_mshr.atomic_fn=='h17)) begin //SC
            data_to_core= 0;
          end
          `ifdef simulate
            let lv_atomic_result = fn_atomic_op(req_from_mshr.atomic_fn, req_from_mshr.payload, data_to_core);
          `endif
        `endif
          wr_mshr_resp_to_core<= Resp_to_core { data: data_to_core,
                                                prf_index: req_from_mshr.prf_index,
                                                rob: req_from_mshr.rob,
                                                exception: No_exception
                                                `ifdef atomic
                                                  `ifdef simulate
                                                  ,  atomic_result: lv_atomic_result
                                                  `endif
                                                `endif };
          wr_is_mshr_resp_to_core<= True;
        end
        //else do nothing
      end
      //else do nothing
      else begin
        `logTimeLevel( dcache, 1, $format("DCACHE : Data for MSHR req is not yet available in the FB" ))
      end
    endrule

    rule rl_MSHR_resp_to_core;
      `logTimeLevel( dcache, 1, $format("DCACHE : MSHR reponse", fshow(wr_mshr_resp_to_core)))
      wr_resp_to_core<= wr_mshr_resp_to_core;
    endrule
   
    //----------------------------- Fill buffer release ---------------------------------//
  `ifdef iclass // 2 cycle fb release and simple checks
    rule rl_check_ff_first_stage_req_to_fb_addr;
      let req = ff_first_stage.first;
      // store commit request matches FB line
      if ((fill_buffer.line_addr == get_line_addr(req.addr)) && (req.origin == Store_commit)) begin
        wr_ff_first_stage_req_to_curr_fb <= True;
        `logTimeLevel( dcache, 1, $format("DCACHE : ff_first_stage store req to curr FB. Req: ", fshow(req)))
      end
    endrule

    //Once the fill buffer indicates that it can be released(i.e. the complete line is available,
    //and no pending MSHR requests exist to the same line*), the data and tag SRAMs are issued a read
    //request to determine which way should be assigned for this line.
    //This rule shouldn't fire if an atomic hit happened, because atomic operation would actually be 
    //performed after one cycle, and in that one cycle, the output of the SRAMs should be held.
    // NOTE: fb release can't be initiated in a flush cycle because the cff fifos in MSHR are "busy" 
    //       during a flush and fb lookup on RAM miss will not happen => We can potentially miss a FB hit for ff_first_stage request
    rule rl_release_fb_cycle1(fill_buffer.can_release && !isValid(wr_mshr_req_to_fb) &&
    rg_fb_state==Read_SRAMs && ff_write_req_to_mem.notFull && !rg_fence && !rg_fence_wait_for_ff_first_stage_empty
    && !wr_ff_first_stage_req_to_curr_fb && !wr_stall_fb_release && !rg_flush.valid);
      Bit#(setbits) set_index= fill_buffer.line_addr[setbits_val-1:0];
      `logTimeLevel( dcache, 1, $format("DCACHE : Initiating release of FB to line address: %h", fill_buffer.line_addr))
      for(Integer i = 0;i<ways_val;i = i+1) begin
        data_arr[i].read(set_index);
        tag_arr[i].read(set_index);
      end
      rg_fb_state<= Write_SRAMs;
    endrule

    //This rule performs actions for the second cycle of fill buffer release. In this cycle, the
    //line from the fill buffer is written onto one of the ways depending on the replacement policy.
    //Also, if the existing line was a dirty line, it is written onto the eviction buffer.
    //The tag bits along with the valid and replacement bits are also updated in this cycle.
    rule rl_release_fb_cycle2(rg_fb_state==Write_SRAMs);
      let line_addr= fill_buffer.line_addr;
      Bit#(setbits) set_index= line_addr[setbits_val-1:0];
      Bit#(linewidth) dataline [ways_val];
      Bit#(tagbits) tag [ways_val];
      Bit#(ways) valid;
      Bit#(ways) dirty;

      for(Integer i = 0; i<ways_val; i = i+1) begin
        let tempdata= data_arr[i].read_response();
        dataline[i] = tempdata; 
        let temptag= tag_arr[i].read_response();
        let lv_tag_arr = temptag; 
        tag[i]= truncate(lv_tag_arr);          //Lower bits hold the value of the tags
        valid[i]= lv_tag_arr[tagbits_val];    //Valid bits
        dirty[i]= lv_tag_arr[tagbits_val+1];  //Dirty bits
      end

      //waynum indicates the way number to which the fill buffer contents will be written to.
      //The replacement bits decide the value of way num depending on the replacement policy used.
      let waynum <- repl.line_replace(set_index, valid, dirty);
      repl.update_set(set_index, waynum);  //Update the replacement bits

      let {fb_dirty,fb_data}= fill_buffer.data;
      Bit#(tagbits) lv_tag= line_addr[tagbits_val+setbits_val-1:setbits_val];
      Bit#(TAdd#(tagbits,2)) lv_dirty_valid_tag= {fb_dirty, 1'b1, lv_tag};
      data_arr[waynum].write(set_index, fb_data);
      tag_arr[waynum].write(set_index, lv_dirty_valid_tag);
      wr_tag_ram_write_valid <= 1;
      wr_tag_ram_write_index <= set_index;
      `logTimeLevel( dcache, 1, $format("DCACHE : Updating way_num: %d and set_index: %d with data: %h and tag: %h", waynum, set_index, fb_data, lv_dirty_valid_tag))

      `ifdef simulate
        for(Integer i = 0; i<ways_val; i = i+1) begin
          if (waynum != fromInteger(i)) begin // check other ways
            if ((valid[i] == 1) && (tag[i] == lv_tag)) begin
              $display($time, " PT: DCACHE: Error! Updating the same physical line with set_index %h tag %h in two different ways!", set_index, lv_tag);
              $display($time, " PT: DCACHE: Error! Update: old way %h new way %h # old dirty %b new dirty %b # old data %h new data %h", i, waynum, dirty[i], fb_dirty, dataline[i], fb_data);
              $finish(0);
              $finish(0);
            end
          end
        end
      `endif

      //Eviction buffer should be written only when there is something to evict, else skip the eviction buffer cycle
      if(valid[waynum]==1 && dirty[waynum]==1) begin
        Bit#(lineoffset) some_zeros= 0;
        Bit#(paddr) evict_lineaddr= {tag[waynum], set_index, some_zeros};
        `ifndef iclass
          rg_evict_lineaddr<= truncateLSB(evict_lineaddr);
          rg_evict_lineaddr_valid[1]<= True;
        `endif
        ff_write_req_to_mem.enq(Write_req_to_mem {addr: evict_lineaddr,
                                                  data: dataline[waynum],
                                                  is_burst: True });
        `logTimeLevel( dcache, 1, $format("DCACHE : Evicting cache line. Addr: %x Data: %x ", evict_lineaddr, dataline[waynum]))
      end
      else begin
        `logTimeLevel( dcache, 1, $format("DCACHE : Updated line is not dirty. Hence, no updation to eviction buffer"))
      end
      rg_fb_state<= Read_SRAMs;
      fill_buffer.release_fb;
      mshr.fb_released;
      `logTimeLevel( dcache, 1, $format("DCACHE : Freeing FB"))
    endrule

  `else // !iclass
    rule rl_check_ff_first_stage_req_to_fb_addr;
      let req= ff_first_stage.first;
      // TODO: check for prefetch request and drop
      // TODO: fix pending for other requests
      if((fill_buffer.line_addr == get_line_addr(req.addr)) && (req.origin == Store_commit)) begin  //Req to same line that is being filled in the FB
        wr_ff_first_stage_req_to_curr_fb<= True;
        `logTimeLevel( dcache, 1, $format("DCACHE : ff_first_stage req to curr FB. Req: ", fshow(req)))
      end
    endrule

    // NOTE: 2nd stage should stall on fill address match (150121)
    rule rl_check_ff_second_stage_req_to_fb_addr;
      let req= ff_second_stage.first;
      if(fill_buffer.line_addr == get_line_addr(req.addr)) begin  //Req to same line that is being filled in the FB
        wr_ff_second_stage_req_to_curr_fb<= True;
        `logTimeLevel( dcache, 1, $format("DCACHE : ff_second_stage req to curr FB. (FB release stall if valid) Req: ", fshow(req)))
      end
    endrule

    //Once the fill buffer indicates that it can be released(i.e. the complete line is available,
    //and no pending MSHR requests exist to the same line*), the data and tag SRAMs are issued a read
    //request to determine which way should be assigned for this line.
    //This rule shouldn't fire if an atomic hit happened, because atomic operation would actually be 
    //performed after one cycle, and in that one cycle, the output of the SRAMs should be held.
    //*Caveat: Though the FIFOs, corresponding to the MSHR entry (corresponding to the line address)
    //         might be empty, there might be a request pending in the ff_second_stage. This is fine,
    //         if it is a load req as the fill buffer is invalidated only after 3 clock cycles. For a 
    //         pending store req in ff_second_stage, stall the FB release by one cycle.
    rule rl_release_fb_cycle1(fill_buffer.can_release && !isValid(wr_mshr_req_to_fb) &&
    rg_fb_state==Read_SRAMs && ff_write_req_to_mem.notFull && !rg_fence && !rg_fence_wait_for_ff_first_stage_empty
    && !wr_ff_first_stage_req_to_curr_fb `ifndef iclass && !wr_ff_second_stage_req_to_curr_fb `endif && !wr_stall_fb_release);
      Bit#(setbits) set_index= fill_buffer.line_addr[setbits_val-1:0];
      `logTimeLevel( dcache, 1, $format("DCACHE : Initiating release of FB to line address: %h", fill_buffer.line_addr))
      for(Integer i = 0;i<ways_val;i = i+1) begin
        data_arr[i].read(set_index);
        tag_arr[i].read(set_index);
      end
      rg_fb_state<= Write_SRAMs;
    endrule

    //This rule performs actions for the second cycle of fill buffer release. In this cycle, the
    //line from the fill buffer is written onto one of the ways depending on the replacement policy.
    //Also, if the existing line was a dirty line, it is written onto the eviction buffer.
    //The tag bits along with the valid and replacement bits are also updated in this cycle.
    rule rl_release_fb_cycle2(rg_fb_state==Write_SRAMs);
      let line_addr= fill_buffer.line_addr;
      Bit#(setbits) set_index= line_addr[setbits_val-1:0];
      Bit#(linewidth) dataline [ways_val];
      Bit#(tagbits) tag [ways_val];
      Bit#(ways) valid;
      Bit#(ways) dirty;

      for(Integer i = 0; i<ways_val; i = i+1) begin
        let tempdata= data_arr[i].read_response();
        dataline[i] = tempdata; 
        let temptag= tag_arr[i].read_response();
        let lv_tag_arr = temptag; 
        tag[i]= truncate(lv_tag_arr);          //Lower bits hold the value of the tags
        valid[i]= lv_tag_arr[tagbits_val];    //Valid bits
        dirty[i]= lv_tag_arr[tagbits_val+1];  //Dirty bits
      end

      //waynum indicates the way number to which the fill buffer contents will be written to.
      //The replacement bits decide the value of way num depending on the replacement policy used.
      let waynum <- repl.line_replace(set_index, valid, dirty);
      repl.update_set(set_index, waynum);  //Update the replacement bits

      let {fb_dirty,fb_data}= fill_buffer.data;
      Bit#(tagbits) lv_tag= line_addr[tagbits_val+setbits_val-1:setbits_val];
      Bit#(TAdd#(tagbits,2)) lv_dirty_valid_tag= {fb_dirty, 1'b1, lv_tag};
      data_arr[waynum].write(set_index, fb_data);
      tag_arr[waynum].write(set_index, lv_dirty_valid_tag);
      wr_tag_ram_write_valid <= 1;
      wr_tag_ram_write_index <= set_index;
      `logTimeLevel( dcache, 1, $format("DCACHE : Updating way_num: %d and set_index: %d with data: %h and tag: %h", waynum, set_index, fb_data, lv_dirty_valid_tag))

      `ifdef simulate
        for(Integer i = 0; i<ways_val; i = i+1) begin
          if (waynum != fromInteger(i)) begin // check other ways
            if ((valid[i] == 1) && (tag[i] == lv_tag)) begin
              $display($time, " PT: DCACHE: Error! Updating the same physical line with set_index %h tag %h in two different ways!", set_index, lv_tag);
              $display($time, " PT: DCACHE: Error! Update: old way %h new way %h # old dirty %b new dirty %b # old data %h new data %h", i, waynum, dirty[i], fb_dirty, dataline[i], fb_data);
              $finish(0);
              $finish(0);
            end
          end
        end
      `endif

      //Eviction buffer should be written only when there is something to evict, else skip the eviction buffer cycle
      if(valid[waynum]==1 && dirty[waynum]==1) begin
        Bit#(lineoffset) some_zeros= 0;
        Bit#(paddr) evict_lineaddr= {tag[waynum], set_index, some_zeros};
        rg_evict_lineaddr<= truncateLSB(evict_lineaddr);
        rg_evict_lineaddr_valid[1]<= True;
        ff_write_req_to_mem.enq(Write_req_to_mem {addr: evict_lineaddr,
                                                  data: dataline[waynum],
                                                  is_burst: True });
        `logTimeLevel( dcache, 1, $format("DCACHE : Evicting cache line. Addr: %x Data: %x ", evict_lineaddr, dataline[waynum]))
      end
      else begin
        `logTimeLevel( dcache, 1, $format("DCACHE : Updated line is not dirty. Hence, no updation to eviction buffer"))
      end
      rg_fb_state<= Release_FB;
      mshr.fb_released;
    endrule

    //Releasing the fill buffer entry happens in a cycle after the tag and data arrays have been updated,
    //because in this cycle there might be a request that is pending in ff_first_stage. Therefore in the
    //cycle where this rule is getting executed, the request from ff_first_stage is serviced.
    rule rl_release_eviction_buffer(rg_fb_state==Release_FB);
      fill_buffer.release_fb;
      rg_fb_state<= Read_SRAMs;
      `logTimeLevel( dcache, 1, $format("DCACHE : Freeing FB"))
    endrule
  `endif // !iclass

    //---------------------------------------------------------------------//

    //----------------------------- Flush ---------------------------------//

    // If flush req is received, and the req is not Store_commit, and this instruction needn't be flushed
    rule rl_flush_ff_req_from_core(  (rg_flush.valid && (core_req.origin!=Store_commit) && (core_req.origin!=PTW)
                                                    && should_flush(rg_flush.head, rg_flush.flush_rob, core_req.rob))
                                   || (wr_load_drop_valid && (wr_load_drop_robid == core_req.rob)) );
      if (rg_flush.valid) begin
        `logTimeLevel( dcache, 1, $format("DCACHE : Flushing ff_req_from_core: ", fshow(core_req)))
      end
      else begin
        `logTimeLevel( dcache, 1, $format("DCACHE : Load (early) with robid %d dropped from input fifo.", core_req.rob))
        `ifdef perfmonitors
          wr_load_dropped_input <= 1;
        `endif
      end
      ff_req_from_core.deq;
    endrule

    let first_stage_req= ff_first_stage.first;
    rule rl_flush_ff_first_stage(rg_flush.valid && (first_stage_req.origin!=Store_commit) && (first_stage_req.origin!=PTW)
                                                && should_flush(rg_flush.head, rg_flush.flush_rob, first_stage_req.rob));
      `logTimeLevel( dcache, 1, $format("DCACHE : Flushing ff_first_stage: ", fshow(first_stage_req)))
      wr_stage1_deq<= True;
      `ifdef atomic
      rg_atomic_hit_info<= tagged Invalid;
      `endif
      // NOTE: No dequeue here: rl_deq_ff_first_stage handles dequeue (otherwise bsc makes that rule conditional on this rule not firing) 220221
      //ff_first_stage.deq;
      //for(Integer i = 0; i<ways_val; i = i+1) begin
      //  ff_first_stage_tag[i].deq;
      //end
    endrule

  `ifdef iclass
    rule rl_flush_mshr(rg_flush.valid);
      mshr.flush(rg_flush);
    endrule

  `else // !iclass
    //This rule resets the valid bit of rg_flush after a flush request is initiated.
    //If ff_second_stage is empty, flush is over. Hence, reset valid bit of rg_flush
    (*no_implicit_conditions, fire_when_enabled*)
    rule rl_flush_ff_second_stage(rg_flush.valid);
      Vector#(1,Bool) valid= cff_second_stage_valid.contents;
      Vector#(1,Tuple2#(Bit#(rob_index), Bool)) meta= cff_second_stage_rob_id.contents;

      if(should_flush(rg_flush.head, rg_flush.flush_rob, tpl_1(meta[0])) && valid[0] && tpl_2(meta[0]))
        valid[0]= False;
      //if(should_flush(rg_flush.head, rg_flush.flush_rob, tpl_1(meta[1])) && valid[1] && tpl_2(meta[1]))
      //  valid[1]= False;

      cff_second_stage_valid.initialize(valid);
      `logTimeLevel( dcache, 1, $format("DCACHE : Flushing everything! meta0: 'h%h old_valid: %b new_valid: %b", pack(meta[0]), pack(cff_second_stage_valid.contents), valid ))
      //`logLevel( dcache, 1, $format("DCACHE : Flushing everything! meta1: 'h%h meta0: 'h%h old_valid: %b new_valid: %b", pack(meta[1]), pack(meta[0]), pack(cff_second_stage_valid.contents), valid ))
      mshr.flush(rg_flush);
    endrule
  `endif // !iclass

    //---------------------------------------------------------------------//

    //----------------------------- Fence ---------------------------------//

    //Wait for ff_first_stage to get empty so that once fence is received from the core, the response 
    //of ff_first_stage req is not sent to the processor.
    //Also, wait if FB is updating the caches.
    rule rl_fence_wait_for_ff_first_stage_empty(rg_fence_wait_for_ff_first_stage_empty && !rg_fence
    && !ff_first_stage.notEmpty && rg_fb_state==Read_SRAMs);
      rg_fence<= True;
      rg_fence_state <= 'h0;
      rg_fence_wait_for_ff_first_stage_empty<= False;
    endrule

    //This rule fires whent the fill buffer is ready to be released.
    //Also, rg_fb_state should be Read_SRAMs because when a new fence is initiated, if fill buffer is
    //in Write_SRAMs state, the fence should begin only after the current fb entry is written to the cache.
    //TODO Moreover, the fb contents need to be written to the next level of memory only if the line is dirty
    //rule rl_fence_fb (rg_fence && fill_buffer.can_release && rg_fb_state==Read_SRAMs && tpl_1(fill_buffer.data)==1
    //&& !isValid(wr_mshr_req_to_fb));
    // NOTE: Changing rule below (rule and eviction condition) to release fb and free mshr even if the line is not dirty.
    // Otherwise, the fence may not "complete" after fencing cache sets. This can happen if ptw or prefetch requests are
    // waiting in the mshr.
`ifndef iclass
    rule rl_fence_fb (rg_fence && fill_buffer.can_release && rg_fb_state==Read_SRAMs && !isValid(wr_mshr_req_to_fb));
      let data= tpl_2(fill_buffer.data);
      let line_addr= fill_buffer.line_addr;
      Bit#(setbits) set_index= line_addr[setbits_val-1:0];
      Bit#(tagbits) tag= line_addr[tagbits_val+setbits_val-1:setbits_val];
      Bit#(lineoffset) some_zeros= 0;
      Bit#(paddr) evict_lineaddr= {tag, set_index, some_zeros};

      // send to eviction buffer if the line is dirty
      if (tpl_1(fill_buffer.data)==1) begin
        rg_evict_lineaddr<= truncateLSB(evict_lineaddr);
        rg_evict_lineaddr_valid[1]<= True;
        ff_write_req_to_mem.enq(Write_req_to_mem {addr: evict_lineaddr,
                                                  data: data,
                                                  is_burst: True });
        `logTimeLevel( dcache, 1, $format("DCACHE : Fence. Fill buffer writing to mem. Addr: %x Data: %x ", evict_lineaddr, data))
      end
      else begin
        `logTimeLevel( dcache, 1, $format("DCACHE : Fence. Fill buffer released and MSHR freed (clean line). Addr: %x Data: %x ", evict_lineaddr, data))
      end

      //The fill buffer entry can be released once the req has been enqueued in ff_write_req_to_mem.
      //We need not wait for the write response for the fence to proceed, as whenever write response
      //is received, it is automatically dequeued from the FIFO and discarded.
      //The MSHR should also be acknowledged about the FB entry release so that it can free-up the
      //MSHR entry.
      mshr.fb_released;
      rg_fence_fb_release<= True;
    endrule

    rule rl_fence_fb_release(rg_fence && rg_fence_fb_release);
      fill_buffer.release_fb;
    endrule
`endif // !iclass

    //Invalidating the evict lineaddr whenever eviction buffer is emptied. The cache is stalled
    //in the first stage till then.
    //TODO can optimize this to stall in second stage so that cache can still respond to hits.
    //Since the write resp from memory will never cause a fault, this is fine.
    //This will not work once you change eviction buffer to a multi-entry buffer.
    //  Moving back to conservative dequeue => no invalidation needed
    //  Invalidation check is on fifo empty and write response but the enqueue rules do not 
    //  check for line address valid => wrong, because another enqueue can happen in the fifo before write response arrives
    //  and the register data only stores one line address (and valid) at a time => eviction addr match check is incomplete!
`ifndef iclass
    rule rl_invalidate_evict_lineaddr(!ff_write_req_to_mem.notEmpty && wr_write_resp_from_mem);
      rg_evict_lineaddr_valid[0]<= False;
    endrule
`endif

`ifdef iclass
    rule rl_print_rg_wait;
        `logTimeLevel( dcache, 1, $format("DCACHE : Status: rg_write_resp_from_mem %b rg_wait_for_write_response %b", rg_write_resp_from_mem, rg_wait_for_write_response))
    endrule

    // Conservative timing: only in the next cycle, the fifo is available and we are not waiting for response
    // TODO: optimize for multi-entry eviction buffer/back-to-back writes
    rule rl_dequeue_eviction_buffer(rg_write_resp_from_mem);
        ff_write_req_to_mem.deq;
        rg_wait_for_write_response <= False;
        `logTimeLevel( dcache, 1, $format("DCACHE : Dequeueing eviction buffer, setting rg_wait to false"))
    endrule
`endif

    //TODO To reduce one cycle per dirty set, implement this function to check if exactly one dirty way exists
    function Bool check_only_one_evict(Bit#(ways) evict);
      return False;
    endfunction

    //rule rl_disp_fence_cache (rg_fence && rg_SRAM_fence[0] && rg_cache_busy && rg_fb_state==Read_SRAMs && rg_fence_set_index=='d23);
    //  Bit#(linewidth) dataline [ways_val];
    //  Bit#(TAdd#(tagbits,2)) tag [ways_val];
    //  Bit#(ways) dirty=0;
    //  Bit#(ways) valid=0;
    //  for(Integer i = 0; i<ways_val; i = i+1) begin
    //    dataline[i]= data_arr[i].read_response;
    //    tag[i]= tag_arr[i].read_response;
    //    `logLevel( dcache, 1, $format("DCACHE : Data[%d]: %d and Tag [%d]: %d ", i, dataline[i], i, tag[i]))
    //  end
    //  for(Integer i = 0; i<ways_val; i = i+1) begin
    //    valid[i]= tag[i][tagbits_val];    //Valid bit
    //    dirty[i]= tag[i][tagbits_val+1];  //Dirty bit
    //    `logLevel( dcache, 1, $format("DCACHE : Dirty and Valid [%d]: %d%d", i, dirty[i], valid[i]))
    //  end
    //endrule

    // Fixed rl_fence_cache for BRAM version; earlier version commented below (180621)
    rule rl_fence_cache (rg_fence && rg_SRAM_fence[0] && rg_cache_busy && rg_fb_state==Read_SRAMs);
      Bit#(linewidth) dataline [ways_val];
      Bit#(TAdd#(tagbits,2)) tag [ways_val];
      Bit#(ways) dirty=0;
      Bit#(ways) valid=0;
      Bool lv_evict= False;
      Bit#(TLog#(ways)) evict_index= 0;

      // read next set; only one read per set
      if (rg_fence_state == 'h0) begin
        //Issue read request to the set which will be processed in the next cycle.
        for (Integer i = 0;i<ways_val;i = i+1) begin
          data_arr[i].read(rg_fence_set_index);
          tag_arr[i].read(rg_fence_set_index);
        end

        // next state
        rg_fence_state <= 'h1;
      end // state = 0

      // read response for this set; register data, tag, valid & dirty
      // conservative (slow fence): no checks and valid/dirty resets this cycle
      else if (rg_fence_state == 'h1) begin
        `logTimeLevel( dcache, 1, $format("DCACHE : Fencing set: %d", rg_fence_set_index))

        for (Integer i = 0; i<ways_val; i = i+1) begin
          dataline[i] = data_arr[i].read_response;
          tag[i] = tag_arr[i].read_response;
          rg_fdataline[i] <= dataline[i];
          rg_ftag[i] <= tag[i];
          `logLevel( dcache, 3, $format("DCACHE : Data[%d]: %h and Tag [%d]: %h ", i, dataline[i], i, tag[i]))
        end

        for (Integer i = 0; i<ways_val; i = i+1) begin
          valid[i] = tag[i][tagbits_val];    //Valid bit
          dirty[i] = tag[i][tagbits_val+1];  //Dirty bit
          rg_fvalid[i] <= valid[i];
          rg_fdirty[i] <= dirty[i];
          `logLevel( dcache, 3, $format("DCACHE : Dirty and Valid [%d]: %d%d", i, dirty[i], valid[i]))
        end

        // next state
        rg_fence_state <= 'h2;
      end // state = 1

      // read from registered data, tag, valid & dirty
      // check valid & dirty lines and write to next lower level: state 2
      else if (rg_fence_state == 'h2) begin
        for (Integer i = 0; i<ways_val; i = i+1) begin
          dataline[i] = rg_fdataline[i];
          tag[i] = rg_ftag[i];
          valid[i] = rg_fvalid[i];
          dirty[i] = rg_fdirty[i];

          `logLevel( dcache, 3, $format("DCACHE : Dirty and Valid [%d]: %d%d", i, rg_fdirty[i], rg_fvalid[i]))
        end // for

        // check valid & dirty
        for (Integer i = 0; i<ways_val; i = i+1) begin
          if(rg_fvalid[i]==1 && rg_fdirty[i]==1) begin
            lv_evict=True;
            evict_index= fromInteger(i);
          end
        end

        if(lv_evict) begin
          Bit#(lineoffset) some_zeros= 0;
          Bit#(tagbits) evict_tag= truncate(tag[evict_index]);
          Bit#(paddr) evict_lineaddr= {evict_tag, rg_fence_set_index, some_zeros};
          Bit#(TAdd#(tagbits,2)) lv_dirty_valid_tag= {1'b1, 1'b0, evict_tag};

          //Updating only the valid bit of the SRAM in order to save power.
          tag_arr[evict_index].write(rg_fence_set_index, lv_dirty_valid_tag);

          //Evicting the line
          ff_write_req_to_mem.enq(Write_req_to_mem {addr: evict_lineaddr,
                                                    data: dataline[evict_index],
                                                    is_burst: True });
          `logLevel( dcache, 3, $format("DCACHE : Fence. Cache writing to mem. Way: %d Addr: %x Data: %x ", evict_index, evict_lineaddr, dataline[evict_index]))
          `logLevel( dcache, 3, $format("DCACHE : Fence. Updating index: %d way: %d with tag: %x ", rg_fence_set_index, evict_index, lv_dirty_valid_tag))

          // reset valid and dirty
          rg_fvalid[evict_index] <= 0;
          rg_fdirty[evict_index] <= 0;

          Bit#(ways) evict_indices;
          for (Integer i=0; i<ways_val; i=i+1) begin
            evict_indices[i] = rg_fvalid[i] & rg_fdirty[i];
          end
          Bool only_one_dirty= check_only_one_evict(evict_indices);

          if(only_one_dirty) begin
            // increment set and go back to state 0 for next read
            rg_fence_set_index <= rg_fence_set_index + 1;
            rg_fence_state <= 0;
            `logLevel( dcache, 3, $format("DCACHE : Fence. Incrementing fence index "))

            // check if last set is done
            if(rg_fence_set_index=='1) begin
              rg_SRAM_fence[0]<= False;
              `logTimeLevel( dcache, 1, $format("DCACHE : Fence. Last SRAM row done. "))
            end
          end
        end
        else begin  //Nothing to evict. Hence, increment fence index and clear the valid bit of all ways in this set
          for(Integer i = 0; i<ways_val; i = i+1) begin
            tag_arr[i].write(rg_fence_set_index, 0);
          end
          // increment set and go back to state 0 for next read
          rg_fence_set_index <= rg_fence_set_index + 1;
          rg_fence_state <= 0;
          `logLevel( dcache, 3, $format("DCACHE : Fence. Incrementing fence index "))

          // check if last set is done
          if(rg_fence_set_index=='1) begin
            rg_SRAM_fence[0]<= False;
            `logTimeLevel( dcache, 1, $format("DCACHE : Fence. Last SRAM row done. "))
          end
        end
      end // state = 2
    endrule

//    // Note: this fence rule is good only for "regfile + added latency" version of cache arrays
//    rule rl_fence_cache (rg_fence && rg_SRAM_fence[0] && rg_cache_busy && rg_fb_state==Read_SRAMs);
//      Bit#(linewidth) dataline [ways_val];
//      Bit#(TAdd#(tagbits,2)) tag [ways_val];
//      Bit#(ways) dirty=0;
//      Bit#(ways) valid=0;
//      Bool incr_fence_set_index= False;
//      Bool lv_evict= False;
//      Bit#(TLog#(ways)) evict_index= 0;
//      `logLevel( dcache, 1, $format("DCACHE : Fencing set: %d", rg_fence_set_index))
//
//      for(Integer i = 0; i<ways_val; i = i+1) begin
//        dataline[i]= data_arr[i].read_response;
//        tag[i]= tag_arr[i].read_response;
//        `logLevel( dcache, 3, $format("DCACHE : Data[%d]: %h and Tag [%d]: %h ", i, dataline[i], i, tag[i]))
//      end
//      for(Integer i = 0; i<ways_val; i = i+1) begin
//        valid[i]= tag[i][tagbits_val];    //Valid bit
//        dirty[i]= tag[i][tagbits_val+1];  //Dirty bit
//        `logLevel( dcache, 3, $format("DCACHE : Dirty and Valid [%d]: %d%d", i, dirty[i], valid[i]))
//        if(valid[i]==1 && dirty[i]==1) begin
//          lv_evict=True;
//          evict_index= fromInteger(i);
//        end
//      end
//
//      if(lv_evict) begin
//        Bit#(lineoffset) some_zeros= 0;
//        Bit#(tagbits) evict_tag= truncate(tag[evict_index]);
//        Bit#(paddr) evict_lineaddr= {evict_tag, rg_fence_set_index, some_zeros};
//        Bit#(TAdd#(tagbits,2)) lv_dirty_valid_tag= {1'b1, 1'b0, evict_tag};
//
//        //Updating only the valid bit of the SRAM in order to save power.
//        tag_arr[evict_index].write(rg_fence_set_index, lv_dirty_valid_tag);
//
//        //Evicting the line
//        ff_write_req_to_mem.enq(Write_req_to_mem {addr: evict_lineaddr,
//                                                  data: dataline[evict_index],
//                                                  is_burst: True });
//        `logLevel( dcache, 3, $format("DCACHE : Fence. Cache writing to mem. Way: %d Addr: %x Data: %x ", evict_index, evict_lineaddr, dataline[evict_index]))
//        `logLevel( dcache, 3, $format("DCACHE : Fence. Updating index: %d way: %d with tag: %x ", rg_fence_set_index, evict_index, lv_dirty_valid_tag))
//
//        Bit#(ways) evict_indices= valid & dirty;
//        Bool only_one_dirty= check_only_one_evict(evict_indices);
//        if(only_one_dirty) begin
//          incr_fence_set_index= True;
//        end
//        //else fence_set_index remains unchanged so that rest of the dirty lines in this set get evicted.
//      end
//      else begin  //Nothing to evict. Hence, increment fence index and clear the valid bit of all ways in this set
//        incr_fence_set_index= True;
//        for(Integer i = 0; i<ways_val; i = i+1) begin
//          tag_arr[i].write(rg_fence_set_index, 0);
//        end
//      end
//
//      Bit#(setbits) lv_next_set_index= rg_fence_set_index;
//      //TODO should this if condition be inside if(incr_fence_set_index)?
//      if(incr_fence_set_index) begin
//        lv_next_set_index= rg_fence_set_index + 1;
//        `logLevel( dcache, 3, $format("DCACHE : Fence. Incrementing fence index "))
//        if(rg_fence_set_index=='1) begin
//          rg_SRAM_fence[0]<= False;
//          `logLevel( dcache, 1, $format("DCACHE : Fence. Last SRAM row done. "))
//        end
//      end
//
//      //Issue read request to the set which will be processed in the next cycle.
//      for(Integer i = 0;i<ways_val;i = i+1) begin
//        data_arr[i].read(lv_next_set_index);
//        tag_arr[i].read(lv_next_set_index);
//      end
//      rg_fence_set_index<= lv_next_set_index;
//    endrule

    //This rule will fire once fence operation has finished. The rg_fence register indicates that
    //a fence operation is ongoing. !rg_SRAM_fence indicates that all entries in the SRAM have
    //finished fencing. !mshr.no_empty indicates that there are no pending requests in the MSHR.
    //!rg_io_req_sent indicates that there are no pending IO responses.
    //rg_io_req_sent indicates that an IO request has been sent. In this implementation, we wait for
    //the IO response before finishing fence operation. Though this can be avoided, currently it is 
    //required as both, this rule, and rule rl_receive_IO_resp write into wr_resp_to_core.
    //Also, the fill buffer need NOT be checked as if there are any entries in the fill buffer,
    //mshr will not be empty. Moreover, the pending responses for the write requests that were
    //issued from the fill buffer will automatically be received (even after fence is done) and 
    //discarded.

    rule rl_disp1(rg_fence && !rg_SRAM_fence[0]);
      `logTimeLevel( dcache, 1, $format("DCACHE : Fence SRAM done. mshr.not_empty: %b rg_io_req_sent: %b ", mshr.not_empty, rg_io_req_sent))
    endrule

    rule rl_SRAM_and_MSHR_done_fencing(rg_fence && !rg_SRAM_fence[0] && !mshr.not_empty && !rg_io_req_sent);
      rg_cache_busy<= False;
      rg_fence<= False;
      rg_fence_set_index<= 0;
      `ifdef atomic
        rg_lr_info<= tuple3(False, ?, ?);
        rg_sc_fail<= False;
      `endif

      wr_resp_to_core<= Resp_to_core { data: ?,
                                       prf_index: ?,
                                       rob: rg_fence_rob,
                                       exception: No_exception
                                       `ifdef atomic
                                         `ifdef simulate
                                         ,  atomic_result: 0
                                         `endif
                                       `endif };
      `logTimeLevel( dcache, 1, $format("DCACHE : Fencing done. "))
    endrule

    rule rl_send_io_request(!rg_io_req_sent && !rg_fence); //TODO should this rule have !rg_fence?
      let req= ff_io_info.first;
      ff_io_req.enq(IO_Req { addr: req.addr,
                             size: {1'b0, req.access_size[1:0]},
                             is_store: (req.origin==Store_commit),
                             data: req.data });
      rg_io_req_sent<= True;
    endrule

    //Currently, once an IO request is obtained, rg_cache_busy is asserted. This can be optimised in 
    //the future versions
    rule rl_receive_IO_resp(rg_cache_busy && rg_io_req_sent);
      let req= ff_io_info.first;
      let resp= ff_io_resp.first;
      ff_io_resp.deq;
      ff_io_info.deq;
      `logTimeLevel( dcache, 1, $format("DCACHE : IO Resp: ", fshow(ff_io_resp.first)))
      //In this implementation, the fence finishes only after receiving any pending IO responses.
      //Hence, if an IO response is received in the middle of a fence request, rg_cache_busy should
      //remain True until the fence operation is over.
      if(!rg_fence) begin
        rg_cache_busy<= False;
      end
      rg_io_req_sent<= False;

      // on a correct response, format load data as required by core
      if ((req.origin == Load_buffer) && (resp.exception==defaultValue)) begin
        if (req.access_size[1:0] == 2'b00) begin
          resp.data = (req.access_size[2] == 0) ? signExtend(resp.data[7:0]) : zeroExtend(resp.data[7:0]);
        end
        else if (req.access_size[1:0] == 2'b01) begin
          resp.data = (req.access_size[2] == 0) ? signExtend(resp.data[15:0]) : zeroExtend(resp.data[15:0]);
        end
        else if (req.access_size[1:0] == 2'b10) begin
          resp.data = (req.access_size[2] == 0) ? signExtend(resp.data[31:0]) : zeroExtend(resp.data[31:0]);
        end
        else if (req.access_size[1:0] == 2'b11) begin
          // ld/sd do nothing
        end
      end // load and !exception
      wr_resp_to_core<= Resp_to_core { data: resp.exception==defaultValue ? resp.data: zeroExtend(tpl_4(rg_access_fault_response)),
                                       prf_index: ff_io_info.first.prf_index,
                                       rob: ff_io_info.first.rob,
                                       exception: resp.exception
                                       `ifdef atomic
                                         `ifdef simulate
                                         ,  atomic_result: 0
                                         `endif
                                       `endif };
    endrule

`ifdef pref
    rule rl_fill_response_to_prefetch;
      if (wr_read_resp_from_mem.id != '1) begin  // valid mem response
        if (fill_buffer.first_response_from_mem()) begin // response for first chunk
          Origin lv_origin = mshr.mshr_primary_request(truncate(wr_read_resp_from_mem.id));
          rg_fill_response_valid <= 1;
          rg_fill_response_demand <= pack(lv_origin != Store_buffer);
          rg_fill_response_address <= mshr.addr_to_fb();
        end
      end
    endrule
`endif

`ifdef simulate
  `ifdef fesvr_sim
    `ifndef baremetal_sim
        rule rl_debug_print00;
          wr_debug_print <= rg_debug_print;
        endrule

        rule rl_debug_print01 (wr_debug_print == 1);
          $display($time, " PT: DCACHE: ========================== No progress ==========================");

          $display($time, " PT: DCACHE: Core_req: valid %b", ff_req_from_core.notEmpty);
          $display($time, " PT: DCACHE: first_stage latch: valid %b", ff_first_stage.notEmpty);
          //$display($time, " PT: DCACHE: second_stage latch: valid %b", ff_second_stage.notEmpty);
        endrule

        rule rl_debug_print02 (wr_debug_print == 1);
          let req = ff_req_from_core.first;
          $display($time, " PT: DCACHE: Core_req: origin %d robid %d addr %h", pack(req.origin), req.rob, req.addr);
        endrule

        rule rl_debug_print03 (wr_debug_print == 1);
          let req = ff_first_stage.first;
          $display($time, " PT: DCACHE: first_stage latch: origin %d robid %d addr %h", pack(req.origin), req.rob, req.addr);
        endrule

        //rule rl_debug_print04 (wr_debug_print == 1);
        //    let req = ff_second_stage.first;
        //    $display($time, " PT: DCACHE: second_stage latch: origin %d addr %h", pack(req.origin), req.addr);
        //endrule

        rule rl_debug_print05 (wr_debug_print == 1);
          $display($time, " PT: DCACHE: previous_request: valid %b addr %h", tpl_1(rg_prev_req_info), tpl_2(rg_prev_req_info));
        endrule

        rule rl_debug_print06 (wr_debug_print == 1);
          $display($time, " PT: DCACHE: load_drop: valid %b robid %d", wr_load_drop_valid, wr_load_drop_robid);
        endrule

        rule rl_debug_print07 (wr_debug_print == 1);
          $display($time, " PT: DCACHE: rg_page_fault: valid %b # rg_leaf_page_response: valid %b", rg_page_fault, rg_leaf_page_response);
        endrule

        rule rl_debug_print08 (wr_debug_print == 1);
          $display($time, " PT: DCACHE: FB: state %d addr %h can_release %d", pack(rg_fb_state), fill_buffer.line_addr, fill_buffer.can_release);
        endrule

        rule rl_debug_print09 (wr_debug_print == 1);
          $display($time, " PT: DCACHE: first_stage polling FB: valid %b", wr_ff_first_stage_req_to_curr_fb);
        endrule

        //rule rl_debug_print10 (wr_debug_print == 1);
        //  $display($time, " PT: DCACHE: second_stage polling FB: valid %b", wr_ff_second_stage_req_to_curr_fb);
        //endrule

        rule rl_debug_print11 (wr_debug_print == 1);
          $display($time, " PT: DCACHE: MSHR polling FB: valid %b", isValid(wr_mshr_req_to_fb));
        endrule

        rule rl_debug_print12 (wr_debug_print == 1);
          if (wr_mshr_req_to_fb matches tagged Valid .req) begin
            $display($time, " PT: DCACHE: MSHR request: origin %d addr %h", pack(req.origin), req.addr);
          end
        endrule

        rule rl_debug_print13 (wr_debug_print == 1);
          $display($time, " PT: DCACHE: MSHR state: empty %d entries_full %d one_fifo_full %d", !mshr.not_empty, mshr.entries_full, mshr.one_fifo_full);
          mshr.debug_print();
          $display($time, " PT: DCACHE: =================================================================");
        endrule
    `endif
  `endif
`endif // simulate


    interface subifc_req_from_core = interface Put
      method Action put(Req_from_core#(vaddr, datawidth, rob_index, prf_index, lsq_index) core_req);
        `ifdef iclass // single pipeline latch between lsu and cache
            `logTimeLevel( dcache, 1, $format("DCACHE : Core request with robid %d enqueued.", core_req.rob))
            ff_req_from_core.enq(core_req);
        `else
          // TODO: change conditions here if bypass fifo is replaced with a wire
          if (   (rg_flush.valid && (core_req.origin != Store_commit) && (core_req.origin != PTW)
                                 && should_flush(rg_flush.head, rg_flush.flush_rob, core_req.rob))
              || (wr_load_drop_valid && (wr_load_drop_robid == core_req.rob)) ) begin
            if (rg_flush.valid) begin
              `logTimeLevel( dcache, 1, $format("DCACHE : Core request dropped: in flush range ", fshow(core_req)))
            end
            else begin
              `logTimeLevel( dcache, 1, $format("DCACHE : Core request dropped: load (early) with robid %d", core_req.rob))
            end
          end // flush or drop
          else begin
            `logTimeLevel( dcache, 1, $format("DCACHE : Core request with robid %d enqueued.", core_req.rob))
            ff_req_from_core.enq(core_req);
          end
        `endif
      endmethod
    endinterface;

    interface subifc_resp_to_core= interface Get
      // NOTE: flushing the response is handled in core (instead of checking here for non-store, non-ptw)
      //       was: if(!rg_fence_wait_for_ff_first_stage_empty && (!rg_flush.valid || !((wr_resp_to_core.rob != '1) && should_flush(rg_flush.head, rg_flush.flush_rob, wr_resp_to_core.rob)) ));
      // If supervisor is supported, do not drop PTW responses
      method ActionValue#(Resp_to_core#(TMul#(wordsize,8), prf_index, rob_index)) get `ifndef supervisor if(!rg_fence_wait_for_ff_first_stage_empty) `endif ;
        `logTimeLevel( dcache, 1, $format("DCACHE : Response to core: ", fshow(wr_resp_to_core)))
        return wr_resp_to_core;
      endmethod
    endinterface;

    `ifdef store_early_ack
    interface subifc_early_resp_to_core = interface Get
      method ActionValue#(Tuple2#(Bit#(1), Resp_to_core#(TMul#(wordsize,8), prf_index, rob_index))) get;
        return tuple2(wr_early_resp_to_core_valid, wr_early_resp_to_core);
      endmethod
    endinterface;
    `endif

    interface subifc_ptw_meta= dtlb.ptw_meta;
`ifdef supervisor
    interface subifc_req_to_ptw= toGet(wr_req_to_ptw);
    interface subifc_response_frm_ptw = interface Put
      method Action put(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) resp);
        // TODO: page fault response to core via dcache/dtlb
        rg_page_fault <= resp.trap;
        rg_leaf_page_response <= !resp.trap;
        dtlb.response_frm_ptw.put(resp);
      endmethod
    endinterface;
`endif
    interface subifc_read_req_to_mem= toGet(ff_read_req_to_mem);

    interface subifc_read_resp_from_mem= interface Put
      method Action put(Read_resp_from_mem#(buswidth, id_bits) resp);
        wr_read_resp_from_mem<= resp;
        `logTimeLevel( dcache, 1, $format("DCACHE : Read response from mem: ", fshow(resp)))
        let mem_req_offset= mshr.mem_req_offset(truncate(resp.id));
        fill_buffer.data_from_mem(resp.data, resp.last, mem_req_offset);
      endmethod
    endinterface;

    //interface subifc_write_req_to_mem= toGet(ff_write_req_to_mem);
    // NOTE: conservative dequeue (on write response) of eviction fifo to track conflicting addresses cleanly
    //       method is conditional on not waiting for response (as fifo still holds the request) 
    // TODO: multi-entry eviction fifo
    interface subifc_write_req_to_mem = interface Get
      method ActionValue#(Write_req_to_mem#(paddr, TMul#(TMul#(wordsize,8), linesize))) get() if (!rg_wait_for_write_response);
        let lv_req = ff_write_req_to_mem.first;
        `logTimeLevel( dcache, 1, $format("DCACHE : Sending write request to mem: ", fshow(lv_req)))
        rg_wait_for_write_response <= True;
        return lv_req;
      endmethod
    endinterface;

    interface subifc_write_resp_from_mem= interface Put
      method Action put(Bool resp);
`ifdef iclass
        rg_write_resp_from_mem<= resp;
        `logTimeLevel( dcache, 1, $format("DCACHE : Receiving write response from mem: %b", resp))
`else
        wr_write_resp_from_mem<= resp;
        rg_evict_lineaddr_valid[0] <= False;
`endif
        // TODO: retry/nack for failed response
        `ifdef ASSERT
          dynamicAssert(resp, "Write request to memory failed (error response).");
        `endif
      endmethod
    endinterface;

    interface subifc_IO_req= toGet(ff_io_req);
    interface subifc_IO_resp= toPut(ff_io_resp);

    //Cache is busy if a PTW is ongoing, or, for a failed atomic op for one cycle, OR cache is full 
    method Bool cache_busy;
      return (rg_cache_busy || !ff_req_from_core.notFull);
    endmethod

    method Action flush(Bit#(rob_index) head, Bit#(rob_index) flush_rob);
      let flush_signal= Flush_type {valid: True,
                                    head: head,
                                    flush_rob: flush_rob };
      rg_flush<= flush_signal;
      `logTimeLevel( dcache, 1, $format("DCACHE : Flush generated: ", fshow(flush_signal)))
    endmethod

    method Action load_drop(Bit#(rob_index) load_rob);
      wr_load_drop_valid <= True;
      wr_load_drop_robid <= load_rob;
      `logTimeLevel( dcache, 1, $format("DCACHE : Load (early) drop received for rob_id %d", load_rob))
    endmethod

`ifdef supervisor
    method Tuple3#(Bit#(1), Bit#(1), Bit#(1)) dtlb_early_lookup(Bit#(vaddr) vaddr, Bit#(1) is_store);
      return dtlb.early_lookup(vaddr, is_store);
    endmethod
`endif // supervisor

`ifdef pref
    method Tuple3#(Bit#(1), Bit#(1), Bit#(TSub#(paddr, TAdd#(TLog#(wordsize), TLog#(linesize))))) fill_response_info();
      return tuple3(rg_fill_response_valid, rg_fill_response_demand, rg_fill_response_address);
    endmethod
`endif // prefetch

`ifdef perfmonitors
    method DCACHE_cntrs mv_dcache_perf_counters();
      DCACHE_cntrs lv_ctr = unpack(0);
      lv_ctr.request_total = wr_request_total;
      lv_ctr.request_io = wr_request_io;
      lv_ctr.request_fence = wr_request_fence;
      lv_ctr.load_hit_cache = wr_load_hit_cache;
      lv_ctr.store_hit_cache = wr_store_hit_cache;
      lv_ctr.ptw_hit_cache = wr_ptw_hit_cache;
      lv_ctr.load_hit_lfb = wr_load_hit_lfb;
      lv_ctr.store_hit_lfb = wr_store_hit_lfb;
      lv_ctr.ptw_hit_lfb = wr_ptw_hit_lfb;
      lv_ctr.load_dropped_input = wr_load_dropped_input;
      lv_ctr.load_dropped_stage1 = wr_load_dropped_stage1;
      lv_ctr.fill_request = wr_fill_request;
      lv_ctr.prefetch_mshr_allocated = wr_prefetch_mshr_allocated;
      lv_ctr.dtlb_miss = wr_dtlb_miss;

      return lv_ctr;
    endmethod
`endif

`ifdef simulate
  `ifdef fesvr_sim
    `ifndef baremetal_sim
        method Action debug_print();
          rg_debug_print <= 1;
        endmethod
    `endif
  `endif
`endif // simulate

  endmodule

  (*synthesize*)
  module mkdcache(Ifc_nbdcache#(`Wordsize, `Linesize, `Setsize, `Ways, `Paddr, `Vaddr, `Dsram, `Tsram, `ifdef split_prf TAdd#(1,TLog#(`num_prfs_max)) `else TLog#(`num_prfs) `endif , `Id_bits, `Mshrsize, `Mshrfifo_depth, `Buswidth, TLog#(`rob_size), TLog#(`L_buf_size)));
    let ifc();
    mknb_dcache#("PLRU") _temp(ifc);
    return (ifc);
  endmodule

  //(*synthesize*)
  //module mknb_dcache_instance(Ifc_nbdcache#(8, 8, 64, 4, 32, 49, 32, 32, 7, 4, 5, 7, 128, 7));
  //  let ifc();
  //  mknb_dcache#("PLRU") _temp(ifc);
  //  return (ifc);
  //endmodule
endpackage
