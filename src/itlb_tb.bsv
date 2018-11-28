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
package itlb_tb;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;

//  import itlb_rv32_bram::*;
  import itlb_rv32_array::*;
  import itlb_rv64_array::*;

//  (*synthesize*)
//  module mkitlb_rv32bram(Ifc_itlb_rv32_bram#(8,8,1,1,9));
//    Ifc_itlb_rv32_bram#(8,8,1,1,9) itlb1 <- mkitlb_rv32_bram(True,"RANDOM","RANDOM");
//    interface core_req=itlb1.core_req;
//    interface satp_from_csr=itlb1.satp_from_csr;
//    interface curr_priv=itlb1.curr_priv;
//    interface req_to_ptw=itlb1.req_to_ptw;
//    interface core_resp=itlb1.core_resp;
//    interface resp_from_ptw=itlb1.resp_from_ptw;
//    interface fence_tlb=itlb1.fence_tlb;
//  endmodule
  
  (*synthesize*)
  module mkitlb_rv32array(Ifc_itlb_rv32_array#(8,8,1,1,9));
    Ifc_itlb_rv32_array#(8,8,1,1,9) itlb2 <- mkitlb_rv32_array("RANDOM","RANDOM");
    interface core_req=itlb2.core_req;
    interface satp_from_csr=itlb2.satp_from_csr;
    interface curr_priv=itlb2.curr_priv;
    interface req_to_ptw=itlb2.req_to_ptw;
    interface core_resp=itlb2.core_resp;
    interface resp_from_ptw=itlb2.resp_from_ptw;
    interface fence_tlb=itlb2.fence_tlb;
  endmodule
  
  (*synthesize*)
  module mkitlb_rv64array(Ifc_itlb_rv64_array#(8,8,8,1,1,1,9));
    Ifc_itlb_rv64_array#(8,8,8,1,1,1,9) itlb3 <- mkitlb_rv64_array("RANDOM","RANDOM");
    interface core_req=itlb3.core_req;
    interface satp_from_csr=itlb3.satp_from_csr;
    interface curr_priv=itlb3.curr_priv;
    interface req_to_ptw=itlb3.req_to_ptw;
    interface core_resp=itlb3.core_resp;
    interface resp_from_ptw=itlb3.resp_from_ptw;
    interface fence_tlb=itlb3.fence_tlb;
  endmodule
endpackage

