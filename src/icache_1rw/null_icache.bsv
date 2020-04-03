/* 
see LICENSE.incore
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package null_icache;
  import FIFOF :: *;
  import SpecialFIFOs :: *;
  import GetPut :: *;

  import icache_types::*;
  import common_tlb_types :: * ;
  
  `include "icache.defines"
  `include "common_tlb.defines"
  
  interface Ifc_icache#( numeric type wordsize, 
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

    interface Put#(ICache_core_request#(vaddr,esize)) put_core_req;
    interface Get#(IMem_core_response#(TMul#(wordsize,8),esize)) get_core_resp;
    interface Get#(ICache_mem_readreq#(paddr)) get_read_mem_req;
    interface Put#(ICache_mem_readresp#(buswidth)) put_read_mem_resp; 
  `ifdef supervisor
    interface Put#(ITLB_core_response#(paddr)) put_pa_from_tlb;
  `endif
    `ifdef pysimulate
      interface Get#(Bit#(1)) meta;
    `endif
    `ifdef perf
      method Bit#(5) mv_perf_counters;
    `endif
    method Action ma_cache_enable(Bool c);
  endinterface

  module mknull_icache(Ifc_icache#(wordsize,blocksize,sets,ways,paddr,vaddr,fbsize,
                                    esize,dbanks,tbanks,buswidth))
          provisos(
          Mul#(wordsize, 8, respwidth),
          Add#(a__, paddr, vaddr),
          Add#(b__, respwidth, buswidth));        // respwidth is the total bits in a word
    
    
    // This fifo stores the request from the core.
    FIFOF#(ICache_core_request#(vaddr, esize)) ff_core_request <- mkSizedFIFOF(2);
    
    // This fifo stores the response that needs to be sent back to the core.
    FIFOF#(IMem_core_response#(respwidth,esize))ff_core_response <- mkBypassFIFOF();
    
    // The following wire holds the physical address from TLB
    //Wire#(Tuple3#(Bit#(paddr),Bool,Bit#(6))) wr_from_tlb <- mkWire();
    FIFOF#(ITLB_core_response#(paddr)) ff_from_tlb <- mkBypassFIFOF();
    
    // this fifo stores the read request that needs to be sent to the next memory level.
    FIFOF#(ICache_mem_readreq#(paddr)) ff_read_mem_request    <- mkSizedFIFOF(2);
    
    // This fifo stores the response from the next level memory.
    FIFOF#(ICache_mem_readresp#(buswidth)) ff_read_mem_response  <- mkBypassFIFOF();

    Reg#(Bool) rg_pending_read <- mkReg(False);

    `ifdef ifence
      rule ignore_fence(ff_core_request.first.fence);
        ff_core_request.deq;
      endrule
    `endif

    rule check_request(!rg_pending_read `ifdef ifence && !ff_core_request.first.fence `endif );
      let req = ff_core_request.first;
      Bool trap = False;
      Bit#(`causesize) cause = `Inst_access_fault;
      Bit#(paddr) phy_addr;
    `ifdef supervisor
      let pa = ff_from_tlb.first;
      phy_addr = pa.address;
      ff_from_tlb.deq;
      if(pa.trap && !trap) begin
        cause = pa.cause;
        trap = True;
      end
    `else
      if( valueOf(vaddr) > valueOf(paddr) ) begin
        Bit#(TSub#(vaddr, paddr)) upper_bits = req.address[valueOf(vaddr) - 1: valueOf(paddr)];
        if(|upper_bits == 1)
          trap = True;
      end
      phy_addr = truncate(req.address);
    `endif

      if(trap) begin
        ff_core_response.enq(IMem_core_response{word:?, trap: trap, 
                                           cause: cause, epochs:req.epochs});
        ff_core_request.deq;
      end
      else begin
        ff_read_mem_request.enq(ICache_mem_readreq{ address    : phy_addr,
                                                   burst_len  : 0,
                                                   burst_size : 2,
                                                   io: True});
        rg_pending_read <= True;
      end
    endrule

    rule receive_nc_response(rg_pending_read);
      let response = ff_read_mem_response.first;
      let req = ff_core_request.first;
      ff_core_request.deq;
      ff_read_mem_response.deq;
      ff_core_response.enq(IMem_core_response{word:truncate(response.data), trap: response.err, 
                                           cause:`Inst_access_fault, epochs:req.epochs});
      rg_pending_read <=  False;
    endrule

    interface put_core_req = toPut(ff_core_request);
    interface get_core_resp = toGet(ff_core_response);
    interface get_read_mem_req= toGet(ff_read_mem_request);
    interface put_read_mem_resp = toPut(ff_read_mem_response);
  `ifdef supervisor
    interface put_pa_from_tlb = toPut(ff_from_tlb);
  `endif
    method Action ma_cache_enable(Bool c);
      noAction;
    endmethod
  endmodule
endpackage
