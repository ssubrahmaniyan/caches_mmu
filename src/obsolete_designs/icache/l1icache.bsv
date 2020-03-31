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
  
TODO: rg_latest_index will not be required since a write-operation to the RAMs by the Fill-buffer
should not cause a change in the read-output-port of the RAMs.
--------------------------------------------------------------------------------------------------
*/
package l1icache;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import FIFO::*;
  import Assert::*;
  import GetPut::*;
  import BUtils::*;
  import ConfigReg::*;

  import globals::*;
  import cache_types::*;
  import mem_config::*;
  import replacement::*;
  
`ifdef ECC
  import ecc_hamming::*;
`endif
`ifdef ecc_test
  import LFSR :: *;
`endif

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
                        `ifdef ECC
			                     numeric type ecc_wordsize,
                           numeric type ebanks,
                        `endif
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
    `ifdef pysimulate
      interface Get#(Bit#(1)) meta;
    `endif
    `ifdef perfmonitors
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
    (Ifc_l1icache#(wordsize,blocksize,sets,ways,paddr,vaddr,fbsize,esize,`ifdef ECC ecc_wordsize, ebanks, `endif dbanks,tbanks,buswidth)) 
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
          Add#(h__, 1, blocksize),
          Add#(l__, paddr, vaddr),
          Mul#(buswidth, q__, linewidth),

          Add#(i__, TLog#(ways), 4),
          Mul#(TDiv#(linewidth, 8), 8, linewidth),
          Add#(j__, TDiv#(linewidth, 8), linewidth),
          Add#(k__, TLog#(ways), TLog#(TAdd#(1, ways)))
`ifdef ECC 
        ,Mul#(TAdd#(2, TLog#(ecc_wordsize)), TDiv#(respwidth, ecc_wordsize), ecc_encoded_parity_wordsize),
    	  Add#(s__, ecc_encoded_parity_wordsize, TMul#(TDiv#(blocksize, TDiv#(buswidth, ecc_wordsize)), ecc_encoded_parity_wordsize)),
        Add#(ad__, ecc_wordsize, respwidth),
	      Log#(TMul#(TDiv#(blocksize, TDiv#(buswidth, respwidth)), ecc_encoded_parity_wordsize_mtpl), TAdd#(blockbits, TLog#(ecc_encoded_parity_wordsize_mtpl))), 
	      Add#(ae__, TAdd#(2, TLog#(ecc_wordsize)), TMul#(TDiv#(buswidth, respwidth), TMul#(TDiv#(respwidth, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))))),
	      Add#(af__, TMul#(TDiv#(buswidth, respwidth), TMul#(TDiv#(respwidth, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize)))), TMul#(TDiv#(blocksize, TDiv#(buswidth, respwidth)), ecc_encoded_parity_wordsize_mtpl)),
	      Add#(ag__, ecc_encoded_parity_wordsize_mtpl, TMul#(TDiv#(blocksize, TDiv#(buswidth, respwidth)), ecc_encoded_parity_wordsize_mtpl)),

        Mul#(TDiv#(buswidth,respwidth), ecc_encoded_parity_wordsize,ecc_encoded_parity_wordsize_mtpl ),
        Add#(tt__, TAdd#(2, TLog#(ecc_wordsize)), TMul#(TDiv#(respwidth,ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize)))),
        Add#(u__, TMul#(TDiv#(ecc_wordsize, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))), TMul#(blocksize, ecc_encoded_parity_wordsize)),
        Add#(v__, TDiv#(TMul#(blocksize, ecc_encoded_parity_wordsize), ebanks), TMul#(blocksize, ecc_encoded_parity_wordsize)),
        Mul#(TDiv#(TMul#(blocksize, ecc_encoded_parity_wordsize), ebanks), ebanks, TMul#(blocksize, ecc_encoded_parity_wordsize)),
        Add#(2, TLog#(ecc_wordsize), encoded_paritysize),
        Add#(w__, ecc_encoded_parity_wordsize, ecc_encoded_parity_linewidth),
        Mul#(TMul#(TDiv#(respwidth,ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))), x__, ecc_encoded_parity_linewidth),
        Mul#(TMul#(TDiv#(ecc_wordsize, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))), y__, TMul#(blocksize, ecc_encoded_parity_wordsize)),
        Add#(z__, TAdd#(2, TLog#(ecc_wordsize)), ecc_encoded_parity_linewidth),
        Add#(aa__, ecc_encoded_parity_wordsize, TMul#(blocksize, ecc_encoded_parity_wordsize)),

	      Add#(r__, TAdd#(2, TLog#(ecc_wordsize)), TMul#(TDiv#(buswidth,ecc_wordsize),TAdd#(2,TLog#(ecc_wordsize)))),
	      Add#(w__, TMul#(TDiv#(buswidth, ecc_wordsize),TAdd#(2,TLog#(ecc_wordsize))), TMul#(TDiv#(blocksize,TDiv#(buswidth,ecc_wordsize)),ecc_encoded_parity_wordsize)),

	      Add#(t__, TAdd#(2, TLog#(ecc_wordsize)), TMul#(TDiv#(buswidth, ecc_wordsize), TMul#(TDiv#(ecc_wordsize, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))))),
	      Add#(ab__, TMul#(TDiv#(buswidth, ecc_wordsize), TMul#(TDiv#(ecc_wordsize, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize)))), TMul#(TDiv#(blocksize, TDiv#(buswidth, ecc_wordsize)), ecc_encoded_parity_wordsize_mtpl)),
	      Add#(ac__, ecc_encoded_parity_wordsize_mtpl, TMul#(TDiv#(blocksize, TDiv#(buswidth, ecc_wordsize)), ecc_encoded_parity_wordsize_mtpl))
