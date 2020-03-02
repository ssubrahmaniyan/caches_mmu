/*
Copyright (c) 2019, IIT Madras All rights reserved.

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

corner-case-1: 
The valid bits of the ram are stored as registers and not in RAMs along with the TAG. Now, consider
a cycle where the following happens:

1. Release from FB updates the TAG RAMs and makes the valid register 1
2. Core initiates the access to the same entry
3. Note: the entry has the same TAG entry as being written by FB but was invalidated by a
previous fence.

In the next cycle, we will read the old value of the TAGs (which co-incidently is the same as what
we want) and also reads the valid bit as 1. Simultaneously, the FB will also give a hit since the
entry is held for an extra cycle. This leads to both RAM and FB claiming a hit - which is wrong. 
Solution: store the valid bit along with the rags in the RAMs.

corner-case-2:
Imagine a store is requested by the core (from exe-stage) which is a hit in the RAMs. 
When a perform store is initiated by the write-back stage, it is possible by now for that line to
have been evicted/replaced due to a FB release to the same set. Now the store would update the wrong
line
Solution:
Maybe the eviction can be stalled if the store is pending in the storebuffer to the same set.
--------------------------------------------------------------------------------------------------
*/
package dcache;
  `include "Logger.bsv"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import BRAMCore :: * ;
  import Vector :: * ;
  import GetPut :: * ;
  import Assert  :: * ;
  import OInt :: * ;
  import BUtils :: * ;
  import Memory :: * ; // only for the updateDataWithMask function
  import DReg :: * ;


  `include "dcache.defines"
  import dcache_types :: * ;
  import replacement_dcache :: * ;
  import mem_config :: * ;
  import dcache_storebuffer :: * ;
  import common_tlb_types::*;

  typedef struct{
    Bit#(addr)  phyaddr;
    Bit#(besize) init_enable;
    Bool io_request;
  } Pending_req#(numeric type addr, numeric type besize) deriving(Bits, Eq, FShow);

  interface Ifc_dcache#(numeric type wordsize,
                        numeric type blocksize,
                        numeric type sets,
                        numeric type ways,
                        numeric type paddr,
                        numeric type vaddr,
                        numeric type sbsize,
                        numeric type esize,
                      `ifdef ECC
                        numeric type ecc_wordsize,
                        numeric type ebanks,
                      `endif
                        numeric type dbanks,
                        numeric type tbanks,
                        numeric type buswidth
                           );
    interface Put#(DCache_core_request#(vaddr,TMul#(wordsize,8),esize)) put_core_req;
    interface Get#(DMem_core_response#(TMul#(wordsize,8),esize)) get_core_resp;
    interface Get#(DCache_mem_readreq#(paddr)) get_read_mem_req;
    interface Put#(DCache_mem_readresp#(buswidth)) put_read_mem_resp;
    method DCache_mem_writereq#(paddr, TMul#(blocksize, TMul#(wordsize, 8))) mv_write_mem_req;
    method Action ma_write_mem_req_deq;
    interface Put#(DCache_mem_writeresp) put_write_mem_resp;
  `ifdef supervisor
    interface Get#(DMem_core_response#(TMul#(wordsize,8),esize)) get_ptw_resp;
    interface Put#(DTLB_core_response#(paddr)) put_pa_from_tlb;
    interface Get#(DCache_core_request#(vaddr, TMul#(wordsize, 8), esize)) get_hold_req;
  `endif
  `ifdef perfmonitors
    method Bit#(13) mv_perf_counters;
  `endif
    method Action ma_cache_enable(Bool c);
    method Bool mv_storebuffer_empty;
    method Action ma_perform_store(Bit#(esize) currepoch);
    method Bool mv_cacheable_store;
    method Bool mv_cache_available;
    method Bool mv_commit_store_ready;
  endinterface

  /*doc:module: */
  (*conflict_free="rl_send_memory_request, rl_response_to_core"*)
  module mkdcache#(function Bool isNonCacheable(Bit#(paddr) addr, Bool cacheable), 
                  parameter Integer alg, parameter Bit#(32) id)
                  (Ifc_dcache#(wordsize, blocksize, sets, ways, paddr, vaddr, sbsize, esize, dbanks, 
                              tbanks, buswidth))
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
          Add#(o__, p__, 2),            // ensure that the buswidth is no more than 2 x respwidth

          // required by bsc
          Mul#(TDiv#(linewidth, TDiv#(linewidth, 8)), TDiv#(linewidth, 8),linewidth),
          Add#(a__, paddr, vaddr),
          Add#(b__, respwidth, linewidth),
          Add#(TAdd#(wordbits, blockbits), d__, paddr),
          Add#(e__, TLog#(ways), 4),
          Add#(f__, TLog#(ways), TLog#(TAdd#(1, ways))),
          Add#(g__, respwidth, buswidth),
          Mul#(buswidth, c__, linewidth),
          Add#(j__, 8, respwidth),
          Add#(k__, 16, respwidth),
          Add#(l__, 32, respwidth),
          Add#(m__, respwidth, vaddr),
          Add#(1, r__, respwidth),
          Add#(u__, TLog#(TDiv#(linewidth, buswidth)), paddr),
          Add#(x__, blockbits, paddr),
        `ifdef ASSERT
          Add#(1, n__, TLog#(TAdd#(1, ways))),
        `endif

          // for using mem_config
          Mul#(TDiv#(tagbits, tbanks), tbanks, tagbits),
          Add#(h__, TDiv#(tagbits, tbanks), tagbits),
          Mul#(TDiv#(linewidth, dbanks), dbanks, linewidth),
          Add#(i__, TDiv#(linewidth, dbanks), linewidth),
          Add#(q__, TDiv#(linewidth, buswidth), paddr),

          // for using storebuffer
          Add#(s__, wordbits, TMul#(wordbits, 2)),
          Add#(1, t__, sbsize),
          Mul#(16, v__, respwidth),
          Mul#(32, w__, respwidth)

    );

    String dcache = "";
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
    let v_respwidth=valueOf(respwidth);
    Integer lv_offset = case(valueOf(respwidth))
      32: 4;
      64: 8;
      128: 16;
    endcase;
    Integer lv_offset1 = case(valueOf(buswidth))
      32: 4;
      64: 8;
      128: 16;
    endcase;

    /*doc:func: This function generates the byte-enable for a data-line sized vector based on the
     * request made by the core */
    function Bit#(TDiv#(linewidth,8)) fn_enable(Bit#(blockbits) word_index);
      Bit#(TDiv#(linewidth,8)) write_enable = 'hF << ({4'b0,word_index}*fromInteger(lv_offset));
      return write_enable;
    endfunction
    
    /*doc:func: This function generates the byte-enable for a data-line sized vector based on the
     * request made by the core */
    function Bit#(TDiv#(linewidth,8)) fn_init_enable(Bit#(TLog#(TDiv#(linewidth,buswidth))) word_index);
      Bit#(TDiv#(linewidth,8)) we = case(valueOf(buswidth))
        32: 'hF;
        64:'hFF;
        default:'hFFFF;
      endcase;
      Bit#(TDiv#(linewidth,8)) write_enable = we << ({4'b0,word_index}*fromInteger(lv_offset1));
      return write_enable;
    endfunction

    /*doc:func: This function carries out the atomic operations based on the RISC-V ISA spec*/
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

    // ----------------------- FIFOs to interact with interface of the design -------------------//
    /*doc:fifo: This fifo stores the request from the core.*/
    FIFOF#(DCache_core_request#(vaddr, respwidth, esize)) ff_core_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response that needs to be sent back to the core.*/
    FIFOF#(DMem_core_response#(respwidth,esize))ff_core_response <- mkBypassFIFOF();
  `ifdef supervisor
    /*doc:fifo: This fifo stores the response that needs to be sent back to the ptw.*/
    FIFOF#(DMem_core_response#(respwidth,esize))ff_ptw_response <- mkBypassFIFOF();
  `endif
    /*doc:fifo: this fifo stores the read request that needs to be sent to the next memory level.*/
    FIFOF#(DCache_mem_readreq#(paddr)) ff_read_mem_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response from the next level memory.*/
    FIFOF#(DCache_mem_readresp#(buswidth)) ff_read_mem_response  <- mkBypassFIFOF();
    /*doc:fifo: this fifo stores the eviction request to be written back*/
    FIFOF#(DCache_mem_writereq#(paddr, linewidth)) ff_write_mem_request <- mkSizedFIFOF(1);
    /*doc:fifo: this fifo stores the write response from an eviction or a io write req*/
    FIFOF#(DCache_mem_writeresp) ff_write_mem_response  <- mkBypassFIFOF();
    /*doc:fifo: this fifo holds the request from core when there has been a tlbmiss */
    FIFOF#(DCache_core_request#(vaddr, respwidth, esize)) ff_hold_request <- mkBypassFIFOF();

  `ifdef supervisor 
    /*doc:fifo: this fifo receives the physical address from the TLB */
    FIFOF#(DTLB_core_response#(paddr)) ff_from_tlb <- mkBypassFIFOF();
  `endif

    // ------------------------ FIFOs for internal state-maintenance ---------------------------//
    /*doc:fifo: This fifo holds meta information of the miss/io request that was made by the core*/
    FIFOF#(Pending_req#(paddr, TDiv#(linewidth,8))) ff_pending_req <- mkUGSizedFIFOF(2);

    // -------------------- Register declarations ----------------------------------------------//

    /*doc:reg: register when True indicates a fence is in progress and thus will prevent taking any
     new requests from the core*/
    Reg#(Bool) rg_fence_stall <- mkReg(False);

    /*doc:reg: When tru indicates that a miss is being catered to*/
    Reg#(Bool) rg_handling_miss <- mkReg(False);

    //------------------------- Fill buffer data structures -------------------------------------//
    /*doc:reg: this register holds the incoming line from the memory on a miss request*/
    Reg#(Bit#(linewidth)) rg_fb_linedata <- mkReg(0);

    /*doc:reg: this register indicates if the current line being filled in the FB had an error from
    * the memory*/
    Reg#(Bool) rg_fb_err <- mkReg(False);

    /*doc:reg: This register holds information if the fill-buffer is dirty or not*/
    Reg#(Bit#(1)) rg_fb_dirty <- mkReg(0);

    /*doc:reg: this register holds the currently available bytes within the fill-buffer that can be
     * used to respond back to core*/
    Reg#(Bit#(TDiv#(linewidth,8))) rg_fb_enable <- mkReg(0);

    /*doc:reg:This register holds the next set of byte-enables that the response from the memory is
    * supposed to fill in the fill-buffer*/
    Reg#(Bit#(TDiv#(linewidth,8))) rg_fb_enable_temp <- mkReg(0);

    /*doc:reg: This register when True indicates that the fill-buffer line has been filled and
    * updated in the ram and thus the fill-buffer entries must be released and reset.*/
    Reg#(Bool) rg_fb_release <- mkDRegA(False);
    /*doc:reg: */
    Reg#(Bit#(TLog#(ways))) rg_release_way <- mkReg(0);
    // ------------------------------------------------------------------------------------------//
    
    // ----------------------------- structures for fence operation -----------------------------//
    /*doc:reg: this register selects the way for performing a fence operation */
    Reg#(Bit#(TLog#(ways))) rg_fence_way <- mkReg(0);
    /*doc:reg: this register selects the set for performing a fence operation */
    Reg#(Bit#(TLog#(sets))) rg_fence_set <- mkReg(0);
    /*doc:reg: this register when true indicates that a fence operation has caused a writeback to
     * the memory and the response has not been received yet.*/
    Reg#(Bool) rg_fence_pending <- mkReg(False);
    /*doc:reg: This register when true indicates that a there exists alteast one dirty line within
     * the data cache */
    Reg#(Bool) rg_globaldirty <- mkReg(False);
    /*doc:reg:*/
    Reg#(Bool) rg_fenceinit <- mkReg(True);
    // ------------------------------------------------------------------------------------------//

    // -------------------- Wire declarations ----------------------------------------------//
    /*doc:wire: boolean wire indicating if the cache is enabled. This is controlled through a csr*/
    Wire#(Bool) wr_cache_enable<-mkWire();

    /*doc:wire: this wire indicates if there was a hit or miss on SRAMs.*/
    Wire#(Bool) wr_fault <- mkDWire(False);
    /*doc:wire: this wire indicates if there was a hit or miss on SRAMs.*/
    Wire#(RespState) wr_ram_state <- mkDWire(None);
    /*doc:wire: this wire holds the response from the RAM in case of a hit in the RAMs*/
    Wire#(DMem_core_response#(respwidth,esize)) wr_ram_response <- mkDWire(?);
    /*doc:wire: in case of a hit in the ram, this wire holds the information of which way was a hit.
    This is used for replacement purposes only.*/
    Wire#(Bit#(TLog#(ways))) wr_ram_hitway <-mkDWire(0);
    /*doc:wire: in case of a store-hit in the RAM, the hit line needs to be transfered to the FB.
    This wire holds that hit line*/
    Wire#(Bit#(linewidth)) wr_ram_hitline <- mkDWire(?);
    /*doc:wire in case of a hit in the rams, the wire holds the holds the value of the set which
    caused a hit. This is necessary since an eviction from the same set should not affect the
    replacement policy if a hit to the same set has occurred in the same cycle */
    Wire#(Maybe#(Bit#(setbits))) wr_ram_hitset <- mkDWire(tagged Invalid);

    /*doc:wire: this wire indicates if there was a hit or miss on Fllbuffer.*/
    Wire#(RespState) wr_fb_state <- mkDWire(None);
    /*doc:wire: this wire holds the response data structure in case of a hit from fill-buffers*/
    Wire#(DMem_core_response#(respwidth,esize)) wr_fb_response <- mkDWire(?);

    /*doc:wire: this wire indicates if the current request is non-cacheable*/
    Wire#(RespState) wr_nc_state <- mkDWire(None);
    /*doc:wire: this wire holds the response data structure in case of a Non-cacheable access*/
    Wire#(DMem_core_response#(respwidth,esize)) wr_nc_response <- mkDWire(?);
  `ifdef perfmonitors
    /*doc:wire: wire to pulse on every read access*/
    Wire#(Bit#(1)) wr_total_read_access <- mkDWire(0);
    /*doc:wire: wire to pulse on every write access*/
    Wire#(Bit#(1)) wr_total_write_access <- mkDWire(0);
    /*doc:wire: wire to pulse on every atomic access*/
    Wire#(Bit#(1)) wr_total_atomic_access <- mkDWire(0);
    /*doc:wire: wire to pulse on every io read access*/
    Wire#(Bit#(1)) wr_total_io_reads <- mkDWire(0);
    /*doc:wire: wire to pulse on every io write access*/
    Wire#(Bit#(1)) wr_total_io_writes <- mkDWire(0);
    /*doc:wire: wire to pulse on every read miss within the cache*/
    Wire#(Bit#(1)) wr_total_read_miss <- mkDWire(0);
    /*doc:wire: wire to pulse on every write miss within the cache*/
    Wire#(Bit#(1)) wr_total_write_miss <- mkDWire(0);
    /*doc:wire: wire to pulse on every atomic miss within the cache*/
    Wire#(Bit#(1)) wr_total_atomic_miss <- mkDWire(0);
    /*doc:wire: wire to pulse on every eviction from the cache*/
    Wire#(Bit#(1)) wr_total_evictions <- mkDWire(0);
  `endif


    // ----------------------- Storage elements -------------------------------------------//
    /*doc:reg: This is an array of the valid bits. Each entry corresponds to a set and contains
    'way' number of bits in each entry*/
    Vector#(sets, Reg#(Bit#(ways))) v_reg_valid <- replicateM(mkReg(0));
    
    /*doc:reg: This is an array of the dirty bits. Each entry corresponds to a set and contains
    'way' number of bits in each entry*/
    Vector#(sets, Reg#(Bit#(ways))) v_reg_dirty <- replicateM(mkReg(0));
    
    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Ifc_mem_config1r1w#(sets, tagbits, tbanks) bram_tag [v_ways];

    /*doc:ram: This the data array which is dual ported has 'way' number of rams*/
    Ifc_mem_config1r1w#(sets, linewidth, dbanks) bram_data[v_ways];
    for (Integer i = 0; i<v_ways; i = i + 1) begin
      bram_tag[i]  <- mkmem_config1r1w(False, True);
      bram_data[i] <- mkmem_config1r1w(False, True);
    end
    Ifc_replace#(sets,ways) replacement <- mkreplace(alg);

    Ifc_storebuffer#(paddr, wordsize, esize, sbsize) storebuffer <- mk_storebuffer(id);

    // --------------------------- Rule operations ------------------------------------- //

    /*doc:rule: rule that fences the cache by invalidating all the lines*/
    rule rl_fence_operation(ff_core_request.first.fence && rg_fence_stall && !ff_pending_req.notEmpty ) ;
      `logLevel( dcache, 0, $format("[%2d]DCACHE: Fence: Operation in progress",id))

      let lv_curr_way = rg_fence_way;
      let lv_curr_set = rg_fence_set;
      
      let lv_next_way = rg_fence_way;
      let lv_next_set = rg_fence_set;

      // done to avoid additional provisos for this combination
      Bit#(TSub#(paddr, TAdd#(tagbits, setbits))) zeros = 'd0;

      Bit#(tagbits) tag = bram_tag[rg_fence_way].read_response;
      Bit#(linewidth) dataline = bram_data[rg_fence_way].read_response;
      Bit#(paddr) final_address={tag, rg_fence_set, zeros};
      Bit#(1) lv_dirty = v_reg_dirty[rg_fence_set][rg_fence_way];
      Bit#(1) lv_valid = v_reg_valid[rg_fence_set][rg_fence_way];
      if(rg_globaldirty)
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Fence: CurrWay:%2d CurrSet:%2d Valid:%b Dirty:%b \
 Addr:%h Data:%h",id, lv_curr_way,lv_curr_set,lv_valid, lv_dirty, final_address, dataline ))
      if( lv_dirty == 1 && lv_valid == 1)
        ff_write_mem_request.enq(DCache_mem_writereq{address   : final_address,
                                                burst_len  : fromInteger(valueOf(blocksize) - 1),
                                                burst_size : fromInteger(valueOf(TLog#(wordsize))),
                                                data       : dataline,
                                                io         : False});
      
      if(lv_curr_way == fromInteger(v_ways-1))
        lv_next_set = lv_curr_set + 1;

      if(v_ways > 1)
        lv_next_way = lv_curr_way + 1;

      bram_data[lv_next_way].read(lv_next_set);
      bram_tag[lv_next_way].read(lv_next_set);

      rg_fence_way <= lv_next_way;
      rg_fence_set <= lv_next_set;
      if((lv_curr_way == fromInteger(v_ways - 1) && lv_curr_set == fromInteger(v_sets - 1))
              || !rg_globaldirty) begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Fence: Clearing all Valid Bits",id))
        for (Integer i = 0; i< fromInteger(v_sets); i = i + 1) begin
          v_reg_valid[i] <= 0 ;
          v_reg_dirty[i] <= 0 ;
        end
        rg_globaldirty <= False;
        rg_fence_stall <= False;
        ff_core_request.deq;
        replacement.reset_repl;
        ff_core_response.enq(DMem_core_response{word:?, trap: False,
                              cause: ?, epochs: ff_core_request.first.epochs});
      end
    endrule

    /*doc:rule: This rule checks the tag rams for a hit*/
    rule rl_ram_check(!ff_core_request.first.fence && !rg_handling_miss);
      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(paddr) phyaddr = pa_response.address;
      Bool lv_access_fault = pa_response.trap;
      Bit#(`causesize) lv_cause = lv_access_fault? pa_response.cause:
                                  req.access == 0?`Load_access_fault:`Store_access_fault;
      `logLevel( dcache, 1, $format("[%2d]DCACHE: Response from PA:",id,fshow(pa_response)))
    `else
      Bit#(TSub#(vaddr,paddr)) upper_bits=truncateLSB(req.address);
      Bit#(paddr) phyaddr = truncate(req.address);
      Bool lv_access_fault = unpack(|upper_bits);
      Bit#(`causesize) lv_cause = req.access == 0?`Load_access_fault:`Store_access_fault;
    `endif

      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(tagbits) request_tag = phyaddr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];

      Vector#(ways, Bit#(respwidth)) dataword;
      Bit#(ways) hit_tag =0;
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        dataword[i] = truncate(bram_data[i].read_response >> block_offset);
        `logLevel( dcache, 0, $format("[%2d]DCACHE: RAM Lines[%2d]: tag:%h", id, i, 
                                     bram_tag[i].read_response, fshow(bram_data[i].read_response)))
      end
      Bit#(respwidth) response_word = ?;
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        if(v_reg_valid[set_index][i] == 1 && bram_tag[i].read_response == request_tag) begin
          hit_tag[i] = 1;
          response_word = dataword[i];
      end
      end
