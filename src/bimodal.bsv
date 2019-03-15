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
  import Assert::*;
  
  /*==== Project imports ======= */
  import mem_config::*; // for bram 1rw instances.
  import globals::*;
  `include "Logger.bsv"
`ifdef ras
  import stack::*;
`endif

  `ifdef compressed
    `define ignore 2
  `else
    `define ignore 3
  `endif

  typedef Tuple3#(Bit#(`vaddr), Bit#(`vaddr), Bit#(2)) Training_data;
`ifdef compressed
  typedef Tuple4#(Bit#(2), Bit#(2), Bit#( `vaddr ), Bool) PredictionResponse;
`else
  typedef Tuple2#(Bit#(2), Bit#(`vaddr )) PredictionResponse;
`endif

	interface Ifc_bimodal;
    // method to receive the new pc for which prediction is to be looked up.
		method Action prediction_req(Bit#(`vaddr) pc `ifdef compressed ,Bool discard `endif );

    // method to respond to stage0 with prediction state and new target address on hit
		interface Get#(PredictionResponse) prediction_response; 

    // method to training the BTB and BHT tables
		method Action train_bpu (Training_data td);

    method PredictionToStage0 predicted_pc;
  `ifdef ras
    method Action train_ras(Bit#(`vaddr) pc);
    method Action ras_push(Bit#(`vaddr) pc);
  `endif
	endinterface

	(*synthesize*)
	module mkbimodal(Ifc_bimodal);
    String bimodal="";
    Ifc_mem_config1r1w#(TDiv#(`btbsize, 2) , `vaddr, 1) mem_btb0 <- mkmem_config1r1w(False,"double");
    Ifc_mem_config1r1w#(TDiv#(`btbsize, 2) , `vaddr, 1) mem_btb1 <- mkmem_config1r1w(False,"double");

    // ram to hold the tag of the address being predicted. The 2 bits are deducted since we are
    // supporting only non-compressed ISA. When compressed is supported, 1 will be dedudcted.
    Ifc_mem_config1r1w#(TDiv#(`btbsize,  2) , 
        TAdd#(TSub#(TSub#(`vaddr, TLog#(`btbsize)),TSub#(`ignore,1)),3),1) mem_btb_tag0 
        <- mkmem_config1r1w(False,"double");
    Ifc_mem_config1r1w#(TDiv#(`btbsize,  2) , 
        TAdd#(TSub#(TSub#(`vaddr, TLog#(`btbsize)),TSub#(`ignore,1)),3),1) mem_btb_tag1 
        <- mkmem_config1r1w(False,"double");

  `ifdef ras 
    // ram to hold the tag bits for return instructions
    Ifc_mem_config1r1w#(TDiv#(`rassets ,2), 
        TAdd#(TSub#(TSub#(`vaddr, TLog#(`rassets )), TSub#(`ignore,1)),1),1) mem_ras_tag0
        <- mkmem_config1r1w(False,"double");
    Ifc_mem_config1r1w#(TDiv#(`rassets, 2), 
        TAdd#(TSub#(TSub#(`vaddr, TLog#(`rassets )), TSub#(`ignore,1)),1),1) mem_ras_tag1
        <- mkmem_config1r1w(False,"double");

    // stack structure to hold the return addresses
    Ifc_stack#(`vaddr, `rassize) ras_stack <- mkstack;
  `endif

    // boolean register and counter used to initialize the ram structure on reset.
    Reg#(Bool) rg_init <- mkReg(True);
    Reg#(Bit#(TAdd#(1,TLog#(TMax#(TDiv#(`btbsize, 2), TDiv#(`rassets,2)))))) rg_init_count <- mkReg(0);

  `ifdef compressed
    FIFOF#(Tuple2#(Bit#(`vaddr), Bool)) ff_pred_request <- mkSizedFIFOF(2);
  `else
    FIFOF#(Bit#(`vaddr)) ff_pred_request <- mkSizedFIFOF(2);
  `endif
    FIFOF#(PredictionResponse) ff_prediction_resp <- mkBypassFIFOF();

    Reg#(PredictionToStage0) rg_prediction_pc[2] <-mkCReg(2,PredictionToStage0{prediction:0});
    
    // RuleName: initialize
    // Explicit Conditions: rg_init==True
    // Implicit Conditions: None
    // on system reset first initialize the ram structure with valid=0.
    rule initialize(rg_init);
      mem_btb_tag0.write(1, truncate(rg_init_count),0);
      mem_btb_tag1.write(1, truncate(rg_init_count),0);
    `ifdef ras
      mem_ras_tag0.write(1 , truncate(rg_init_count),0);
      mem_ras_tag1.write(1 , truncate(rg_init_count),0);
    `endif
      if(rg_init_count==fromInteger(max((`btbsize/2),(`rassets/2)))) begin
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
      Bit#(4) hit=0;
    `ifdef compressed
      let {va, discard} = ff_pred_request.first();
    `else
      let va = ff_pred_request.first();
    `endif
      ff_pred_request.deq();
    `ifdef compressed
      Bit#(2) prediction0=0;
      Bit#(2) prediction1=0;
      Bit#(2) prediction=0;
    `else
      Bit#(2) prediction=0;
    `endif

      Bit#(TSub#(TSub#(`vaddr , TLog#(`btbsize)),TSub#(`ignore,1))) tag_compare = truncateLSB(va);
      let bimodal_target_addr0 = mem_btb0.read_response;
      let bht_tag_state0 = mem_btb_tag0.read_response;
      Bit#(TSub#(TSub#(`vaddr, TLog#(`btbsize)),TSub#(`ignore,1))) bht_tag0 = truncate(bht_tag_state0);
      Bit#(3) state0 = truncateLSB(bht_tag_state0);

      let bimodal_target_addr1 = mem_btb1.read_response;
      let bht_tag_state1 = mem_btb_tag1.read_response;
      Bit#(TSub#(TSub#(`vaddr, TLog#(`btbsize)),TSub#(`ignore,1))) bht_tag1 = truncate(bht_tag_state1);
      Bit#(3) state1 = truncateLSB(bht_tag_state1);
      `logLevel( bimodal, 1, $format("Bimodal: va:%h bht0:%h state0:%b bht1:%h state1:%b",va,bht_tag0,state0,bht_tag1,state1))

    `ifdef ras
      Bit#(TSub#(TSub#(`vaddr , TLog#(`rassets)),TSub#(1,`ignore))) tag2_compare = truncateLSB(va);
      let ras_tag_valid0 = mem_ras_tag0.read_response;
      Bit#(TSub#(TSub#(`vaddr,TLog#(`rassets)),TSub#(`ignore,1))) ras_tag0 = truncate(ras_tag_valid0);
      Bit#(1) ras_valid0 = truncateLSB(ras_tag_valid);
      let ras_tag_valid1 = mem_ras_tag1.read_response;
      Bit#(TSub#(TSub#(`vaddr,TLog#(`rassets)),TSub#(`ignore,1))) ras_tag1 = truncate(ras_tag_valid1);
      Bit#(1) ras_valid1 = truncateLSB(ras_tag_valid1);
      let ras_target_address = ras_stack.top;
    `endif

      Bit#(`vaddr) target_address=bimodal_target_addr0;
      if (tag_compare == bht_tag0 && state0[2]==1 `ifdef compressed && !discard `endif ) begin
      `ifdef compressed
        prediction0=state0[1:0];
        prediction=state0[1:0];
      `else
        prediction=state0[1:0];
      `endif
        `logLevel( bimodal, 1, $format("Bimodal: tag_compare:%h,tag0:%h,",tag_compare,bht_tag0))
        `logLevel( bimodal, 1, $format("Bimodal: BTB0 hit"))
        hit[0]=1;
      end
      if (tag_compare == bht_tag1 && state1[2]==1) begin
      `ifdef compressed
        prediction1=state1[1:0];
        if(hit[0]==0)begin
          target_address=bimodal_target_addr1;
          prediction=state1[1:0];
        end
        hit[0]=1;
      `else
        prediction=state1[1:0];
        target_address=bimodal_target_addr1;
        hit[1]=1;
      `endif
        `logLevel( bimodal, 1, $format("Bimodal: BTB0 hit"))
      end
    `ifdef ras
      if( tag2_compare == ras_tag0 && ras_valid0==1 && !ras_stack.empty && !discard)begin
      `ifdef compressed
        prediction0=3;
        prediction=3;
      `else
        prediction=3;
      `endif
        target_address=ras_target_address0;
        ras_stack.pop;
        `logLevel( bimodal, 1, $format("Bimodal: RAS0 hit"))
        hit[2]=1;
      end
      else if( tag2_compare == ras_tag1 && ras_valid1==1 && !ras_stack.empty)begin
      `ifdef compressed
        prediction1=3;
        if(hit2[2]==0) begin
          prediction=3;
          target_address=ras_target_address1;
        end
        hit[2]=1;
      `else
        prediction=3;
        target_address=ras_target_address0;
        hit[2]=1;
      `endif
        `logLevel( bimodal, 1, $format("Bimodal: RAS1 hit"))
        ras_stack.pop;
      end
    `endif
  `ifndef compressed
    `ifdef ASSERT
      dynamicAssert(countOnes(hit)<=1, "Multiple hits in BPU");
    `endif
  `endif
    `ifdef compressed
      PredictionResponse resp = tuple4(prediction0,prediction1,va, discard);
    `else
      PredictionResponse resp = tuple2(prediction,va);
    `endif
      `logLevel( bimodal, 0, $format("Bimodal: enquing Response:",fshow(resp)))
      rg_prediction_pc[0]<=PredictionToStage0{prediction:prediction,
                                              target_pc :target_address};
      ff_prediction_resp.enq(resp);
    endrule

    // MethodName: prediction_req
    // Explicit Conditions: rg_init==False
    // Implicit Conditions: None
    // Description: This rule will latch the index of the PC to be predicted.
		method Action prediction_req(Bit#(`vaddr) pc `ifdef compressed , Bool discard `endif )if(!rg_init);
      Bit#(TLog#(TDiv#(`btbsize, 2))) index = truncate(pc>>`ignore);
      mem_btb0.read(index);
      mem_btb1.read(index);
      mem_btb_tag0.read(index);
      mem_btb_tag1.read(index);
    `ifdef ras
      Bit#(TLog#(TDiv#(`rassets,2))) index1 = truncate(pc>>`ignore);
      mem_ras_tag0.read(index1);
      mem_ras_tag1.read(index1);
    `endif
    `ifdef compressed
      ff_pred_request.enq(tuple2(pc, discard));
    `else
      ff_pred_request.enq(pc);
    `endif
      `logLevel( bimodal, 0, $format("Bimodal: Prediction request for PC:%h index:%d",pc,index))
		endmethod

    // MethodName: prediction_resp
    // Explicit Conditions: rg_init==False
    // Implicit Conditions: None
    // Description: This rule read the response from the rams, check if the next PC is either PC+4
    // or redirected to a new target address. The redirect address is directly taken from the ram.
    // If there is not hit in the BTB the prediction value of 0 is sent indicating that the next PC
    // is PC+4 which needs to happen outside this module
		interface prediction_response = interface Get
      method ActionValue#(PredictionResponse) get()if(!rg_init);
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
        Bit#(TLog#(TDiv#(`btbsize , 2))) index = truncate(pc>>`ignore);
        Bit#(TSub#(TSub#(`vaddr , TLog#(`btbsize)),TSub#(`ignore,1))) tag = truncateLSB(pc);
        if (pc[`ignore - 1]==0)begin
          mem_btb0.write(1, index,branch_address);
          mem_btb_tag0.write(1, index, {1'b1,state,tag});
          `logLevel( bimodal, 0, $format("Bimodal: Training BTB0: ",fshow(td)))
          `logLevel( bimodal, 0, $format("Bimodal: Training BTB0: index:%d tag:%h state:%b", index,tag,state))
        end
      `ifndef branch_speculation
        else begin
          mem_btb1.write(1, index,branch_address);
          mem_btb_tag1.write(1, index, {1'b1,state,tag});
          `logLevel( bimodal, 0, $format("Bimodal: Training BTB1: ",fshow(td)))
          `logLevel( bimodal, 0, $format("Bimodal: Training BTB1: index:%d tag:%h state:%b", index,tag,state))
        end
      `endif
		endmethod

    // MethodName: prediction_pc
    // Explicit Conditions: None
    // Implicit Conditions: None 
    // Description: This method sends the latest prediction to stage0 for generating next pc
    method predicted_pc=rg_prediction_pc[1];

  `ifdef ras
    // MethodName: train_ras
    // Explicit Conditions: rg_init==False
    // Implicit Conditions: None 
    // Description: This method will update the RAS tag and state entries to indicate a pop
    method Action train_ras(Bit#(`vaddr) pc)if(!rg_init);
      Bit#(TLog#(TDiv#(`rassets, 2))) index = truncate(pc>>2);
      Bit#(TSub#(TSub#(`vaddr , TLog#(`rassets)),TSub#(`ignore,1))) tag = truncateLSB(pc);
      if(pc[`ignore -1]==0)begin
        mem_ras_tag0.write(1,index, {1'b1,tag});
        `logLevel( bimodal, 0, $format("Bimodal: Training RAS0 for ",fshow(pc)))
      end
    `ifndef branch_speculation
      else begin
        mem_ras_tag1.write(1,index, {1'b1,tag});
        `logLevel( bimodal, 0, $format("Bimodal: Training RAS0 for ",fshow(pc)))
      end
    `endif
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
