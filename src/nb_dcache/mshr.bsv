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

	interface Ifc_mshr#(numeric type paddr,
											numeric type data,
											numeric type id_bits);
		method ActionValue#(Maybe#(Read_req_to_mem)) allocate (Req_from_core#(paddr, data) req);
		method Req_from_core#(paddr, data) req_to_fb(Bit#(id_bits) rid, Bool rlast);
		method Action ack_from_fb;
	endinterface

	module mkmshr#(linewidthbits, mshrsize) (Ifc_mshr#(paddr, linewidthbits, data, id_bits, prfindex, mshrsize)
				 provisos (	Log#(mshrsize, mshrbits),
				 						Add#(paddr, linewidthbits, addr_in_mshr)
			 						 ));

		Reg#(Bit#(addr_in_mshr)) rg_mshr_line_addr [mshrsize];
		Reg#(Bool) rg_mshr_valid [mshrsize];
		Reg#(Bit#(id_bits)) rg_curr_fb_id <- mkReg(0);

		FIFO#(Req_from_core#(linewidthbits, data)) ff_mshr [mshrsize];

		Bool one_mshr_fifo_full= False;
		Bool mshr_full= True;
		Bool mshr_not_empty= False;
		for(Integer i=0; i<mshrsize; i=i+1) begin
			rg_line_addr[i] <- mkReg(0);
			rg_mshr_valid[i] <- mkReg(False);
			ff_mshr[i] <- mkUGFIFOF(defaultValue);
			one_mshr_fifo_full= one_mshr_fifo_full || !ff_mshr.not_full[i];
			mshr_full= mshr_full && rg_mshr_valid[i];
			mshr_not_empty= mshr_not_empty || rg_mshr_valid[i];
		end

		rule rl_free_one_MSHR;
			if(rg_curr_fb_id matched tagged Valid .fb_id &&& !ff_mshr[fb_id].notEmpty && wr_curr_req_mshr_id!=rg_curr_fb_id) begin
				rg_curr_fb_id<= tagged Invalid;
			end
		endrule
		
		method Action allocate (Req_from_core#(paddr, data, prfindex) req) if(!one_mshr_fifo_full && !mshr_full);
			Bool mshr_allocated= False;
			Bit#(mshrbits) mshr_allocated_id= 0;
			Bit#(addr_in_mshr) req_line_addr= req.addr[paddr-1:linewidthbits];
			for(Integer i=0; i<mshrsize; i=i+1) begin
				if(rg_mshr_valid[i] && ( req_line_addr == rg_mshr_line_addr[i])) begin
					mshr_allocated= True;
					mshr_allocated_id= i;
				end
			end
			wr_curr_req_mshr_id<= mshr_allocated_id;

			if(!mshr_allocated) begin
				rg_mshr_line_addr[mshr_allocated_id]<= req_line_addr;
				rg_mshr_valid[mshr_allocated_id]<= True;
			end
			ff_mshr[mshr_allocated_id].enq(Req_from_core {addr: req_line_addr,
																										access_size: req.access_size,
																										payload: req.payload,
																										origin: req.origin });
		endmethod

		//TODO make the FIFO unguarded and put explicit conditions wherever requried
		//Check if the condition for the method to fire should be mshr_not_empty or that 
		//For whatever MSHR the response has come, that FIFO is not empty.
		method Req_from_core#(paddr, data) req_to_fb(Bit#(id_bits) req_rid) if(mshr_not_empty);
			Req_from_core#(paddr, data) req= defaultValue;
			if(rg_curr_fb_id matches tagged Invalid &&& req_rid!='1) begin
				rg_curr_fb_id<= tagged Valid req_rid;
				if(rg_mshr_valid[req_rid]) begin
					req= (Req_from_core {	addr: {rg_mshr_line_addr[req_rid], ff_mshr[req_rid].addr},
																access_size: ff_mshr[req_rid].access_size,
																payload: ff_mshr[req_rid].payload,
																origin: ff_mshr[req_rid].origin });
				end
				//This condition should never happen as if the MSHR is not empty, and a response comes from
				//the memory, then there should be at least one request in the FIFO corresponding to MSHR[req_rid]
				else begin
					`ifdef ASSERT
						dynamicAssert(req_rid=='1,"Invalid memory response"); 
					`endif
				end
			end
			else if(rg_curr_fb_id matches tagged Valid .curr_rid) begin		//The current MSHR's (that is being serviced) id
				
				if(ff_mshr[curr_rid].notEmpty) begin
					req= (Req_from_core {	addr: {rg_mshr_line_addr[curr_rid], ff_mshr[curr_rid].addr},
																access_size: ff_mshr[curr_rid].access_size,
																payload: ff_mshr[curr_rid].payload,
																origin: ff_mshr[curr_rid].origin });
				end
				//curr_id is being serviced right now, but ff_mshr[curr_rid] is empty, then check if wr_curr_req_mshr_id
				//is to curr_id or not. If so, then rg_curr_fb_id should remain unchanged, else, Invalidate it
				//so that in the next cycle it will be assigned the value
				else if(!ff_mshr[curr_rid].notEmpty && wr_curr_req_mshr_id!=curr_id) begin
					rg_curr_fb_id<= tagged Invalid
				end

			end
			return req;
		endmethod

		method Action ack_from_fb if(mshr_not_empty);
			if(rg_curr_fb_id matches tagged Valid fb_id &&& ff_mshr[fb_id].notEmpty) begin
      	`logLevel( nb_dcache, 1, $format("DCACHE: ack from fb for id: %d", fb_id))
				ff_mshr[fb_id].deq;
			end
			else begin
      `ifdef ASSERT
        dynamicAssert(True,"Ack from fb called when ff_mshr empty");
      `endif
			end
		endmethod
		
	endmodule

endpackage