//      for (Integer i = 0; i< v_ways; i = i + 1) begin
//        hit_tag[i] = pack(v_reg_valid[set_index][i] == 1 && bram_tag[i].read_response == request_tag);
//      end
//      Bit#(respwidth) response_word=select(dataword, unpack(hit_tag));

      let lv_response = DMem_core_response{word:response_word, trap: lv_access_fault,
                                          cause: lv_cause, epochs: req.epochs};
      wr_ram_response <= lv_response;
      wr_ram_hitway<=truncate(pack(countZerosLSB(hit_tag)));
 //     wr_ram_hitline<=select(lines,unpack(hit_tag));

      if(lv_access_fault ) begin
        wr_fault <= True;
      end
      else if(|(hit_tag) == 1 ) begin// trap or hit in RAMs
        wr_ram_state <= Hit;
      end
      else begin // in case of miss from cache
        wr_ram_state <= Miss;
      end
    `ifdef ASSERT
      dynamicAssert(countOnes(hit_tag) <= 1,"DCACHE: More than one way is a hit in the RAM");
    `endif
      `logLevel( dcache, 0, $format("[%2d]DCACHE: RAM: reqTag:%h set_index:%d",id,request_tag, set_index))
      `logLevel( dcache, 0, $format("[%2d]DCACHE: RAM: Hit:%b For Req:",id,(hit_tag),fshow(req)))
      `logLevel( dcache, 0, $format("[%2d]DCACHE: RAM: Response:",id, fshow(lv_response)))
    endrule

    /*doc:rule: This rule will check if the requested word is present in the fill-buffer or not*/
    rule rl_fillbuffer_check(!ff_core_request.first.fence);
      let req = ff_core_request.first;
    `ifdef supervisor
      Bit#(paddr) phyaddr = ff_from_tlb.first.address;
    `else
      Bit#(paddr) phyaddr = truncate(req.address);
    `endif
      let lv_io_req = isNonCacheable(phyaddr, wr_cache_enable);
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(blockbits) word_index= truncate(phyaddr>>v_wordbits);
      Bit#(respwidth) response_word=truncate(rg_fb_linedata >> block_offset);
      let required_enable = fn_enable(word_index);
      Bit#(`causesize) lv_cause = req.access == 0? `Load_access_fault: `Store_access_fault;
      let lv_response = DMem_core_response{word:response_word, trap: rg_fb_err,
                                          cause: lv_cause, epochs: req.epochs};
      `logLevel( dcache, 1, $format("[%2d]DCACHE: FB processing Req: ",id,fshow(req)))
      Bit#(TSub#(paddr, TAdd#(wordbits,blockbits))) lv_fb_addr = truncateLSB(ff_pending_req.first.phyaddr);
      Bit#(TSub#(paddr, TAdd#(wordbits,blockbits))) lv_req_addr = truncateLSB(phyaddr);
      if(lv_io_req && req.access != 0) begin
        wr_fb_state <= Hit;
        `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Detected NC Write",id))
      end
      else if(lv_req_addr == lv_fb_addr && ff_pending_req.notEmpty)begin
        `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Hit in FB Line for Addr:%h",id,phyaddr))
        if((required_enable & rg_fb_enable) !=0)begin
          wr_fb_state <= Hit;
          wr_fb_response <= lv_response;
          `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Required Word found in FB",id))
        end
        else begin
          wr_fb_state <= None;
          `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Required word not available in the FB yet",id))
        end
      end
      else begin
        wr_fb_state <= Miss;
        `logLevel( dcache, 1, $format("[%2d]DCACHE: FB: Miss in FB also",id))
      end

    endrule

    /*doc:rule: this rule fires when the requested word is either present in the SRAMs or the
     fill-buffer or if there was an error in the request */
    rule rl_response_to_core(!ff_core_request.first.fence && (
                                wr_nc_state == Hit || wr_ram_state == Hit || wr_fb_state == Hit));
      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(paddr) phyaddr = pa_response.address;
      ff_from_tlb.deq;
    `else
      Bit#(paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      DMem_core_response#(respwidth,esize) lv_response;

      let {storemask, storedata} <- storebuffer.mav_check_sb_hit(phyaddr);

      Bit#(3) onehot_hit = {pack(wr_ram_state==Hit || wr_fault), 
                            pack(wr_fb_state==Hit && !wr_fault), 
                            pack(wr_nc_state==Hit && !wr_fault)};
    `ifdef ASSERT
      if(!wr_fault)
        dynamicAssert(countOnes(onehot_hit) == 1, "More than one data structure shows a hit");
    `endif
      Vector#(3, DMem_core_response#(respwidth,esize)) lv_responses;
      lv_responses[0] = wr_nc_response;
      lv_responses[1] = wr_fb_response;
      lv_responses[2] = wr_ram_response;

      lv_response = select(lv_responses,unpack(onehot_hit));

      if(wr_ram_state == Hit && !wr_fault) begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Response: Hit from SRAM",id))
        if(alg == 2) begin
          replacement.update_set(set_index, wr_ram_hitway);//wr_replace_line); 
          wr_ram_hitset <= tagged Valid set_index;
        end
      end
      if(wr_fb_state == Hit && !wr_fault) begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Response: Hit from Fillbuffer",id))
      end
      if(wr_nc_state == Hit && !wr_fault) begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Response: Hit from NC",id))
      end

      lv_response.word = (storemask & storedata) | (~storemask & lv_response.word);

      // capture the sign bit of the response to the core
      Bit#(1) lv_sign =case(req.size[1:0])
          'b00: lv_response.word[7];
          'b01: lv_response.word[15];
          default: lv_response.word[31];
        endcase;
      // manipulate the sign based on the request of the core
      lv_sign = lv_sign & ~req.size[2];

      // generate a mask based on the request of the core.
      Bit#(respwidth) mask = case(req.size[1:0])
        'b00: 'hFF;
        'b01: 'hFFFF;
        'b10: 'hFFFFFFFF;
        default: '1;
      endcase;

      // signmask basically has all bits which are zeros in the mask duplicated with the required
      // sign bit. Theese need to be set in the final response to the core and will thus be ORed
      Bit#(respwidth) signmask = ~mask & duplicate(lv_sign);
      lv_response.word = (lv_response.word & mask) | signmask;
      lv_response.word = lv_response.trap?truncateLSB(req.address):lv_response.word;

      ff_core_request.deq;
    `ifdef supervisor
      if(pa_response.tlbmiss)
        ff_hold_request.enq(ff_core_request.first());
      else if(req.ptwalk_req && !pa_response.tlbmiss)
        ff_ptw_response.enq(lv_response);
      else
    `endif
      ff_core_response.enq(lv_response);
      rg_handling_miss <= False;
    `ifdef supervisor
      if(!pa_response.tlbmiss)
    `endif
      `logLevel( dcache, 0, $format("[%2d]DCACHE: Responding to Core:",id, fshow(lv_response)))
