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
*/
package fill_buffer;

	interface Ifc_fill_buffer#( numeric type paddr, numeric type data, numeric type buswidth);
		method ActionValue#(Maybe#(Bit#(data))) request(Req_from_core#(paddr, data) req);
		method Action data_from_mem(Bit#(buswidth) mem_resp);
	endinterface

	module mkfill_buffer#(linewidth) Ifc_fill_buffer#(paddr, data, buswidth)
				 provisos(Log#(buswidth, buswidthbits),
			 						Div#(linewidth, data, num_chunks);
		let num_chunks_val= valueOf(num_chunks);
		let buswidthbits_val= valueOf(buswidthbits);

		function Bit#(linewidth) generate_masked_data(Bit#(linewidth) sram_data, Bit#(data) core_data, Bit#(linewidthbits) line_addr);
    	Bit#(data) temp = size[1 : 0] == 0?'hFF : 
    	                       size[1 : 0] == 1?'hFFFF : 
    	                       size[1 : 0] == 2?'hFFFFFFFF : '1;

    	Bit#(linewidth) mask = zeroExtend(temp);
    	Bit#(data) zeros = 0;
    	mask = mask<<{line_addr,3'd0};
			let writedata= (mask & duplicate(core_data)) |(~mask & sram_data);
		endfunction

		Reg#(Bit#(linewidth)) rg_fill_buffer <- mkReg(0);
		Reg#(Bit#(num_chunks)) rg_valid <- mkReg(0);
		Reg#(Bool) rg_can_release <- mkReg(False);
		Reg#(Bool) rg_first_resp <- mkReg(False);

		rule rl_operation;
			if(rg_first_resp) begin
				rg_first_resp<= False;
			end
			else if(wr_data_from_mem.rlast) begin
				rg_first_resp<= True;
			end
		endrule

		rule rl_operation;
			let req= wr_req;
			Bit#(TLog#(num_chunks)) lv_index;
			if(rg_first_resp) begin
				Bit#(TLog#(num_chunks)) valid_index= req.addr[num_chunks_val + buswidthbits_val -1 : buswidthbits_val];
				rg_index<= valid_index+1;
				lv_index= valid_index;
			end
			else begin
				rg_index<= rg_index + 1;
				lv_index= rg_index;
			end
			Bit#(linewidthbits) write_lineaddr= {lv_index, req.addr[buswidthbits_val-1:0]};
			Bit#(linewidthbits) write_linedata= generate_masked_data(rg_fill_buffer, req.rdata, write_lineaddr);
			rg_fill_buffer<= write_linedata;
		endrule
	
		method ActionValue#(Maybe#(Bit#(data))) request(Req_from_core#(paddr, data) req);
			Bit#(TLog#(num_chunks)) valid_index= req.addr[num_chunks_val + buswidthbits_val -1 : buswidthbits_val];
			wr_req<= req;
			if(rg_valid[req[valid_index])
				return tagged Valid rg_fill_buffer;
			else
				return tagged Invalid;
		endmethod

		method Action data_from_mem(Bit#(data) mem_resp) if(!rg_can_release);
			wr_data_from_mem<= mem_resp;	
		endmethod
	endmodule

endpackage
