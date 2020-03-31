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

--------------------------------------------------------------------------------------------------
*/
package l1dcache;
  // ---- package imports ----//
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import Assert::*;
  import GetPut::*;
  import BUtils::*;
  import ConfigReg::*;

  // ---- project imports ----//
  import cache_types::*;          // for local cache types
  import globals::*;              // for core side types
  import mem_config::*;           // for instantiating brams
  import replacement_dcache::*;   // for replacement algorithms
  `include "cache.defines"        // for macro definitions
  `include "Logger.bsv"           // for logging
  
`ifdef ECC
  import ecc_hamming::*;
`endif
`ifdef ecc_test
  import LFSR :: *;
`endif

  interface Ifc_l1dcache#( numeric type wordsize, 
                           numeric type blocksize,  
                           numeric type sets,
                           numeric type ways,
                           numeric type paddr,
                           numeric type vaddr,
                           numeric type fbsize,
                           numeric type sbsize,
                           numeric type esize,
`ifdef ECC
                           numeric type ecc_wordsize,
                           numeric type ebanks,
`endif
                           numeric type dbanks,
                           numeric type tbanks
                           );

    interface Put#(DCache_core_request#(vaddr, TMul#(wordsize, 8), esize)) core_req;
    interface Get#(DMem_core_response#(TMul#(wordsize, 8), esize)) core_resp;
    interface Get#(DCache_mem_readreq#(paddr)) read_mem_req;
    interface Put#(DCache_mem_readresp#(TMul#(wordsize, 8))) read_mem_resp;
    interface Get#(DCache_mem_readreq#(paddr)) nc_read_req;
    interface Put#(DCache_mem_readresp#(TMul#(wordsize, 8))) nc_read_resp;
    method DCache_mem_writereq#(paddr, TMul#(blocksize, TMul#(wordsize, 8))) write_mem_req_rd;
    method Action write_mem_req_deq;
    interface Put#(DCache_mem_writeresp) write_mem_resp;
    interface Get#(DCache_mem_writereq#(paddr, TMul#(wordsize, 8))) nc_write_req;
    `ifdef pysimulate
      interface Get#(Bit#(1)) meta;
    `endif
    `ifdef perfmonitors
      method Bit#(13) perf_counters;
    `endif
    method Action cache_enable(Bool c);
    method Action perform_store(Bit#(esize) currepoch);
    method Bool cacheable_store;
    method Bool cache_available;
    method Bool storebuffer_empty;
  endinterface

  (*conflict_free="request_to_memory,update_fb_with_memory_response"*)
  (*conflict_free="respond_to_core,fence_operation"*)
  (*conflict_free="request_to_memory,fence_operation"*)
  (*conflict_free="request_to_memory,release_from_FB"*)
  (*conflict_free="respond_to_core,release_from_FB"*)
  (*conflict_free="respond_to_core,update_fb_with_memory_response"*)
  (*conflict_free="release_from_FB,update_fb_with_memory_response"*)
  (*conflict_free="respond_to_core,perform_store"*)
  (*conflict_free="update_fb_with_memory_response,perform_store"*)
  (*conflict_free="allocate_storebuffer,perform_store"*)
  (*conflict_free="request_to_memory, perform_store"*)
  (*conflict_free="allocate_storebuffer,respond_to_core"*)
  (*conflict_free="allocate_storebuffer,request_to_memory"*)
  (*conflict_free="perform_store,fence_operation"*)
  module mkl1dcache#(function Bool isNonCacheable(Bit#(paddr) addr, Bool cacheable), 
                     parameter String alg) 
                     (Ifc_l1dcache#(wordsize, blocksize, sets, ways, paddr, vaddr, fbsize, 
                                    sbsize, esize, `ifdef ECC ecc_wordsize, ebanks, `endif dbanks, tbanks)) 
    provisos(
          Mul#(wordsize, 8, respwidth),        // respwidth is the total bits in a word
          Mul#(blocksize, respwidth,linewidth),// linewidth is the total bits in a cache line
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset, 
          Add#(tagbits, _b, paddr),     // tagbits = 32-(wordbits+blockbits+setbits)
          Add#(s__, respwidth, vaddr),

          `ifdef ASSERT
          Add#(1, p__, TLog#(TAdd#(1, fbsize))),
          Add#(1, f__, TLog#(TAdd#(1, ways))),
          Add#(1, o__, TLog#(TAdd#(1, sbsize))),
          `endif

            // for dbanks
          Add#(q__, TDiv#(linewidth, dbanks), linewidth),
          Mul#(TDiv#(linewidth, dbanks), dbanks, linewidth),
          Add#(r__, TDiv#(tagbits, tbanks), tagbits),
          Mul#(TDiv#(tagbits, tbanks), tbanks, tagbits),

          Add#(a__, respwidth, linewidth),
          Add#(b__, 32, respwidth),
          Add#(c__, 16, respwidth),
          Add#(d__, 8, respwidth),
          Add#(TAdd#(tagbits, setbits), g__, paddr),
          Add#(h__, 1, blocksize),
          Add#(e__, 3, TLog#(respwidth)),
          Add#(t__, paddr, vaddr),

          Add#(i__, TLog#(ways), 4),
          Mul#(TDiv#(linewidth, 8), 8, linewidth),
          Add#(j__, TDiv#(linewidth, 8), linewidth),
          Add#(k__, TLog#(ways), TLog#(TAdd#(1, ways))),
          Mul#(32, l__, respwidth),
          Mul#(16, m__, respwidth),
          Add#(n__, TLog#(fbsize), TLog#(TAdd#(1, fbsize))),
          Add#(n__, TLog#(sbsize), TLog#(TAdd#(1, sbsize)))
          
`ifdef ECC
          ,
	  Add#(ab__, ecc_wordsize, respwidth),
	  Add#(ac__, TMul#(TDiv#(respwidth, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))), TMul#(blocksize, ecc_encoded_parity_wordsize)),
	  Mul#(TMul#(TDiv#(respwidth, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))), ad__, TMul#(blocksize, ecc_encoded_parity_wordsize)),

          Mul#(TDiv#(respwidth,ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize)), ecc_encoded_parity_wordsize),
          Mul#(blocksize,ecc_encoded_parity_wordsize,ecc_encoded_parity_linewidth),
          Add#(tt__, TAdd#(2, TLog#(ecc_wordsize)), TMul#(TDiv#(respwidth,ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize)))),
          Add#(u__, TMul#(TDiv#(ecc_wordsize, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))), TMul#(blocksize, ecc_encoded_parity_wordsize)),
          Add#(v__, TDiv#(TMul#(blocksize, ecc_encoded_parity_wordsize), ebanks), TMul#(blocksize, ecc_encoded_parity_wordsize)),
          Mul#(TDiv#(TMul#(blocksize, ecc_encoded_parity_wordsize), ebanks), ebanks, TMul#(blocksize, ecc_encoded_parity_wordsize)),
          Add#(2, TLog#(ecc_wordsize), encoded_paritysize),
          Add#(w__, ecc_encoded_parity_wordsize, ecc_encoded_parity_linewidth),
	  Mul#(TMul#(TDiv#(respwidth,ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))), x__, ecc_encoded_parity_linewidth),
	  Mul#(TMul#(TDiv#(ecc_wordsize, ecc_wordsize), TAdd#(2, TLog#(ecc_wordsize))), y__, TMul#(blocksize, ecc_encoded_parity_wordsize)),
	  Add#(z__, TAdd#(2, TLog#(ecc_wordsize)), ecc_encoded_parity_linewidth),
	  Log#(TMul#(blocksize, ecc_encoded_parity_wordsize), TAdd#(TLog#(ecc_encoded_parity_wordsize), blockbits)),
	  Add#(aa__, ecc_encoded_parity_wordsize, TMul#(blocksize, ecc_encoded_parity_wordsize))

`endif

          
    );
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
    let v_sbsize = valueOf(sbsize);

    String dcache=""; // defined for Logger

