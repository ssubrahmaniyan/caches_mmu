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
  import Memory :: * ;
  import DReg :: * ;

  `include "cache.defines"
  import cache_types :: * ;
  import globals :: * ;

  typedef struct{
    Bit#(addr)  phyaddr;
    Bit#(besize) init_enable;
  } Pending_req#(numeric type addr, numeric type besize) deriving(Bits, Eq, FShow);

  interface Ifc_icache#(numeric type wordsize,
                        numeric type blocksize,
                        numeric type sets,
                        numeric type ways,
                        numeric type paddr,
                        numeric type vaddr,
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
    `ifdef perfmonitors
      method Bit#(5) perf_counters;
    `endif
    method Action ma_cache_enable(Bool c);
  endinterface

  /*doc:module: */
  module mkicache#(function Bool isNonCacheable(Bit#(paddr) addr, Bool cacheable))
                  (Ifc_icache#(wordsize, blocksize, sets, ways, paddr, vaddr, esize, dbanks, tbanks,
                            buswidth))
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

          // required by bsc
          Mul#(TDiv#(linewidth, TDiv#(linewidth, 8)), TDiv#(linewidth, 8),linewidth),
          Add#(a__, paddr, vaddr),
          Add#(b__, respwidth, linewidth),
          Mul#(buswidth, c__, linewidth)
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

    function Bit#(TDiv#(linewidth,8)) fn_enable(Bit#(blockbits) word_index);
      Bit#(TDiv#(linewidth,8)) write_enable = 'hF << word_index;
      return write_enable;
    endfunction

    // ----------------------- FIFOs to interact with interface of the design -------------------//
    /*doc:fifo: This fifo stores the request from the core.*/
    FIFOF#(ICache_request#(vaddr,esize)) ff_core_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response that needs to be sent back to the core.*/
    FIFOF#(FetchResponse#(respwidth,esize))ff_core_response <- mkBypassFIFOF();
    /*doc:fifo: this fifo stores the read request that needs to be sent to the next memory level.*/
    FIFOF#(ICache_mem_request#(paddr)) ff_read_mem_request    <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response from the next level memory.*/
    FIFOF#(ICache_mem_response#(buswidth)) ff_read_mem_response  <- mkBypassFIFOF();

    // ------------------------ FIFOs for internal state-maintenance ---------------------------//
    FIFOF#(Pending_req#(paddr, TDiv#(linewidth,8))) ff_pending_req <- mkSizedFIFOF(2);

    // -------------------- Register declarations ----------------------------------------------//
    /*doc:reg: register when True indicates a fence is in progress and thus will prevent taking any
     new requests from the core*/
    Reg#(Bool) rg_fence_stall <- mkReg(False);

    /*doc:reg: When tru indicates that a miss is being catered to*/
    Reg#(Bool) rg_handling_miss <- mkReg(False);

    Reg#(Bit#(linewidth)) rg_fb_linedata <- mkReg(0);
    Reg#(Bit#(TDiv#(linewidth,8))) rg_fb_enable <- mkReg(0);
    Reg#(Bit#(TDiv#(linewidth,8))) rg_fb_enable_temp <- mkReg(0);
    Reg#(Bit#(TSub#(paddr,(TAdd#(wordbits,blockbits))))) rg_fb_addr <- mkReg(0);
    Reg#(Bool) rg_fb_release <- mkDReg(False);
    /*doc:reg: */
    Reg#(Bool) rg_fb_valid[2] <- mkCReg(2,False);

    // -------------------- Wire declarations ----------------------------------------------//
    /*doc:wire: boolean wire indicating if the cache is enabled. This is controlled through a csr*/
    Wire#(Bool) wr_cache_enable<-mkWire();

    /*doc:wire: this wire indicates if there was a hit or miss on SRAMs.*/
    Wire#(RespState) wr_ram_state <- mkDWire(None);
    Wire#(FetchResponse#(respwidth,esize)) wr_ram_response <- mkDWire(?);

    /*doc:wire: this wire indicates if there was a hit or miss on Fllbuffer.*/
    Wire#(RespState) wr_fb_state <- mkDWire(None);
    Wire#(FetchResponse#(respwidth,esize)) wr_fb_response <- mkDWire(?);

  `ifdef perfmonitors
    /*doc:wire: wire to pulse on every access*/
    Wire#(Bit#(1)) wr_total_access <- mkDWire(0);
    /*doc:wire: wire to pulse on every cache miss*/
    Wire#(Bit#(1)) wr_total_cache_misses <- mkDWire(0);
    /*doc:wire: wire to pulse on non-cacheable accesses*/
    Wire#(Bit#(1)) wr_total_nc <- mkDWire(0);
  `endif


    // ----------------------- Storage elements -------------------------------------------//
    Vector#(sets, Reg#(Bit#(ways))) v_reg_valid <- replicateM(mkReg(0));
    BRAM_DUAL_PORT#(Bit#(TLog#(sets)), Bit#(tagbits)) bram_tag [v_ways];
    BRAM_DUAL_PORT_BE#(Bit#(TLog#(sets)), Bit#(linewidth), TDiv#(linewidth,8)) bram_data [v_ways];
    for (Integer i = 0; i<v_ways; i = i + 1) begin
      bram_tag[i]  <- mkBRAMCore2(v_sets, False);
      bram_data[i] <- mkBRAMCore2BE(v_sets, False);
    end


    // --------------------------- Rule operations ------------------------------------- //
    /*doc:rule: rule that fences the cache by invalidating all the lines*/
    rule rl_fence_operation(ff_core_request.first.fence && rg_fence_stall ) ;
      `logLevel( icache, 0, $format("ICACHE : Fence operation in progress"))
      for (Integer i = 0; i< v_sets ; i = i + 1) begin
        v_reg_valid[i] <= 0;
      end
      rg_fence_stall <= False;
      ff_core_request.deq;
      // TODO: reset replacement as well
    endrule

    /*doc:rule: This rule checks the tag rams for a hit*/
    rule rl_ram_check(!ff_core_request.first.fence);
      let req = ff_core_request.first;
    `ifdef supervisor
      Bit#(paddr) phyaddr = ff_from_tlb.first;
    `else
      Bit#(TSub#(vaddr,paddr)) upper_bits=truncateLSB(req.address);
      Bit#(paddr) phyaddr = truncate(req.address);
      Bool lv_access_fault = unpack(|upper_bits);
    `endif
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(tagbits) request_tag = phyaddr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];

      Vector#(v_ways, Bit#(linewidth)) datalines;
      Bit#(ways) hit_tag =0;
      for (Integer i = 0; i< v_ways; i = i + 1)
        datalines[i] = bram_data[i].a.read;
      for (Integer i = 0; i< v_ways; i = i + 1)
        hit_tag[i] = pack(v_reg_valid[set_index][i] == 1 && bram_tag[i].a.read == request_tag);

      let hit_dataline = select(datalines, unpack(hit_tag));
      Bit#(respwidth) response_word=truncate(hit_dataline >> block_offset);
    `ifdef ASSRT
      dynamicAssert(countOnes(hit_tag) <= 1,"ICACHE: More than one way is a hit in the cache");
    `endif

      let lv_response = FetchResponse{instr:response_word, trap: lv_access_fault,
                                          cause: `Inst_access_fault, epochs: req.epochs};
      wr_ram_response <= lv_response;
      if(lv_access_fault || |(hit_tag) == 1) begin// trap or hit in RAMs
        wr_ram_state <= Hit;
      end
      else begin // in case of miss from cache
        wr_ram_state <= Miss;
      end
      `logLevel( icache, 0, $format("ICACHE: Hit:%b, Response:", |(hit_tag),lv_response))
    endrule

    /*doc:rule: This rule will check if the requested word is present in the fill-buffer or not*/
    rule rl_fillbuffer_check(!ff_core_request.first.fence && ff_pending_req.notFull);
      let req = ff_core_request.first;
    `ifdef supervisor
      Bit#(paddr) phyaddr = ff_from_tlb.first;
    `else
      Bit#(paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(blockbits) word_index= phyaddr[v_blockbits+v_wordbits-1:v_wordbits];
      Bit#(respwidth) response_word=truncate(rg_fb_linedata >> block_offset);

      let required_enable = fn_enable(word_index);
      let lv_response = FetchResponse{instr:response_word, trap: False,
                                          cause: `Inst_access_fault, epochs: req.epochs};
      `logLevel( icache, 1, $format("ICACHE: FB processing Req: ",fshow(req)))
//      `logLevel( icache, 1, $format("ICACHE: FB required enable:%b rg_fb_addr:%h rg_fb_enable:%b",
//                                required_enable, rg_fb_addr, rg_fb_enable))
      if(truncateLSB(phyaddr) == rg_fb_addr && rg_fb_valid[0])begin
        `logLevel( icache, 1, $format("ICACHE: Hit in FB Line for Addr:%h",phyaddr))
        if((required_enable & rg_fb_enable) !=0)begin
          wr_fb_state <= Hit;
          wr_fb_response <= lv_response;
          `logLevel( icache, 1, $format("ICACHE: Required Word found in FB"))
        end
        else begin
          wr_fb_state <= None;
          `logLevel( icache, 1, $format("ICACHE: Required word not available in the FB yet"))
        end
      end
      else begin
        wr_fb_state <= Miss;
        `logLevel( icache, 1, $format("ICACHE: Miss in FB also"))
      end

    endrule

    /*doc:rule: this rule fires when the requested word is either present in the SRAMs or the
     fill-buffer or if there was an error in the request */
    rule rl_response_to_core(!ff_core_request.first.fence && (
                                wr_ram_state == Hit || wr_fb_state == Hit));
      if(wr_ram_state == Hit) begin
        `logLevel( icache, 0, $format("ICACHE: Hit from SRAM"))
        ff_core_response.enq(wr_ram_response);
      end
      else begin
        `logLevel( icache, 0, $format("ICACHE: Hit from Fillbuffer"))
        ff_core_response.enq(wr_fb_response);
      end
      ff_core_request.deq;
    endrule

    /*doc:rule: This rule fires when the requested word is a miss in both the SRAMs and the
     * Fill-buffer. This rule thereby forwards the requests to the network. IOs by default should
     * be a miss in both the SRAMs and the FB and thus need to be checked only here */
    rule rl_send_memory_request(wr_ram_state == Miss && wr_fb_state == Miss);
      let req = ff_core_request.first;
      Bit#(paddr) phyaddr = truncate(req.address);
      Bit#(blockbits) word_index= phyaddr[v_blockbits+v_wordbits-1:v_wordbits];
      let pend_req = Pending_req{phyaddr: phyaddr, init_enable:fn_enable(word_index)};
      ff_pending_req.enq(pend_req);
      if(isNonCacheable(phyaddr,wr_cache_enable)) begin
        ff_read_mem_request.enq(ICache_mem_request{  address    : phyaddr,
                                                  burst_len  : 0,
                                                  burst_size : fromInteger(v_wordbits)});
        `logLevel( icache, 0, $format("ICACHE: Sending IO Request for Addr:%h",phyaddr))
      `ifdef perfmonitors
        wr_total_nc <= 1;
      `endif
      end
      else begin
      `ifdef perfmonitors
        wr_total_cache_misses <= 1;
      `endif
        rg_fb_addr <= truncateLSB(phyaddr);
        rg_fb_valid[1] <= True;
        // TODO allocate new line in FB
        `logLevel( icache, 0, $format("ICACHE : Sending Line Request for Addr:%h", phyaddr))
        let shift_amount = valueOf(TLog#(TDiv#(buswidth,8)));
        phyaddr= (phyaddr>>shift_amount)<<shift_amount; // align the address to be one word aligned.
        let burst_len = (v_blocksize/valueOf(TDiv#(buswidth,respwidth)))-1;
        let burst_size = valueOf(TLog#(TDiv#(buswidth,8)));
        ff_read_mem_request.enq(ICache_mem_request{ address    : phyaddr,
                                                  burst_len  : fromInteger(burst_len),
                                                  burst_size : fromInteger(burst_size)});

      end
    endrule

    /*doc:rule: */
    rule rl_fill_from_memory(!rg_fb_release);
      let pending_req = ff_pending_req.first;
      let response = ff_read_mem_response.first;
      ff_read_mem_response.deq;
      Bit#(setbits) set_index=pending_req.phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(TDiv#(linewidth,8)) lv_current_enable = rg_fb_enable == 0? pending_req.init_enable:
                                                                    rg_fb_enable_temp;
      Bit#(linewidth) lv_new_word = duplicate(response.data);
      let rotate_amount = valueOf(TDiv#(buswidth,8));
      if(response.last) begin
        rg_fb_release <= True;
      end
      else begin
        rg_fb_enable_temp <= rotateBitsBy(lv_current_enable,fromInteger(rotate_amount));
        rg_fb_enable <= rg_fb_enable | lv_current_enable;
      end
      rg_fb_linedata <=  updateDataWithMask(rg_fb_linedata, lv_new_word, lv_current_enable);
      // TODO define the way that needs to be replaced
      bram_data[0].b.put(lv_current_enable,set_index,duplicate(response.data));

      `logLevel( icache, 0, $format("ICACHE: Response from Memory:",fshow(response)))
      `logLevel( icache, 0, $format("ICACHE: current_en:%b",lv_current_enable))
    endrule

    /*doc:rule: */
    rule rl_delay_fb_release(rg_fb_release);
      rg_fb_enable <= 0;
      rg_fb_enable_temp <= 0;
      rg_fb_linedata <= 0;
      ff_pending_req.deq;
      rg_fb_valid[0] <= False;
      `logLevel( icache, 1, $format("ICACHE: Releasing FB line"))
    endrule

    interface core_req=interface Put
      method Action put(ICache_request#(vaddr,esize) req)if( ff_core_response.notFull &&
                            !rg_fence_stall);
      `ifdef perfmonitors
        wr_total_access<=1;
      `endif
        Bit#(paddr) phyaddr = truncate(req.address);
        Bit#(setbits) set_index=phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=req.fence;
        for(Integer i=0;i<v_ways;i=i+1)begin
          bram_data[i].a.put('b0,set_index,?);
          bram_tag[i].a.put(False,set_index,?);
        end
        `logLevel( icache, 0, $format("ICACHE : Receiving request: ",fshow(req)))
      endmethod
    endinterface;
    method Action ma_cache_enable(Bool c);
      wr_cache_enable <= c;
    endmethod

    interface read_mem_req = toGet(ff_read_mem_request);
    interface read_mem_resp = toPut(ff_read_mem_response);
    interface core_resp = toGet(ff_core_response);
  endmodule
endpackage