//      if(req.access!=0 && !lv_response.trap `ifdef supervisor && !pa_response.tlbmiss `endif )begin
//        Bit#(TLog#(fbsize)) fbindex = (wr_fb_state == Hit && !wr_fault)? wr_fb_hitindex:rg_fbhead;
//        `ifdef atomic
//          if(req.access == 2)
//            req.data = fn_atomic_op(req.atomic_op, req.data, lv_response.word);
//        `endif
//        storebuffer.ma_allocate_entry(phyaddr,req.data, req.epochs, fbindex, truncate(req.size),
//          isNonCacheable(phyaddr, wr_cache_enable));
//        `logLevel( dcache, 0, $format("[%2d]DCACHE: Response: Allocating Store Buffer",id))
//        wr_allocating_storebuffer <= True;
//      end
    endrule

    /*doc:rule: This rule fires when the requested word is a miss in both the SRAMs and the
     * Fill-buffer. This rule thereby forwards the requests to the network. IOs by default should
     * be a miss in both the SRAMs and the FB and thus need to be checked only here */
    rule rl_send_memory_request(wr_ram_state == Miss && wr_fb_state == Miss && ff_pending_req.notFull);
      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(paddr) phyaddr = pa_response.address;
    `else
      Bit#(paddr) phyaddr = truncate(req.address);
    `endif
      let lv_busbits = valueOf(TLog#(TDiv#(buswidth,8))); // 4
      Bit#(TLog#(TDiv#(linewidth,buswidth))) word_index= truncate(phyaddr>>lv_busbits);
      let lv_io_req = isNonCacheable(phyaddr, wr_cache_enable);
      let burst_len = lv_io_req?0:(v_blocksize/valueOf(TDiv#(buswidth,respwidth)))-1;
      let burst_size = lv_io_req?v_wordbits:valueOf(TLog#(TDiv#(buswidth,8)));
      let shift_amount = valueOf(TLog#(TDiv#(buswidth,8)));
      let pend_req = Pending_req{phyaddr: phyaddr, init_enable:fn_init_enable(word_index), 
                                io_request: lv_io_req};
      phyaddr= lv_io_req?phyaddr:(phyaddr>>shift_amount)<<shift_amount; // align the address to be one word aligned.
      ff_pending_req.enq(pend_req);
      ff_read_mem_request.enq(DCache_mem_readreq{  address   : phyaddr,
                                                  burst_len  : fromInteger(burst_len),
                                                  burst_size : fromInteger(burst_size),
                                                  io         : lv_io_req});
      if(lv_io_req) begin
        `logLevel( dcache, 0, $format("[%2d]DCACHE: MemReq: Sending NC Request for Addr:%h",id,phyaddr))
      `ifdef perfmonitors
        if(req.access == 0)
          wr_total_io_reads <= 1;
        if(req.access == 1)
          wr_total_io_writes <= 1;
      `endif
      end
      else begin
      `ifdef perfmonitors
        if(req.access == 0)
          wr_total_read_miss <= 1;
        if(req.access == 1)
          wr_total_write_miss <= 1;
        `ifdef atomic
          if(req.access == 2)
            wr_total_atomic_miss <= 1;
        `endif
      `endif
        `logLevel( dcache, 0, $format("[%2d]DCACHE : MemReq: Sending Line Request for Addr:%h",id, phyaddr))
      end
      rg_handling_miss <= True;
    endrule

    /*doc:rule: this rule will fill up the FB with the response from the memory, Once the last word
    * has been received the entire line and tag are written in to the BRAM and the fill buffer is
    * released in the next cycle*/
    rule rl_fill_from_memory(!rg_fb_release && ff_pending_req.notEmpty &&
                                                                  !ff_pending_req.first.io_request);
      let pending_req = ff_pending_req.first;
      let response = ff_read_mem_response.first;
      `logLevel( dcache, 0, $format("[%2d]DCACHE: FILL: Processing:",id,fshow(pending_req)))
      ff_read_mem_response.deq;
      Bit#(setbits) set_index=pending_req.phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(TDiv#(linewidth,8)) lv_current_enable = rg_fb_enable == 0? pending_req.init_enable:
                                                                    rg_fb_enable_temp;
      Bit#(linewidth) lv_new_word = duplicate(response.data);
      Bit#(tagbits) lv_write_tag = truncateLSB(pending_req.phyaddr);
      Bit#(TAdd#(TLog#(TDiv#(linewidth,8)),1)) rotate_amount =
                                                (fromInteger(valueOf(TDiv#(buswidth,8))));

      let lv_fb_linedata = updateDataWithMask(rg_fb_linedata, lv_new_word, lv_current_enable);
      if(response.last) begin
        let waynum<-replacement.line_replace(set_index, v_reg_valid[set_index],
                                                                          v_reg_dirty[set_index]);
        replacement.update_set(set_index,waynum);
        rg_fb_release <= True;
        rg_release_way <= waynum;
        bram_tag[waynum].write(1,set_index,lv_write_tag);
        bram_data[waynum].write(1,set_index,lv_fb_linedata);
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Writing set:%d tag:%h way:%d",id,
                                                                    set_index,lv_write_tag,waynum))
        `logLevel( dcache, 0, $format("[%2d]DCACHE: Writing data:%h",id,lv_fb_linedata))
      end
      else begin
        rg_fb_enable_temp <= rotateBitsBy(lv_current_enable,unpack(truncate(rotate_amount)));
      end
      rg_fb_enable <= rg_fb_enable | lv_current_enable;
      rg_fb_linedata <=  lv_fb_linedata;
      rg_fb_err <= response.err;
      `logLevel( dcache, 0, $format("[%2d]DCACHE: FILL: current_enable:%h",id,lv_current_enable))
      `logLevel( dcache, 0, $format("[%2d]DCACHE: FILL: Response from Memory:",id,fshow(response)))
    endrule

    /*doc:rule: this rule is responsible for capturing the memory response for an IO request.*/
    rule rl_capture_io_response(ff_pending_req.notEmpty && ff_pending_req.first.io_request);
      let response = ff_read_mem_response.first;
      let req = ff_core_request.first;
      Bit#(`causesize) lv_cause = req.access == 0? `Load_access_fault: `Store_access_fault;
      let lv_response = DMem_core_response{word:truncate(response.data), trap: response.err,
                                          cause: lv_cause, epochs: req.epochs};
      wr_nc_response <= lv_response;
      wr_nc_state <= Hit;
      ff_read_mem_response.deq;
      ff_pending_req.deq;
      `logLevel( dcache, 2, $format("[%2d]DCACHE: IO Response from Memory: ",id,fshow(response)))
    endrule

    /*doc:rule: hold the fillbuffer for an extra cycle since the write to the BRAM is only available
    * in the next cycle. This rule will also re-initialize all the fb related registers*/
    rule rl_delay_fb_release(rg_fb_release && !ff_pending_req.first.io_request &&
                                                                          ff_pending_req.notEmpty);
      rg_fb_enable <= 0;
      rg_fb_enable_temp <= 0;
      rg_fb_linedata <= 0;
      rg_fb_err <= False;
      ff_pending_req.deq;
      Bit#(setbits) set_index=ff_pending_req.first.phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      v_reg_valid[set_index][rg_release_way]<= 1'b1;
      `logLevel( dcache, 1, $format("[%2d]DCACHE: Releasing FB. Addr:",id,fshow(ff_pending_req.first)))
    endrule

    interface put_core_req=interface Put
      method Action put(DCache_core_request#(vaddr,respwidth,esize) req)if( ff_core_response.notFull &&
                            !rg_fence_stall);
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
        Bit#(paddr) phyaddr = truncate(req.address);
        Bit#(setbits) set_index=req.fence?0:phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=req.fence;
        for(Integer i=0;i<v_ways;i=i+1)begin
          bram_data[i].read(set_index);
          bram_tag[i].read(set_index);
        end
        `logLevel( dcache, 0, $format("[%2d]DCACHE : Receiving request: ",id,fshow(req)))
        `logLevel( dcache, 0, $format("[%2d]DCACHE : set:%d",id,set_index))
      endmethod
    endinterface;
    method Action ma_cache_enable(Bool c);
      wr_cache_enable <= c;
    endmethod

    interface get_read_mem_req = toGet(ff_read_mem_request);
    interface put_read_mem_resp = toPut(ff_read_mem_response);
    interface get_core_resp = toGet(ff_core_response);
    method mv_write_mem_req = ff_write_mem_request.first;
    method Action ma_write_mem_req_deq;
      ff_write_mem_request.deq;
    endmethod
    interface put_write_mem_resp = toPut(ff_write_mem_response);
  `ifdef supervisor
    interface get_ptw_resp = toGet(ff_ptw_response);
    interface put_pa_from_tlb = toPut(ff_from_tlb);
    interface get_hold_req = toGet(ff_hold_request);
  `endif
    `ifdef perfmonitors
      method mv_perf_counters = {wr_total_read_access , wr_total_write_access , wr_total_atomic_access 
                            , wr_total_io_reads , wr_total_io_writes , wr_total_read_miss , 
                              wr_total_write_miss , wr_total_atomic_miss , 4'b0, wr_total_evictions };
    `endif
    //TODO
    method mv_storebuffer_empty = storebuffer.mv_sb_empty;
    method mv_cacheable_store = storebuffer.mv_cacheable_store;
    method mv_cache_available = ff_core_response.notFull && ff_core_request.notFull;
    method mv_commit_store_ready = ff_write_mem_request.notFull;
  endmodule
endpackage