`ifdef ECC
    let v_ecc_wordsize=valueOf(ecc_wordsize);
    let v_ecc_encoded_parity_wordsize= valueOf(ecc_encoded_parity_wordsize);
    let v_num_ecc_per_word = valueOf(TDiv#(respwidth, ecc_wordsize));
    let v_encoded_paritysize = valueOf((TAdd#(2, TLog#(ecc_wordsize)))) ;
    let v_decoded_paritysize = valueOf((TAdd#(1, TLog#(ecc_wordsize)))) ;
`endif


    function Bit#(respwidth) fn_atomic_op (Bit#(5) op,  Bit#(respwidth) rs2,  Bit#(respwidth) loaded);
      Bit#(respwidth) op1 = loaded;
      Bit#(respwidth) op2 = rs2;
      if(op[4]==0)begin
	  		op1=signExtend(loaded[31:0]);
        op2= signExtend(rs2[31:0]);
      end
      Int#(respwidth) s_op1 = unpack(op1);
	  	Int#(respwidth) s_op2 = unpack(op2);
      
      case (op[3:0])
	  			'b0011:return op2;
	  			'b0000:return (op1+op2);
	  			'b0010:return (op1^op2);
	  			'b0110:return (op1&op2);
	  			'b0100:return (op1|op2);
	  			'b1100:return min(op1,op2);
	  			'b1110:return max(op1,op2);
	  			'b1000:return pack(min(s_op1,s_op2));
	  			'b1010:return pack(max(s_op1,s_op2));
	  			default:return op1;
	  		endcase
    endfunction

  
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
    FIFOF#(DCache_core_request#(vaddr, respwidth, esize)) ff_core_request <- mkSizedFIFOF(2); 
    // This fifo stores the response that needs to be sent back to the core.
    FIFOF#(DMem_core_response#(respwidth, esize))ff_core_response <- mkBypassFIFOF();
    // this fifo stores the read request that needs to be sent to the next memory level.
    FIFOF#(DCache_mem_readreq#(paddr)) ff_read_mem_request    <- mkSizedFIFOF(2);
    // This fifo stores the response from the next level memory.
    FIFOF#(DCache_mem_readresp#(respwidth)) ff_read_mem_response  <- mkBypassFIFOF();
    
    FIFOF#(DCache_mem_readreq#(paddr)) ff_nc_read_request    <- mkSizedFIFOF(2);
    // This fifo stores the response from the next level memory.
    FIFOF#(DCache_mem_readresp#(respwidth)) ff_nc_read_response  <- mkBypassFIFOF();
    
    FIFOF#(DCache_mem_writereq#(paddr, TMul#(wordsize, 8))) ff_nc_write_request  <- mkSizedFIFOF(2);
    
    FIFOF#(DCache_mem_writereq#(paddr, TMul#(blocksize, TMul#(wordsize, 8)))) ff_write_mem_request    
                                                                              <- mkSizedFIFOF(1);
    FIFOF#(DCache_mem_writeresp) ff_write_mem_response  <- mkBypassFIFOF();

    Wire#(Bool) wr_takingrequest <- mkDWire(False);
    Wire#(Bool) wr_cache_enable<-mkWire();
    Wire#(Bit#(respwidth)) wr_resp_word <- mkUnsafeDWire(?);
    `ifdef pysimulate
      FIFOF#(Bit#(1)) ff_meta <- mkSizedFIFOF(2);
    `endif
    `ifdef perfmonitors
      Wire#(Bit#(1)) wr_total_read_access <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_write_access <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_atomic_access <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_io_reads <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_io_writes <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_read_miss <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_write_miss <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_atomic_miss <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_readfb_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_writefb_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_atomicfb_hits <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_fbfills <- mkDWire(0);
      Wire#(Bit#(1)) wr_total_evictions <- mkDWire(0);
    `endif
    // ------------------------------------------------------------------------------------------//

   
    // ------------------------ Structures required for cache RAMS ------------------------------//
`ifdef ECC
    Ifc_mem_config1rw#(sets, (TMul#(blocksize,ecc_encoded_parity_wordsize)), ebanks) ecc_arr [v_ways]; // ecc array
    Reg#(Bool) perform_store_upd<-mkDReg(False);
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
`ifdef ECC
      fb_addr[i]<-mkConfigReg(0);
      fb_enables[i]<-mkConfigReg(0);
      fb_dataline[i]<-mkConfigReg(0);
      fb_dirty[i]<-mkConfigReg(0);
      fb_err[i]<-mkConfigReg(0);
