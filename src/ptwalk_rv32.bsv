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
package ptwalk_rv32;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import GetPut::*;

  import cache_types::*;
  `include "cache.defines"

  interface Ifc_ptwalk_rv32#(numeric type asid_width);
    interface Put#(DCore_request#(32, 32, `desize )) from_tlb;
                          // ppn   , levels , trap
    interface Get#(Tuple4#(Bit#(32),Bit#(1),Bool, Bit#(6))) to_tlb;
    interface Put#(Bit#(32)) satp_from_csr;
    interface Put#(Bit#(32)) mstatus_from_csr;
    interface Put#(Bit#(2)) curr_priv;
    interface Get#(DCore_request#(32, 32, `desize )) request_to_cache;
                          // data , err
    interface Put#(DCore_response#(TMul#(`dwords,8), `desize )) response_frm_cache;
  endinterface

  typedef enum {ReSendReq, WaitForMemory, GeneratePTE} State deriving(Bits,Eq,FShow);

  module mkptwalk_rv32(Ifc_ptwalk_rv32#(asid_width));
    let verbosity=`VERBOSITY;
    let v_asid_width = valueOf(asid_width);
    let pagesize=12;

    FIFOF#(DCore_request#(32, 32, `desize )) ff_req_queue<-mkSizedFIFOF(2);
    FIFOF#(Tuple4#(Bit#(32),Bit#(1),Bool, Bit#(6))) ff_response<-mkSizedFIFOF(2);
    FIFOF#(DCore_request#(32, 32, `desize )) ff_memory_req<-mkSizedFIFOF(2);
    FIFOF#(DCore_response#(TMul#(`dwords,8), `desize )) ff_memory_response<-mkSizedFIFOF(2);

    // wire which hold the inputs from csr
    Wire#(Bit#(32)) wr_satp <- mkWire();
    Wire#(Bit#(32)) wr_mstatus <- mkWire();
    Wire#(Bit#(2)) wr_priv <- mkWire();
    
    Bit#(22) satp_ppn = truncate(wr_satp);
    Bit#(asid_width) satp_asid = wr_satp[v_asid_width-1+22:22];
    Bit#(1) satp_mode = wr_satp[31];
    Bit#(1) mxr = wr_mstatus[19];
    Bit#(1) sum = wr_mstatus[18];
    Bit#(2) mpp = wr_mstatus[12:11];
    Bit#(1) mprv = wr_mstatus[17];

    // register to hold the level number
    Reg#(Bit#(1)) rg_levels <- mkReg(1);

    // this register is named "a" to keep coherence with the algorithem provided in the spec.
    Reg#(Bit#(34)) rg_a <- mkReg(0);

    Reg#(State) rg_state<- mkReg(GeneratePTE);

    rule resend_core_req_to_cache(rg_state==ReSendReq);
      if(verbosity>2)
       $display($time,"\tPTW: Resending core request: ",fshow(ff_req_queue.first));
      `ifdef atomic
        let {va, sfence, epoch, access, size, data, atomicop,core_ptw} =ff_req_queue.first;
      `else
        let {va, sfence, epoch, access, size, data, core_ptw} =ff_req_queue.first;
      `endif
      `ifdef atomic
        ff_memory_req.enq(tuple8(va, False ,epoch, access, size, data, atomicop, False));
      `else
        ff_memory_req.enq(tuple7(va, False ,epoch, access, size, data, False));
      `endif
        ff_req_queue.deq();
        rg_state<=GeneratePTE;
    endrule

    rule generate_pte(rg_state==GeneratePTE);
      `ifdef atomic
        let {va, sfence, epoch, access, size, data, atomicop,core_ptw} =ff_req_queue.first;
      `else
        let {va, sfence, epoch, access, size, data, core_ptw} =ff_req_queue.first;
      `endif
      if(verbosity>2)
        $display($time,"\tPTW: Recieved Request: ",fshow(ff_req_queue.first));

      Bit#(10) vpn[2];
      vpn[1]=va[31:22];
      vpn[0]=va[21:12];

      Bit#(34) a = rg_levels==1?{satp_ppn,12'b0}:rg_a;

      Bit#(34) pte_address=a+zeroExtend({vpn[rg_levels],2'b0});
      `ifdef atomic
        ff_memory_req.enq(tuple8(truncate(pte_address), False,epoch, 0, 3, ?, ?, True));
      `else
        ff_memory_req.enq(tuple7(truncate(pte_address), False,epoch, 0, 3, ?, True));
      `endif
      rg_state<=WaitForMemory;
    endrule

    rule check_pte(rg_state==WaitForMemory);
      `ifdef atomic
        let {va, sfence, epoch, access, size, data, atomicop,core_ptw} =ff_req_queue.first;
      `else
        let {va, sfence, epoch, access, size, data, core_ptw} =ff_req_queue.first;
      `endif
      Bit#(10) vpn[2];
      vpn[1]=va[31:22];
      vpn[0]=va[21:12];

      if(verbosity>2)
        $display($time,"\tPTW: Received Memory response: ",fshow(ff_memory_response.first),
        " for VA:%h Access:%d Curr_priv:%d",va,access,wr_priv);

      let {pte,err,c,epochn}=ff_memory_response.first();
      ff_memory_response.deq;
      Bit#(10) ppn0=pte[19:10];
      Bit#(12) ppn1=pte[31:20];
      
      Bool fault=False;
      Bit#(6) cause=0;
      Bool trap=False;
      // capture the permissions of the hit entry from the TLBs
      // 7 6 5 4 3 2 1 0
      // D A G U X W R V
      TLB_permissions permissions=bits_to_permission(truncate(pte));
      Bit#(2) priv = mprv==0?wr_priv:mpp;
      if(verbosity>2)
        $display($time,"\tPTW. Permissions: ",fshow(permissions));
      if (!permissions.v || (!permissions.r && permissions.w))begin // access fault generated while doing PTWALK
        fault=True;
      end
      else if(rg_levels==0 && !permissions.r && !permissions.x) begin // level=0 and not leaf PTE
        fault=True;
      end
      else if(permissions.x||permissions.r||permissions.w) begin // valid PTE
        // general
        if(!permissions.a || (!permissions.d && (access==2||access==1)))
          fault=True;

        // for execute access
        if(access == 3  && !permissions.x)
          fault=True;
        if(access == 3  && permissions.x && permissions.u && wr_priv==1)
          fault=True;
        if(access == 3  && permissions.x && !permissions.u && wr_priv==0)
          fault=True;

        // for load access
        if(access == 0 && !permissions.r && (!permissions.x || mxr==0)) // if not readable and not mxr  executable
          fault=True;
        if(access != 3 && priv==1 && permissions.u && sum==0) // supervisor accessing user
          fault=True;
        if(access != 3 && !permissions.u && priv==0)
          fault=True;
        
        // for Store access
        if((access == 2 || access==1) && !permissions.w) // if not readable and not mxr  executable
          fault=True;

        // mis-aligned page fault
        if(rg_levels==1 && ppn0!=0)
          fault=True;
      end

      if(fault || err) begin  
        trap=True;
        if(err)
          cause = access==3?`Inst_access_fault :
                  access==0?`Load_access_fault :`Store_access_fault;
        else if(fault)
          cause = access==3?`Inst_pagefault : 
                      access==0?`Load_pagefault : `Store_pagefault;
        if(verbosity>2)
          $display($time,"\tPTW: Generated Error. Cause:%d",cause);
        if(access!=3)
        `ifdef atomic
          ff_memory_req.enq(tuple8(va, True,epoch, access, size, zeroExtend(cause), ?, True));
        `else
          ff_memory_req.enq(tuple7(va, True,epoch, access, size, zeroExtend(cause), True));
        `endif
        ff_response.enq(tuple4(truncate(pte),rg_levels,trap,cause));
        ff_req_queue.deq();
        rg_state<=GeneratePTE;
        rg_levels<=1;
      end
      else if (!permissions.r && !permissions.x)begin // this pointer to next level
        rg_levels<=rg_levels-1;
        rg_a<={pte[31:10],12'b0};
        rg_state<=GeneratePTE;
        if(verbosity>2)
          $display($time,"\tPTW: Pointer to NextLevel:%h Level:%d",{pte[31:10],12'b0},rg_levels);
      end
      else begin // Leaf PTE found
        ff_response.enq(tuple4(truncate(pte),rg_levels,trap,cause));
        if(verbosity>2)
          $display($time,"\tPTW: Found Leaf PTE:%h levels: %d",pte,rg_levels);
        if(access!=3)
          rg_state<=ReSendReq;
        else begin
          rg_state<=GeneratePTE;
          ff_req_queue.deq;
        end
        rg_levels<=1;
      end
    endrule

    interface from_tlb=interface Put
      method Action put(DCore_request#(32, 32, `desize ) req);
        ff_req_queue.enq(req);
      endmethod
    endinterface;

    interface to_tlb=interface Get
      method ActionValue#(Tuple4#(Bit#(32),Bit#(1),Bool,Bit#(6))) get;
        ff_response.deq;
        return ff_response.first();
      endmethod
    endinterface;

    interface satp_from_csr=interface Put
      method Action put (Bit#(32) satp);
        wr_satp<=satp;
      endmethod
    endinterface;

    interface curr_priv = interface Put
      method Action put (Bit#(2) priv);
        wr_priv<=priv;
      endmethod
    endinterface;
    interface request_to_cache=interface Get
      method ActionValue#(DCore_request#(32, 32, `desize )) get;
        ff_memory_req.deq;
        return ff_memory_req.first();
      endmethod
    endinterface;

    interface response_frm_cache=interface Put
      method Action put (DCore_response#(TMul#(`dwords,8), `desize ) resp);
        ff_memory_response.enq(resp);
      endmethod
    endinterface;
    interface mstatus_from_csr=interface Put
      method Action put (Bit#(32) mstatus);
        wr_mstatus<=mstatus;
      endmethod
    endinterface;
  endmodule

  (*synthesize*)
  module mkinstance(Ifc_ptwalk_rv32#(9));
    let ifc();
    mkptwalk_rv32 _temp(ifc);
    return (ifc);
  endmodule
endpackage
