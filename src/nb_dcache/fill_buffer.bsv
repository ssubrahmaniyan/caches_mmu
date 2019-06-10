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
TODO 
1. Optimize the input struct. "Origin" is not required. A single bit indicating ld/st is enough.
2. UniqueWrapper for function
3. Instead of combining fill buffer and memory resp first, and then combining mshr_req, first combine
   MSHR req and memory.
*/
package fill_buffer;

	interface Ifc_fill_buffer#( numeric type paddr, numeric type data, numeric type buswidth);
		method ActionValue#(Maybe#(Bit#(data))) request(Req_from_core#(paddr, data) req);
		method Action data_from_mem(Bit#(buswidth) mem_resp);
		method Action release_fb(all_valid);
		method Bool can_release;
	endinterface

	(*preempts="rl_operation, rl_serve_remaining_mshr_requests"*)
	(*preempts=""*)
	module mkfill_buffer#(linewidth) Ifc_fill_buffer#(paddr, data, buswidth)
				 provisos(Log#(buswidth, buswidthbits),
				 					Log#(linewidth, linewidthbits),
			 						Div#(linewidth, buswidth, num_chunks),
									Log#(num_chunks, num_chunkbits));

		let num_chunks_val= valueOf(num_chunks);
		let buswidthbits_val= valueOf(buswidthbits);
		let num_chunkbits_val= valueOf(num_chunkbits);

		function Bit#(linewidth) generate_masked_data_bus(Bit#(linewidth) sram_data, Bit#(buswidthbits) core_data, Bit#(TLog#(num_chunks)) chunk_addr);
			Bit#(buswidthbits) temp= '1;
    	Bit#(linewidth) mask = zeroExtend(temp);
			Bit#(TLog#(buswidthbits)) zeros= 'd0;
    	mask = mask<<{chunk_addr,zeros};
			let writedata= (mask & duplicate(core_data)) |(~mask & sram_data);
			return writedata;
		endfunction

		//TODO Make a UniqueWrapper for this
		function Bit#(linewidth) generate_masked_data(Bit#(linewidth) sram_data, Bit#(data) core_data, Bit#(buswidthbits) line_addr, Bit#(2) size);
    	Bit#(data) temp = size[1 : 0] == 0?'hFF : 
    	                       size[1 : 0] == 1?'hFFFF : 
    	                       size[1 : 0] == 2?'hFFFFFFFF : '1;

    	Bit#(linewidth) mask = zeroExtend(temp);
			Bit#(wordsize) zeros= 'd0;
    	mask = mask<<{line_addr,zeros};
			let writedata= (mask & duplicate(core_data)) |(~mask & sram_data);
			return writedata;
		endfunction

		Reg#(Bit#(linewidth)) rg_fill_buffer <- mkReg(0);
		Reg#(Bit#(num_chunks)) rg_valid <- mkReg(0);
		Reg#(Bool) rg_can_release <- mkReg(False);
		Reg#(Bool) rg_first_resp <- mkReg(False);

		Wire#(Req_from_core#(paddr, data)) wr_req <- mkDWire(defaultValue);
		Wire#(Bit#(data)) wr_data_from_mem <- mkWire;

		let all_valid= (rg_valid=='1);

		rule rl_operation;
			if(rg_first_resp) begin
				rg_first_resp<= False;
			end
			else if(wr_data_from_mem.rlast) begin
				rg_first_resp<= True;
			end
		endrule

		rule rl_operation(!all_valid);
			let req= wr_req;
			Bit#(TLog#(num_chunks)) lv_index;
			//For the first response from memory, since the critical data arrives first, the index to be written
			//in the FB is computed. In the first cycle, the MSHR will definitely send a request with the
			//corresponding address to the memory response's rid. In the subsequent cycles, the index is
			//just incremented and is independent of the MSHR req. Therefore, even if MSHR doesn't send a req,
			//it does not matter.
			if(rg_first_resp) begin
				Bit#(TLog#(num_chunks)) valid_index= req.addr[num_chunks_val + buswidthbits_val -1 : buswidthbits_val];
				rg_index<= valid_index+1;
				lv_index= valid_index;
			end
			else begin
				rg_index<= rg_index + 1;
				lv_index= rg_index;
			end

			//Mix the fill buffer and the data from memory response
			Bit#(linewidthbits) write_linedata= generate_masked_data_bus(rg_fill_buffer, wr_data_from_mem, lv_index);

			//For a store commit combine the above data along with that of the request
			if(req.origin==Store_commit) begin
				Bit#(buswidthbits) write_reqaddr= req.addr[buswidthbits_val-1:0];
				write_linedata= generate_masked_data(write_linedata, req.rdata, write_reqaddr);
				rg_fill_buffer<= write_linedata;
			end
			//When MSHR doesn't have any pending request, the defaultValue of req will have origin=Store_buffer
			//In which case this else statement gets executed.
			else begin
				rg_fill_buffer<= write_linedata;
			end
			rg_valid[lv_index]<= 1'b1;
		endrule

		rule rl_serve_remaining_mshr_requests;
			let req= wr_req;
			Bit#(buswidthbits) write_reqaddr= req.addr[buswidthbits_val-1:0];
			Bit#(linewidthbits) write_linedata= generate_masked_data(rg_fill_buffer, req.rdata, write_reqaddr);
			rg_fill_buffer<= write_linedata;
		endrule
	
		//Assigning req to wr_req, for a write req will perform the write even when corresponding fb
		//entry is invalid. This does not matter however as this method returns "tagged Invalid" as the 
		//result, and in the subsequent clock cycles, the same request will again be sent by the MSHR.
		//For a request from ff_first_stage, they will get enqueued to ff_second_stage.
		method ActionValue#(Maybe#(Bit#(data))) request(Req_from_core#(paddr, data) req);
			Bit#(TLog#(num_chunks)) valid_index= req.addr[linewidthbits_val -1 : buswidthbits_val];
			wr_req<= req;
			if(rg_valid[valid_index] && req.addr[paddr_val-1:linewidthbits_val]==rg_fb_addr) begin
				return tagged Valid rg_fill_buffer;
			end
			else begin
				return tagged Invalid;
			end
		endmethod

		method Action data_from_mem(Bit#(data) mem_resp) if(!all_valid);
			wr_data_from_mem<= mem_resp;	
		endmethod

		method Action release_fb(all_valid);
			for(Integer i=0; i<
			rg_valid<= 'd0;
		endmethod

		method Bool can_release;
			return all_valid;
		endmethod

	endmodule

endpackage
