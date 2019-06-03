package mshr;

	interface Ifc_mshr#(paddr, linewidthbits, data, id_bits, prfindex, mshrsize);
		method Action allocate (Req_from_core#(addr, data, prfindex) req);
	endinterface

	module mkmshr(Ifc_mshr#(paddr, linewidthbits, data, id_bits, prfindex, mshrsize)
				 provisos (	Add#(paddr, lineaddrbits, linewidthbis),
				 						Log#(mshrsize, mshrbits)
			 						 );

		Reg#(Bit#(lineaddrbits)) rg_line_addr [mshrsize];
		Reg#(Bit#(id_bits)) rg_fb_

		for(Integer i=0; i<mshrsize; i=i+1)
			rg_line_addr[i] <- mkReg(0);

		
		method Action allocate (Req_from_core#(addr, data, prfindex) req);
		endmethod
		
	endmodule

endpackage
