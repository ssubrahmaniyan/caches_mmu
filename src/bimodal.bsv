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
package bimodal;
	/*===== Pacakge imports ===== */
	import FIFO::*;
	import FIFOF::*;
	import SpecialFIFOs::*;
	import ConfigReg::*;
	import Connectable::*;
	import GetPut::*;
  
  /*==== Project imports ======= */
  import mem_config::*; // for bram 1rw instances.
  `include "Logger.bsv"
`ifdef ras
  import stack::*;
`endif

  typedef Tuple3#(Bit#(`vaddr), Bit#(`vaddr), Bit#(2)) Training_data;

	interface Ifc_bimodal;
    // method to receive the new pc for which prediction is to be looked up.
		method Action prediction_req(Bit#(`vaddr) pc);

    // method to respond to stage0 with prediction state and new target address on hit
		interface Get#(Tuple3#(Bit#(2), Bit#(`vaddr ), Bit#(`vaddr))) prediction_response; // TODO: send only prediction bits

    // method to training the BTB and BHT tables
		method Action train_bpu (Training_data td);

    method Tuple2#(Bit#(2), Bit#(`vaddr)) prediction_pc;
  `ifdef ras
    method Action train_ras(Bit#(`vaddr) pc);
    method Action ras_push(Bit#(`vaddr) pc);
  `endif
	endinterface

	(*synthesize*)
	module mkbimodal(Ifc_bimodal);
    String bimodal="";
    // ram to hold the target address. // TODO need to store only offset?
    Ifc_mem_config1r1w#(`btbsize , `vaddr, 1) mem_btb <- mkmem_config1r1w(False,"double");

    // ram to hold the tag of the address being predicted. The 2 bits are deducted since we are
    // supporting only non-compressed ISA. When compressed is supported, 1 will be dedudcted.
    Ifc_mem_config1r1w#(`btbsize , TSub#(TSub#(`vaddr, TLog#(`btbsize)),2), 1) mem_btb_tag 
                                                              <- mkmem_config1r1w(False,"double");

    // ram to hold the state of the history table.
    Ifc_mem_config1r1w#(`btbsize, 3, 1) mem_bht_state <- mkmem_config1r1w(False,"double");
  `ifdef ras 
    // ram to hold the tag bits for return instructions
    Ifc_mem_config1r1w#(`rassets, TSub#(TSub#(`vaddr, TLog#(`rassets )), 2),1) mem_ras_tag
                                                              <- mkmem_config1r1w(False,"double");
    // ram to hold the state of the ras entries.
    Ifc_mem_config1r1w#(`rassets, 1, 1) mem_ras_state <- mkmem_config1r1w(False,"double");

    // stack structure to hold the return addresses
    Ifc_stack#(`vaddr, `rassize) ras_stack <- mkstack;
  `endif

    // boolean register and counter used to initialize the ram structure on reset.
    Reg#(Bool) rg_init <- mkReg(True);
    Reg#(Bit#(TAdd#(1,TLog#(TMax#(`btbsize, `rassets))))) rg_init_count <- mkReg(0);

    FIFOF#(Bit#(`vaddr)) ff_pred_request <- mkSizedFIFOF(2);
    FIFOF#(Tuple3#(Bit#(2),Bit#(`vaddr),Bit#(`vaddr))) ff_prediction_resp <- mkBypassFIFOF();

    Reg#(Tuple2#(Bit#(2), Bit#(`vaddr))) rg_prediction_pc[2] <-mkCReg(2,tuple2(0,?));
    
    // RuleName: initialize
    // Explicit Conditions: rg_init==True
    // Implicit Conditions: None
    // on system reset first initialize the ram structure with valid=0.
    rule initialize(rg_init);
      mem_bht_state.write(1, truncate(rg_init_count),3'b001);
    `ifdef ras
      mem_ras_state.write(1 , truncate(rg_init_count),0);
    `endif
      if(rg_init_count==fromInteger(max(`btbsize,`rassets))) begin
				rg_init<=False;
			end
      `logLevel( bimodal, 0, $format("Bimodal: Init stage. Count:%d",rg_init_count))
      rg_init_count<=rg_init_count+1;
		endrule

    // RuleName: perform_prediction
    // Explicit Conditions: None
    // Implicit Conditions: None
    // Description: This rule will the prediction response from the BTB and RAS and send the result
    // to stage1. A hit can occur either in the BTB or the RAS and never both
    rule perform_prediction(!rg_init);
      let va = ff_pred_request.first();
      ff_pred_request.deq();
      Bit#(2) prediction=0;

      Bit#(TSub#(TSub#(`vaddr , TLog#(`btbsize)),2)) tag1 = truncateLSB(va);
      let bimodal_target_addr = mem_btb.read_response;
      let bht_tag = mem_btb_tag.read_response;
      let state = mem_bht_state.read_response;
    `ifdef ras
      Bit#(TSub#(TSub#(`vaddr , TLog#(`rassets)),2)) tag2 = truncateLSB(va);
      let ras_tag = mem_ras_tag.read_response;
      let ras_valid = mem_ras_state.read_response;
      let ras_target_address = ras_stack.top;
    `endif

      Bit#(`vaddr) target_address=bimodal_target_addr;
      if (tag1 == bht_tag && state[2]==1) begin
        prediction=state[1:0];
        `logLevel( bimodal, 1, $format("Bimodal: BTB hit"))
      end
    `ifdef ras
      if( tag2 == ras_tag && ras_valid==1 && !ras_stack.empty)begin
        prediction=3;
        target_address=ras_target_address;
        ras_stack.pop;
        `logLevel( bimodal, 1, $format("Bimodal: RAS hit"))
      end
    `endif
      Tuple3#(Bit#(2), Bit#(`vaddr), Bit#(`vaddr)) resp = tuple3(prediction,target_address,va);
      `logLevel( bimodal, 0, $format("Bimodal: enquing Response:",fshow(resp)))
      rg_prediction_pc[0]<=tuple2(prediction,target_address);
      ff_prediction_resp.enq(resp);
    endrule

    // MethodName: prediction_req
    // Explicit Conditions: rg_init==False
    // Implicit Conditions: None
    // Description: This rule will latch the index of the PC to be predicted.
		method Action prediction_req(Bit#(`vaddr) pc)if(!rg_init);
      Bit#(TLog#(`btbsize )) index = truncate(pc>>2);
      `logLevel( bimodal, 0, $format("Bimodal: Prediction request for PC:%h",pc))
      mem_btb.read(index);
      mem_btb_tag.read(index);
      mem_bht_state.read(index);
    `ifdef ras
      Bit#(TLog#(`rassets)) index1 = truncate(pc>>2);
      mem_ras_state.read(index1);
      mem_ras_tag.read(index1);
    `endif
      ff_pred_request.enq(pc);
		endmethod

    // MethodName: prediction_resp
    // Explicit Conditions: rg_init==False
    // Implicit Conditions: None
    // Description: This rule read the response from the rams, check if the next PC is either PC+4
    // or redirected to a new target address. The redirect address is directly taken from the ram.
    // If there is not hit in the BTB the prediction value of 0 is sent indicating that the next PC
    // is PC+4 which needs to happen outside this module
		interface prediction_response = interface Get
      method ActionValue#(Tuple3#(Bit#(2), Bit#(`vaddr), Bit#(`vaddr))) get()if(!rg_init);
        ff_prediction_resp.deq;
        return ff_prediction_resp.first();
      endmethod
    endinterface;

    // MethodName: training
    // Explicit Conditions: rg_init==False
    // Implicit Conditions: None 
    // Description: This method will update the BTB and BHT with the new training packet from the
    // execute stage
		method Action train_bpu (Training_data td)if(!rg_init);
      let {pc, branch_address, state} = td;
        Bit#(TLog#(`btbsize )) index = truncate(pc>>2);
        Bit#(TSub#(TSub#(`vaddr , TLog#(`btbsize)),2)) tag = truncateLSB(pc);
        mem_btb.write(1, index,branch_address);
        mem_btb_tag.write(1, index, tag);
        mem_bht_state.write(1, index, {1'b1,state});
        `logLevel( bimodal, 0, $format("Bimodal: Training BTB for ",fshow(td)))
        `logLevel( bimodal, 0, $format("Bimodal: Training BTB: index:%d tag:%h state:%b", index,tag,state))
		endmethod

    // MethodName: prediction_pc
    // Explicit Conditions: None
    // Implicit Conditions: None 
    // Description: This method sends the latest prediction to stage0 for generating next pc
    method prediction_pc=rg_prediction_pc[1];

  `ifdef ras
    // MethodName: train_ras
    // Explicit Conditions: rg_init==False
    // Implicit Conditions: None 
    // Description: This method will update the RAS tag and state entries to indicate a pop
    method Action train_ras(Bit#(`vaddr) pc)if(!rg_init);
      Bit#(TLog#(`rassets )) index = truncate(pc>>2);
      Bit#(TSub#(TSub#(`vaddr , TLog#(`rassets)),2)) tag = truncateLSB(pc);
      mem_ras_state.write(1, index, 1);
      mem_ras_tag.write(1,index, tag);
      `logLevel( bimodal, 0, $format("Bimodal: Training RAS for ",fshow(pc)))
    endmethod

    // MethodName: ras_push
    // Explicit Conditions: None
    // Implicit Conditions: None 
    // Description: This method will push a return address on the RAS stack
    method Action ras_push(Bit#(`vaddr) pc);
      `logLevel( bimodal, 0, $format("Bimodal: Pushing to RAS:%h ",pc))
      ras_stack.push(pc);
    endmethod
  `endif
	endmodule
endpackage