`else
      fb_addr[i]<-mkReg(0);
      fb_enables[i]<-mkReg(0);
      fb_dataline[i]<-mkReg(0);
      fb_dirty[i]<-mkReg(0);
      fb_err[i]<-mkReg(0);
`endif
    end
    Wire#(RespState) wr_fb_response <- mkDWire(None);
    Wire#(Bit#(respwidth)) wr_fb_word <-mkDWire(0);
    Wire#(Bit#(TLog#(fbsize))) wr_fbindexhit <-mkDWire(0);
    Wire#(Bit#(1)) wr_fb_err <-mkDWire(0);
    // this register is used to ensure that the cache does not do a tag match when FB is polling on
    // a line for the requested word.
    Reg#(Bool) rg_polling <-mkReg(False);
    `ifdef pysimulate
      Wire#(Bool) wrpolling<-mkDWire(False);
    `endif

    // This register indicates which entry in the FB should be allocated when there is miss in the
    // FB and the cache for a given request.
    Reg#(Bit#(TLog#(fbsize))) rg_fbmissallocate <-mkConfigReg(0);

    // This register follows the rg_fbmissallocate register but is updated when the last word of a
    // line is filled in the FB on a miss.
    FIFOF#(Bit#(TLog#(fbsize))) ff_fb_fillindex <-mkSizedFIFOF(2);
    Wire#(Maybe#(Bit#(TLog#(fbsize)))) wr_fbbeingfilled <-mkDWire(tagged Invalid);

    // This register points to the entry in the FB which needs to be written back to the cache
    // whenever possible.
    Reg#(Bit#(TLog#(fbsize))) rg_fbwriteback <-mkReg(0);
    Reg#(Bit#(blocksize))     rg_fbfillenable <- mkReg(0);
    Reg#(Bool) rg_readdone <-mkDReg(False);
    Wire#(Bool) wr_access_fault <- mkDWire(False);
    
    Bit#(tagbits) writetag=fb_addr[rg_fbwriteback][v_paddr-1:v_paddr-v_tagbits];
    Bit#(linewidth) writedata=fb_dataline[rg_fbwriteback];

    Bool fb_full= (all(isTrue,readVReg(fb_valid)));
    Bool fb_empty=!(any(isTrue,readVReg(fb_valid)));
    Bit#(TLog#(sets)) fillindex=fb_addr[rg_fbwriteback][v_setbits+v_blockbits+v_wordbits-1:
                                                                          v_blockbits+v_wordbits];
    // ------------------------------------------------------------------------------------------//

    // ----------------------------- structures for fence operation -----------------------------//
    Reg#(Bit#(ways)) rg_way_select<-mkReg(1);
    Reg#(Bit#(TLog#(sets))) rg_set_select <-mkReg(0);
    Reg#(Bool) rg_fence_pending <- mkReg(False);
    Reg#(Bool) rg_globaldirty <- mkReg(False);
    Reg#(Bool) rg_fenceinit <-mkReg(True);
    // ------------------------------------------------------------------------------------------//

    // -------------------------- Structures for store-buffer -----------------------------------//

    Reg#(Bit#(paddr)) store_addr [v_sbsize];
    Reg#(Bit#(respwidth)) store_data [v_sbsize];
    Reg#(Bit#(2)) store_size [v_sbsize];
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
    Wire#(Bool) wr_store_response <- mkDWire(False);
    Wire#(Bool) wr_allocate_storebuffer <- mkDWire(False);

    Wire#(Bit#(respwidth)) wr_sb_hitword <-mkDWire(0);
    Wire#(Bit#(respwidth)) wr_sb_mask <- mkDWire(0);

    Bool sb_full= (all(isTrue,readVReg(store_valid)));
    Bool sb_empty=!(any(isTrue,readVReg(store_valid)));
    Wire#(Bool) wr_store_in_progress <- mkDWire(False);
    // ------------------------------------------------------------------------------------------//

    /**************************************ECC Hamming Encoded Parity structures******************/

`ifdef ECC // bug fix CReg may be reverted
    Reg#(Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize))) fb_ecc_encoded_parity_line [v_fbsize];
    Reg#(Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize))) fb_ecc_encoded_parity_line_full [v_fbsize][2];
    Reg#(Bit#(TAdd#(1,blockbits))) rg_j[2]  <- mkCReg(2,0);
    for(Integer i=0;i<v_fbsize;i=i+1)begin
      fb_ecc_encoded_parity_line[i]<-mkConfigReg(0);
      fb_ecc_encoded_parity_line_full[i]<-mkCReg(2,0);
    end

    Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize)) writeecc=fb_ecc_encoded_parity_line[rg_fbwriteback]; //bug fix
    Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize)) junkecc=0; // bug fix

    Reg#(Bit#(ecc_encoded_parity_linewidth)) wr_upd_fillingmask_ecc <-mkConfigReg(0);
    Reg#(Bit#(ecc_encoded_parity_linewidth)) wr_upd_fillingdata_ecc <-mkConfigReg(0);
    Reg#(Bit#(ecc_encoded_parity_linewidth)) rg_upd_fillingmask_ecc <-mkReg(0);
    Reg#(Bit#(ecc_encoded_parity_linewidth)) rg_upd_fillingdata_ecc <-mkReg(0);

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

    Bool fill_oppurtunity=(!ff_core_request.notEmpty && !wr_takingrequest) && !fb_empty &&
         /*countOnes(fb_valid)>0 &&*/ (fillindex!=rg_latest_index) && !wr_store_in_progress;

    rule display_stuff;
      `logLevel( dcache, 2, $format("DCACHE : fb_full:%b fb_empty:%b rg_fbwb:%d rg_fbmiss:%d \
fbvalid:%b", fb_full, fb_empty, rg_fbwriteback, rg_fbmissallocate, readVReg(fb_valid)))
      `logLevel( dcache, 2, $format("DCACHE : sb_empty:%b sb_full:%b store_valid:%b storetail:%d \
storehd:%d", sb_empty, sb_full, readVReg(store_valid), rg_storetail, rg_storehead))

    endrule

    // This rull fires when the fence operation is signalled by the core and the FB is empty.
    // if the rg_global_dirty is not set then the dcache 
    // will take only a single cycle since all the valid signals in the cache and FB are registers
    // which can be reset in one-shot. The replacement policies for each set should also be reset.
    // Since they too are implemented as array of registers it can be done in a single cycle.
    // Additionaly, any set that has no dirty lines is immediately skipped. This improves fence
    // performance.
    rule fence_operation(ff_core_request.first.fence && rg_fence_stall && fb_empty &&
                                                !rg_replaylatest &&   sb_empty && !rg_fence_pending);
      let request = ff_core_request.first;
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
`ifdef ECC
	rg_upd_fillingmask_ecc <= 0;
	rg_upd_fillingdata_ecc <= 0;
	wr_upd_fillingmask_ecc <= 0;
	wr_upd_fillingdata_ecc <= 0;
