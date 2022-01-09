/*
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package fa_dtlb_hypervisor;
  `include "Logger.bsv"
  `include "common_tlb.defines"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import Vector :: * ;
  import common_tlb_types:: * ;
  import GetPut :: * ;

  // structure of the virtual tag for fully-associative look-up
  typedef struct{
    TLB_permissions permissions;
    Bit#(`vpnsize) vpn;
    Bit#(`asidwidth) asid;
    Bit#(TMul#(TSub#(`varpages,1), `subvpn)) pagemask;
    Bit#(`ppnsize) ppn;
    Bit#(1) vs_bit;	//Adding V bit to Stage1 TLB which will help to differentiate between HS/U-mode and VS/VU-mode translation 
  } VPNTag deriving(Bits, FShow, Eq);

  typedef struct{
    Bool trap;
    Bit#(`causesize) cause;
    Bool tlbmiss;
    Bool translation_done;
    Bit#(`vaddr) va;
    VPNTag pte;
    Bit#(2) access;
    Bit#(2) prv;
  `ifdef hypervisor
    Bit#(1)           virt;
    Bit#(1)           hlvx;
  `endif
  } LookUpResult deriving(Bits, FShow, Eq);

  interface Ifc_fa_dtlb;

    interface Put#(DTLB_core_request#(`vaddr)) put_core_request;
    interface Get#(DTLB_core_response#(`paddr)) get_core_response;

    interface Get#(PTWalk_tlb_request#(`vaddr)) get_request_to_ptw;
    interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) put_response_frm_ptw;

    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(`vaddr) s);

    /*doc:method: method to receive the current values of the mstatus register*/
    method Action ma_mstatus_from_csr (Bit#(`vaddr) m);
    
  `ifdef hypervisor
   	method Action ma_vsatp_from_csr (Bit#(`vaddr) vsatp);	//For VS-stage translation (if v = 1)
   	method Action ma_vsstatus_from_csr (Bit#(`vaddr) vsstatus);
  `endif
    /*doc:method: */
    method Bool mv_tlb_available;
  `ifdef perfmonitors
    method Bit#(1) mv_perf_counters;
  `endif
  endinterface:Ifc_fa_dtlb

  /*doc:module: */
  (*synthesize*)
  (*conflict_free="put_response_frm_ptw_put, put_core_request_put"*)
    module mkfa_dtlb#(parameter Bit#(32) hartid) (Ifc_fa_dtlb);
    Vector#( `dtlbsize, Reg#(VPNTag) ) v_vpn_tag <- replicateM(mkReg(unpack(0))) ;

    /*doc:reg: register to indicate which entry need to be filled/replaced*/
    Reg#(Bit#(TLog#(`dtlbsize))) rg_replace <- mkReg(0);
    /*doc:wire: wire holding the latest value of the satp csr*/
    Wire#(Bit#(`vaddr)) wr_satp <- mkWire();
    /*doc:wire: wire holds the current privilege mode of the core*/
    Wire#(Bit#(2)) wr_priv <- mkWire();
    /*doc:wire: wire holding the current values of mstatus fields*/
    Wire#(Bit#(`vaddr)) wr_mstatus <- mkWire();
    //Wires for V-mode
    Wire#(Bit#(`vaddr)) wr_vsatp <- mkWire();
    Wire#(Bit#(`vaddr)) wr_vsstatus <- mkWire();
    /*doc:reg: */
    Reg#(Bit#(`vaddr)) rg_miss_queue <- mkReg(0);
    FIFOF#(PTWalk_tlb_request#(`vaddr)) ff_request_to_ptw <- mkSizedFIFOF(2);
    FIFOF#(LookUpResult) ff_lookup_result <- mkSizedFIFOF(2);
    FIFOF#(DTLB_core_response#(`paddr)) ff_core_response <- mkBypassFIFOF();
    
    /*doc:reg: register to indicate that a tlb miss is in progress*/
    Reg#(Bool) rg_tlb_miss <- mkReg(False);

    /*doc:reg: register to indicate the tlb is undergoing an sfence*/
    Reg#(Bool) rg_sfence <- mkReg(False);
    
    `ifdef hypervisor
     /*register to indicate the tlb is undergoing an hfence*/
    Reg#(Bool) rg_hfence <- mkReg(False);   
     `endif
     
  `ifdef perfmonitors
    /*doc:wire: */
    Wire#(Bit#(1)) wr_count_misses <- mkDWire(0);
  `endif

    /*doc:rule: this rule is fired when the core requests a sfence. This rule will simply invalidate
     all the tlb entries, (even those with vs_bit=1?)*/
    rule rl_fence( (rg_sfence `ifdef hypervisor || rg_hfence `endif ) && !rg_tlb_miss && !ff_lookup_result.notEmpty);
      for (Integer i = 0; i < `dtlbsize; i = i + 1) begin
        v_vpn_tag[i] <= unpack(0);
      end
      rg_replace <= 0;
      if (rg_sfence) begin
        `logLevel( dtlb, 1, $format("[%2d]DTLB: SFencing Now",hartid))
        rg_sfence <= False;
      end
    `ifdef hypervisor
      if (rg_hfence) begin
        `logLevel( dtlb, 1, $format("[%2d]DTLB: HFencing Now",hartid))
        rg_hfence <= False;
      end
    `endif
    endrule:rl_fence
    
    /*`ifdef hypervisor
	    [>For Hypervisor: This rule is fired when the core requests a hfence. This rule will simply invalidate
	     all the stage1 tlb entries having vs_bit=1 in TLB tag<]
	    rule rl_hfence(rg_hfence && !rg_tlb_miss && !ff_lookup_result.notEmpty);
	      for (Integer i = 0; i < `dtlbsize; i = i + 1) begin
 	      	if(v_vpn_tag[i].vs_bit==1)
		        v_vpn_tag[i] <= unpack(0);
	      end
	      rg_hfence <= False;
	      rg_replace <= 0;  //Which to replace ???
	      `logLevel( dtlb, 1, $format("[%2d]DTLB: HFencing Now",hartid))
	    endrule
     `endif*/
	    
    /*doc:rule: */
    rule rl_send_response(!rg_sfence `ifdef hypervisor && !rg_hfence `endif );
      let lookup = ff_lookup_result.first;
      ff_lookup_result.deq;

      Bit#(`vaddr) satp_new = (lookup.virt==1) ? wr_vsatp : wr_satp;
      Bit#(`vaddr) status_new = (lookup.virt==1) ? wr_vsstatus : wr_mstatus;   //As per QEMU-H extension 
      // global variables based on the above wires
      Bit#(`asidwidth) satp_asid = satp_new[`asidwidth - 1 + `ppnsize : `ppnsize ];
    `ifdef sv32
      Bit#(1) satp_mode = truncateLSB(satp_new);
    `else
      Bit#(4) satp_mode = truncateLSB(satp_new);
    `endif
      Bit#(1) mxr = status_new[19];	//As per QEMU-H extension 
      Bit#(1) sum = status_new[18];	//As per QEMU-H extension 

      Bit#(12) page_offset = lookup.va[11 : 0];
      Bit#(`vpnsize) fullvpn = truncate(lookup.va >> 12);
      `logLevel( dtlb, 1, $format("[%2d]DTLB: LookupResult: ",hartid,fshow(lookup)))
      if(lookup.translation_done)begin
        ff_core_response.enq(DTLB_core_response{address: truncate(lookup.va),
                                             trap: lookup.trap,
                                             cause: lookup.cause,
                                             tlbmiss: False});
        `logLevel( dtlb, 0, $format("[%2d]DTLB: Transparent Translation done",hartid))
      end
      else begin
        Bool page_fault = False; 
        Bit#(`causesize) cause;  /*condition wr_vs_mode or lookup.pte.vs_bit==1??*/
        if(lookup.pte.vs_bit==1)	 //If V mode, guest page fault exceptions need to be raised	
        	cause = lookup.access == 0 ?`Load_guest_pagefault : `Store_guest_pagefault;
        else
        	cause = lookup.access == 0 ?`Load_pagefault : `Store_pagefault;
        let pte = lookup.pte  ;
        Bit#(TSub#(`vaddr, `maxvaddr)) unused_va = lookup.va[`vaddr - 1 : `maxvaddr];
        let permissions = pte.permissions;
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = truncate(pte.pagemask);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte.ppn);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa =(mask&lower_ppn)|(~mask&lower_vpn);
        Bit#(`lastppnsize) highest_ppn = truncateLSB(pte.ppn);
      `ifdef sv32
        Bit#(`vaddr) physicaladdress = truncate({highest_ppn, lower_pa, page_offset});
      `else
        Bit#(`vaddr) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});
      `endif

        `logLevel( dtlb, 2, $format("[%2d]DTLB: mask:%h",hartid,mask))
        `logLevel( dtlb, 2, $format("[%2d]DTLB: lower_ppn:%h",hartid,lower_ppn))
        `logLevel( dtlb, 2, $format("[%2d]DTLB: lower_vpn:%h",hartid,lower_vpn))
        `logLevel( dtlb, 2, $format("[%2d]DTLB: lower_pa:%h",hartid,lower_pa))
        `logLevel( dtlb, 2, $format("[%2d]DTLB: highest_ppn:%h",hartid,highest_ppn))
	      `logLevel( dtlb, 2, $format("[%2d]DTLB: vs_bit:%h sum:%b mxr:%b",hartid,pte.vs_bit, sum, mxr))	//Vs bit in TLB
        // check for permission faults
      `ifndef sv32
        if(unused_va != signExtend(lookup.va[`maxvaddr-1]))begin
          page_fault = True;
          `logLevel( dtlb, 0, $format("[%2d]DTLB-Fault1",hartid))
        end
      `endif
        if (lookup.hlvx == 1 && !permissions.x)begin
          page_fault = True;
          `logLevel( dtlb, 0, $format("[%2d]DTLB-Fault2",hartid))
        end
        // pte.a == 0 || pte.d == 0 and access != Load
        if(!permissions.a || (!permissions.d && lookup.access != 0))begin
          page_fault = True;
          `logLevel( dtlb, 0, $format("[%2d]DTLB-Fault3",hartid))
        end
        if(lookup.access == 0 && lookup.hlvx == 0 && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
          page_fault = True;
          `logLevel( dtlb, 0, $format("[%2d]DTLB-Fault4",hartid))
        end
        if(lookup.prv == 1 && permissions.u && sum == 0 && pte.vs_bit == 0)begin // supervisor accessing user
          page_fault = True;
          `logLevel( dtlb, 0, $format("[%2d]DTLB-Fault5",hartid))
        end
        if(!permissions.u && (lookup.prv == 0 || pte.vs_bit == 1))begin
          page_fault = True;
          `logLevel( dtlb, 0, $format("[%2d]DTLB-Fault6",hartid))
        end

        // for Store access
        if(lookup.access != 0 && !permissions.w)begin // if not readable and not mxr  executable
          page_fault = True;
          `logLevel( dtlb, 0, $format("[%2d]DTLB-Fault7",hartid))
        end
        if(lookup.tlbmiss)begin
          rg_miss_queue <= lookup.va;
          ff_request_to_ptw.enq(PTWalk_tlb_request{address : lookup.va, 
                                                  access : lookup.access,
                                                  prv: lookup.prv
                                              `ifdef hypervisor
                                                  ,virt: lookup.virt
                                                  ,hlvx: lookup.hlvx
                                              `endif });
          `logLevel( dtlb, 0, $format("[%2d]DTLB: Sending req to PTW", hartid))
          ff_core_response.enq(DTLB_core_response{address  : ?,
                                                 trap     : False,
                                                 cause    : ?,
                                                 tlbmiss  : True});
        end
        else begin
          `logLevel( dtlb, 0, $format("[%2d]DTLB: Sending PA:%h Trap:%b",hartid, physicaladdress, page_fault))
          `logLevel( dtlb, 0, $format("[%2d]DTLB: Hit in TLB:",hartid,fshow(pte)))
          ff_core_response.enq(DTLB_core_response{address  : truncate(physicaladdress),
                                               trap     : page_fault,
                                               cause    : cause,
                                               tlbmiss  : False});
        end
      end
    endrule

    interface put_core_request = interface Put
      method Action put (DTLB_core_request#(`vaddr) req) if(!rg_sfence `ifdef hypervisor && !rg_hfence `endif );

        `logLevel( dtlb, 0, $format("[%2d]DTLB: received req: ",hartid,fshow(req)))

        Bit#(12) page_offset = req.address[11 : 0];
        Bit#(`vpnsize) fullvpn = truncate(req.address >> 12);

        Bit#(`vaddr) satp_new = (req.virt==1) ? wr_vsatp : wr_satp;
        // global variables based on the above wires
        Bit#(`asidwidth) satp_asid = satp_new[`asidwidth - 1 + `ppnsize : `ppnsize ];
      `ifdef sv32
        Bit#(1) satp_mode = truncateLSB(satp_new);
      `else
        Bit#(4) satp_mode = truncateLSB(satp_new);
      `endif

        /*doc:func: */
        function Bool fn_vtag_match (VPNTag t);
          return t.permissions.v && (({'1,t.pagemask} & fullvpn) == t.vpn)
                                 && (t.asid == satp_asid || t.permissions.g);
        endfunction

        Bit#(`vaddr) va = req.address;
        Bit#(`causesize) cause = req.cause;
        Bool trap = req.ptwalk_trap;
        Bool translation_done = False;
        let hit_entry = find(fn_vtag_match, readVReg(v_vpn_tag));
        Bool tlbmiss = !isValid(hit_entry);
        VPNTag pte = fromMaybe(?,hit_entry);
        Bit#(TSub#(`vaddr, `paddr)) upper_bits = truncateLSB(req.address);
        translation_done = (satp_mode == 0 || req.prv == 3 || req.ptwalk_req || req.ptwalk_trap);
        if(!trap && translation_done)begin
           trap = |upper_bits == 1;
           cause = req.access == 0? `Load_access_fault: `Store_access_fault;
        end

        if(req.sfence && !req.ptwalk_req)begin
          rg_sfence <= True;
        end
      `ifdef hypervisor
    		else if(req.hfence && !req.ptwalk_req)begin
    		  rg_hfence <= True;
    		end
      `endif
        else begin
          ff_lookup_result.enq(LookUpResult{va: va, trap: trap, cause: cause,
                                            translation_done: translation_done, prv: req.prv,
                                            tlbmiss: tlbmiss, pte: pte, access: req.access
                                        `ifdef hypervisor 
                                            , hlvx: req.hlvx, virt: req.virt
                                        `endif });
        end

        if(req.sfence `ifdef hypervisor || req.hfence `endif )
          rg_tlb_miss <= False;
        else if(rg_tlb_miss && req.ptwalk_trap)
          rg_tlb_miss <= False;
        else if(!translation_done && !req.ptwalk_req) begin
          rg_tlb_miss <= tlbmiss;
        `ifdef perfmonitors
          wr_count_misses <= pack(tlbmiss);
        `endif
        end

      endmethod
    endinterface;

    interface put_response_frm_ptw = interface Put
      method Action put(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) resp) if(rg_tlb_miss && !rg_sfence `ifdef hypervisor 				&& !rg_hfence `endif );
        let core_req = rg_miss_queue ;
        Bit#(12) page_offset = core_req[11 : 0];

        `logLevel( dtlb, 0, $format("[%2d]DTLB: Response from PTW:",hartid, fshow(resp)))

        Bit#(`vpnsize) fullvpn = truncate(core_req >> 12);
        Bit#(`ppnsize) fullppn = truncate(resp.pte >> 10);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = '1;
        Bit#(TLog#(TMul#(TSub#(`varpages,1),`subvpn))) shiftamt = `subvpn * zeroExtend(resp.levels);
        mask = mask << shiftamt;
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(fullppn);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(core_req >> 12);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa =(mask&lower_ppn)|(~mask&lower_vpn);
        Bit#(`lastppnsize) highest_ppn = truncateLSB(fullppn);
      `ifdef sv32
        Bit#(`vaddr) physicaladdress = truncate({highest_ppn, lower_pa, page_offset});
      `else
        Bit#(`vaddr) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});
      `endif

        Bit#(`vaddr) satp_new = (resp.virt==1) ? wr_vsatp : wr_satp;
        Bit#(`vaddr) status_new = (resp.virt==1) ? wr_vsstatus : wr_mstatus;   //As per QEMU-H extension 
        // global variables based on the above wires
        Bit#(`asidwidth) satp_asid = satp_new[`asidwidth - 1 + `ppnsize : `ppnsize ];

        let tag = VPNTag{ permissions: unpack(truncate(resp.pte)),
                          vpn: {'1,mask} & fullvpn,
                          asid: satp_asid,
                          pagemask: mask,
                          ppn: fullppn, 
                          vs_bit: resp.virt //Added Vs_bit in VPNTag struct.
                          };
        if(!resp.trap) begin
          `logLevel( dtlb, 0, $format("[%2d]DTLB: Allocating index:%d for Tag:",hartid, rg_replace, fshow(tag)))
          v_vpn_tag[rg_replace] <= tag;
          rg_replace <= rg_replace + 1;
        end

      endmethod
    endinterface;

    interface get_core_response = toGet(ff_core_response);

    interface get_request_to_ptw = toGet(ff_request_to_ptw);

    method Action ma_satp_from_csr (Bit#(`vaddr) s);
      wr_satp <= s;
    endmethod

    /*doc:method: */
    method Action ma_mstatus_from_csr (Bit#(`vaddr) m);
      wr_mstatus <= m;
    endmethod

    /*doc:method: */
    method mv_tlb_available = !rg_tlb_miss && ff_lookup_result.notFull;
  
  `ifdef perfmonitors
    method mv_perf_counters = wr_count_misses;
  `endif
   
  `ifdef hypervisor
	    
	  method Action ma_vsatp_from_csr (Bit#(`vaddr) vsatp);
	    wr_vsatp <= vsatp;
	  endmethod:ma_vsatp_from_csr
	    
	  method Action ma_vsstatus_from_csr (Bit#(`vaddr) vsstatus);
      wr_vsstatus <= vsstatus;
  	endmethod:ma_vsstatus_from_csr
  `endif
  endmodule:mkfa_dtlb

endpackage

