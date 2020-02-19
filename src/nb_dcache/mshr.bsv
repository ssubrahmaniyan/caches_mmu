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

Author: Arjun Menon
Email id: c.arjunmenon@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package mshr;
  import nb_dcache_types::*; 	         
	import DefaultValue :: *;
  `include "Logger.bsv"           // for logging
	import FIFO::*;
	import FIFOF::*;
	import ConfigReg::*;
	import Vector::*;
	import SEMF_FIFO::*;
	import SESFMI_FIFO::*;
	`include "parameters.txt"

	interface Ifc_mshr#(numeric type paddr,
											numeric type linewidthbits,
											numeric type data,
											numeric type mshrsize,
											numeric type mshrfifo_depth,
											numeric type rob_index,
                      numeric type prf_index );
		method ActionValue#(Maybe#(Bit#(TLog#(mshrsize)))) allocate (Cache_req#(paddr, data, rob_index, prf_index) req);
		method ActionValue#(Tuple2#(Bool, MSHR_Req#(paddr, data, prf_index, rob_index))) req_to_fb(Maybe#(Bit#(TLog#(mshrsize))) v_req_rid);
		(*always_ready*) method Bit#(linewidthbits) mem_req_offset(Bit#(TLog#(mshrsize)) id);
    method Bit#(TSub#(paddr,linewidthbits)) addr_to_fb;
		method Action ack_from_fb;
		method Action flush (Flush_type#(rob_index) bundle);
		method Action fence;
		method Bool not_empty;
	endinterface

	//(* conflict_free= "ack_from_fb, rl_deq_ff"*)
	//(*preempts= "cff_valid.initialize, (cff_valid.incCtr, cff_valid.decCtr, cff_valid.both) "*)
  //(*execution_order="rl_deq_ff, ack_from_fb"*)
	module mkmshr (Ifc_mshr#(paddr, linewidthbits, data, mshrsize, mshrfifo_depth, rob_index, prf_index))
				 provisos ( Add#(addr_in_mshr, linewidthbits, paddr),
				 						Add#(mshrfifo_depth, 0, `Mshrfifo_depth),
                    Add#(a__, prf_index, data)
			 						 );
		let paddr_val= valueOf(paddr);
		let linewidthbits_val= valueOf(linewidthbits);
		let mshrsize_val= valueOf(mshrsize);
		let mshrfifo_depth_val= valueOf(mshrfifo_depth);

		function Bool should_flush(Bit#(rob_index) head, Bit#(rob_index) flush_rob, Bit#(rob_index) rob);
			Bool lv_should_flush= False;
			Bool cond1= (rob>=flush_rob);
			Bool cond2= (rob<head && head!=0);

			if(head<=flush_rob) begin
				if( cond1 || cond2 ) begin
					lv_should_flush= True;
				end
			end
			else if(cond1 && cond2) begin
				lv_should_flush= True;
			end

			return lv_should_flush;
		endfunction

		Reg#(Bit#(addr_in_mshr)) rg_mshr_line_addr [mshrsize_val];
    `ifdef atomic
      Reg#(Tuple2#(Bit#(5), Bit#(prf_index))) rg_atomic_info <- mkConfigReg(tuple2(0,0)); //TODO reset on fence and flush
    `endif
		Reg#(Bool) rg_mshr_valid [mshrsize_val];
		//TODO Does rg_curr_fb_id really need to be Maybe#. Is this correct?
		Reg#(Maybe#(Bit#(TLog#(mshrsize)))) rg_curr_fb_id <- mkConfigReg(tagged Invalid);
		Reg#(Bool) rg_fence <- mkConfigReg(False);
		Reg#(Bool) rg_wait_state <- mkReg(False);
		Reg#(Flush_type#(rob_index)) rg_flush[2] <- mkCReg(2, defaultValue);

		FIFOF#(MSHR_FIFO#(linewidthbits, data)) ff_mshr [mshrsize_val];

		Wire#(Maybe#(Bit#(TLog#(mshrsize)))) wr_curr_req_mshr_id <- mkDWire(tagged Invalid);
		Wire#(Maybe#(Bit#(TLog#(mshrsize)))) wr_allocate_id <- mkDWire(tagged Invalid);
		Wire#(Maybe#(Bit#(TLog#(mshrsize)))) wr_deq_ff_id <- mkDWire(tagged Invalid);
		Wire#(Bit#(addr_in_mshr)) wr_addr_to_fb <- mkDWire(0);

		//Create a structure with unguarded single enq, deq and first; and another initialize method which updates
		//all the entries. Can enqueue be stalled for a cycle? Will any deadlock happen if stalled? Will
		//any false response be sent to the processor? If it cannot be stalled, how to combine the data of
		//enq and initialize method?
		//Updating cff_valid at one shot would work as it would reset the valid bit to 0 if should_flush
		//function returns True, and otherwise leave the entry unchanged. Also, whenever any corresponding
		//ff_mshr is enqueued a 1 is enqueued inside, and when ff_mshr is dequeued, cff_valid is also dequeued.
		Ifc_SESFMI_FIFO#(mshrfifo_depth, Bit#(1)) cff_valid [mshrsize_val];
		Ifc_SEMF_FIFO#(mshrfifo_depth, Bit#(rob_index)) cff_rob [mshrsize_val];
		for(Integer i=0; i< mshrsize_val; i=i+1) begin
			//(*preempts= "flush, (cff_valid[i].incCtr, cff_valid[i].decCtr, cff_valid[i].both) "*)
			cff_valid[i] <- mkSESFMI_inst;
			cff_rob[i] <- mkSEMF_FIFO(0);
		end

		Bool one_mshr_fifo_full= False;
		Bool mshr_full= True;
		Bool mshr_not_empty= False;
		for(Integer i=0; i<mshrsize_val; i=i+1) begin
			rg_mshr_line_addr[i] <- mkConfigReg(0);
			rg_mshr_valid[i] <- mkConfigReg(False);
			ff_mshr[i] <- mkGSizedFIFOF(True, True, mshrfifo_depth_val);	//TODO check if both enq and deq should be unguarded
			one_mshr_fifo_full= one_mshr_fifo_full || !ff_mshr[i].notFull;
			mshr_full= mshr_full && rg_mshr_valid[i];
			mshr_not_empty= mshr_not_empty || rg_mshr_valid[i];
		end

		rule rl_update_mshr_valid;
			if(wr_allocate_id matches tagged Valid .allocate_id) begin
				rg_mshr_valid[allocate_id]<= True;
			end

			if(rg_curr_fb_id matches tagged Valid .curr_fb_id &&&  !ff_mshr[curr_fb_id].notEmpty) begin
				if(wr_allocate_id matches tagged Valid .allocate_id &&& allocate_id== curr_fb_id) begin
					`logLevel( dcache, 2, $format("MSHR: ff_mshr[%d] is empty, but new allocation to the same MSHR in this cycle ", curr_fb_id))
				end
				else begin	//An MSHR should be invalidated only after the FB has been released
					`logLevel( dcache, 2, $format("MSHR: rg_mshr_valid[%d] is assigned False", curr_fb_id))
					rg_mshr_valid[curr_fb_id]<= False;
				end
			end
		endrule

		rule rl_deq_ff(wr_deq_ff_id matches tagged Valid .deq_ff_id);
			let id= deq_ff_id;
			let lv_req_prf= ff_mshr[id].first.payload;
			`logLevel( dcache, 2, $format("MSHR[%d]: Flushed request for prf_index: %d being dequeued from FIFOs", id, lv_req_prf))
			ff_mshr[id].deq;
			cff_rob[id].deq;
			cff_valid[id].deq;
		endrule

		rule rl_done_fencing(!rg_wait_state && rg_fence && !mshr_not_empty);
			rg_wait_state<= True;
		endrule

		rule rl_reset_fence(rg_wait_state && !mshr_not_empty && rg_fence);
			rg_fence<= False;
			rg_wait_state<= False;
		endrule

		method ActionValue#(Maybe#(Bit#(TLog#(mshrsize)))) allocate (Cache_req#(paddr, data, rob_index, prf_index) req)
												if(!one_mshr_fifo_full && !mshr_full);
			Bool mshr_allocated= False;
			Bit#(TLog#(mshrsize)) mshr_allocated_id= 0;
			Bit#(TLog#(mshrsize)) mshr_unallocated_id= 0;
			Bit#(addr_in_mshr) req_line_addr= req.addr[paddr_val-1:linewidthbits_val];
			`logLevel( dcache, 2, $format("MSHR : New req for line_addr: %h req_addr: %h", req_line_addr, req.addr))
			for(Integer i=0; i<mshrsize_val; i=i+1) begin
				`logLevel( dcache, 2, $format("MSHR[%d]: Valid: %b line_addr: %h", i, rg_mshr_valid[i], rg_mshr_line_addr[i]))
				if(rg_mshr_valid[i] && (req_line_addr == rg_mshr_line_addr[i])) begin
					mshr_allocated= True;
					mshr_allocated_id= fromInteger(i);
				end
				else if(!rg_mshr_valid[i]) begin	//If an MSHR entry is not allocated
					mshr_unallocated_id= fromInteger(i);
				end
			end
			if(mshr_allocated)
				wr_curr_req_mshr_id<= tagged Valid mshr_allocated_id;

			if(!mshr_allocated) begin
				rg_mshr_line_addr[mshr_unallocated_id]<= req_line_addr;
        `ifdef atomic
          rg_atomic_info<= tuple2(req.atomic_fn, req.prf_index);
        `endif
				wr_allocate_id<= tagged Valid mshr_unallocated_id;
				ff_mshr[mshr_unallocated_id].enq(MSHR_FIFO{ addr: req.addr[linewidthbits_val-1:0],
																										access_size: req.access_size,
																										payload: req.payload,
																										origin: req.origin
                                                    `ifdef atomic 
                                                      , is_atomic: req.is_atomic
                                                    `endif });
				cff_rob[mshr_unallocated_id].enq(req.rob);
				cff_valid[mshr_unallocated_id].enq(1'b1);
				`logLevel( dcache, 2, $format("MSHR : Allocated MSHR id: %d for addr: %h", mshr_unallocated_id, req.addr))
				return tagged Valid mshr_unallocated_id;
			end
			else if(mshr_allocated) begin
				ff_mshr[mshr_allocated_id].enq(MSHR_FIFO{ addr: req.addr[linewidthbits_val-1:0],
																									access_size: req.access_size,
																									payload: req.payload,
																									origin: req.origin
                                                  `ifdef atomic 
                                                    , is_atomic: req.is_atomic
                                                  `endif });
				cff_rob[mshr_allocated_id].enq(req.rob);
				cff_valid[mshr_allocated_id].enq(1'b1);
				return tagged Invalid;
			end
			else begin
				return tagged Invalid;
			end
		endmethod

		//TODO make the FIFO guarded and put explicit conditions wherever requried
		//Check if the condition for the method to fire should be mshr_not_empty or that 
		//For whatever MSHR the response has come, that FIFO is not empty.
		method ActionValue#(Tuple2#(Bool, MSHR_Req#(paddr, data, prf_index, rob_index))) req_to_fb(Maybe#(Bit#(TLog#(mshrsize))) v_req_rid);
			Tuple2#(Bool, MSHR_Req#(paddr, data, prf_index, rob_index)) req= tuple2(False, ?);
			`logLevel( dcache, 2, $format("MSHR : rg_curr_fb_id: ", fshow(rg_curr_fb_id)))
			`logLevel( dcache, 2, $format("MSHR : v_req_rid: ", fshow(v_req_rid)))
			if(rg_curr_fb_id matches tagged Invalid &&& v_req_rid matches tagged Valid .req_rid) begin
				if(rg_mshr_valid[req_rid]) begin
					rg_curr_fb_id<= tagged Valid req_rid;
					let fifo_top= ff_mshr[req_rid].first;
					let cfifo_valid= cff_valid[req_rid].first;

					//If a store_commit is pending, perform it irrespective of whether the cfifo_valid bit is 
					//set, or if it is a fence instruction as this store got committed before the flush or fence 
					//operation. Also, the req is valid if cfifo_valid is set and no fence operation is being done.
					if(fifo_top.origin==Store_commit || (cfifo_valid==1'b1 && !rg_fence)) begin
            Bit#(prf_index) prf_id= `ifdef atomic fifo_top.is_atomic? tpl_2(rg_atomic_info): `endif truncate(fifo_top.payload);
						req= tuple2(True, MSHR_Req {	addr: {rg_mshr_line_addr[req_rid], fifo_top.addr},
																					access_size: fifo_top.access_size,
																					payload: fifo_top.payload,
																					origin: fifo_top.origin,
                                          prf_index: prf_id,
                                          rob: cff_rob[req_rid].first
                                          `ifdef atomic
                                          , is_atomic: fifo_top.is_atomic
                                          , atomic_fn: tpl_1(rg_atomic_info) 
                                          `endif });
						`logLevel( dcache, 2, $format("MSHR : Miss req to FB when rg_curr_fb_id is Invalid: ", fshow(req)))
					end
					else begin
						wr_deq_ff_id<= tagged Valid req_rid;
					end
				end
				//Else no pending req of current MSHR are pending, hence wait for the fill buffer to get filled
				else begin
					`logLevel( dcache, 2, $format("MSHR : Waiting for fill buffer to get filled for id: ", fshow(v_req_rid)))
				end
			end
			else if(rg_curr_fb_id matches tagged Valid .curr_rid) begin		//The current MSHR's (that is being serviced) id
				if(ff_mshr[curr_rid].notEmpty) begin
					let fifo_top= ff_mshr[curr_rid].first;
					let cfifo_valid= cff_valid[curr_rid].first;

					if(cfifo_valid==1'b1 && (!rg_fence || fifo_top.origin==Store_commit)) begin
            Bit#(prf_index) prf_id= `ifdef atomic fifo_top.is_atomic? tpl_2(rg_atomic_info): `endif truncate(fifo_top.payload);
						req= tuple2(True, MSHR_Req {	addr: {rg_mshr_line_addr[curr_rid], fifo_top.addr},
																					access_size: fifo_top.access_size,
																					payload: fifo_top.payload,
																					origin: fifo_top.origin,
                                          prf_index: prf_id,
                                          rob: cff_rob[curr_rid].first
                                          `ifdef atomic
                                          , is_atomic: fifo_top.is_atomic
                                          , atomic_fn: tpl_1(rg_atomic_info)
                                          `endif });
						`logLevel( dcache, 2, $format("MSHR : Miss req from MSHR[%d] to FB: ", curr_rid, fshow(req)))
					end
					else begin
						wr_deq_ff_id<= tagged Valid curr_rid;
					end
				end
				//curr_id is being serviced right now, but ff_mshr[curr_rid] is empty, then check if wr_curr_req_mshr_id
				//is to curr_id or not. If so, then rg_curr_fb_id should remain unchanged, else, Invalidate it
				//so that in the next cycle it will be assigned the value
				else if(wr_curr_req_mshr_id matches tagged Valid .curr_req_rid &&& curr_req_rid==curr_rid) begin //implicit && !ff_mshr[curr_rid].notEmpty
					`logLevel( dcache, 2, $format("MSHR : New req from ff_second_stage to existing MSHR of id: %d", curr_rid))
				end
				else begin
					rg_curr_fb_id<= tagged Invalid;
					`logLevel( dcache, 2, $format("MSHR : No more pending requests of id: %d", curr_rid))
				end

			end
			wr_addr_to_fb<= truncateLSB(tpl_2(req).addr);
			return req;
		endmethod

		method Bit#(linewidthbits) mem_req_offset(Bit#(TLog#(mshrsize)) id);
			return ff_mshr[id].first.addr;
		endmethod

    method Bit#(addr_in_mshr) addr_to_fb;
      return wr_addr_to_fb;
    endmethod

		method Action ack_from_fb if(mshr_not_empty && !isValid(wr_deq_ff_id));
			if(rg_curr_fb_id matches tagged Valid .fb_id &&& ff_mshr[fb_id].notEmpty) begin
      	`logLevel( nb_dcache, 1, $format("MSHR : ack from fb for id: %d", fb_id))
				ff_mshr[fb_id].deq;
				cff_rob[fb_id].deq;
				cff_valid[fb_id].deq;
			end
			else begin
      `ifdef ASSERT
        dynamicAssert(True,"MSHR : Ack from fb called when ff_mshr empty");
      `endif
			end
		endmethod
		
		method Action flush (Flush_type#(rob_index) bundle);
			rg_flush[0]<= bundle;
      `logLevel( nb_dcache, 1, $format("MSHR : Flush initiated: ", fshow(bundle)))
			for(Integer i=0; i<mshrsize_val; i=i+1) begin
				Vector#(mshrfifo_depth,Bit#(1)) valid= cff_valid[i].contents;
				Vector#(mshrfifo_depth,Bit#(rob_index)) cff_rob_id= cff_rob[i].contents;

				for(Integer j=0; j<mshrfifo_depth_val; j=j+1) begin
      		`logLevel( nb_dcache, 1, $format("MSHR : Flush: Initial V[%d][%d]= %b", i,j, valid[j]))
      		`logLevel( nb_dcache, 1, $format("MSHR : Flush: Initial ROB[%d][%d]= %d", i,j, cff_rob_id[j]))
					if(should_flush(bundle.head, bundle.flush_rob, cff_rob_id[j])) begin
						valid[j]=0;
      			`logLevel( nb_dcache, 1, $format("MSHR : Flush: Invalidating (%d,%d)", i, j))
					end
				end
      	`logLevel( nb_dcache, 1, $format("MSHR : Flush: Setting V[%d]= %b\n", i, valid))
				cff_valid[i].initialize(valid);
			end
		endmethod

		method Action fence if(!rg_fence);
			rg_fence<= True;
		endmethod

		method Bool not_empty;
			return mshr_not_empty;
		endmethod
	endmodule

  (*synthesize*)
	module mkmshr_instance (Ifc_mshr#(32, 9, 64, 4, 3, 7, 6));
    let ifc();
    mkmshr _temp(ifc);
    return (ifc);
  endmodule
endpackage
