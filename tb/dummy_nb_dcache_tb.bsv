package nb_dcache_tb;
	import nb_dcache_types::*;
	import nb_dcache::*;
	import GetPut::*;
	import DefaultValue::*;
	`include "parameters.txt"
  `include "Logger.bsv"           // for logging

	(*synthesize*)
	module mknb_dcache_tb(Empty);
		let cache <- mkdcache;
		Reg#(Bit#(7)) rg_state <- mkReg('d0);
		Reg#(Bit#(`Buswidth)) rg_data <- mkReg('d1);
		Reg#(Bit#(2)) rg_read_cntr <- mkReg('d0);
		Reg#(Maybe#(Read_req_to_mem#(`Paddr, `Id_bits))) rg_read_req_from_cache <- mkReg(tagged Invalid);

  	String dcache=""; // defined for Logger
		rule rl_finish_sim (rg_state=='1);
			$finish(0);
		endrule

		rule rl_send_request(rg_state==0);
			Req_from_core#(`Vaddr, TMul#(`Wordsize, 8)) req= Req_from_core{ addr: 'hA00,
																																			access_size: 'd3,
																																			payload: 'hbbbbbbbb,
																																			origin: Load_buffer };
			rg_state<=1;
			cache.subifc_req_from_core.put(req);
      `logLevel( dcache, 1, $format("DCACHE_TB : Sending req to processor: ", fshow(req)))
		endrule

		rule rl_get_cache_response(rg_state==1);
			let resp<- cache.subifc_resp_to_core.get;
      `logLevel( dcache, 1, $format("DCACHE_TB : Cache response to processor: ", fshow(resp)))
			rg_state<='1;
		endrule

		rule rl_take_req_to_mem(rg_read_req_from_cache matches tagged Invalid);
			let req<- cache.subifc_read_req_to_mem.get;
			rg_read_req_from_cache<= tagged Valid req; 
		endrule

		rule rl_send_read_resp_to_cache(rg_read_req_from_cache matches tagged Valid .req);
			cache.subifc_read_resp_from_mem.put(Read_resp_from_mem {	data: rg_data,
																																id: req.id,
																																last: (rg_read_cntr=='d3) });
			rg_read_cntr<= rg_read_cntr+1;
			rg_data<= rg_data+1;
			if(rg_read_cntr=='d3)
				rg_read_req_from_cache<= tagged Invalid;
		endrule

	endmodule
endpackage
