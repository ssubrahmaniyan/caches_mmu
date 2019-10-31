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

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package test_icache;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import BUtils::*;
  import RegFile::*;
  `include "Logger.bsv"

  interface Ifc_test_caches#(numeric type wordsize, 
                           numeric type blocksize,  
                           numeric type sets,
                           numeric type ways,
                           numeric type respwidth, 
                           numeric type paddr,
                           numeric type ibuswidth);
    method ActionValue#(Bit#(respwidth)) memory_operation(Bit#(paddr) addr,
        Bit#(2) access, Bit#(3) size, Bit#(respwidth) data);
  endinterface

  module mktest_caches(Ifc_test_caches#(wordsize, blocksize, sets, ways,
  respwidth, paddr, ibuswidth))
    provisos(
            Add#(a__, 32, respwidth),
            Add#(b__, 16, respwidth),
            Add#(c__, 8, respwidth),
            Add#(d__, 19, paddr),
    
            Mul#(8, e__, respwidth),
            Mul#(16, f__, respwidth),
            Mul#(32, g__, respwidth),
            Add#(h__, respwidth, ibuswidth),
            Add#(i__, TLog#(TDiv#(ibuswidth, 8)), TMul#(2, TLog#(TDiv#(ibuswidth,8))))

    );
    RegFile#(Bit#(19), Bit#(ibuswidth)) mem <- mkRegFileFullLoad("data.mem");

    method ActionValue#(Bit#(respwidth)) memory_operation(Bit#(paddr) addr,
        Bit#(2) access, Bit#(3) size, Bit#(respwidth) data);
      
        data= case (size[1:0])
          'b00: duplicate(data[7:0]);
          'b01: duplicate(data[15:0]);
          'b10: duplicate(data[31:0]);
          default: data;
        endcase;


        let v_wordbits = valueOf(TLog#(TDiv#(ibuswidth,8)));
        Bit#(19) index = truncate(addr>>v_wordbits);
        let loaded_data=mem.sub(index);
        Bit#(TLog#(TDiv#(ibuswidth,8))) zeros = 0;
        Bit#(TMul#(2,TLog#(TDiv#(ibuswidth,8)))) shift={addr[v_wordbits-1:0],zeros};
        let temp = loaded_data>>shift;
        Bit#(respwidth) response_word = case (size)
            'b000: signExtend(temp[7:0]);
            'b001: signExtend(temp[15:0]);
            'b010: signExtend(temp[31:0]);
            'b100: zeroExtend(temp[7:0]);
            'b101: zeroExtend(temp[15:0]);
            'b110: zeroExtend(temp[31:0]);
            default: truncate(temp);
          endcase;

        `logLevel( testcache, 0, $format("\tTEST: addr: %h index: %d access: %d size: %b Loadeddata: %h",
          addr, index, access, size, loaded_data))
      return response_word;
    endmethod
  endmodule
endpackage

