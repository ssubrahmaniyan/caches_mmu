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
    import fa_dtlb::*;

    (*synthesize*)
    module mksa_dtlb_tb();

        Ifc_sa_dtlb#(`xlen, `paddr) dut <- mksa_dtlb();
      
        Reg#(int) cycles <- mkReg(0);

        rule cycle_counter;
            cycles <= cycles + 1;
            $display("End of Cycle:%d", cycles);
        endrule : cycle_counter

        rule ptw_meta_driver;
            dut.ptw_meta.ma_satp_from_csr(64'h8000000000080007);
            dut.ptw_meta.ma_curr_priv(2'b1);
            dut.ptw_meta.ma_mstatus_from_csr(64'h8000000a00046000);
        endrule : ptw_meta_driver

        rule cache_dump (cycles == 9);
            dut.dump();
            let sresp = dut.early_lookup(64'h80123456, 1'b0);
            $display(fshow(sresp));
        endrule : cache_dump

        rule tlb_miss(cycles == 2 || cycles == 10);
            let request = Cache_DTLB_request{address : 64'h80123456,
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : False};
            let response <- dut.translate(request);
        endrule : tlb_miss

        rule fill_cache (cycles == 3);
            dut.response_frm_ptw.put(PTWalk_tlb_response{pte : 54'h200000cf,
                                                        levels : 1,
                                                        trap : False,
                                                        cause : ?});
        endrule : fill_cache

        rule tlb_hit(cycles == 4);
            let request = Cache_DTLB_request{address : 64'h80123456,
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : False};
            let response <- dut.translate(request);
            let sresp = dut.early_lookup(64'h80123456, 1'b0);
            $display(fshow(sresp));
            dut.dump();
        endrule : tlb_hit

        rule fence(cycles == 6);
            let request = Cache_DTLB_request{address : 64'h80123456,
                                            access : 2'b0,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : True};
            let response <- dut.translate(request);
        endrule : fence

        rule endsim (cycles == 14);
            $display("Reached the end of simulation, total cycles=\t%d", cycles);
            $finish(0);
        endrule : endsim

    endmodule : mksa_dtlb_tb

endpackage : sa_dtlb_tb