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
5. Remove rg_first_resp and use all_invalid signal instead
*/
package fill_buffer;

  //`include "Logger.bsv"           // for logging
  import nb_dcache_types::*; 	         
  import BUtils::*;
	import DefaultValue :: *;
	import ConfigReg::*;
  `include "Logger.bsv"           // for logging

	interface Ifc_fill_buffer#( numeric type paddr, numeric type data, numeric type buswidth,
															numeric type linewidth, numeric type lineoffset, numeric type wordsize, numeric type prf_index);
		method ActionValue#(Maybe#(Bit#(linewidth))) request(MSHR_Req#(paddr, data, prf_index) req);
		method Action data_from_mem(Bit#(buswidth) mem_resp, Bool last, Bit#(lineoffset) offset_val);
		method Action release_fb;
		method Bool can_release;
		method Tuple2#(Bit#(1), Bit#(linewidth)) data;
		(*always_ready, always_enabled*) method Bit#(TSub#(paddr, lineoffset)) line_addr;
	endinterface

	//(* preempts= "rl_operation, rl_serve_remaining_mshr_requests" *)
	module mkfill_buffer (Ifc_fill_buffer#(paddr, data, buswidth, linewidth, lineoffset, wordsize, prf_index))
				 provisos(Log#(TDiv#(buswidth,8), busoffset),
				 					Log#(buswidth, buswidthbits),
			 						Div#(linewidth, buswidth, num_chunks),
									Log#(num_chunks, num_chunksbits),
									Mul#(a__, data, linewidth),
									Add#(b__, data, linewidth),
									Add#(c__, buswidth, linewidth),			  //for generate_masked_data_bus fn
									Mul#(d__, buswidth, linewidth),			  //for generate_masked_data_bus fn
									Mul#(e__, 8, linewidth),						  //for generate_masked_data fn
									Mul#(f__, 16, linewidth),						  //for generate_masked_data fn
									Mul#(g__, 32, linewidth),						  //for generate_masked_data fn
                  `ifdef atomic
                  Add#(h__, 32, data),
                  Add#(i__, lineoffset, paddr),
                  `endif
									Add#(num_chunksbits, j__, lineoffset)//to find fb_index for first mem_response
								);

		let paddr_val= valueOf(paddr);
		let busoffset_val= valueOf(busoffset);
		let buswidthbits_val= valueOf(buswidthbits);
		let lineoffset_val= valueOf(lineoffset);
		let num_chunksbits_val= valueOf(num_chunksbits);

		function Bit#(linewidth) generate_masked_data_bus(Bit#(linewidth) sram_data, Bit#(buswidth) bus_data, Bit#(TLog#(num_chunks)) chunk_addr);
			Bit#(buswidth) temp= '1;
    	Bit#(linewidth) mask = zeroExtend(temp);
			Bit#(TLog#(buswidth)) zeros= 'd0;
    	mask = mask<<{chunk_addr,zeros};
			let writedata= (mask & duplicate(bus_data)) |(~mask & sram_data);
			return writedata;
		endfunction

		//TODO Make a UniqueWrapper for this
		function Bit#(linewidth) generate_masked_data(Bit#(linewidth) sram_data, Bit#(data) core_data, Bit#(buswidthbits) line_addr, Bit#(2) size);
    	Bit#(data) temp = size[1 : 0] == 0?'hFF : 
    	                       size[1 : 0] == 1?'hFFFF : 
    	                       size[1 : 0] == 2?'hFFFFFFFF : '1;

    	Bit#(linewidth) mask = zeroExtend(temp);
    	mask = mask<<{line_addr, 3'd0};
			Bit#(linewidth) data_to_mask= size=='d0? duplicate(core_data[7:0])  :
																		size=='d1? duplicate(core_data[15:0]) :
																		size=='d2? duplicate(core_data[31:0]) :
																							 duplicate(core_data);
			let writedata= (mask & data_to_mask) |(~mask & sram_data);
			return writedata;
		endfunction

		function Bit#(datawidth) fn_extract_data(Bit#(linewidth) line, Bit#(lineoffset) line_offset, Bit#(2) size)
      provisos(Add#(z__, datawidth, linewidth));
    	Bit#(datawidth) mask = size[1 : 0] == 0?'hFF : 
    	                       size[1 : 0] == 1?'hFFFF : 
    	                       size[1 : 0] == 2?'hFFFFFFFF : '1;

    	line = line>>{line_offset,3'd0};
			Bit#(datawidth) readdata= truncate(line) & mask;
			return readdata;
		endfunction

    `ifdef atomic
    function Bit#(datawidth) fn_atomic_op (Bit#(5) op, Bit#(datawidth) rs2, Bit#(datawidth) loaded)
      provisos(Add#(z__, 32, datawidth));
      Bit#(datawidth) op1 = loaded;
      Bit#(datawidth) op2 = rs2;
      if(op[4] == 0)begin
	  		op1 = signExtend(loaded[31 : 0]);
        op2 = signExtend(rs2[31 : 0]);
      end
      Int#(datawidth) s_op1 = unpack(op1);
	  	Int#(datawidth) s_op2 = unpack(op2);
      
      case (op[3 : 0])
	  			'b0011 : return op2;
	  			'b0000 : return (op1 + op2);
	  			'b0010 : return (op1^op2);
	  			'b0110 : return (op1 & op2);
	  			'b0100 : return (op1|op2);
	  			'b1100 : return min(op1, op2);
	  			'b1110 : return max(op1, op2);
	  			'b1000 : return pack(min(s_op1, s_op2));
	  			'b1010 : return pack(max(s_op1, s_op2));
	  			default : return op1;
	  		endcase
    endfunction
    `endif

		Reg#(Bit#(linewidth)) rg_fill_buffer <- mkConfigReg(0);
		Reg#(Bit#(num_chunks)) rg_valid <- mkConfigReg(0);
		Reg#(Bool) rg_can_release <- mkReg(False);
		Reg#(Bool) rg_first_resp <- mkReg(True);
		Reg#(Bit#(TLog#(num_chunks))) rg_index <- mkReg('1);
		Reg#(Bit#(TSub#(paddr, lineoffset))) rg_fb_addr <- mkConfigReg(0);
		Reg#(Bit#(1)) rg_dirty <- mkReg(0);

		Wire#(MSHR_Req#(paddr, data, prf_index)) wr_req <- mkDWire(defaultValue);
		Wire#(Tuple3#(Bit#(buswidth), Bool, Bit#(num_chunksbits))) wr_data_from_mem <- mkWire;
		Wire#(Bool) wr_can_perform_store <- mkDWire(False);

		let all_valid= (rg_valid=='1);
		let all_invalid= (rg_valid=='0);

		//When the first reponse from memory comes for a request, rg_first_resp will be True. In this
		//case, set the value of rg_first_resp to be False and also set rg_fb_addr as the line address
		//of the current request. Since, when the memory responds the first data for a request, the MSHR
		//also sends a first request. Therefore, there will never be a case when wr_data_from_mem holds
		//a value in the first response, and wr_req does not hold anything.
		//Also, if rg_first_resp is set as False, if the memory responds with the last data, rg_first_resp
		//should be set as True.
		rule rl_set_rg_first_resp(rg_first_resp && !all_valid);
			rg_fb_addr<= wr_req.addr[paddr_val-1:lineoffset_val];
			rg_first_resp<= False;
    endrule

    rule rl_reset_rg_first_resp(!rg_first_resp && tpl_2(wr_data_from_mem));
			rg_first_resp<= True;
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
				Bit#(TLog#(num_chunks)) valid_index= tpl_3(wr_data_from_mem); //req.addr[num_chunksbits_val + busoffset_val -1 : busoffset_val];
				rg_index<= valid_index+1;
				lv_index= valid_index;
				`logLevel( dcache, 2, $format("FB : First response from Mem. Valid index in FB: %d for req: ", valid_index, fshow(req)))
			end
			else begin
				rg_index<= rg_index + 1;
				lv_index= rg_index;
			end

			//Bit#(buswidth) temp= '1;
    	//Bit#(linewidth) mask = zeroExtend(temp);
			//Bit#(TLog#(buswidth)) zeros= 'd0;
    	//mask = mask<<{lv_index,zeros};
			//`logLevel( dcache, 2, $format("FB : Mask:%h data_from_mem: %h fb_data: %h ", mask, tpl_1(wr_data_from_mem), rg_fill_buffer))
			//Bit#(linewidth) write_linedata= (mask & duplicate(tpl_1(wr_data_from_mem))) | (~mask & rg_fill_buffer);
			//Mix the fill buffer and the data from memory response
			Bit#(linewidth) write_linedata= generate_masked_data_bus(rg_fill_buffer, tpl_1(wr_data_from_mem), lv_index);

			Bit#(TLog#(num_chunks)) lv_store_index= req.addr[num_chunksbits_val + busoffset_val -1 : busoffset_val];
			//For a store commit combine the above data along with that of the request
			if(req.origin==Store_commit && rg_valid[lv_store_index]==1'b1 && wr_can_perform_store
        `ifdef atomic && !req.is_atomic `endif ) begin
				rg_dirty<= 1;
				Bit#(buswidthbits) write_reqaddr= req.addr[buswidthbits_val-1:0];
				let sram_data= write_linedata;
				let core_data= req.payload;
				let size= req.access_size;
    		Bit#(data) temp = size[1 : 0] == 0?'hFF : 
    		                  size[1 : 0] == 1?'hFFFF : 
    		                  size[1 : 0] == 2?'hFFFFFFFF : '1;

    		Bit#(linewidth) mask = zeroExtend(temp);
    		mask = mask<<{write_reqaddr, 3'd0};
				Bit#(linewidth) data_to_mask= size=='d0? duplicate(core_data[7:0])  :
																			size=='d1? duplicate(core_data[15:0]) :
																			size=='d2? duplicate(core_data[31:0]) :
																								 duplicate(core_data);
				write_linedata= (mask & data_to_mask) |(~mask & sram_data);
			`logLevel( dcache, 2, $format("FB : addr: 'h%h write_linedata: %h mask: %h",write_reqaddr, write_linedata, mask))
				//write_linedata= generate_masked_data(write_linedata, req.payload, write_reqaddr, req.access_size);
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
        let store_data= req.payload;
        `ifdef atomic
        if(req.is_atomic) begin
				  let data_extracted= fn_extract_data(rg_fill_buffer, truncate(req.addr), req.access_size);
          store_data= fn_atomic_op(req.atomic_fn, req.payload, data_extracted);
          //$display("cache_data: %h", data_extracted);
			    `logLevel( dcache, 1, $format("FB : Performing atomic op: %b cache_data: rs2: %h result: %h", req.atomic_fn, req.payload, store_data))
        end
        `endif

				Bit#(buswidthbits) write_reqaddr= req.addr[buswidthbits_val-1:0];
				Bit#(linewidth) write_linedata= generate_masked_data(rg_fill_buffer, store_data, write_reqaddr, req.access_size);
				rg_fill_buffer<= write_linedata;
			end
		endrule
	
		//Assigning req to wr_req, for a write req will perform the write even when corresponding fb
		//entry is invalid. This does not matter however as this method returns "tagged Invalid" as the 
		//result, and in the subsequent clock cycles, the same request will again be sent by the MSHR.
		//For a request from ff_first_stage, they will get enqueued to ff_second_stage.
		method ActionValue#(Maybe#(Bit#(linewidth))) request(MSHR_Req#(paddr, data, prf_index) req);
			Bit#(TLog#(num_chunks)) valid_index= req.addr[lineoffset_val -1 : busoffset_val];
			Bit#(TSub#(paddr, lineoffset)) lv_req_addr= req.addr[paddr_val-1:lineoffset_val];
			`logLevel( dcache, 2, $format("FB : MSHR_req_addr: %h MSHR_req_line_addr: %h rg_fb_addr: %h fb_index: %d index_valid: %b", req.addr, lv_req_addr, rg_fb_addr, valid_index, rg_valid[valid_index] ))
			wr_req<= req;
			if(rg_valid[valid_index]==1 && req.addr[paddr_val-1:lineoffset_val]==rg_fb_addr) begin
				wr_can_perform_store<= True;
				return tagged Valid rg_fill_buffer;
			end
			else begin
				return tagged Invalid;
			end
		endmethod

		method Action data_from_mem(Bit#(buswidth) mem_resp, Bool last, Bit#(lineoffset) offset_val) if(!all_valid);
			wr_data_from_mem<= tuple3(mem_resp, last, truncateLSB(offset_val));
		endmethod

		method Action release_fb if(all_valid);
			rg_valid<= 'd0;
			rg_dirty<= 0;
			rg_fb_addr<= 0;
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
	module mkfill_buffer_instance(Ifc_fill_buffer#(32, 64, 128, 512, 6, 8, 6));
    let ifc();
    mkfill_buffer _temp(ifc);
    return (ifc);
  endmodule
endpackage
