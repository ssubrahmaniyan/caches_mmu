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

--------------------------------------------------------------------------------------------------
*/
package null_dcache;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import GetPut::*;
  import BUtils::*;
  import Assert :: *;

  import cache_types :: *;
  import globals :: *;
  `include "cache.defines"
  `include "Logger.bsv"


  interface Ifc_l1dcache#( numeric type wordsize, 
                           numeric type blocksize,  
                           numeric type sets,
                           numeric type ways,
                           numeric type paddr,
                           numeric type vaddr,
                           numeric type fbsize,
                           numeric type sbsize,
                           numeric type esize,
                           numeric type dbanks,
                           numeric type tbanks
                           );

    interface Put#(DCache_core_request#(vaddr, TMul#(wordsize, 8), esize)) core_req;
    interface Get#(DMem_core_response#(TMul#(wordsize, 8), esize)) core_resp;
    method DCache_mem_writereq#(paddr, TMul#(wordsize, 8)) write_mem_req_rd;
    method Action write_mem_req_deq;
    interface Get#(DCache_mem_readreq#(paddr)) read_mem_req;
    interface Put#(DCache_mem_readresp#(TMul#(wordsize, 8))) read_mem_resp;
    `ifdef pysimulate
      interface Get#(Bit#(1)) meta;
    `endif
    `ifdef perf
      method Bit#(5) perf_counters;
    `endif
    method Action cache_enable(Bool c);
    method Action perform_store(Bit#(esize) currepoch);
    method Bool cacheable_store;
    method Bool cache_available;
    method Bool storebuffer_empty;
  `ifdef supervisor
    interface Get#(DCache_core_request#(vaddr, TMul#(wordsize, 8), esize)) hold_req;
    interface Put#(DTLB_core_response#(paddr)) pa_from_tlb;
    interface Get#(DMem_core_response#(TMul#(wordsize, 8), esize)) ptw_resp;
  `endif
  endinterface

  (*conflict_free="allocate_storebuffer, perform_store"*)
  (*conflict_free="allocate_storebuffer, respond_to_core"*)
  module mknull_dcache(Ifc_l1dcache#(wordsize, blocksize, sets, ways, paddr, vaddr, fbsize, 
                                    sbsize, esize, dbanks, tbanks))
    provisos(
          Mul#(wordsize, 8, respwidth),// respwidth is the total bits in a word
          Add#(a__, paddr, vaddr),
          Log#(wordsize, wordbits),      // wordbits is no. of bits to index a byte in a word
          Add#(b__, 3, TLog#(respwidth)),
          Mul#(16, c__, respwidth),
          Mul#(32, d__, respwidth),
          Add#(e__, 16, respwidth),
          Add#(f__, 8, respwidth),
          Add#(g__, respwidth, vaddr),
          Add#(h__, 32, respwidth)
          );        

    String dcache = "";
    let v_sbsize = valueOf(sbsize);
    let v_respwidth = valueOf(respwidth);
    let v_wordbits = valueOf(wordbits);

    function Bit#(respwidth) fn_atomic_op (Bit#(5) op,  Bit#(respwidth) rs2,  
                                           Bit#(respwidth) loaded);
      Bit#(respwidth) op1 = loaded;
      Bit#(respwidth) op2 = rs2;
      if(op[4] == 0)begin
	  		op1 = signExtend(loaded[31 : 0]);
        op2 = signExtend(rs2[31 : 0]);
      end
      Int#(respwidth) s_op1 = unpack(op1);
	  	Int#(respwidth) s_op2 = unpack(op2);
      
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
    function Bool isTrue(Bool a);
      return a;
    endfunction
    function Bool isOne(Bit#(1) a);
      return unpack(a);
    endfunction
    
    // This fifo stores the request from the core.
    FIFOF#(DCache_core_request#(vaddr, respwidth, esize)) ff_core_request <- mkSizedFIFOF(2); 
    // This fifo stores the response that needs to be sent back to the core.
    FIFOF#(DMem_core_response#(respwidth, esize))ff_core_response <- mkBypassFIFOF();
    // this fifo stores the read request that needs to be sent to the next memory level.
    FIFOF#(DCache_mem_readreq#(paddr)) ff_read_mem_request    <- mkSizedFIFOF(2);
    // This fifo stores the response from the next level memory.
    FIFOF#(DCache_mem_readresp#(respwidth)) ff_read_mem_response  <- mkBypassFIFOF();
    
    FIFOF#(DCache_mem_writereq#(paddr, TMul#(wordsize, 8))) ff_write_mem_request    
                                                                              <- mkSizedFIFOF(1);
    Wire#(Bool) wr_trap <- mkDWire(False);

  `ifdef supervisor
    FIFOF#(DCache_core_request#(vaddr, respwidth, esize)) ff_hold_request <- mkBypassFIFOF(); 
    // This fifo stores the response that needs to be sent back to the PTW.
    FIFOF#(DMem_core_response#(respwidth, esize))ff_ptw_response <- mkBypassFIFOF();
    // The following wire holds the physical address from TLB
    FIFOF#(DTLB_core_response#(paddr)) ff_from_tlb <- mkBypassFIFOF();
    Wire#(Bool) wr_tlb_miss <- mkDWire(False);
  `endif
    Reg#(Bool) rg_pending_read <- mkReg(False);
    Wire#(Bool) wr_nc_response <- mkDWire(False);
    Wire#(Bit#(respwidth)) wr_nc_word <- mkDWire(0);
    Wire#(Bool) wr_nc_err <- mkDWire(False);
    
    Reg#(Bit#(paddr)) store_addr [v_sbsize];
    Reg#(Bit#(respwidth)) store_data [v_sbsize];
    Reg#(Bit#(2)) store_size [v_sbsize];
    Vector#(sbsize, Reg#(Bool)) store_valid <- replicateM(mkReg(False));
    Reg#(Bit#(esize)) store_epoch [v_sbsize];
    for (Integer i = 0;i<v_sbsize;i = i+1)begin
      store_data[i] <- mkReg(0);
      store_valid[i] <- mkReg(False);
      store_size[i] <- mkReg(0);
      store_addr[i] <- mkReg(0);
      store_epoch[i] <- mkReg(0);
    end
    Reg#(Bit#(TLog#(sbsize))) rg_storehead <- mkReg(0);
    Reg#(Bit#(TLog#(sbsize))) rg_storetail <- mkReg(0);
    Wire#(Bool) wr_store_response <- mkDWire(False);
    Wire#(Bool) wr_allocate_storebuffer <- mkDWire(False);
    Wire#(Bool) wr_store_detected <- mkDWire(False);
    Wire#(Bit#(respwidth)) wr_resp_word <- mkUnsafeDWire(?);

    Wire#(Bit#(respwidth)) wr_sb_hitword <- mkDWire(0);
    Wire#(Bit#(respwidth)) wr_sb_mask <- mkDWire(0);

    Bool sb_full = (all(isTrue, readVReg(store_valid)));
    Bool sb_empty=!(any(isTrue, readVReg(store_valid)));

    rule ignore_fence(ff_core_request.first.fence && sb_empty);
      let req = ff_core_request.first;
      ff_core_request.deq;
      ff_core_response.enq(DMem_core_response{word: ?, trap : False, cause: ?,
                                                  epochs : req.epochs});
    endrule

    rule check_hit_in_storebuffer(ff_core_response.notFull && !ff_core_request.first.fence);
      let req = ff_core_request.first;
      let offset = (v_respwidth == 64) ? 2:1;
      Bit#(paddr) phy_addr;
    `ifdef supervisor
      let pa = ff_from_tlb.first;
      phy_addr = pa.address;
    `else
      phy_addr = truncate(req.address);
    `endif
      Bit#(TLog#(respwidth)) shiftamt1 = {store_addr[rg_storetail - 1][v_wordbits - 1:0], 3'b0};//TODO parameterize for XLEN
      Bit#(respwidth) storemask1 = 0;
      Bit#(respwidth) storemask2 = 0;
      Bool validm1 = store_valid[rg_storetail - 1];
      Bool valid = store_valid[rg_storetail];
      Bit#(TSub#(paddr, wordbits)) wordaddr = truncateLSB(phy_addr);

      Bit#(TSub#(paddr, wordbits)) compareaddr1 = truncateLSB(store_addr[rg_storetail - 1]);
      Bit#(TSub#(paddr, wordbits)) compareaddr2 = truncateLSB(store_addr[rg_storetail]);
      if(compareaddr1 == wordaddr && validm1)begin
        Bit#(respwidth) temp = store_size[rg_storetail - 1] == 0?'hff:
                          store_size[rg_storetail - 1] == 1?'hffff:
                          store_size[rg_storetail - 1] == 2?'hffffffff : '1;
        temp = temp << shiftamt1; 
        storemask1 = temp;  
      end
      if(compareaddr2 == wordaddr && valid)begin
        Bit#(TLog#(respwidth)) shiftamt2 = {store_addr[rg_storetail][v_wordbits - 1:0], 3'b0}; //TODO parameterize for XLEN
        Bit#(respwidth) temp = store_size[rg_storetail] == 0?'hff:
                          store_size[rg_storetail] == 1?'hffff:
                          store_size[rg_storetail] == 2?'hffffffff : '1;
        temp = temp << shiftamt2;
        storemask2 = temp & (~storemask1); // 'h00_00_00_FF
      end
    
      let data1 = storemask1 & store_data[rg_storetail - 1];
      let data2 = storemask2 & store_data[rg_storetail];
      wr_sb_hitword <= data1|data2;
      wr_sb_mask <= storemask1|storemask2;
    endrule

    rule allocate_storebuffer( wr_allocate_storebuffer &&  
                                !ff_core_request.first.fence && !wr_trap);

      let request = ff_core_request.first();
      Bit#(paddr) phy_addr;
    `ifdef supervisor
      let pa = ff_from_tlb.first;
      phy_addr = pa.address;
    `else
      phy_addr = truncate(request.address);
    `endif
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
      store_valid[sbindex] <= True;
      store_size[sbindex] <= truncate(request.size);
      store_addr[sbindex] <= phy_addr;
      store_epoch[sbindex] <= request.epochs;
      rg_storetail <= rg_storetail + 1;
      `logLevel( dcache, 0, $format("DCACHE : Allocating SB. sbindex:%d, data:%h addr:%h", 
                                    sbindex, request.data, phy_addr))
    endrule

    rule respond_to_core((wr_trap || wr_store_detected || wr_nc_response 
                        `ifdef supervisor || wr_tlb_miss `endif ) 
                          && !ff_core_request.first.fence);
      `logLevel( dcache, 0, $format("DCACHE: Responding to Core"))
      let req = ff_core_request.first;
      Bit#(paddr) phy_addr;
      Bit#(respwidth) resp_word = wr_nc_word;
      Bit#(`causesize) cause = req.access == 0?`Load_access_fault : `Store_access_fault;
      Bool trap = (wr_nc_response && wr_nc_err) || wr_trap;
    `ifdef supervisor
      let pa = ff_from_tlb.first;
      `logLevel( dcache, 0, $format("DCACHE: Responding. PA: ",fshow(pa)))
      phy_addr = pa.address;
      if(pa.trap) begin
        cause = pa.cause;
      end
    `else
      phy_addr = truncate(req.address);
    `endif
    `ifdef supervisor
      if(wr_tlb_miss)begin
        ff_hold_request.enq(req);
        ff_core_request.deq;
        ff_from_tlb.deq;
      end
      else
    `endif
      if(trap) begin
        ff_core_response.enq(DMem_core_response{ word:truncate(req.address), trap : True, cause: cause,
                                                 epochs : req.epochs});
        ff_core_request.deq;
      `ifdef supervisor
        ff_from_tlb.deq;
      `endif
      end
      else if(wr_nc_response) begin
      resp_word=
        case (req.size)
          'b000 : signExtend(resp_word[7 : 0]);
          'b001 : signExtend(resp_word[15 : 0]);
          'b010 : signExtend(resp_word[31 : 0]);
          'b100 : zeroExtend(resp_word[7 : 0]);
          'b101 : zeroExtend(resp_word[15 : 0]);
          'b110 : zeroExtend(resp_word[31 : 0]);
          default : resp_word;
        endcase;
      `ifdef supervisor
        if(req.ptwalk_req && !pa.tlbmiss) begin
          ff_ptw_response.enq(DMem_core_response{word : resp_word, trap : pa.trap, cause : pa.cause,
                                                 epochs : req.epochs});
        end
        else
      `endif
        ff_core_response.enq(DMem_core_response{ word: resp_word, trap : False, cause: ?,
                                                   epochs : req.epochs});
        ff_core_request.deq;
      `ifdef atomic
        if(req.access == 2) begin
          wr_allocate_storebuffer <= True;
          wr_resp_word <= wr_nc_word;
        end
      `endif
      `ifdef supervisor
        ff_from_tlb.deq;
      `endif
      end
      else if(wr_store_detected `ifdef supervisor && !pa.tlbmiss `endif ) begin
        ff_core_response.enq(DMem_core_response{ word: ?, trap : False, cause: ?,
                                                   epochs : req.epochs});
        wr_allocate_storebuffer <= True;
        wr_resp_word <= req.data;
        ff_core_request.deq;
      `ifdef supervisor
        ff_from_tlb.deq;
      `endif
      end
    endrule

    rule check_request(!ff_core_request.first.fence && !rg_pending_read && sb_empty );
      let req = ff_core_request.first;
      `logLevel( dcache, 0, $format("DCACHE: Checking Request: ",fshow(req)))
      Bit#(paddr) phy_addr;
      Bool trap = False;
    `ifdef supervisor
      let pa = ff_from_tlb.first;
      `logLevel( dcache, 0, $format("DCAHE: PA: ",fshow(pa)))
      phy_addr = pa.address;
    `else
      phy_addr = truncate(req.address);
    `endif

    `ifdef supervisor
      if(pa.trap) begin
        trap = True;
      end
    `else
      if( valueOf(vaddr) > valueOf(paddr) ) begin
        Bit#(TSub#(vaddr, paddr)) upper_bits = req.address[valueOf(vaddr) - 1: valueOf(paddr)];
        if(|upper_bits == 1)
          trap = True;
      end
    `endif
    `ifdef supervisor
      if(pa.tlbmiss)begin
        wr_tlb_miss <= True;
      end
      else
    `endif
      if(trap) begin
        `logLevel( dcache, 0, $format("DCACHE: Trap generated."))
        wr_trap <= True;
      end
      else if(req.access == 0 `ifdef atomic || req.access == 2 `endif )begin
        ff_read_mem_request.enq(DCache_mem_readreq{address    : phy_addr,
                                                  burst_len  : 0,
                                                  burst_size : zeroExtend(req.size[1:0])});
        `logLevel( dcache, 0, $format("DCACHE : Sending IO Request for Addr:%h", phy_addr))
        rg_pending_read <= True;
      end
      else if(req.access == 1)begin
        wr_store_detected<= True;
        `logLevel( dcache, 0, $format("DCACHE : Allocating IO Write in SB for Addr: %h", phy_addr))
      end
    endrule

    rule receive_nc_response(rg_pending_read);
      let response = ff_read_mem_response.first;
      ff_read_mem_response.deq;
      wr_nc_err <= response.err;
      wr_nc_word <= response.data;
      wr_nc_response <= True;
      `ifdef ASSERT
        dynamicAssert(response.last,"Why is IO response a burst");
      `endif
      rg_pending_read <= False;
    endrule

    interface core_req = interface Put
      method Action put(DCache_core_request#(vaddr, respwidth, esize) req);
        ff_core_request.enq(req);
        `logLevel( dcache, 0, $format("DCACHE : Receiving request: ",fshow(req)))
      endmethod
    endinterface;
    interface core_resp     = toGet(ff_core_response);
    interface read_mem_req  = toGet(ff_read_mem_request);
    interface read_mem_resp = toPut(ff_read_mem_response);

    method DCache_mem_writereq#(paddr, TMul#(wordsize, 8)) write_mem_req_rd;
      return ff_write_mem_request.first;
    endmethod
    method Action write_mem_req_deq;
      ff_write_mem_request.deq;
    endmethod
    method Action perform_store(Bit#(esize) currepoch);
      let addr = store_addr[rg_storehead];
      let data = store_data[rg_storehead];
      let valid = store_valid[rg_storehead];
      let size = store_size[rg_storehead];
      let epoch = store_epoch[rg_storehead];
      Bit#(respwidth) temp = size[1 : 0] == 0?'hFF : 
                             size[1 : 0] == 1?'hFFFF : 
                             size[1 : 0] == 2?'hFFFFFFFF : '1;
      `logLevel( dcache, 0, $format("DCACHE : Performing Store. sbhead:%d addr:%h data:%h",
                                     rg_storehead, addr, data))
      if(epoch == currepoch)begin
          `logLevel( dcache, 1, $format("DCACHE : IO Store Addr:%h Size:%d Data:%h", addr, 
                                         size, data))
          ff_write_mem_request.enq(DCache_mem_writereq{address     : addr,
                                                      burst_len   : 0,
                                                      burst_size  : zeroExtend(size),
                                                      data        : data});
      end
      else begin
        `logLevel( dcache, 0, $format("DCACHE : Dropping Store sbhead:%d",rg_storehead))
      end
      rg_storehead <= rg_storehead + 1;
      store_valid[rg_storehead] <= False;
      `ifdef ASSERT
        dynamicAssert(store_valid[rg_storehead],"Performing Store on invalid entry in SB");
      `endif
    endmethod
    method Action cache_enable(Bool c);
      noAction;
    endmethod
    method cacheable_store = False;
    method cache_available = ff_core_request.notFull && ff_core_response.notFull && !sb_full;
    method storebuffer_empty = sb_empty;
  `ifdef supervisor
    interface ptw_resp      = toGet(ff_ptw_response);
    interface hold_req      = toGet(ff_hold_request);
    interface pa_from_tlb   = toPut(ff_from_tlb);
  `endif
  endmodule
endpackage

