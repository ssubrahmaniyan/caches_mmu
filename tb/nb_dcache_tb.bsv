package nb_dcache_tb;
	import nb_dcache_types::*;
	import nb_dcache::*;
	import GetPut::*;
	`include "parameters.txt"
  `include "Logger.bsv"           // for logging

	(*synthesize*)
	module mknb_dcache_tb(Empty);
		let cache <- mkdcache;
		Reg#(Bit#(4)) rg_state <- mkReg(0);

  	String dcache=""; // defined for Logger
		rule rl_send_request(rg_state==0);
			Req_from_core#(`Vaddr, TMul#(`Wordsize, 8)) req= Req_from_core{ addr: 'h900,
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
			$finish(0);
		endrule

		//rule rl_take_req_to_mem;
		//	let req<- cache.subifc_read_req_to_mem;
		//endrule
	endmodule
endpackage