`endif

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
          `logLevel( dcache, 2, $format("DCACHE: Fence Evicting Addr:%h Data:%h", final_address,
                                        final_line))
          ff_write_mem_request.enq(DCache_mem_writereq{address   : final_address,
                                                burst_len : fromInteger(valueOf(blocksize) - 1),
                                                burst_size : fromInteger(valueOf(TLog#(wordsize))),
                                                data      : final_line});
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
        ff_core_response.enq(DMem_core_response{word: ?, trap : False, cause: ?,
                                                  epochs : request.epochs});
        `ifdef pysimulate
          ff_meta.enq(0);
        `endif
      end
      else
        rg_fenceinit<=False;

      `logLevel( dcache, 0, $format("DCACHE : Fence in progress."))
      `logLevel( dcache, 1, $format("DCACHE : Fence : way:%b set:%d index:%d nset:%d", 
                                    rg_way_select, rg_set_select, index, next_set))
    endrule

    rule receive_memory_response(rg_fence_pending && ff_core_request.first.fence);
      rg_fence_pending<=False;
      let x=ff_write_mem_response.first;
    endrule

    rule deq_write_response;
      ff_write_mem_response.deq;
    endrule

    // This rule will perform the check on the tags from the cache and detect is there is a hit or a
    // miss. On a hit the required word is forwarded to the rule respond_to_core. On a miss the
    // address is forwarded to the rule request_to_memory;
    rule tag_match(ff_core_response.notFull && !rg_miss_ongoing && !rg_polling &&
          !ff_core_request.first.fence && !fb_full && !rg_replaylatest && !sb_full);
      let request = ff_core_request.first();
      Bit#(paddr) phy_addr = truncate(request.address);
      Bit#(TSub#(vaddr,paddr)) upper_bits=truncateLSB(request.address);
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phy_addr[v_blockbits+v_wordbits-1:0],3'b0};
`ifdef ECC
      Bit#(TAdd#(TLog#(ecc_encoded_parity_wordsize),blockbits)) block_offset_ecc=(phy_addr[v_blockbits+v_wordbits-1:v_wordbits]); //ported bug fix
`endif
      Bit#(blockbits) word_index= phy_addr[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(tagbits) request_tag = phy_addr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= phy_addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];

      Bit#(linewidth) dataline[v_ways];
`ifdef ECC
      Bit#(ecc_encoded_parity_linewidth) dataline_ecc[v_ways];
`endif
      Bit#(tagbits) tag[v_ways];
      for(Integer i=0;i<v_ways;i=i+1)begin
        tag[i]<- tag_arr[i].read_response;
        dataline[i]<- data_arr[i].read_response;
`ifdef ECC
        dataline_ecc[i]<- ecc_arr[i].read_response;
`endif
      end
      Bit#(linewidth) hitline=0;
`ifdef ECC
      Bit#(ecc_encoded_parity_linewidth) hitline_ecc=0;
`endif
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
      wr_hitway<=truncate(pack(countZerosLSB(hit)));
      wr_hitline<=hitline;
`ifdef ECC
      wr_hitline_ecc<=hitline_ecc;
`endif
      Bit#(respwidth) response_word=truncate(hitline>>block_offset)  `ifdef ecc_test ^ wr_err_mask `endif  ;

`ifdef ECC
      Bit#(ecc_encoded_parity_wordsize) response_word_ecc = 0;
      Bit#(TAdd#(1, TLog#(ecc_wordsize))) decoded_parity = 0;
      Bit#(respwidth) response_word_correct = 0;
      Bit#(1) det_only = 0;
      Bool trap = False;
      Bool resp_ecc_fault = False;

      response_word_ecc= truncate(hitline_ecc>> (block_offset_ecc*fromInteger(v_ecc_encoded_parity_wordsize)));

      Bit#(ecc_wordsize) ecc_word = 0;
      Bit#(encoded_paritysize) ecc_enc_word = 0;
      Bit#(ecc_wordsize) word_correct = 0;
      for (Integer i=0; i < v_num_ecc_per_word ; i=i+1) begin
        ecc_word = response_word[i*v_ecc_wordsize+v_ecc_wordsize-1:i*v_ecc_wordsize];
        ecc_enc_word = response_word_ecc[i*v_encoded_paritysize+v_encoded_paritysize-1:i*v_encoded_paritysize];
        {word_correct,decoded_parity, trap} = ecc_hamming_decode_correct(ecc_word,ecc_enc_word,det_only);
        if (trap == True) begin
           resp_ecc_fault = resp_ecc_fault || trap;
        end
        //else if (((decoded_parity == 0) || (det_only == 1'b1)) && (trap == False)) begin
        else begin
           response_word_correct[i*v_ecc_wordsize+v_ecc_wordsize-1:i*v_ecc_wordsize] = word_correct;
        end
      end
      wr_resp_ecc_fault <= resp_ecc_fault;
`endif

      if(|upper_bits==1)
        wr_access_fault<=True;
      else if(cache_hit)begin
        wr_cache_response<=Hit;
`ifdef ECC
        wr_cache_hitword<=response_word_correct;
`else
        wr_cache_hitword<=response_word;
`endif
      end
      else begin
        wr_cache_response<=Miss;
      end

      `logLevel( dcache, 0, $format("DCACHE : TAGCMP for Req: ",fshow(request)))
      `logLevel( dcache, 1, $format("DCACHE : TAGCMP Result. Hit:%b Hitline:%h",hit, hitline))
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
      let request = ff_core_request.first();
      Bit#(paddr) phy_addr = truncate(request.address);
      Bit#(setbits) read_set = phy_addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phy_addr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(TAdd#(3,(wordbits))) byte_index = {phy_addr[v_wordbits-1:0],3'b000}; // bug fix
`ifdef ECC
      Bit#(TAdd#(TLog#(ecc_encoded_parity_wordsize),blockbits))block_offset_ecc=phy_addr[v_blockbits+v_wordbits-1:v_wordbits]; //bug_fix
      Bit#(TAdd#(3,TAdd#(TLog#(respwidth),blockbits)))block_offset_tmp={phy_addr[v_blockbits+v_wordbits-1:v_wordbits]} * fromInteger(v_respwidth);
      Bit#(ecc_encoded_parity_linewidth) hitline_ecc=0;
`endif
      Bit#(blockbits) word_index=phy_addr[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(TAdd#(tagbits,setbits)) t=truncateLSB(phy_addr);
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
`ifdef ECC
	  if((rg_j[1] >= 0) && (rg_j[1] <= fromInteger(v_blocksize))) //bug fix
		if (perform_store_upd == True) begin
          		hitline_ecc=(~wr_upd_fillingmask_ecc & fb_ecc_encoded_parity_line[i]) | (wr_upd_fillingmask_ecc & wr_upd_fillingdata_ecc);
		end
		else begin
          		hitline_ecc=fb_ecc_encoded_parity_line[i];
		end
`endif
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
      `ifdef pysimulate
        wrpolling<=rg_polling;
      `endif

      Bit#(respwidth) fb_word = 0;
      Bool fb_ecc_fault = False;
      fb_word=truncate(hitline>>block_offset); 

`ifdef ECC
      Bit#(respwidth) fb_word_tmp = 0;
      fb_word_tmp=truncate(hitline>>block_offset_tmp) `ifdef ecc_test ^ wr_err_mask `endif ; // bug fix 
      Bit#(ecc_encoded_parity_wordsize) fb_word_ecc = 0;
      Bit#(TAdd#(1, TLog#(ecc_wordsize))) decoded_parity = 0;
      Bit#(respwidth) fb_word_correct = 0;
      Bit#(1) det_only = 0;
      Bool trap = False;

      fb_word_ecc= truncate(hitline_ecc>> (block_offset_ecc*fromInteger(v_ecc_encoded_parity_wordsize)));

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
      wr_fb_word <= fb_word;
`endif

      wr_fbindexhit<=truncate(pack(countZerosLSB(fbhit)));
      wr_fb_err<= fberr | pack(fb_ecc_fault);

      `logLevel( dcache, 0, $format("DCACHE : FB Polling for Req: ",fshow(request)))
      `logLevel( dcache, 1, $format("DCACHE : FP Polling Result. linehit:%b wordhit:%b", 
                                    linehit, wordhit))

      `ifdef ASSERT
        dynamicAssert(countOnes(fbhit)<=1,"More than one line in FB is hit");
      `endif
    endrule

    rule check_hit_in_storebuffer(ff_core_response.notFull && !ff_core_request.first.fence);
      let offset = (v_respwidth==64)?2:1;
      let request = ff_core_request.first();
      Bit#(paddr) phy_addr = truncate(request.address);
      Bit#(TLog#(respwidth)) shiftamt1 = {store_addr[rg_storetail-1][v_wordbits-1:0],3'b0};
      Bit#(respwidth) storemask1 = 0;
      Bit#(respwidth) storemask2 = 0;
      Bool validm1 = store_valid[rg_storetail-1];
      Bool valid = store_valid[rg_storetail];
      Bit#(TSub#(paddr,wordbits)) wordaddr = truncateLSB(phy_addr);

      Bit#(TSub#(paddr,wordbits)) compareaddr1=truncateLSB(store_addr[rg_storetail-1]);
      Bit#(TSub#(paddr,wordbits)) compareaddr2=truncateLSB(store_addr[rg_storetail]);
      if(compareaddr1 == wordaddr /*&& validm1*/)begin
        Bit#(respwidth) temp = store_size[rg_storetail-1]==0?'hff:
                          store_size[rg_storetail-1]==1?'hffff:
                          store_size[rg_storetail-1]==2?'hffffffff:'1;
        temp = temp << shiftamt1; 
        storemask1 = temp;  
      end
      if(compareaddr2 == wordaddr /*&& valid*/)begin
        Bit#(TLog#(respwidth)) shiftamt2 = {store_addr[rg_storetail][v_wordbits - 1:0], 3'b0};
        Bit#(respwidth) temp = store_size[rg_storetail]==0?'hff:
                          store_size[rg_storetail]==1?'hffff:
                          store_size[rg_storetail]==2?'hffffffff:'1;
        temp = temp << shiftamt2;
        storemask2 = temp&(~storemask1); // 'h00_00_00_FF
      end
    
      let data1 = storemask1& store_data[rg_storetail-1];
      let data2 = storemask2& store_data[rg_storetail];
      wr_sb_hitword<=data1|data2;
      wr_sb_mask<=storemask1|storemask2;
    endrule

    rule allocate_storebuffer( (wr_cache_response == Hit || 
                               (wr_fb_response == Hit && wr_fb_err == 0) ||
                                wr_allocate_storebuffer|| wr_nc_response == Hit) &&  
                                ff_core_request.first.access != 0 && 
                                !ff_core_request.first.fence && !wr_access_fault);
      let request = ff_core_request.first();
      wr_store_in_progress<=True;
      Bit#(paddr) phy_addr = truncate(request.address);
      Bit#(TLog#(fbsize)) fbindex = (wr_fb_response==Hit)?wr_fbindexhit:rg_fbmissallocate;
      Bit#(TLog#(sbsize)) sbindex = rg_storetail;
    `ifdef atomic
      if(request.access == 2)begin
        request.data = fn_atomic_op(request.atomic_op, request.data, wr_resp_word);
      end
    `endif
      request.data = case (request.size[1 : 0])
          'b00 : duplicate(request.data[7 : 0]);
          'b01 : duplicate(request.data[15 : 0]);
          'b10 : duplicate(request.data[31 : 0]);
          default : request.data;
      endcase;
      store_data[sbindex] <= request.data;
      store_valid[sbindex]<=True;
      store_size[sbindex] <= truncate(request.size);
      store_addr[sbindex] <= phy_addr;
      store_fbindex[sbindex]<=fbindex;
      store_io[sbindex]<=pack(wr_allocate_storebuffer || wr_nc_response == Hit);
      store_epoch[sbindex] <= request.epochs;
      rg_storetail<=rg_storetail+1;
      `logLevel( dcache, 0, $format("DCACHE : Allocating SB. sbindex:%d, data:%h addr:%h, \
fbindex:%d", sbindex, request.data, phy_addr, fbindex))
    endrule

    // This rule is fired when there is a hit in the cache. The word received is further modified
    // depending on the request made by the core.
    rule respond_to_core(wr_cache_response == Hit || wr_fb_response == Hit || wr_nc_response == Hit
      || wr_access_fault);
      let request = ff_core_request.first();
      Bit#(paddr) phy_addr = truncate(request.address);
      Bit#(respwidth) word=0;
      //Bool err = wr_access_fault;
      Bool err=wr_access_fault `ifdef ECC || wr_resp_ecc_fault `endif ;
      Bit#(setbits) set_index=phy_addr[v_setbits + v_blockbits + v_wordbits - 1 : v_blockbits + v_wordbits];
      let offset = (v_respwidth==64)?2:1;
      Bit#(TLog#(respwidth)) loadoffset = {phy_addr[v_wordbits - 1:0],3'b0};
      if(wr_cache_response==Hit)begin
        word=wr_cache_hitword;
        if(alg=="PLRU") begin
          wr_cache_hitindex<=tagged Valid set_index;
          repl.update_set(set_index, wr_hitway);//wr_replace_line); 
        end
      end
      else if(wr_fb_response==Hit)begin
        if(request.access == 0 `ifdef atomic || request.access == 2 `endif )begin
          Bit#(respwidth) updated_word = wr_fb_word<<loadoffset;
          updated_word= (updated_word&~wr_sb_mask)|(wr_sb_hitword);
          word = updated_word>>loadoffset;
        end
        else 
          word=wr_fb_word;

        err=unpack(wr_fb_err);
        `ifdef perfmonitors
          // Only when the hit in the LB is not because of a miss should the counter be enabled.
          if(!rg_miss_ongoing) begin
              if(request.access == 0)
                wr_total_readfb_hits <= 1;
              if(request.access == 1)
                wr_total_writefb_hits <= 1;
            `ifdef atomic
              if(request.access == 2)
                wr_total_atomicfb_hits <= 1;
            `endif
          end
        `endif
      end
      else if(wr_nc_response==Hit)begin
        Bit#(respwidth) updated_word = wr_nc_word<<loadoffset;
        updated_word = (updated_word&~wr_sb_mask)|(wr_sb_hitword);
        word = updated_word>>loadoffset;
        err=wr_nc_err;
      `ifdef perfmonitors
        if(request.access == 0)
          wr_total_io_reads <= 1;
        if(request.access == 1)
          wr_total_io_writes <= 1;
        `endif
      end
      if(request.access != 0 && (wr_fb_response == Hit || wr_cache_response == Hit))begin
        rg_globaldirty<=True;
      end

      // This captures a line from the cache RAMS into the Fill buffer on a store/atomic hit.
      if(request.access != 0 && wr_cache_response == Hit)begin
        rg_fbmissallocate<=rg_fbmissallocate+1;
        fb_valid[rg_fbmissallocate]<=True;
        fb_addr[rg_fbmissallocate] <= phy_addr;
        fb_err[rg_fbmissallocate]<=0;
        fb_enables[rg_fbmissallocate]<='1;
        fb_dataline[rg_fbmissallocate]<=wr_hitline;
`ifdef ECC
	fb_ecc_encoded_parity_line[rg_fbmissallocate]<= wr_hitline_ecc; // bug fix
`endif
        fb_dirty[rg_fbmissallocate]<=rg_dirty[set_index][wr_hitway];
        rg_valid[set_index][wr_hitway]<=1'b0;
        rg_dirty[set_index][wr_hitway] <= 1'b0;
        `ifdef ASSERT
          dynamicAssert(!fb_valid[rg_fbmissallocate],"Allocating valid entry in fill - buffer on \
Cache Hit");
        `endif
      end
      rg_miss_ongoing<=False;
      // depending onthe request made by the core, the word is either sigextended/zeroextend and
      // truncated if necessary.
      wr_resp_word<= word;
      word=
        case (request.size)
          'b000: signExtend(word[7:0]);
          'b001: signExtend(word[15:0]);
          'b010: signExtend(word[31:0]);
          'b100: zeroExtend(word[7:0]);
          'b101: zeroExtend(word[15:0]);
          'b110: zeroExtend(word[31:0]);
          default: word;
        endcase;
        `logLevel( dcache, 0, $format("DCACHE: Sending to Core. Word:%h Addr:%h Access:%d TagHit:%b \
FBHit:%b NCHit:%b", word, request.address, request.access, pack(wr_cache_response), 
pack(wr_fb_response), pack(wr_nc_response)))
      Bit#(`causesize) cause = request.access == 0?`Load_access_fault:`Store_access_fault;
      if(err)
	word = truncate(request.address);
      ff_core_response.enq(DMem_core_response{word : word, trap : err, cause : cause, 
                                                  epochs : request.epochs});
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
        dynamicAssert(countOnes(temp)<=1, "More than one data structure shows a hit");
        dynamicAssert(countOnes(temp1)<=1, "More than one data structure shows a hit");
      `endif
    endrule

    `ifdef pysimulate
      rule put_meta;
        if(wr_cache_response==Hit)
          ff_meta.enq(1);
        else if(wr_fb_response==Hit)
          ff_meta.enq(pack(!wrpolling));
      endrule
    `endif

    // This rule will generate a miss request to the next level memory. The address from the core
    // cannot be directly sent to the bus. The address will have to made word - aligned before 
    // sending it to the next level.
    // Here as soon as a miss is detected we allocate a line in the fill buffer for the requested
    // access. The line-allocation is done using rg_fbmissallocate register which follows a
    // round-robin mechanism for now. 
    // the line to be filled is further enqued into the ff_fb_fillindex which is used to identify
    // which line is the memory response to fill in the FB
    rule request_to_memory(wr_cache_response == Miss && !rg_miss_ongoing && wr_fb_response == Miss
                                         && wr_nc_response != Hit && !fb_full && !wr_access_fault);
                                                                                        
      let request = ff_core_request.first();
      Bit#(paddr) phy_addr = truncate(request.address);
      if(!isNonCacheable(phy_addr,wr_cache_enable)) begin
        phy_addr= (phy_addr>>v_wordbits)<<v_wordbits; // align the address to be one word aligned.
        ff_read_mem_request.enq(DCache_mem_readreq{address    : phy_addr,
                                                   burst_len  : fromInteger(v_blocksize - 1),
                                                   burst_size : fromInteger(v_wordbits)});
        rg_miss_ongoing<=True;
        rg_fbmissallocate<=rg_fbmissallocate+1;
        fb_valid[rg_fbmissallocate]<=True;
        fb_addr[rg_fbmissallocate]<=phy_addr;
        fb_err[rg_fbmissallocate]<=0;
        fb_enables[rg_fbmissallocate]<=0;
        fb_dirty[rg_fbmissallocate] <= 0;
`ifdef ECC
	fb_ecc_encoded_parity_line[rg_fbmissallocate] <= 0; //bug fix
`endif
        ff_fb_fillindex.enq(rg_fbmissallocate);
        `logLevel( dcache, 0, $format("DCACHE : Sending Line Request for Addr:%h", phy_addr)) 
        `logLevel( dcache, 1, $format("DCACHE : Allocating FBindex:", rg_fbmissallocate)) 
        `ifdef ASSERT
          dynamicAssert(!fb_valid[rg_fbmissallocate],"Allocating valid entry in fill-buffer");
        `endif
      `ifdef perfmonitors
        if(request.access == 0)
          wr_total_read_miss <= 1;
        if(request.access == 1)
          wr_total_write_miss <= 1;
        `ifdef atomic
          if(request.access == 2)
            wr_total_atomic_miss <= 1;
        `endif
      `endif
      end
      else if(request.access == 0 `ifdef atomic || request.access == 2 `endif )begin
        rg_miss_ongoing<=True;
        ff_nc_read_request.enq(DCache_mem_readreq{address    : phy_addr,
                                                  burst_len  : 0,
                                                  burst_size : request.size});
        `logLevel( dcache, 0, $format("DCACHE : Sending IO Request for Addr:%h", phy_addr))
      end
      else if(request.access == 1)begin
        wr_allocate_storebuffer<=True;
        ff_core_response.enq(DMem_core_response{ word:?, trap : False, cause: ?,
                                                   epochs : request.epochs});
        ff_core_request.deq;
        wr_resp_word <= request.data;
        `logLevel( dcache, 0, $format("DCACHE : Allocating IO Write in SB for Addr: %h", phy_addr))
      end

    endrule

    // This rule will update an entry pointed by the entry in ff_fb_fillindex with the incoming
    // response from the lower memory level.
    rule update_fb_with_memory_response(!fb_empty);
      let response = ff_read_mem_response.first();

`ifdef ECC
      Bit#(ecc_wordsize) ecc_word = 0;
      Bit#(TAdd#(2, TLog#(ecc_wordsize))) ecc_encoded_parity = 0;
      Bit#(TMul#((TDiv#(respwidth, ecc_wordsize)), (TAdd#(2, TLog#(ecc_wordsize))))) ecc_encoded_parity_word = 0;
      for (Integer i=0; i < v_num_ecc_per_word; i=i+1) begin
        ecc_word = response.data[i*v_ecc_wordsize+v_ecc_wordsize-1:i*v_ecc_wordsize];
        ecc_encoded_parity = ecc_hamming_encode(ecc_word);
        ecc_encoded_parity_word[i * v_encoded_paritysize+ v_encoded_paritysize -1: i*v_encoded_paritysize] = ecc_encoded_parity;
      end
`endif

      let fbindex=ff_fb_fillindex.first();
      fb_err[fbindex] <= pack(response.err);
      ff_read_mem_response.deq;
      Bit#(blocksize) temp=0;
      Bit#(blockbits) word_index=fb_addr[fbindex][v_blockbits+v_wordbits-1:v_wordbits];
`ifdef ECC
      Bit#(TAdd#(blockbits,TLog#(ecc_encoded_parity_wordsize))) word_index_ecc=fb_addr[fbindex][v_blockbits+v_wordbits-1:v_wordbits]; // bug fix
`endif
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
      Bit#(linewidth) final_data = (wr_upd_fillingmask & wr_upd_fillingdata) | 
                                   (mask & duplicate(response.data));
      Bit#(linewidth) x=(~final_mask&fb_dataline[fbindex]) | (final_mask&final_data);
      fb_dataline[fbindex]<=x;

`ifdef ECC
      Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize)) fb_ecc_encoded_parity_line_temp = 0;
      Bit#(TMul#(blocksize,ecc_encoded_parity_wordsize)) fb_ecc_mask_temp = 0;
      Bit#(ecc_encoded_parity_wordsize) mask_temp = '1;
      for (Integer i=0; i < v_blocksize; i=i+1) begin
        if (fromInteger(i) == rg_j[0]) begin
           fb_ecc_encoded_parity_line_temp[i*v_ecc_encoded_parity_wordsize+v_ecc_encoded_parity_wordsize-1:i*v_ecc_encoded_parity_wordsize] =ecc_encoded_parity_word;
           fb_ecc_mask_temp[i*v_ecc_encoded_parity_wordsize+v_ecc_encoded_parity_wordsize-1:i*v_ecc_encoded_parity_wordsize] = mask_temp;
        end
      end
      
      let shift_val = unpack(word_index_ecc*fromInteger(v_ecc_encoded_parity_wordsize));
      fb_ecc_encoded_parity_line_temp= rotateBitsBy(fb_ecc_encoded_parity_line_temp,shift_val); // bug fix 
      fb_ecc_mask_temp= rotateBitsBy(fb_ecc_mask_temp,shift_val); // bug fix 
      if (rg_j[0] < fromInteger(v_blocksize)) begin //bug_fix
      	if (rg_j[0] == fromInteger(v_blocksize-1)) begin //bug_fix
        	rg_j[0] <=0;
        	fb_ecc_encoded_parity_line_full[fbindex][0] <= (~rg_upd_fillingmask_ecc & ((~fb_ecc_mask_temp & fb_ecc_encoded_parity_line[fbindex]) | fb_ecc_encoded_parity_line_temp)) | (rg_upd_fillingmask_ecc & rg_upd_fillingdata_ecc);
        end
	else
        	rg_j[0] <= rg_j[0] + 1;
        fb_ecc_encoded_parity_line[fbindex] <= (~rg_upd_fillingmask_ecc & ((~fb_ecc_mask_temp & fb_ecc_encoded_parity_line[fbindex])| fb_ecc_encoded_parity_line_temp)) | (rg_upd_fillingmask_ecc & rg_upd_fillingdata_ecc);
      end
