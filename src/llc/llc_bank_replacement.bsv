/* 
Copyright (c) 2019, IIT Madras All rights reserved.

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

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package llc_bank_replacement;
  `include "Logger.bsv"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import Vector::*;
  import LFSR::*;
  import Assert::*;
  import coherence_types :: * ;
  

  interface Ifc_replace#(numeric type sets, numeric type ways);
    method ActionValue#(Bit#(TLog#(ways))) line_replace (Bit#(TLog#(sets)) index, 
                                                  Bit#(ways) valid, Vector#(ways, Dict) states);
    method Action update_set (Bit#(TLog#(sets)) index, Bit#(TLog#(ways)) way);
    method Action reset_repl;
  endinterface
  
  module mkreplace#(String alg)(Ifc_replace#(sets,ways));

    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);

    Vector#(sets,Reg#(Bit#(TLog#(ways)))) v_count <- replicateM(mkReg(fromInteger(v_ways-1)));

    method ActionValue#(Bit#(TLog#(ways))) line_replace (Bit#(TLog#(sets)) index, 
                                                  Bit#(ways) valid, Vector#(ways, Dict) states);
      if (&(valid)==1)begin
        Bit#(TLog#(ways)) temp=0;
        for(Bit#(TAdd#(1,TLog#(ways))) i=0;i<fromInteger(v_ways);i=i+1) begin
          if(states[i] == Dict_I)begin
            temp=truncate(i);
          end
        end
        return temp;
      end
      else begin // if any line empty then send that
        Bit#(TLog#(ways)) temp=0;
        for(Bit#(TAdd#(1,TLog#(ways))) i=0;i<fromInteger(v_ways);i=i+1) begin
          if(valid[i]==0)begin
            temp=truncate(i);
          end
        end
        return temp;
      end
    endmethod
    method Action update_set (Bit#(TLog#(sets)) index, Bit#(TLog#(ways)) way);
      v_count[index]<=v_count[index]-1;
    endmethod
    method Action reset_repl;
      for(Integer i=0;i<v_sets;i=i+1)
        v_count[i]<=fromInteger(v_ways-1);
    endmethod
  endmodule
endpackage

