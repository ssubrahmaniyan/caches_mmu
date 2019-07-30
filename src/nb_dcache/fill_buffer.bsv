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
4. Add appropriate always_ready and always_enabled signals
*/
package fill_buffer;

  //`include "Logger.bsv"           // for logging
  import nb_dcache_types::*; 	         
  import BUtils::*;
	import DefaultValue :: *;
	import ConfigReg::*;
  `include "Logger.bsv"           // for logging

	interface Ifc_fill_buffer#( numeric type paddr, numeric type data, numeric type buswidth,
															numeric type linewidth, numeric type lineoffset, numeric type wordsize);
		method ActionValue#(Maybe#(Bit#(linewidth))) request(Req_from_core#(paddr, data) req);
		method Action data_from_mem(Bit#(buswidth) mem_resp, Bool last);
		method Action release_fb;
		method Bool can_release;
		method Tuple2#(Bit#(1), Bit#(linewidth)) data;
		(*always_ready, always_enabled*) method Bit#(TSub#(paddr, lineoffset)) line_addr;
	endinterface

	//(* preempts= "rl_operation, rl_serve_remaining_mshr_requests" *)
	module mkfill_buffer (Ifc_fill_buffer#(paddr, data, buswidth, linewidth, lineoffset, wordsize))
				 provisos(Log#(TDiv#(buswidth,8), busoffset),
			 						Div#(linewidth, buswidth, num_chunks),
									Log#(num_chunks, num_chunksbits),
									Mul#(a__, data, linewidth),
									Add#(b__, data, linewidth),
									Add#(c__, buswidth, linewidth),			//for generate_masked_data_bus fn
									Mul#(d__, buswidth, linewidth)			//for generate_masked_data_bus fn
								);

		let paddr_val= valueOf(paddr);
		let busoffset_val= valueOf(busoffset);
		let lineoffset_val= valueOf(lineoffset);
		let num_chunksbits_val= valueOf(num_chunksbits);

		function Bit#(linewidth) generate_masked_data_bus(Bit#(linewidth) sram_data, Bit#(buswidth) bus_data, Bit#(TLog#(num_chunks)) chunk_addr);
			Bit#(buswidth) temp= '1;
    	Bit#(linewidth) mask = zeroExtend(temp);
			Bit#(busoffset) zeros= 'd0;
    	mask = mask<<{chunk_addr,zeros};
			let writedata= (mask & duplicate(bus_data)) |(~mask & sram_data);
			return writedata;
		endfunction

		//TODO Make a UniqueWrapper for this
		function Bit#(linewidth) generate_masked_data(Bit#(linewidth) sram_data, Bit#(data) core_data, Bit#(busoffset) line_addr, Bit#(2) size);
    	Bit#(data) temp = size[1 : 0] == 0?'hFF : 
    	                       size[1 : 0] == 1?'hFFFF : 
    	                       size[1 : 0] == 2?'hFFFFFFFF : '1;

    	Bit#(linewidth) mask = zeroExtend(temp);
			Bit#(wordsize) zeros= 'd0;
    	mask = mask<<{line_addr,zeros};
			let writedata= (mask & duplicate(core_data)) |(~mask & sram_data);
			return writedata;
		endfunction

		Reg#(Bit#(linewidth)) rg_fill_buffer <- mkConfigReg(0);
		Reg#(Bit#(num_chunks)) rg_valid <- mkConfigReg(0);
		Reg#(Bool) rg_can_release <- mkReg(False);
		Reg#(Bool) rg_first_resp <- mkReg(True);
		Reg#(Bit#(TLog#(num_chunks))) rg_index <- mkReg('1);
		Reg#(Bit#(TSub#(paddr, lineoffset))) rg_fb_addr <- mkConfigReg(0);
		Reg#(Bit#(1)) rg_dirty <- mkReg(0);

		Wire#(Req_from_core#(paddr, data)) wr_req <- mkDWire(defaultValue);
		Wire#(Tuple2#(Bit#(buswidth), Bool)) wr_data_from_mem <- mkWire;

		let all_valid= (rg_valid=='1);

		//When the first reponse from memory comes for a request, rg_first_resp will be True. In this
		//case, set the value of rg_first_resp to be False and also set rg_fb_addr as the line address
		//of the current request. Since, when the memory responds the first data for a request, the MSHR
		//also sends a first request. Therefore, there will never be a case when wr_data_from_mem holds
		//a value in the first response, and wr_req does not hold anything.
		//Also, if rg_first_resp is set as False, if the memory responds with the last data, rg_first_resp
		//should be set as True.
		rule rl_update_rg_first_resp;
			//`logLevel( dcache, 2, $format("FB : rg_first_resp: %b rlast: %b wr_req: %h", rg_first_resp, tpl_2(wr_data_from_mem), wr_req))
			if(rg_first_resp) begin
				rg_fb_addr<= wr_req.addr[paddr_val-1:lineoffset_val];
				rg_first_resp<= False;
			end
			else if(tpl_2(wr_data_from_mem)) begin
				rg_first_resp<= True;
			end
		endrule

		//This rule fires when the fill buffer is not full, and the response from mem is valid (which
		//is an implicit confition as wr_data_from_mem is a mkWire, whose value is read in this rule)
		rule rl_operation(!all_valid);
			let req= wr_req;
			`logLevel( dcache, 2, $format("FB : rl_operation firing. data_from_mem: %h req_from_mshr: ", tpl_1(wr_data_from_mem), fshow(req)))
			Bit#(TLog#(num_chunks)) lv_index;
			//For the first response from memory, since the critical data arrives first, the index to be written
			//in the FB is computed. In the first cycle, the MSHR will definitely send a request with the
			//corresponding address to the memory response's rid. In the subsequent cycles, the index is
			//just incremented and is independent of the MSHR req. Therefore, even if MSHR doesn't send a req,
			//it does not matter.
			if(rg_first_resp) begin
				Bit#(TLog#(num_chunks)) valid_index= req.addr[num_chunksbits_val + busoffset_val -1 : busoffset_val];
				rg_index<= valid_index+1;
				lv_index= valid_index;
				`logLevel( dcache, 2, $format("FB : First response from Mem. Valid index in FB: %d for req: ", valid_index, fshow(req)))
			end
			else begin
				rg_index<= rg_index + 1;
				lv_index= rg_index;
			end

			//Mix the fill buffer and the data from memory response
			Bit#(linewidth) write_linedata= generate_masked_data_bus(rg_fill_buffer, tpl_1(wr_data_from_mem), lv_index);

			//For a store commit combine the above data along with that of the request
			if(req.origin==Store_commit) begin
				rg_dirty<= 1;
				Bit#(busoffset) write_reqaddr= req.addr[busoffset_val-1:0];
				write_linedata= generate_masked_data(write_linedata, req.payload, write_reqaddr, req.access_size);
				rg_fill_buffer<= write_linedata;
			end
			//When MSHR doesn't have any pending request, the defaultValue of req will have origin=Store_buffer
			//In which case this else statement gets executed.
			else begin
				rg_fill_buffer<= write_linedata;
			end
			rg_valid[lv_index]<= 1'b1;
		endrule

		rule rl_disp;
			`logLevel( dcache, 2, $format("FB : Value: %h valid: %b", rg_fill_buffer, rg_valid))
		endrule

		rule rl_serve_remaining_mshr_requests(all_valid);
			let req= wr_req;
			if(req.origin==Store_commit) begin
				Bit#(busoffset) write_reqaddr= req.addr[busoffset_val-1:0];
				Bit#(linewidth) write_linedata= generate_masked_data(rg_fill_buffer, req.payload, write_reqaddr, req.access_size);
				rg_fill_buffer<= write_linedata;
			end
		endrule
	
		//Assigning req to wr_req, for a write req will perform the write even when corresponding fb
		//entry is invalid. This does not matter however as this method returns "tagged Invalid" as the 
		//result, and in the subsequent clock cycles, the same request will again be sent by the MSHR.
		//For a request from ff_first_stage, they will get enqueued to ff_second_stage.
		method ActionValue#(Maybe#(Bit#(linewidth))) request(Req_from_core#(paddr, data) req);
			Bit#(TLog#(num_chunks)) valid_index= req.addr[lineoffset_val -1 : busoffset_val];
			wr_req<= req;
			Bit#(TSub#(paddr, lineoffset)) lv_req_addr= req.addr[paddr_val-1:lineoffset_val];
			`logLevel( dcache, 2, $format("FB : MSHR_req_addr: %h MSHR_req_line_addr: %h rg_fb_addr: %h fb_index: %d index_valid: %b", req.addr, lv_req_addr, rg_fb_addr, valid_index, rg_valid[valid_index] ))
			if(rg_valid[valid_index]==1 && req.addr[paddr_val-1:lineoffset_val]==rg_fb_addr) begin
				return tagged Valid rg_fill_buffer;
			end
			else begin
				return tagged Invalid;
			end
		endmethod

		method Action data_from_mem(Bit#(buswidth) mem_resp, Bool last) if(!all_valid);
			wr_data_from_mem<= tuple2(mem_resp, last);
		endmethod

		method Action release_fb if(all_valid);
			rg_valid<= 'd0;
			rg_dirty<= 0;
		endmethod

		method Bool can_release;
			return all_valid;
		endmethod

		method Tuple2#(Bit#(1), Bit#(linewidth)) data;
			return tuple2(rg_dirty, rg_fill_buffer);
		endmethod

		method Bit#(TSub#(paddr, lineoffset)) line_addr;
			return rg_fb_addr;
		endmethod

	endmodule

  (*synthesize*)
	module mkfill_buffer_instance(Ifc_fill_buffer#(32, 64, 128, 512, 6, 8));
    let ifc();
    mkfill_buffer _temp(ifc);
    return (ifc);
  endmodule
endpackage
