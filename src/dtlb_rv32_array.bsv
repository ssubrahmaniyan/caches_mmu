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

The TLBs are implemented as array of registers.

--------------------------------------------------------------------------------------------------
*/
package dtlb_rv32_array;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import FIFO::*;
  import GetPut::*;
  import BUtils::*;

  import mem_config::*;
  import replacement::*;
  import cache_types::*;
  `include "cache.defines"
  `include "Logger.bsv"

  interface Ifc_dtlb_rv32_array#(
      numeric type paddr,
      numeric type reg_size, 
      numeric type mega_size,
      numeric type reg_ways,
      numeric type mega_ways,
      numeric type asid_width);
    interface Put#(DTLB_core_request#(32)) core_req;
    interface Get#(DTLB_core_response#(paddr)) core_resp;

    interface Get#(PTWalk_tlb_request#(32)) req_to_ptw;
    interface Put#(PTWalk_tlb_response#(32, 2)) resp_from_ptw;
    interface Put#(Bit#(32)) satp_from_csr;
    interface Put#(Bit#(32)) mstatus_from_csr;
    interface Put#(Bit#(2)) curr_priv;
  `ifdef pmp
    method Action pmp_cfg (Vector#(`PMPSIZE, Bit#(8)) pmpcfg);
    method Action pmp_addr(Vector#(`PMPSIZE, Bit#(paddr)) pmpadr);
  `endif
    method Bool tlb_available;
  endinterface



  module mkdtlb_rv32_array#(parameter String alg_reg, parameter String alg_mega) 
    (Ifc_dtlb_rv32_array#(paddr, reg_size,mega_size,reg_ways,mega_ways,asid_width))
    provisos(
      Add#(a__, TLog#(reg_size), 20),
      Add#(d__, TLog#(mega_size), 10),
      Add#(b__, paddr, 34),
      Add#(c__, paddr, 32),

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
  `ifdef pmp
    function Tuple2#(Bool,Bit#(6)) pmp_check (Array#(Bit#(8)) cfg, Array#(Bit#(paddr)) pmpaddr,
                                Bit#(paddr) phy_addr, Bit#(2) priv);
      Bool sucess=True;
      Bit#(6) cause = 0;
      //Bit#(TSub#(paddr,2)) comp_addr = truncateLSB(paddr);
      for(Integer i=0;i<valueOf(`PMPSIZE ); i=i+1)begin
        Bit#(1) x = cfg[i][2];
        Bit#(2) a = cfg[i][4:3];
        Bit#(1) l = cfg[i][7];
        Bool valid_acess = (l==0 && (priv==3 || x==1)) || (l==1 && x==1);

        Bit#(paddr) tor_top = pmpaddr[i];
        Bit#(paddr) tor_base = (i==0)?0:pmpaddr[i-1];
        if(a==1)begin // TOR:
          if(tor_base<=phy_addr && phy_addr<tor_top)
            sucess=valid_acess&&sucess;
        end
        else if(a==3)begin // NAPOT
          
        end
      end
      return (tuple2(!sucess,cause));
    endfunction
  `endif
    // definging the tlb entries and virtual tags for regular pages.
    Reg#(Bit#(32)) tlb_pte_reg [v_reg_ways][v_reg_size];
    Reg#(Bit#(TAdd#(asid_width,20))) tlb_vtag_reg [v_reg_ways][v_reg_size];
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
    Reg#(Bit#(32)) tlb_pte_mega [v_mega_ways][v_mega_size]; // data array
    // VTAG stores a Valid bit, ASID and  Virtual PN,
    Reg#(Bit#(TAdd#(asid_width,10))) tlb_vtag_mega [v_mega_ways][v_mega_size]; // data array
    for(Integer i=0;i<v_mega_ways;i=i+1)begin
      for(Integer j=0;j<v_mega_size;j=j+1)begin
        tlb_pte_mega[i][j]<-mkReg(0);
        tlb_vtag_mega[i][j]<-mkReg(0);
      end
    end
    Ifc_replace#(mega_size,mega_ways) mega_replacement<- mkreplace(alg_reg);
    Reg#(Bit#(TLog#(mega_ways))) mega_replaceway<- mkReg(0);



    // -------------- Common data structures and resources across TLBs ----------- //
    // register to initialize the tlbs on reset.
    Reg#(Bool) rg_init <- mkReg(False);
    Reg#(Bit#(32)) rg_rs1<- mkReg(0);
    Reg#(Bit#(32)) rg_rs2<- mkReg(0);

    // wire which hold the inputs from csr
    Wire#(Bit#(32)) wr_satp <- mkWire();
    Wire#(Bit#(32)) wr_mstatus <- mkWire();
    Wire#(Bit#(2)) wr_priv <- mkWire();

    // local variables extracted from csrs
    Bit#(22) satp_ppn = truncate(wr_satp);
    Bit#(asid_width) satp_asid = wr_satp[v_asid_width-1+22:22];
    Bit#(1) satp_mode = wr_satp[31];
    Bit#(1) mxr = wr_mstatus[19];
    Bit#(1) sum = wr_mstatus[18];
    Bit#(2) mpp = wr_mstatus[12:11];
    Bit#(1) mprv = wr_mstatus[17];

    // FIFO to hold the next input
    Reg#(Tuple2#(Bit#(32), Bit#(2))) ff_req_queue <- mkReg(?);
    FIFOF#(Tuple5#(Bit#(paddr), Bit#(2), Bool, Bit#(`causesize), Bool)) ff_translated <- mkSizedFIFOF(2);
    FIFOF#(PTWalk_tlb_request#(32)) ff_ptw_req <- mkSizedFIFOF(2);
    FIFOF#(DTLB_core_response#(paddr)) ff_core_resp <- mkBypassFIFOF();
    Reg#(Bool) rg_tlb_miss<- mkReg(False);
    // -------------------------------------------------------------------------- //

  `ifdef pmp
    Vector#(`PMPSIZE, Wire#(Bit#(8))) wr_pmp_cfg <- replicateM(mkWire());
    Vector#(`PMPSIZE, Wire#(Bit#(paddr))) wr_pmp_addr <- replicateM(mkWire());
  `endif

    rule initialize(rg_init && !rg_tlb_miss && !ff_translated.notEmpty);
      for(Integer i=0;i<v_reg_ways;i=i+1) 
        for(Integer j=0;j<v_reg_size;j=j+1)
          tlb_pte_reg[i][j]<='d0;

      for(Integer k=0;k<v_mega_ways;k=k+1) 
        for(Integer l=0;l<v_mega_size;l=l+1)
          tlb_pte_mega[k][l]<='d0;
      rg_init<=False;
    endrule

    rule perform_pmp_check(!rg_init);
      `logLevel( dtlb, 0, $format("DTLB: Sending PA: ", fshow(ff_translated.first)))
      let {pa,access,trap,cause, miss} = ff_translated.first;
      // TODO: perform PMP check here
      ff_core_resp.enq(DTLB_core_response{address   : pa, 
                                          trap      : trap, 
                                          cause     : cause, 
                                          tlbmiss   : miss});
      ff_translated.deq;
    endrule

    interface core_req=interface Put
      method Action put (DTLB_core_request#(32) req) if(!rg_init);
      Bool init_tlb = !req.ptwalk_req && req.sfence;
      `logLevel( dtlb, 0, $format("DTLB: Received Request: ",fshow(req)))
      // capture input vpns for regular and mega pages.
      Bit#(20) inp_vpn_reg=req.address[31:12];
      Bit#(10) inp_vpn_mega=req.address[31:22];
      Bit#(10) vpn0=req.address[21:12];
      Bit#(10) vpn1=req.address[31:22];
      Bit#(12) page_offset = req.address[11:0];

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

      Bit#(TLog#(reg_size)) index_reg=truncate(inp_vpn_reg);
      for(Integer i=0;i<v_reg_ways;i=i+1) begin
        pte_reg[i]=tlb_pte_reg[i][index_reg];
        let x=tlb_vtag_reg[i][index_reg];
        pte_vpn_reg[i]=truncate(x);
        pte_asid_reg[i]=x[20+v_asid_width-1:20];
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
      Bit#(32) pte_mega [v_mega_ways];
      Bit#(10) pte_vpn_mega [v_mega_ways];
      Bit#(asid_width) pte_asid_mega [v_mega_ways];
      Bit#(mega_ways) pte_vpn_valid_mega=0;
      Bit#(mega_ways) hit_mega=0;
      Bit#(32) temp1_mega [v_mega_ways];
      Bit#(32) temp2_mega [v_mega_ways];
      Bit#(32) final_mega_pte=0;
      Bit#(1) global_mega [v_mega_ways];
      Bit#(TLog#(mega_size)) index_mega=truncate(inp_vpn_mega);
      for(Integer i=0;i<v_mega_ways;i=i+1) begin
        pte_mega[i]=tlb_pte_mega[i][index_mega];
        let y=tlb_vtag_mega[i][index_mega];
        pte_vpn_mega[i]=truncate(y);
        pte_asid_mega[i]=y[10+v_asid_width-1:10];
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

      // capture the permissions of the hit entry from the TLBs
      // 7 6 5 4 3 2 1 0
      // D A G U X W R V
      TLB_permissions permissions=|(hit_reg)==1?bits_to_permission(final_reg_pte[7:0]):
                                                bits_to_permission(final_mega_pte[7:0]);

      Bit#(22) physical_address=0;
      if(|(hit_reg)==1)
        physical_address=truncateLSB(final_reg_pte);
      else
        physical_address={final_mega_pte[31:20],vpn0};
      
      Bit#(10) ppn0=physical_address[9:0];
      Bit#(12) ppn1=physical_address[21:10];

      // Check for instruction page-fault conditions
      Bool page_fault=False;
      Bit#(6) cause=req.access==0?`Load_pagefault:`Store_pagefault;
      Bit#(2) priv = mprv==0?wr_priv:mpp;
      if(!init_tlb)begin
        // transparent translation
        if(req.ptwalk_trap)begin
          cause = req.cause;
          page_fault=True;
          ff_translated.enq(tuple5(truncate({physical_address, page_offset}), req.access, page_fault, cause ,
                                                                                            False));
          `logLevel( dtlb, 2, $format("DTLB: Forwarding Trap from PTW"))
          if(rg_tlb_miss) begin
            rg_tlb_miss<=False;
          end
        end
        else if(satp_mode == 0 || priv == 3 || req.ptwalk_req)begin
          Bit#(paddr) coreresp = truncate(req.address);
          ff_translated.enq(tuple5(signExtend(coreresp),req.access,False, req.access==0?`Load_access_fault :
                                                           `Store_access_fault , False ));
          `logLevel( dtlb, 0, $format("DTLB: Transparent Translation. PA:%h",coreresp))
        end
        else if(|(hit_reg)==1 || |(hit_mega)==1) begin
          // pte.a==0 || pte.d==0 and access!=Load
          if(!permissions.a || (!permissions.d && req.access != 0))begin
            page_fault=True;
          end
          if(req.access == 0 && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
            page_fault=True;
          end
          if(priv==1 && permissions.u && sum==0)begin // supervisor accessing user
            page_fault=True;
          end
          if(!permissions.u && priv==0)begin
            page_fault=True;
          end
          
          // for Store access
          if(req.access != 0 && !permissions.w)begin // if not readable and not mxr  executable
          page_fault=True;
          end

          ff_translated.enq(tuple5(truncate({physical_address, page_offset}), req.access, page_fault, cause ,
                                                                                            False));
          if(rg_tlb_miss) begin
            rg_tlb_miss<=False;
          end
        end
        else begin
          // Send virtual-address and indicate it is an instruction access to the PTW
          `logLevel( dtlb, 0, $format("DTLB: Miss. "))
          ff_ptw_req.enq(PTWalk_tlb_request{address : req.address, access : req.access });
          rg_tlb_miss<=True;
          ff_req_queue <= (tuple2(req.address, req.access));
          ff_translated.enq(tuple5(truncate({physical_address, page_offset}), req.access, page_fault, cause, True));
        end
      end
      else begin
        `logLevel( dtlb, 0, $format("DTLB: Received Sfence"))
        rg_init<=True;
        if(rg_tlb_miss && !req.ptwalk_req)
          rg_tlb_miss<=False;
      end
      endmethod
    endinterface;

    interface satp_from_csr=interface Put
      method Action put (Bit#(32) satp);
        wr_satp<=satp;
      endmethod
    endinterface;
    
    interface mstatus_from_csr=interface Put
      method Action put (Bit#(32) mstatus);
        wr_mstatus<=mstatus;
      endmethod
    endinterface;

    interface curr_priv = interface Put
      method Action put (Bit#(2) priv);
        wr_priv<=priv;
      endmethod
    endinterface;

    interface req_to_ptw = interface Get
      method ActionValue#(PTWalk_tlb_request#(32)) get;
        ff_ptw_req.deq;
        return ff_ptw_req.first;
      endmethod
    endinterface;
    interface resp_from_ptw = interface Put
      method Action put(PTWalk_tlb_response#(32, 2) resp)if(!rg_init);
        let {va,access}=ff_req_queue;
        `logLevel( dtlb, 0, $format("DTLB: from PTW: ",fshow(resp)))
        Bit#(20) vpn_reg=va[31:12];
        Bit#(TLog#(reg_size)) index_reg=truncate(vpn_reg);
        
        Bit#(10) vpn_mega=va[31:22];
        Bit#(TLog#(mega_size)) index_mega=truncate(vpn_mega);

        Bit#(10) vpn0=va[21:12];

        if(!resp.trap)begin
          if(resp.levels == 0) begin
              `logLevel( dtlb, 1, $format("DTLB: Updating Reg"))
              tlb_pte_reg[reg_replaceway][index_reg] <= resp.pte;
              tlb_vtag_reg[reg_replaceway][index_reg]<={satp_asid,vpn_reg};
              if(v_reg_ways>1)
                reg_replacement.update_set(truncate(vpn_reg),?);//TODO for plru need to send current valids
          end
          else begin
              `logLevel( dtlb, 1, $format("DTLB: Updating Mega"))
            // index into the mega page arrays
              tlb_pte_mega[mega_replaceway] [index_mega] <= resp.pte;
              tlb_vtag_mega[mega_replaceway][index_mega]<={satp_asid,vpn_mega};
              if(v_mega_ways>1)
                mega_replacement.update_set(truncate(vpn_mega),?);//TODO for plru need to send current valids
          end
        end
      endmethod
    endinterface;
    interface core_resp= interface Get
      method ActionValue#(DTLB_core_response#(paddr)) get;
        ff_core_resp.deq;
        return ff_core_resp.first();
      endmethod
    endinterface;
  `ifdef pmp
    method Action pmp_cfg (Vector#(`PMPSIZE, Bit#(8)) pmpcfg);
      for(Integer i=0;i<valueOf(`PMPSIZE) ;i=i+1)
        wr_pmp_cfg[i] <= pmpcfg[i];
    endmethod
    method Action pmp_addr(Vector#(`PMPSIZE, Bit#(paddr)) pmpadr);
      for(Integer i=0;i<valueOf(`PMPSIZE) ;i=i+1)
        wr_pmp_addr[i] <= pmpadr[i];
    endmethod
  `endif
    method tlb_available=!rg_tlb_miss && ff_translated.notFull;

  endmodule
endpackage

