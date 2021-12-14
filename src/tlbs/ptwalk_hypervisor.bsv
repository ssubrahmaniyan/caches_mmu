/* 
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/


package ptwalk_hypervisor;
import Vector::*;
import FIFOF::*;
import DReg::*;
import SpecialFIFOs::*;
import BRAMCore::*;
import FIFO::*;
import GetPut::*;

import dcache_types:: *;
import common_tlb_types :: * ;
`include "dcache.defines"
`include "Logger.bsv"	
`include "common_tlb.defines"



interface Ifc_ptwalk;
  interface Put#(PTWalk_tlb_request#(`vaddr)) from_tlb;	

	//varpages - 2:sv32 | 3:sv39 | 4:sv48
  interface Get#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) to_tlb; 

  interface Get#(DMem_request#(`vaddr, TMul#(`dwords, 8), `desize)) request_to_cache;

  interface Put#(DMem_core_response#(TMul#(`dwords, 8),`desize)) response_frm_cache;

  interface Put#(DCache_core_request#(`vaddr, TMul#(`dwords, 8), `desize)) hold_req;

  (*always_enabled, always_ready*)
  method Action ma_satp_from_csr (Bit#(`xlen) _satp);
  (*always_enabled, always_ready*)
  method Action ma_mstatus_from_csr (Bit#(`xlen) mstatus);
  (*always_enabled, always_ready*)
  method Action ma_curr_priv (Bit#(2) priv);
  
`ifdef hypervisor
  (*always_enabled, always_ready*)
	method Action ma_hgatp_from_csr (Bit#(`xlen) _hgatp);	//similar to satp, for hypervisor
  (*always_enabled, always_ready*)
	method Action ma_hstatus_from_csr (Bit#(`xlen) hstatus); //Hypervisor status reg
  (*always_enabled, always_ready*)
	method Action ma_vs_mode (Bit#(1) v);	//Virt. mode, to enable 2-stage address translation
  (*always_enabled, always_ready*)
	method Action ma_vsatp_from_csr (Bit#(`xlen) vsatp);	 //For VS-stage translation (if v = 1)
  (*always_enabled, always_ready*)
	method Action ma_vsstatus_from_csr(Bit#(`xlen) vsstatus); //swap the contents of S-mode bits of MSTATUS with VSSTATUS on transition
`endif   
endinterface:Ifc_ptwalk

/*First do normal VS Stage translation using satp, if virtual_mode == 0 send the response. 
If virtual_mode ==1 perform stage two tranlation using hgatp.

Assumed hgatp_mode same as satp_mode
Also if hypervisor mode change current privilege mode to USER MODE (wr_priv to 0??)*/

typedef enum {ReSendReq, WaitForMemory, GeneratePTE} State deriving(Bits,Eq,FShow);

typedef struct{
  Bit#(2) levels;
  Bit#(5) idxbits;
  Bit#(2) widenbits;
  Bit#(2) ptesize;
  Bit#(`ppnsize) ptbase;
} VMINFO deriving(Bits, FShow, Eq);