`endif
          
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

`ifdef ECC 
    let v_ecc_wordsize=valueOf(ecc_wordsize);
    let v_ecc_encoded_parity_wordsize= valueOf(ecc_encoded_parity_wordsize);
    let v_ecc_encoded_parity_wordsize_mtpl= valueOf(ecc_encoded_parity_wordsize_mtpl);
    let v_num_ecc_per_word = valueOf(TDiv#(respwidth, ecc_wordsize));
    let v_encoded_paritysize = valueOf((TAdd#(2, TLog#(ecc_wordsize)))) ;
    let v_decoded_paritysize = valueOf((TAdd#(1, TLog#(ecc_wordsize)))) ;
`endif

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
    Wire#(Bool) wr_takingrequest <- mkDWire(False);
    Wire#(Bool) wr_cache_enable<-mkWire();
    `ifdef pysimulate
      FIFOF#(Bit#(1)) ff_meta <- mkSizedFIFOF(2);
    `endif
    `ifdef perfmonitors
      Wire#(Bit#(1)) wr_total_access <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_cache_misses <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_fb_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_nc <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_fbfills <- mkDWire(0);
    `endif
    // ------------------------------------------------------------------------------------------//

   
    // ------------------------ Structures required for cache RAMS ------------------------------//
`ifdef ECC
    Ifc_mem_config1rw#(sets, (TMul#(blocksize,ecc_encoded_parity_wordsize)), ebanks) ecc_arr [v_ways]; // ecc array
`endif
    Ifc_mem_config1rw#(sets, linewidth, dbanks) data_arr [v_ways]; // data array
    Ifc_mem_config1rw#(sets, tagbits, tbanks) tag_arr [v_ways];// one extra valid bit
    for(Integer i=0;i<v_ways;i=i+1)begin
      data_arr[i]<-mkmem_config1rw(False, "single"); 
      tag_arr[i]<-mkmem_config1rw(False, "single");
`ifdef ECC
      ecc_arr[i]<-mkmem_config1rw(False, "single");
`endif
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
    Wire#(Bool) wr_access_fault <- mkDWire(False);
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
`ifdef ECC
      fb_addr[i]<-mkConfigReg(0);
      fb_enables[i]<-mkConfigReg(0);
      fb_dataline[i]<-mkConfigReg(0);
      fb_err[i]<-mkConfigReg(0);
`else
      fb_addr[i]<-mkReg(0);
      fb_enables[i]<-mkReg(0);
      fb_dataline[i]<-mkReg(0);
      fb_err[i]<-mkReg(0);
`endif
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


    /**************************************ECC Hamming Encoded Parity structures******************/

`ifdef ECC
    Reg#(Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize))) fb_ecc_encoded_parity_line [v_fbsize];
    Reg#(Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize))) fb_ecc_encoded_parity_line_full [v_fbsize];
    Reg#(Bit#(TAdd#(1,blockbits))) rg_j[2]  <- mkCReg(2,0);
    for(Integer i=0;i<v_fbsize;i=i+1)begin
      fb_ecc_encoded_parity_line[i]<-mkConfigReg(0);
      fb_ecc_encoded_parity_line_full[i]<-mkConfigReg(0);
    end
    
    Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize)) writeecc=fb_ecc_encoded_parity_line[rg_fbwriteback];
    Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize)) junkecc=0;   

    Wire#(Bit#(ecc_encoded_parity_linewidth)) wr_hitline_ecc <-mkDWire(0);

    Wire#(Bool) wr_fb_ecc_fault <- mkDWire(False);
    Wire#(Bool) wr_resp_ecc_fault <- mkDWire(False);

`endif

    // ------------------------------------------------------------------------------------------//
  `ifdef ecc_test
    LFSR#(Bit#(5)) lfsr <- mkFeedLFSR('h12);
    Reg#(Bool) rg_init <- mkReg(True);
    Wire#(Bit#(respwidth)) wr_err_mask <- mkWire();
    rule rl_initialize(rg_init);
      rg_init <= False;
      lfsr.seed('d20);
    endrule
    rule generate_error(!rg_init);
      wr_err_mask <= 'b1 << lfsr.value;
      lfsr.next;
    endrule
  `endif

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
                                                                        wr_access_fault);
      let req = ff_core_request.first();
      Bit#(paddr) phy_addr=truncate(req.address);
      Bit#(respwidth) word=0;
      Bool err=wr_access_fault `ifdef ECC || wr_resp_ecc_fault `endif ;
      let set_index=phy_addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      if(wr_ram_response==Hit)begin
        word=wr_ram_hitword;
        if(alg=="PLRU") begin
          wr_ram_hitindex<=tagged Valid set_index;
          replacement.update_set(set_index, wr_ram_hitway);//wr_replace_line); 
        end
      end
      else if(wr_fb_response==Hit)begin
        word=wr_fb_word;
        err=unpack(wr_fb_err);
        `ifdef perfmonitors
          // Only when the hit in the LB is not because of a miss should the counter be enabled.
          if(!rg_miss_ongoing)
            wr_total_fb_hits<=1;
        `endif
      end
      else if(wr_nc_response==Hit)begin
        word=wr_nc_word;
        err=wr_nc_err;
      end
      rg_miss_ongoing<=False;
      // depending onthe request made by the core, the word is either sigextended/zeroextend and
      // truncated if necessary.
      `logLevel( icache, 0, $format("ICACHE: Sending Response word:%h for Addr:%h", word, phy_addr))
      ff_core_response.enq(FetchResponse{instr:word, trap: err, cause:`Inst_access_fault, epochs:req.epochs});
      ff_core_request.deq;
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
      Bit#(paddr) phy_addr=truncate(req.address);
      Bit#(TSub#(vaddr,paddr)) upper_bits=truncateLSB(req.address);
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phy_addr[v_blockbits+v_wordbits-1:0],3'b0};
`ifdef ECC
      Bit#(TAdd#(TLog#(ecc_encoded_parity_wordsize),blockbits)) block_offset_ecc=(phy_addr[v_blockbits+v_wordbits-1:v_wordbits]); //ported bug fix
      Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize)) dataline_ecc[v_ways];
      Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize)) hitline_ecc=0;
`endif
      Bit#(blockbits) word_index= phy_addr[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(tagbits) request_tag = phy_addr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= phy_addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];

      Bit#(linewidth) dataline[v_ways];
      Bit#(tagbits) tag[v_ways];
      for(Integer i=0;i<v_ways;i=i+1)begin
        tag[i]<- tag_arr[i].read_response;
        dataline[i]<- data_arr[i].read_response;
`ifdef ECC
        dataline_ecc[i]<- ecc_arr[i].read_response;
`endif
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
`ifdef ECC
          hitline_ecc=dataline_ecc[i];
`endif
        end
      end
      Bool cache_hit=unpack(|(hit));
      wr_ram_hitway<=truncate(pack(countZerosLSB(hit)));
      Bit#(respwidth) response_word=truncate(hitline>>block_offset) `ifdef ecc_test ^ wr_err_mask `endif ;

`ifdef ECC
      Bit#(ecc_encoded_parity_wordsize) response_word_ecc = 0;
      Bit#(TAdd#(1, TLog#(ecc_wordsize))) decoded_parity = 0;
      Bit#(respwidth) response_word_correct = 0;
      Bit#(1) det_only = 0;
      Bool trap = False;
      Bool resp_ecc_fault = False;

      response_word_ecc= truncate(hitline_ecc>> ((block_offset_ecc)*fromInteger(v_ecc_encoded_parity_wordsize)));

      Bit#(ecc_wordsize) ecc_word = 0;
      Bit#(encoded_paritysize) ecc_enc_word = 0;
      Bit#(ecc_wordsize) word_correct = 0;
      for (Integer i=0; i < v_num_ecc_per_word; i=i+1) begin
        ecc_word = response_word[i*v_ecc_wordsize+v_ecc_wordsize-1:i*v_ecc_wordsize];
        ecc_enc_word = response_word_ecc[i*v_encoded_paritysize+v_encoded_paritysize-1:i*v_encoded_paritysize];
        {word_correct,decoded_parity, trap} = ecc_hamming_decode_correct(ecc_word,ecc_enc_word,det_only);
        if (trap) begin
           resp_ecc_fault = resp_ecc_fault || trap;
        end
        else begin
           response_word_correct[i*v_ecc_wordsize+v_ecc_wordsize-1:i*v_ecc_wordsize] = word_correct;
        end
      end
      wr_resp_ecc_fault <= resp_ecc_fault;
`endif

      if(|upper_bits==1)
        wr_access_fault<=True;
      else if(cache_hit)begin
        wr_ram_response<=Hit;
`ifdef ECC
        wr_ram_hitword<=response_word_correct;
`else
        wr_ram_hitword<=response_word;
`endif
      end
      else begin
        wr_ram_response<=Miss;
      end
      `logLevel( icache, 0, $format("ICACHE : TAGCMP for Req: ",fshow(req)))
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
      Bit#(paddr) phy_addr=truncate(req.address);
      Bit#(setbits) read_set = phy_addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phy_addr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(TAdd#(3,(wordbits))) byte_index = {phy_addr[v_wordbits-1:0],3'b000}; // bug fix
`ifdef ECC
      Bit#(TAdd#(TLog#(ecc_encoded_parity_wordsize),blockbits))block_offset_ecc=phy_addr[v_blockbits+v_wordbits-1:v_wordbits]; //bug_fix
      Bit#(TAdd#(3,TAdd#(TLog#(respwidth),blockbits)))block_offset_tmp={phy_addr[v_blockbits+v_wordbits-1:v_wordbits]} * fromInteger(v_respwidth);
      Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize)) hitline_ecc=0;
`endif
      Bit#(blockbits) word_index=phy_addr[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(TAdd#(tagbits,setbits)) t=truncateLSB(phy_addr);
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
`ifdef ECC
          let m= valueOf(TDiv#(buswidth,respwidth));
	  if((rg_j[1] >= 0) && (rg_j[1] <= fromInteger(v_blocksize/m)))
                hitline_ecc=fb_ecc_encoded_parity_line[i];
          else
	        hitline_ecc=fb_ecc_encoded_parity_line_full[i];
`endif
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

      Bit#(respwidth) fb_word = 0;
      Bool fb_ecc_fault = False;
      fb_word=truncate(hitline>>block_offset); 

`ifdef ECC
      Bit#(respwidth) fb_word_tmp = 0;
      fb_word_tmp=truncate(hitline>>(block_offset_tmp)) `ifdef ecc_test ^ wr_err_mask `endif ; // bug fix
      //fb_word_tmp=truncate(hitline>>(block_offset_tmp/fromInteger(m))); // bug fix
      Bit#(ecc_encoded_parity_wordsize) fb_word_ecc = 0;
      Bit#(TAdd#(1, TLog#(ecc_wordsize))) decoded_parity = 0;
      Bit#(respwidth) fb_word_correct = 0;
      Bit#(1) det_only = 0;
      Bool trap = False;

      //fb_word_ecc= truncate(hitline_ecc>> ((block_offset_ecc/fromInteger(m))*fromInteger(v_ecc_encoded_parity_wordsize)));
      fb_word_ecc= truncate(hitline_ecc>> ((block_offset_ecc)*fromInteger(v_ecc_encoded_parity_wordsize)));

      Bit#(ecc_wordsize) ecc_word = 0;
      Bit#(encoded_paritysize) ecc_enc_word = 0;
      Bit#(ecc_wordsize) word_correct = 0;
      for (Integer i=0; i < v_num_ecc_per_word; i=i+1) begin
        ecc_word = fb_word_tmp[i*v_ecc_wordsize+v_ecc_wordsize-1:i*v_ecc_wordsize];
        ecc_enc_word = fb_word_ecc[i*v_encoded_paritysize+v_encoded_paritysize-1:i*v_encoded_paritysize];
      	{word_correct,decoded_parity, trap} = ecc_hamming_decode_correct(ecc_word,ecc_enc_word,det_only);
	if (trap == True) begin
           fb_ecc_fault = fb_ecc_fault || trap;
	end
        else begin
	//if (((decoded_parity == 0) || (det_only == 1'b1)) && (trap == False)) begin
           fb_word_correct[i*v_ecc_wordsize+v_ecc_wordsize-1:i*v_ecc_wordsize] = word_correct;
        end
      end
      
      wr_fb_word <= fb_word_correct >> byte_index;
`else
      wr_fb_word <= fb_word ;
`endif

      wr_fb_err <= fberr | pack(fb_ecc_fault);

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
                                          && wr_nc_response!=Hit &&!fb_full && !wr_access_fault);
                                                                                        
      let req =ff_core_request.first();
      Bit#(paddr) phy_addr = truncate(req.address);
      if(isNonCacheable(phy_addr,wr_cache_enable))begin
        ff_nc_read_request.enq(ICache_mem_request{  address    : phy_addr,
                                                    burst_len  : 0,
                                                    burst_size : fromInteger(v_wordbits)});
        `logLevel( icache, 0, $format("ICACHE : Sending IO Request for Addr:%h", phy_addr))
      `ifdef perfmonitors
        wr_total_nc<=1;
      `endif
      end
      else begin
        `logLevel( icache, 0, $format("ICACHE : Sending Line Request for Addr:%h", phy_addr)) 
        `logLevel( icache, 1, $format("ICACHE : Allocating FBindex:", rg_fbmissallocate)) 
        let shift_amount = valueOf(TLog#(TDiv#(buswidth,8)));
        phy_addr= (phy_addr>>shift_amount)<<shift_amount; // align the address to be one word aligned.
        let burst_len = (v_blocksize/valueOf(TDiv#(buswidth,respwidth)))-1;
        let burst_size = valueOf(TLog#(TDiv#(buswidth,8)));
        ff_read_mem_request.enq(ICache_mem_request{ address    : phy_addr,
                                                    burst_len  : fromInteger(burst_len),
                                                    burst_size : fromInteger(burst_size)});
        rg_fbmissallocate<=rg_fbmissallocate+1;
        fb_valid[rg_fbmissallocate]<=True;
        fb_addr[rg_fbmissallocate]<=phy_addr;
        fb_enables[rg_fbmissallocate]<=0;
        ff_fb_fillindex.enq(rg_fbmissallocate);
    `ifdef perfmonitors
        wr_total_cache_misses<=1;
    `endif
      end
      rg_miss_ongoing<=True;
    endrule

    // This rule will update an entry pointed by the register rg_fbbeingfilled with the incoming
    // response from the lower memory level.
    rule update_fb_with_memory_response;

      let response=ff_read_mem_response.first();

`ifdef ECC
      let m= valueOf(TDiv#(buswidth,respwidth));
      Bit#(ecc_wordsize) ecc_word = 0;
      Bit#(TAdd#(2, TLog#(ecc_wordsize))) ecc_encoded_parity = 0;
      Bit#(TMul#((TDiv#(respwidth, ecc_wordsize)), (TAdd#(2, TLog#(ecc_wordsize)))) )  ecc_encoded_parity_word = 0;
      Bit#(TMul#(TDiv#(buswidth,respwidth), TMul#((TDiv#(respwidth, ecc_wordsize)), TAdd#(2, TLog#(ecc_wordsize))) ))  ecc_encoded_parity_word_mtpl = 0;
      for (Integer j=0; j < m; j=j+1) begin
      	for (Integer i=0; i < v_num_ecc_per_word; i=i+1) begin
		let k = (j*v_num_ecc_per_word) + i;
        	ecc_word = response.data[k*v_ecc_wordsize+v_ecc_wordsize-1:k*v_ecc_wordsize];
        	ecc_encoded_parity = ecc_hamming_encode(ecc_word);
		ecc_encoded_parity_word[i* v_encoded_paritysize+ v_encoded_paritysize -1:i*v_encoded_paritysize] = ecc_encoded_parity;
		ecc_encoded_parity_word_mtpl[k* v_encoded_paritysize+ v_encoded_paritysize -1:k*v_encoded_paritysize] = ecc_encoded_parity;
      	end 
      end
`endif

      rg_fb_err<=response.err;
      ff_read_mem_response.deq;
      let fbindex=ff_fb_fillindex.first();
      Bit#(blocksize) temp=0;
      Bit#(blockbits) word_index=fb_addr[fbindex][v_blockbits+v_wordbits-1:v_wordbits];
`ifdef ECC
      Bit#(TAdd#(blockbits,TLog#(ecc_encoded_parity_wordsize_mtpl))) word_index_ecc=fb_addr[fbindex][v_blockbits+v_wordbits-1:v_wordbits]; // bug fix
`endif

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

`ifdef ECC
      Bit#(TMul#(TDiv#(blocksize,(TDiv#(buswidth,respwidth))),ecc_encoded_parity_wordsize_mtpl)) fb_ecc_encoded_parity_line_temp = 0;
      Bit#(TMul#(TDiv#(blocksize,(TDiv#(buswidth,respwidth))),ecc_encoded_parity_wordsize_mtpl)) fb_ecc_mask_temp = 0;
      Bit#(ecc_encoded_parity_wordsize_mtpl) mask_temp = '1;

      //for (Integer i=0; i < (v_blocksize/m); i=i+1) begin 
      for (Integer i=0; i < (v_blocksize/m); i=i+1) begin 
        if (fromInteger(i) == rg_j[0]) begin
      	   fb_ecc_encoded_parity_line_temp[i*v_ecc_encoded_parity_wordsize_mtpl+v_ecc_encoded_parity_wordsize_mtpl-1:i*v_ecc_encoded_parity_wordsize_mtpl] =ecc_encoded_parity_word_mtpl;
           fb_ecc_mask_temp[i*v_ecc_encoded_parity_wordsize_mtpl+v_ecc_encoded_parity_wordsize_mtpl-1:i*v_ecc_encoded_parity_wordsize_mtpl] = mask_temp;
        end
      end 
      let shift_val = unpack((word_index_ecc/fromInteger(m))*fromInteger(v_ecc_encoded_parity_wordsize_mtpl));
      fb_ecc_encoded_parity_line_temp= rotateBitsBy(fb_ecc_encoded_parity_line_temp,shift_val); // bug fix
      fb_ecc_mask_temp= rotateBitsBy(fb_ecc_mask_temp,shift_val); // bug fix
      if (rg_j[0] < fromInteger(v_blocksize/m)) begin //bug_fix
        if ( rg_j[0] == fromInteger((v_blocksize/m)-1)) begin
	  rg_j[0] <=0;
          //fb_ecc_encoded_parity_line_full[fbindex][0] <= (((~fb_ecc_mask_temp & fb_ecc_encoded_parity_line[fbindex]) | fb_ecc_encoded_parity_line_temp)) ;
        end 
        else
          rg_j[0] <= rg_j[0] + 1;
        fb_ecc_encoded_parity_line[fbindex] <= (((~fb_ecc_mask_temp & fb_ecc_encoded_parity_line[fbindex])| fb_ecc_encoded_parity_line_temp));
      end 
`endif

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
`ifdef ECC
        ecc_arr[waynum].request(1'b1,set_index,writeecc);
`endif
        tag_arr[waynum].request(1'b1,set_index,writetag);
        data_arr[waynum].request(1'b1,set_index,writedata);
        rg_valid[set_index][waynum]<=1'b1;
        if(fb_full && fillindex==rg_latest_index)
          rg_replaylatest<=True;
        `ifdef perfmonitors
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
`ifdef ECC
        ecc_arr[i].request(1'b0,rg_latest_index,writeecc);
`endif
        data_arr[i].request(1'b0,rg_latest_index,writedata);
        tag_arr[i].request(1'b0,rg_latest_index,writetag);
      end
      `logLevel( icache, 1, $format("ICACHE : Replaying last request for index:%d", rg_latest_index))
    endrule

    interface core_req=interface Put
      method Action put(ICache_request#(vaddr,esize) req)if( ff_core_response.notFull &&
                                !rg_replaylatest &&  !rg_fence_stall && !fb_full);
        `ifdef perfmonitors
          wr_total_access<=1;
        `endif
        Bit#(paddr) phy_addr = truncate(req.address);
        Bit#(setbits) set_index=phy_addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=req.fence;
        for(Integer i=0;i<v_ways;i=i+1)begin
`ifdef ECC
          ecc_arr[i].request(1'b0,set_index,writeecc);
`endif
          data_arr[i].request(1'b0,set_index,writedata);
          tag_arr[i].request(1'b0,set_index,writetag);
        end
        wr_takingrequest<=True;
        `logLevel( icache, 0, $format("ICACHE : Receiving request: ",fshow(req)))
        rg_latest_index<=set_index;
      endmethod
    endinterface;

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
    `ifdef perfmonitors
      method Bit#(5) perf_counters;
        return {wr_total_fbfills,wr_total_nc,wr_total_fb_hits,wr_total_cache_misses,wr_total_access};
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

