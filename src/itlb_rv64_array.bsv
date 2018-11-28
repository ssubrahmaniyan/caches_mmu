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
This module will implement the TLB for SV32 configuration.

Here the TLBs are implemented as n-way associative structures. Since sv32 supports both regular
pages (4KB) and mega-pages (4MB), indexing into a single TLB will not work. Therefore, we maintain 2
separate TLBs one for regular PTEs and another for mega PTEs.

The code is parameterized to define the size and ways of each TLB differently. 
A hit in the regular TLB gets precedence over a hit in the mega-TLB for the same reques.

The TLBs are implemented as array of registers.

--------------------------------------------------------------------------------------------------
*/
package itlb_rv64_array;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import FIFO::*;
  import GetPut::*;
  import BUtils::*;

  import mem_config::*;
  import common_types::*;
  import replacement::*;

  interface Ifc_itlb_rv64_array#(
      numeric type reg_size, 
      numeric type mega_size,
      numeric type giga_size,
      numeric type reg_ways,
      numeric type mega_ways,
      numeric type giga_ways,
      numeric type asid_width);
    interface Put#(Bit#(64)) core_req;
    interface Get#(Tuple2#(Bit#(44), Trap_type)) core_resp;

                          // va , type: 0-Execution, 1-Load, 2-Store, 3-Atomic
    interface Get#(Tuple2#(Bit#(64),Bit#(2))) req_to_ptw;
                          // ppn   , levels , trap
    interface Put#(Tuple3#(Bit#(54),Bit#(2),Trap_type)) resp_from_ptw;
    interface Put#(Bit#(64)) satp_from_csr;
    interface Put#(Bit#(2)) curr_priv;
    interface Put#(Tuple2#(Bit#(64),Bit#(64))) fence_tlb;
  endinterface



  module mkitlb_rv64_array#(parameter String alg_reg, parameter String alg_mega) 
    (Ifc_itlb_rv64_array#(reg_size,mega_size,giga_size,reg_ways,mega_ways,giga_ways,asid_width))
    provisos(
      Add#(a__, TLog#(reg_size), 27),
      Add#(b__, TLog#(mega_size), 18),
      Add#(c__, TLog#(giga_size), 9),

      // for replacement
      Add#(d__, TLog#(reg_ways), 4),
      Add#(e__, TLog#(mega_ways), 4),
      Add#(f__, TLog#(giga_ways), 4)
    );

    let v_reg_ways=valueOf(reg_ways);
    let v_mega_ways=valueOf(mega_ways);
    let v_giga_ways=valueOf(giga_ways);
    let v_reg_size=valueOf(reg_size);    
    let v_mega_size=valueOf(mega_size);    
    let v_giga_size=valueOf(giga_size);    
    let v_asid_width = valueOf(asid_width);
    let verbosity=`VERBOSITY;

    // defining the tlb entries and virtual tags for regular pages.
    Reg#(Bit#(54)) tlb_pte_reg [v_reg_ways][v_reg_size];
    Reg#(Bit#(TAdd#(asid_width,27))) tlb_vtag_reg [v_reg_ways][v_reg_size];
    // VTAG stores a Valid bit, ASID and  Virtual PN,
    for(Integer i=0;i<v_reg_ways;i=i+1)begin
      for(Integer j=0;j<v_reg_size;j=j+1)begin
        tlb_pte_reg[i][j]<-mkReg(0);
        tlb_vtag_reg[i][j]<-mkReg(0);
      end
    end
    Ifc_replace#(reg_size,reg_ways) reg_replacement<- mkreplace(alg_reg);
    Reg#(Bit#(TLog#(reg_ways))) reg_replaceway<- mkReg(0);
    
    // defining the tlb entries and virtual tags for mega pages.
    Reg#(Bit#(54)) tlb_pte_mega [v_mega_ways][v_mega_size]; // data array
    // VTAG stores a Valid bit, ASID and  Virtual PN,
    Reg#(Bit#(TAdd#(asid_width,18))) tlb_vtag_mega [v_mega_ways][v_mega_size]; // data array
    for(Integer i=0;i<v_mega_ways;i=i+1)begin
      for(Integer j=0;j<v_mega_size;j=j+1)begin
        tlb_pte_mega[i][j]<-mkReg(0);
        tlb_vtag_mega[i][j]<-mkReg(0);
      end
    end
    Ifc_replace#(mega_size,mega_ways) mega_replacement<- mkreplace(alg_reg);
    Reg#(Bit#(TLog#(mega_ways))) mega_replaceway<- mkReg(0);

    // defining the tlb entries and virtual tags for giga pages.
    Reg#(Bit#(54)) tlb_pte_giga [v_giga_ways][v_giga_size]; // data array
    // VTAG stores a Valid bit, ASID and  Virtual PN,
    Reg#(Bit#(TAdd#(asid_width,9))) tlb_vtag_giga [v_giga_ways][v_giga_size]; // data array
    for(Integer i=0;i<v_giga_ways;i=i+1)begin
      for(Integer j=0;j<v_giga_size;j=j+1)begin
        tlb_pte_giga[i][j]<-mkReg(0);
        tlb_vtag_giga[i][j]<-mkReg(0);
      end
    end
    Ifc_replace#(giga_size,giga_ways) giga_replacement<- mkreplace(alg_reg);
    Reg#(Bit#(TLog#(giga_ways))) giga_replaceway<- mkReg(0);


    // -------------- Common data structures and resources across TLBs ----------- //
    // register to initialize the tlbs on reset.
    Reg#(Bool) rg_init <- mkReg(False);
    Reg#(Bit#(32)) rg_rs1<- mkReg(0);
    Reg#(Bit#(32)) rg_rs2<- mkReg(0);

    // wire which hold the inputs from csr
    Wire#(Bit#(64)) wr_satp <- mkWire();
    Wire#(Bit#(2)) wr_priv <- mkWire();

    // local variables extracted from csrs
    Bit#(44) satp_ppn = truncate(wr_satp);
    Bit#(asid_width) satp_asid = wr_satp[v_asid_width-1+44:44];
    Bit#(4) satp_mode = wr_satp[63:60];

    // FIFO to hold the next input
    FIFOF#(Bit#(64)) ff_req_queue <- mkSizedFIFOF(2);
    FIFOF#(Tuple2#(Bit#(64),Bit#(2))) ff_ptw_req <- mkSizedFIFOF(2);
    FIFOF#(Tuple2#(Bit#(44),Trap_type)) ff_core_resp<- mkSizedFIFOF(2);
    Reg#(Bool) rg_tlb_miss<- mkReg(False);
    // -------------------------------------------------------------------------- //

    rule initialize(rg_init && !ff_req_queue.notEmpty);
      $display($time,"\tITLB: Initiliazing TLB");
      for(Integer i=0;i<v_reg_ways;i=i+1) 
        for(Integer j=0;j<v_reg_size;j=j+1)
          tlb_vtag_reg[i][j]<='d0;

      for(Integer k=0;k<v_mega_ways;k=k+1) 
        for(Integer l=0;l<v_mega_size;l=l+1)
          tlb_vtag_mega[k][l]<='d0;
      
      for(Integer m=0;m<v_giga_ways;m=m+1) 
        for(Integer n=0;n<v_giga_size;n=n+1)
          tlb_vtag_giga[m][n]<='d0;
      rg_init<=False;
    endrule

    rule access_tlb_on_request(!rg_tlb_miss && !rg_init);

      // capture input vpns for regular and mega pages.
      Bit#(27) inp_vpn_reg=ff_req_queue.first()[38:12];
      Bit#(18) inp_vpn_mega=ff_req_queue.first()[38:21];
      Bit#(9) inp_vpn_giga=ff_req_queue.first()[38:30];

      Bit#(9) vpn0=ff_req_queue.first()[20:12];
      Bit#(9) vpn1=ff_req_queue.first()[29:21];
      Bit#(9) vpn2=ff_req_queue.first()[38:30];

      // find if there is a hit in the regular page tlb
      Bit#(54) pte_reg [v_reg_ways];
      Bit#(27) pte_vpn_reg [v_reg_ways];
      Bit#(asid_width) pte_asid_reg [v_reg_ways];
      Bit#(reg_ways) pte_vpn_valid_reg=0;
      Bit#(reg_ways) hit_reg=0;
      Bit#(54) temp1_reg [v_reg_ways];
      Bit#(54) temp2_reg [v_reg_ways];
      Bit#(54) final_reg_pte=0;
      Bit#(1) global_reg [v_reg_ways];

      Bit#(TLog#(reg_size)) index_reg=truncate(inp_vpn_reg);
      for(Integer i=0;i<v_reg_ways;i=i+1) begin
        pte_reg[i]=tlb_pte_reg[i][index_reg];
        let x=tlb_vtag_reg[i][index_reg];
        pte_vpn_reg[i]=truncate(x);
        pte_asid_reg[i]=x[27+v_asid_width-1:27];
        pte_vpn_valid_reg[i]=pte_reg[i][0];
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
      Bit#(54) pte_mega [v_mega_ways];
      Bit#(18) pte_vpn_mega [v_mega_ways];
      Bit#(asid_width) pte_asid_mega [v_mega_ways];
      Bit#(mega_ways) pte_vpn_valid_mega=0;
      Bit#(mega_ways) hit_mega=0;
      Bit#(54) temp1_mega [v_mega_ways];
      Bit#(54) temp2_mega [v_mega_ways];
      Bit#(54) final_mega_pte=0;
      Bit#(1) global_mega [v_mega_ways];
      Bit#(TLog#(mega_size)) index_mega=truncate(inp_vpn_mega);
      for(Integer i=0;i<v_mega_ways;i=i+1) begin
        pte_mega[i]=tlb_pte_mega[i][index_mega];
        let y=tlb_vtag_mega[i][index_mega];
        pte_vpn_mega[i]=truncate(y);
        pte_asid_mega[i]=y[18+v_asid_width-1:18];
        pte_vpn_valid_mega[i]=pte_mega[i][0];
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

      // find if there is a hit in the giga pages.
      Bit#(54) pte_giga [v_giga_ways];
      Bit#(9) pte_vpn_giga [v_giga_ways];
      Bit#(asid_width) pte_asid_giga [v_giga_ways];
      Bit#(giga_ways) pte_vpn_valid_giga=0;
      Bit#(giga_ways) hit_giga=0;
      Bit#(54) temp1_giga [v_giga_ways];
      Bit#(54) temp2_giga [v_giga_ways];
      Bit#(54) final_giga_pte=0;
      Bit#(1) global_giga [v_giga_ways];
      Bit#(TLog#(giga_size)) index_giga=truncate(inp_vpn_giga);
      for(Integer i=0;i<v_giga_ways;i=i+1) begin
        pte_giga[i]=tlb_pte_giga[i][index_giga];
        let y=tlb_vtag_giga[i][index_giga];
        pte_vpn_giga[i]=truncate(y);
        pte_asid_giga[i]=y[9+v_asid_width-1:9];
        pte_vpn_valid_giga[i]=pte_giga[i][0];
        global_giga[i]=pte_giga[i][5];
      end
      for(Integer i=0;i<v_giga_ways;i=i+1)begin
        hit_giga[i]=pack(pte_vpn_valid_giga[i]==1 && pte_vpn_giga[i]==inp_vpn_giga &&
            (pte_asid_giga[i]==satp_asid || global_giga[i]==1)); 
        temp1_giga[i]=duplicate(hit_giga[i]);
        temp2_giga[i]=temp1_giga[i]&pte_giga[i];
      end
      for(Integer i=0;i<v_giga_ways;i=i+1)
        final_giga_pte=temp2_giga[i]|final_giga_pte;
      if(v_giga_ways>1)begin
        let giga_linereplace<-giga_replacement.line_replace(truncate(inp_vpn_giga),pte_vpn_valid_giga);
        giga_replaceway<=giga_linereplace;
      end
      else
        giga_replaceway<=0;
      // capture the permissions of the hit entry from the TLBs
      // 7 6 5 4 3 2 1 0
      // D A G U X W R V
      Bit#(8) permissions=|(hit_reg)==1?final_reg_pte[7:0]:|(hit_mega)==1?final_mega_pte[7:0]:
                                                                          final_giga_pte[7:0];

      Bit#(44) physical_address=0;
      if(|(hit_reg)==1)
        physical_address=truncateLSB(final_reg_pte);
      else if(|(hit_mega)==1)
        physical_address={final_mega_pte[53:19],vpn0};
      else
        physical_address={final_giga_pte[53:28],vpn1,vpn0};

      Bit#(9) ppn0=physical_address[8:0];
      Bit#(9) ppn1=physical_address[17:9];
      Bit#(26) ppn2=physical_address[43:18];
      // Check for instruction page-fault conditions
      Bool page_fault=False;
      Bit#(25) unused_va=ff_req_queue.first()[63:39];
      // if the upper bits of the virtual address are not signextend versions of bit 38 then fault.
      if(unused_va!=signExtend(ff_req_queue.first()[38])) begin
        Trap_type exception=tagged Exception Inst_pagefault; 
        ff_core_resp.enq(tuple2(physical_address,exception));
        ff_req_queue.deq;
      end
      // transparent translation
      else if(satp_mode==0 || wr_priv==3)begin
        ff_core_resp.enq(tuple2(signExtend(ff_req_queue.first()[38:12]),tagged None));
        ff_req_queue.deq();
      end
      else if(|(hit_reg)==1 || |(hit_mega)==1 || |(hit_giga)==1 ) begin
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
        else if( (|(hit_mega)==1 && ppn0!=0) || (|(hit_giga)==1 && {ppn1,ppn0}!=0) )
          page_fault=True;

        Trap_type exception=page_fault?tagged Exception Inst_pagefault:tagged None; 
        ff_core_resp.enq(tuple2(physical_address,exception));
        ff_req_queue.deq;
      end
      else begin
        // Send virtual-address and indicate it is an instruction access to the PTW
        ff_ptw_req.enq(tuple2(ff_req_queue.first(), 0));
        rg_tlb_miss<=True;
      end
    endrule

    interface core_req=interface Put
      method Action put (Bit#(64) va) if(!rg_init);
        Bit#(12) page_offset=va[11:0];

        ff_req_queue.enq(va);
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

    interface req_to_ptw = interface Get
      method ActionValue#(Tuple2#(Bit#(64),Bit#(2))) get;
        ff_ptw_req.deq;
        return ff_ptw_req.first;
      endmethod
    endinterface;
    interface resp_from_ptw = interface Put
      method Action put(Tuple3#(Bit#(54),Bit#(2),Trap_type) resp)if(rg_tlb_miss && !rg_init);
        // This will then cause the rule access_tlb_on_request to fire again
        // which cause a hit in the tlb now and thus respond back to the core.
        let {pte, levels, trap}=resp;
        let va=ff_req_queue.first();
        Bit#(27) vpn_reg=ff_req_queue.first[38:12];
        Bit#(TLog#(reg_size)) index_reg=truncate(vpn_reg);
        
        Bit#(18) vpn_mega=ff_req_queue.first[38:21];
        Bit#(TLog#(mega_size)) index_mega=truncate(vpn_mega);

        Bit#(9) vpn_giga=ff_req_queue.first[38:30];
        Bit#(TLog#(giga_size)) index_giga=truncate(vpn_giga);

        if(trap matches tagged None)begin
          if(levels==0) begin
              tlb_pte_reg[reg_replaceway][index_reg]<=pte;
              tlb_vtag_reg[reg_replaceway][index_reg]<={satp_asid,vpn_reg};
              if(v_reg_ways>1)
                reg_replacement.update_set(truncate(vpn_reg),?);//TODO for plru need to send current valids
          end
          else if(levels==1)begin
            // index into the mega page arrays
              tlb_pte_mega[mega_replaceway] [index_mega]<=pte;
              tlb_vtag_mega[mega_replaceway][index_mega]<={satp_asid,vpn_mega};
              if(v_mega_ways>1)
                mega_replacement.update_set(truncate(vpn_mega),?);//TODO for plru need to send current valids
          end
          else begin
            // index into the giga page arrays
              tlb_pte_giga[giga_replaceway] [index_giga]<=pte;
              tlb_vtag_giga[giga_replaceway][index_giga]<={satp_asid,vpn_giga};
              if(v_giga_ways>1)
                giga_replacement.update_set(truncate(vpn_giga),?);//TODO for plru need to send current valids
          end
        end
        Bit#(44) physical_address=0;
        Bit#(9) vpn0=va[20:12];
        Bit#(9) vpn1=va[29:21];
        Bit#(9) vpn2=va[38:30];
        if(levels==0)
          physical_address=truncateLSB(pte);
        else if(levels==1)
          physical_address={pte[53:19],vpn0};
        else
          physical_address={pte[53:28],vpn1,vpn0};
        ff_core_resp.enq(tuple2(physical_address,trap));
        ff_req_queue.deq;
        rg_tlb_miss<=True;
      endmethod
    endinterface;
    interface  fence_tlb=interface Put
      method Action put(Tuple2#(Bit#(64),Bit#(64)) req) if(!rg_init);
        rg_init<=True;
      endmethod
    endinterface;

    interface core_resp= interface Get
      method ActionValue#(Tuple2#(Bit#(44),Trap_type)) get;
        ff_core_resp.deq;
        return ff_core_resp.first();
      endmethod
    endinterface;
  endmodule
endpackage

