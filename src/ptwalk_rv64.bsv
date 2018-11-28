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
package ptwalk_rv64;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import GetPut::*;

  import common_types::*;
  import cache_types::*;

  interface Ifc_ptwalk_rv64#(numeric type asid_width);
    interface Put#(Tuple2#(Bit#(64),Bit#(2))) from_tlb;
                          // ppn   , levels , trap
    interface Get#(Tuple3#(Bit#(64),Bit#(2),Trap_type)) to_tlb;
    interface Put#(Bit#(64)) satp_from_csr;
    interface Put#(Bit#(64)) mstatus_from_csr;
    interface Put#(Bit#(2)) curr_priv;
    interface Get#(Bit#(56)) request_to_cache;
                          // data , err, epoch
    interface Put#(Tuple3#(Bit#(64),Bit#(1),Bit#(1))) response_frm_cache;
  endinterface

  typedef enum {WaitForMemory, GeneratePTE} State deriving(Bits,Eq,FShow);

  module mkptwalk_rv64(Ifc_ptwalk_rv64#(asid_width));
    let v_asid_width = valueOf(asid_width);
    let pagesize=12;

    FIFOF#(Tuple2#(Bit#(64),Bit#(2))) ff_req_queue<-mkSizedFIFOF(2);
    FIFOF#(Tuple3#(Bit#(64),Bit#(2),Trap_type)) ff_response<-mkSizedFIFOF(2);
    FIFOF#(Bit#(56)) ff_memory_req<-mkSizedFIFOF(2);
    FIFOF#(Tuple3#(Bit#(64),Bit#(1),Bit#(1))) ff_memory_response<-mkSizedFIFOF(2);

    // wire which hold the inputs from csr
    Wire#(Bit#(64)) wr_satp <- mkWire();
    Wire#(Bit#(64)) wr_mstatus <- mkWire();
    Wire#(Bit#(2)) wr_priv <- mkWire();
    
    Bit#(44) satp_ppn = truncate(wr_satp);
    Bit#(asid_width) satp_asid = wr_satp[v_asid_width-1+44:44];
    Bit#(4) satp_mode = wr_satp[63:60];
    Bit#(1) mxr = wr_mstatus[19];
    Bit#(1) sum = wr_mstatus[18];

    // register to hold the level number
    Reg#(Bit#(2)) rg_levels <- mkReg(2);

    // this register is named "a" to keep coherence with the algorithem provided in the spec.
    Reg#(Bit#(56)) rg_a <- mkReg(0);

    Reg#(State) rg_state<- mkReg(GeneratePTE);

    rule generate_pte(rg_state==GeneratePTE);
      let {va,access}=ff_req_queue.first();

      Bit#(9) vpn[3];
      vpn[2]=va[38:30];
      vpn[1]=va[29:21];
      vpn[0]=va[20:12];

      Bit#(2) max_levels = satp_mode==8?2:3;
      Bit#(56) a = rg_levels==max_levels?{satp_ppn,12'b0}:rg_a;

      Bit#(56) pte_address=a+zeroExtend({vpn[rg_levels],3'b0});
      ff_memory_req.enq(pte_address);
      rg_state<=WaitForMemory;
    endrule

    rule check_pte(rg_state==WaitForMemory);
      let {va,access}=ff_req_queue.first();
      Bit#(9) vpn[3];
      vpn[2]=va[38:30];
      vpn[1]=va[29:21];
      vpn[0]=va[20:12];

      let {pte,err,epoch}=ff_memory_response.first();
      ff_memory_response.deq;
      Bit#(9) ppn0=pte[18:10];
      Bit#(9) ppn1=pte[27:19];
      Bit#(9) ppn2=pte[36:28];
      
      Bool fault=False;
      Trap_type exception=tagged None;
      // capture the permissions of the hit entry from the TLBs
      // 7 6 5 4 3 2 1 0
      // D A G U X W R V
      TLB_permissions permissions=bits_to_permission(truncate(pte));
      if(err ==1) begin
        fault=True;
      end
      else if (permissions.v || (!permissions.r && permissions.w))begin // access fault generated while doing PTWALK
        fault=True;
      end
      else if(rg_levels==0 && !permissions.r && !permissions.x) begin // level=0 and not leaf PTE
        fault=True;
      end
      else if(permissions.x||permissions.r||permissions.w) begin // valid PTE
        // general
        if(!permissions.a || (!permissions.d && access==2))
          fault=True;

        // for execute access
        if(access == 0  && !permissions.x)
          fault=True;
        if(access == 0  && permissions.x && permissions.u && wr_priv==1)
          fault=True;
        if(access == 0  && permissions.x && !permissions.u && wr_priv==0)
          fault=True;

        // for load access
        if(access == 1 && !permissions.r && (!permissions.x || mxr==0)) // if not readable and not mxr  executable
          fault=True;
        if(access != 0 && wr_priv==1 && permissions.u && sum==0) // supervisor accessing user
          fault=True;
        if(access != 0 && !permissions.u && wr_priv==0)
          fault=True;
        
        // for Store access
        if(access == 2 && !permissions.w) // if not readable and not mxr  executable
          fault=True;

        // mis-aligned page fault
        if((rg_levels==1 && ppn0!=0) || (rg_levels==2 && {ppn1,ppn0}!=0) || (rg_levels==3 && 
                                                                {ppn2,ppn1,ppn0}!=0) )
          fault=True;
      end

      if(fault || err==1) begin  
        if(err==1)
          exception = access==0?tagged Exception Inst_access_fault: 
                    access==1?tagged Exception Load_access_fault:
                    tagged Exception Store_access_fault;
        else if(fault)
          exception = access==0?tagged Exception Inst_pagefault: 
                    access==1?tagged Exception Load_pagefault:
                    tagged Exception Store_pagefault;

        ff_response.enq(tuple3(pte,rg_levels,exception));
        ff_req_queue.deq();
        rg_levels<=satp_mode==8?2:3;
      end
      else if (!permissions.r && !permissions.x)begin // this pointer to next level
        rg_levels<=rg_levels-1;
        rg_a<={pte[53:10],12'b0};
        rg_state<=GeneratePTE;
      end
      else begin // Leaf PTE found
        ff_response.enq(tuple3(pte,rg_levels,exception));
        ff_req_queue.deq();
        rg_levels<=satp_mode==8?2:3;
      end
    endrule

    interface from_tlb=interface Put
      method Action put(Tuple2#(Bit#(64),Bit#(2)) req);
        ff_req_queue.enq(req);
      endmethod
    endinterface;

    interface to_tlb=interface Get
      method ActionValue#(Tuple3#(Bit#(64),Bit#(2),Trap_type)) get;
        ff_response.deq;
        return ff_response.first();
      endmethod
    endinterface;

    interface satp_from_csr=interface Put
      method Action put (Bit#(64) satp);
        wr_satp<=satp;
      endmethod
    endinterface;

    interface curr_priv = interface Put
      method Action put (Bit#(2) priv);
        wr_priv<=priv;
      endmethod
    endinterface;
    interface request_to_cache=interface Get
      method ActionValue#(Bit#(56)) get;
        ff_memory_req.deq;
        return ff_memory_req.first();
      endmethod
    endinterface;

    interface response_frm_cache=interface Put
      method Action put (Tuple3#(Bit#(64),Bit#(1),Bit#(1)) resp);
        ff_memory_response.enq(resp);
      endmethod
    endinterface;
    interface mstatus_from_csr=interface Put
      method Action put (Bit#(64) mstatus);
        wr_mstatus<=mstatus;
      endmethod
    endinterface;
  endmodule

  (*synthesize*)
  module mkinstance(Ifc_ptwalk_rv64#(9));
    let ifc();
    mkptwalk_rv64 _temp(ifc);
    return (ifc);
  endmodule
endpackage
