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
Author: Neel Gala,Deepa N. Sarma
Email id: neelgala@gmail.com
Details:
--------------------------------------------------------------------------------------------------
*/

package icache_dm;
  import cache_types::*;
  import mem_config::*;
  import GetPut::*;
  import FIFOF::*;
  import BUtils ::*;  
  import DReg::*;
  import Assert::*;
  
  //parameters:
  // wordsize: number of bytes per word. This is what is responded back to the core.
  // blocksize: number of words per data line.
  // sets: number of sets within the cache.

  // list of performance counters:
  // 0. Total accesses
  // 1. Total Hits in Cache
  // 2. Total Hits in LB
  // 3. Total IO requests
  // 4. Misses which cause evictions
  
  interface Ifc_icache_dm#(numeric type wordsize, numeric type blocksize,  numeric type sets,numeric
  type respwidth, numeric type paddr);
    interface Put#(ICore_request#(paddr)) core_req;
    interface Get#(ICore_response#(respwidth)) core_resp;
    interface Get#(IMem_request#(paddr)) mem_req;
    interface Put#(IMem_response#(respwidth)) mem_resp;
    `ifdef simulate
      interface Get#(Bit#(1)) meta;
    `endif
    `ifdef perf
      method Bit#(5) perf_counters;
    `endif
  endinterface

  (*conflict_free="rl_response_to_core,rl_request_to_memory"*)
