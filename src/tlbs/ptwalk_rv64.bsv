/* 
see LICENSE.incore
see LICENSE.iitm

Author : Neel Gala
Email id : neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package ptwalk_rv64;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import GetPut::*;

  import dcache_types::*;
  import common_tlb_types :: * ;
  `include "dcache.defines"
  `include "Logger.bsv"

  interface Ifc_ptwalk_rv64#(numeric type asid_width);
    interface Put#(PTWalk_tlb_request#(64)) from_tlb;
    interface Get#(PTWalk_tlb_response#(54, 3)) to_tlb;
    interface Get#(DMem_request#(64, 64, `desize )) request_to_cache;
    interface Put#(DMem_core_response#(TMul#(`dwords, 8),`desize) ) response_frm_cache;
    interface Put#(DCache_core_request#(64, 64, `desize)) hold_req;

    (*always_enabled, always_ready*)
    method Action ma_satp_from_csr (Bit#(64) satp);
    (*always_enabled, always_ready*)
    method Action ma_mstatus_from_csr (Bit#(64) mstatus);
    (*always_enabled, always_ready*)
    method Action ma_curr_priv (Bit#(2) curr_priv);
  endinterface

  typedef enum {ReSendReq, WaitForMemory, GeneratePTE} State deriving(Bits, Eq, FShow);

  module mkptwalk_rv64(Ifc_ptwalk_rv64#(asid_width));
    String ptwalk="";
    let v_asid_width = valueOf(asid_width);
    let pagesize = 12;

    FIFOF#(PTWalk_tlb_request#(64)) ff_req_queue <- mkSizedFIFOF(2);
    FIFOF#(PTWalk_tlb_response#(54, 3)) ff_response <- mkSizedFIFOF(2);
    FIFOF#(DMem_request#(64, 64, `desize )) ff_memory_req <- mkSizedFIFOF(2);
    FIFOF#(DMem_core_response#(TMul#(`dwords, 8),`desize)) ff_memory_response <- mkSizedFIFOF(2);

    FIFOF#(DCache_core_request#(64, 64, `desize)) ff_hold_req <- mkFIFOF1();

    Reg#(Bit#(`desize)) rg_hold_epoch <- mkReg(0);

    // wire which hold the inputs from csr
    Wire#(Bit#(64)) wr_satp <- mkWire();
    Wire#(Bit#(64)) wr_mstatus <- mkWire();
    Wire#(Bit#(2)) wr_priv <- mkWire();
    
    Bit#(44) satp_ppn = truncate(wr_satp);
    Bit#(asid_width) satp_asid = wr_satp[v_asid_width - 1+44 : 44];
    Bit#(4) satp_mode = wr_satp[63 : 60];
    Bit#(1) mxr = wr_mstatus[19];
    Bit#(1) sum = wr_mstatus[18];
    Bit#(2) mpp = wr_mstatus[12 : 11];
    Bit#(1) mprv = wr_mstatus[17];

    // register to hold the level number
    Reg#(Bit#(2)) rg_levels <- mkReg(2);

    // this register is named "a" to keep coherence with the algorithem provided in the spec.
    Reg#(Bit#(56)) rg_a <- mkReg(0);

    Reg#(State) rg_state <- mkReg(GeneratePTE);

    Wire#(Bool) wr_deq_holding_ff <- mkWire();

    function DMem_request#(64, 64, `desize) gen_dcache_packet (PTWalk_tlb_request#(64) req, 
                                                   Bool reqtype, Bool trap, Bit#(`causesize) cause);
      return DMem_request{address     : req.address,
                          epochs      : rg_hold_epoch,
                          size        : 3,
                          access      : 0,
                          fence       : False,
                          writedata   : zeroExtend(cause),
                        `ifdef atomic
                          atomic_op   : ?,
                        `endif
                          sfence      : False,
                          ptwalk_req  : reqtype,
                          ptwalk_trap : trap};
    endfunction

    rule resend_core_req_to_cache(rg_state == ReSendReq);
      `logLevel( ptwalk, 2, $format("PTW : Resending Core request back to DCache: ", 
                                    fshow(ff_hold_req.first)))
      let request = ff_req_queue.first;
      let hold_req = ff_hold_req.first;
      ff_memory_req.enq(DMem_request{address    : hold_req.address,
                                     epochs     : hold_req.epochs,
                                     size       : hold_req.size,
                                     fence      : False,
                                     access     : hold_req.access,
                                     writedata  : hold_req.data,
                                   `ifdef atomic
                                     atomic_op  : hold_req.atomic_op,
                                   `endif
                                     sfence     : False,
                                     ptwalk_req : False,
                                     ptwalk_trap : False});
      ff_req_queue.deq();
      rg_state <= GeneratePTE;
      wr_deq_holding_ff <= True;
    endrule

    rule deq_holding_fifo(wr_deq_holding_ff);
      ff_hold_req.deq;
    endrule

    rule generate_pte(rg_state == GeneratePTE);
      let request = ff_req_queue.first;
      `logLevel( ptwalk, 2, $format("PTW : Recieved Request: ",fshow(ff_req_queue.first)))
      Bit#(9) vpn[3];
      vpn[2] = request.address[38 : 30];
      vpn[1] = request.address[29 : 21];
      vpn[0] = request.address[20 : 12];

      Bit#(2) max_levels = satp_mode == 8?2 : 3;
      Bit#(56) a = rg_levels == max_levels?{satp_ppn, 12'b0}:rg_a;

      Bit#(56) pte_address = a+zeroExtend({vpn[rg_levels], 3'b0});
      
      // re - organize request packet for ptwalk 
      request.address = signExtend(pte_address);

      `logLevel( ptwalk, 2, $format("PTW : Sending PTE - Address to DMEM:%h",pte_address))
      ff_memory_req.enq(gen_dcache_packet(request, True, False,?));
      rg_state <= WaitForMemory;
    endrule

    rule check_pte(rg_state == WaitForMemory);
      let request = ff_req_queue.first;
      Bit#(9) vpn[3];
      vpn[2] = request.address[38 : 30];
      vpn[1] = request.address[29 : 21];
      vpn[0] = request.address[20 : 12];
      `logLevel( ptwalk, 2, $format("PTW : Memory Response: ",fshow(ff_memory_response.first)))
      `logLevel( ptwalk, 2, $format("PTW : For Request: ",fshow(ff_req_queue.first)))

      let response = ff_memory_response.first();
      ff_memory_response.deq;
      Bit#(9) ppn0 = response.word[18 : 10];
      Bit#(9) ppn1 = response.word[27 : 19];
      Bit#(9) ppn2 = response.word[36 : 28];
      
      Bool fault = False;
      Bit#(6) cause = 0;
      Bool trap = False;
      // capture the permissions of the hit entry from the TLBs
      // 7 6 5 4 3 2 1 0
      // D A G U X W R V
      TLB_permissions permissions = bits_to_permission(truncate(response.word));
      Bit#(2) priv = mprv == 0?wr_priv : mpp;
      `logLevel( ptwalk, 2, $format("PTW : Permissions", fshow(permissions)))
      if (!permissions.v || (!permissions.r && permissions.w))begin // access fault generated while doing PTWALK
        fault = True;
      end
      else if(rg_levels == 0 && !permissions.r && !permissions.x) begin // level = 0 and not leaf PTE
        fault = True;
      end
      else if(permissions.x||permissions.r||permissions.w) begin // valid PTE
        // general
        if(!permissions.a || (!permissions.d && (request.access == 2||request.access == 1)))
          fault = True;

        // for execute access
        if(request.access == 3  && !permissions.x)
          fault = True;
        if(request.access == 3  && permissions.x && permissions.u && wr_priv == 1)
          fault = True;
        if(request.access == 3  && permissions.x && !permissions.u && wr_priv == 0)
          fault = True;

        // for load access
        if(request.access == 0 && !permissions.r && (!permissions.x || mxr == 0)) // if not readable and not mxr  executable
          fault = True;
        if(request.access != 3 && priv == 1 && permissions.u && sum == 0) // supervisor accessing user
          fault = True;
        if(request.access != 3 && !permissions.u && priv == 0)
          fault = True;
        
        // for Store access
        if((request.access == 2 || request.access == 1) && !permissions.w) // if not readable and not mxr  executable
          fault = True;

        // mis - aligned page fault
        if((rg_levels == 1 && ppn0 != 0) || (rg_levels == 2 && {ppn1, ppn0}!=0) || (rg_levels == 3 && 
                                                                {ppn2, ppn1, ppn0}!=0) )
          fault = True;
      end

      if(fault || response.trap) begin  
        trap = True;
        if(response.trap)
          cause = request.access == 3?`Inst_access_fault :
                  request.access == 0?`Load_access_fault : `Store_access_fault;
        else if(fault)
          cause = request.access == 3?`Inst_pagefault : 
                      request.access == 0?`Load_pagefault : `Store_pagefault;
        `logLevel( ptwalk, 2, $format("PTW : Generated Error. Cause:%d",cause))
        if(request.access != 3)begin
          ff_memory_req.enq(gen_dcache_packet(request, False, True, cause));
        end
        ff_response.enq(PTWalk_tlb_response{pte : truncate(response.word),
                                        levels  : rg_levels,
                                        trap    : trap,
                                        cause   : cause});
        if(request.access != 3)
           wr_deq_holding_ff <= True;
        ff_req_queue.deq();
        rg_state <= GeneratePTE;
        rg_levels <= satp_mode == 8?2 : 3;
      end
      else if (!permissions.r && !permissions.x)begin // this pointer to next level
        rg_levels <= rg_levels - 1;
        rg_a<={response.word[53 : 10], 12'b0};
        rg_state <= GeneratePTE;
        `logLevel( ptwalk, 2, $format("PTW : Pointer to NextLevel:%h Levels:%d", {response.word[53 : 10], 12'b0}, 
                                      rg_levels))
      end
      else begin // Leaf PTE found
        ff_response.enq(PTWalk_tlb_response{pte     : truncate(response.word),
                                        levels  : rg_levels,
                                        trap    : trap,
                                        cause   : cause});
        `logLevel( ptwalk, 2, $format("PTW : Found Leaf PTE:%h levels: %d", response.word,
                                      rg_levels))
        if(request.access != 3)
          rg_state <= ReSendReq;
        else begin
          rg_state <= GeneratePTE;
          ff_req_queue.deq;
        end
        rg_levels <= satp_mode == 8?2 : 3;
      end
    endrule

    interface from_tlb            = toPut(ff_req_queue);

    interface to_tlb              = toGet(ff_response);
    
    interface hold_req            = interface Put
      method Action put(DCache_core_request#(64, 64, `desize) req);
        rg_hold_epoch<=req.epochs;
        ff_hold_req.enq(req);
      endmethod
    endinterface;

    interface request_to_cache    = toGet(ff_memory_req);

    interface response_frm_cache  = toPut(ff_memory_response);

    method Action ma_satp_from_csr (Bit#(64) satp);
      wr_satp <= satp;
    endmethod

    method Action ma_curr_priv (Bit#(2) priv);
      wr_priv <= priv;
    endmethod

    method Action ma_mstatus_from_csr (Bit#(64) mstatus);
      wr_mstatus <= mstatus;
    endmethod

  endmodule

  (*synthesize*)
  module mkinstance(Ifc_ptwalk_rv64#(9));
    let ifc();
    mkptwalk_rv64 _temp(ifc);
    return (ifc);
  endmodule
endpackage
