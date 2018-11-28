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
This module will implement the Data-TLB for SV32 configuration.

Here the TLBs are implemented as n-way associative structures. Since sv32 supports both regular
pages (4KB) and mega-pages (4MB), indexing into a single TLB will not work. Therefore, we maintain 2
separate TLBs one for regular PTEs and another for mega PTEs.

The code is parameterized to define the size and ways of each TLB differently. 
A hit in the regular TLB gets precedence over a hit in the mega-TLB for the same reques.

The TLBs are implemented as BRAMs rather than RegFile to account for scalability and ASIC
performance.

--------------------------------------------------------------------------------------------------
*/
package dtlb_rv32_bram;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import GetPut::*;
  import BUtils::*;

  import mem_config::*;
  import common_types::*;
  import replacement::*;

  interface Ifc_dtlb_rv32_bram#(
      numeric type reg_size, 
      numeric type mega_size,
      numeric type reg_ways,
      numeric type mega_ways,
      numeric type asid_width);
    interface Put#(Tuple2#(Bit#(32),Bit#(2))) core_req;
    interface Get#(Tuple2#(Bit#(22), Trap_type)) core_resp;

                          // va , type: 0-Execution, 1-Load, 2-Store, 3-Atomic
    interface Get#(Tuple2#(Bit#(32),Bit#(2))) req_to_ptw;
                          // ppn   , levels , trap
    interface Put#(Tuple3#(Bit#(32),Bit#(1),Trap_type)) resp_from_ptw;
    interface Put#(Bit#(32)) satp_from_csr;
    interface Put#(Bit#(2)) curr_priv;
    interface Put#(Tuple2#(Bit#(32),Bit#(32))) fence_tlb;
  endinterface



  module mkdtlb_rv32_bram#(parameter Bool ramreg, parameter String alg_reg, parameter String alg_mega) 
    (Ifc_dtlb_rv32_bram#(reg_size,mega_size,reg_ways,mega_ways,asid_width))
    provisos(
      Add#(a__, TLog#(reg_size), 20),
      Add#(d__, TLog#(mega_size), 10),
      Add#(b__, TLog#(reg_size), TLog#(TMax#(reg_size, mega_size))),
      Add#(c__, TLog#(mega_size), TLog#(TMax#(reg_size, mega_size))),

      // for replacement
      Add#(e__, TLog#(reg_ways), 4),
      Add#(f__, TLog#(mega_ways), 4)
    );

    let v_reg_ways=valueOf(reg_ways);
    let v_mega_ways=valueOf(mega_ways);
    let v_reg_size=valueOf(reg_size);    
    let v_mega_size=valueOf(mega_size);    
    let v_index_bits=valueOf(TLog#(reg_size));
    let v_asid_width = valueOf(asid_width);
    let verbosity=`VERBOSITY;

    // definging the tlb entries and virtual tags for regular pages.
    Ifc_mem_config#(reg_size, 32, 1) tlb_pte_reg [v_reg_ways]; // data array
    // VTAG stores a Valid bit, ASID and  Virtual PN,
    Ifc_mem_config#(reg_size, TAdd#(1,TAdd#(asid_width,20)), 1) tlb_vtag_reg[v_reg_ways]; // data array 
    for(Integer i=0;i<v_reg_ways;i=i+1)begin
      tlb_pte_reg[i]<-mkmem_config_h(ramreg);
      tlb_vtag_reg[i]<-mkmem_config_h(ramreg);
    end
    Ifc_replace#(reg_size,reg_ways) reg_replacement<- mkreplace(alg_reg);
    Reg#(Bit#(TLog#(reg_ways))) reg_replaceway<- mkReg(0);
    
    // defining the tlb entries and virtual tags for mega pages.
    Ifc_mem_config#(mega_size, 32, 1) tlb_pte_mega [v_mega_ways]; // data array
    // VTAG stores a Valid bit, ASID and  Virtual PN,
    Ifc_mem_config#(mega_size, TAdd#(1,TAdd#(asid_width,10)), 1) tlb_vtag_mega [v_mega_ways]; // data array
    for(Integer i=0;i<v_mega_ways;i=i+1)begin
      tlb_pte_mega[i]<-mkmem_config_h(ramreg);
      tlb_vtag_mega[i]<-mkmem_config_h(ramreg);
    end
    Ifc_replace#(mega_size,mega_ways) mega_replacement<- mkreplace(alg_reg);
    Reg#(Bit#(TLog#(mega_ways))) mega_replaceway<- mkReg(0);


    // register to initialize the tlbs on reset.
    Reg#(Bool) rg_init <- mkReg(True);
    Reg#(Bit#(32)) rg_rs1<- mkReg(0);
    Reg#(Bit#(32)) rg_rs2<- mkReg(0);

    // register to index into the tlb during initialization phase.
    Reg#(Bit#(TLog#(TMax#(reg_size,mega_size)))) rg_index <- mkReg(0);

    // wire which hold the inputs from csr
    Wire#(Bit#(32)) wr_satp <- mkWire();
    Wire#(Bit#(2)) wr_priv <- mkWire();

    // local variables extracted from csrs
    Bit#(22) satp_ppn = truncate(wr_satp);
    Bit#(asid_width) satp_asid = wr_satp[v_asid_width-1+22:22];
    Bit#(1) satp_mode = wr_satp[31];

    // FIFO to hold the next input
    FIFOF#(Tuple2#(Bit#(32),Bit#(2))) ff_req_queue <- mkSizedFIFOF(2);
    FIFOF#(Tuple2#(Bit#(32),Bit#(2))) ff_ptw_req <- mkSizedFIFOF(2);
    FIFOF#(Tuple2#(Bit#(22),Trap_type)) ff_core_resp<- mkSizedFIFOF(2);
    Reg#(Bool) rg_tlb_miss<- mkReg(False);
    Reg#(Bool) rg_delay <- mkDReg(False);
    Bool delay_checking= ramreg && rg_delay && ff_req_queue.notFull && ff_req_queue.notEmpty;

    rule initialize(rg_init && !ff_req_queue.notEmpty);
      if(verbosity>0)
        $display($time,"\tITLB: Initiliazing TLB index: %d",rg_index);
      for(Integer i=0;i<v_reg_ways;i=i+1) 
        tlb_pte_reg[i].write_request(truncate(rg_index),'d0);

      for(Integer i=0;i<v_mega_ways;i=i+1) 
        tlb_pte_mega[i].write_request(truncate(rg_index),'d0);

      rg_index<=rg_index+1;
      if(rg_index==fromInteger(v_reg_size-1))
        rg_init<=False;
    endrule

    rule access_tlb_on_request(!rg_tlb_miss && !rg_init && !delay_checking);
      let {va,access}=ff_req_queue.first();
      // capture input vpns for regular and mega pages.
      Bit#(20) inp_vpn_reg=va[31:12];
      Bit#(10) inp_vpn_mega=va[31:22];
      Bit#(10) vpn0=va[21:12];
      Bit#(10) vpn1=va[31:22];

      // find if there is a hit in the regular page tlb
      Bit#(32) pte_reg [v_reg_ways];
      Bit#(20) pte_vpn_reg [v_reg_ways];
      Bit#(asid_width) pte_asid_reg [v_reg_ways];
      Bit#(reg_ways) pte_vpn_valid_reg=0;
      Bit#(reg_ways) hit_reg=0;
      Bit#(32) temp1_reg [v_reg_ways];
      Bit#(32) temp2_reg [v_reg_ways];
      Bit#(32) final_reg_pte=0;
      Bit#(1) global_reg [v_reg_ways];
      for(Integer i=0;i<v_reg_ways;i=i+1) begin
        pte_reg[i]<-tlb_pte_reg[i].read_response();
        let x<-tlb_vtag_reg[i].read_response();
        pte_vpn_reg[i]=truncate(x);
        pte_asid_reg[i]=x[20+v_asid_width-1:20];
        pte_vpn_valid_reg[i]=truncateLSB(x);
        global_reg[i]=pte_reg[i][5];
      end
      for(Integer i=0;i<v_reg_ways;i=i+1)begin
        hit_reg[i]=pack(pte_vpn_valid_reg[i]==1 && pte_vpn_reg[i]==inp_vpn_reg &&
            (pte_asid_reg[i]==satp_asid || global_reg[i]==1)); 
        temp1_reg[i]=duplicate(hit_reg[i]);
        temp2_reg[i]=temp1_reg[i]&pte_reg[i];
      end
      for(Integer i=0;i<v_reg_ways;i=i+1)
        final_reg_pte=temp2_reg[i]|final_reg_pte;
      if(v_reg_ways>1)begin
        let reg_linereplace<-reg_replacement.line_replace(truncate(inp_vpn_reg),pte_vpn_valid_reg);
        reg_replaceway<=reg_linereplace;
      end
      else
        reg_replaceway<=0;
      
      // find if there is a hit in the mega pages.
      Bit#(32) pte_mega [v_mega_ways];
      Bit#(10) pte_vpn_mega [v_mega_ways];
      Bit#(asid_width) pte_asid_mega [v_mega_ways];
      Bit#(mega_ways) pte_vpn_valid_mega=0;
      Bit#(mega_ways) hit_mega=0;
      Bit#(32) temp1_mega [v_mega_ways];
      Bit#(32) temp2_mega [v_mega_ways];
      Bit#(32) final_mega_pte=0;
      Bit#(1) global_mega [v_mega_ways];
      for(Integer i=0;i<v_mega_ways;i=i+1) begin
        pte_mega[i]<-tlb_pte_mega[i].read_response();
        let y<-tlb_vtag_mega[i].read_response();
        pte_vpn_mega[i]=truncate(y);
        pte_asid_mega[i]=y[10+v_asid_width-1:10];
        pte_vpn_valid_mega[i]=truncateLSB(y);
        global_mega[i]=pte_mega[i][5];
      end
      for(Integer i=0;i<v_mega_ways;i=i+1)begin
        hit_mega[i]=pack(pte_vpn_valid_mega[i]==1 && pte_vpn_mega[i]==inp_vpn_mega &&
            (pte_asid_mega[i]==satp_asid || global_mega[i]==1)); 
        temp1_mega[i]=duplicate(hit_mega[i]);
        temp2_mega[i]=temp1_mega[i]&pte_mega[i];
      end
      for(Integer i=0;i<v_mega_ways;i=i+1)
        final_mega_pte=temp2_mega[i]|final_mega_pte;
      if(v_mega_ways>1)begin
        let mega_linereplace<-mega_replacement.line_replace(truncate(inp_vpn_mega),pte_vpn_valid_mega);
        mega_replaceway<=mega_linereplace;
      end
      else
        mega_replaceway<=0;

      // capture the permissions of the hit entry from the TLBs
      // 7 6 5 4 3 2 1 0
      // D A G U X W R V
      Bit#(8) permissions=|(hit_reg)==1?final_reg_pte[7:0]:final_mega_pte[7:0];

      Bit#(22) pte=0;
      if(|(hit_reg)==1)
        pte=truncateLSB(final_reg_pte);
      else
        pte={final_mega_pte[31:20],vpn0};

      // Check for instruction page-fault conditions
      Bool page_fault=False;
      if(satp_mode==0 || wr_priv==3)begin
        ff_core_resp.enq(tuple2(signExtend(va[31:12]),tagged None));
        ff_req_queue.deq();
      end
      else if(|(hit_reg)==1 || |(hit_mega)==1) begin
        // pte.x == 0
        if(permissions[3]==0)
          page_fault=True;
        // pte.a == 0
        else if(permissions[6]==0)
          page_fault=True;
        // pte.u==0 for user mode
        else if(permissions[4]==0 && wr_priv==0)
          page_fault=True;
        // pte.u=1 for supervisor
        else if(permissions[4]==1 && wr_priv==1)
          page_fault=True;

       Trap_type exception=page_fault?tagged Exception Inst_pagefault:tagged None; 
       ff_core_resp.enq(tuple2(pte,exception));
       ff_req_queue.deq;
      end
      else begin
        // Send virtual-address and indicate it is an instruction access to the PTW
        ff_ptw_req.enq(tuple2(va, access));
        rg_tlb_miss<=True;
      end
    endrule

    interface core_req=interface Put
      method Action put (Tuple2#(Bit#(32),Bit#(2)) req) if(!rg_init);
        let {va,access}=req;
        Bit#(12) page_offset=va[11:0];

        // index into the regular page arrays
        Bit#(20) vpn_reg=va[31:12];
        for(Integer i=0;i<v_reg_ways;i=i+1)begin
          tlb_pte_reg[i].read_request(truncate(vpn_reg));
          tlb_vtag_reg[i].read_request(truncate(vpn_reg));
        end

        // index into the mega page arrays
        Bit#(10) vpn_mega=va[31:22];
        for(Integer i=0;i<v_mega_ways;i=i+1)begin
          tlb_pte_mega[i].read_request(truncate(vpn_mega));
          tlb_vtag_mega[i].read_request(truncate(vpn_mega));
        end
        ff_req_queue.enq(req);
        if(ramreg)
          rg_delay<=True;
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

    interface req_to_ptw = interface Get
      method ActionValue#(Tuple2#(Bit#(32),Bit#(2))) get;
        ff_ptw_req.deq;
        return ff_ptw_req.first;
      endmethod
    endinterface;
    interface resp_from_ptw = interface Put
      method Action put(Tuple3#(Bit#(32),Bit#(1),Trap_type) resp)if(rg_tlb_miss && !rg_init);
        // This will then cause the rule access_tlb_on_request to fire again
        // which cause a hit in the tlb now and thus respond back to the core.
        let {va,access}=ff_req_queue.first();
        let {pte, levels, trap}=resp;
        Bit#(20) vpn_reg=va[31:12];
        if(levels==0) begin
            tlb_pte_reg[reg_replaceway].write_request(truncate(vpn_reg),pte);
            tlb_vtag_reg[reg_replaceway].write_request(truncate(vpn_reg),{1'b1,satp_asid,vpn_reg});
            if(v_reg_ways>1)
              reg_replacement.update_set(truncate(vpn_reg),?);//TODO for plru need to send current valids
        end
        else begin
          // index into the mega page arrays
          Bit#(10) vpn_mega=va[31:22];
            tlb_pte_mega[mega_replaceway].write_request(truncate(vpn_mega),pte);
            tlb_vtag_mega[mega_replaceway].write_request(truncate(vpn_mega),{1'b1,satp_asid,vpn_mega});
            if(v_mega_ways>1)
              mega_replacement.update_set(truncate(vpn_mega),?);//TODO for plru need to send current valids
        end
        ff_core_resp.enq(tuple2(truncateLSB(pte),trap));
        ff_req_queue.deq;
        rg_tlb_miss<=True;
      endmethod
    endinterface;
    interface  fence_tlb=interface Put
      method Action put(Tuple2#(Bit#(32),Bit#(32)) req) if(!rg_init);
        rg_init<=True;
      endmethod
    endinterface;

    interface core_resp= interface Get
      method ActionValue#(Tuple2#(Bit#(22),Trap_type)) get;
        ff_core_resp.deq;
        return ff_core_resp.first();
      endmethod
    endinterface;
  endmodule
endpackage

