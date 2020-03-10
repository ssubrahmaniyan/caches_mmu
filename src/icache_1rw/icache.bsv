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

--------------------------------------------------------------------------------------------------
*/
/*doc:overview:

Working Principle
-----------------

A request from the core is enqueued into a request fifo (``ff_core_request``). On a hit within the 
cache, the required word is enqueued into the response fifo (``ff_core_response``) which is read by 
the core. On a miss, a read request for the line is sent to the fabric via the 
``ff_read_mem_request`` and simultaneously an entry in the fill-buffer is allotted to capture the 
fabric response. The responses from the fabric are enqueued in the ``ff_read_mem_response`` fifo. 

Serving core requests
^^^^^^^^^^^^^^^^^^^^^

A core request can only be enqueued in ``ff_core_request`` fifo if the following conditions are true :- 

1. Fill-buffer is not full.
2. Core is ready to receive a response or deq the previous response
3. Fence operation is not in progress.
4. A replay of SRAM tag and data request (for a previous request) is not happening 
   (its necessity is discussed in later sections).

The reason for point 1 and 2 being, once either of the two structures are full, a hit or a miss 
cannot be processed further. In this situation, if there is one outstanding request already 
present in ``ff_core_request``, enqueuing one more request would overwrite the SRAM tag and data 
values of the previous one. When tag matching resumes, incorrect tag would be used leading to 
incorrect behaviour.

Once a request is enqueued into the ``ff_core_request`` fifo, a tag and data read request is sent to 
the SRAMs simultaneously. In the next cycle, if there isn't a pending request and fill-buffer & 
ff_core_response are not full, the tag field of the request is compared with the tags stored in 
the SRAMs (tag field of all the ways for particular set) and the fill-buffer 
(tag field of all the entries). 

A hit occurs in following scenarios :- 1. Tag matches in SRAM 2. Tag matches in fill-buffer and 
also the requested word is present. There might be a case where tag matches in fill-buffer but the 
word is not present as the line is still getting filled by the fabric. In that case we keep 
polling on the fill-buffer until there's a **word-hit**. Please note, that a tag-hit can occur 
either in the SRAM or the fill-buffer and never both. Assertions to check this have been put in 
place. A miss occurs when tag match fails in both the SRAM and the fill-buffer. Now following 
scenarios can occur :-

1. **For a Read request**: if it's a hit, the requested word is enqueued in ``ff_core_response`` 
   fifo in the same cycle as the tag-match.

2. **For a Read request**: If it's a miss, the address (after making it word aligned) is 
   enqueued into the ``ff_read_mem_request`` fifo to be sent to fabric. Simultaneously, a 
   fill-buffer entry is assigned to capture the line requested from the fabric. Once the 
   requested word is captured in the fill-buffer (while rest of the line is still getting filled), 
   it is enqueued into the ``ff_core_response`` to be sent to core and the entry in ``ff_core_request`` 
   is dequeued. We are now ready to service the subsequent request in the next cycle.

Release from fill-buffer
^^^^^^^^^^^^^^^^^^^^^^^^

The necessary condition for a release of a line from fill-buffer and its updation into SRAM is 
that the line itself is valid and all the words in the line are present. 

1. **Fill-buffer is full**. A release is necessary in this case since no more requests can be 
   taken and it can stall the pipe. While the release happens, suppose there is an entry already 
   present in the request fifo which is to the line being released. The tag and data for that 
   entry have already been read and would be used to check hit/miss. The SRAM tag matching would 
   take place with a stale value and would result in a miss. It would also be a miss in fill-buffer 
   since the line would already have been released. To prevent this incorrect behaviour, we need to 
   replay the SRAM tag and data requests (now it would be a hit in SRAM).

2. **Opportunistic fill**: if the fill-buffer is not full but there is no request being enqueued 
   in a particular cycle (this does not mean ``ff_core_request`` is empty). Given this, if there is 
   an entry in ``ff_core_request`` to the line being released, we prevent the release for not 
   wanting to replay the SRAM read request (described in point 1).

We can directly put a write request (of the line being released) to the SRAM along with updation 
of the SRAM valid bits accordingly.
Once a release is done from the fill-buffer, that particular entry in the fill-buffer is 
invalidated and thus is available for new allocation on a miss.

The fill-buffer is implemented as a circular-buffer with head and tail pointer-registers.

Fence operation
^^^^^^^^^^^^^^^

A cache-flush operation is initiated when the core presents a fence instruction. A fence operation 
can only start if following conditions are met:

1. the entire fill-buffer is empty (i.e. all lines are updated in the SRAM).

Here the fence is a single-cycle operation which resets all the valid bits to 0 (which are
implemented as registers) and also resets the replacement policies.

--------------------------------------------------------------------------------------------------
*/
package icache;
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


  `include "icache.defines"
  import icache_types :: * ;
  import common_tlb_types :: * ;
  import replacement:: * ;
  import mem_config :: * ;

  typedef struct{
    Bit#(addr)  phyaddr;
    Bit#(besize) init_enable;
    Bit#(TLog#(fbsize)) fbindex;
    Bool io_request;
  } Pending_req#(numeric type addr, numeric type besize, numeric type fbsize) 
                deriving(Bits, Eq, FShow);

  interface Ifc_icache#(numeric type wordsize,
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
    interface Put#(ICache_core_request#(vaddr,esize)) put_core_req;
    interface Get#(IMem_core_response#(TMul#(wordsize,8),esize)) get_core_resp;
    interface Get#(ICache_mem_readreq#(paddr)) get_read_mem_req;
    interface Put#(ICache_mem_readresp#(buswidth)) put_read_mem_resp;
  `ifdef supervisor
    interface Put#(ITLB_core_response#(paddr)) put_pa_from_tlb;
  `endif
  `ifdef perfmonitors
    method Bit#(5) mv_perf_counters;
  `endif
    method Action ma_cache_enable(Bool c);
    method Bool mv_cache_available;
  endinterface


  /*doc:module: */
  // both update rg_handling_miss but can never fire together
  (*conflict_free="rl_send_memory_request, rl_response_to_core"*)
  // both update different entries of fb
  (*conflict_free="rl_send_memory_request, rl_fill_from_memory"*) 
  // both update fb buffer entries, however both can never fire simultaneously
  (*conflict_free="rl_send_memory_request, rl_release_from_fillbuffer"*)
  //both of these update fillbuffer entries but can never fire simultaneously
  (*conflict_free="rl_response_to_core,rl_fill_from_memory"*)
  (*conflict_free="rl_response_to_core,rl_release_from_fillbuffer"*)
  module mkicache#(function Bool isNonCacheable(Bit#(paddr) addr, Bool cacheable), 
                  parameter Integer alg, parameter Bit#(32) id)
                  (Ifc_icache#(wordsize, blocksize, sets, ways, paddr, vaddr, fbsize,
                                esize, dbanks, tbanks, buswidth))
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
          Add#(TAdd#(tagbits, setbits), y__, paddr),
          Mul#(TMul#(wordsize, 8), z__, linewidth),
          Mul#(aa__, 8, linewidth),
          Add#(ab__, TLog#(fbsize), TLog#(TAdd#(1, fbsize))),
           Div#(linewidth, 8, aa__),
        `ifdef ASSERT
          Add#(1, n__, TLog#(TAdd#(1, ways))),
        `endif

          // for using mem_config
          Mul#(TDiv#(tagbits, tbanks), tbanks, tagbits),
          Add#(h__, TDiv#(tagbits, tbanks), tagbits),
          Mul#(TDiv#(linewidth, dbanks), dbanks, linewidth),
          Add#(i__, TDiv#(linewidth, dbanks), linewidth),
          Add#(q__, TDiv#(linewidth, buswidth), paddr)

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
    let v_respwidth=valueOf(respwidth);
    let v_fbsize = valueOf(fbsize);
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
  
    function Bool isTrue(Bool a);
      return a;
    endfunction

    /*doc:func: This function generates the byte-enable for a data-line sized vector based on the
    request made by the core */
    function Bit#(TDiv#(linewidth,8)) fn_enable(Bit#(blockbits) word_index);
      Bit#(TDiv#(linewidth,8)) write_enable = 'hF << ({4'b0,word_index}*fromInteger(lv_offset));
      return write_enable;
    endfunction
    
    /*doc:func: This function generates the byte-enable for a data-line sized vector based on the
    request made by the core */
    function Bit#(TDiv#(linewidth,8)) fn_init_enable(Bit#(TLog#(TDiv#(linewidth,buswidth))) word_index);
      Bit#(TDiv#(linewidth,8)) we = case(valueOf(buswidth))
        32: 'hF;
        64:'hFF;
        default:'hFFFF;
      endcase;
      Bit#(TDiv#(linewidth,8)) write_enable = we << ({4'b0,word_index}*fromInteger(lv_offset1));
      return write_enable;
    endfunction

    // ----------------------- FIFOs to interact with interface of the design -------------------//
    /*doc:fifo: This fifo stores the request from the core.*/
    FIFOF#(ICache_core_request#(vaddr, esize)) ff_core_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response that needs to be sent back to the core.*/
    FIFOF#(IMem_core_response#(respwidth,esize))ff_core_response <- mkBypassFIFOF();
    /*doc:fifo: this fifo stores the read request that needs to be sent to the next memory level.*/
    FIFOF#(ICache_mem_readreq#(paddr)) ff_read_mem_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response from the next level memory.*/
    FIFOF#(ICache_mem_readresp#(buswidth)) ff_read_mem_response  <- mkBypassFIFOF();

  `ifdef supervisor 
    /*doc:fifo: this fifo receives the physical address from the TLB */
    FIFOF#(ITLB_core_response#(paddr)) ff_from_tlb <- mkBypassFIFOF();
  `endif

    // ------------------------ FIFOs for internal state-maintenance ---------------------------//
    /*doc:fifo: This fifo holds meta information of the miss/io request that was made by the core*/
    FIFOF#(Pending_req#(paddr, TDiv#(linewidth,8),fbsize)) ff_pending_req <- mkUGSizedFIFOF(2);

    // -------------------- Register declarations ----------------------------------------------//

    /*doc:reg: register when True indicates a fence is in progress and thus will prevent taking any
     new requests from the core*/
    Reg#(Bool) rg_fence_stall <- mkReg(False);

    /*doc:reg: When tru indicates that a miss is being catered to*/
    Reg#(Bool) rg_handling_miss <- mkReg(False);

    //------------------------- Fill buffer data structures -------------------------------------//
   
    /*doc: vec: vector of registers to maintain the valid bit for fill-buffers*/
    Vector#(fbsize,Reg#(Bool))                      v_fb_valid    <- replicateM(mkReg(False));
    /*doc: vec: vector of registers to hold the dataline for fill-buffers.*/
    Vector#(fbsize,Reg#(Bit#(linewidth)))           v_fb_data     <- replicateM(mkReg(unpack(0)));
    /*doc: vec: vector of registers to indicate that the line fill faced a bus-error*/
    Vector#(fbsize,Reg#(Bit#(1)))                   v_fb_err      <- replicateM(mkReg(0));
    /*doc: vec: vector of regisetrs to indicate how many bytes of the line have been filled by the
     bus*/
    Vector#(fbsize,Reg#(Bit#(TDiv#(linewidth,8))))  v_fb_enables  <- replicateM(mkReg(0));
    /*doc: vec: vector registers indicating the address of the fill-buffer line*/
    Vector#(fbsize,Reg#(Bit#(paddr)))               v_fb_addr     <- replicateM(mkReg(0));

    /*doc:reg: register pointing to next entry being allotted on the filbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbhead     <- mkReg(0);
    /*doc:reg: register pointing to the next entry being released from the fillbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbtail     <- mkReg(0);
    /*doc:reg: temporary register holding the WE for the data to be updated in the fillbuffer from
    the memory response*/
    Reg#(Bit#(TDiv#(linewidth,8)))                  rg_temp_enable<- mkReg(0);
    /*doc:reg: this register indicates the read-phase of the release sequence*/
    Reg#(Bool) rg_release_readphase <- mkDReg(False);

    /*doc:reg: This register indicates that the bram inputs are being re-driven by those provided
    from the core in the most recent request. This can happen because there has been a replacement
    of a line to a set which is also being accessed by the core. Thus the core request needs to be
    replayed on these again */
    Reg#(Bool) rg_performing_replay <- mkReg(False);
    /*doc:reg: this register holds the index of the most recent request performed by the core*/
    Reg#(Bit#(setbits)) rg_recent_req <- mkReg(0);
    /*doc:reg: this register indicates that the line corresponding to the current request to the
    core is already persent however, the necessary is not present. This doesn't generate a miss
    and thus rg_miss_handling cannot be used here. Hence the need for this register*/
    Reg#(Bool) rg_polling_mode <- mkReg(False);
    
    Bit#(tagbits) writetag = truncateLSB(v_fb_addr[rg_fbtail]);
    Bit#(linewidth) writedata = v_fb_data[rg_fbtail];
    
    /*doc:var: variable indicating the fillbuffer is full*/
    Bool fb_full = (all(isTrue, readVReg(v_fb_valid)));
    /*doc:var: variable indicating the fillbuffer is empty*/
    Bool fb_empty=!(any(isTrue, readVReg(v_fb_valid)));
    // ------------------------------------------------------------------------------------------//

    // -------- oppurtunistic filling related structures --------------------------------------//
    /*doc:wire: this is a boolean wire which indicates is a req is being taken by the cache from the
    core */
    Wire#(Bool) wr_takingrequest <- mkDWire(False);
    Bit#(TLog#(sets)) fillindex = v_fb_addr[rg_fbtail][v_setbits + v_blockbits + v_wordbits - 1:
                                                                          v_blockbits + v_wordbits];
    Bool fill_oppurtunity = (!ff_core_request.notEmpty && !wr_takingrequest) && !fb_empty &&
         /*countOnes(fb_valid)>0 &&*/ (fillindex != rg_recent_req);
    // ------------------------------------------------------------------------------------------//
    

    // -------------------- Wire declarations ----------------------------------------------//
    /*doc:wire: boolean wire indicating if the cache is enabled. This is controlled through a csr*/
    Wire#(Bool) wr_cache_enable<-mkWire();

    /*doc:wire: this wire indicates if there was a fault in the address or during translation*/
    Wire#(Bool) wr_fault <- mkDWire(False);
    /*doc:wire: this wire indicates if there was a hit or miss on SRAMs.*/
    Wire#(RespState) wr_ram_state <- mkDWire(None);
    /*doc:wire: this wire holds the response from the RAM in case of a hit in the RAMs*/
    Wire#(IMem_core_response#(respwidth,esize)) wr_ram_response <- mkDWire(?);
    /*doc:wire: in case of a hit in the ram, this wire holds the information of which way was a hit.
    This is used for replacement purposes only.*/
    Wire#(Bit#(TLog#(ways))) wr_ram_hitway <-mkDWire(0);
    /*doc:wire in case of a hit in the rams, the wire holds the holds the value of the set which
    caused a hit. This is necessary since an eviction from the same set should not affect the
    replacement policy if a hit to the same set has occurred in the same cycle */
    Wire#(Maybe#(Bit#(setbits))) wr_ram_hitset <- mkDWire(tagged Invalid);

    /*doc:wire: this wire indicates if there was a hit or miss on Fllbuffer.*/
    Wire#(RespState) wr_fb_state <- mkDWire(None);
    /*doc:wire: this wire holds the response data structure in case of a hit from fill-buffers*/
    Wire#(IMem_core_response#(respwidth,esize)) wr_fb_response <- mkDWire(?);

    /*doc:wire: this wire indicates if the current request is non-cacheable*/
    Wire#(RespState) wr_nc_state <- mkDWire(None);
    /*doc:wire: this wire holds the response data structure in case of a Non-cacheable access*/
    Wire#(IMem_core_response#(respwidth,esize)) wr_nc_response <- mkDWire(?);
  `ifdef perfmonitors
    /*doc:wire: pulse on every request made by the core*/
    Wire#(Bit#(1)) wr_total_access <- mkDWire(0);
    /*doc:wire: pulse on every miss in the cache*/
    Wire#(Bit#(1)) wr_total_cache_misses <- mkDWire(0);
    /*doc:wire: pulse everytime there is a hit from the fill-buffer*/
    Wire#(Bit#(1)) wr_total_fb_hits <- mkDWire(0);
    /*doc:wire: pulse everytime there is a non-cacheable access*/
    Wire#(Bit#(1)) wr_total_nc <- mkDWire(0);
    /*doc:wire: pulse everytime there is a fill from the fill-buffer to the RAMs*/
    Wire#(Bit#(1)) wr_total_fbfills <- mkDWire(0);
  `endif
    // ----------------------- Storage elements -------------------------------------------//
    /*doc:reg: This is an array of the valid bits. Each entry corresponds to a set and contains
     'way' number of bits in each entry*/
    Vector#(sets, Reg#(Bit#(ways))) v_reg_valid <- replicateM(mkReg(0));
    
    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Ifc_mem_config1rw#(sets, tagbits, tbanks) bram_tag [v_ways];

    /*doc:ram: This the data array which is dual ported has 'way' number of rams*/
    Ifc_mem_config1rw#(sets, linewidth, dbanks) bram_data[v_ways];
    for (Integer i = 0; i<v_ways; i = i + 1) begin
      bram_tag[i]  <- mkmem_config1rw(False);
      bram_data[i] <- mkmem_config1rw(False);
    end
    Ifc_replace#(sets,ways) replacement <- mkreplace(alg);

    // --------------------------- Rule operations ------------------------------------- //

    /*doc:rule: */
    rule rl_print_stats;
      `logLevel( icache, 2, $format("[%2d]ICACHE: fb_full:%b fb_empty:%b fbhead:%d fbtail:%d FEB:%b",
      id, fb_full, fb_empty, rg_fbhead, rg_fbtail, &(v_fb_enables[rg_fbtail])))
    endrule
    /*doc:rule: rule that fences the cache by invalidating all the lines*/
    rule rl_fence_operation(ff_core_request.first.fence && rg_fence_stall && fb_empty &&
                                      !rg_performing_replay) ;
      `logLevel( icache, 0, $format("[%2d]ICACHE : Fence operation in progress",id))

      for (Integer i = 0; i< fromInteger(v_sets); i = i + 1) begin
        v_reg_valid[i] <= 0 ;
      end
      rg_fence_stall <= False;
      ff_core_request.deq;
      replacement.reset_repl;
    endrule

    /*doc:rule: This rule checks the tag rams for a hit*/
    rule rl_ram_check(!ff_core_request.first.fence && !rg_handling_miss && !rg_performing_replay
                      && !rg_polling_mode && !fb_full);
      let req = ff_core_request.first;
      // select the physical address and check for any faults
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(paddr) phyaddr = pa_response.address;
      Bool lv_access_fault = pa_response.trap;
      Bit#(`causesize) lv_cause = lv_access_fault? pa_response.cause:`Inst_access_fault;
    `else
      Bit#(TSub#(vaddr,paddr)) upper_bits=truncateLSB(req.address);
      Bit#(paddr) phyaddr = truncate(req.address);
      Bool lv_access_fault = unpack(|upper_bits);
      Bit#(`causesize) lv_cause = `Inst_access_fault;
    `endif
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(tagbits) request_tag = phyaddr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      
      Vector#(ways, Bit#(respwidth)) dataword;
      Vector#(ways, Bit#(linewidth)) lines;
      Bit#(ways) hit_tag =0;
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        dataword[i] = truncate(bram_data[i].read_response >> block_offset);
        lines[i] = bram_data[i].read_response;
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

      let lv_response = IMem_core_response{word:lv_access_fault? truncate(req.address):response_word, 
                                          trap: lv_access_fault, cause: lv_cause, epochs: req.epochs};
      wr_ram_response <= lv_response;
      wr_ram_hitway<=truncate(pack(countZerosLSB(hit_tag)));

      if(lv_access_fault) begin
        wr_fault <= True;
      end
      else if(|(hit_tag) == 1 ) begin// trap or hit in RAMs
        wr_ram_state <= Hit;
      end
      else begin // in case of miss from cache
        wr_ram_state <= Miss;
      end

    `ifdef ASSERT
      dynamicAssert(countOnes(hit_tag) <= 1,"ICACHE: More than one way is a hit in the cache");
    `endif
      `logLevel( icache, 0, $format("[%2d]ICACHE: RAM For Req:",id,(hit_tag),fshow(req)))
      `logLevel( icache, 0, $format("[%2d]ICACHE: RAM Hit:%b set:%d tag:%h",id,hit_tag,set_index,
                                    request_tag))
      `logLevel( icache, 0, $format("[%2d]ICACHE: RAM Response:",id, fshow(lv_response)))
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
      
      Bit#(TAdd#(tagbits, setbits)) input_tag = truncateLSB(phyaddr);

      Bit#(blockbits) word_index = truncate(phyaddr >> v_wordbits);
      let required_enable = fn_enable(word_index);
      Bit#(`causesize) lv_cause = `Inst_access_fault;
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset =
                                                      {phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      
      Vector#(fbsize, Bit#(respwidth)) lv_respwords;
      Bit#(fbsize) lv_hit = 0;
      for (Integer i = 0; i<v_fbsize; i = i + 1) begin
        lv_respwords[i] = truncate(v_fb_data[i] >> block_offset);
      end
      Bit#(respwidth) lv_response_word = ?;
      Bit#(1) lv_response_err = 0;
      Bit#(TDiv#(linewidth,8)) lv_fb_enable = ?;
      for (Integer i = 0; i<v_fbsize; i = i + 1) begin
        if((truncateLSB(v_fb_addr[i]) == input_tag) && v_fb_valid[i])begin
          lv_hit[i] = 1;
          lv_response_err = v_fb_err[i];
          lv_response_word = lv_respwords[i];
          lv_fb_enable = v_fb_enables[i];
        end
      end
      //for (Integer i = 0; i<v_fbsize; i = i + 1) begin
      //  lv_hit[i] = pack((truncateLSB(v_fb_addr[i]) == input_tag) && v_fb_valid[i]);
      //end
      //Bit#(respwidth) lv_response_word = select(lv_respwords, unpack(lv_hit));
      //Bit#(1) lv_response_err = select(readVReg(v_fb_err),unpack(lv_hit));
      //Bit#(TDiv#(linewidth,8)) lv_fb_enable = select(readVReg(v_fb_enables),unpack(lv_hit));
      let lv_response = IMem_core_response{word:lv_response_word, trap: unpack(lv_response_err),
                                          cause: lv_cause, epochs: req.epochs};
      `logLevel( icache, 1, $format("[%2d]ICACHE: FB: processing Req: ",id,fshow(req)))
      if(|lv_hit == 1 )begin
        `logLevel( icache, 1, $format("[%2d]ICACHE: FB: Hit in Line for Addr:%h",id,phyaddr))
        if((required_enable & lv_fb_enable) !=0)begin
          wr_fb_state <= Hit;
          wr_fb_response <= lv_response;
          `logLevel( icache, 1, $format("[%2d]ICACHE: FB: Required Word found",id))
          rg_polling_mode <= False;
        end
        else begin
          wr_fb_state <= None;
          rg_polling_mode <= True;
          `logLevel( icache, 1, $format("[%2d]ICACHE: FB: Required word not available yet",id))
        end
      end
      else begin
        wr_fb_state <= Miss;
        rg_polling_mode <= False;
        `logLevel( icache, 1, $format("[%2d]ICACHE: FB: Miss",id))
      end      
    endrule

    /*doc:rule: this rule fires when the requested word is either present in the SRAMs or the
    fill-buffer or if there was an error in the request. */
    rule rl_response_to_core(!ff_core_request.first.fence &&
                      ( wr_fault || wr_nc_state == Hit || wr_ram_state == Hit || 
                        wr_fb_state == Hit));

      let req = ff_core_request.first;
    `ifdef supervisor
      let pa_response = ff_from_tlb.first;
      Bit#(paddr) phyaddr = pa_response.address;
      ff_from_tlb.deq;
    `else
      Bit#(paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      IMem_core_response#(respwidth,esize) lv_response;

      Bit#(3) onehot_hit = {pack(wr_ram_state==Hit || wr_fault), 
                            pack(wr_fb_state==Hit && !wr_fault), 
                            pack(wr_nc_state==Hit && !wr_fault)};
    `ifdef ASSERT
      dynamicAssert(countOnes(onehot_hit) == 1, "More than one data structure shows a hit");
    `endif
      Vector#(3, IMem_core_response#(respwidth,esize)) lv_responses;
      lv_responses[0] = wr_nc_response;
      lv_responses[1] = wr_fb_response;
      lv_responses[2] = wr_ram_response;

      lv_response = select(lv_responses,unpack(onehot_hit));

      if(wr_ram_state == Hit && !wr_fault ) begin
        `logLevel( icache, 0, $format("[%2d]ICACHE: Response: Hit from SRAM",id))
        if(alg == 2) begin
          replacement.update_set(set_index, wr_ram_hitway);//wr_replace_line); 
          wr_ram_hitset <= tagged Valid set_index;
        end
      end
      if(wr_fb_state == Hit && !wr_fault ) begin
        `logLevel( icache, 0, $format("[%2d]ICACHE: Response: Hit from Fillbuffer",id))
      end
      if(wr_nc_state == Hit && !wr_fault ) begin
        `logLevel( icache, 0, $format("[%2d]ICACHE: Response: Hit from NC",id))
      end
    
      ff_core_request.deq;
      ff_core_response.enq(lv_response);
      rg_handling_miss <= False;
      `logLevel( icache, 0, $format("[%2d]ICACHE: Sending Response:",id,fshow(lv_response)))
    `ifdef perfmonitors
      if(!rg_handling_miss && onehot_hit[1] == 1)
          wr_total_fb_hits<=1;
    `endif
    endrule

    /*doc:rule: This rule fires when the requested word is a miss in both the SRAMs and the
    Fill-buffer. This rule thereby forwards the requests to the network. IOs by default should
    be a miss in both the SRAMs and the FB and thus need to be checked only here */
    rule rl_send_memory_request(wr_ram_state == Miss && wr_fb_state == Miss && !fb_full &&
                                !rg_handling_miss && ! ff_core_request.first.fence && 
                                ff_pending_req.notFull );
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
      // allocate a pending req which points to the new fb entry that is allotted.
      // TODO: in case of coherence this entry should point to an existing entry is only permission
      // upgrades are demanded
       // align the address to be line-address aligned
      phyaddr= lv_io_req?phyaddr:(phyaddr>>shift_amount)<<shift_amount;
      ff_read_mem_request.enq(ICache_mem_readreq{  address   : phyaddr,
                                                  burst_len  : fromInteger(burst_len),
                                                  burst_size : fromInteger(burst_size),
                                                  io: lv_io_req
                                              });
      rg_handling_miss <= True;
      Bit#(TLog#(fbsize)) lv_alotted_fb = rg_fbhead;

      // -- allocate a new entry in the fillbuffer
      if(!lv_io_req) begin

        if(rg_fbhead == fromInteger(v_fbsize-1))
          rg_fbhead <=0;
        else
          rg_fbhead <= rg_fbhead + 1;
        
        begin
          v_fb_valid[rg_fbhead] <= True;
          v_fb_addr[rg_fbhead] <= phyaddr;
          v_fb_enables[rg_fbhead] <= 0;
          v_fb_err[rg_fbhead] <= 0;
        end
        `logLevel( icache, 0, $format("[%2d]ICACHE: MemReq: Allocating Fbindex:%d",id, lv_alotted_fb))
      end
      let pend_req = Pending_req{phyaddr: phyaddr, init_enable:fn_init_enable(word_index), 
                                io_request: lv_io_req, fbindex: lv_alotted_fb};
      ff_pending_req.enq(pend_req);
      if(lv_io_req) begin
        `logLevel( icache, 0, $format("[%2d]ICACHE: MemReq: Sending NC Request for Addr:%h",id,phyaddr))
      `ifdef perfmonitors
          wr_total_nc<= 1;
      `endif
      end
      else begin
      `ifdef perfmonitors
          wr_total_cache_misses <= 1;
      `endif
        `logLevel( icache, 0, $format("[%2d]ICACHE : MemReq: Sending Line Request for Addr:%h",id, phyaddr))
      end
    endrule

    /*doc:rule: this rule will fill up the FB with the response from the memory, Once the last word
    has been received the entire line and tag are written in to the BRAM and the fill buffer is
    released in the next cycle*/
    rule rl_fill_from_memory(ff_pending_req.notEmpty && !ff_pending_req.first.io_request);
      let pending_req = ff_pending_req.first;
      let response = ff_read_mem_response.first;
      `logLevel( icache, 0, $format("[%2d]ICACHE: Processing:",id,fshow(pending_req)))
      ff_read_mem_response.deq;

      let fbindex = pending_req.fbindex;
      let lv_fb_enable = v_fb_enables[fbindex];
      v_fb_err[fbindex] <= pack(response.err);
      Bit#(TDiv#(linewidth,8)) lv_current_enable = lv_fb_enable == 0? pending_req.init_enable:
                                                                    rg_temp_enable;
      Bit#(linewidth) lv_new_word = duplicate(response.data);
      Bit#(TAdd#(TLog#(TDiv#(linewidth,8)),1)) rotate_amount =
                                                (fromInteger(valueOf(TDiv#(buswidth,8))));
  
      // using a special function here from Memory library of Bluespec to update data
      let lv_fb_linedata = updateDataWithMask(v_fb_data[fbindex], lv_new_word, lv_current_enable);
      rg_temp_enable <= rotateBitsBy(lv_current_enable,unpack(truncate(rotate_amount)));
      v_fb_enables[fbindex] <= lv_fb_enable | lv_current_enable;
      v_fb_data[fbindex] <=  lv_fb_linedata;
      `logLevel( icache, 0, $format("[%2d]ICACHE: current_enable:%h ",id,
                                                              lv_current_enable))
      `logLevel( icache, 0, $format("[%2d]ICACHE: Response from Memory:",id,fshow(response)))
      if(response.last)
        ff_pending_req.deq;
    endrule

    /*doc:rule: this rule is responsible for capturing the memory response for an IO request.*/
    rule rl_capture_io_response(ff_pending_req.notEmpty && ff_pending_req.first.io_request);
      let response = ff_read_mem_response.first;
      let req = ff_core_request.first;
      Bit#(`causesize) lv_cause = `Inst_access_fault;
      let lv_response = IMem_core_response{word:truncate(response.data), trap: response.err,
                                          cause: lv_cause, epochs: req.epochs};
      wr_nc_response <= lv_response;
      wr_nc_state <= Hit;
      ff_read_mem_response.deq;
      ff_pending_req.deq;
      `logLevel( icache, 2, $format("[%2d]ICACHE: NC Response from Memory: ",id,fshow(response)))
    endrule

    /*doc:rule: 
    This rule will evict an entry from the fill - buffer and update it in the cache RAMS.
    Multiple conditions under which this rule can fire:
    1. when the FB is full
    2. when the core is not requesting anything in a particular cycle and there exists a valid
       filled entry in the FB
    3. The rule will not fire when the entry being evicted is a line that has been recently
    requested by the core (present in the ff_core_request). Writing this line would cause a
    replay of the latest request. This would cause another cycle delay which would eventually be
    a hit in the cache RAMS.
    4. The latest request from the core is replayed if the replacement was to
    the same index.*/
    rule rl_release_from_fillbuffer((fb_full || rg_fence_stall) && !fb_empty
        && (&v_fb_enables[rg_fbtail]==1) && !rg_performing_replay);
      `logLevel( icache, 0, $format("[%2d]ICACHE: Release rule firing",id))
      let addr = v_fb_addr[rg_fbtail];
      Bit#(setbits) set_index = addr[v_setbits + v_blockbits + v_wordbits - 1 :
                                                                         v_blockbits + v_wordbits];

      let waynum <- replacement.line_replace(set_index, v_reg_valid[set_index],0);
      `logLevel( icache, 2, $format("[%2d]ICACHE: Release: set%d way:%d valid:%b",id,
                                    set_index, waynum,v_reg_valid[set_index][waynum]))
      if(v_fb_err[rg_fbtail] == 0)begin
        v_reg_valid[set_index][waynum]<=1;
        bram_tag[waynum].request(1,set_index,writetag, '1);
        bram_data[waynum].request(1,set_index,writedata, '1);
        if(rg_fbtail == fromInteger(v_fbsize-1))
          rg_fbtail <=0;
        else
          rg_fbtail <= rg_fbtail + 1;
        v_fb_valid[rg_fbtail]<=False;
        if(set_index == rg_recent_req )
          rg_performing_replay <= True;

        // --- update the replacement policy ------------//
        if(&v_reg_valid[set_index] == 1) begin
          if(alg != 2 )
            replacement.update_set(set_index,waynum);
          else begin
            if(wr_ram_hitset matches tagged Valid .i &&& i == set_index) begin
            end
            else
              replacement.update_set(set_index,waynum);
          end
        end
      `ifdef perfmonitors
        wr_total_fbfills<=1;
      `endif
      end
      else begin
        // enter here only if the fillbuffer entry has an error
        v_fb_valid[rg_fbtail]<=False;
        rg_fbtail <= rg_fbtail + 1;
      end
    endrule

    /*doc:rule: */
    rule rl_perform_replay(rg_performing_replay);
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        bram_tag[i].request(0,rg_recent_req,writetag, '1);
        bram_data[i].request(0,rg_recent_req,writedata, '1);
      end
      rg_performing_replay <= False;
      `logLevel( icache, 0, $format("[%2d]ICACHE: Replaying Req. Index:%d",id,rg_recent_req))
    endrule

    interface put_core_req=interface Put
      method Action put(ICache_core_request#(vaddr,esize) req)if( ff_core_response.notFull &&
                            !rg_fence_stall && !fb_full && !rg_performing_replay);
      `ifdef perfmonitors
        wr_total_access<= 1;
      `endif
        Bit#(paddr) phyaddr = truncate(req.address);
        Bit#(setbits) set_index=req.fence?0:phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=req.fence;
        rg_recent_req <= set_index;
        for(Integer i=0;i<v_ways;i=i+1)begin
          bram_data[i].request(0,set_index,writedata, '1);
          bram_tag[i].request(0,set_index,writetag, '1);
        end
        `logLevel( icache, 0, $format("[%2d]ICACHE: Receiving request: ",id,fshow(req)))
        `logLevel( icache, 0, $format("[%2d]ICACHE: set:%d",id,set_index))
        wr_takingrequest <= True;
      endmethod
    endinterface;
    method Action ma_cache_enable(Bool c);
      wr_cache_enable <= c;
    endmethod

    interface get_read_mem_req = toGet(ff_read_mem_request);
    interface put_read_mem_resp = toPut(ff_read_mem_response);
    interface get_core_resp = toGet(ff_core_response);
    // TODO
  `ifdef supervisor
    interface put_pa_from_tlb = toPut(ff_from_tlb);
  `endif
    `ifdef perfmonitors
      method mv_perf_counters = {wr_total_fbfills,wr_total_nc,wr_total_fb_hits,wr_total_cache_misses,wr_total_access};
    `endif
    //TODO
    method mv_cache_available = ff_core_response.notFull && ff_core_request.notFull && 
        !rg_fence_stall && !fb_full && !rg_performing_replay ;
  endmodule
endpackage

