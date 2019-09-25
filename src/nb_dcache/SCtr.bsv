package SCtr;
	interface SCounter;
	   method Action incr;
	   method Action decr;
	   method Bool isEq(Integer n);
	   method Action setNext (b value, Reg#(b) as[]);
	   method Action set (b value, Reg#(b) as[]);
	   method Action clear;
	endinterface
	
	module mkSCtr#(Reg#(UInt#(s)) c)(SCounter);
	   method Action incr; c <= c+1; endmethod
	   method Action decr; c <= c-1; endmethod
	   method isEq(n) = (c==fromInteger(n));
	   method Action setNext (b value, Reg#(b) as[]); as[c] <= value; endmethod
	   method Action set (b value, Reg#(b) as[]); as[c-1] <= value; endmethod
	   method Action clear; c <= 0; endmethod
	endmodule
	
	// A counter which can count up to m inclusive (m known at compile time):
	module mkSCounter#(Integer m)(SCounter);
	   let _i = ?;
	   if      (m<2)      begin Reg#(UInt#(1))  r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<4)      begin Reg#(UInt#(2))  r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<8)      begin Reg#(UInt#(3))  r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<16)     begin Reg#(UInt#(4))  r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<32)     begin Reg#(UInt#(5))  r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<64)     begin Reg#(UInt#(6))  r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<128)    begin Reg#(UInt#(7))  r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<256)    begin Reg#(UInt#(8))  r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<512)    begin Reg#(UInt#(9))  r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<1024)   begin Reg#(UInt#(10)) r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<2048)   begin Reg#(UInt#(11)) r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<4096)   begin Reg#(UInt#(12)) r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<8192)   begin Reg#(UInt#(13)) r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<16384)  begin Reg#(UInt#(14)) r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<32768)  begin Reg#(UInt#(15)) r <- mkReg(0); _i <- mkSCtr(r); end
	   else if (m<65536)  begin Reg#(UInt#(16)) r <- mkReg(0); _i <- mkSCtr(r); end
	   return _i;
	endmodule
endpackage
