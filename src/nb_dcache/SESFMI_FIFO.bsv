// Copyright (c) 2007--2009 Bluespec, Inc.  All rights reserved.
/* 
see LICENSE.iitm

Author: Arjun Menon
Email id: c.arjunmenon@gmail.com
Details: Unguarded Single Enqueue and Dequeue, multiple first FIFO.

--------------------------------------------------------------------------------------------------
*/
package SESFMI_FIFO;
	import Vector::*;
	import SCtr::*;
	import ConfigReg::*;
	`include "parameters.txt"

	interface Ifc_SESFMI_FIFO#(numeric type depth, type a);
		method Action enq(a item);
		method Action deq;
		method a first;
    method Bool notFull;
		method Vector#(depth, a) contents;
		method Action initialize(Vector#(depth,a) init);
		method Action clear;
	endinterface


	module mkSESFMI_FIFO#(a dflt)(Ifc_SESFMI_FIFO#(depth,a))
	provisos (Bits#(a,sa));
		let n= valueOf(depth);
		// If the queue contains n elements, they are in q[0]..q[n-1].  The head of
		// the queue (the "first" element) is in q[0], the tail in q[n-1].
	
		Reg#(a) q[n];
		for (Integer i=0; i<n; i=i+1)
			q[i] <- mkConfigReg(dflt);

		Vector#(depth, Reg#(a)) vec_of_regs= newVector();
		for(Integer i=0; i<n; i=i+1) begin
			vec_of_regs[i]= asReg(q[i]);
		end

		SCounter cntr <- mkSCounter(n);
	
		PulseWire enqueueing <- mkPulseWire;
		Wire#(a)		x_wire <- mkWire;
		PulseWire dequeueing <- mkPulseWire;
	
		//TODO replace with mkPulseWire
		Wire#(Bool) wr_clear <- mkDWire(False);
		Wire#(Bool) wr_initialize <- mkDWire(False);

		let empty = cntr.isEq(0);
		let full  = cntr.isEq(n);

		let can_fire= !wr_clear && !wr_initialize;
	
		rule incCtr (enqueueing && !dequeueing && can_fire);
			cntr.incr;
			cntr.setNext(x_wire, q);
		endrule
		rule decCtr (dequeueing && !enqueueing && can_fire);
			for (Integer i=0; i<n; i=i+1)
				q[i] <= (i==(n - 1) ? dflt : q[i + 1]);
			cntr.decr;
		endrule
		rule both (dequeueing && enqueueing && can_fire);
			for (Integer i=0; i<n; i=i+1)
				if (!cntr.isEq(i + 1)) q[i] <= (i==(n - 1) ? dflt : q[i + 1]);
			cntr.set(x_wire, q);
		endrule
	
		method Action deq if(!wr_initialize);
			if (!empty) dequeueing.send;
		endmethod
	
		method a first;
			return q[0];
		endmethod
	
		method Action enq(x) if (!wr_initialize);
			enqueueing.send;
			x_wire <= x;
		endmethod

    method Bool notFull;
      return !full;
    endmethod
	
		method Action initialize(Vector#(depth,a) init);
			for(Integer i=0; i<n; i=i+1) begin
				q[i]<= init[i];
			end
			wr_initialize<= True;
		endmethod
	
		method Vector#(depth, a) contents;
			return readVReg(vec_of_regs);
		endmethod
	
		method Action clear;
			cntr.clear;
			wr_clear<= True;
		endmethod
	endmodule

  (*synthesize*)
	(*preempts="initialize, (decCtr, incCtr, both)"*)
	module mkSESFMI_mshr_inst(Ifc_SESFMI_FIFO#(`Mshrfifo_depth, Bit#(1)));
    let ifc();
    mkSESFMI_FIFO#(0) _temp(ifc);
    return (ifc);
  endmodule

  (*synthesize*)
	(*preempts="initialize, (decCtr, incCtr, both)"*)
	module mkSESFMI_second_stage_inst(Ifc_SESFMI_FIFO#(2, Bool));
    let ifc();
    mkSESFMI_FIFO#(False) _temp(ifc);
    return (ifc);
  endmodule

endpackage