`endif

      if(response.last) begin
        ff_fb_fillindex.deq();
      end
      `logLevel( dcache, 0, $format("DCACHE : Received from mem: ",fshow(ff_read_mem_response.first)))
      `logLevel( dcache, 2, $format("DCACHE : Filling FB. fbindex:%d fb_addr:%h fb_data:%h \
fbenable:%h", fbindex, fb_addr[fbindex], fb_dataline[fbindex], fb_enables[fbindex]))
      `ifdef ASSERT
        dynamicAssert(fb_enables[fbindex]!='1,"Filling FB with already filled line");
      `endif
      wr_fbbeingfilled<=tagged Valid fbindex;
    endrule
    rule receive_nc_response;
      let response = ff_nc_read_response.first;
      `logLevel( dcache, 1, $format("DCACHE: received IO response: ", fshow(response)))
      ff_nc_read_response.deq;
      wr_nc_err <= response.err;
      wr_nc_word <= response.data;
      wr_nc_response<=Hit;
      `ifdef ASSERT
        dynamicAssert(response.last,"Why is IO response a burst");
      `endif
    endrule
    
    // This rule will evict an entry from the fill - buffer and update it in the cache RAMS. 
    // Multiple conditions under which this rule can fire:
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
    // line in one = cycle. The latest request from the core is replayed if the replacement was to 
    // the same index.
    rule release_from_FB((fb_full || fill_oppurtunity || rg_fence_stall) && 
                          !rg_replaylatest && !fb_empty && fb_valid[rg_fbwriteback] && 
                          (&fb_enables[rg_fbwriteback]) == 1 
                          && sb_empty);
      // if line is valid and is completely filled.
      let addr=fb_addr[rg_fbwriteback];
      Bit#(setbits) set_index = addr[v_setbits + v_blockbits + v_wordbits - 1 : 
                                                                          v_blockbits + v_wordbits];
      Bit#(tagbits) tag = addr[v_paddr-1:v_paddr-v_tagbits];
      let waynum<-repl.line_replace(set_index, rg_valid[set_index], rg_dirty[set_index]);
      // the line being replaced is dirty then evict it.
      if(fb_err[rg_fbwriteback]==0)begin
        if((rg_valid[set_index][waynum]&rg_dirty[set_index][waynum])==1 && !rg_readdone)begin
          `logLevel( dcache, 1, $format("DCACHE : FBRelease. ReadPhase. index:%d",set_index))
          tag_arr[waynum].request(0,set_index,writetag);
          data_arr[waynum].request(0,set_index,writedata);
`ifdef ECC
          ecc_arr[waynum].request(0,set_index,writeecc);
