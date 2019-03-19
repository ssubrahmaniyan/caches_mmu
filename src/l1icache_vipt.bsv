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
  list of performance counters:
  0. Total accesses
  1. Total Hits in Cache
  2. Total Hits in LB
  3. Total IO requests
  4. Total Fills from FB to Cache
  
--------------------------------------------------------------------------------------------------
*/
package l1icache_vipt;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import FIFO::*;
  import Assert::*;
  import GetPut::*;
  import BUtils::*;

  import globals::*;
  import cache_types::*;
  import mem_config::*;
  import replacement::*;
  `include "cache.defines"
  `include "Logger.bsv"
  
  interface Ifc_l1icache#( numeric type wordsize, 
                           numeric type blocksize,  
                           numeric type sets,
                           numeric type ways,
                           numeric type paddr,
                           numeric type vaddr,
                           numeric type fbsize,
                           numeric type esize, 
                           numeric type dbanks,
                           numeric type tbanks,
                           numeric type buswidth
                           );

    interface Put#(ICache_request#(vaddr,esize)) core_req;
    interface Get#(FetchResponse#(TMul#(wordsize,8),esize)) core_resp;
    interface Get#(ICache_mem_request#(paddr)) read_mem_req;
    interface Put#(ICache_mem_response#(buswidth)) read_mem_resp;
    interface Get#(ICache_mem_request#(paddr)) nc_read_req;
    interface Put#(ICache_mem_response#(TMul#(wordsize,8))) nc_read_resp;
    interface Put#(ITLB_core_response#(paddr)) pa_from_tlb;
    `ifdef pysimulate
      interface Get#(Bit#(1)) meta;
    `endif
    `ifdef perf
      method Bit#(5) perf_counters;
    `endif
    method Action cache_enable(Bool c);
  endinterface

  (*conflict_free="request_to_memory,update_fb_with_memory_response"*)
  (*conflict_free="respond_to_core,fence_operation"*)
  (*conflict_free="request_to_memory,fence_operation"*)
  (*conflict_free="request_to_memory,release_from_FB"*)
  (*conflict_free="respond_to_core,release_from_FB"*)
  module mkl1icache#(function Bool isNonCacheable(Bit#(paddr) addr, Bool cacheable), parameter String alg)
    (Ifc_l1icache#(wordsize,blocksize,sets,ways,paddr,vaddr,fbsize,esize,dbanks,tbanks,buswidth)) 
    provisos(
          Mul#(wordsize, 8, respwidth),        // respwidth is the total bits in a word
          Mul#(blocksize, respwidth,linewidth),// linewidth is the total bits in a cache line
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset, 
          Add#(tagbits, _b, paddr),     // tagbits = 32-(wordbits+blockbits+setbits)
          Div#(buswidth,respwidth,o__), 
          Add#(o__, p__, 2),            // ensure that the buswidth is no more than twice the size of respwidth

          `ifdef ASSERT
          Add#(1, e__, TLog#(TAdd#(1, fbsize))),
          Add#(1, f__, TLog#(TAdd#(1, ways))),
          `endif

          // for dbanks
          Add#(m__, TDiv#(linewidth, dbanks), linewidth),
          Mul#(TDiv#(linewidth, dbanks), dbanks, linewidth),

          Add#(n__, TDiv#(tagbits, tbanks), tagbits),
          Mul#(TDiv#(tagbits, tbanks), tbanks, tagbits),

          Add#(a__, respwidth, linewidth),
          Add#(b__, 32, respwidth),
          Add#(c__, 16, respwidth),
          Add#(d__, 8, respwidth),
          Add#(TAdd#(tagbits, setbits), g__, paddr),
          Add#(TAdd#(tagbits, setbits), l__, vaddr),
          Add#(h__, 1, blocksize),
          Mul#(buswidth, q__, linewidth),

          Add#(i__, TLog#(ways), 4),
          Mul#(TDiv#(linewidth, 8), 8, linewidth),
          Add#(j__, TDiv#(linewidth, 8), linewidth),
          Add#(k__, TLog#(ways), TLog#(TAdd#(1, ways)))
          
    );

    String icache = "";
    let v_sets=valueOf(sets);
    let v_setbits=valueOf(setbits);
    let v_wordbits=valueOf(wordbits);
    let v_blockbits=valueOf(blockbits);
    let v_linewidth=valueOf(linewidth);
    let v_tagbits=valueOf(tagbits);
    let v_paddr=valueOf(paddr);
    let v_ways=valueOf(ways);
    let v_wordsize=valueOf(wordsize);
    let v_blocksize=valueOf(blocksize);
    let v_fbsize=valueOf(fbsize);
    let v_respwidth=valueOf(respwidth);

    //Following function returns the info regarding word_position in line getting filled
    function Bit#(blocksize) fn_enable(Bit#(blockbits)word_index);
       Bit#(blocksize) write_enable ='h0; //
       write_enable[word_index]=1;
       for(Integer i=0;i<valueOf(TDiv#(buswidth,respwidth));i=i+1)
         write_enable[word_index+fromInteger(i)]=1;
       return write_enable;
    endfunction
    function Bool isTrue(Bool a);
      return a;
    endfunction
    function Bool isOne(Bit#(1) a);
      return unpack(a);
    endfunction
  
//    String alg ="RROBIN";

    // ----------------------- FIFOs to interact with interface of the design -------------------//
    // This fifo stores the request from the core.
    FIFOF#(ICache_request#(vaddr,esize)) ff_core_request <- mkSizedFIFOF(2); 
    // This fifo stores the response that needs to be sent back to the core.
    FIFOF#(FetchResponse#(respwidth,esize))ff_core_response <- mkBypassFIFOF();
    // this fifo stores the read request that needs to be sent to the next memory level.
    FIFOF#(ICache_mem_request#(paddr)) ff_read_mem_request    <- mkSizedFIFOF(2);
    // This fifo stores the response from the next level memory.
    FIFOF#(ICache_mem_response#(buswidth)) ff_read_mem_response  <- mkBypassFIFOF();
    
    FIFOF#(ICache_mem_request#(paddr)) ff_nc_read_request    <- mkSizedFIFOF(2);
    // This fifo stores the response from the next level memory.
    FIFOF#(ICache_mem_response#(respwidth)) ff_nc_read_response  <- mkBypassFIFOF();

    // The following wire holds the physical address from TLB
    //Wire#(Tuple3#(Bit#(paddr),Bool,Bit#(6))) wr_from_tlb <- mkWire();
    FIFOF#(ITLB_core_response#(paddr)) ff_from_tlb <- mkBypassFIFOF();
    
    Wire#(Bool) wr_takingrequest <- mkDWire(False);
    Wire#(Bool) wr_cache_enable<-mkWire();
    `ifdef pysimulate
      FIFOF#(Bit#(1)) ff_meta <- mkSizedFIFOF(2);
    `endif
    `ifdef perf
      Wire#(Bit#(1)) wr_total_access <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_cache_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_fb_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_nc <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_fbfills <- mkDWire(0);
    `endif
    // ------------------------------------------------------------------------------------------//

   
    // ------------------------ Structures required for cache RAMS ------------------------------//
    Ifc_mem_config1rw#(sets, linewidth, dbanks) data_arr [v_ways]; // data array
    Ifc_mem_config1rw#(sets, tagbits, tbanks) tag_arr [v_ways];// one extra valid bit
    for(Integer i=0;i<v_ways;i=i+1)begin
      data_arr[i]<-mkmem_config1rw(False, "single"); 
      tag_arr[i]<-mkmem_config1rw(False, "single");
    end
    Ifc_replace#(sets,ways) replacement <- mkreplace(alg);
    Reg#(Bit#(ways)) rg_valid[v_sets];
    for(Integer i=0;i<v_sets;i=i+1)begin
      rg_valid[i]<-mkReg(0);
    end
    Wire#(RespState) wr_ram_response <- mkDWire(None);
    Wire#(Bit#(respwidth)) wr_ram_hitword <-mkDWire(0);
    Wire#(Bit#(TLog#(ways))) wr_ram_hitway <-mkDWire(0);
    Wire#(Maybe#(Bit#(TLog#(sets)))) wr_ram_hitindex <-mkDWire(tagged Invalid);
    // ------------------------------------------------------------------------------------------//

    // -------------------------- Common State control structures -------------------------------//
    Reg#(Bool) rg_miss_ongoing <- mkReg(False);
    Reg#(Bool) rg_fence_stall <- mkReg(False);
    Reg#(Bit#(TLog#(sets))) rg_latest_index<- mkReg(0);
    Reg#(Bool) rg_replaylatest<-mkReg(False);
    // ----------------------------------------------------------------------------------------- //

    // -------------------------------- None Cacheable Strcutures ------------------------------ //
    Wire#(RespState) wr_nc_response <- mkDWire(None);
    Wire#(Bit#(respwidth)) wr_nc_word <-mkDWire(0);
    Wire#(Bool) wr_nc_err <-mkDWire(False);
    // ------------------------------------------------------------------------------------------//


    // ----------------- Fill buffer structures -------------------------------------------------//
    Reg#(Bit#(linewidth)) fb_dataline [v_fbsize];
    Reg#(Bit#(paddr)) fb_addr [v_fbsize];
    Reg#(Bit#(blocksize)) fb_enables [v_fbsize];
    Reg#(Bit#(1)) fb_err [v_fbsize];
    Vector#(fbsize,Reg#(Bool)) fb_valid<-replicateM(mkReg(False));
    for(Integer i=0;i<v_fbsize;i=i+1)begin
      fb_dataline[i]<-mkReg(0);
      fb_addr[i]<-mkReg(0);
      fb_enables[i]<-mkReg(0);
      fb_err[i]<-mkReg(0);
    end
    Wire#(RespState) wr_fb_response <- mkDWire(None);
    Wire#(Bit#(respwidth)) wr_fb_word <-mkDWire(0);
    Wire#(Bit#(1)) wr_fb_err <-mkDWire(0);
    Reg#(Bool) rg_fb_err <-mkDReg(False);
    // this register is used to ensure that the cache does not do a tag match when FB is polling on
    // a line for the requested word.
    Reg#(Bool) rg_polling <-mkReg(False);
    `ifdef pysimulate
      Wire#(Bool) wrpolling<-mkDWire(False);
    `endif

    // This register indicates which entry in the FB should be allocated when there is miss in the
    // FB and the cache for a given request.
    Reg#(Bit#(TLog#(fbsize))) rg_fbmissallocate <-mkReg(0);

    // This register follows the rg_fbmissallocate register but is updated when the last word of a
    // line is filled in the FB on a miss.
    // Reg#(Bit#(TLog#(fbsize))) rg_fbbeingfilled <-mkReg(0);
    FIFOF#(Bit#(TLog#(fbsize))) ff_fb_fillindex<-mkSizedFIFOF(2);

    // This register points to the entry in the FB which needs to be written back to the cache
    // whenever possible.
    Reg#(Bit#(TLog#(fbsize))) rg_fbwriteback <-mkReg(0);
    Reg#(Bit#(blocksize))     rg_fbfillenable <- mkReg(0);

    Bool fb_full= (all(isTrue,readVReg(fb_valid)));
    Bool fb_empty=!(any(isTrue,readVReg(fb_valid)));
    Bit#(TLog#(sets)) fillindex=fb_addr[rg_fbwriteback][v_setbits+v_blockbits+v_wordbits-1:
                                                                          v_blockbits+v_wordbits];
    Bool fill_oppurtunity=(!ff_core_request.notEmpty || !wr_takingrequest) && !fb_empty &&
         /*countOnes(fb_valid)>0 &&*/ (fillindex!=rg_latest_index);
    Bit#(tagbits) writetag=fb_addr[rg_fbwriteback][v_paddr-1:v_paddr-v_tagbits];
    Bit#(linewidth) writedata=fb_dataline[rg_fbwriteback];
    // ------------------------------------------------------------------------------------------//
    // ----------------------------- Structures for MMU support ---------------------------------//
    Wire#(Bool) wr_trap_from_tlb <- mkDWire(False);
    // ------------------------------------------------------------------------------------------//


    rule display_stuff;
      `logLevel( icache, 2, $format("ICACHE: fbfull:%b fbempty:%b rgfbwb:%d rgfbmiss:%d", fb_full,
                                                      fb_empty, rg_fbwriteback, rg_fbmissallocate))
    endrule

    // This rull fires when the fence operation is signalled by the core. For the i-cache this rule
    // will take only a single cycle since all the valid signals in the cache and FB are registers
    // which can be reset in one-shot. The replacement policies for each set should also be reset.
    // Since they too are implemented as array of registers it can be done in a single cycle.
    rule fence_operation(ff_core_request.first.fence && rg_fence_stall && fb_empty);
      for(Integer i=0;i<v_sets;i=i+1)
        rg_valid[i]<=0;
      for(Integer i=0;i<v_fbsize;i=i+1)
        fb_valid[i]<=False;
      rg_fence_stall<=False;
      ff_core_request.deq; 
      replacement.reset_repl;
      `logLevel( icache, 0, $format("FEnce operation in progress"))
    endrule
    
    // This rule is fired when there is a hit in the cache. The word received is further modified
    // depending on the request made by the core.
    rule respond_to_core(wr_ram_response==Hit || wr_fb_response==Hit || wr_nc_response==Hit ||
                                                                                  wr_trap_from_tlb);
      let req = ff_core_request.first();
      let pa = ff_from_tlb.first;
      Bit#(respwidth) word=0;
      Bool err=False;
      let set_index=req.address[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      if(wr_ram_response==Hit)begin
        word=wr_ram_hitword;
        if(alg=="PLRU") begin
          wr_ram_hitindex<=tagged Valid set_index;
          replacement.update_set(set_index, wr_ram_hitway);//wr_replace_line); 
        end
        `ifdef perf
          wr_total_cache_hits<=1;
        `endif
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
          wr_total_nc<=1;
        `endif
      end
      rg_miss_ongoing<=False;
      // depending onthe request made by the core, the word is either sigextended/zeroextend and
      // truncated if necessary.
      `logLevel( icache, 0, $format("ICACHE: Sending Response word:%h for Addr:%h", word, req.address))
      if(!pa.trap && err)begin
        pa.cause=`Inst_access_fault;
        pa.trap=True;
      end
      ff_core_response.enq(FetchResponse{instr:word, trap: pa.trap, cause:pa.cause, epochs:req.epochs});
      ff_core_request.deq;
      ff_from_tlb.deq;
      `ifdef pysimulate
        if(wr_ram_response==Hit)
          ff_meta.enq(1);
        else
          ff_meta.enq(0);
      `endif
      `ifdef ASSERT
        dynamicAssert(!(wr_ram_response==Hit && wr_fb_response==Hit),
                                                  "Cache and FB both are hit simultaneously");
        dynamicAssert(!(wr_nc_response==Hit && wr_fb_response==Hit),
                                                  "IO and FB both are hit simultaneously");
        dynamicAssert(!(wr_ram_response==Hit && wr_nc_response==Hit),
                                                  "Cache and IO both are hit simultaneously");
      `endif
    endrule

    // This rule will perform the check on the tags from the cache and detect is there is a hit or a
    // miss. On a hit the required word is forwarded to the rule respond_to_core. On a miss the
    // address is forwarded to the rule request_to_memory;
    rule tag_match(ff_core_response.notFull && !rg_miss_ongoing && !rg_polling &&
          !ff_core_request.first.fence);
      let req =ff_core_request.first();
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={req.address[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(blockbits) word_index= req.address[v_blockbits+v_wordbits-1:v_wordbits];
      let pa = ff_from_tlb.first;
      Bit#(tagbits) request_tag = pa.address[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= req.address[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];

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
      wr_ram_hitway<=truncate(pack(countZerosLSB(hit)));
      Bit#(respwidth) response_word=truncate(hitline>>block_offset);
      if(pa.trap) begin
        wr_trap_from_tlb<=True;
      end
      else if(cache_hit)begin
        wr_ram_response<=Hit;
        wr_ram_hitword<=response_word;
      end
      else begin
        wr_ram_response<=Miss;
      end
      `logLevel( icache, 0, $format("ICACHE : TAGCMP for Req: ",fshow(req)))
      `logLevel( icache, 0, $format("ICACHE : ",fshow(pa)))
      `logLevel( icache, 1, $format("ICACHE : TAGCMP Result. Hit:%b Hitline:%h",hit, hitline))

      `ifdef ASSERT
        dynamicAssert(countOnes(hit)<=1,"More than one way is a hit in the cache");
      `endif
    endrule

    // This rule will fire whenever a core request is present. This rule will check the entire FB if
    // the requested line and hence the word is present. A "TRUE" miss in the cache is only
    // generated when the line containing the requested word is not present in FB and the cache. 
    // There can be a case where the line requested is present but the word is not preset since it
    // is being filled by the lower level memory.
    rule check_fb_for_corerequest(ff_core_response.notFull && !ff_core_request.first.fence);
      Bool wordhit=False;
      let req =ff_core_request.first();
      let pa = ff_from_tlb.first;
      Bit#(setbits) read_set = req.address[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={req.address[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(blockbits) word_index=req.address[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(TAdd#(tagbits,setbits)) t=truncateLSB(pa.address);
      Bit#(fbsize) fbhit=0;
      Bit#(linewidth) hitline=0;
      Bit#(1) fberr = 0;
 
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
          fberr=fb_err[i];
          fbhit[i]=1;
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
      `ifdef pysimulate
        wrpolling<=rg_polling;
      `endif
      wr_fb_word<=truncate(hitline>>block_offset); 
      wr_fb_err <= fberr;

      `logLevel( icache, 0, $format("ICACHE : FB Polling for Req: ",fshow(req)))
      `logLevel( icache, 1, $format("ICACHE : FP Polling Result. linehit:%b wordhit:%b", 
                                    linehit, wordhit))

      `ifdef ASSERT
        dynamicAssert(countOnes(fbhit)<=1,"More than one line in FB is hit");
      `endif
    endrule

    // This rule will generate a miss request to the next level memory. The address from the core
    // cannot be directly sent to the bus. The address will have to made word-aligned before sending
    // it to the next level.
    // Here as soon as a miss is detected we allocate a line in the fill buffer for the requested
    // access. The line-allocation is done using rg_fbmissallocate register which follows a
    // round-robin mechanism for now. 
    // the register rg_fbbeingfilled follows the rg_fbmissallocate but gets updated only when the
    // entire line in the FB has been filled.
    // It is not possible at any point of time for rg_fbmissallocate and rg_fbbeingfilled to update
    // the same entry in the FB.
    rule request_to_memory(wr_ram_response==Miss && !rg_miss_ongoing && wr_fb_response==Miss
                                          && wr_nc_response!=Hit &&!fb_full && !wr_trap_from_tlb);
                                                                                        
      let req =ff_core_request.first();
      let pa = ff_from_tlb.first;
      if(isNonCacheable(pa.address,wr_cache_enable))begin 
        ff_nc_read_request.enq(ICache_mem_request{  address    : pa.address,
                                                    burst_len  : 0,
                                                    burst_size : fromInteger(v_wordbits)});
        `logLevel( icache, 0, $format("ICACHE : Sending IO Request for Addr:%h", pa.address))
      end
      else begin
        `logLevel( icache, 0, $format("ICACHE : Sending Line Request for Addr:%h", pa.address)) 
        `logLevel( icache, 1, $format("ICACHE : Allocating FBindex:", rg_fbmissallocate)) 
        let shift_amount = valueOf(TLog#(TDiv#(buswidth,8)));
        pa.address= (pa.address>>shift_amount)<<shift_amount; // align the address to be one word aligned.
        let burst_len = (v_blocksize/valueOf(TDiv#(buswidth,respwidth)))-1;
        let burst_size = valueOf(TLog#(TDiv#(buswidth,8)));
        ff_read_mem_request.enq(ICache_mem_request{ address    : pa.address,
                                                    burst_len  : fromInteger(burst_len),
                                                    burst_size : fromInteger(burst_size)});
        rg_fbmissallocate<=rg_fbmissallocate+1;
        fb_valid[rg_fbmissallocate]<=True;
        fb_addr[rg_fbmissallocate]<=pa.address;
        fb_enables[rg_fbmissallocate]<=0;
        ff_fb_fillindex.enq(rg_fbmissallocate);
      end
      rg_miss_ongoing<=True;
    endrule

    // This rule will update an entry pointed by the register rg_fbbeingfilled with the incoming
    // response from the lower memory level.
    rule update_fb_with_memory_response;
      let response=ff_read_mem_response.first();
      rg_fb_err<=response.err;
      ff_read_mem_response.deq;
      let fbindex=ff_fb_fillindex.first();
      Bit#(blocksize) temp=0;
      Bit#(blockbits) word_index=fb_addr[fbindex][v_blockbits+v_wordbits-1:v_wordbits];
      if(fb_enables[fbindex]==0)
        temp=fn_enable(word_index);
      else
        temp=rg_fbfillenable;
      fb_enables[fbindex]<=fb_enables[fbindex]|temp;
      let rotate_amount = valueOf(TDiv#(buswidth,respwidth));
      rg_fbfillenable <=rotateBitsBy(temp,fromInteger(rotate_amount));

      Bit#(linewidth) mask=0;
      for (Integer i=0;i<v_blocksize;i=i+1)begin
        Bit#(respwidth) we=duplicate(temp[i]);
        mask[i*v_respwidth+v_respwidth-1:i*v_respwidth]=we;
      end
      fb_dataline[fbindex]<=(~mask&fb_dataline[fbindex])|(mask&duplicate(response.data));
      fb_err[fbindex]<=pack(response.err);
      if(response.last)
        ff_fb_fillindex.deq();

      `logLevel( icache, 0, $format("ICACHE : Received from mem: ",fshow(ff_read_mem_response.first)))
      `logLevel( icache, 2, $format("ICACHE : Filling FB. fbindex:%d fb_addr:%h fb_data:%h \
fbenable:%h", fbindex, fb_addr[fbindex], fb_dataline[fbindex], fb_enables[fbindex]))
        
    endrule

    rule receive_nc_response;
      let response=ff_nc_read_response.first;
      ff_nc_read_response.deq;
      wr_nc_err<=response.err;
      wr_nc_word<=response.data;
      wr_nc_response<=Hit;
      `ifdef ASSERT
        dynamicAssert(response.last,"Why is IO response a burst?");
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
    rule release_from_FB((fb_full || fill_oppurtunity || rg_fence_stall) && !rg_replaylatest &&
              !fb_empty && fb_valid[rg_fbwriteback] && (&fb_enables[rg_fbwriteback])==1);
      // if line is valid and is completely filled.
      let addr=fb_addr[rg_fbwriteback];
      Bit#(setbits) set_index=addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      if(fb_err[rg_fbwriteback]==0)begin
        let waynum<-replacement.line_replace(set_index, rg_valid[set_index]);
        if(&(rg_valid[set_index])==1)begin
          if(alg!="PLRU")
            replacement.update_set(set_index,waynum);
          else begin
            if(wr_ram_hitindex matches tagged Valid .i &&& i==set_index)begin
            end
            else
              replacement.update_set(set_index,waynum);
          end
        end
        tag_arr[waynum].request(1'b1,set_index,writetag);
        data_arr[waynum].request(1'b1,set_index,writedata);
        rg_valid[set_index][waynum]<=1'b1;
        if(fb_full && fillindex==rg_latest_index)
          rg_replaylatest<=True;
        `ifdef perf
          wr_total_fbfills<=1;
        `endif
        `logLevel( icache, 1, $format("ICACHE : ReleaseFiring. rg_fbwb:%d index:%d tag:%h way:%d", 
                                         rg_fbwriteback, set_index, writetag, waynum))
      end

      rg_fbwriteback<=rg_fbwriteback+1;
      fb_valid[rg_fbwriteback]<=False;
    endrule

    rule replay_latest_request(rg_replaylatest);
      rg_replaylatest<=False;
      for(Integer i=0;i<v_ways;i=i+1)begin
        data_arr[i].request(1'b0,rg_latest_index,writedata);
        tag_arr[i].request(1'b0,rg_latest_index,writetag);
      end
      `logLevel( icache, 1, $format("ICACHE : Replaying last request for index:%d", rg_latest_index))
    endrule

    interface core_req=interface Put
      method Action put(ICache_request#(vaddr,esize) req)if( ff_core_response.notFull &&
                                !rg_replaylatest &&  !rg_fence_stall && !fb_full);
        `ifdef perf
          wr_total_access<=1;
        `endif
        Bit#(setbits) set_index=req.address[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=req.fence;
        for(Integer i=0;i<v_ways;i=i+1)begin
          data_arr[i].request(1'b0,set_index,writedata);
          tag_arr[i].request(1'b0,set_index,writetag);
        end
        wr_takingrequest<=True;
        `logLevel( icache, 0, $format("ICACHE : Receiving request: ",fshow(req)))
        rg_latest_index<=set_index;
      endmethod
    endinterface;
    interface pa_from_tlb = toPut(ff_from_tlb);


    interface core_resp = interface Get
      method ActionValue#(FetchResponse#(respwidth,esize)) get();
        ff_core_response.deq;
        return ff_core_response.first;
      endmethod
    endinterface;
    
    interface read_mem_req = interface Get
      method ActionValue#(ICache_mem_request#(paddr)) get;
        ff_read_mem_request.deq;
        return ff_read_mem_request.first;
      endmethod
    endinterface;

    interface read_mem_resp= interface Put
     method Action put(ICache_mem_response#(buswidth) resp);
        ff_read_mem_response.enq(resp);
     endmethod
    endinterface;
    
    interface nc_read_req = interface Get
      method ActionValue#(ICache_mem_request#(paddr)) get;
        ff_nc_read_request.deq;
        return ff_nc_read_request.first;
      endmethod
    endinterface;

    interface nc_read_resp= interface Put
     method Action put(ICache_mem_response#(respwidth) resp);
        ff_nc_read_response.enq(resp);
     endmethod
    endinterface;
    `ifdef pysimulate 
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
    `ifdef perf
      method Bit#(5) perf_counters;
        return {wr_total_fbfills,wr_total_nc,wr_total_fb_hits,wr_total_cache_hits,wr_total_access};
      endmethod
    `endif
  endmodule
 
//  function Bool isIO(Bit#(32) addr, Bool cacheable);
//    if(!cacheable)
//      return True;
//    else if( addr < 4096)
//      return True;
//    else
//      return False;    
//  endfunction
//
//
//  (*synthesize*)
//  module mkicache(Ifc_l1icache#(4, 8, 64, 4 ,32,1,2));
//    let ifc();
//    mkl1icache#(isIO,"RROBIN") _temp(ifc);
//    return (ifc);
//  endmodule
endpackage

