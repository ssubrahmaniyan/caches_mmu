/*
see LICENSE.iitm

Author: Sriram Shanmuga
Email id: sriramshanmugacf+shakti@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package sa_dtlb_tb;

    `include "nb_dcache.defines"

    import GetPut::*;
    import nb_dcache_types :: * ;
    import common_tlb_types :: *;
    import sa_dtlb::*;

    (*synthesize*)
    /*doc:module:*/
    module mksa_dtlb_tb();

        Ifc_sa_dtlb#(`xlen, `paddr) dut <- mksa_dtlb();
      
        Reg#(int) cycles <- mkReg(0);

	/*doc:rule: this rule is fired every cycle which counts the cycles. */
        rule cycle_counter;
            cycles <= cycles + 1;
            //$display("End of Cycle:%d", cycles);
        endrule : cycle_counter

	/*doc:rule: this rule dumps the entire cache.*/
        rule probe (cycles == 13);
            //dut.ma_dump();
        endrule : probe

	/*doc:rule: this rule drives the ptw_meta values.*/
        rule ptw_meta_driver;
            dut.ptw_meta.ma_satp_from_csr(64'h8000000000080007);
            dut.ptw_meta.ma_curr_priv(2'b1);
            dut.ptw_meta.ma_mstatus_from_csr(64'h8000000a00046000);
        endrule : ptw_meta_driver

	/*doc:rule: this rule issues a request that results in TLB miss.*/
        rule tlb_miss(cycles == 2 || cycles == 9);
            let request = Cache_DTLB_request{address : (cycles == 2 ? 64'h80122456 : 64'h90122456),
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : False};
            let response <- dut.translate(request);
        endrule : tlb_miss

	/*doc:rule: this rule populates the cache with a legal entry.*/
        rule fill_cache (cycles == 3 || cycles == 12);
            dut.response_frm_ptw.put(PTWalk_tlb_response{pte : 54'h200000cf,
                                                        levels : 1,
                                                        trap : False,
                                                        cause : ?});
        endrule : fill_cache

	/*doc:rule: this rule issues a request that results in TLB hit.*/
        rule tlb_hit(cycles == 4);
            let request = Cache_DTLB_request{address : 64'h80122456,
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : False};
            let response <- dut.translate(request);
        endrule : tlb_hit

	/*doc:rule: this rule issues a sideband access request.*/
	rule sideband_access(cycles == 4);
            let sresp = dut.early_lookup(64'h80122456, 1'b0);
            $display(fshow(sresp));
	endrule : sideband_access
 
	/*doc:rule: this rule issues a request that invalidates all TLB entries.*/
        rule fence(cycles == 6);
            let request = Cache_DTLB_request{address : 64'h80122456,
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : True};
            let response <- dut.translate(request);
        endrule : fence

	/*doc:rule: this rule wraps up the simulation.*/
        rule endsim (cycles == 14);
            $display("Reached the end of simulation, total cycles=\t%d", cycles);
            $finish(0);
        endrule : endsim

    endmodule : mksa_dtlb_tb

endpackage : sa_dtlb_tb
