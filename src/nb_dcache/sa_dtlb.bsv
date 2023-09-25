/*
see LICENSE.iitm

Author: Arjun Menon, Neel Gala, Sriram Shanmuga, Nitya Ranganathan
Email id: c.arjunmenon@gmail.com, neelgala@gmail.com, sriramshanmugacf+shakti@gmail.com, nitya.ranganathan@gmail.com
Details: sa_dtlb is an associativity-configurable and 'sv39 only' implementation that succeeds fa_dtlb; It supports 4K, 2M and 1G pages; 

--------------------------------------------------------------------------------------------------
*/
`ifdef sv39
package sa_dtlb;
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
  import Assert :: * ;
`ifdef supervisor
  import io_func :: * ;
`endif

  // structure of the virtual tags for set-associative look-ups
  typedef struct{
    TLB_permissions permissions;
    Bit#(TSub#(`vpnsize, TLog#(`dtlbsets_4k))) vpn;
    Bit#(`asidwidth) asid;
    Bit#(`ppnsize) ppn;
  } VPNTag_4K deriving(Bits, FShow, Eq);

  typedef struct{
    TLB_permissions permissions;
    Bit#(TSub#(`vpnsize, TAdd#(TLog#(`dtlbsets_2m), `subvpn))) vpn;
    Bit#(`asidwidth) asid;
    Bit#(`ppnsize) ppn;
  } VPNTag_2M deriving(Bits, FShow, Eq);

  typedef struct{
    TLB_permissions permissions;
    Bit#(TSub#(`vpnsize, TAdd#(TLog#(`dtlbsets_1g), TMul#(`subvpn, 2)))) vpn;
    Bit#(`asidwidth) asid;
    Bit#(`ppnsize) ppn;
  } VPNTag_1G deriving(Bits, FShow, Eq);

  interface Ifc_ptw_meta#(numeric type xlen);
    /*doc:method: method to receive the current satp csr from the core*/
    method Action ma_satp_from_csr (Bit#(xlen) s);

    /*doc:method: method to recieve the current privilege mode of operation*/
    method Action ma_curr_priv (Bit#(2) c);

    /*doc:method: method to receive the current values of the mstatus register*/
    method Action ma_mstatus_from_csr (Bit#(xlen) m);

//  `ifdef pmp
//    /*doc:method: */
//    method Action ma_pmp_cfg ( Vector#(`PMPSIZE, Bit#(8)) pmpcfg) ;
//    /*doc:method: */
//    method Action ma_pmp_addr ( Vector#(`PMPSIZE, Bit#(paddr)) pmpaddr);
//  `endif

  `ifdef perfmonitors
    method Bit#(1) mv_perf_counters;
  `endif
  endinterface

  interface Ifc_sa_dtlb#(numeric type xlen, numeric type paddr);
    method ActionValue#(DTLB_Cache_response#(paddr)) translate(Cache_DTLB_request#(xlen) req);
    interface Put#(PTWalk_tlb_response#(TAdd#(`ppnsize,10), `varpages)) response_frm_ptw;
    interface Ifc_ptw_meta#(xlen) ptw_meta;
`ifdef enable_cache_dump
    method Action ma_dump;
`endif
`ifdef supervisor
    method Tuple3#(Bit#(1), Bit#(1), Bit#(1)) early_lookup(Bit#(xlen) vaddr, Bit#(1) is_store);
`endif
  endinterface

  /*doc:module:*/
  module mksa_dtlb(Ifc_sa_dtlb#(xlen, paddr))
    provisos (
      Add#(TMul#(TSub#(`varpages,1),`subvpn), a__, xlen),
      Add#(b__, paddr, xlen),
      Add#(c__, 40, xlen),
      Add#(d__, 27, xlen),
      Add#(e__, 44, xlen),
      Add#(f__, 56, xlen),
      Add#(g__, 4, xlen)
    );

    /*doc:vector: vector arrays that hold all the tags*/
    Vector#( `dtlbways_4k, Reg#(VPNTag_4K) ) v_vpn_tags_4k[`dtlbsets_4k];
    for (Integer i = 0; i < (`dtlbsets_4k); i = i + 1) begin
      v_vpn_tags_4k[i] <- replicateM(mkReg(unpack(0))) ;
    end

    Vector#( `dtlbways_2m, Reg#(VPNTag_2M) ) v_vpn_tags_2m[`dtlbsets_2m];
    for (Integer i = 0; i < (`dtlbsets_2m); i = i + 1) begin
      v_vpn_tags_2m[i] <- replicateM(mkReg(unpack(0))) ;
    end

    Vector#( `dtlbways_1g, Reg#(VPNTag_1G) ) v_vpn_tags_1g[`dtlbsets_1g];
    for (Integer i = 0; i < (`dtlbsets_1g); i = i + 1) begin
      v_vpn_tags_1g[i] <- replicateM(mkReg(unpack(0))) ;
    end

    /*doc:reg: registers to indicate which entry need to be filled/replaced in the corresponding TLB*/
    Reg#(Bit#(TLog#(`dtlbways_4k))) rgs_replace_4k[`dtlbsets_4k]; 
    for (Integer i = 0; i < (`dtlbsets_4k); i = i + 1) begin
      rgs_replace_4k[i] <- mkReg(0);
    end

    Reg#(Bit#(TLog#(`dtlbways_2m))) rgs_replace_2m[`dtlbsets_2m]; 
    for (Integer i = 0; i < (`dtlbsets_2m); i = i + 1) begin
      rgs_replace_2m[i] <- mkReg(0);
    end

    Reg#(Bit#(TLog#(`dtlbways_1g))) rgs_replace_1g[`dtlbsets_1g]; 
    for (Integer i = 0; i < (`dtlbsets_1g); i = i + 1) begin
      rgs_replace_1g[i] <- mkReg(0);
    end

    /*doc:wire: wire holding the latest value of the satp csr*/
    Wire#(Bit#(xlen)) wr_satp <- mkWire();
    /*doc:wire: wire holds the current privilege mode of the core*/
    Wire#(Bit#(2)) wr_priv <- mkWire();
    /*doc:wire: wire holding the current values of mstatus fields*/
    Wire#(Bit#(xlen)) wr_mstatus <- mkWire();

    /*doc:reg: record vpn that triggered a tlb miss*/
    Reg#(Bit#(xlen)) rg_miss_queue <- mkConfigReg(0);

    // global variables based on the above wires
    Bit#(`ppnsize) satp_ppn = truncate(wr_satp);
    Bit#(`asidwidth) satp_asid = wr_satp[`asidwidth - 1 + `ppnsize : `ppnsize ];
    Bit#(4) satp_mode = truncateLSB(wr_satp);
    Bit#(1) mxr = wr_mstatus[19];
    Bit#(1) sum = wr_mstatus[18];
    Bit#(2) mpp = wr_mstatus[12 : 11];
    Bit#(1) mprv = wr_mstatus[17];

    /*doc:reg: register to indicate that a tlb miss is in progress*/
    Reg#(Bool) rg_tlb_miss <- mkConfigReg(False);

    /*doc:reg: registers to indicate the tlb is undergoing an sfence*/
    Reg#(Bool) rg_sfence <- mkConfigReg(False);

//  `ifdef pmp
//    Vector#(`PMPSIZE, Wire#(Bit#(8))) wr_pmp_cfg <- replicateM(mkWire());
//    Vector#(`PMPSIZE, Wire#(Bit#(paddr))) wr_pmp_addr <- replicateM(mkWire());
//  `endif

  `ifdef perfmonitors
    /*doc:wire: */
    Wire#(Bit#(1)) wr_count_misses <- mkDWire(0);
  `endif

    /*doc:rule: this rule is fired when VERBOSITY > 1, it dumps register values.*/
    rule rl_display_tlb_regs;
      if (`VERBOSITY > 1) begin
        $display($time, " PT: DTLB: tlb_miss %d sfence %d miss_va %h", rg_tlb_miss, rg_sfence, rg_miss_queue);
      end
    endrule

    /*doc:rule: this rule is fired when the core requests a sfence. This rule will simply invalidate all tlb entries.*/
    rule rl_fence(rg_sfence && !rg_tlb_miss);

      `logLevel( dtlb, 1, $format("DTLB: SFencing Now"))

      for (Integer i = 0; i < `dtlbsets_4k; i = i + 1) begin
        for (Integer j = 0; j < `dtlbways_4k; j = j + 1) begin
          v_vpn_tags_4k[i][j] <= unpack(0);
        end
        rgs_replace_4k[i] <= 0;
      end

      for (Integer i = 0; i < `dtlbsets_2m; i = i + 1) begin
        for (Integer j = 0; j < `dtlbways_2m; j = j + 1) begin
          v_vpn_tags_2m[i][j] <= unpack(0);
        end
        rgs_replace_2m[i] <= 0;
      end

      for (Integer i = 0; i < `dtlbsets_1g; i = i + 1) begin
        for (Integer j = 0; j < `dtlbways_1g; j = j + 1) begin
          v_vpn_tags_1g[i][j] <= unpack(0);
        end
        rgs_replace_1g[i] <= 0;
      end
      
      rg_sfence <= False;
      
    endrule

    /*doc:method: looks up the given virtual address in the cache and returns the corresponding physical address if present.*/
    method ActionValue#(DTLB_Cache_response#(paddr)) translate(Cache_DTLB_request#(xlen) req) if(!rg_sfence);
      `logTimeLevel( dtlb, 0, $format("DTLB: Translate request for ",fshow(req)))

      Bit#(`vpnsize) fullvpn = truncate(req.address >> 12);
      Bit#(xlen) va = req.address;
      DCache_exception exception = No_exception;
      Bool trap = req.ptwalk_trap;
      Bool translation_done = False;

      /*doc:func: check for 4k hit*/
      function Bool fn_vtag_match_4k (VPNTag_4K t);
        Bit#(TSub#(`vpnsize, TLog#(`dtlbsets_4k))) vpn = truncateLSB(fullvpn);
        return t.permissions.v && (vpn == t.vpn) && ((t.asid == satp_asid) || t.permissions.g);
      endfunction

      Bit#(TLog#(`dtlbsets_4k)) set_index_4k = (valueOf(TLog#(`dtlbsets_4k)) == 0) ? 0 : fullvpn[valueOf(TLog#(`dtlbsets_4k))-1:0]; 
      let hit_entry_4k = find(fn_vtag_match_4k, readVReg(v_vpn_tags_4k[set_index_4k])); 
      Bool tlbmiss_4k = !isValid(hit_entry_4k);
      VPNTag_4K pte_4k = fromMaybe(?, hit_entry_4k);

      /*doc:func: check for 2m hit*/
      Bit#(TSub#(`vpnsize, `subvpn)) vpn_2m = truncateLSB(fullvpn);
      function Bool fn_vtag_match_2m (VPNTag_2M t);
        Bit#(TSub#(`vpnsize, TAdd#(TLog#(`dtlbsets_2m), `subvpn))) vpn = truncateLSB(vpn_2m);
        return t.permissions.v && (vpn == t.vpn) && ((t.asid == satp_asid) || t.permissions.g);
      endfunction

      Bit#(TLog#(`dtlbsets_2m)) set_index_2m = (valueOf(TLog#(`dtlbsets_2m)) == 0) ? 0 : vpn_2m[valueOf(TLog#(`dtlbsets_2m))-1:0]; 
      let hit_entry_2m = find(fn_vtag_match_2m, readVReg(v_vpn_tags_2m[set_index_2m])); 
      Bool tlbmiss_2m = !isValid(hit_entry_2m);
      VPNTag_2M pte_2m = fromMaybe(?, hit_entry_2m);

      /*doc:func: check for 1g hit*/
      Bit#(TSub#(`vpnsize, TMul#(`subvpn, 2))) vpn_1g = truncateLSB(fullvpn);
      function Bool fn_vtag_match_1g (VPNTag_1G t);
        Bit#(TSub#(`vpnsize, TAdd#(TLog#(`dtlbsets_1g), TMul#(`subvpn, 2)))) vpn = truncateLSB(vpn_1g);
        return t.permissions.v && (vpn == t.vpn) && ((t.asid == satp_asid) || t.permissions.g);
      endfunction

      Bit#(TLog#(`dtlbsets_1g)) set_index_1g = (valueOf(TLog#(`dtlbsets_1g)) == 0) ? 0 : vpn_1g[valueOf(TLog#(`dtlbsets_1g))-1:0]; 
      let hit_entry_1g = find(fn_vtag_match_1g, readVReg(v_vpn_tags_1g[set_index_1g])); 
      Bool tlbmiss_1g = !isValid(hit_entry_1g);
      VPNTag_1G pte_1g = fromMaybe(?, hit_entry_1g);

      Bool tlbmiss = tlbmiss_4k && tlbmiss_2m && tlbmiss_1g;

      Bit#(TSub#(xlen, paddr)) upper_bits = truncateLSB(req.address);
      Bit#(2) priv = mprv == 0?wr_priv : mpp;
      translation_done = (satp_mode == 0 || priv == 3 || req.ptwalk_req || req.ptwalk_trap);
      DTLB_Cache_response#(paddr) core_resp= ?;

      if(!trap && translation_done) begin
         trap = |upper_bits == 1;
         exception = req.access == 0? Load_access_fault: Store_access_fault;
      end

      if (`VERBOSITY > 1) begin
        $display($time, " PT: DTLB: satp mode %h priv %d ptw_req %d ptw_trap %d trap %d exception %h mprv %d mpp %d", satp_mode, priv, req.ptwalk_req, req.ptwalk_trap, trap, exception, mprv, mpp);
      end

      if(req.sfence && !req.ptwalk_req) begin
        rg_sfence <= True;
        if (`VERBOSITY > 1) begin
          $display($time, " PT: DTLB: case: sfence");
        end
      end
      else begin
        Bit#(12) page_offset = va[11 : 0]; 
        if(translation_done) begin
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

          if (((!tlbmiss_4k && !tlbmiss_2m) || (!tlbmiss_2m && !tlbmiss_1g) || (!tlbmiss_1g && !tlbmiss_4k)) && (`VERBOSITY > 1)) begin
            $display($time, " PT: DTLB: multiple hits detected! 4K:%d,2M:%d,1G:%d", !tlbmiss_4k, !tlbmiss_2m, !tlbmiss_1g);
          end

          `ifdef ASSERT
          dynamicAssert(!((!tlbmiss_4k && !tlbmiss_2m) || (!tlbmiss_2m && !tlbmiss_1g) || (!tlbmiss_1g && !tlbmiss_4k)), "DTLB: multiple hits detected!");
          `endif

          // hit in 4k table?
          if (!tlbmiss_4k) begin

            let permissions = pte_4k.permissions;
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = '1;
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte_4k.ppn);
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa = (mask & lower_ppn) | (~mask & lower_vpn);
            Bit#(`lastppnsize) highest_ppn = truncateLSB(pte_4k.ppn);
            Bit#(xlen) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});

            `logLevel( dtlb, 2, $format("DTLB: mask:%h",mask))
            `logLevel( dtlb, 2, $format("DTLB: lower_ppn:%h",lower_ppn))
            `logLevel( dtlb, 2, $format("DTLB: lower_vpn:%h",lower_vpn))
            `logLevel( dtlb, 2, $format("DTLB: lower_pa:%h",lower_pa))
            `logLevel( dtlb, 2, $format("DTLB: highest_ppn:%h",highest_ppn))
            if (`VERBOSITY > 1) begin
              $display($time, " PT: DTLB: translating: addr %h unused %h perm %h # mask %h lower_ppn %h lower_vpn %h lower_pa %h highest_ppn %h paddr %h", va, unused_va, permissions, mask, lower_ppn, lower_vpn, lower_pa, highest_ppn, physicaladdress);
            end

            // check for permission faults
            if(unused_va != signExtend(va[`maxvaddr-1])) begin
              page_fault = True;
            end
            // pte_4k.a == 0 || pte_4k.d == 0 and access != Load
            if(!permissions.a || (!permissions.d && req.access != 0)) begin
              page_fault = True;
            end
            if(req.access == 0 && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
              page_fault = True;
            end
            if(priv == 1 && permissions.u && sum == 0) begin // supervisor accessing user
              page_fault = True;
            end
            if(!permissions.u && priv == 0) begin
              page_fault = True;
            end

            // for Store access
            if(req.access != 0 && !permissions.w) begin // if not writable
              page_fault = True;
            end

            // Store and Dirty bit unset
            if (req.access == 1 && !permissions.d) begin
              page_fault = True;
            end
            // Writable pages must also be readable
            if (permissions.w && !permissions.r) begin
              page_fault = True;
            end

            // For non-leaf PTEs, the D, A, and U bits should be cleared.
            if ((!permissions.r && !permissions.w && !permissions.x) && (permissions.d || permissions.a || permissions.u)) begin
              page_fault = True;
            end

            // Reserved cases
            if ((!permissions.x && permissions.w && !permissions.r) || (permissions.x && permissions.w && !permissions.r)) begin
              page_fault = True;
            end

            `logTimeLevel( dtlb, 0, $format("DTLB: Sending PA:%h Trap:%b", physicaladdress, page_fault))
            `logTimeLevel( dtlb, 0, $format("DTLB: Hit in TLB:",fshow(pte_4k)))
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
          end // hit in 4k

          // hit in 2m table?
          else if (!tlbmiss_2m) begin

            let permissions = pte_2m.permissions;
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = 'h3fe00;
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte_2m.ppn);
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa = (mask & lower_ppn) | (~mask & lower_vpn);
            Bit#(`lastppnsize) highest_ppn = truncateLSB(pte_2m.ppn);
            Bit#(xlen) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});

            `logLevel( dtlb, 2, $format("DTLB: mask:%h",mask))
            `logLevel( dtlb, 2, $format("DTLB: lower_ppn:%h",lower_ppn))
            `logLevel( dtlb, 2, $format("DTLB: lower_vpn:%h",lower_vpn))
            `logLevel( dtlb, 2, $format("DTLB: lower_pa:%h",lower_pa))
            `logLevel( dtlb, 2, $format("DTLB: highest_ppn:%h",highest_ppn))
            if (`VERBOSITY > 1) begin
              $display($time, " PT: DTLB: translating: addr %h unused %h perm %h # mask %h lower_ppn %h lower_vpn %h lower_pa %h highest_ppn %h paddr %h", va, unused_va, permissions, mask, lower_ppn, lower_vpn, lower_pa, highest_ppn, physicaladdress);
            end

            // check for permission faults
            if(unused_va != signExtend(va[`maxvaddr-1])) begin
              page_fault = True;
            end
            // pte_2m.a == 0 || pte_2m.d == 0 and access != Load
            if(!permissions.a || (!permissions.d && req.access != 0)) begin
              page_fault = True;
            end
            if(req.access == 0 && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
              page_fault = True;
            end
            if(priv == 1 && permissions.u && sum == 0) begin // supervisor accessing user
              page_fault = True;
            end
            if(!permissions.u && priv == 0) begin
              page_fault = True;
            end

            // for Store access
            if(req.access != 0 && !permissions.w) begin // if not writable
              page_fault = True;
            end

            // Store and Dirty bit unset
            if (req.access == 1 && !permissions.d) begin
              page_fault = True;
            end
            // Writable pages must also be readable
            if (permissions.w && !permissions.r) begin
              page_fault = True;
            end

            // For non-leaf PTEs, the D, A, and U bits should be cleared.
            if ((!permissions.r && !permissions.w && !permissions.x) && (permissions.d || permissions.a || permissions.u)) begin
              page_fault = True;
            end

            // Reserved cases
            if ((!permissions.x && permissions.w && !permissions.r) || (permissions.x && permissions.w && !permissions.r)) begin
              page_fault = True;
            end

            `logTimeLevel( dtlb, 0, $format("DTLB: Sending PA:%h Trap:%b", physicaladdress, page_fault))
            `logTimeLevel( dtlb, 0, $format("DTLB: Hit in TLB:",fshow(pte_2m)))
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
          end // hit in 2m

          // hit in 1g table or miss in all
          else begin

            let permissions = pte_1g.permissions;
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = '0;
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte_1g.ppn);
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
            Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa = (mask & lower_ppn) | (~mask & lower_vpn);
            Bit#(`lastppnsize) highest_ppn = truncateLSB(pte_1g.ppn);
            Bit#(xlen) physicaladdress = zeroExtend({highest_ppn, lower_pa, page_offset});

            `logLevel( dtlb, 2, $format("DTLB: mask:%h",mask))
            `logLevel( dtlb, 2, $format("DTLB: lower_ppn:%h",lower_ppn))
            `logLevel( dtlb, 2, $format("DTLB: lower_vpn:%h",lower_vpn))
            `logLevel( dtlb, 2, $format("DTLB: lower_pa:%h",lower_pa))
            `logLevel( dtlb, 2, $format("DTLB: highest_ppn:%h",highest_ppn))
            if (`VERBOSITY > 1) begin
              $display($time, " PT: DTLB: translating: addr %h unused %h perm %h # mask %h lower_ppn %h lower_vpn %h lower_pa %h highest_ppn %h paddr %h", va, unused_va, permissions, mask, lower_ppn, lower_vpn, lower_pa, highest_ppn, physicaladdress);
            end

            // check for permission faults
            if(unused_va != signExtend(va[`maxvaddr-1])) begin
              page_fault = True;
            end
            // pte_1g.a == 0 || pte_1g.d == 0 and access != Load
            if(!permissions.a || (!permissions.d && req.access != 0)) begin
              page_fault = True;
            end
            if(req.access == 0 && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
              page_fault = True;
            end
            if(priv == 1 && permissions.u && sum == 0) begin // supervisor accessing user
              page_fault = True;
            end
            if(!permissions.u && priv == 0) begin
              page_fault = True;
            end

            // for Store access
            if(req.access != 0 && !permissions.w) begin // if not writable
              page_fault = True;
            end

            // Store and Dirty bit unset
            if (req.access == 1 && !permissions.d) begin
              page_fault = True;
            end
            // Writable pages must also be readable
            if (permissions.w && !permissions.r) begin
              page_fault = True;
            end

            // For non-leaf PTEs, the D, A, and U bits should be cleared.
            if ((!permissions.r && !permissions.w && !permissions.x) && (permissions.d || permissions.a || permissions.u)) begin
              page_fault = True;
            end

            // Reserved cases
            if ((!permissions.x && permissions.w && !permissions.r) || (permissions.x && permissions.w && !permissions.r)) begin
              page_fault = True;
            end

            // miss in all tables
            if(tlbmiss) begin
              rg_miss_queue <= va;
              core_resp= (DTLB_Cache_response{address  : ?,
                                            trap     : False,
                                            exception: exception,
                                            tlbmiss  : True});
              if (`VERBOSITY > 1) begin
                $display($time, " PT: DTLB: miss in tlb");
              end
            end
            // hit in 1g table
            else begin
              `logTimeLevel( dtlb, 0, $format("DTLB: Sending PA:%h Trap:%b", physicaladdress, page_fault))
              `logTimeLevel( dtlb, 0, $format("DTLB: Hit in TLB:",fshow(pte_1g)))
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

          end // request serviced

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
      Bit#(xlen) va = vaddr;
      Bool translation_done = False;

      /*doc:func: check for 4k hit*/
      function Bool fn_vtag_match_4k (VPNTag_4K t);
        Bit#(TSub#(`vpnsize, TLog#(`dtlbsets_4k))) vpn = truncateLSB(fullvpn);
        return t.permissions.v && (vpn == t.vpn) && ((t.asid == satp_asid) || t.permissions.g);
      endfunction

      Bit#(TLog#(`dtlbsets_4k)) set_index_4k = (valueOf(TLog#(`dtlbsets_4k)) == 0) ? 0 : fullvpn[valueOf(TLog#(`dtlbsets_4k))-1:0]; 
      let hit_entry_4k = find(fn_vtag_match_4k, readVReg(v_vpn_tags_4k[set_index_4k])); 
      Bool tlbmiss_4k = !isValid(hit_entry_4k);
      VPNTag_4K pte_4k = fromMaybe(?, hit_entry_4k);

      /*doc:func: check for 2m hit*/
      Bit#(TSub#(`vpnsize, `subvpn)) vpn_2m = truncateLSB(fullvpn);
      function Bool fn_vtag_match_2m (VPNTag_2M t);
        Bit#(TSub#(`vpnsize, TAdd#(TLog#(`dtlbsets_2m), `subvpn))) vpn = truncateLSB(vpn_2m);
        return t.permissions.v && (vpn == t.vpn) && ((t.asid == satp_asid) || t.permissions.g);
      endfunction

      Bit#(TLog#(`dtlbsets_2m)) set_index_2m = (valueOf(TLog#(`dtlbsets_2m)) == 0) ? 0 : vpn_2m[valueOf(TLog#(`dtlbsets_2m))-1:0]; 
      let hit_entry_2m = find(fn_vtag_match_2m, readVReg(v_vpn_tags_2m[set_index_2m])); 
      Bool tlbmiss_2m = !isValid(hit_entry_2m);
      VPNTag_2M pte_2m = fromMaybe(?, hit_entry_2m);

      /*doc:func: check for 1g hit*/
      Bit#(TSub#(`vpnsize, TMul#(`subvpn, 2))) vpn_1g = truncateLSB(fullvpn);
      function Bool fn_vtag_match_1g (VPNTag_1G t);
        Bit#(TSub#(`vpnsize, TAdd#(TLog#(`dtlbsets_1g), TMul#(`subvpn, 2)))) vpn = truncateLSB(vpn_1g);
        return t.permissions.v && (vpn == t.vpn) && ((t.asid == satp_asid) || t.permissions.g);
      endfunction

      Bit#(TLog#(`dtlbsets_1g)) set_index_1g = (valueOf(TLog#(`dtlbsets_1g)) == 0) ? 0 : vpn_1g[valueOf(TLog#(`dtlbsets_1g))-1:0]; 
      let hit_entry_1g = find(fn_vtag_match_1g, readVReg(v_vpn_tags_1g[set_index_1g])); 
      Bool tlbmiss_1g = !isValid(hit_entry_1g);
      VPNTag_1G pte_1g = fromMaybe(?, hit_entry_1g);
      
      Bit#(TSub#(xlen, paddr)) upper_bits = truncateLSB(vaddr);
      Bit#(2) priv = mprv == 0?wr_priv : mpp;
      translation_done = (satp_mode == 0 || priv == 3);

      Bool tlbmiss = tlbmiss_4k && tlbmiss_2m && tlbmiss_1g;

      if(!trap && translation_done) begin
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

        if (((!tlbmiss_4k && !tlbmiss_2m) || (!tlbmiss_2m && !tlbmiss_1g) || (!tlbmiss_1g && !tlbmiss_4k)) && (`VERBOSITY > 1)) begin
          let x = $display($time, " DTLB: multiple hits detected! 4K:%d,2M:%d,1G:%d", !tlbmiss_4k, !tlbmiss_2m, !tlbmiss_1g);
        end

        if (!tlbmiss_4k) begin
          let permissions = pte_4k.permissions;
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = '1;
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte_4k.ppn);
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa = (mask & lower_ppn) | (~mask & lower_vpn);
          Bit#(`lastppnsize) highest_ppn = truncateLSB(pte_4k.ppn);
          lv_paddr = zeroExtend({highest_ppn, lower_pa, page_offset});

          // check for permission faults
            if(unused_va != signExtend(va[`maxvaddr-1])) begin
              page_fault = True;
            end
          // pte_4k.a == 0 || pte_4k.d == 0 and access != Load
          if(!permissions.a || (!permissions.d && (is_store == 1))) begin
            page_fault = True;
          end
          if((is_store == 0) && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
            page_fault = True;
          end
          if(priv == 1 && permissions.u && sum == 0) begin // supervisor accessing user
            page_fault = True;
          end
          if(!permissions.u && priv == 0) begin
            page_fault = True;
          end

          // for Store access
          if((is_store == 1) && !permissions.w) begin // if not writable
            page_fault = True;
          end

          // Store and Dirty bit unset
          if ((is_store == 1) && !permissions.d) begin
            page_fault = True;
          end
          // Writable pages must also be readable
          if (permissions.w && !permissions.r) begin
            page_fault = True;
          end

          // For non-leaf PTEs, the D, A, and U bits should be cleared.
          if ((!permissions.r && !permissions.w && !permissions.x) && (permissions.d || permissions.a || permissions.u)) begin
            page_fault = True;
          end

          // Reserved cases
          if ((!permissions.x && permissions.w && !permissions.r) || (permissions.x && permissions.w && !permissions.r)) begin
            page_fault = True;
          end

        end // No hit in 4k
        else if (!tlbmiss_2m) begin

          let permissions = pte_2m.permissions;
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = 'h3fe00;
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte_2m.ppn);
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa = (mask & lower_ppn) | (~mask & lower_vpn);
          Bit#(`lastppnsize) highest_ppn = truncateLSB(pte_2m.ppn);
          lv_paddr = zeroExtend({highest_ppn, lower_pa, page_offset});

          // check for permission faults
          if(unused_va != signExtend(va[`maxvaddr-1])) begin
            page_fault = True;
          end
          // pte_2m.a == 0 || pte_2m.d == 0 and access != Load
          if(!permissions.a || (!permissions.d && (is_store == 1))) begin
            page_fault = True;
          end
          if((is_store == 0) && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
            page_fault = True;
          end
          if(priv == 1 && permissions.u && sum == 0) begin // supervisor accessing user
            page_fault = True;
          end
          if(!permissions.u && priv == 0) begin
            page_fault = True;
          end

          // for Store access
          if((is_store == 1) && !permissions.w) begin // if not writable
            page_fault = True;
          end

          // Store and Dirty bit unset
          if ((is_store == 1) && !permissions.d) begin
            page_fault = True;
          end
          // Writable pages must also be readable
          if (permissions.w && !permissions.r) begin
            page_fault = True;
          end

          // For non-leaf PTEs, the D, A, and U bits should be cleared.
          if ((!permissions.r && !permissions.w && !permissions.x) && (permissions.d || permissions.a || permissions.u)) begin
            page_fault = True;
          end

          // Reserved cases
          if ((!permissions.x && permissions.w && !permissions.r) || (permissions.x && permissions.w && !permissions.r)) begin
            page_fault = True;
          end

        end // No hit in 2m
        else begin

          let permissions = pte_1g.permissions;
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) mask = '0;
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_ppn = truncate(pte_1g.ppn);
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_vpn = truncate(fullvpn);
          Bit#(TMul#(TSub#(`varpages,1),`subvpn)) lower_pa = (mask & lower_ppn) | (~mask & lower_vpn);
          Bit#(`lastppnsize) highest_ppn = truncateLSB(pte_1g.ppn);
          lv_paddr = zeroExtend({highest_ppn, lower_pa, page_offset});

          // check for permission faults
          if(unused_va != signExtend(va[`maxvaddr-1])) begin
            page_fault = True;
          end
          // pte_1g.a == 0 || pte_1g.d == 0 and access != Load
          if(!permissions.a || (!permissions.d && (is_store == 1))) begin
            page_fault = True;
          end
          if((is_store == 0) && !permissions.r && (!permissions.x || mxr == 0)) begin// if not readable and not mxr  executable
            page_fault = True;
          end
          if(priv == 1 && permissions.u && sum == 0) begin // supervisor accessing user
            page_fault = True;
          end
          if(!permissions.u && priv == 0) begin
            page_fault = True;
          end

          // for Store access
          if((is_store == 1) && !permissions.w) begin // if not writable
            page_fault = True;
          end

          // Store and Dirty bit unset
          if ((is_store == 1) && !permissions.d) begin
            page_fault = True;
          end
          // Writable pages must also be readable
          if (permissions.w && !permissions.r) begin
            page_fault = True;
          end

          // For non-leaf PTEs, the D, A, and U bits should be cleared.
          if ((!permissions.r && !permissions.w && !permissions.x) && (permissions.d || permissions.a || permissions.u)) begin
            page_fault = True;
          end

          // Reserved cases
          if ((!permissions.x && permissions.w && !permissions.r) || (permissions.x && permissions.w && !permissions.r)) begin
            page_fault = True;
          end

        end

      end // request serviced

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

        `logTimeLevel( dtlb, 0, $format("DTLB: Put request for ", fshow(resp)))

        let core_req = rg_miss_queue ;
        Bit#(12) page_offset = core_req[11 : 0];

        Bit#(`vpnsize) fullvpn = truncate(core_req >> 12);
        Bit#(`ppnsize) fullppn = truncate(resp.pte >> 10);

        if (resp.levels == 0) begin

          Bit#(TSub#(`vpnsize, TLog#(`dtlbsets_4k))) actual_vpn = truncateLSB(fullvpn);

          let tag = VPNTag_4K{ permissions: unpack(truncate(resp.pte)),
                          vpn: actual_vpn,
                          asid: satp_asid,
                          ppn: fullppn };

          if(!resp.trap) begin

            Bit#(TLog#(`dtlbsets_4k)) set_index = (valueOf(TLog#(`dtlbsets_4k)) == 0) ? 0 : fullvpn[valueOf(TLog#(`dtlbsets_4k))-1:0]; 
            `logTimeLevel( dtlb, 0, $format("DTLB: Allocating index:%d in set:%d in PT:%d for (%x), ", 
                                            rgs_replace_4k[set_index], set_index, resp.levels, core_req, fshow(tag)))

            v_vpn_tags_4k[set_index][rgs_replace_4k[set_index]] <= tag;

            rgs_replace_4k[set_index] <= rgs_replace_4k[set_index] + 1;
            
          end

        end // 4K page
        else if (resp.levels == 1) begin

          Bit#(TSub#(`vpnsize, `subvpn)) vpn_2m = truncateLSB(fullvpn);
          Bit#(TSub#(`vpnsize, TAdd#(TLog#(`dtlbsets_2m), `subvpn))) actual_vpn = truncateLSB(vpn_2m);

          let tag = VPNTag_2M{ permissions: unpack(truncate(resp.pte)),
                          vpn: actual_vpn,
                          asid: satp_asid,
                          ppn: fullppn };

          if(!resp.trap) begin

            Bit#(TLog#(`dtlbsets_2m)) set_index = (valueOf(TLog#(`dtlbsets_2m)) == 0) ? 0 : vpn_2m[valueOf(TLog#(`dtlbsets_2m))-1:0]; 
            `logTimeLevel( dtlb, 0, $format("DTLB: Allocating index:%d in set:%d in PT:%d with actual_vpn %x for (%x), ", 
                                            rgs_replace_2m[set_index], set_index, resp.levels, actual_vpn, core_req, fshow(tag)))

            v_vpn_tags_2m[set_index][rgs_replace_2m[set_index]] <= tag;

            rgs_replace_2m[set_index] <= rgs_replace_2m[set_index] + 1;
            
          end

        end // 2M page
        else begin

          Bit#(TSub#(`vpnsize, TMul#(`subvpn, 2))) vpn_1g = truncateLSB(fullvpn);
          Bit#(TSub#(`vpnsize, TAdd#(TLog#(`dtlbsets_1g), TMul#(`subvpn, 2)))) actual_vpn = truncateLSB(vpn_1g);

          let tag = VPNTag_1G{ permissions: unpack(truncate(resp.pte)),
                          vpn: actual_vpn,
                          asid: satp_asid,
                          ppn: fullppn };

          if(!resp.trap) begin

            Bit#(TLog#(`dtlbsets_1g)) set_index = (valueOf(TLog#(`dtlbsets_1g)) == 0) ? 0 : vpn_1g[valueOf(TLog#(`dtlbsets_1g))-1:0]; 
            `logTimeLevel( dtlb, 0, $format("DTLB: Allocating index:%d in set:%d in PT:%d for (%x), ", 
                                            rgs_replace_1g[set_index], set_index, resp.levels, core_req, fshow(tag)))

            v_vpn_tags_1g[set_index][rgs_replace_1g[set_index]] <= tag;

            rgs_replace_1g[set_index] <= rgs_replace_1g[set_index] + 1;
            
          end

        end // 1G page

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

      method Action ma_mstatus_from_csr (Bit#(xlen) m);
        wr_mstatus <= m;
      endmethod

//    `ifdef pmp
//      method Action ma_pmp_cfg (Vector#(`PMPSIZE, Bit#(8)) pmpcfg);
//        for(Integer i = 0;i<valueOf(`PMPSIZE) ;i = i+1)
//          wr_pmp_cfg[i] <= pmpcfg[i];
//      endmethod
//      method Action ma_pmp_addr(Vector#(`PMPSIZE, Bit#(paddr)) pmpadr);
//        for(Integer i = 0;i<valueOf(`PMPSIZE) ;i = i+1)
//          wr_pmp_addr[i] <= pmpadr[i];
//      endmethod
//    `endif

    `ifdef perfmonitors
      method mv_perf_counters = wr_count_misses;
    `endif
    endinterface;
    
    `ifdef enable_cache_dump
    /*doc:method: dump the entire cache*/
    method Action ma_dump;

      for (Integer i = 0; i < `dtlbsets_4k; i = i + 1) begin
        for (Integer j = 0; j < `dtlbways_4k; j = j + 1) begin
          $display("4K: Set%d, Entry%d", i, j, fshow(v_vpn_tags_4k[i][j]));
        end
      end

      for (Integer i = 0; i < `dtlbsets_2m; i = i + 1) begin
        for (Integer j = 0; j < `dtlbways_2m; j = j + 1) begin
          $display("2M: Set%d, Entry%d", i, j, fshow(v_vpn_tags_2m[i][j]));
        end
      end

      for (Integer i = 0; i < `dtlbsets_1g; i = i + 1) begin
        for (Integer j = 0; j < `dtlbways_1g; j = j + 1) begin
          $display("1G: Set%d, Entry%d", i, j, fshow(v_vpn_tags_1g[i][j]));
        end
      end

    endmethod : ma_dump
    `endif
    
  endmodule

endpackage
`endif
