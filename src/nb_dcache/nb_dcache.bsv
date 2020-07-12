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

Author: Arjun Menon
Email id: c.arjunmenon@gmail.com
Details: Refer the design doc.

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
  `include "parameters.txt"
//  `include "parameters.bsv"
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
                          numeric type rob_index);      //Log of number of ROB entries
    interface Put#(Req_from_core#(vaddr, TMul#(wordsize,8), rob_index, prf_index))  subifc_req_from_core;
    interface Get#(Resp_to_core#(TMul#(wordsize,8), prf_index, rob_index))           subifc_resp_to_core;
    interface Get#(Req_from_core#(vaddr, TMul#(wordsize,8), rob_index, prf_index))  subifc_req_to_ptw;
    interface Ifc_ptw_meta#(vaddr)                                                  subifc_ptw_meta;
    interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages))             subifc_response_frm_ptw;
    interface Get#(Read_req_to_mem#(paddr, id_bits))                                 subifc_read_req_to_mem;
    interface Put#(Read_resp_from_mem#(buswidth, id_bits))                           subifc_read_resp_from_mem;
    interface Get#(Write_req_to_mem#(paddr, TMul#(TMul#(wordsize,8), linesize)))     subifc_write_req_to_mem;
    interface Put#(Bool)                                                             subifc_write_resp_from_mem;
    interface Get#(IO_Req#(paddr, TMul#(wordsize,8)))                                 subifc_IO_req;
    interface Put#(IO_Resp#(TMul#(wordsize,8)))                                     subifc_IO_resp;
    method Action flush(Bit#(rob_index) head, Bit#(rob_index) flush_rob);
    method Bool cache_busy;
  endinterface

  (*preempts = "rl_MSHR_req_to_fill_buffer, rl_stage2_req_to_fb"*)
  (*preempts = "rl_MSHR_resp_to_core, rl_stage2_fb_resp_to_core"*)
  (*preempts = "rl_MSHR_resp_to_core, rl_sram_resp_to_core"*)
  (*conflict_free = "rl_stage2_fb_resp_to_core, rl_sram_resp_to_core"*)
  (*execution_order = "rl_tag_and_data_array_read_response, rl_stage2_req_to_fb"*)
  (*preempts = "rl_release_fb_cycle1, rl_handle_req_from_core"*)
  (*conflict_free = "rl_release_fb_cycle2, rl_tag_and_data_array_read_response"*)
  `ifdef atomic
    (*conflict_free = "rl_release_fb_cycle2, rl_core_resp_for_atomic"*)
  `endif 
  (*conflict_free = "rl_enq_ff_second_stage, rl_fb_enq_ff_second_stage"*)
  (*preempts= "rl_initialize, (rl_handle_req_from_core, rl_tag_and_data_array_read_response, rl_access_MSHRs, rl_MSHR_req_to_fill_buffer, rl_release_fb_cycle1, rl_release_fb_cycle2, rl_release_eviction_buffer, rl_fence_cache)"*)
  (*conflict_free="rl_MSHR_req_to_fill_buffer, mshr.rl_deq_ff"*)
  (*preempts="rl_sram_resp_to_core, rl_access_fault_response_to_core"*)
  (*preempts="rl_stage2_fb_resp_to_core, rl_access_fault_response_to_core"*)
  (*preempts="rl_fence_fb, rl_fence_cache"*)
`ifdef atomic
  (*preempts = "rl_MSHR_resp_to_core, rl_sc_fail_response_to_core"*)
  (*preempts = "rl_sram_resp_to_core, rl_sc_fail_response_to_core"*)
  (*preempts = "rl_stage2_fb_resp_to_core, rl_sc_fail_response_to_core"*)
  (*preempts = "rl_access_fault_response_to_core, rl_sc_fail_response_to_core"*)
  (*preempts = "rl_receive_IO_resp, rl_sc_fail_response_to_core"*)
 `endif
  (*preempts = "rl_receive_IO_resp, (rl_stage2_fb_resp_to_core, rl_sram_resp_to_core, rl_MSHR_resp_to_core, rl_access_fault_response_to_core)"*)
  (*preempts = "rl_stall_for_load_after_store_to_same_word, rl_handle_req_from_core"*)
  (*preempts = "rl_SRAM_and_MSHR_done_fencing, rl_MSHR_resp_to_core"*)  //TODO does this order matter?

  module mknb_dcache#(parameter String alg)
  //                  8,        8,      128,     4,    32,    32,    32,    32,      6,         4,       4,          3,           128,        7
    (Ifc_nbdcache#(wordsize, linesize, setsize, ways, paddr, vaddr, dsram, tsram, prf_index, id_bits, mshrsize, mshrfifo_depth, buswidth, rob_index))
    provisos(
      Log#(wordsize, wordbits),
      Mul#(wordsize, 8, datawidth),          //64 datawidth is the total bits in a word
      Mul#(linesize, datawidth, linewidth),  //512 linewidth is the total bits in a cache line
      Add#(wordbits, TLog#(linesize), lineoffset),  //6 lineoffset is no. of bits to indicate byte offset within a line
      Log#(setsize, setbits),                //7 setbits is the no. of bits used as index in BRAMs
      //Add#(, a__, id_bits),                // id_bits should be greater than Log(mshrsize+2)
      Add#(lineoffset, setbits, tagpos),    //13 tagpos total bits for index + offset, 
      Add#(tagbits, tagpos, paddr),          //19 tagbits = paddr - (lineoffset + setbits)
      Log#(TDiv#(buswidth, 8), busoffset),  //4 busoffset is no. of bits to indicate a byte offset within a buswidth data 
      Div#(linewidth, buswidth, evict_iter),//4 evict_iter is the burst length while evicting a cache line
      Add#(b__, prf_index, datawidth),      //Load responses after stage2 will have prf encoded in the payload field
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
    //----------------------//
    );

    let ways_val= valueOf(ways);
    let paddr_val= valueOf(paddr);
    let datawidth_val= valueOf(datawidth);
    let buswidth_val= valueOf(buswidth);
    let busoffset_val= valueOf(busoffset);
    let linewidthbits_val= valueOf(lineoffset);
    let setbits_val= valueOf(setbits);
    let tagbits_val= valueOf(tagbits);
    let tagpos_val= valueOf(tagpos);
    let evict_iter_val= valueOf(evict_iter);

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
    FIFOF#(Req_from_core#(vaddr, datawidth, rob_index, prf_index)) ff_req_from_core <- mkBypassFIFOF;
    Wire#(Resp_to_core#(datawidth, prf_index, rob_index)) wr_resp_to_core <- mkWire;
    
    //If a req is a miss in the TLB, that request would be sent to the PTW module. PTW module will
    //store this req and also start performing the PTW. Once PTW is done, it again sends this req
    //to the cache. Now, this request will be a hit in the TLB. This FIFO is used to send the req to
    //the PTW module
    Wire#(Req_from_core#(vaddr, datawidth, rob_index, prf_index)) wr_req_to_ptw <- mkWire;
    FIFO#(Read_req_to_mem#(paddr, id_bits)) ff_read_req_to_mem <- mkSizedFIFO(4);
    Wire#(Read_resp_from_mem#(buswidth, id_bits)) wr_read_resp_from_mem <- mkDWire(defaultValue);
    FIFOF#(Write_req_to_mem#(paddr, linewidth)) ff_write_req_to_mem <- mkBypassFIFOF;
    Wire#(Bool) wr_write_resp_from_mem <- mkWire;

    FIFO#(IO_Req#(paddr, datawidth)) ff_io_req <- mkSizedFIFO(1);
    FIFO#(IO_Resp#(datawidth)) ff_io_resp <- mkSizedFIFO(1);


    ///////////////////////////// Module signals ///////////////////////////////////////////////////
    FIFOF#(Req_from_core#(paddr, datawidth, rob_index, prf_index)) ff_first_stage <- mkPipelineFIFOF;
    FIFO#(Bit#(TAdd#(tagbits,2))) ff_first_stage_tag[ways_val];
    for(Integer i=0; i<ways_val; i=i+1)
      ff_first_stage_tag[i]<- mkBypassFIFO;
    FIFOF#(Cache_req#(paddr, datawidth, rob_index, prf_index)) ff_second_stage <- mkFIFOF;
    Ifc_SESFMI_FIFO#(2, Bool) cff_second_stage_valid <- mkSESFMI_second_stage_inst;
    Ifc_SEMF_FIFO#(2, Bit#(rob_index)) cff_second_stage_rob_id <- mkSEMF_FIFO(0);
    FIFO#(Req_from_core#(paddr, datawidth, rob_index, prf_index)) ff_io_info <- mkFIFO;

    Reg#(Bool) rg_cache_busy <- mkConfigReg(True);  //TODO has to be reset depending upon when the leaf page is received
                                                    //or when PTW walk indicates so

    Reg#(FB_state) rg_fb_state <- mkReg(defaultValue);
    Reg#(Bit#(setbits)) rg_initialize_index <- mkReg(0);
    Reg#(Bool) rg_initialize_done <- mkReg(False);
    Reg#(Flush_type#(rob_index)) rg_flush <- mkDReg(defaultValue);
    Reg#(Bool) rg_fence <- mkReg(False);
    Reg#(Bit#(setbits)) rg_fence_set_index <- mkConfigReg(0);
    Reg#(Bit#(setbits)) rg_prev_fence_set_index <- mkConfigReg(0);
    Reg#(Bool) rg_SRAM_fence[2] <- mkCReg(2, True);
    Reg#(Tuple3#(DCache_exception, Bit#(prf_index), Bit#(rob_index))) rg_access_fault_response <- mkReg(tuple3(defaultValue, ?, ?));
    Reg#(Bool) rg_io_req_sent <- mkReg(False);
    Reg#(Tuple2#(Bool, Bit#(TSub#(vaddr,wordbits)))) rg_prev_req_info <- mkReg(tuple2(False, ?));
    Reg#(Bit#(rob_index)) rg_fence_rob <- mkRegU;

  `ifdef atomic
    Reg#(Maybe#(Tuple2#(Bit#(TLog#(ways)), Bit#(datawidth)))) rg_atomic_hit_info <- mkReg(tagged Invalid);
    Reg#(Tuple3#(Bool, Bit#(paddr), Bit#(rob_index))) rg_lr_info <- mkReg(tuple3(False, ?, ?));
    Reg#(Bool) rg_sc_fail <- mkReg(False);
  `endif

    Wire#(Bool) wr_is_mshr_req_to_fb_valid <- mkDWire(False);
    Wire#(MSHR_Req#(paddr, datawidth, prf_index, rob_index)) wr_mshr_req_to_fb <- mkWire;
    Wire#(Bool) wr_stage2_check_fb <-mkWire;
    Wire#(Bool) wr_is_mshr_resp_to_core <- mkDWire(False);
    Wire#(Bool) wr_stage2_req_to_fb <- mkWire;
    Wire#(Resp_to_core#(datawidth, prf_index, rob_index)) wr_mshr_resp_to_core <- mkWire;
    Wire#(Resp_to_core#(datawidth, prf_index, rob_index)) wr_sram_resp_to_core <- mkWire();
    Wire#(Resp_to_core#(datawidth, prf_index, rob_index)) wr_stage2_fb_resp_to_core <- mkWire();
    Wire#(Bool) wr_stage1_deq <- mkDWire(False);
    Wire#(Bool) wr_stage1_deq_enq <- mkDWire(False);
    Wire#(Bool) wr_stage1_fb_deq <- mkDWire(False);
    Wire#(Bool) wr_stage1_fb_deq_enq <- mkDWire(False);
    Wire#(Cache_req#(paddr, datawidth, rob_index, prf_index)) wr_stage2_enq <- mkWire;
    Wire#(Cache_req#(paddr, datawidth, rob_index, prf_index)) wr_stage2_fb_enq <- mkWire;

    
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

    function Cache_req#(paddr, datawidth, rob_index, prf_index) convert_to_Cache_req(Req_from_core#(paddr, datawidth, rob_index, prf_index) req);
      Bit#(datawidth) lv_payload= req.origin==Store_commit? req.data : zeroExtend(req.prf_index);
      return Cache_req { addr: req.addr,
                         access_size: req.access_size,
                         payload: lv_payload,
                         origin: req.origin,
                         prf_index: req.prf_index,
                          rob: req.rob
                       `ifdef atomic
                         , is_atomic: req.is_atomic
                         , atomic_fn: req.atomic_fn
                       `endif };
    endfunction

    function MSHR_Req#(addrwidth, datawidth, prf_index, rob_index) convert_to_MSHR_Req(Req_from_core#(addrwidth, datawidth, rob_index, prf_index) req);
      return MSHR_Req { addr: req.addr,
                        access_size: req.access_size,
                        payload: req.data,
                        origin: req.origin,
                        prf_index: req.prf_index,
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

    function Cache_DTLB_request#(vaddr) convert_core_to_tlb_req(Req_from_core#(vaddr, datawidth, rob_index, prf_index) core_req);
      Bit#(2) access= core_req.origin==Store_commit ? 2'b01 : 2'b00;

      Cache_DTLB_request#(vaddr) dtlb_req= Cache_DTLB_request { address: core_req.addr,
                                                             access: access,
                                                             ptwalk_trap: core_req.ptwalk_trap,
                                                             ptwalk_req: (core_req.origin==PTW),
                                                             sfence: core_req.sfence };
      return dtlb_req;
    endfunction

    function Bool is_IO(Bit#(vaddr) addr);
      if(addr < 'h1000) begin
        return True;
      end
      else begin
        return False;
      end
    endfunction

//    function Bool is_IO(Bit#(vaddr) addr); //TODO remove this dummy is_IO function
//      if(addr < 'h2000) begin
//        return False;
//      end
//      else if(addr > 'h80000000 && addr < 'h90000000) begin
//        return False;
//      end
//      else begin
//        return True;
//      end
//    endfunction

    `ifdef atomic
    function Bit#(datawidth) fn_atomic_op (Bit#(5) op, Bit#(datawidth) rs2, Bit#(datawidth) loaded);
      //provisos(Add#(z__, 32, datawidth));
      Bit#(datawidth) op1 = loaded;
      Bit#(datawidth) op2 = rs2;
      if(op[4] == 0)begin
        op1 = signExtend(loaded[31 : 0]);
        op2 = signExtend(rs2[31 : 0]);
      end
      Int#(datawidth) s_op1 = unpack(op1);
      Int#(datawidth) s_op2 = unpack(op2);
      
      case (op[3 : 0])
          'b0011 : return op2;
          'b0000 : return (op1 + op2);
          'b0010 : return (op1^op2);
          'b0110 : return (op1 & op2);
          'b0100 : return (op1|op2);
          'b1100 : return min(op1, op2);
          'b1110 : return max(op1, op2);
          'b1000 : return pack(min(s_op1, s_op2));
          'b1010 : return pack(max(s_op1, s_op2));
          default : return op1;
        endcase
    endfunction
    `endif

    rule rl_initialize(!rg_initialize_done);
      `logLevel( dcache, 2, $format("DCACHE : Clearing valid bit of set_index: %d", rg_initialize_index))
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
      `logLevel( dcache, 2, $format("DCACHE_INFO : Core_req: ", fshow(core_req)))
      `logLevel( dcache, 2, $format("DCACHE_INFO : rg_prev_req_info: ", fshow(rg_prev_req_info)))
      Bit#(TSub#(vaddr,wordbits)) lv_prev_addr= truncateLSB(tpl_2(rg_prev_req_info));
      Bit#(TSub#(vaddr,wordbits)) lv_curr_addr= truncateLSB(core_req.addr);
      `logLevel( dcache, 2, $format("DCACHE_INFO : prev_addr: %h curr_addr: %h", lv_prev_addr, lv_curr_addr))
    endrule

    rule rl_stall_for_load_after_store_to_same_word(tpl_1(rg_prev_req_info) &&
    (core_req.origin==Load_buffer || core_req.origin==PTW) &&
    tpl_2(rg_prev_req_info)==truncateLSB(core_req.addr));
      rg_prev_req_info<= tuple2(False, ?);
      `logLevel( dcache, 2, $format("DCACHE : Stalling req from core as prev was store. Core_req: ", fshow(core_req)))
    endrule

    rule rl_handle_req_from_core(!rg_cache_busy && !rg_fence `ifdef atomic && !rg_sc_fail `endif
                                 );
      let core_req= ff_req_from_core.first;
      ff_req_from_core.deq;
      Bool is_actual_store= (core_req.origin == Store_commit);
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
        set_index= core_req.addr[setbits_val + linewidthbits_val - 1 : linewidthbits_val];
      end
      `logLevel( dcache, 2, $format("DCACHE : Stage 1 Core_req: ", fshow(core_req), "set_index: %d", set_index))
      
      for(Integer i = 0;i<ways_val;i = i+1) begin
        data_arr[i].read(set_index);
        tag_arr[i].read(set_index);
      end
      let resp_from_tlb<- dtlb.translate(convert_core_to_tlb_req(core_req));
      Req_from_core#(paddr, datawidth, rob_index, prf_index) req= Req_from_core{  addr: resp_from_tlb.address,
                                                                      access_size: core_req.access_size,
                                                                      data: core_req.data,
                                                                      origin: core_req.origin,
                                                                      sfence: core_req.sfence,
                                                                      ptwalk_trap: core_req.ptwalk_trap,
                                                                      rob: core_req.rob,
                                                                      prf_index: core_req.prf_index 
                                                                      `ifdef atomic
                                                                        , is_atomic: core_req.is_atomic
                                                                        , atomic_fn: core_req.atomic_fn
                                                                      `endif };
      Bool is_IO_access= is_IO(core_req.addr);
      if(core_req.sfence) begin
        mshr.fence;
        rg_fence<= True;
        rg_fence_rob<= core_req.rob;
        rg_SRAM_fence[0]<= True;
        rg_cache_busy<= True;
        `logLevel( dcache, 1, $format("DCACHE : Fence instruction received."))
      end
      else if(!resp_from_tlb.tlbmiss || is_IO_access) begin      //Hit in the TLB or is an IO operation
        `logLevel( dcache, 2, $format("DCACHE : Hit in the TLB"))
        if(resp_from_tlb.trap) begin  //Access fault
          rg_cache_busy<= True;
          `logLevel( dcache, 1, $format("DCACHE : TLB Access fault"))
          rg_access_fault_response<= tuple3(resp_from_tlb.exception, core_req.prf_index, core_req.rob);
        end
        else begin  //Access is valid
          Bool lv_sc_pass= True;
        `ifdef atomic
          if(core_req.is_atomic) begin
            if(core_req.atomic_fn=='d2 && !tpl_1(rg_lr_info)) //LR and rg_lr_info is false
              rg_lr_info<= tuple3(True, resp_from_tlb.address, core_req.rob);
            else
              rg_lr_info<= tuple3(False, ?, ?);

            if(core_req.atomic_fn=='d3) begin   //SC
              Bit#(TSub#(paddr,3)) lv_reserved_addr= tpl_2(rg_lr_info)[paddr_val-1:3];
              if(!(tpl_1(rg_lr_info) && lv_reserved_addr==resp_from_tlb.address[paddr_val-1:3]))
                lv_sc_pass= False;
            end
          end
          else 
            rg_lr_info<= tuple3(False, ?, ?);
        `endif

          if(is_IO_access) begin  //IO operation
            //Enqueue into a separate FIFO that handles IO Requests
            `logLevel( dcache, 2, $format("DCACHE : IO request sent to Stage2"))
            ff_io_info.enq(req);
            rg_cache_busy<= True;
          end
          else if(lv_sc_pass) begin  //Else it's a cacheable request. Enqueue in the first stage FIFO.
            `logLevel( dcache, 2, $format("DCACHE : Sending req ", fshow(req), " to Stage2"))
            ff_first_stage.enq(req);
          end
        `ifdef atomic
          else begin
            rg_sc_fail<= True;
            rg_access_fault_response<= tuple3(defaultValue, core_req.prf_index, core_req.rob);
            rg_cache_busy<= True;
            `logLevel( dcache, 2, $format("DCACHE : Atomic failed"))
          end
        `endif
        end
      end
      else begin    //Miss in the TLB and not IO or fence operation
        `logLevel( dcache, 2, $format("DCACHE : Miss in the TLB"))
        wr_req_to_ptw<= core_req;    //TODO PTW will store the req and send it again, once PTW is done.
        rg_cache_busy<= True;
      end
      `logLevel( dcache, 2, $format("DCACHE : Physical addr from TLB: %h", req.addr))
    endrule

    rule rl_access_fault_response_to_core(!wr_is_mshr_resp_to_core &&
    tpl_1(rg_access_fault_response)!=defaultValue && rg_cache_busy);
      wr_resp_to_core<= Resp_to_core {data: ?,
                                      prf_index: tpl_2(rg_access_fault_response),
                                      rob: tpl_3(rg_access_fault_response),
                                      exception: tpl_1(rg_access_fault_response) };
      rg_cache_busy<= False;
      rg_access_fault_response<= tuple2(defaultValue, ?);
    endrule

  `ifdef atomic
    rule rl_sc_fail_response_to_core(!wr_is_mshr_resp_to_core && rg_sc_fail && !rg_fence && rg_cache_busy);
      wr_resp_to_core<= Resp_to_core {data: 'd1,
                                      prf_index: tpl_2(rg_access_fault_response),
                                      rob: tpl_3(rg_access_fault_response),
                                      exception: defaultValue };
      rg_sc_fail<= False;
      rg_cache_busy<= False;
    endrule
  `endif

    //In case we cannot enqueue into ff_second_stage, the second stage would stall. After some clock
    //cycles when the we can enqueue into ff_second_stage, the correct values of tag will not be 
    //available as the first stage is not repeated in this cycle. Hence, an intermediate BypassFIFO
    //is required to store the tag bits. For the case, when there is no stall, since it's a BypassFIFO
    //the value enqueued can be read in the same cycle, and does not result in any stalls. On the other
    //hand when there is a stall, this FIFO will hold the value of the tag untill data can be enqueued
    //into ff_second_stage.
    rule rl_read_tag_response(ff_first_stage.notEmpty);
      for(Integer i = 0; i<ways_val; i = i+1) begin
        let temp = tag_arr[i].read_response;
        `logLevel( dcache, 2, $format("DCACHE : Stage2 tag[%d] read: %h", i, temp))
        ff_first_stage_tag[i].enq(temp);
      end
    endrule

    //This rule matches the tag and checks if it was a hit in the cache; and if it is, sends a response
    //to the core (in case no request from MSHR is sending a response to the core). If it's a miss in the
    //cache, then the request is sent to the fill buffer.
    rule rl_tag_and_data_array_read_response(!rg_fence `ifdef atomic &&& rg_atomic_hit_info matches tagged Invalid `endif );
      let req= ff_first_stage.first;
      `logLevel( dcache, 2, $format("DCACHE : Stage2 req: ", fshow(req)))

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
        if(tag[tagbits_val]==1) begin
          Bit#(setbits) dummy_set_index = req.addr[setbits_val + linewidthbits_val - 1 : linewidthbits_val];
          `logLevel( dcache, 2, $format("DCACHE : Valid tag at index: %d and way: %d", dummy_set_index, i ))
        end
        if(tag[tagbits_val]==1 && tag[tagbits_val-1:0]== req_tag) begin    
          `logLevel( dcache, 2, $format("DCACHE : Hit at way num: %d tag: %h req_tag: %h", i, tag, req_tag ))
          way_num= fromInteger(i);  //Store the index of the tag match
        end
      end

      if(way_num!='1) begin                                    //It's a line hit
        Bit#(TLog#(ways)) hit_way= truncate(way_num);
        Bit#(setbits) set_index = req.addr[setbits_val + linewidthbits_val - 1 : linewidthbits_val];
        let line= dataline[hit_way];  //TODO change this to OInt type
        let disp_tag= tag_arr[hit_way].read_response;
        `logLevel( dcache, 2, $format("DCACHE : Hit in the dcache", fshow(req)))
        `logLevel( dcache, 2, $format("DCACHE : Hit at set_index: %d way_num: %d line: %h tag: %h", set_index, hit_way, line, disp_tag))

        Bit#(datawidth) data_to_core= fn_extract_data(line, truncate(req.addr), req.access_size);  //TODO Make UniqueWrapper for this fn

        //If MSHR req is not sending response, the current hit response can be sent to the processor.
        //Hence, deq ff_first_stage. Also, for Store_buffer requests, no response needs to be sent,
        //and therfore, ff_first_stage can be dequeued.
        if((!wr_is_mshr_resp_to_core `ifdef atomic && !req.is_atomic `endif ) || req.origin==Store_buffer) begin
          wr_stage1_deq<= True;
        end

        //If MSHR req is not sending response, then this stage can send a response for hit.
        if(send_resp && !wr_is_mshr_resp_to_core `ifdef atomic && !req.is_atomic `endif ) begin
          wr_sram_resp_to_core<= Resp_to_core { data: data_to_core,
                                                 prf_index: req.prf_index,
                                                rob: req.rob,
                                                 exception: No_exception };
          repl.update_set(set_index, hit_way);  //Update the replacement bits on a hit
          `logLevel( dcache, 2, $format("DCACHE : Hit response to proc. data: %h prf_index: %h", data_to_core, req.prf_index))
        
          //For a store instruction, update the appropriate data and tag bits in the SRAM.
          //TODO If MSHR is sending response in a cycle, should the store happen in that or
          //     should it wait for a free cycle where this stage can send a response?
          if(req.origin==Store_commit) begin
            Bit#(lineoffset) line_offset= req.addr[linewidthbits_val-1:0];
            let write_data= generate_masked_data(line, req.data, line_offset, req.access_size);
            data_arr[hit_way].write(set_index, write_data);
            `logLevel( dcache, 2, $format("DCACHE : Hit for store. Writing: %h", write_data))
          end
        end
        `ifdef atomic
        else if(req.is_atomic) begin
          //let data= perform_atomic_op(data_to_core, req.data, req.atomic_fn);
          rg_atomic_hit_info<= tagged Valid tuple2(hit_way, data_to_core);
        end
        `endif
      end
      else if(wr_is_mshr_req_to_fb_valid) begin    //Some pending MSHR request to FB
        if(req.origin!=Store_commit || !wr_is_mshr_resp_to_core) begin
          `logLevel( dcache, 2, $format("DCACHE : MSHR polling FB. Miss in the dcache. Sending req: ", fshow(req), "to ff_second_stage"))
          wr_stage2_enq<= convert_to_Cache_req(req);
          if(req.origin==Store_commit `ifdef atomic && !req.is_atomic `endif ) begin
            wr_sram_resp_to_core<= Resp_to_core { data: ?,
                                                  prf_index: req.prf_index,
                                                  rob: req.rob,
                                                  exception: No_exception };
          end
        end
        else begin
          `logLevel( dcache, 2, $format("DCACHE : MSHR polling FB and MSHR sending resp to core. Hence stalling store/atomic req: ", fshow(req)))
        end
      end
      else begin  //Line miss; send req to FB since MSHR is not sending
        wr_stage2_req_to_fb<= True;
        `logLevel( dcache, 2, $format("DCACHE : #### ", fshow(req)))
      end
    endrule

  `ifdef atomic
    rule rl_core_resp_for_atomic(rg_atomic_hit_info matches tagged Valid .atomic_hit_info &&& !wr_is_mshr_resp_to_core);
      let req= ff_first_stage.first;
      let atomic_fn= req.atomic_fn;
      match {.hit_way, .cache_data}= atomic_hit_info;
      let atomic_result= fn_atomic_op(atomic_fn, req.data, cache_data);
      Bit#(lineoffset) line_offset= req.addr[linewidthbits_val-1:0];
      let cache_line= data_arr[hit_way].read_response;
      let write_data= generate_masked_data(cache_line, atomic_result, line_offset, req.access_size); //TODO make UniqueWrapper
      Bit#(setbits) set_index = req.addr[setbits_val + linewidthbits_val - 1 : linewidthbits_val];
      data_arr[hit_way].write(set_index, write_data);
      wr_stage1_deq<= True;
      rg_atomic_hit_info<= tagged Invalid;
      if(atomic_fn=='d3) begin  //if SC
        cache_data= 'd0;
      end
      wr_sram_resp_to_core<= Resp_to_core { data: cache_data, //TODO check if correct for atomics
                                            prf_index: req.prf_index,
                                            rob: req.rob,
                                            exception: No_exception };
    endrule
  `endif


    //This rule fires in the same cycle as rl_tag_and_data_array_read_response if tag match returned a miss.
    //This rule sends a req to FB and checks if the response is a hit or not. If it's a hit, an
    //acknoledgement is sent to the core; else, the request is stored into ff_second_stage.
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
      `logLevel( dcache, 2, $format("DCACHE : Not a hit in SRAM. Checking fill buffer for req:", fshow(req)))
      //if(req.origin==Store_commit && !wr_is_mshr_resp_to_core)  //TODO Arjun NEW.
      //  lv_stage1_fb_deq= True;

      if(fill_buffer_resp matches tagged Valid .fb_data) begin
        if(!wr_is_mshr_resp_to_core || req.origin==Store_buffer) begin
          lv_stage1_fb_deq= True;
        end
        `logLevel( dcache, 2, $format("DCACHE : Fill buffer hit with data: %h for prf_index: %h",  fb_data, req.prf_index))
        Bit#(datawidth) data_to_core= fn_extract_data(fb_data, truncate(req.addr), req.access_size);
        Bool send_resp= req.origin!=Store_buffer;
      `ifdef atomic
        if(req.is_atomic && req.atomic_fn=='d3) begin //SC
          data_to_core= 0;
        end
      `endif
        if(send_resp && !wr_is_mshr_resp_to_core) begin
          wr_stage2_fb_resp_to_core<= Resp_to_core { data: data_to_core,
                                                      prf_index: req.prf_index,
                                                     rob: req.rob,
                                                      exception: No_exception };
        end
        //else do nothing
      end
      else if(fill_buffer.line_addr == req.addr[paddr_val-1:linewidthbits_val]) begin  //Req to same line that is being filled in the FB
        `logLevel( dcache, 2, $format("DCACHE : Req to same line_addr: %h that is being filled in the FB. Stalling... ", fill_buffer.line_addr))
      end
      else begin
        `logLevel( dcache, 2, $format("DCACHE : Miss request. Fill buffer miss for req: ", fshow(req)))
        Bool is_store_instruction= (req.origin==Store_commit `ifdef atomic && !req.is_atomic `endif );

        //if store instructions, and mshr is sending response to core, then do not enqueue request into next cycle
        //For store instructions, if TLB checks pass, the response can immediately be sent. Therefore, instead of sending it to the MSHR,
        //We stall untill MSHR is not sending a response to the core. This way, the ROB can move forward asap.
        //Also, this will have no impact on throughput as the same store instruction would have arrived from the store buffer
        //a couple of clock cycles before. Therefore, even if the store is a miss in the cache, a "prefetch" would
        //have already started.
        if(!is_store_instruction || !wr_is_mshr_resp_to_core) begin
          wr_stage2_fb_enq<= convert_to_Cache_req(req);
          `logLevel( dcache, 2, $format("DCACHE : Converted to cache request"))
        end
        
        if(is_store_instruction) begin
          if(wr_is_mshr_resp_to_core) begin
            `logLevel( dcache, 2, $format("DCACHE : MSHR responding to core. Hence stalling Store req: ", fshow(req)))
          end
          else begin
            `logLevel( dcache, 2, $format("DCACHE : Sending store response for prf_index: %h ", req.prf_index))
            wr_stage2_fb_resp_to_core<= Resp_to_core { data: ?,
                                                         prf_index: req.prf_index,
                                                       rob: req.rob,
                                                         exception: No_exception };
          end
        end
      end

      wr_stage1_fb_deq<= lv_stage1_fb_deq;
    endrule

    rule rl_enq_ff_second_stage(!rg_flush.valid);
      `logLevel( dcache, 2, $format("DCACHE : ff_second_stage enq req: ", fshow(wr_stage2_enq)))
      wr_stage1_deq_enq<= True;
      ff_second_stage.enq(wr_stage2_enq);
      cff_second_stage_rob_id.enq(wr_stage2_enq.rob);
      cff_second_stage_valid.enq(True);
    endrule

    rule rl_fb_enq_ff_second_stage(!rg_flush.valid);
      `logLevel( dcache, 2, $format("DCACHE : ff_second_stage fb enq req: ", fshow(wr_stage2_fb_enq)))
      wr_stage1_fb_deq_enq<= True;
      ff_second_stage.enq(wr_stage2_fb_enq);
      cff_second_stage_rob_id.enq(wr_stage2_fb_enq.rob);
      cff_second_stage_valid.enq(True);
    endrule

    rule rl_sram_resp_to_core;
      `logLevel( dcache, 2, $format("DCACHE : SRAM response", fshow(wr_sram_resp_to_core)))
      wr_resp_to_core<= wr_sram_resp_to_core;
    endrule

    rule rl_stage2_fb_resp_to_core;
      `logLevel( dcache, 2, $format("DCACHE : FB response", fshow(wr_stage2_fb_resp_to_core)))
      wr_resp_to_core<= wr_stage2_fb_resp_to_core;
    endrule

    rule rl_deq_ff_first_stage(wr_stage1_fb_deq || wr_stage1_deq || wr_stage1_fb_deq_enq || wr_stage1_deq_enq);
      `logLevel( dcache, 2, $format("Deq by stage1_fb:%b stage1:%b wr_stage1_fb_deq_enq:%b stage1_deq_enq:%b ",
      wr_stage1_fb_deq, wr_stage1_deq, wr_stage1_fb_deq_enq, wr_stage1_deq_enq))

      ff_first_stage.deq;
      for(Integer i = 0; i<ways_val; i = i+1) begin
        ff_first_stage_tag[i].deq;
      end
    endrule

    //TODO Accessing MSHRs when no flush is happening. Can be optimised by by adding a should_flush fn
    // and removing check for index 0 in rl_flush_ff_second_stage.
    rule rl_access_MSHRs(!rg_flush.valid);
      let req= ff_second_stage.first;
      ff_second_stage.deq;
      req.rob= cff_second_stage_rob_id.first;
      cff_second_stage_rob_id.deq;
      cff_second_stage_valid.deq;

      //If valid (not flushed) request OR if fence && a store request
      if( cff_second_stage_valid.first || (rg_fence && req.origin==Store_buffer) ) begin  
        let mshr_resp<- mshr.allocate(req);
        if(mshr_resp matches tagged Valid .read_id) begin
          Bit#(TSub#(paddr,busoffset)) line_addr= req.addr[paddr_val-1:busoffset_val];
          Bit#(busoffset) zeros= 'd0;
          Bit#(paddr) mem_addr= {line_addr, zeros};
          `logLevel( dcache, 2, $format("DCACHE : MSHR %d initiated a memory request for addr: %h",read_id, mem_addr))
          ff_read_req_to_mem.enq(Read_req_to_mem {addr: mem_addr,
                                                  id: zeroExtend(read_id),
                                                  is_burst: True });
        end
        else begin
          `logLevel( dcache, 2, $format("DCACHE : MSHR already allocated for this req addr: %h", req.addr))
        end
      end
      else begin
        `logLevel( dcache, 2, $format("DCACHE : Discarding ff_second_stage req: ", fshow(req)))
      end
    endrule

    //This rule resets the valid bit of rg_flush after a flush request is initiated.
    //If ff_second_stage is empty, flush is over. Hence, reset valid bit of rg_flush
    (*no_implicit_conditions, fire_when_enabled*)
    rule rl_flush_ff_second_stage(rg_flush.valid);
      Vector#(2,Bool) valid= cff_second_stage_valid.contents;
      Vector#(2,Bit#(rob_index)) rob_id= cff_second_stage_rob_id.contents;

      if(should_flush(rg_flush.head, rg_flush.flush_rob, rob_id[0]) && valid[0])
        valid[0]= False;
      if(should_flush(rg_flush.head, rg_flush.flush_rob, rob_id[1]) && valid[1])
        valid[1]= False;

      cff_second_stage_valid.initialize(valid);
      `logLevel( dcache, 2, $format("DCACHE : Flusing everything! valid: %h", valid ))
      mshr.flush(rg_flush);
    endrule

    rule rl_MSHR_req;
      let resp_from_mem= wr_read_resp_from_mem;
      Maybe#(Bit#(TLog#(mshrsize))) lv_id_to_mshr;
      if(resp_from_mem.id=='1)
        lv_id_to_mshr= tagged Invalid;
      else
        lv_id_to_mshr= tagged Valid truncate(resp_from_mem.id);
      let maybe_req_from_mshr<- mshr.req_to_fb(lv_id_to_mshr);    //Receive the request from MSHR corresponding to the rid
      `logLevel( dcache, 2, $format("DCACHE : Request from MSHR to FB: ", fshow(maybe_req_from_mshr)))
      if(tpl_1(maybe_req_from_mshr)) begin
        wr_mshr_req_to_fb<= tpl_2(maybe_req_from_mshr);
      end
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
    rule rl_MSHR_req_to_fill_buffer;
      let req_from_mshr= wr_mshr_req_to_fb;
      `logLevel( dcache, 2, $format("DCACHE :Sending  Request from MSHR to FB. "))
      wr_is_mshr_req_to_fb_valid<= True;
      let fb_addr= req_from_mshr.addr[paddr_val-1:linewidthbits_val];
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
        `logLevel( dcache, 2, $format("DCACHE : Response data from FB to MSHR: %h", fb_data ))
        mshr.ack_from_fb;
        Bool send_resp= (req_from_mshr.origin==Load_buffer || req_from_mshr.origin==PTW
                         `ifdef atomic || req_from_mshr.is_atomic `endif );
        if(send_resp) begin
          Bit#(datawidth) data_to_core= fn_extract_data(fb_data, truncate(req_from_mshr.addr), req_from_mshr.access_size);
        `ifdef atomic
          if(req_from_mshr.is_atomic && req_from_mshr.atomic_fn=='d3) begin //SC
            data_to_core= 0;
          end
        `endif
          wr_mshr_resp_to_core<= Resp_to_core { data: data_to_core,
                                                prf_index: req_from_mshr.prf_index,
                                                rob: req_from_mshr.rob,
                                                exception: No_exception };
          wr_is_mshr_resp_to_core<= True;
        end
        //else do nothing
      end
      //else do nothing
      else begin
        `logLevel( dcache, 2, $format("DCACHE : Data for MSHR req is not yet available in the FB" ))
      end
    endrule

    rule rl_MSHR_resp_to_core;
      `logLevel( dcache, 2, $format("DCACHE : MSHR reponse", fshow(wr_mshr_resp_to_core)))
      wr_resp_to_core<= wr_mshr_resp_to_core;
    endrule
    
    //Once the fill buffer indicates that it can be released(i.e. the complete line is available,
    //and no pending MSHR requests exist to the same line*), the data and tag SRAMs are issued a read
    //request to determine which way should be assigned for this line.
    //*Caveat: Though the FIFOs, corresponding to the MSHR entry (corresponding to the line address)
    //         might be empty, there might be a request pending in the ff_second_stage. This is fine
    //         as the fill buffer is invalidated only after 3 clock cycles.
    rule rl_release_fb_cycle1(fill_buffer.can_release && wr_is_mshr_req_to_fb_valid==False && rg_fb_state==Read_SRAMs && ff_write_req_to_mem.notFull && !rg_fence);
      Bit#(setbits) set_index= fill_buffer.line_addr[setbits_val-1:0];
      `logLevel( dcache, 2, $format("DCACHE : Initiating release of FB to line address: %h", fill_buffer.line_addr))
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
      `logLevel( dcache, 2, $format("DCACHE : Updating way_num: %d and set_index: %d with data: %h and tag: %h", waynum, set_index, fb_data, lv_dirty_valid_tag))

      //Eviction buffer should be written only when there is something to evict, else skip the eviction buffer cycle
      if(valid[waynum]==1 && dirty[waynum]==1) begin
        Bit#(lineoffset) some_zeros= 0;
        Bit#(paddr) evict_lineaddr= {tag[waynum], set_index, some_zeros};
        ff_write_req_to_mem.enq(Write_req_to_mem {addr: evict_lineaddr,
                                                  data: dataline[waynum],
                                                  is_burst: True });
        `logLevel( dcache, 2, $format("DCACHE : Evicting cache line. Addr: %x Data: %x ", evict_lineaddr, dataline[waynum]))
      end
      else begin
        `logLevel( dcache, 2, $format("DCACHE : Updated line is not dirty. Hence, no updation to eviction buffer"))
      end
      rg_fb_state<= Release_FB;
    endrule

    //Releasing the fill buffer entry happens in a cycle after the tag and data arrays have been updated,
    //because in this cycle there might be a request that is pending in ff_first_stage. Therefore in the
    //cycle where this rule is getting executed, the request from ff_first_stage is serviced.
    rule rl_release_eviction_buffer(rg_fb_state==Release_FB);
      fill_buffer.release_fb;
      mshr.fb_released;
      rg_fb_state<= Read_SRAMs;
      `logLevel( dcache, 2, $format("DCACHE : Freeing FB"))
    endrule

    //Fence logic

    //This rule fires whent the fill buffer is ready to be released.
    //Also, rg_fb_state should be Read_SRAMs because when a new fence is initiated, if fill buffer is
    //in Write_SRAMs state, the fence should begin only after the current fb entry is written to the cache.
    //TODO Moreover, the fb contents need to be written to the next level of memory only if the line is dirty
    rule rl_fence_fb (rg_fence && fill_buffer.can_release && rg_fb_state==Read_SRAMs && tpl_1(fill_buffer.data)==1);
      let data= tpl_2(fill_buffer.data);
      let line_addr= fill_buffer.line_addr;
      Bit#(setbits) set_index= line_addr[setbits_val-1:0];
      Bit#(tagbits) tag= line_addr[tagbits_val+setbits_val-1:setbits_val];
      Bit#(lineoffset) some_zeros= 0;
      Bit#(paddr) evict_lineaddr= {tag, set_index, some_zeros};
      ff_write_req_to_mem.enq(Write_req_to_mem {addr: evict_lineaddr,
                                                data: data,
                                                is_burst: True });

      //The fill buffer entry can be released once the req has been enqueued in ff_write_req_to_mem.
      //We need not wait for the write response for the fence to proceed, as whenever write response
      //is received, it is automatically dequeued from the FIFO and discarded.
      //The MSHR should also be acknowledged about the FB entry release so that it can free-up the
      //MSHR entry.
      fill_buffer.release_fb;
      mshr.fb_released;
      `logLevel( dcache, 2, $format("DCACHE : Fence. Fill buffer writing to mem. Addr: %x Data: %x ", evict_lineaddr, data))
    endrule

    //TODO To reduce one cycle per dirty set, implement this function to check if exactly one dirty way exists
    function Bool check_only_one_evict(Bit#(ways) evict);
      return False;
    endfunction

    rule rl_fence_cache (rg_fence && rg_SRAM_fence[0] && rg_cache_busy && rg_fb_state==Read_SRAMs);
      Bit#(linewidth) dataline [ways_val];
      Bit#(TAdd#(tagbits,2)) tag [ways_val];
      Bit#(ways) dirty=0;
      Bit#(ways) valid=0;
      Bool incr_fence_set_index= False;
      Bool lv_evict= False;
      Bit#(TLog#(ways)) evict_index= 0;
      `logLevel( dcache, 2, $format("DCACHE : Fencing set: %d", rg_prev_fence_set_index))

      for(Integer i = 0; i<ways_val; i = i+1) begin
        dataline[i]= data_arr[i].read_response;
        tag[i]= tag_arr[i].read_response;
      end
      for(Integer i = 0; i<ways_val; i = i+1) begin
        valid[i]= tag[i][tagbits_val];    //Valid bit
        dirty[i]= tag[i][tagbits_val+1];  //Dirty bit
        if(valid[i]==1 && dirty[i]==1) begin
          lv_evict=True;
          evict_index= fromInteger(i);
        end
      end

      if(lv_evict) begin
        Bit#(lineoffset) some_zeros= 0;
        Bit#(tagbits) evict_tag= truncate(tag[evict_index]);
        Bit#(paddr) evict_lineaddr= {evict_tag, rg_prev_fence_set_index, some_zeros};
        Bit#(TAdd#(tagbits,2)) lv_dirty_valid_tag= {1'b1, 1'b0, evict_tag};

        //Updating only the valid bit of the SRAM in order to save power.
        tag_arr[evict_index].write(rg_prev_fence_set_index, lv_dirty_valid_tag);

        //Evicting the line
        ff_write_req_to_mem.enq(Write_req_to_mem {addr: evict_lineaddr,
                                                  data: dataline[evict_index],
                                                  is_burst: True });
        `logLevel( dcache, 2, $format("DCACHE : Fence. Cache writing to mem. Way: %d Addr: %x Data: %x ", evict_index, evict_lineaddr, dataline[evict_index]))

        Bit#(ways) evict_indices= valid & dirty;
        Bool only_one_dirty= check_only_one_evict(evict_indices);
        if(only_one_dirty) begin
          incr_fence_set_index= True;
        end
        //else fence_set_index remains unchanged so that rest of the dirty lines in this set get evicted.
      end
      else begin  //Nothing to evict. Hence, increment fence index and clear the valid bit of all ways in this set
        incr_fence_set_index= True;
        for(Integer i = 0; i<ways_val; i = i+1) begin
          tag_arr[i].write(rg_prev_fence_set_index-1, 0);
        end
      end

      if(rg_prev_fence_set_index=='1) begin
        rg_SRAM_fence[0]<= False;
        `logLevel( dcache, 2, $format("DCACHE : Fence. Last SRAM row done. "))
      end
      else if(incr_fence_set_index) begin
        rg_fence_set_index<= rg_fence_set_index + 1;
        rg_prev_fence_set_index<= rg_fence_set_index;
      end
      //Issue read request to the set which will be processed in the next cycle.
      for(Integer i = 0;i<ways_val;i = i+1) begin
        data_arr[i].read(rg_fence_set_index);
        tag_arr[i].read(rg_fence_set_index);
      end
    endrule

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
      `logLevel( dcache, 2, $format("DCACHE : Fence SRAM done. mshr.not_empty: %b rg_io_req_sent: %b ", mshr.not_empty, rg_io_req_sent))
    endrule

    rule rl_SRAM_and_MSHR_done_fencing(rg_fence && !rg_SRAM_fence[0] && !mshr.not_empty && !rg_io_req_sent);
      rg_cache_busy<= False;
      rg_fence<= False;
      rg_prev_fence_set_index<= 0;
      `ifdef atomic
        rg_lr_info<= tuple3(False, ?, ?);
        rg_sc_fail<= False;
      `endif

      wr_resp_to_core<= Resp_to_core { data: ?,
                                       prf_index: ?,
                                       rob: rg_fence_rob,
                                       exception: No_exception };
      `logLevel( dcache, 2, $format("DCACHE : Fencing done. "))
    endrule

    rule rl_send_io_request(!rg_io_req_sent && !rg_fence); //TODO should this rule have !rg_fence?
      let req= ff_io_info.first;
      ff_io_req.enq(IO_Req { addr: req.addr,
                             size: req.access_size,
                             is_store: True, //TODO done to finish sim. Change later.
                             data: req.data });
      rg_io_req_sent<= True;
    endrule

    //Currently, once an IO request is obtained, rg_cache_busy is asserted. This can be optimised in 
    //the future versions
    rule rl_receive_IO_resp(rg_cache_busy && rg_io_req_sent);
      let resp= ff_io_resp.first;
      ff_io_resp.deq;
      ff_io_info.deq;
      //In this implementation, the fence finishes only after receiving any pending IO responses.
      //Hence, if an IO response is received in the middle of a fence request, rg_cache_busy should
      //remain True until the fence operation is over.
      if(!rg_fence) begin
        rg_cache_busy<= False;
      end
      rg_io_req_sent<= False;
      wr_resp_to_core<= Resp_to_core { data: resp.data,
                                       prf_index: ff_io_info.first.prf_index,
                                       rob: ff_io_info.first.rob,
                                       exception: resp.exception };
    endrule

    interface subifc_req_from_core= toPut(ff_req_from_core);
    interface subifc_resp_to_core= toGet(wr_resp_to_core);
    interface subifc_req_to_ptw= toGet(wr_req_to_ptw);
    interface subifc_ptw_meta= dtlb.ptw_meta;
    interface subifc_response_frm_ptw= dtlb.response_frm_ptw;
    interface subifc_read_req_to_mem= toGet(ff_read_req_to_mem);

    interface subifc_read_resp_from_mem= interface Put
      method Action put(Read_resp_from_mem#(buswidth, id_bits) resp);
        wr_read_resp_from_mem<= resp;
        `logLevel( dcache, 2, $format("DCACHE : Read response from mem: ", fshow(resp)))
        let mem_req_offset= mshr.mem_req_offset(truncate(resp.id));
        fill_buffer.data_from_mem(resp.data, resp.last, mem_req_offset);
      endmethod
    endinterface;

    interface subifc_write_req_to_mem= toGet(ff_write_req_to_mem);

    interface subifc_write_resp_from_mem= interface Put
      method Action put(Bool resp);
         wr_write_resp_from_mem<= resp;
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
    endmethod

  endmodule

  (*synthesize*)
  module mkdcache(Ifc_nbdcache#(`Wordsize, `Linesize, `Setsize, `Ways, `Paddr, `Vaddr, `Dsram, `Tsram, `Prf_index, `Id_bits, `Mshrsize, `Mshrfifo_depth, `Buswidth, `Rob_index));
  //module mkdcache(Ifc_nbdcache#(`Wordsize, `Linesize, `Setsize, `Ways, `Paddr, `Vaddr, `Dsram, `Tsram, TLog#(`num_prfs), `Id_bits, `Mshrsize, `Mshrfifo_depth, `Buswidth, TLog#(`rob_size)));
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
