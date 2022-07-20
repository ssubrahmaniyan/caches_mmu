// Copyright (c) 2007--2009 Bluespec, Inc.  All rights reserved.
/* 
see LICENSE.iitm

Author: Arjun Menon
Email id: c.arjunmenon@gmail.com
Details: Unguarded Single Enqueue and Dequeue, multiple first FIFO.

--------------------------------------------------------------------------------------------------
*/
package SEMF_FIFO;
  import Vector::*;
  import SCtr::*;

  interface Ifc_SEMF_FIFO#(numeric type depth, type a);
    method Action enq(a item);
    method a first;
    method Bool notFull;
    method Action deq;
    method Vector#(depth, a) contents;
    method Action clear;
  endinterface


  module mkSEMF_FIFO#(a dflt)(Ifc_SEMF_FIFO#(depth,a))
  provisos (Bits#(a,sa));
    let n= valueOf(depth);
    // If the queue contains n elements, they are in q[0]..q[n-1].  The head of
    // the queue (the "first" element) is in q[0], the tail in q[n-1].
 
    Reg#(a) q[n];
    for (Integer i=0; i<n; i=i+1)
      q[i] <- mkReg(dflt);

    Vector#(depth, Reg#(a)) vec_of_regs= newVector();
    for(Integer i=0; i<n; i=i+1) begin
      vec_of_regs[i]= asReg(q[i]);
    end

    SCounter cntr <- mkSCounter(n);
  
    PulseWire enqueueing <- mkPulseWire;
    Wire#(a)    x_wire <- mkWire;
    PulseWire dequeueing <- mkPulseWire;

    //TODO replace with mkPulseWire
    Wire#(Bool) wr_clear <- mkDWire(False);
  
    let empty = cntr.isEq(0);
    let full  = cntr.isEq(n);
  
    rule incCtr (enqueueing && !dequeueing && !wr_clear);
      cntr.incr;
      cntr.setNext(x_wire, q);
    endrule
    rule decCtr (dequeueing && !enqueueing && !wr_clear);
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
  
    method Action enq(x);
      enqueueing.send;
      x_wire <= x;
    endmethod

    method Bool notFull;
      return !full;
    endmethod
  
    method a first;
      return q[0];
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
  module mkSEMF_inst(Ifc_SEMF_FIFO#(3, Bit#(23)));
    let ifc();
    mkSEMF_FIFO#(0) _temp(ifc);
    return (ifc);
  endmodule

endpackage
