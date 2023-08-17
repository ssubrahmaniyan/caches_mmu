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

    (*synthesize*)
    module mksa_dtlb_tb();

        Ifc_sa_dtlb#(`xlen, `paddr) dut <- mksa_dtlb();

        Reg#(int) cycles <- mkReg(0);

        rule cycle_counter;
            cycles <= cycles + 1;
            $display("Cycle:%d", cycles);
        endrule : cycle_counter

        rule tlb_miss(cycles == 2);
            $display("TLB Miss");
            let request = Cache_DTLB_request{address : 64'h00001000,
                                            access : 2'b00,
                                            ptwalk_trap : False,
                                            ptwalk_req : True,
                                            sfence : False};
            let response = dut.translate(request);
        endrule : tlb_miss

        rule tlb_hit(cycles == 5);
            $display("TLB Hit");
            let request = Cache_DTLB_request{address : 64'h00001000,
                                            access : 2'b00,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : False};
            let response = dut.translate(request);
        endrule : tlb_hit

        rule fence(cycles == 6);
            $display("FENCE");
            let request = Cache_DTLB_request{address : 64'h00001000,
                                            access : 2'b00,
                                            ptwalk_trap : False,
                                            ptwalk_req : False,
                                            sfence : True};
            let response = dut.translate(request);
        endrule : fence

        rule endsim (cycles == 10);
            $display("Ending simulation");
            $finish(0);
        endrule : endsim

    endmodule : mksa_dtlb_tb

endpackage : sa_dtlb_tb