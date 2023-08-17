/*
see LICENSE.iitm

Author: Sriram Shanmuga
Email id: sriramshanmugacf+shakti@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package sa_dtlb_tb;

    import nb_dcache_types :: * ;
    import sa_dtlb::*;
    import fa_dtlb::*;

    (*synthesize*)
    module mksa_dtlb_tb();

        Ifc_sa_dtlb#(`xlen, `paddr) dut <- mksa_dtlb();
      
        Reg#(int) cycles <- mkReg(0);

        rule cycle_counter;
            cycles <= cycles + 1;
            //$display("End of Cycle:%d", cycles);
        endrule : cycle_counter

        rule ptw_meta_driver;
            dut.ptw_meta.ma_satp_from_csr(64'h8000000000080007);
            dut.ptw_meta.ma_curr_priv(2'b1);
            dut.ptw_meta.ma_mstatus_from_csr(64'h8000000a00046000);
        endrule : ptw_meta_driver

        rule cache_dump (cycles % 2 == 1);
            //dut.dump();
        endrule : cache_dump

        rule tlb_miss(cycles == 2 || cycles == 8);
            let request = Cache_DTLB_request{address : 64'h1000,
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : True,
                                            sfence : False};
            let response <- dut.translate(request);
        endrule : tlb_miss

        rule tlb_hit(cycles == 4);
            let request = Cache_DTLB_request{address : 64'h1000,
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : False};
            let response <- dut.translate(request);
        endrule : tlb_hit

        rule fence(cycles == 6);
            let request = Cache_DTLB_request{address : 64'h1000,
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : True};
            let response <- dut.translate(request);
        endrule : fence

        rule endsim (cycles == 10);
            $display("Reached the end of simulation, total cycles=\t%d", cycles);
            $finish(0);
        endrule : endsim

    endmodule : mksa_dtlb_tb

endpackage : sa_dtlb_tb