`endif
          rg_readdone<=True;
        end
        else if((rg_valid[set_index][waynum]&rg_dirty[set_index][waynum])!=1 || rg_readdone)begin
          Bit#(TSub#(paddr,TAdd#(tagbits,setbits))) zeros='d0;
          let dirtytag<-tag_arr[waynum].read_response;
          let dirtydata<-data_arr[waynum].read_response;
`ifdef ECC
          let dirtyecc<-ecc_arr[waynum].read_response;
`endif
          Bit#(paddr) final_address={dirtytag,set_index,zeros};
          if(rg_readdone)begin
            `logLevel( dcache, 1, $format("DCACHE : FBRelease. Evict Addr:%h Data:%h", 
                                          final_address, dirtydata))
            ff_write_mem_request.enq(DCache_mem_writereq{address   : final_address,
                                               burst_len : fromInteger(valueOf(blocksize) - 1),
                                               burst_size : fromInteger(valueOf(TLog#(wordsize))),
                                               data      : dirtydata});
          `ifdef perfmonitors
            wr_total_evictions <= 1;
          `endif
          end
          rg_valid[set_index][waynum]<=1'b1;
          rg_dirty[set_index][waynum]<=fb_dirty[rg_fbwriteback];
`ifdef ECC
          ecc_arr[waynum].request(1,set_index,writeecc);
`endif
          tag_arr[waynum].request(1,set_index,writetag);
          data_arr[waynum].request(1,set_index,writedata);
          rg_fbwriteback<=rg_fbwriteback+1;
          fb_valid[rg_fbwriteback]<=False;
          // TODO is the rg_dirty check in the following if required?
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
          `logLevel( dcache, 1, $format("DCACHE : ReleaseFiring. rg_fbwb:%d index:%d tag:%h way:%d", 
                                         rg_fbwriteback, set_index, writetag, waynum))
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
`ifdef ECC
	ecc_arr[i].request(0,rg_latest_index,writeecc);
`endif
      end
      `logLevel( dcache, 1, $format("DCACHE : Replaying last request for index:%d", rg_latest_index))
    endrule

    interface core_req=interface Put
      method Action put(DCache_core_request#(vaddr, respwidth, esize) req) 
                if( ff_core_response.notFull && !rg_replaylatest &&  !rg_fence_stall && !fb_full );
      `ifdef perfmonitors
          if(req.access == 0)
            wr_total_read_access <= 1;
          if(req.access == 1)
            wr_total_write_access <= 1;
        `ifdef atomic
          if(req.access == 2)
            wr_total_atomic_access <= 1;
        `endif
      `endif
      Bit#(paddr) phy_addr = truncate(req.address);
        Bit#(setbits) set_index=phy_addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall <= req.fence;
        for(Integer i=0;i<v_ways;i=i+1)begin
          data_arr[i].request(0,set_index,writedata);
          tag_arr[i].request(0,set_index,writetag);
`ifdef ECC
          ecc_arr[i].request(0,set_index,junkecc); //bug fix
`endif
        end
        wr_takingrequest<=True;
        `logLevel( dcache, 0, $format("DCACHE : Receiving request: ",fshow(req)))
        rg_latest_index<=set_index;
      endmethod
    endinterface;

    interface core_resp     = toGet(ff_core_response);

    interface read_mem_req  = toGet(ff_read_mem_request);
    
    interface read_mem_resp = toPut(ff_read_mem_response);

    interface nc_read_req   = toGet(ff_nc_read_request);

    interface nc_read_resp  = toPut(ff_nc_read_response);


    `ifdef pysimulate 
    interface meta = toGet(ff_meta)
    `endif 
    method Action cache_enable(Bool c);
      wr_cache_enable<=c;
    endmethod

    method Action perform_store(Bit#(esize) currepoch);
      let fbindex=store_fbindex[rg_storehead];
      let addr = store_addr[rg_storehead];
      let data = store_data[rg_storehead];
      let valid = store_valid[rg_storehead];
      let size = store_size[rg_storehead];
      let epoch = store_epoch[rg_storehead];
      let io = store_io[rg_storehead];
      Bit#(respwidth) temp = size[1 : 0] == 0?'hFF : 
                             size[1 : 0] == 1?'hFFFF : 
                             size[1 : 0] == 2?'hFFFFFFFF : '1;

      Bit#(linewidth) mask =zeroExtend(temp); 
`ifdef ECC
      Bit#(ecc_encoded_parity_wordsize) temp_ecc = '1;
      Bit#(ecc_encoded_parity_linewidth) mask_ecc =zeroExtend(temp_ecc); 
`endif
      Bit#(wordbits) zeros=0;
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits))) block_offset=
                                    {addr[v_blockbits+v_wordbits-1:0],3'b0};
      
      mask=mask<<block_offset;
      Bit#(linewidth) masked_data = (duplicate(data) & mask) | (~mask&fb_dataline[fbindex]); // bug fix
      Bit#(TAdd#(TLog#(respwidth), blockbits)) word_offset = (addr[v_blockbits+v_wordbits-1:v_wordbits]);
      Bit#(respwidth) masked_data_word = truncate(masked_data >> (word_offset * fromInteger(v_respwidth))); // bug fix
`ifdef ECC
      Bit#(TAdd#(blockbits,TLog#(ecc_encoded_parity_wordsize))) block_offset_ecc=addr[v_blockbits+v_wordbits-1:v_wordbits] * fromInteger(v_ecc_encoded_parity_wordsize);
      Bit#(ecc_wordsize) ecc_word = 0;
      Bit#(TAdd#(2, TLog#(ecc_wordsize))) ecc_encoded_parity = 0;
      Bit#(TMul#((TDiv#(respwidth, ecc_wordsize)), (TAdd#(2, TLog#(ecc_wordsize))))) ecc_encoded_parity_word_store = 0;
      for (Integer i=0; i < v_num_ecc_per_word; i=i+1) begin
        ecc_word = masked_data_word[i*v_ecc_wordsize+v_ecc_wordsize-1:i*v_ecc_wordsize]; // bug fix
        ecc_encoded_parity = ecc_hamming_encode(ecc_word);
        ecc_encoded_parity_word_store[i * v_encoded_paritysize+ v_encoded_paritysize -1: i*v_encoded_paritysize] = ecc_encoded_parity;
      end

      mask_ecc = mask_ecc << block_offset_ecc;
`endif
      //mask=mask<<block_offset; 
      `logLevel( dcache, 0, $format("DCACHE : Performing Store. sbhead:%d addr:%h data:%h",
                                     rg_storehead, addr, data))
      if(epoch==currepoch)begin
        if(io==1)begin
          `logLevel( dcache, 1, $format("DCACHE : IO Store Addr:%h Size:%d Data:%h", addr, 
                                         size, data))
          ff_nc_write_request.enq(DCache_mem_writereq{address     : addr,
                                                      burst_len   : 0,
                                                      burst_size  : zeroExtend(size),
                                                      data        : data});
        end
        else begin
          if(wr_fbbeingfilled matches tagged Valid .fbi &&& fbindex==fbi)begin
            wr_upd_fillingmask<=mask;
            wr_upd_fillingdata<=duplicate(data);
`ifdef ECC
            wr_upd_fillingmask_ecc<=mask_ecc;
            rg_upd_fillingmask_ecc<=mask_ecc;
            wr_upd_fillingdata_ecc<=duplicate(ecc_encoded_parity_word_store);
            rg_upd_fillingdata_ecc<=duplicate(ecc_encoded_parity_word_store);
	    perform_store_upd <= True;
`endif
            `logLevel( dcache, 1, $format("DCACHE : Store to FillingFB"))
          end
          else begin
            `logLevel( dcache, 1, $format("DCACHE : Store to FB index:%d",fbindex))
            fb_dataline[fbindex]<= (mask&duplicate(data)) |(~mask&fb_dataline[fbindex]);
            let check_fb_dataline = (mask&duplicate(data)) |(~mask&fb_dataline[fbindex]);
`ifdef ECC
	    fb_ecc_encoded_parity_line[fbindex]<= (mask_ecc&duplicate(ecc_encoded_parity_word_store)) | (~mask_ecc&fb_ecc_encoded_parity_line[fbindex]);
`endif
          end
          fb_dirty[fbindex]<=1'b1;
        end
      end
      else begin
        `logLevel( dcache, 0, $format("DCACHE : Dropping Store sbhead:%d",rg_storehead))
      end
      rg_storehead<=rg_storehead+1;
      store_valid[rg_storehead]<=False;
      `ifdef ASSERT
        dynamicAssert(store_valid[rg_storehead],"Performing Store on invalid entry in SB");
      `endif
    endmethod
    method Bool cacheable_store;
      Bool complete=True;
      if(store_io[rg_storehead]==1)
        complete=False;
      return complete;
    endmethod
    `ifdef perfmonitors
      method Bit#(13) perf_counters;
        return{wr_total_read_access ,wr_total_write_access ,wr_total_atomic_access ,wr_total_io_reads
          ,wr_total_io_writes ,wr_total_read_miss ,wr_total_write_miss ,wr_total_atomic_miss
          ,wr_total_readfb_hits ,wr_total_writefb_hits ,wr_total_atomicfb_hits ,wr_total_fbfills
        ,wr_total_evictions};
      endmethod
    `endif
      method DCache_mem_writereq#(paddr, TMul#(blocksize, TMul#(wordsize, 8))) write_mem_req_rd;
        return ff_write_mem_request.first;
      endmethod
      method Action write_mem_req_deq;
        ff_write_mem_request.deq;
      endmethod

    interface write_mem_resp = toPut(ff_write_mem_response);
    
    interface nc_write_req = toGet(ff_nc_write_request);

    method cache_available = ff_core_request.notFull && ff_core_response.notFull && 
                  !rg_replaylatest &&  !rg_fence_stall && !fb_full && !sb_full;
    method storebuffer_empty = sb_empty;

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
//  module mkdcache(Ifc_l1dcache#(4, 8, 64, 4 ,32,8,2,1));
//    let ifc();
//    mkl1dcache#(isIO, "PLRU") _temp(ifc);
//    return (ifc);
//  endmodule
endpackage