//  (*preempts="get_io_response, check_hit_or_miss"*)
  module mkicache_dm#(function Bool is_IO(Bit#(paddr) addr, Bool cacheable), parameter Bool ramreg,
  parameter Bool prefetch_en)
    (Ifc_icache_dm#(wordsize,blocksize,sets,respwidth, paddr))
  provisos(
            Mul#(wordsize, 8, _w),        // _w is the total bits in a word
            Mul#(blocksize, _w,linewidth),// linewidth is the total bits in a cache line
            Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
            Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
            Log#(sets, setbits),          // setbits is the no. of bits used as index in BRAMs.
            Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
            Add#(_a, setbits, _b),        // _b total bits for index+offset, 
            Add#(tagbits, _b, paddr),        // tagbits = 32-(wordbits+blockbits+setbits)
            Mul#(wordsize,8,word_len),    // word_len = number of bits in a word
            Div#(respwidth,word_len,num_words),//num_words=number of words fetched from memory in a
            //cycle
            // Provisos for mem_config. If the number of banks have changed then the following
            // provisos will have to be re-written.
            Add#(a__, TDiv#(linewidth, 8), linewidth),
            Mul#(TDiv#(TDiv#(linewidth, 8), TDiv#(TDiv#(linewidth, 8), 8)),
              TDiv#(TDiv#(linewidth, 8), 8), TDiv#(linewidth, 8)),
            Mul#(TDiv#(linewidth, 8), 8, linewidth),
            // following provisos required by compiler:
            Bits#(Tuple2#(Bit#(respwidth), Bool), c__),
            Add#(d__, 1, blocksize),
            Add#(e__, respwidth, linewidth),
            Mul#(respwidth, f__, linewidth)
            );
  
    let v_sets=valueOf(sets);
    let v_setbits=valueOf(setbits);
    let v_wordbits=valueOf(wordbits);
    let v_blockbits=valueOf(blockbits);
    let v_linewidth=valueOf(linewidth);
    let v_tagbits=valueOf(tagbits);
    let v_num_words=valueOf(num_words);
    let verbosity=`VERBOSITY;
    let v_paddr=valueOf(paddr);

    //Following function returns the info regarding word_position in line getting filled
    function Bit#(blocksize) fn_enable(Bit#(blockbits)word_index);
       Bit#(blocksize) write_enable ='h0; //
       for(Integer i=0;i<v_num_words;i=i+1)
         write_enable[word_index+fromInteger(i)]=1;
       return write_enable;
    endfunction

    Ifc_mem_config#(sets, linewidth, 8) data_arr <- mkmem_config_h(ramreg); // data array
    Ifc_mem_config#(sets, TAdd#(1, tagbits), 1) tag_arr <- mkmem_config_h(ramreg); // one extra valid bit
   
    // FIFOs for interface communication
    FIFOF#(ICore_response#(respwidth))ff_core_response <- mkSizedFIFOF(2);
    FIFOF#(IMem_request#(paddr)) ff_mem_request    <- mkSizedFIFOF(2);
    FIFOF#(IMem_response#(respwidth)) ff_mem_response  <- mkSizedFIFOF(2);
    FIFOF#(ICore_request#(paddr)) ff_req_queue <- mkSizedFIFOF(2); 

    // This register is used to indicate that a miss is ongoing and thus prevents further requests
    // from being handled.
    Reg#(Bool) rg_miss_ongoing <- mkReg(False);

    // The following set of wires indicate if there was a hit or miss by the cache, LB or io
    // respectively.
    Wire#(RespState) wr_cache_state <- mkDWire(None);
    Wire#(RespState) wr_lb_state <- mkDWire(None);
    Wire#(Bool) wr_io_response <- mkDWire(False);

    // The following wire holds the request that needs to be made to the memory for a miss in cache
    // and LB.
    Wire#(IMem_request#(paddr)) wr_miss_from_cache <- mkDWire(tuple3(0,0,0));
    `ifdef simulate
      Wire#(IMem_request#(paddr)) wr_miss_lb_cache <- mkDWire(tuple3(0,0,0));
    `endif

    // The following wires hold the word that was received on a hit in the cache, LB or io.
    Wire#(Tuple2#(Bit#(respwidth),Bool)) wr_hit_cache <- mkDWire(tuple2(0,False));
    Wire#(Tuple2#(Bit#(respwidth),Bool)) wr_hit_lb <- mkDWire(tuple2(0,False));
    Wire#(Tuple2#(Bit#(respwidth),Bool)) wr_hit_io <- mkDWire(tuple2(0,False));

    `ifdef simulate
      FIFOF#(Bit#(1)) ff_meta <- mkSizedFIFOF(2);
    `endif

    Reg#(Bit#(TLog#(sets))) rg_fence_index <- mkReg(0);
    Reg#(Bool) rg_init <- mkReg(True);
    Reg#(Bool) rg_fence_stall <- mkReg(True);
    Reg#(Bit#(blocksize))rg_blockenable <- mkReg(0);
    Reg#(Bit#(blockbits))index<-mkReg(0);
    //linebuffer control
    FIFOF#(Tuple4#(Bit#(tagbits), Bit#(setbits),Bit#(blocksize), Bool)) ff_lb_control <- mkUGSizedFIFOF(2);
    Reg#(Bit#(1)) rg_lbvalid <- mkReg(0);
    Reg#(Bit#(linewidth)) rg_lbdataline <- mkReg(0);
    Reg#(Bit#(blocksize)) rg_lbenables <- mkReg(0);
    Reg#(Bool) rg_lberr <- mkReg(False);

    Reg#(Bool) rg_deq_lb <- mkDReg(False);

    // The following register is used to capture the latest index which has been latched into the
    // data/tag array. This is used during deque of the LB. If the request to the SRAM was to the 
    // same line as that held in the LB, then the same line is indexed again while lb deq
    Reg#(Bit#(setbits)) rg_latest_index <- mkReg(0);

    `ifdef perf
      Wire#(Bit#(1)) wr_total_access <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_cache_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_lb_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_io <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_evictions <- mkDWire(0);
      Wire#(Bool) wr_line_valid <- mkDWire(False);
    `endif

    // The following register is used only when ramreg is set to True - i.e. when the BRAM outputs
    // are registered. In this case, when a core-requests arrives, the output of the BRAMs should
    // only be checked on the next-to-next cycle (i.e. not the immediately next cycle). Also this
    // should only happen when the ff_req_queue has only one entry within it.
    Reg#(Bool) rg_delay <- mkDReg(False);
    Bool delay_checking= ramreg && rg_delay && ff_req_queue.notFull && ff_req_queue.notEmpty;
    // on reset we issue a fence instruction to initiliase the cache.
    rule initialize(rg_init);
      ff_req_queue.enq(tuple4(?,True,?, False));
      rg_init<=False;
    endrule

    //Fencing the cache
    // rule to fire only when there is not a pending fill to LB.
    // If this condition is not added then it is possible that LB populates the CACHE line after
    // being fenced which is wrong behavior
    rule fence_cache(tpl_2(ff_req_queue.first) && !ff_lb_control.notEmpty && rg_fence_stall);
       tag_arr.write_request(rg_fence_index,'d0);
       rg_fence_index<= rg_fence_index+1;
       if(verbosity>0)
         $display($time,"\tICACHE: Fence in progress. Index: %d",rg_fence_index);
       if(rg_fence_index==(fromInteger(v_sets-1))) begin
          ff_req_queue.deq;
          rg_fence_stall<=False;
          if(verbosity>1)begin
            $display($time,"\tICACHE Params:");
            $display($time,"\tv_sets: %d",v_sets);
            $display($time,"\tv_setbits: %d",v_setbits);
            $display($time,"\tv_wordbits: %d",v_wordbits);
            $display($time,"\tv_blockbits: %d",v_blockbits);
            $display($time,"\tv_tagbits: %d",v_tagbits);
            $display($time,"\tv_num_words: %d",v_num_words);
          end
       end
    endrule
    
    // Checking the data and tag arrays of the cache for a hit or miss.
    // This rule will fire for every request from the core that is not a Fence operation.
    // This rule will also check if the request is cacheable. If not, then a miss generated for that
    // one request and not the entire line.
    rule check_hit_or_miss(!tpl_2(ff_req_queue.first) && !rg_miss_ongoing && ff_lb_control.notFull 
       && !delay_checking);
      let {request, fence, epoch, prefetch} =ff_req_queue.first();
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset=
                                                          (request[v_blockbits+v_wordbits-1:0])<<3;
      Bit#(blockbits) word_index=request[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(linewidth) dataline <- data_arr.read_response;
      Bit#(TAdd#(1, tagbits)) tag <- tag_arr.read_response;
      Bit#(tagbits) request_tag = request[v_paddr-1:v_paddr-v_tagbits];
      Bit#(1) valid=tag[v_tagbits];
      Bit#(tagbits) stored_tag=tag[v_tagbits-1:0];
      Bit#(setbits) set_index=request[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];

//      `ifdef simulate
//        dynamicAssert(data_arr.read_index==set_index,"Cache response is for wrong index");
//      `endif

      if(verbosity!=0)begin
        $display($time,"\tICACHE: Check for Address:%h Valid: %b ReqTag: %h StoredTag: %h index: %d",
            request,valid,request_tag,stored_tag,set_index);
      end

      // check if the request is cacheable or not
      if(is_IO(request, True))begin
        $display($time,"\tICACHE: Cache received IO request for address: %h",request);
        wr_cache_state<=Miss;
        wr_miss_from_cache<=(tuple3(request,0,2));        
      end
      // check if hit  in the cache
      else if((valid==1) && (stored_tag==request_tag)) begin // hit in cache
        Bit#(respwidth) word_response = truncate(dataline>>block_offset); 
        wr_hit_cache<= tuple2(word_response, False);// word and no bus-error;
        wr_cache_state<=Hit;
        if(verbosity!=0)
          $display($time,"\tHIT IN CACHE for addr:%h data:%h",request,word_response);
      end
      // generate a miss
      else begin
        `ifdef perf
          wr_line_valid<=unpack(valid);
        `endif
        wr_cache_state<=Miss;
        wr_miss_from_cache<=  (tuple3(request,fromInteger(valueOf(blocksize)-1),2));        
        if(verbosity!=0)
            $display($time,"\tICACHE: Miss in Cache for addr: %h",request);
      end
    endrule

    // This rule will fire for every request from the core that is not a Fence operation.
    rule poll_on_lb(!tpl_2(ff_req_queue.first));
      
      // We first check if the requested word is in the line-buffer. This is done by checking the
      // if the tags match. While this means that the line-buffer should have the data
      // required, it might not be available unless it has been filled by the memory. We can confirm
      // this by checking the byte-enables which indicate which bytes of the line are available and
      // also confirm if the valid bit is set.

      
      let {lbtag,lbset,init_we, isIO}=ff_lb_control.first();
      let {request, fence, epoch, prefetch}=ff_req_queue.first();

      Bit#(tagbits) request_tag = request[v_paddr-1:v_paddr-v_tagbits]; 
      let request_index=request[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(blockbits) word_index=request[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset=
                                                          (request[v_blockbits+v_wordbits-1:0])<<3;

      // check if line-buffer holds the line containing the word requested
      if(lbtag==request_tag && lbset==request_index && ff_lb_control.notEmpty) begin
        if(verbosity!=0)
          $display($time,"\tICACHE: Polling LB Holds the line for address: %h",request);
        // check if the word is available in the line-buffer.
        if(rg_lbenables[word_index]!=1||rg_lbvalid!=1) begin
          if(verbosity!=0)
            $display($time,"\tICACHE: Polling Miss. Word not found in LB for address: %h",request);
        end  
        else begin
          if(verbosity!=0)
              $display($time,"\tICACHE: Polling Hit. Word present in LB for address: %h",request);
          Bit#(respwidth) word_response = truncate(rg_lbdataline>>block_offset); 
          wr_hit_lb<=(tuple2(word_response,rg_lberr));// word and no bus-error;
          wr_lb_state<=Hit;
        end
      end
      else begin
        if(verbosity!=0)
          $display($time,"\tICACHE: Miss in LB for address: %h",request);
        wr_lb_state<=Miss;
        `ifdef simulate
          wr_miss_lb_cache<=(tuple3(request,fromInteger(valueOf(blocksize)-1),2));
        `endif
      end
    endrule

    // If the miss generated is cacheable then update the line-buffer with the word responded by the
    // next level memory structure. If the request if not cacheable then deque the line-buffer and
    // generate an IO hit response.
    rule rl_response_to_core(!tpl_2(ff_req_queue.first) && (wr_lb_state==Hit || wr_cache_state==Hit
        || wr_io_response));
      `ifdef simulate
        $display($time,"\tICACHE: Sending Response to the Core");
        dynamicAssert(!(wr_lb_state==Hit && wr_cache_state==Hit), "Hit in Both LB and Cache found");
      `endif
      let {addr, fence, epoch, prefetch}=ff_req_queue.first();
      ff_req_queue.deq();
      Bit#(respwidth) word=0;
      Bool err=False;
      if(wr_cache_state == Hit) begin
        `ifdef perf
          wr_total_cache_hits<=1;
        `endif
        {word,err}=wr_hit_cache;
      end
      else if(wr_lb_state == Hit)begin
        `ifdef perf
          // Only when the hit in the LB is not because of a miss should the counter be enabled.
          if(!rg_miss_ongoing)
            wr_total_lb_hits<=1;
        `endif
        {word,err}=wr_hit_lb;
      end
      else if(wr_io_response)begin
        `ifdef perf
          wr_total_io<=1;
        `endif
        {word,err}=wr_hit_io;
      end
      if(prefetch_en)begin
        if(!prefetch)
          ff_core_response.enq(tuple3(word,err,epoch));
      end
      else
        ff_core_response.enq(tuple3(word,err,epoch));
      rg_miss_ongoing<=False;
      `ifdef simulate
        if(rg_miss_ongoing)
          ff_meta.enq(0);
        else
          ff_meta.enq(1);  
      `endif
    endrule

    rule rl_request_to_memory(wr_cache_state==Miss && wr_lb_state==Miss);
      `ifdef perf
        if(wr_line_valid)
          wr_total_evictions<=1;
      `endif
      rg_miss_ongoing<=True;
      `ifdef simulate
        $display($time,"\tICACHE: Sending Request to Memory: ",fshow(wr_miss_from_cache));
        dynamicAssert(rg_miss_ongoing==False,"Issuing a Memory request while one is ongoing");
        dynamicAssert(tpl_1(wr_miss_from_cache)==tpl_1(wr_miss_lb_cache),"Miss from LB and Cache for different\
addresses");
      `endif
      let {request, fence, epoch}=ff_req_queue.first();
      Bit#(tagbits) request_tag = request[v_paddr-1:v_paddr-v_tagbits]; 
      let request_index=request[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(blockbits) word_index=request[v_blockbits+v_wordbits-1:v_wordbits];
      ff_mem_request.enq(wr_miss_from_cache);
      ff_lb_control.enq(tuple4(request_tag,request_index,fn_enable(word_index),
                                                          tpl_2(wr_miss_from_cache)==0));
    endrule
    
    //Capturing memory_response
    rule capture_memory_response(&(rg_lbenables)!=1 && ff_lb_control.notEmpty);
     
      let {word,err} = ff_mem_response.first;
      ff_mem_response.deq;

      let {lbtag,lbset, init_we, isIO}=ff_lb_control.first();
      let lbenables=rg_lbenables;

      Bit#(blocksize) temp = 0;
      if(rg_blockenable==0)
        temp=init_we;
      else
        temp=rg_blockenable;

      lbenables = lbenables|temp;

     //Each bit in write_enable register refers to corresponding word in block 
      
      Bit#(linewidth) mask = 0;
      for(Integer i=0;i<valueOf(blocksize);i=i+1)
      begin
            Bit#(respwidth) ex_we=duplicate(temp[i]);
            let v_word_len = valueOf(word_len);
            mask[((i*v_word_len)+(v_word_len-1)):i*v_word_len]=ex_we;
      end

      if (verbosity!=0) begin
        $display($time,"\tICACHE: Receiving Memory Response. Word: %h err: %b",word,err);
        $display($time,"\tICACHE: Lbenables changes to:%b",lbenables);
        $display($time,"\tICACHE: WE :%b",temp);
        $display($time,"\tICACHE: MASK:%h",mask);
      end

      Bit#(linewidth) y  = duplicate(word) ; 
      let new_word_line  = y & mask;
      Bit#(linewidth) x  = rg_lbdataline|new_word_line;

      if(isIO) begin
        wr_hit_io<=tuple2(word,err);
        wr_io_response<=True;
        ff_lb_control.deq;
      end
      else begin
        rg_lbvalid<=1;
        rg_lbdataline<=x;
        rg_lbenables<=lbenables;
        rg_lberr<=rg_lberr||err;
        rg_blockenable <= {temp[valueOf(blocksize)-2:0],
                                                temp[valueOf(blocksize)-1]};
      end
      if(verbosity!=0)
        $display($time,"\tICACHE: Updating line_buffer:%h",x);

    endrule

    //Loading data into the cache from line_buffer
    rule upd_data_into_cache(&(rg_lbenables)==1 && (!ff_lb_control.notFull|| rg_fence_stall) && ff_lb_control.notEmpty  && !rg_deq_lb);
      let {lbtag,lbset,init_we, isIO}=ff_lb_control.first();
      tag_arr.write_request(lbset,{1,lbtag});//lbtag
      data_arr.write_request(lbset,truncate(rg_lbdataline));
      if(verbosity!=0)
        $display($time,"\tICACHE: loading set:%h with dataline %h and tag %h",
                                        lbset,rg_lbdataline,lbtag);
      rg_deq_lb<=True;
    endrule
    rule deq_lb(rg_deq_lb && &(rg_lbenables)==1 && (!ff_lb_control.notFull|| rg_fence_stall) && ff_lb_control.notEmpty);
      ff_lb_control.deq;
      rg_blockenable<=0;
      rg_lbenables<=0;
      rg_lbvalid<=0;
      rg_lbdataline<=0;
      rg_lberr<=False;
      Bit#(setbits) set_index=rg_latest_index;
      let {lbtag,lbset, init_we, isIO}=ff_lb_control.first();
      if (lbset==set_index) begin
        $display($time,"\tICACHE: Resending request to cache for index: %d",set_index);
        data_arr.read_request(set_index);
        tag_arr.read_request(set_index);
      end
    endrule

    interface core_req=interface Put
      method Action put(ICore_request#(paddr) req) if(!rg_init && !rg_fence_stall );
        `ifdef perf
          wr_total_access<=1;
        `endif
        let {addr, fence, epoch} =req;
        if(fence)
          rg_fence_stall<=True;

        ff_req_queue.enq(req);
        Bit#(setbits) set_index=addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        data_arr.read_request(set_index);
        tag_arr.read_request(set_index);
        rg_latest_index<=set_index;
        if (verbosity!=0)
		    $display($time,"\tICACHE: Receiving request to address:%h Fence: %b epoch: %b index: %d",
          addr, fence, epoch, set_index); 
        if(verbosity!=0)
		      $display($time,"\tICACHE: Access Cache for Addr: %h Index: %d",addr,set_index); 
        
        if(ramreg)
          rg_delay<=True;
      endmethod
    endinterface;

    interface core_resp = interface Get
      method ActionValue#(ICore_response#(respwidth)) get();
        ff_core_response.deq;
        return ff_core_response.first;
      endmethod
    endinterface;
    
    interface mem_req = interface Get
      method ActionValue#(IMem_request#(paddr)) get;
        ff_mem_request.deq;
        return ff_mem_request.first;
      endmethod
    endinterface;

    interface mem_resp= interface Put
     method Action put(IMem_response#(respwidth) resp);
        ff_mem_response.enq(resp);
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
    `ifdef perf
      method Bit#(5) perf_counters;
        return {wr_total_evictions,wr_total_io,wr_total_lb_hits,wr_total_cache_hits,wr_total_access};
      endmethod
    `endif
  endmodule

endpackage
