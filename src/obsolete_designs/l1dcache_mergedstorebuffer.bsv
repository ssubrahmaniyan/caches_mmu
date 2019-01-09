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
TODO:  performance counters
NOTE: This module merges stores to the same word to a single entry in the store-buffer instead of
having those stores as separate entries in the store-buffer. Thus when the core indicates to perform
a store, it is possible that 2 stores to the same word are performed in a single cycle. This can
cause issues when the 2 stores to the same word can cause different side-effects to the system.
--------------------------------------------------------------------------------------------------
*/
package l1dcache;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import Assert::*;
  import GetPut::*;
  import BUtils::*;

  import cache_types::*;
  import mem_config::*;
  import replacement_dcache::*;
  
  interface Ifc_l1dcache#( numeric type wordsize, 
                           numeric type blocksize,  
                           numeric type sets,
                           numeric type ways,
                           numeric type paddr,
                           numeric type fbsize,
                           numeric type sbsize,
                           numeric type esize
                           );

    interface Put#(DCore_request#(paddr,TMul#(wordsize,8),esize)) core_req;
    interface Get#(DCore_response#(TMul#(wordsize,8),esize)) core_resp;
    interface Get#(DMem_read_request#(paddr)) read_mem_req;
    interface Put#(DMem_read_response#(TMul#(wordsize,8))) read_mem_resp;
    interface Get#(DMem_read_request#(paddr)) nc_read_req;
    interface Put#(DMem_read_response#(TMul#(wordsize,8))) nc_read_resp;
    
    interface Get#(DMem_write_request#(paddr,TMul#(blocksize,TMul#(wordsize,8)))) write_mem_req;
    interface Put#(DMem_write_response) write_mem_resp;
    interface Get#(DMem_write_request#(paddr,TMul#(wordsize,8))) nc_write_req;
    interface Put#(DMem_write_response) nc_write_resp;
    `ifdef simulate
      interface Get#(Bit#(1)) meta;
    `endif
    `ifdef perf
      method Bit#(5) perf_counters;
    `endif
    method Action cache_enable(Bool c);
    method Action perform_store(Bit#(esize) currepoch);
    method Bool cache_available;
    method Bool storebuffer_empty;
    method Bool store_response;
  endinterface

  (*conflict_free="request_to_memory,update_fb_with_memory_response"*)
  (*conflict_free="respond_to_core,fence_operation"*)
  (*conflict_free="request_to_memory,fence_operation"*)
  (*conflict_free="request_to_memory,release_from_FB"*)
  (*conflict_free="respond_to_core,release_from_FB"*)
  (*conflict_free="respond_to_core,update_fb_with_memory_response"*)
  (*conflict_free="release_from_FB,update_fb_with_memory_response"*)
  (*conflict_free="respond_to_core,update_store_inFB"*)
  (*conflict_free="update_fb_with_memory_response,update_store_inFB"*)
  (*conflict_free="update_storebuffer_onhit,update_store_inFB"*)
  module mkl1dcache#(function Bool isNonCacheable(Bit#(paddr) addr, Bool cacheable), parameter String alg)
    (Ifc_l1dcache#(wordsize,blocksize,sets,ways,paddr,fbsize,sbsize,esize)) 
    provisos(
          Mul#(wordsize, 8, respwidth),        // respwidth is the total bits in a word
          Mul#(blocksize, respwidth,linewidth),// linewidth is the total bits in a cache line
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset, 
          Add#(tagbits, _b, paddr),     // tagbits = 32-(wordbits+blockbits+setbits)

          `ifdef ASSERT
          Add#(1, e__, TLog#(TAdd#(1, fbsize))),
          Add#(1, f__, TLog#(TAdd#(1, ways))),
          Add#(1, o__, TLog#(TAdd#(1, sbsize))),
          `endif

          Add#(a__, respwidth, linewidth),
          Add#(b__, 32, respwidth),
          Add#(c__, 16, respwidth),
          Add#(d__, 8, respwidth),
          Add#(TAdd#(tagbits, setbits), g__, paddr),
          Add#(h__, 1, blocksize),

          Add#(i__, TLog#(ways), 4),
          Mul#(TDiv#(linewidth, 8), 8, linewidth),
          Add#(j__, TDiv#(linewidth, 8), linewidth),
          Add#(k__, TLog#(ways), TLog#(TAdd#(1, ways))),
          Mul#(32, l__, respwidth),
          Mul#(16, m__, respwidth),
          Add#(n__, TLog#(fbsize), TLog#(TAdd#(1, fbsize))),
          Add#(n__, TLog#(sbsize), TLog#(TAdd#(1, sbsize)))
          
    );
    let v_sets=valueOf(sets);
    let v_setbits=valueOf(setbits);
    let v_wordbits=valueOf(wordbits);
    let v_blockbits=valueOf(blockbits);
    let v_linewidth=valueOf(linewidth);
    let v_tagbits=valueOf(tagbits);
    let verbosity=`VERBOSITY;
    let v_paddr=valueOf(paddr);
    let v_ways=valueOf(ways);
    let v_wordsize=valueOf(wordsize);
    let v_blocksize=valueOf(blocksize);
    let v_fbsize=valueOf(fbsize);
    let v_respwidth=valueOf(respwidth);
    let v_sbsize = valueOf(sbsize);

    //Following function returns the info regarding word_position in line getting filled
    function Bit#(blocksize) fn_enable(Bit#(blockbits)word_index);
       Bit#(blocksize) write_enable ='h0; //
       write_enable[word_index]=1;
       return write_enable;
    endfunction
    function Bool isTrue(Bool a);
      return a;
    endfunction
    function Bool isOne(Bit#(1) a);
      return unpack(a);
    endfunction

    // ----------------------- FIFOs to interact with interface of the design -------------------//
    // This fifo stores the request from the core.
    FIFOF#(DCore_request#(paddr,respwidth,esize)) ff_core_request <- mkSizedFIFOF(2); 
    // This fifo stores the response that needs to be sent back to the core.
    FIFOF#(DCore_response#(respwidth,esize))ff_core_response <- mkSizedFIFOF(2);
    // this fifo stores the read request that needs to be sent to the next memory level.
    FIFOF#(DMem_read_request#(paddr)) ff_read_mem_request    <- mkSizedFIFOF(2);
    // This fifo stores the response from the next level memory.
    FIFOF#(DMem_read_response#(respwidth)) ff_read_mem_response  <- mkSizedBypassFIFOF(1);
    
    FIFOF#(DMem_read_request#(paddr)) ff_nc_read_request    <- mkSizedFIFOF(2);
    // This fifo stores the response from the next level memory.
    FIFOF#(DMem_read_response#(respwidth)) ff_nc_read_response  <- mkSizedBypassFIFOF(1);
    
    FIFOF#(DMem_write_request#(paddr,TMul#(wordsize,8))) ff_nc_write_request  <- mkSizedFIFOF(2);
    FIFOF#(DMem_write_response) ff_nc_write_response  <- mkSizedFIFOF(2);
    
    FIFOF#(DMem_write_request#(paddr,TMul#(blocksize,TMul#(wordsize,8)))) ff_write_mem_request    
                                                                              <- mkSizedFIFOF(2);
    FIFOF#(DMem_write_response) ff_write_mem_response  <- mkSizedFIFOF(2);

    Wire#(Bool) wr_takingrequest <- mkDWire(False);
    Wire#(Bool) wr_cache_enable<-mkWire();
    `ifdef simulate
      FIFOF#(Bit#(1)) ff_meta <- mkSizedFIFOF(2);
    `endif
    `ifdef perf
      Wire#(Bit#(1)) wr_total_access <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_cache_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_fb_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_io <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_fbfills <- mkDWire(0);
    `endif
    // ------------------------------------------------------------------------------------------//

   
    // ------------------------ Structures required for cache RAMS ------------------------------//
    Ifc_mem_config1rw#(sets, linewidth, 1) data_arr [v_ways]; // data array
    Ifc_mem_config1rw#(sets, tagbits, 1) tag_arr [v_ways];// one extra valid bit
    for(Integer i=0;i<v_ways;i=i+1)begin
      data_arr[i]<-mkmem_config1rw(False, "single"); // TODO parameterize arguments
      tag_arr[i]<-mkmem_config1rw(False, "single");
    end
    Ifc_replace#(sets,ways) repl <- mkreplace(alg);
    Vector#(sets,Reg#(Bit#(ways))) rg_valid<-replicateM(mkReg(0));
    Reg#(Bit#(ways)) rg_dirty[v_sets];
    for(Integer i=0;i<v_sets;i=i+1)begin
      rg_dirty[i]<-mkReg(0);
    end
    Wire#(RespState) wr_cache_response <- mkDWire(None);
    Wire#(Bit#(respwidth)) wr_cache_hitword <-mkDWire(0);
    Wire#(Bit#(TLog#(ways))) wr_hitway <-mkDWire(0);
    Wire#(Maybe#(Bit#(TLog#(sets)))) wr_cache_hitindex <-mkDWire(tagged Invalid);
    Wire#(RespState) wr_nc_response <- mkDWire(None);
    Wire#(Bit#(respwidth)) wr_nc_word <-mkDWire(0);
    Wire#(Bool) wr_nc_err <-mkDWire(False);
    Wire#(Bit#(linewidth)) wr_hitline <-mkDWire(0);
    Reg#(Bool) rg_miss_ongoing <- mkReg(False);
    Reg#(Bool) rg_fence_stall <- mkReg(False);
    Reg#(Bit#(TLog#(sets))) rg_latest_index<- mkReg(0);
    Reg#(Bool) rg_replaylatest<-mkReg(False);
    // ------------------------------------------------------------------------------------------//

    // ----------------- Fill buffer structures -------------------------------------------------//
    Reg#(Bit#(linewidth)) fb_dataline [v_fbsize];
    Reg#(Bit#(1)) fb_err [v_fbsize];
    Reg#(Bit#(paddr)) fb_addr [v_fbsize];
    Reg#(Bit#(blocksize)) fb_enables [v_fbsize];
    Reg#(Bit#(1)) fb_dirty [v_fbsize] ;
    Vector#(fbsize,Reg#(Bool)) fb_valid <-replicateM(mkReg(False));
    for(Integer i=0;i<v_fbsize;i=i+1)begin
      fb_dataline[i]<-mkReg(0);
      fb_addr[i]<-mkReg(0);
      fb_enables[i]<-mkReg(0);
      fb_dataline[i]<-mkReg(0);
      fb_dirty[i]<-mkReg(0);
      fb_err[i]<-mkReg(0);
    end
    Wire#(RespState) wr_fb_response <- mkDWire(None);
    Wire#(Bit#(respwidth)) wr_fb_word <-mkDWire(0);
    Wire#(Bit#(TLog#(fbsize))) wr_fbindexhit <-mkDWire(0);
    Wire#(Bit#(1)) wr_fb_err <-mkDWire(0);
    // this register is used to ensure that the cache does not do a tag match when FB is polling on
    // a line for the requested word.
    Reg#(Bool) rg_polling <-mkReg(False);
    `ifdef simulate
      Wire#(Bool) wrpolling<-mkDWire(False);
    `endif

    // This register indicates which entry in the FB should be allocated when there is miss in the
    // FB and the cache for a given request.
    Reg#(Bit#(TLog#(fbsize))) rg_fbmissallocate <-mkReg(0);

    // This register follows the rg_fbmissallocate register but is updated when the last word of a
    // line is filled in the FB on a miss.
    FIFOF#(Bit#(TLog#(fbsize))) ff_fb_fillindex <-mkSizedFIFOF(2);
    Wire#(Maybe#(Bit#(TLog#(fbsize)))) wr_fbbeingfilled <-mkDWire(tagged Invalid);

    // This register points to the entry in the FB which needs to be written back to the cache
    // whenever possible.
    Reg#(Bit#(TLog#(fbsize))) rg_fbwriteback <-mkReg(0);
    Reg#(Bit#(blocksize))     rg_fbfillenable <- mkReg(0);
    Reg#(Bool) rg_readdone <-mkDReg(False);
    
    Bit#(tagbits) writetag=fb_addr[rg_fbwriteback][v_paddr-1:v_paddr-v_tagbits];
    Bit#(linewidth) writedata=fb_dataline[rg_fbwriteback];

    Bool fb_full= (all(isTrue,readVReg(fb_valid)));
    Bool fb_empty=!(any(isTrue,readVReg(fb_valid)));
    Bit#(TLog#(sets)) fillindex=fb_addr[rg_fbwriteback][v_setbits+v_blockbits+v_wordbits-1:
                                                                          v_blockbits+v_wordbits];
    Bool fill_oppurtunity=(!ff_core_request.notEmpty || !wr_takingrequest) && !fb_empty &&
         /*countOnes(fb_valid)>0 &&*/ (fillindex!=rg_latest_index);
    // ------------------------------------------------------------------------------------------//

    // ----------------------------- structures for fence operation -----------------------------//
    Reg#(Bit#(ways)) rg_way_select<-mkReg(1);
    Reg#(Bit#(TLog#(sets))) rg_set_select <-mkReg(0);
    Reg#(Bool) rg_fence_pending <- mkReg(False);
    Reg#(Bool) rg_globaldirty <- mkReg(False);
    Reg#(Bool) rg_fenceinit <-mkReg(True);
    Wire#(RespState) wr_sb_response <- mkDWire(None);
    Wire#(Bit#(respwidth)) wr_sb_hitword <-mkDWire(0);
    Wire#(Bit#(respwidth)) wr_sb_hitword1 <-mkDWire(0);
    Wire#(Bit#(TLog#(sbsize))) wr_sbindexhit <-mkDWire(0);
    // ------------------------------------------------------------------------------------------//

    // -------------------------- Structures for store-buffer -----------------------------------//

    Reg#(Bit#(paddr)) store_addr [v_sbsize];
    Reg#(Bit#(respwidth)) store_data [v_sbsize];
    Reg#(Bit#(3)) store_size [v_sbsize];
    Vector#(sbsize,Reg#(Bool)) store_valid <-replicateM(mkReg(False));
    Reg#(Bit#(TLog#(fbsize))) store_fbindex [v_sbsize];
    Reg#(Bit#(esize)) store_epoch [v_sbsize];
    Reg#(Bit#(1)) store_io [v_sbsize];
    for (Integer i=0;i<v_sbsize;i=i+1)begin
      store_data[i]<-mkReg(0);
      store_valid[i]<-mkReg(False);
      store_size[i]<-mkReg(0);
      store_addr[i]<-mkReg(0);
      store_fbindex[i]<-mkReg(0);
      store_epoch[i]<-mkReg(0);
      store_io[i]<- mkReg(0);
    end
    Reg#(Bit#(TLog#(sbsize))) rg_storehead <-mkReg(0);
    Reg#(Bit#(TLog#(sbsize))) rg_storetail <- mkReg(0);
    Wire#(Bit#(linewidth)) wr_upd_fillingdata <-mkDWire(0);
    Wire#(Bit#(linewidth)) wr_upd_fillingmask <-mkDWire(0);
    Wire#(Bool) wr_perform_store <-mkDWire(False);
    Wire#(Bit#(esize)) wr_currepoch <-mkDWire(0);
    Wire#(Bool) wr_store_response <- mkDWire(False);
    Bool sb_full= (all(isTrue,readVReg(store_valid)));
    Bool sb_empty=!(any(isTrue,readVReg(store_valid)));
    // ------------------------------------------------------------------------------------------//

    rule display_stuff;
      if(verbosity!=0)begin
        $display($time,"\tDACHE: fb_full: %b fb_empty: %b rg_fbwriteback: %d rg_fbmissallocate: :%d"
          ,fb_full,fb_empty,rg_fbwriteback,rg_fbmissallocate);
        $display($time,"\tDCACHE: ff_core_response.notFull: %b rg_fence_stall: %b",
          ff_core_response.notFull,rg_fence_stall);
        $display($time,"\tDCACHE: sb_empty: %b sb_full: %b store_valid: %h",sb_empty,sb_full,readVReg(store_valid));
        $display($time,"\tDCACHE: fb_enables[wr]: %h rg_replaylatest: %b fb_valid[wr]",
        fb_enables[rg_fbwriteback],rg_replaylatest, fb_valid[rg_fbwriteback]);
      end
    endrule

    // This rull fires when the fence operation is signalled by the core and the FB is empty.
    // if the rg_global_dirty is not set then the dcache 
    // will take only a single cycle since all the valid signals in the cache and FB are registers
    // which can be reset in one-shot. The replacement policies for each set should also be reset.
    // Since they too are implemented as array of registers it can be done in a single cycle.
    // Additionaly, any set that has no dirty lines is immediately skipped. This improves fence
    // performance.
    rule fence_operation(tpl_2(ff_core_request.first) && rg_fence_stall && fb_empty &&
                                                !rg_replaylatest &&   sb_empty && !rg_fence_pending);
      Bit#(linewidth) dataline [v_ways];
      Bit#(tagbits) tag [v_ways];
      Bit#(linewidth) temp [v_ways];
      Bit#(linewidth) final_line =0;
      Bit#(TLog#(ways)) waynum = truncate(pack(countZerosLSB(rg_way_select)));
      Bit#(TSub#(paddr,TAdd#(tagbits,setbits))) zeros='d0;
      
      Bit#(TAdd#(1,TLog#(sets))) next_set={1'b0,rg_set_select}+1;
      Bit#(TAdd#(1,TLog#(sets))) index={1'b0,rg_set_select};

      Bit#(1) dirty_and_valid = rg_dirty[rg_set_select][waynum]&rg_valid[rg_set_select][waynum];
      for(Integer i=0;i<v_ways;i=i+1)begin
        dataline[i]<-data_arr[i].read_response();
        tag[i]<-tag_arr[i].read_response();
      end

      for(Integer i=0;i<v_ways;i=i+1)begin
        temp[i]=duplicate( dirty_and_valid & rg_way_select[i]) & dataline[i] ;
        final_line=final_line|temp[i];
      end
      Bit#(paddr) final_address={tag[waynum],rg_set_select,zeros};
      if(!rg_fenceinit && rg_globaldirty)begin
        if(rg_way_select[v_ways-1]==1 || rg_dirty[rg_set_select]==0)begin
          index=next_set;
        end
        if(unpack(dirty_and_valid))begin
          ff_write_mem_request.enq(tuple4(final_address,fromInteger(valueOf(blocksize)-1),
                                fromInteger(valueOf(TLog#(wordsize))),final_line));
          rg_fence_pending<=True;
        end
        rg_set_select<=truncate(index);
        if(rg_dirty[rg_set_select]!=0)
          rg_way_select<=rotateBitsBy(rg_way_select,1);
      end
      for(Integer i=0;i<v_ways;i=i+1)begin
        tag_arr[i].request(0,truncate(index),writetag);
        data_arr[i].request(0,truncate(index),writedata);// send request to all ways a set.
      end

      if ( (next_set==fromInteger(v_sets) && (rg_way_select[v_ways-1]==1 ||
              rg_dirty[rg_set_select]==0)) || !rg_globaldirty )begin
        for(Integer i=0;i<v_sets;i=i+1)begin
          rg_valid[i]<=0;
          rg_dirty[i]<=0;
        end
        for(Integer j=0;j<v_fbsize;j=j+1)begin
          fb_enables[j]<=0;
          fb_valid[j]<=False;
        end
        rg_fenceinit<=True;
        rg_fence_stall<=False;
        ff_core_request.deq;
        rg_globaldirty<=False;
        repl.reset_repl;
        ff_core_response.enq(tuple3(?,False,tpl_3(ff_core_request.first)));
        `ifdef simulate
          ff_meta.enq(0);
        `endif
      end
      else
        rg_fenceinit<=False;
      if(verbosity!=0)begin
        $display($time,"\tDCACHE: Fence operation in progress globaldirty: %b rg_fenceinit: %b",
                    rg_globaldirty,rg_fenceinit);
        $display($time,"\tDCACHE: rg_way_select: %b rg_set_select: %d index: %d next_set: %d",
            rg_way_select,rg_set_select,index,next_set);
      end
    endrule

    rule receive_memory_response(rg_fence_pending && tpl_2(ff_core_request.first));
      rg_fence_pending<=False;
      let x=ff_write_mem_response.first;
      ff_write_mem_response.deq;
    endrule

    // This rule will perform the check on the tags from the cache and detect is there is a hit or a
    // miss. On a hit the required word is forwarded to the rule respond_to_core. On a miss the
    // address is forwarded to the rule request_to_memory;
    rule tag_match(ff_core_response.notFull && !rg_miss_ongoing && !rg_polling &&
          !tpl_2(ff_core_request.first()) );
      let {addr, fence, epoch, access, size, data} =ff_core_request.first();
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={addr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(blockbits) word_index= addr[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(tagbits) request_tag = addr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];

      Bit#(linewidth) dataline[v_ways];
      Bit#(tagbits) tag[v_ways];
      for(Integer i=0;i<v_ways;i=i+1)begin
        tag[i]<- tag_arr[i].read_response;
        dataline[i]<- data_arr[i].read_response;
      end
      Bit#(linewidth) hitline=0;
      Bit#(ways) hit=0;

/*
      Bit#(linewidth) temp[v_ways]; // mask for each way dataline.
      // Find the line that was hit
      for(Integer i=0;i<v_ways;i=i+1)begin
        hit[i]=pack(tag[i]==request_tag && rg_valid[set_index][i]==1);
        temp[i]=duplicate(hit[i])&dataline[i];
      end
      for(Integer i=0;i<v_ways;i=i+1)
        hitline=hitline|temp[i];
*/
      for(Integer i=0;i<v_ways;i=i+1)begin
        if(rg_valid[set_index][i]==1 && request_tag==tag[i])begin
          hit[i]=1'b1;
          hitline=dataline[i];
        end
      end
      Bool cache_hit=unpack(|(hit));
      wr_hitway<=truncate(pack(countZerosLSB(hit)));
      wr_hitline<=hitline;
      Bit#(respwidth) response_word=truncate(hitline>>block_offset);
      if(cache_hit)begin
        wr_cache_response<=Hit;
        wr_cache_hitword<=response_word;
      end
      else begin
        wr_cache_response<=Miss;
      end

      if(verbosity!=0)begin
        $display($time,"\tDCACHE: TAGMATCH: addr:%h hit: %b hitline: %h access: %d size: %b",
            addr,hit,hitline,access,size);
      end

      `ifdef ASSERT
        dynamicAssert(countOnes(hit)<=1,"More than one way is a hit in the cache");
      `endif
    endrule

    // This rule will fire whenever a core request is present. This rule will check the entire FB if
    // the requested line and hence the word is present. A "TRUE" miss in the cache is only
    // generated when the line containing the requested word is not present in FB and the cache. 
    // There can be a case where the line requested is present but the word is not preset since it
    // is being filled by the lower level memory.
    rule check_fb_for_corerequest(ff_core_response.notFull && !tpl_2(ff_core_request.first));
      Bool wordhit=False;
      let {addr, fence, epoch, access, size, data} =ff_core_request.first();
      Bit#(tagbits) read_tag = addr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) read_set = addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={addr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(blockbits) word_index=addr[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(TAdd#(tagbits,setbits)) t=truncateLSB(addr);
      Bit#(fbsize) fbhit=0;
      Bit#(linewidth) hitline=0;
      Bit#(1) fberr =0;
 
 /*
      Bit#(linewidth) data_t [v_fbsize];
      for (Integer i=0; i<v_fbsize ; i=i+1) begin
        fbhit[i]=pack( truncateLSB(fb_addr[i])==t && fb_valid[i]==1 );
        data_t[i]=duplicate(fbhit[i])&fb_dataline[i];
        if(fb_enables[i][word_index]==1'b1)
            wordhit=(fbhit[i]==1'b1);
      end
      for(Integer i=0; i<v_fbsize ;i=i+1)
        hitline=hitline|data_t[i];
 */     
      
      for (Integer i=0;i<v_fbsize;i=i+1)begin
        // we use truncateLSB because we need to match only the tag and set bits
        if( truncateLSB(fb_addr[i])==t && fb_valid[i])begin
          hitline=fb_dataline[i];
          fbhit[i]=1;
          fberr=fb_err[i];
          if(fb_enables[i][word_index]==1'b1) begin
            wordhit=True;
          end
        end          
      end
      
      Bool linehit=unpack(|fbhit);
      if(wordhit)
        wr_fb_response<=Hit;
      else if(!linehit) // generate a miss only if the line is missing.
        wr_fb_response<=Miss;
      // setting this register will prevent the rule tag_match from firing when polling is expected.
      rg_polling<=(linehit && !wordhit);
      `ifdef simulate
        wrpolling<=rg_polling;
      `endif
      wr_fb_word<=truncate(hitline>>block_offset); 
      wr_fbindexhit<=truncate(pack(countZerosLSB(fbhit)));
      wr_fb_err<= fberr;

      if(verbosity!=0)begin
        $display($time,"\tDCACHE: Polling addr: %h linehit: %b wordhit: %b rg_polling: %b",
            addr,linehit,wordhit,rg_polling);
      end

      `ifdef ASSERT
        dynamicAssert(countOnes(fbhit)<=1,"More than one line in FB is hit");
      `endif
    endrule

    rule check_hit_in_storebuffer(ff_core_response.notFull && !tpl_2(ff_core_request.first));
      let {addr, fence, epoch, access, size, data} =ff_core_request.first();
      Bit#(TSub#(paddr,wordbits)) compareaddr=truncateLSB(addr);
      Bit#(respwidth) word=0;
      Bit#(sbsize) sbhit=0;
      for (Integer i=0;i<v_sbsize;i=i+1)begin
        if(store_valid[i] && compareaddr==truncateLSB(store_addr[i]))begin
          sbhit[i]=1;
          word=store_data[i];
        end
      end
      if(|sbhit==1)
        wr_sb_response<=Hit;
      else
        wr_sb_response<=Miss;
      wr_sb_hitword1<=word;
      Bit#(TAdd#(wordbits,3)) wordoffset={addr[v_wordbits-1:0],3'b0};
      Bit#(respwidth) coreword=word>>wordoffset;
      if(verbosity!=0)
        $display($time,"\tDCACHE: sbhit: %b word: %h store_addr: %h wordoffset: %d coreword: %h", 
                                                      sbhit, word, compareaddr, wordoffset,coreword);
      wr_sb_hitword<=coreword;
      wr_sbindexhit<=truncate(pack(countZerosLSB(sbhit)));
      `ifdef ASSERT
        dynamicAssert(countOnes(sbhit)<=1,"More than one line in SB is hit");
      `endif
    endrule

    rule update_storebuffer_onhit(tpl_4(ff_core_request.first)!=1 && (wr_cache_response==Hit || 
        wr_fb_response==Hit || wr_sb_response==Hit) && !tpl_2(ff_core_request.first()));
      let {addr, fence, epoch, access, size, data} =ff_core_request.first();
      Bit#(respwidth) mask = size[1:0]==0?'hFF:size[1:0]==1?'hFFFF:size[1:0]==2?'hFFFFFFFF:'1;
      Bit#(TAdd#(3,wordbits)) wordoffset={addr[v_wordbits-1:0],3'b0};
      Bit#(respwidth) hitword = wr_cache_hitword;
      Bit#(TLog#(fbsize)) fbindex = rg_fbmissallocate;
      Bit#(TLog#(sbsize)) sbindex = rg_storetail;

      mask=mask<<wordoffset;
      data = case (size[1:0])
          'b00: duplicate(data[7:0]);
          'b01: duplicate(data[15:0]);
          'b10: duplicate(data[31:0]);
          default: data;
      endcase;

      if(wr_sb_response==Hit)begin
        hitword=wr_sb_hitword1;
        sbindex=wr_sbindexhit;
      end
      else if(wr_fb_response==Hit)begin
        hitword=wr_fb_word;
        rg_storetail<=rg_storetail+1;
        fbindex=wr_fbindexhit;
      end
      else begin
        rg_storetail<=rg_storetail+1;
      end
      Bit#(respwidth) finalword=(mask&data)|(~mask&hitword);
      if(wr_sb_response!=Hit)begin
        store_data[sbindex]<=finalword;
        store_valid[sbindex]<=True;
        store_size[sbindex]<=size;
        store_addr[sbindex]<=addr;
        store_fbindex[sbindex]<=fbindex;
        store_io[sbindex]<=pack(isNonCacheable(addr,wr_cache_enable));
      end
      else begin
        store_data[sbindex]<=finalword;
      end
      store_epoch[sbindex]<=epoch;
      if(verbosity!=0)
        $display($time,"\tDCACHE: Updating SB. sbindex: %d data: %h addr: %h fbindex: %d",
            sbindex,data,addr,fbindex);
    endrule
    
    // This rule is fired when there is a hit in the cache. The word received is further modified
    // depending on the request made by the core.
    rule respond_to_core(wr_cache_response==Hit || wr_fb_response==Hit || wr_nc_response==Hit ||
    wr_sb_response==Hit);
      let {addr, fence, epoch, access, size, data} =ff_core_request.first();
      Bit#(respwidth) word=0;
      Bool err=False;
      Bit#(setbits) set_index=addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      if(wr_cache_response==Hit)begin
        word=wr_cache_hitword;
        if(alg=="PLRU") begin
          wr_cache_hitindex<=tagged Valid set_index;
          repl.update_set(set_index, wr_hitway);//wr_replace_line); 
        end
        `ifdef perf
          wr_total_cache_hits<=1;
        `endif
      end
      else if(wr_sb_response==Hit)begin
        word=wr_sb_hitword;
      end
      else if(wr_fb_response==Hit)begin
        word=wr_fb_word;
        err=unpack(wr_fb_err);
        `ifdef perf
          // Only when the hit in the LB is not because of a miss should the counter be enabled.
          if(!rg_miss_ongoing)
            wr_total_fb_hits<=1;
        `endif
      end
      else if(wr_nc_response==Hit)begin
        word=wr_nc_word;
        err=wr_nc_err;
        `ifdef perf
          wr_total_io<=1;
        `endif
      end
      if(access!=1 && (wr_fb_response==Hit || wr_cache_response==Hit))begin
        rg_globaldirty<=True;
      end

      // This captures a line from the cache RAMS into the Fill buffer on a store/atomic hit.
      if(access!=1 && wr_cache_response==Hit)begin
        rg_fbmissallocate<=rg_fbmissallocate+1;
        fb_valid[rg_fbmissallocate]<=True;
        fb_addr[rg_fbmissallocate]<=addr;
        fb_enables[rg_fbmissallocate]<='1;
        fb_dataline[rg_fbmissallocate]<=wr_hitline;
        fb_dirty[rg_fbmissallocate]<=rg_dirty[set_index][wr_hitway];
        rg_valid[set_index][wr_hitway]<=1'b0;

      end
      rg_miss_ongoing<=False;
      // depending onthe request made by the core, the word is either sigextended/zeroextend and
      // truncated if necessary.
      word=
        case (size)
          'b000: signExtend(word[7:0]);
          'b001: signExtend(word[15:0]);
          'b010: signExtend(word[31:0]);
          'b100: zeroExtend(word[7:0]);
          'b101: zeroExtend(word[15:0]);
          'b110: zeroExtend(word[31:0]);
          default: word;
        endcase;
      if(verbosity!=0)
        $display($time,"\tDCACHE: Sending response to core. Word: %h for address: %h",word,addr);
      ff_core_response.enq(tuple3(word,err,epoch));
      ff_core_request.deq;
      `ifdef ASSERT
        Bit#(3) temp=0;
        Bit#(3) temp1=0;
        if(wr_cache_response==Hit)begin
          temp[0]=1;
          temp1[0]=1;
        end
        if(wr_fb_response==Hit)begin
          temp[1]=1;
        end
        if(wr_nc_response==Hit)begin
          temp[2]=1;
          temp1[2]=1;
        end
        if(wr_sb_response==Hit)
          temp1[1]=1;
        dynamicAssert(countOnes(temp)<=1, "More than one data structure shows a hit");
        dynamicAssert(countOnes(temp1)<=1, "More than one data structure shows a hit");
      `endif
    endrule

    `ifdef simulate
      rule put_meta;
        if(wr_cache_response==Hit)
          ff_meta.enq(1);
        else if(wr_fb_response==Hit)
          ff_meta.enq(pack(!wrpolling));
      endrule
    `endif

    // This rule will generate a miss request to the next level memory. The address from the core
    // cannot be directly sent to the bus. The address will have to made word-aligned before sending
    // it to the next level.
    // Here as soon as a miss is detected we allocate a line in the fill buffer for the requested
    // access. The line-allocation is done using rg_fbmissallocate register which follows a
    // round-robin mechanism for now. 
    // the line to be filled is further enqued into the ff_fb_fillindex which is used to identify
    // which line is the memory response to fill in the FB
    rule request_to_memory(wr_cache_response==Miss && !rg_miss_ongoing && wr_fb_response==Miss
                                         && wr_sb_response==Miss && wr_nc_response!=Hit &&!fb_full);
                                                                                        
      let {addr, fence, epoch, access, size, data} =ff_core_request.first();
      if(isNonCacheable(addr,wr_cache_enable))begin
        ff_nc_read_request.enq(tuple3(addr,0,fromInteger(v_wordbits)));
        if(verbosity!=0)begin
          $display($time,"\tICACHE: Sending IO memory request. Addr: %h",addr);
        end
      end
      else begin
        addr= (addr>>v_wordbits)<<v_wordbits; // align the address to be one word aligned.
        ff_read_mem_request.enq(tuple3(addr,fromInteger(v_blocksize-1),fromInteger(v_wordbits)));
        rg_miss_ongoing<=True;
        rg_fbmissallocate<=rg_fbmissallocate+1;
        fb_valid[rg_fbmissallocate]<=True;
        fb_addr[rg_fbmissallocate]<=addr;
        fb_enables[rg_fbmissallocate]<=0;
        ff_fb_fillindex.enq(rg_fbmissallocate);
        
        if(verbosity!=0)begin
          $display($time,"\tDCACHE: Sending memory request. Addr: %h",addr);
          $display($time,"\tDCACHE: Allocating FB line: %d",rg_fbmissallocate);
        end
      end

    endrule

    // This rule will update an entry pointed by the entry in ff_fb_fillindex with the incoming
    // response from the lower memory level.
    rule update_fb_with_memory_response(!fb_empty);
      let {word,last,err}=ff_read_mem_response.first();
      let fbindex=ff_fb_fillindex.first();
      fb_err[fbindex]<=pack(err);
      ff_read_mem_response.deq;
      Bit#(blocksize) temp=0;
      Bit#(blockbits) word_index=fb_addr[fbindex][v_blockbits+v_wordbits-1:v_wordbits];
      if(fb_enables[fbindex]==0)
        temp=fn_enable(word_index);
      else
        temp=rg_fbfillenable;
      fb_enables[fbindex]<=fb_enables[fbindex]|temp;
      rg_fbfillenable <= {temp[valueOf(blocksize)-2:0],temp[valueOf(blocksize)-1]};

      Bit#(linewidth) mask=0;
      for (Integer i=0;i<v_blocksize;i=i+1)begin
        Bit#(respwidth) we=duplicate(temp[i]);
        mask[i*v_respwidth+v_respwidth-1:i*v_respwidth]=we;
      end
      
      Bit#(linewidth) final_mask = mask|wr_upd_fillingmask;
      Bit#(linewidth) final_data = (wr_upd_fillingmask&wr_upd_fillingdata)|(mask&duplicate(word));
      Bit#(linewidth) x=(~final_mask&fb_dataline[fbindex]) | (final_mask&final_data);
      fb_dataline[fbindex]<=x;
      if(last) begin
        ff_fb_fillindex.deq();
      end
      if(verbosity!=0)begin
        $display($time,"\tDCACHE: finalmask: %h final_data: %h",final_mask,final_data);
        $display($time,"\tDCACHE: Filling up FB. fbindex: %d fb_addr: %h fb_dataline: %h \
fb_enables: %h",fbindex,fb_addr[fbindex],fb_dataline[fbindex],fb_enables[fbindex]);
      end
      `ifdef ASSERT
        dynamicAssert(fb_enables[fbindex]!='1,"Filling FB with already filled line");
      `endif
      wr_fbbeingfilled<=tagged Valid fbindex;
    endrule
    rule receive_nc_response;
      let {word,last,err}=ff_nc_read_response.first;
      ff_nc_read_response.deq;
      wr_nc_err<=err;
      wr_nc_word<=word;
      wr_nc_response<=Hit;
      `ifdef ASSERT
        dynamicAssert(last,"Why is IO response a burst");
      `endif
    endrule
    
    // This rule will evict an entry from the fill-buffer and update it in the cache RAMS. Multiple
    // conditions under which this rule can fire:
    // 1. when the FB is full
    // 2. when the core is not requesting anything in a particular cycle and there exists a valid
    //    filled entry in the FB
    // 3. The rule will not fire when the entry being evicted is a line that has been recently
    // requested by the core (present in the ff_core_request). Writing this line would cause a
    // replay of the latest request. This would cause another cycle delay which would eventually be
    // a hit in the cache RAMS. 
    // 4. If while filling the RAM, it is found that the line being filled is dirty then a read
    // request for that line is sent. In the next cycle the read line is sent to memory and the line
    // from the FB is written into the RAM. Also in the next cycle a read-request for the latest
    // read from the core is replayed again.
    // 5. If the line being filled in the RAM is not dirty, then the FB line simply ovrwrites the
    // line in one=cycle. The latest request from the core is replayed if the replacement was to the
    // same index.
    rule release_from_FB((fb_full || fill_oppurtunity || rg_fence_stall) && !rg_replaylatest &&
              !fb_empty && fb_valid[rg_fbwriteback] && (&fb_enables[rg_fbwriteback])==1 && sb_empty);
      // if line is valid and is completely filled.
      let addr=fb_addr[rg_fbwriteback];
      Bit#(setbits) set_index=addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(tagbits) tag = addr[v_paddr-1:v_paddr-v_tagbits];
      let waynum<-repl.line_replace(set_index, rg_valid[set_index], rg_dirty[set_index]);
      // the line being replaced is dirty then evict it.
      if(fb_err[rg_fbwriteback]==0)begin
        if((rg_valid[set_index][waynum]&rg_dirty[set_index][waynum])==1 && !rg_readdone)begin
          if(verbosity!=0)begin
            $display($time,"\tDCACHE: release. Read request for dirty line. way: %d set_index: %d", 
                waynum,set_index);
          end
          tag_arr[waynum].request(0,set_index,writetag);
          data_arr[waynum].request(0,set_index,writedata);
          rg_readdone<=True;
        end
        else if((rg_valid[set_index][waynum]&rg_dirty[set_index][waynum])!=1 || rg_readdone)begin
          Bit#(TSub#(paddr,TAdd#(tagbits,setbits))) zeros='d0;
          let dirtytag<-tag_arr[waynum].read_response;
          let dirtydata<-data_arr[waynum].read_response;
          Bit#(paddr) final_address={dirtytag,set_index,zeros};
          if(rg_readdone)begin
            if(verbosity!=0)begin
              $display($time,"\tDCACHE: release. Write to mem. addr: %h data: %h", 
                  final_address,dirtydata);
            end
            ff_write_mem_request.enq(tuple4(final_address,fromInteger(valueOf(blocksize)-1),
                                  fromInteger(valueOf(TLog#(wordsize))),dirtydata));
          end
          rg_valid[set_index][waynum]<=1'b1;
          rg_dirty[set_index][waynum]<=fb_dirty[rg_fbwriteback];
          tag_arr[waynum].request(1,set_index,writetag);
          data_arr[waynum].request(1,set_index,writedata);
          rg_fbwriteback<=rg_fbwriteback+1;
          fb_valid[rg_fbwriteback]<=False;
          if((fb_full && fillindex==rg_latest_index) || rg_dirty[set_index][waynum]==1)
            rg_replaylatest<=True;
          if(&(rg_valid[set_index])==1)begin
            if(alg!="PLRU")
              repl.update_set(set_index,waynum);
            else begin
              if(wr_cache_hitindex matches tagged Valid .i &&& i==set_index)begin
              end
              else
                repl.update_set(set_index,waynum);
            end
          end
          if(verbosity!=0)begin
            $display($time,"\tDCACHE: release from FB firing");
            $display($time,"\tDCACHE: rg_fbwriteback: %d fb_valid: %b fb_enables: %b setindex: %d \
 addr:   %h way: %d fb_dataline: %h",
             rg_fbwriteback,fb_valid[rg_fbwriteback],fb_enables[rg_fbwriteback],set_index,
             fb_addr[rg_fbwriteback], waynum,fb_dataline[rg_fbwriteback]);
          end
        end
      end
      else begin 
        fb_valid[rg_fbwriteback]<= False;
        rg_fbwriteback<=rg_fbwriteback+1;
      end
      `ifdef perf
        wr_total_fbfills<=1;
      `endif
    endrule

    rule replay_latest_request(rg_replaylatest);
      rg_replaylatest<=False;
      for(Integer i=0;i<v_ways;i=i+1)begin
        data_arr[i].request(0,rg_latest_index,writedata);
        tag_arr[i].request(0,rg_latest_index,writetag);
      end
      if(verbosity!=0)begin
        $display($time,"\tDCACHE: replaying last request to index: %d maintain sync",rg_latest_index);
      end
    endrule

    rule update_store_inFB(wr_perform_store && !sb_empty);
      let fbindex=store_fbindex[rg_storehead];
      let addr = store_addr[rg_storehead];
      let data = store_data[rg_storehead];
      let valid = store_valid[rg_storehead];
      let size = store_size[rg_storehead];
      let epoch = store_epoch[rg_storehead];
      let io = store_io[rg_storehead];
      Bit#(linewidth) mask = size[1:0]==0?'hFF:size[1:0]==1?'hFFFF:size[1:0]==2?'hFFFFFFFF:'1;
      Bit#(wordbits) zeros=0;
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits))) block_offset=
                                    {addr[v_blockbits+v_wordbits-1:0],3'b0};
      mask=mask<<block_offset;
      if(epoch==wr_currepoch)begin
        if(io==1)begin
          ff_nc_write_request.enq(tuple4(addr,0,size,data));
        end
        else begin
          wr_store_response<=True;
          if(wr_fbbeingfilled matches tagged Valid .fbi &&& fbindex==fbi)begin
            wr_upd_fillingmask<=mask;
            wr_upd_fillingdata<=duplicate(data);
            if(verbosity!=0)
              $display($time,"\tDCACHE: Store to FB being filled. mask: %h data: %h",mask,data);
          end
          else begin
            if(verbosity!=0)
              $display($time,"\tDCACHE: Store to FB index: %d. mask: %h data: %h",fbindex,mask,data);
            fb_dataline[fbindex]<= (mask&duplicate(data)) |(~mask&fb_dataline[fbindex]);
          end
          $display($time,"\tDCACHE: Store to FB. rg_storehead: %d",rg_storehead);
          fb_dirty[fbindex]<=1'b1;
        end
      end
      else if(verbosity!=0)
        $display($time,"\tDCACHE: Dropping Store for addr: %h store_head: %d",addr,rg_storehead);
      rg_storehead<=rg_storehead+1;
      store_valid[rg_storehead]<=False;
      `ifdef ASSERT
        dynamicAssert(store_valid[rg_storehead],"Performing Store on invalid entry in SB");
      `endif
    endrule


    interface core_req=interface Put
      method Action put(DCore_request#(paddr,respwidth,esize) req)if( ff_core_response.notFull &&
                                !rg_replaylatest &&  !rg_fence_stall && !fb_full);
        `ifdef perf
          wr_total_access<=1;
        `endif
        let {addr, fence, epoch, access, size, data} =req;
        Bit#(setbits) set_index=addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=fence;
        for(Integer i=0;i<v_ways;i=i+1)begin
          data_arr[i].request(0,set_index,writedata);
          tag_arr[i].request(0,set_index,writetag);
        end
        wr_takingrequest<=True;
        if (verbosity!=0) begin
		      $display($time,"\tDCACHE: Receiving request to address:%h Fence: %b epoch: %b index: %d \
access: %d size: %b data:%h", addr, fence, epoch, set_index,  access,  size,  data); 
        end
        rg_latest_index<=set_index;
      endmethod
    endinterface;

    interface core_resp = interface Get
      method ActionValue#(DCore_response#(respwidth,esize)) get();
        ff_core_response.deq;
        return ff_core_response.first;
      endmethod
    endinterface;
    
    interface read_mem_req = interface Get
      method ActionValue#(DMem_read_request#(paddr)) get;
        ff_read_mem_request.deq;
        return ff_read_mem_request.first;
      endmethod
    endinterface;

    interface read_mem_resp= interface Put
     method Action put(DMem_read_response#(respwidth) resp);
        ff_read_mem_response.enq(resp);
     endmethod
    endinterface;
    
    interface nc_read_req = interface Get
      method ActionValue#(DMem_read_request#(paddr)) get;
        ff_nc_read_request.deq;
        return ff_nc_read_request.first;
      endmethod
    endinterface;

    interface nc_read_resp= interface Put
     method Action put(DMem_read_response#(respwidth) resp);
        ff_nc_read_response.enq(resp);
     endmethod
    endinterface;
    `ifdef simulate 
      interface meta = interface Get
        method ActionValue#(Bit#(1)) get();
          ff_meta.deq;
          return ff_meta.first;
        endmethod
      endinterface;
    `endif 
    method Action cache_enable(Bool c);
      wr_cache_enable<=c;
    endmethod

    method Action perform_store(Bit#(esize) currepoch);
      wr_perform_store <= True;
      wr_currepoch<=currepoch;
    endmethod
    `ifdef perf
      method Bit#(5) perf_counters;
        return {wr_total_fbfills,wr_total_io,wr_total_fb_hits,wr_total_cache_hits,wr_total_access};
      endmethod
    `endif
    interface write_mem_req = interface Get
      method ActionValue#(DMem_write_request#(paddr,TMul#(blocksize,TMul#(wordsize,8)))) get;
        ff_write_mem_request.deq;
        return ff_write_mem_request.first;
      endmethod
    endinterface;

    interface write_mem_resp= interface Put
     method Action put(DMem_write_response resp);
        ff_write_mem_response.enq(resp);
     endmethod
    endinterface;
    
    interface nc_write_req = interface Get
      method ActionValue#(DMem_write_request#(paddr,TMul#(wordsize,8))) get;
        ff_nc_write_request.deq;
        return ff_nc_write_request.first;
      endmethod
    endinterface;

    interface nc_write_resp= interface Put
     method Action put(DMem_write_response resp);
        ff_nc_write_response.enq(resp);
     endmethod
    endinterface;

    method cache_available = ff_core_request.notFull && ff_core_response.notFull && 
                                                  !rg_replaylatest &&  !rg_fence_stall && !fb_full;
    method storebuffer_empty = sb_empty;
    method store_response=wr_store_response;

  endmodule
 
  function Bool isIO(Bit#(32) addr, Bool cacheable);
    if(!cacheable)
      return True;
    else if( addr < 4096)
      return True;
    else
      return False;    
  endfunction


  (*synthesize*)
  module mkdcache(Ifc_l1dcache#(4, 8, 64, 4 ,32,8,4,1));
    let ifc();
    mkl1dcache#(isIO, "PLRU") _temp(ifc);
    return (ifc);
  endmodule
endpackage

