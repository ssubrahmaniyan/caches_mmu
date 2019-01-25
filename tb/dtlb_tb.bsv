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

--------------------------------------------------------------------------------------------------
*/
package dtlb_tb;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;

//  import dtlb_rv32_bram::*;
//  import dtlb_rv32_array::*;
  import dtlb_rv64_array::*;

 // (*synthesize*)
 // module mkdtlb_rv32bram(Ifc_dtlb_rv32_bram#(8,8,1,1,9));
 //   Ifc_dtlb_rv32_bram#(8,8,1,1,9) dtlb1 <- mkdtlb_rv32_bram(True,"RANDOM","RANDOM");
 //   interface core_req=dtlb1.core_req;
 //   interface satp_from_csr=dtlb1.satp_from_csr;
 //   interface curr_priv=dtlb1.curr_priv;
 //   interface req_to_ptw=dtlb1.req_to_ptw;
 //   interface core_resp=dtlb1.core_resp;
 //   interface resp_from_ptw=dtlb1.resp_from_ptw;
 //   interface fence_tlb=dtlb1.fence_tlb;
 // endmodule
//  
//  (*synthesize*)
//  module mkdtlb_rv32array(Ifc_dtlb_rv32_array#(8,8,1,1,9));
//    Ifc_dtlb_rv32_array#(8,8,1,1,9) dtlb2 <- mkdtlb_rv32_array("RANDOM","RANDOM");
//    interface core_req=dtlb2.core_req;
//    interface satp_from_csr=dtlb2.satp_from_csr;
//    interface curr_priv=dtlb2.curr_priv;
//    interface req_to_ptw=dtlb2.req_to_ptw;
//    interface core_resp=dtlb2.core_resp;
//    interface resp_from_ptw=dtlb2.resp_from_ptw;
//    interface fence_tlb=dtlb2.fence_tlb;
//    interface mstatus_from_csr=dtlb2.mstatus_from_csr;
//  endmodule
//  
  (*synthesize*)
  module mkdtlb_rv64array(Ifc_dtlb_rv64_array#(32,8,8,8,1,1,1,9));
    Ifc_dtlb_rv64_array#(32,8,8,8,1,1,1,9) dtlb3 <- mkdtlb_rv64_array("RANDOM","RANDOM");
    interface core_req=dtlb3.core_req;
    interface satp_from_csr=dtlb3.satp_from_csr;
    interface curr_priv=dtlb3.curr_priv;
    interface req_to_ptw=dtlb3.req_to_ptw;
    interface core_resp=dtlb3.core_resp;
    interface resp_from_ptw=dtlb3.resp_from_ptw;
    interface mstatus_from_csr=dtlb3.mstatus_from_csr;
  `ifdef pmp
    interface pmp_cfg=dtlb3.pmp_cfg;
    interface pmp_addr=dtlb3.pmp_addr;
  `endif
  endmodule
endpackage