function VMINFO fn_decode_vminfo( Bool stage2, Bit#(2) prv, Bit#(`xlen) satp, Bit#(`xlen) hgatp)
  provisos(Bits#(ptwalk_hypervisor::VMINFO, a__));
  VMINFO _vminfo = unpack(0);
  if (prv == 3)
    _vminfo = unpack(0);
  else if (!stage2 && prv <= 1) begin
  `ifdef sv32
    Bit#(1) satp_mode = truncateLSB(satp);    
    case(satp_mode)
      'd0: _vminfo = unpack(0);
      'd1: _vminfo = {levels: 1, idxbits: 10, widenbits: 0, ptesize: 2, ptbase: truncate(satp)};
    endcase
  `else
    Bit#(4) satp_mode = truncateLSB(satp);    
    case(satp_mode)
      'd0: _vminfo = unpack(0);
      'd8: _vminfo = VMINFO{levels: 2, idxbits: 9, widenbits: 0, ptesize: 3, ptbase: truncate(satp)};
      'd9: _vminfo = VMINFO{levels: 3, idxbits: 9, widenbits: 0, ptesize: 3, ptbase: truncate(satp)};
      /*'d10: _vminfo = VMINFO{levels: 4, idxbits: 9, widenbits: 0, ptesize: 3, ptbase: truncate(satp)};
      'd11: _vminfo = VMINFO{levels: 5, idxbits: 9, widenbits: 0, ptesize: 3, ptbase: truncate(satp)};*/
    endcase
  `endif
  end
  else if (stage2) begin
  `ifdef sv32
    Bit#(1) hgatp_mode = truncateLSB(hgatp);    
    case(hgatp_mode)
      'd0: _vminfo = unpack(0);
      'd1: _vminfo = VMINFO{levels: 1, idxbits: 10, widenbits: 2, ptesize: 2, ptbase: truncate(hgatp)};
    endcase
  `else
    Bit#(4) hgatp_mode = truncateLSB(hgatp);    
    Bit#(44) ppn = truncate(hgatp);
    case(hgatp_mode)
      'd0: _vminfo = unpack(0);
      'd8: _vminfo = VMINFO{levels: 2, idxbits: 9, widenbits: 2, ptesize: 3, ptbase: truncate(hgatp)};
      'd9: _vminfo = VMINFO{levels: 3, idxbits: 9, widenbits: 2, ptesize: 3, ptbase: truncate(hgatp)};
    endcase
  `endif
  end
  return _vminfo;
endfunction: fn_decode_vminfo

(*synthesize*)
module mkptwalk(Ifc_ptwalk);
  String ptwalk="";
  let pagesize=12;

  FIFOF#(PTWalk_tlb_request#(`vaddr)) ff_req_queue <- mkSizedFIFOF(2);

  FIFOF#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) ff_response <- mkSizedFIFOF(2);

  //req. to dcache fifo
  FIFOF#(DMem_request#(`vaddr, TMul#(`dwords, 8), `desize)) ff_memory_req <- mkSizedFIFOF(2);
  
  //response from dcache fifo
  FIFOF#(DMem_core_response#(TMul#(`dwords, 8),`desize)) ff_memory_response <- mkSizedFIFOF(2);

  //Resend core req. after handle of tlb miss
  FIFOF#(DCache_core_request#(`vaddr, TMul#(`dwords, 8), `desize)) ff_hold_req <- mkFIFOF1();

  Reg#(Bit#(`desize)) rg_hold_epoch <- mkReg(0);

  //For G-stage trans. , this is o/p of VS stage trans. (i.e guest phy. addr which  
  Reg#(Bit#(TAdd#(`ppnsize , 12))) rg_gpa <- mkReg(0);

  // wire which hold the inputs from csr
  Wire#(Bit#(`xlen)) wr_satp <- mkWire();
  Wire#(Bit#(`xlen)) wr_mstatus <- mkWire();
  Wire#(Bit#(2)) wr_priv <- mkWire();
 
  //wires for hypervisor
  Wire#(Bit#(`xlen)) wr_hgatp <- mkWire();
  Wire#(Bit#(`xlen)) wr_hstatus <- mkWire();
  Wire#(Bit#(1)) wr_vs_mode <- mkWire();
  Wire#(Bit#(`xlen)) wr_vsatp <- mkWire();
  Wire#(Bit#(`xlen)) wr_vsstatus <- mkWire();

  // register to hold the level number.1-sv32 | 2-sv39 | 3-sv48
  Reg#(Bit#(2)) rg_levels <- mkReg(`varpages - 1);		

  //1-sv32x4  2-sv39x4  3-sv48x4
  Reg#(Bit#(2)) rg_levels_vs <- mkReg(`varpages - 1);  	

  // indicates if the stage2 translation is active
  Reg#(Bool) rg_stage2 <- mkReg(False);
  Reg#(Bool) rg_vs_trans <- mkReg(False); 			//Indicates if in VS-Stage (F) or in G-Stage (T)

  // this register is named "a" to keep coherence with the algorithem provided in the spec.
  //Page size is 12
  Reg#(Bit#(TAdd#(`ppnsize , `pagesize))) rg_a <- mkReg(0);

  Reg#(State) rg_state<- mkReg(GeneratePTE);

  Wire#(Bool) wr_deq_holding_ff <- mkWire();
  
 
  // mux for new satp that needs to be used
  Bit#(`xlen) satp = (wr_vs_mode==1) ? wr_vsatp : wr_satp;
  Bit#(`xlen) status = (wr_vs_mode==1) ? wr_vsstatus : wr_mstatus; 
  
  Bit#(`ppnsize) satp_ppn = truncate(satp);	//Phy. page no. of root page table

  Bit#(`asidwidth) satp_asid = satp[`asidwidth-1 + `ppnsize : `ppnsize];
  Bit#(`modesz) satp_mode = truncateLSB(satp);

`ifdef hypervisor 
  Bit#(`ppnsize) hgatp_ppn = truncate(wr_hgatp);   //Phy. page no. of root page table
  Bit#(TSub#(`asidwidth,2)) hgatp_vmid = wr_hgatp[`asidwidth-3 + `ppnsize : `ppnsize];  //vmid = asid-2
  Bit#(`modesz) hgatp_mode = truncateLSB(wr_hgatp); 	   //1-sv32x4
`endif
  /*The vsstatus field MXR, which makes execute-only pages readable, only overrides VS-stage page
    protection. Setting MXR at VS-level does not override guest-physical page protections. Setting
    MXR at HS-level, however, overrides both VS-stage and G-stage execute-only permissions. */
  Bit#(1) mxr = rg_stage2?wr_mstatus[19]: (wr_mstatus | (wr_vs_mode==1?wr_vsstatus:0))[19];  //As per QEMU-H extension 
  Bit#(1) sum = status[18];  //As per QEMU-H extension 
  Bit#(2) mpp = wr_mstatus[12:11];
  Bit#(1) mprv = wr_mstatus[17];
  Bool s_mode = wr_priv == 1;
//HSTATUS?//

  function DMem_request#(`vaddr, TMul#(`dwords, 8), `desize) gen_dcache_packet (PTWalk_tlb_request#(`vaddr) req, 
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
                      `ifdef hypervisor
                        hfence      : False,
                      `endif
                        sfence      : False,
                        ptwalk_req  : reqtype,
                        ptwalk_trap : trap};
  endfunction


  rule resend_core_req_to_cache(rg_state==ReSendReq);
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
                                `ifdef hypervisor
                                   hfence     : False,
                                `endif
                                   sfence     : False,
                                   ptwalk_req : False,
                                   ptwalk_trap : False});
    ff_req_queue.deq();
    rg_state<=GeneratePTE;
    wr_deq_holding_ff <= True;
  endrule

  rule deq_holding_fifo(wr_deq_holding_ff);
    ff_hold_req.deq;
  endrule

  rule generate_pte(rg_state==GeneratePTE);
    
    let request = ff_req_queue.first;
    `logLevel( ptwalk, 2, $format("PTW : Processing Core Request: ",fshow(ff_req_queue.first)))
    `logLevel( pt, 0, $format("PTW: satp:%h hgatp:%h vs_mode:%b vs_trans:%b status:%h rg_levels:%d",satp,
                            wr_hgatp,wr_vs_mode,rg_stage2,status,rg_levels))
    
    Bit#(TAdd#(`subvpn,2)) gpa[`varpages];		//extend by 2 bits
    //V mode and 1st (VS) stage over (i.e rg_vs_trans = TRUE), now G stage
    for (Integer i = 0; i<`varpages; i = i + 1) begin
      if (i== (`varpages-1))
        gpa[i] = rg_gpa[pagesize + (i+1)*`subvpn + 1: pagesize + i*`subvpn];
      else
        gpa[i] = {2'b0,(rg_gpa[pagesize + (i+1)*`subvpn - 1: pagesize + i*`subvpn])};
    end

    Bit#(`subvpn) vpn[`varpages];
    for(int k=0; k<`varpages ; k=k+1)
      vpn[k] = request.address[pagesize + (k+1)*`subvpn - 1 : pagesize + (k)*`subvpn];

    let vminfo = fn_decode_vminfo(rg_stage2, wr_priv, satp, wr_hgatp);
    `logLevel( ptwalk, 0, $format("PTW: VMINFO:",fshow(vminfo)))
  
    Bit#(`maxpaddr) a = (rg_levels == vminfo.levels)?{vminfo.ptbase,12'b0} : rg_a;
    Bit#(`maxpaddr) pte_address = a + (rg_stage2?(zeroExtend(gpa[rg_levels])<<vminfo.ptesize):
                                      (zeroExtend(vpn[rg_levels])<<vminfo.ptesize));
    request.address = signExtend(pte_address);
    `logLevel( ptwalk, 2, $format("PTW : Sending PTE - Address to DMEM:%h",pte_address))
    ff_memory_req.enq(gen_dcache_packet(request, True, False,?));
    rg_state<=WaitForMemory;
  endrule:generate_pte

  rule check_pte(rg_state==WaitForMemory);
    let request = ff_req_queue.first;
    Bit#(TAdd#(`subvpn,2)) gpa[`varpages];		//extend by 2 bits
    //V mode and 1st (VS) stage over (i.e rg_vs_trans = TRUE), now G stage
    for (Integer i = 0; i<`varpages; i = i + 1) begin
      if (i== (`varpages-1))
        gpa[i] = rg_gpa[pagesize + (i+1)*`subvpn + 1: pagesize + i*`subvpn];
      else
        gpa[i] = {2'b0, rg_gpa[pagesize + (i+1)*`subvpn - 1: pagesize + i*`subvpn]};
    end

    Bit#(`subvpn) vpn[`varpages];
    for(int k=0; k<`varpages ; k=k+1)
      vpn[k] = request.address[pagesize + (k+1)*`subvpn - 1 : pagesize + (k)*`subvpn];
    
    `logLevel( ptwalk, 2, $format("PTW : Memory Response: ",fshow(ff_memory_response.first)))
    `logLevel( ptwalk, 2, $format("PTW : For Request: ",fshow(ff_req_queue.first)))

    let response = ff_memory_response.first();	
    ff_memory_response.deq;
    let pte = response.word;
    
    Bit#(`subvpn) ppn0 = pte[10 + `subvpn - 1 : 10];	//10bits-rv32, 9bits-rv64
    
  `ifdef RV32
    Bit#(`lastppnsize) ppn1 = response.word[10 + `subvpn + `lastppnsize - 1 : 10 + `subvpn];
  `elsif RV64
    Bit#(`subvpn) ppn1 = response.word[10 + 2*`subvpn - 1 : 10 + `subvpn];
  `endif
    Bit#(`subvpn) ppn2 = response.word[10 + 3*`subvpn - 1 : 10 + 2*`subvpn];
    Bit#(`subvpn) ppn3 = response.word[10 + 4*`subvpn - 1 : 10 + 3*`subvpn];

    let vminfo = fn_decode_vminfo(rg_stage2, wr_priv, satp, wr_hgatp);
    `logLevel( ptwalk, 0, $format("PTW: VMINFO:",fshow(vminfo)))
    	
    Bool fault = False;
    Bit#(`causesize) cause = 0;  
    Bool trap = False;

    Bit#(2) lv_levels = rg_levels;

    // capture the permissions of the hit entry from the TLBs
    // 7 6 5 4 3 2 1 0
    // D A G U X W R V
    TLB_permissions permissions=bits_to_permission(truncate(pte));

    Bit#(2) priv = rg_stage2?0 : mprv == 0?wr_priv: mpp;

    `logLevel( ptwalk, 2, $format("PTW : Permissions", fshow(permissions)))

  `ifdef RV64
    if (pte[63:54]  != 0) // reserved bits are set
      fault = True;
    else
  `endif

    if (!permissions.v || (!permissions.r && permissions.w)) begin // access fault generated while doing PTWALK
      fault=True;
    end
    else if(lv_levels==0 && !permissions.r && !permissions.x) begin // level=0 and not leaf PTE
      fault=True;
    end
    else if(permissions.x||permissions.r||permissions.w) begin // valid PTE
      // general
      if(!permissions.a || (!permissions.d && (request.access==2 || request.access==1)))
        fault=True;

      // for execute access
      if(request.access == 3  && !permissions.x)
        fault=True;
      if(request.access == 3  && permissions.x && permissions.u && wr_priv==1)
        fault=True;
      if(request.access == 3  && permissions.x && !permissions.u && wr_priv == 0)
        fault=True;

      // for load access
      if(request.access == 0 && !permissions.r && (!permissions.x || mxr == 0)) // if not readable and not mxr  executable
        fault=True;
      if(request.access != 3 && priv == 1 && permissions.u && sum == 0) // supervisor accessing user
        fault=True;
      if(request.access != 3 && !permissions.u && priv == 0)
        fault=True;
      
      // for Store access
      if((request.access == 2 || request.access == 1) && !permissions.w) // if not readable and not mxr  executable
        fault=True;
        
    `ifdef RV32
      // mis-aligned page fault
      if(lv_levels == 1 && ppn0!=0)
        fault=True;
      // mis - aligned page fault
    `elsif RV64
      `ifdef sv39		
	 	  if((lv_levels == 1 && ppn0 != 0) || (lv_levels == 2 && {ppn1, ppn0}!=0) || 
	 	                                  (lv_levels == 3 && {ppn2, ppn1, ppn0}!=0) )
  	  	fault = True;
     	`elsif sv48	
	    if((lv_levels == 1 && ppn0 != 0) || (lv_levels == 2 && {ppn1, ppn0}!=0) || (lv_levels == 3 && 
	  	                                   {ppn2, ppn1, ppn0}!=0) || (lv_levels == 4 && {ppn3, ppn2, ppn1, ppn0}!=0) )
	  	  fault = True;
      `endif
    `endif
    end


    if (vminfo.levels == 0 || (rg_stage2 && wr_vs_mode==0)) begin
   	  ff_response.enq(PTWalk_tlb_response{pte     : truncate(rg_gpa),
	                                levels  : lv_levels,
	                                trap    : False,
	                                cause   : ?});
      ff_req_queue.deq();
      rg_state<=GeneratePTE;
      rg_stage2 <= False;
    `ifdef RV32
      lv_levels=1;
    `elsif RV64
      lv_levels = satp_mode == 8?2 : 3;
      `logLevel( ptwalk, 0, $format("PTW: Sending response to TLB"))
    end
    else if(fault || response.trap) begin  
      trap=True;
      if(response.trap)
        cause = request.access == 3?`Inst_access_fault :
                request.access == 0?`Load_access_fault : `Store_access_fault;
      else if(fault) begin
         if(rg_stage2)	 	//If V mode, guest page fault exceptions need to be raised
          cause = request.access == 3?`Inst_guest_pagefault : 
                      request.access == 0?`Load_guest_pagefault : `Store_guest_pagefault;
         else
          cause = request.access == 3?`Inst_pagefault : 
                      request.access == 0?`Load_pagefault : `Store_pagefault;          
      end
      `logLevel( ptwalk, 2, $format("PTW : Generated Error. Cause:%d",cause))
      
      if(request.access != 3) begin
        ff_memory_req.enq(gen_dcache_packet(request, False, True, cause));
        wr_deq_holding_ff <= True;
      end

      ff_response.enq(PTWalk_tlb_response{pte : truncate(response.word),
                                      levels  : lv_levels,
                                      trap    : trap,
                                      cause   : cause});
      ff_req_queue.deq();
      rg_state<=GeneratePTE;
      rg_stage2 <= False;
    `ifdef RV32
      lv_levels=1;
    `elsif RV64
      lv_levels = satp_mode == 8?2 : 3;
    `endif
    end
    else if (!permissions.r && !permissions.x) begin // this pointer to next level
      lv_levels=lv_levels-1;
      Bit#(TAdd#(`ppnsize , 12)) temp = {response.word[10 + `ppnsize - 1:10],12'b0}; //temp of size same as rg_a
      rg_a<=temp;
      rg_state<=GeneratePTE;
      `logLevel( ptwalk, 2, $format("PTW : Pointer to NextLevel:%h Levels:%d", temp, lv_levels))
    end
    
    else begin // Leaf PTE found
    /*If no vs_mode(Only vs-stage), the obtained response is final response, send through ff_response
    If vs_mode, now need to perform G-stage using this response (stored in rg_gpa). 
    For this set rg_vs_trans to true, now hgatp reg is used for address translation and rg_levels_vs for levels
    */
    	if((wr_vs_mode==1) &&(rg_stage2==False)) begin	//Hyp.
        let vminfo2 = fn_decode_vminfo(True, wr_priv, satp, wr_hgatp);
        `logLevel( ptwalk, 0, $format("PTW: VMINFO2:",fshow(vminfo)))
    	  Bit#(TAdd#(`ppnsize , 12)) temp1 = {response.word[10 + `ppnsize - 1:10],12'b0}; //temp1 of size same as rg_a
        if (vminfo2.levels == 0) begin
   	      let tlb_resp = PTWalk_tlb_response{pte     : truncate(response.word),
	                                            levels  : lv_levels,
	                                            trap    : False,
	                                            cause   : ?};
	        ff_response.enq(tlb_resp);
	        `logLevel( ptwalk, 0, $format("PTW: Sending response to from Stage1 TLB:",temp1))
      	  if(request.access != 3)
      	    rg_state<=ReSendReq;
      	  else begin
      	    rg_state<=GeneratePTE;
      	    ff_req_queue.deq;
      	  end
	      end
	      else begin
    	    rg_stage2<= True;
          rg_gpa<=temp1; 	//rg_gpa ,for next stage 
          rg_state<=GeneratePTE;
          `logLevel( ptwalk, 2, $format("PTW : (Second Stage) Pointer to NextLevel:%h Levels:%d", temp1, lv_levels))
        end
      `ifdef RV32
        lv_levels=1;
      `elsif RV64
        lv_levels = satp_mode == 8?2 : 3;
      `endif
    	end
    	else begin	//No hyp.
    	  ff_response.enq(PTWalk_tlb_response{pte     : truncate(response.word),
	                                levels  : lv_levels,
	                                trap    : trap,
	                                cause   : cause});
      	`logLevel( ptwalk, 2, $format("PTW : Found Leaf PTE:%h levels: %d", response.word,
	                              lv_levels))
      	if(request.access != 3)
      	  rg_state<=ReSendReq;
      	else begin
      	  rg_state<=GeneratePTE;
      	  ff_req_queue.deq;
      	end
      `ifdef RV32
      	lv_levels=1;
      `elsif RV64
      	lv_levels = satp_mode == 8?2 : 3;
      `endif
      	 rg_stage2 <= False;
      end
    end
    rg_levels<=lv_levels;
//    if(wr_vs_mode==1 && rg_vs_trans)  rg_levels_vs <= lv_levels;	
  endrule

  interface from_tlb            = toPut(ff_req_queue);

  interface to_tlb              = toGet(ff_response);
  
  interface hold_req            = interface Put
    method Action put(DCache_core_request#(`vaddr, TMul#(`dwords, 8), `desize) req);
      rg_hold_epoch<=req.epochs;
      ff_hold_req.enq(req);
    endmethod
  endinterface;

  interface request_to_cache    = toGet(ff_memory_req);

  interface response_frm_cache  = toPut(ff_memory_response);

  method Action ma_satp_from_csr (Bit#(`vaddr) _satp);
    wr_satp <= _satp;
  endmethod

  method Action ma_curr_priv (Bit#(2) priv);
    wr_priv <= priv;
  endmethod

  method Action ma_mstatus_from_csr (Bit#(`vaddr) mstatus);
    wr_mstatus <= mstatus;
  endmethod
  
  `ifdef hypervisor
    method Action ma_hgatp_from_csr (Bit#(`vaddr) _hgatp);
      wr_hgatp <= _hgatp;
    endmethod
    
    method Action ma_hstatus_from_csr (Bit#(`vaddr) hstatus);
      wr_hstatus <= hstatus;
    endmethod
    
    method Action ma_vs_mode (Bit#(1) v);	//To enable 2-stage translation
      wr_vs_mode <= v;
    endmethod
    
    method Action ma_vsatp_from_csr (Bit#(`vaddr) vsatp);
      wr_vsatp <= vsatp;
    endmethod
    
    method Action ma_vsstatus_from_csr (Bit#(`vaddr) vsstatus);
      wr_vsstatus <= vsstatus;
    endmethod
  `endif    
endmodule:mkptwalk

/*(*synthesize*)
module mkinstance(Ifc_ptwalk_hypervisor#(9));
  let ifc();
  mkptwalk_hypervisor _temp(ifc);
  return (ifc);
endmodule*/
endpackage
