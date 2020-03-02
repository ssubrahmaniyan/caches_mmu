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
  import replacement :: * ;
  import mem_config :: * ;

  typedef struct{
    Bit#(addr)  phyaddr;
    Bit#(besize) init_enable;
    Bool io_request;
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
  `ifdef supervisor
    interface Put#(ITLB_core_response#(paddr)) mav_pa_from_tlb;
  `endif
  `ifdef perfmonitors
    method Bit#(5) perf_counters;
  `endif
    method Action ma_cache_enable(Bool c);
  endinterface

  /*doc:module: */
  (*conflict_free="rl_send_memory_request, rl_response_to_core"*)
  module mkicache#(function Bool isNonCacheable(Bit#(paddr) addr, Bool cacheable), 
                    parameter String alg)
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
          Mul#(buswidth, c__, linewidth),
          Add#(TAdd#(wordbits, blockbits), d__, paddr),
          Add#(e__, TLog#(ways), 4),
          Add#(f__, TLog#(ways), TLog#(TAdd#(1, ways))),
          Add#(g__, respwidth, buswidth),
          Add#(respwidth, k__, vaddr),
          Add#(l__, TLog#(TDiv#(linewidth, buswidth)), paddr),
          Add#(m__, blockbits, paddr),          
        `ifdef ASSERT
          Add#(1, j__, TLog#(TAdd#(1, ways))),
        `endif

          // for using mem_config
          Mul#(TDiv#(tagbits, tbanks), tbanks, tagbits),
          Add#(h__, TDiv#(tagbits, tbanks), tagbits),
          Mul#(TDiv#(linewidth, dbanks), dbanks, linewidth),
          Add#(i__, TDiv#(linewidth, dbanks), linewidth)
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

    // ----------------------- FIFOs to interact with interface of the design -------------------//
    /*doc:fifo: This fifo stores the request from the core.*/
    FIFOF#(ICache_request#(vaddr,esize)) ff_core_request <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response that needs to be sent back to the core.*/
    FIFOF#(FetchResponse#(respwidth,esize))ff_core_response <- mkBypassFIFOF();
    /*doc:fifo: this fifo stores the read request that needs to be sent to the next memory level.*/
    FIFOF#(ICache_mem_request#(paddr)) ff_read_mem_request    <- mkSizedFIFOF(2);
    /*doc:fifo: This fifo stores the response from the next level memory.*/
    FIFOF#(ICache_mem_response#(buswidth)) ff_read_mem_response  <- mkBypassFIFOF();
  `ifdef supervisor 
    /*doc:fifo: this fifo receives the physical address from the TLB */
    FIFOF#(ITLB_core_response#(paddr)) ff_from_tlb <- mkBypassFIFOF();
  `endif

    // ------------------------ FIFOs for internal state-maintenance ---------------------------//
    /*doc:fifo: This fifo holds meta information of the miss/io request that was made by the core*/
    FIFOF#(Pending_req#(paddr, TDiv#(linewidth,8))) ff_pending_req <- mkUGSizedFIFOF(2);

    // -------------------- Register declarations ----------------------------------------------//

    /*doc:reg: register when True indicates a fence is in progress and thus will prevent taking any
     new requests from the core*/
    Reg#(Bool) rg_fence_stall <- mkRegA(False);

    /*doc:reg: When tru indicates that a miss is being catered to*/
    Reg#(Bool) rg_handling_miss <- mkRegA(False);

    //------------------------- Fill buffer data structures -------------------------------------//
    /*doc:reg: this register holds the incoming line from the memory on a miss request*/
    Reg#(Bit#(linewidth)) rg_fb_linedata <- mkRegA(0);

    /*doc:reg: this register indicates if the current line being filled in the FB had an error from
    * the memory*/
    Reg#(Bool) rg_fb_err <- mkRegA(False);

    /*doc:reg: this register holds the currently available bytes within the fill-buffer that can be
     * used to respond back to core*/
    Reg#(Bit#(TDiv#(linewidth,8))) rg_fb_enable <- mkRegA(0);

    /*doc:reg:This register holds the next set of byte-enables that the response from the memory is
    * supposed to fill in the fill-buffer*/
    Reg#(Bit#(TDiv#(linewidth,8))) rg_fb_enable_temp <- mkRegA(0);

    /*doc:reg: This register when True indicates that the fill-buffer line has been filled and
    * updated in the ram and thus the fill-buffer entries must be released and reset.*/
    Reg#(Bool) rg_fb_release <- mkDRegA(False);

    // -------------------- Wire declarations ----------------------------------------------//
    /*doc:wire: boolean wire indicating if the cache is enabled. This is controlled through a csr*/
    Wire#(Bool) wr_cache_enable<-mkWire();

    /*doc:wire: this wire indicates if there was a hit or miss on SRAMs.*/
    Wire#(RespState) wr_ram_state <- mkDWire(None);
    Wire#(FetchResponse#(respwidth,esize)) wr_ram_response <- mkDWire(?);
    Wire#(Bit#(TLog#(ways))) wr_ram_hitway <-mkDWire(0);

    /*doc:wire: this wire indicates if there was a hit or miss on Fllbuffer.*/
    Wire#(RespState) wr_fb_state <- mkDWire(None);
    Wire#(FetchResponse#(respwidth,esize)) wr_fb_response <- mkDWire(?);

    Wire#(RespState) wr_nc_state <- mkDWire(None);
    Wire#(FetchResponse#(respwidth,esize)) wr_nc_response <- mkDWire(?);

  `ifdef perfmonitors
    /*doc:wire: wire to pulse on every access*/
    Wire#(Bit#(1)) wr_total_access <- mkDWire(0);
    /*doc:wire: wire to pulse on every cache miss*/
    Wire#(Bit#(1)) wr_total_cache_misses <- mkDWire(0);
    /*doc:wire: wire to pulse on non-cacheable accesses*/
    Wire#(Bit#(1)) wr_total_nc <- mkDWire(0);
  `endif


    // ----------------------- Storage elements -------------------------------------------//
    /*doc:reg: This is an array of the valid bits. Each entry corresponds to a set and contains
     * 'way' number of bits in each entry*/
    Vector#(sets, Reg#(Bit#(ways))) v_reg_valid <- replicateM(mkRegA(0));
    
    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Ifc_mem_config1r1w#(sets, tagbits, tbanks) bram_tag [v_ways];

    /*doc:ram: This the data array which is dual ported has 'way' number of rams*/
    Ifc_mem_config1r1w#(sets, linewidth, dbanks) bram_data[v_ways];
    for (Integer i = 0; i<v_ways; i = i + 1) begin
      bram_tag[i]  <- mkmem_config1r1w(False,"double");
      bram_data[i] <- mkmem_config1r1w(False,"double");
    end
    Ifc_replace#(sets,ways) replacement <- mkreplace(alg);

    // --------------------------- Rule operations ------------------------------------- //
    /*doc:rule: rule that fences the cache by invalidating all the lines*/
    rule rl_fence_operation(ff_core_request.first.fence && rg_fence_stall && !ff_pending_req.notEmpty ) ;
      `logLevel( icache, 0, $format("ICACHE : Fence operation in progress"))
      for (Integer i = 0; i< v_sets ; i = i + 1) begin
        v_reg_valid[i] <= 0;
      end
      rg_fence_stall <= False;
      ff_core_request.deq;
      replacement.reset_repl;
    endrule

    /*doc:rule: This rule checks the tag rams for a hit*/
    rule rl_ram_check(!ff_core_request.first.fence && !rg_handling_miss);
      let req = ff_core_request.first;
    `ifdef supervisor
      Bit#(paddr) phyaddr = ff_from_tlb.first.address;
      Bool lv_access_fault = ff_from_tlb.first.trap;
      Bit#(`causesize) lv_cause = lv_access_fault? ff_from_tlb.first.cause:`Inst_access_fault;
    `else
      Bit#(`causesize) lv_cause = `Inst_access_fault;
      Bit#(TSub#(vaddr,paddr)) upper_bits=truncateLSB(req.address);
      Bit#(paddr) phyaddr = truncate(req.address);
      Bool lv_access_fault = unpack(|upper_bits);
    `endif
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(tagbits) request_tag = phyaddr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set_index= phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];

      Vector#(v_ways, Bit#(respwidth)) dataword;
      Bit#(ways) hit_tag =0;
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        dataword[i] = truncate(bram_data[i].read_response >> block_offset);
      end
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        hit_tag[i] = pack(v_reg_valid[set_index][i] == 1 && bram_tag[i].read_response == request_tag);
      end

      let hit_dataline = select(dataword, unpack(hit_tag));
      Bit#(respwidth) response_word=hit_dataline;
    `ifdef ASSERT
      dynamicAssert(countOnes(hit_tag) <= 1,"ICACHE: More than one way is a hit in the cache");
    `endif

      let lv_response = FetchResponse{instr:response_word, trap: lv_access_fault,
                                          cause: lv_cause, epochs: req.epochs};
      wr_ram_response <= lv_response;
      wr_ram_hitway<=truncate(pack(countZerosLSB(hit_tag)));
      if(lv_access_fault || |(hit_tag) == 1) begin// trap or hit in RAMs
        wr_ram_state <= Hit;
      end
      else begin // in case of miss from cache
        wr_ram_state <= Miss;
      end
      `logLevel( icache, 0, $format("ICACHE: Hit:%b For Req:",(hit_tag),fshow(req)," Response:", 
                                      fshow(lv_response)))
    endrule

    /*doc:rule: This rule will check if the requested word is present in the fill-buffer or not*/
    rule rl_fillbuffer_check(!ff_core_request.first.fence);
      let req = ff_core_request.first;
    `ifdef supervisor
      Bit#(paddr) phyaddr = ff_from_tlb.first.address;
    `else
      Bit#(paddr) phyaddr = truncate(req.address);
    `endif
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset={phyaddr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(blockbits) word_index= truncate(phyaddr>>v_wordbits);
      Bit#(respwidth) response_word=truncate(rg_fb_linedata >> block_offset);
      let required_enable = fn_enable(word_index);
      let lv_response = FetchResponse{instr:response_word, trap: rg_fb_err,
                                          cause: `Inst_access_fault, epochs: req.epochs};
      `logLevel( icache, 1, $format("ICACHE: FB processing Req: ",fshow(req)))
      Bit#(TSub#(paddr, TAdd#(wordbits,blockbits))) lv_fb_addr = truncateLSB(ff_pending_req.first.phyaddr);
      Bit#(TSub#(paddr, TAdd#(wordbits,blockbits))) lv_req_addr = truncateLSB(phyaddr);
      if(lv_req_addr == lv_fb_addr && ff_pending_req.notEmpty)begin
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
      FetchResponse#(respwidth,esize) lv_response;

      Bit#(3) onehot_hit = {pack(wr_ram_state==Hit), pack(wr_fb_state==Hit), pack(wr_nc_state==Hit)};
      Vector#(3, FetchResponse#(respwidth,esize)) lv_responses;
      lv_responses[0] = wr_nc_response;
      lv_responses[1] = wr_fb_response;
      lv_responses[2] = wr_ram_response;

      lv_response = select(lv_responses,unpack(onehot_hit));

      if(wr_ram_state == Hit) begin
        `logLevel( icache, 0, $format("ICACHE: Hit from SRAM"))
        if(alg == "PLRU")
          replacement.update_set(set_index, wr_ram_hitway);//wr_replace_line); 
      end
      else if(wr_fb_state == Hit) begin
        `logLevel( icache, 0, $format("ICACHE: Hit from Fillbuffer"))
      end
      else begin
        `logLevel( icache, 0, $format("ICACHE: Hit from NC"))
      end
      lv_response.instr= lv_response.trap?truncateLSB(req.address): lv_response.instr ;
      ff_core_request.deq;
      ff_core_response.enq(lv_response);
      rg_handling_miss <= False;
    `ifdef ASSERT
      Bit#(3) __t ;
      __t[0]= pack(wr_ram_state == Hit);
      __t[1]= pack(wr_fb_state == Hit);
      __t[2] =pack(wr_nc_state == Hit);
      dynamicAssert(countOnes(__t) == 1, "More than one data structure shows a hit");
    `endif
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
      ff_read_mem_request.enq(ICache_mem_request{  address   : phyaddr,
                                                  burst_len  : fromInteger(burst_len),
                                                  burst_size : fromInteger(burst_size)});
      if(lv_io_req) begin
        `logLevel( icache, 0, $format("ICACHE: Sending IO Request for Addr:%h",phyaddr))
      `ifdef perfmonitors
        wr_total_nc <= 1;
      `endif
      end
      else begin
      `ifdef perfmonitors
        wr_total_cache_misses <= 1;
      `endif
        `logLevel( icache, 0, $format("ICACHE : Sending Line Request for Addr:%h", phyaddr))
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
        let waynum<-replacement.line_replace(set_index, v_reg_valid[set_index]);
        replacement.update_set(set_index,waynum);
        rg_fb_release <= True;
        bram_tag[waynum].write(1,set_index,lv_write_tag);
        bram_data[waynum].write(1,set_index,lv_fb_linedata);
        v_reg_valid[set_index][waynum]<= 1'b1;
        `logLevel( icache, 0, $format("ICACHE: Writing set:%d tag:%h way:%d",
                                                                    set_index,lv_write_tag,waynum))
        `logLevel( icache, 0, $format("ICACHE: Writing data:%h",lv_fb_linedata))
      end
      else begin
        rg_fb_enable_temp <= rotateBitsBy(lv_current_enable,unpack(truncate(rotate_amount)));
      end
      rg_fb_enable <= rg_fb_enable | lv_current_enable;
      rg_fb_linedata <=  lv_fb_linedata;
      rg_fb_err <= response.err;
      `logLevel( icache, 0, $format("ICACHE: current_enable:%h",lv_current_enable))
      `logLevel( icache, 0, $format("ICACHE: Response from Memory:",fshow(response)))
    endrule

    /*doc:rule: this rule is responsible for capturing the memory response for an IO request.*/
    rule rl_capture_io_response(ff_pending_req.notEmpty && ff_pending_req.first.io_request);
      let response = ff_read_mem_response.first;
      let req = ff_core_request.first;
      let lv_response = FetchResponse{instr:truncate(response.data), trap: response.err,
                                          cause: `Inst_access_fault, epochs: req.epochs};
      wr_nc_response <= lv_response;
      wr_nc_state <= Hit;
      ff_read_mem_response.deq;
      ff_pending_req.deq;
      `logLevel( icache, 2, $format("ICACHE: IO Response from Memory: ",fshow(response)))
    endrule

    /*doc:rule: hold the fillbuffer for an extra cycle since the write to the BRAM is only available
    * in the next cycle. This rule will also re-initialize all the fb related registers*/
    rule rl_delay_fb_release(rg_fb_release && !ff_pending_req.first.io_request);
      rg_fb_enable <= 0;
      rg_fb_enable_temp <= 0;
      rg_fb_linedata <= 0;
      rg_fb_err <= False;
      ff_pending_req.deq;
      `logLevel( icache, 1, $format("ICACHE: Releasing FB. Addr:",fshow(ff_pending_req.first)))
    endrule

    interface core_req=interface Put
      method Action put(ICache_request#(vaddr,esize) req)if( ff_core_response.notFull &&
                            !rg_fence_stall);
      `ifdef perfmonitors
        wr_total_access<=1;
      `endif
        Bit#(paddr) phyaddr = truncate(req.address);
        Bit#(setbits) set_index=req.fence?0:phyaddr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
        ff_core_request.enq(req);
        rg_fence_stall<=req.fence;
        for(Integer i=0;i<v_ways;i=i+1)begin
          bram_data[i].read(set_index);
          bram_tag[i].read(set_index);
        end
        `logLevel( icache, 0, $format("ICACHE : Receiving request: ",fshow(req)))
        `logLevel( icache, 0, $format("ICACHE : set:%d",set_index))
      endmethod
    endinterface;
    method Action ma_cache_enable(Bool c);
      wr_cache_enable <= c;
    endmethod

    interface read_mem_req = toGet(ff_read_mem_request);
    interface read_mem_resp = toPut(ff_read_mem_response);
    interface core_resp = toGet(ff_core_response);
  `ifdef supervisor
    interface mav_pa_from_tlb = toPut(ff_from_tlb);
  `endif
    `ifdef perfmonitors
      method Bit#(5) perf_counters;
        return {1'b0,wr_total_nc,1'b0,wr_total_cache_misses,wr_total_access};
      endmethod
    `endif
  endmodule
endpackage

