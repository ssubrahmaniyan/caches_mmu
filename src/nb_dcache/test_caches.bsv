/* 
see LICENSE.iitm

Author: Neel Gala, Arjun Menon
Email id: neelgala@gmail.com, c.arjunmenon@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package test_caches;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import BUtils::*;
  import RegFile::*;

  interface Ifc_test_caches#(numeric type wordsize, 
                           numeric type blocksize,  
                           numeric type sets,
                           numeric type ways,
                           numeric type respwidth, 
                           numeric type paddr);
    method ActionValue#(Bit#(respwidth)) memory_operation(Bit#(paddr) addr,
        Bit#(2) access, Bit#(3) size, Bit#(respwidth) data);
  endinterface

  module mktest_caches(Ifc_test_caches#(wordsize, blocksize, sets, ways, respwidth, paddr))
    provisos(
            Add#(k__, 128, respwidth),
            Add#(i__, 64, respwidth),
            Add#(a__, 32, respwidth),
            Add#(b__, 16, respwidth),
            Add#(c__, 8, respwidth),
            Add#(d__, 19, paddr),
    
            Mul#(8, e__, respwidth),
            Mul#(16, f__, respwidth),
            Mul#(32, g__, respwidth),
            Mul#(64, h__, respwidth),
            Mul#(128, j__, respwidth)

    );
    RegFile#(Bit#(19), Bit#(respwidth)) mem <- mkRegFileFullLoad("data.mem");

    method ActionValue#(Bit#(respwidth)) memory_operation(Bit#(paddr) addr,
        Bit#(2) access, Bit#(3) size, Bit#(respwidth) data);
      
        data= case (size[1:0])
          'b00: duplicate(data[7:0]);
          'b01: duplicate(data[15:0]);
          'b10: duplicate(data[31:0]);
					'b11: duplicate(data[63:0]);
          default: data;
        endcase;


        let v_wordbits = valueOf(TLog#(wordsize));
        Bit#(19) index = truncate(addr>>v_wordbits);
        let loaded_data=mem.sub(index);
        Bit#(TAdd#(3,TLog#(wordsize))) shift={addr[v_wordbits-1:0],3'b0};
        let temp = loaded_data>>shift;
        Bit#(respwidth) response_word = case (size)
            'b000: signExtend(temp[7:0]);
            'b001: signExtend(temp[15:0]);
            'b010: signExtend(temp[31:0]);
            'b011: signExtend(temp[63:0]);
            'b100: zeroExtend(temp[7:0]);
            'b101: zeroExtend(temp[15:0]);
            'b110: zeroExtend(temp[31:0]);
            'b111: zeroExtend(temp[63:0]);
            default: temp;
          endcase;

        Bit#(respwidth) mask = size[1:0]==0?'hFF:size[1:0]==1?'hFFFF:size[1:0]==2?'hFFFFFFFF:size[1:0]==3?'hFFFFFFFF_FFFF_FFFF:'1;
        Bit#(TAdd#(3,TLog#(wordsize))) shift_amt={addr[v_wordbits-1:0],3'b0};
        mask= mask<<shift_amt;
        Bit#(respwidth) write_word=~mask&loaded_data|mask&data;
        $display($time,"\tTEST: addr: %h index: %d access: %d size: %b Loadeddata: %h mask: %h data: %h write_Word:%h",
            addr, index, access, size, loaded_data, mask, data, write_word);
        if(access==2)
          mem.upd(index,write_word);
        return response_word;
    endmethod
  endmodule
endpackage


