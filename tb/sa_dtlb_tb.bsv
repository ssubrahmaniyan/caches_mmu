/*
see LICENSE.iitm

Author: Sriram Shanmuga
Email id: sriramshanmugacf+shakti@gmail.com
Details: Testbench for the multi-page dtlb (sa_dtlb.bsv). 

Every 20 cycles, the pagesize is cycled from 0 to 2 using 'levels' and the following rules take place in order: 

	T    : tlb_miss
	T+4  : fill_cache
	T+8  : tlb_hit
	T+10 : sideband_access
	T+12 : fence
	T+18 : probe

Note: rule ptw_meta_driver is essential for the functioning of the module.
Note: define enable_cache_dump in "nb_dcache.defines" for enabling ma_dump.
Note: Every new issue is marked by "NEW ISSUE" in logs.

--------------------------------------------------------------------------------------------------
*/
package sa_dtlb_tb;

    `include "nb_dcache.defines"

    import GetPut::*;
    import nb_dcache_types :: * ;
    import common_tlb_types :: *;
    import dtlb :: *;

    (*synthesize*)
    /*doc:module:*/
    module mksa_dtlb_tb();

        Ifc_dtlb#(`xlen, `paddr) dut <- mk_dtlb();
      
        Reg#(int) cycles <- mkReg(1);
        Reg#(Bit#(2)) levels <- mkReg(0);

	/*doc:rule: this rule is fired every cycle which counts the cycles. */
        rule cycle_counter;
            cycles <= cycles + 1;
        endrule : cycle_counter

        /*doc:rule: this rule drives the ptw_meta values.*/
        rule ptw_meta_driver;
            dut.ptw_meta.ma_satp_from_csr(64'h8000000000080007);
            dut.ptw_meta.ma_curr_priv(2'b1);
            dut.ptw_meta.ma_mstatus_from_csr(64'h8000000a00046000);
        endrule : ptw_meta_driver

	/*doc:rule: this rule issues a request that results in TLB miss.*/
        rule tlb_miss(cycles % 20 == 0);
		
	        $display("NEW ISSUE");
            let request = Cache_DTLB_request{address : 64'h80122456,
                                            access : 2'b1,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : False};

            let response <- dut.translate(request);

        endrule : tlb_miss

	/*doc:rule: this rule populates the cache with a legal entry.*/
        rule fill_cache ((cycles >= 4) && ((cycles-4) % 20 == 0));

	        levels <= levels + 1;

            dut.response_frm_ptw.put(PTWalk_tlb_response{pte : 54'h200000cf,
                                                        levels : levels%3,
                                                        trap : False,
                                                        cause : ?});

        endrule : fill_cache

	/*doc:rule: this rule issues a request that results in TLB hit.*/
        rule tlb_hit ((cycles >= 8) && ((cycles-8) % 20 == 0));

            let request = Cache_DTLB_request{address : 64'h80122456,
                                            access : 2'b1,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : False};

            let response <- dut.translate(request);

        endrule : tlb_hit

	/*doc:rule: this rule issues a sideband access request.*/
        rule sideband_access((cycles >= 10) && ((cycles-10) % 20 == 0));
            let sresp = dut.early_lookup(64'h80122456, 1'b0);
            $display(fshow(sresp));
        endrule : sideband_access
 
	/*doc:rule: this rule issues a request that invalidates all TLB entries.*/
        rule fence((cycles >= 12) && ((cycles-12) % 20 == 0));

            let request = Cache_DTLB_request{address : 64'h0,
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : True};

            let response <- dut.translate(request);

        endrule : fence

	`ifdef enable_cache_dump
	/*doc:rule: this rule dumps the entire cache.*/
        rule probe ((cycles >= 18) && ((cycles-18) % 20 == 0));
            dut.ma_dump();
        endrule : probe
	`endif	

	/*doc:rule: this rule wraps up the simulation.*/
        rule endsim ((cycles/20) == 5);
            $display("Reached the end of simulation, total cycles=\t%d", cycles);
            $finish(0);
        endrule : endsim

    endmodule : mksa_dtlb_tb

endpackage : sa_dtlb_tb
