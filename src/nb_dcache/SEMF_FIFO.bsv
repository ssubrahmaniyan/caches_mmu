// Copyright (c) 2007--2009 Bluespec, Inc.  All rights reserved.
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

Details: Unguarded Single Enqueue and Dequeue, multiple first FIFO.

--------------------------------------------------------------------------------------------------
*/
package SEMF_FIFO;
	import SpecialFIFOS::mkSCtr;

	interface Ifc_SEMF_FIFO#(numeric type n, type a);
		method Action enq(a item);
		method Action deq;
		method Vector#(n, a) contents;
		method clear;
	endinterface

	module mkSEMF_FIFO#(a dflt)(Ifc_SEMF_FIFO#(n,a));
   provisos (Bits#(a,sa));

   // If the queue contains n elements, they are in q[0]..q[n-1].  The head of
   // the queue (the "first" element) is in q[0], the tail in q[n-1].

   Reg#(a) q[n];
   for (Integer i=0; i<n; i=i+1)
      q[i] <- mkReg(dflt);
   SCounter cntr <- mkSCounter(n);

   PulseWire enqueueing <- mkPulseWire;
   Wire#(a)      x_wire <- mkWire;
   PulseWire dequeueing <- mkPulseWire;

   let empty = cntr.isEq(0);
   let full  = cntr.isEq(n);

   rule incCtr (enqueueing && !dequeueing);
      cntr.incr;
      cntr.setNext(x_wire, q);
   endrule
   rule decCtr (dequeueing && !enqueueing);
      for (Integer i=0; i<n; i=i+1)
	 q[i] <= (i==(n - 1) ? dflt : q[i + 1]);
      cntr.decr;
   endrule
   rule both (dequeueing && enqueueing);
      for (Integer i=0; i<n; i=i+1)
	 if (!cntr.isEq(i + 1)) q[i] <= (i==(n - 1) ? dflt : q[i + 1]);
      cntr.set(x_wire, q);
   endrule

   method Action deq;
      if (!empty) dequeueing.send;
   endmethod

   method Action enq(x) if (!full);
      enqueueing.send;
      x_wire <= x;
   endmethod

	 method Vector#(n, a) contents;
      return unpack(pack(q));
   endmethod

   method Action clear;
      cntr.clear;
   endmethod
	endmodule
endpackage
