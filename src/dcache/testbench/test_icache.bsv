/* 
see LICENSE.incore
see LICENSE.iitm

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
        
        Bit#(ibuswidth) mask = size[1:0]==0?'hFF:size[1:0]==1?'hFFFF:size[1:0]==2?'hFFFFFFFF:'1;
        Bit#(TAdd#(3,TLog#(wordsize))) shift_amt={addr[v_wordbits-1:0],3'b0};
        mask= mask<<shift_amt;
        Bit#(ibuswidth) write_word=~mask&loaded_data|mask&zeroExtend(data);

        `logLevel( testcache, 0, $format("\tTEST: addr: %h index: %d access: %d size: %b \
  Loadeddata: %h write_word:%h mask:%h",
          addr, index, access, size, loaded_data, write_word, mask))
        if(access==1)
          mem.upd(index,write_word);
      return response_word;
    endmethod
  endmodule
endpackage

