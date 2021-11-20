/*
see LICENSE.iitm

Author: Arjun Menon, Neel Gala, Nitya Ranganathan
Email id: c.arjunmenon@gmail.com, neelgala@gmail.com, nitya.ranganathan@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package fa_dtlb;
  `include "Logger.bsv"
  `include "nb_dcache.defines"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import Vector :: * ;
  import GetPut :: * ;
  import ConfigReg :: * ;
  import nb_dcache_types :: * ;
  import common_tlb_types :: * ;
`ifdef supervisor
  import io_func :: * ;
`endif

  // structure of the virtual tag for fully-associative look-up
  typedef struct{
    TLB_permissions permissions;
    Bit#(`vpnsize) vpn;
    Bit#(`asidwidth) asid;
    Bit#(TMul#(TSub#(`varpages,1), `subvpn)) pagemask;
    Bit#(`ppnsize) ppn;
  } VPNTag deriving(Bits, FShow, Eq);

  interface Ifc_ptw_meta#(numeric type xlen);
    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(xlen) s);

    /*doc:method: method to recieve the current privilege mode of operation*/
    method Action ma_curr_priv (Bit#(2) c);

    /*doc:method: method to receive the current values of the mstatus register*/
    method Action ma_mstatus_from_csr (Bit#(xlen) m);

  `ifdef pmp
    /*doc:method: */
    method Action ma_pmp_cfg ( Vector#(`PMPSIZE, Bit#(8)) pmpcfg) ;
    /*doc:method: */
    method Action ma_pmp_addr ( Vector#(`PMPSIZE, Bit#(paddr)) pmpaddr);
  `endif
  `ifdef perfmonitors
    method Bit#(1) mv_perf_counters;
  `endif
  endinterface

  interface Ifc_fa_dtlb#(numeric type xlen, numeric type paddr);
    method ActionValue#(DTLB_Cache_response#(paddr)) translate(Cache_DTLB_request#(xlen) req);
    interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) response_frm_ptw;
    interface Ifc_ptw_meta#(xlen) ptw_meta;
`ifdef supervisor
    method Tuple3#(Bit#(1), Bit#(1), Bit#(1)) early_lookup(Bit#(xlen) vaddr, Bit#(1) is_store);
`endif
  endinterface

  /*doc:module: */
  module mkfa_dtlb(Ifc_fa_dtlb#(xlen, paddr))
    provisos (
      Add#(TMul#(TSub#(`varpages,1),`subvpn), a__, xlen),
      Add#(b__, paddr, xlen),
    `ifdef sv32
      Add#(c__, 22, xlen),
      Add#(d__, 20, xlen),
      Add#(e__, xlen, 34),
      Add#(f__, 1, xlen)
    `else
      `ifdef sv39
        Add#(c__, 40, xlen),
        Add#(d__, 27, xlen),
      `else
        Add#(c__, 49, xlen),
        Add#(d__, 36, xlen),
      `endif
      Add#(e__, 44, xlen),
      Add#(f__, 56, xlen),
      Add#(g__, 4, xlen)
    `endif
    );

    Vector#( `dtlbsize, Reg#(VPNTag) ) v_vpn_tag <- replicateM(mkReg(unpack(0))) ;

    /*doc:reg: register to indicate which entry need to be filled/replaced*/
    Reg#(Bit#(TLog#(`dtlbsize))) rg_replace <- mkReg(0);
    /*doc:wire: wire holding the latest value of the satp csr*/
    Wire#(Bit#(xlen)) wr_satp <- mkWire();
    /*doc:wire: wire holds the current privilege mode of the core*/
    Wire#(Bit#(2)) wr_priv <- mkWire();
    /*doc:wire: wire holding the current values of mstatus fields*/
    Wire#(Bit#(xlen)) wr_mstatus <- mkWire();

    /*doc:reg: */
    Reg#(Bit#(xlen)) rg_miss_queue <- mkConfigReg(0);

    // global variables based on the above wires
    Bit#(`ppnsize) satp_ppn = truncate(wr_satp);
    Bit#(`asidwidth) satp_asid = wr_satp[`asidwidth - 1 + `ppnsize : `ppnsize ];
  `ifdef sv32
    Bit#(1) satp_mode = truncateLSB(wr_satp);
  `else
    Bit#(4) satp_mode = truncateLSB(wr_satp);
  `endif
    Bit#(1) mxr = wr_mstatus[19];
    Bit#(1) sum = wr_mstatus[18];
    Bit#(2) mpp = wr_mstatus[12 : 11];
    Bit#(1) mprv = wr_mstatus[17];

    /*doc:reg: register to indicate that a tlb miss is in progress*/
    Reg#(Bool) rg_tlb_miss <- mkConfigReg(False);

    /*doc:reg: register to indicate the tlb is undergoing an sfence*/
    Reg#(Bool) rg_sfence <- mkConfigReg(False);

  `ifdef pmp
    Vector#(`PMPSIZE, Wire#(Bit#(8))) wr_pmp_cfg <- replicateM(mkWire());
    Vector#(`PMPSIZE, Wire#(Bit#(paddr))) wr_pmp_addr <- replicateM(mkWire());
  `endif

  `ifdef perfmonitors
    /*doc:wire: */
    Wire#(Bit#(1)) wr_count_misses <- mkDWire(0);
  `endif

    rule rl_display_tlb_regs;
      if (`VERBOSITY > 1) begin
        $display($time, " PT: DTLB: tlb_miss %d sfence %d miss_va %h", rg_tlb_miss, rg_sfence, rg_miss_queue);
      end
    endrule

    /*doc:rule: this rule is fired when the core requests a sfence. This rule will simply invalidate
     all the tlb entries*/
    rule rl_fence(rg_sfence && !rg_tlb_miss);
      for (Integer i = 0; i < `dtlbsize; i = i + 1) begin
        v_vpn_tag[i] <= unpack(0);
      end
      rg_sfence <= False;
      rg_replace <= 0;
      `logLevel( dtlb, 1, $format("DTLB: SFencing Now"))
    endrule

    method ActionValue#(DTLB_Cache_response#(paddr)) translate(Cache_DTLB_request#(xlen) req) if(!rg_sfence);
      `logTimeLevel( dtlb, 0, $format("DTLB: received req: ",fshow(req)))

      Bit#(`vpnsize) fullvpn = truncate(req.address >> 12);

      /*doc:func: */
      function Bool fn_vtag_match (VPNTag t);
        return t.permissions.v && (({'1,t.pagemask} & fullvpn) == t.vpn)
                               && (t.asid == satp_asid || t.permissions.g);
      endfunction

      Bit#(xlen) va = req.address;
      DCache_exception exception = No_exception;
      Bool trap = req.ptwalk_trap;
      Bool translation_done = False;
      let hit_entry = find(fn_vtag_match, readVReg(v_vpn_tag));
      Bool tlbmiss = !isValid(hit_entry);
      VPNTag pte = fromMaybe(?,hit_entry);
      Bit#(TSub#(xlen, paddr)) upper_bits = truncateLSB(req.address);
      Bit#(2) priv = mprv == 0?wr_priv : mpp;
      translation_done = (satp_mode == 0 || priv == 3 || req.ptwalk_req || req.ptwalk_trap);
      DTLB_Cache_response#(paddr) core_resp= ?;

      if(!trap && translation_done)begin
         trap = |upper_bits == 1;
         exception = req.access == 0? Load_access_fault: Store_access_fault;
      end

      if (`VERBOSITY > 1) begin
        $display($time, " PT: DTLB: satp mode %h priv %d ptw_req %d ptw_trap %d trap %d exception %h mprv %d mpp %d", satp_mode, priv, req.ptwalk_req, req.ptwalk_trap, trap, exception, mprv, mpp);
      end

      if(req.sfence && !req.ptwalk_req)begin
        rg_sfence <= True;
        if (`VERBOSITY > 1) begin
          $display($time, " PT: DTLB: case: sfence");
        end
      end
      else begin
        Bit#(12) page_offset = va[11 : 0];
        if(translation_done)begin
          core_resp= (DTLB_Cache_response{address: truncate(va),
                                         trap: trap,
                                         exception: exception,
                                         tlbmiss: False});
          if (`VERBOSITY > 1) begin
            $display($time, " PT: DTLB: translation done; sending response %h", va);
          end
        end
        else begin
          Bool page_fault = False;
          Bit#(TSub#(xlen, `maxvaddr)) unused_va = va[valueOf(xlen) - 1 : `maxvaddr];
          let permissions = pte.permissions;
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = truncate(pte.pagemask);
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte.ppn);
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa =(mask&lower_ppn)|(~mask&lower_vpn);
          Bit#(`lastppnsize) highest_ppn = truncateLSB(pte.ppn);
        `ifdef sv32
          Bit#(xlen) physicaladdress = truncate({highest_ppn, lower_pa, page_offset});
        `else
          Bit#(xlen) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});
        `endif

          `logLevel( dtlb, 2, $format("mask:%h",mask))
          `logLevel( dtlb, 2, $format("lower_ppn:%h",lower_ppn))
          `logLevel( dtlb, 2, $format("lower_vpn:%h",lower_vpn))
          `logLevel( dtlb, 2, $format("lower_pa:%h",lower_pa))
          `logLevel( dtlb, 2, $format("highest_ppn:%h",highest_ppn))
          if (`VERBOSITY > 1) begin
            $display($time, " PT: DTLB: translating: addr %h unused %h perm %h # mask %h lower_ppn %h lower_vpn %h lower_pa %h highest_ppn %h", va, unused_va, permissions, unused_va, permissions, mask, lower_ppn, lower_vpn, lower_pa, highest_ppn);
          end

          // check for permission faults
        `ifndef sv32
          if(unused_va != signExtend(va[`maxvaddr-1]))begin
            page_fault = True;
          end
        `endif
          // pte.a == 0 || pte.d == 0 and access != Load
          if(!permissions.a || (!permissions.d && req.access != 0))begin
            page_fault = True;
          end
          if(req.access == 0 && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
            page_fault = True;
          end
          if(priv == 1 && permissions.u && sum == 0)begin // supervisor accessing user
            page_fault = True;
          end
          if(!permissions.u && priv == 0)begin
            page_fault = True;
          end

          // for Store access
          if(req.access != 0 && !permissions.w)begin // if not readable and not mxr  executable
            page_fault = True;
          end
          if(tlbmiss)begin
            rg_miss_queue <= va;
            core_resp= (DTLB_Cache_response{address  : ?,
                                           trap     : False,
                                           exception: exception,
                                           tlbmiss  : True});
            if (`VERBOSITY > 1) begin
              $display($time, " PT: DTLB: miss in tlb");
            end
          end
          else begin
            `logTimeLevel( dtlb, 0, $format("DTLB: Sending PA:%h Trap:%b", physicaladdress, page_fault))
            `logTimeLevel( dtlb, 0, $format("DTLB: Hit in TLB:",fshow(pte)))
`ifdef supervisor
            exception = (req.access == 0) ? Load_page_fault : Store_page_fault;
`endif
            core_resp= (DTLB_Cache_response{address  : truncate(physicaladdress),
                                           trap     : page_fault,
                                           exception: exception,
                                           tlbmiss  : False});
            if (`VERBOSITY > 1) begin
              $display($time, " PT: DTLB: hit in tlb: paddr %h trap %h exception %h", physicaladdress, page_fault, exception);
            end
          end
        end
      end

      if(req.sfence)
        rg_tlb_miss <= False;
      else if(rg_tlb_miss && req.ptwalk_trap)
        rg_tlb_miss <= False;
      else if(!translation_done && !req.ptwalk_req) begin
        rg_tlb_miss <= tlbmiss;
      `ifdef perfmonitors
        wr_count_misses <= pack(tlbmiss);
      `endif
      end

      return core_resp;
    endmethod

`ifdef supervisor
    method Tuple3#(Bit#(1), Bit#(1), Bit#(1)) early_lookup(Bit#(xlen) vaddr, Bit#(1) is_store);
      Bit#(1) lv_hit = 0;
      Bit#(1) lv_cacheable = 0;
      Bit#(1) lv_excp = 0;
      Bit#(xlen) lv_paddr = '0;
      Bool trap = False;
      Bool page_fault = False;

      // Subset of the translate method above + no side-effects
      // TODO: sfence check not needed now.
      Bit#(`vpnsize) fullvpn = truncate(vaddr >> 12);

      /*doc:func: */
      function Bool fn_vtag_match (VPNTag t);
        return t.permissions.v && (({'1,t.pagemask} & fullvpn) == t.vpn)
                               && (t.asid == satp_asid || t.permissions.g);
      endfunction

      Bit#(xlen) va = vaddr;
      Bool translation_done = False;
      let hit_entry = find(fn_vtag_match, readVReg(v_vpn_tag));
      Bool tlbmiss = !isValid(hit_entry);
      VPNTag pte = fromMaybe(?,hit_entry);
      Bit#(TSub#(xlen, paddr)) upper_bits = truncateLSB(vaddr);
      Bit#(2) priv = mprv == 0?wr_priv : mpp;
      translation_done = (satp_mode == 0 || priv == 3);

      if(!trap && translation_done)begin
         trap = |upper_bits == 1;
      end

      Bit#(12) page_offset = va[11 : 0];
      if (translation_done) begin
        lv_paddr = vaddr;
        tlbmiss = False;
      end
      // translate
      else begin
        Bit#(TSub#(xlen, `maxvaddr)) unused_va = va[valueOf(xlen) - 1 : `maxvaddr];
        let permissions = pte.permissions;
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = truncate(pte.pagemask);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte.ppn);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
        Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa =(mask&lower_ppn)|(~mask&lower_vpn);
        Bit#(`lastppnsize) highest_ppn = truncateLSB(pte.ppn);
        `ifdef sv32
          lv_paddr = truncate({highest_ppn, lower_pa, page_offset});
        `else
          lv_paddr = zeroExtend({highest_ppn, lower_pa, page_offset});
        `endif

        // check for permission faults
        `ifndef sv32
          if(unused_va != signExtend(va[`maxvaddr-1]))begin
            page_fault = True;
          end
        `endif
        // pte.a == 0 || pte.d == 0 and access != Load
        if(!permissions.a || (!permissions.d && (is_store == 1)))begin
          page_fault = True;
        end
        if((is_store == 0) && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
          page_fault = True;
        end
        if(priv == 1 && permissions.u && sum == 0)begin // supervisor accessing user
          page_fault = True;
        end
        if(!permissions.u && priv == 0)begin
          page_fault = True;
        end

        // for Store access
        if((is_store == 1) && !permissions.w)begin // if not readable and not mxr executable
          page_fault = True;
        end
      end // translate

      // tlb miss
      if (tlbmiss) begin
        lv_hit = 0;
        lv_cacheable = 0;
        lv_excp = 0;
      end
      // tlb hit
      else begin
        lv_hit = 1;
        lv_cacheable = pack(!isIO(lv_paddr[`paddr-1:0], True));
        lv_excp = pack(trap || page_fault);
      end

      return tuple3(lv_hit, lv_cacheable, lv_excp);
    endmethod
`endif

    interface response_frm_ptw = interface Put
      method Action put(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages) resp) if(rg_tlb_miss && !rg_sfence);
        let core_req = rg_miss_queue ;
        Bit#(12) page_offset = core_req[11 : 0];

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
        Bit#(xlen) physicaladdress = truncate({highest_ppn, lower_pa, page_offset});
      `else
        Bit#(xlen) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});
      `endif

        let tag = VPNTag{ permissions: unpack(truncate(resp.pte)),
                          vpn: {'1,mask} & fullvpn,
                          asid: satp_asid,
                          pagemask: mask,
                          ppn: fullppn };
        if(!resp.trap) begin
          `logTimeLevel( dtlb, 0, $format("DTLB: Allocating index:%d for Tag:", rg_replace, fshow(tag)))
          v_vpn_tag[rg_replace] <= tag;
          rg_replace <= rg_replace + 1;
        end

        if (`VERBOSITY > 1) begin
          $display($time, " PT: DTLB: Response received from PTW: pte %h levels %d trap %d cause %h", resp.pte, resp.levels, resp.trap, resp.cause);
        end
      endmethod
    endinterface;

    interface ptw_meta = interface Ifc_ptw_meta
      method Action ma_satp_from_csr (Bit#(xlen) s);
        wr_satp <= s;
      endmethod

      method Action ma_curr_priv (Bit#(2) c);
        wr_priv <= c;
      endmethod

      /*doc:method: */
      method Action ma_mstatus_from_csr (Bit#(xlen) m);
        wr_mstatus <= m;
      endmethod

    `ifdef pmp
      method Action ma_pmp_cfg (Vector#(`PMPSIZE, Bit#(8)) pmpcfg);
        for(Integer i = 0;i<valueOf(`PMPSIZE) ;i = i+1)
          wr_pmp_cfg[i] <= pmpcfg[i];
      endmethod
      method Action ma_pmp_addr(Vector#(`PMPSIZE, Bit#(paddr)) pmpadr);
        for(Integer i = 0;i<valueOf(`PMPSIZE) ;i = i+1)
          wr_pmp_addr[i] <= pmpadr[i];
      endmethod
    `endif

    `ifdef perfmonitors
      method mv_perf_counters = wr_count_misses;
    `endif
    endinterface;
    
  endmodule

endpackage

