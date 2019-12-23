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
package storebuffer;
  `include "Logger.bsv"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import Vector :: * ; 

  interface Ifc_storebuffer#(numeric type addr, numeric type data, numeric type esize,
                              numeric type sbsize, numeric type fbsize);

  endinterface

  function Bool isTrue(Bool a);
    return a;
  endfunction

  module mk_storebuffer(Ifc_storebuffer#(addr, data, esize, sbsize, fbsize));
    Vector#(sbsize, Reg#(Bit#(addr))) sb_addr <- replicateM(mkReg(0));
    Vector#(sbsize, Reg#(Bit#(esize))) sb_epoch <- replicateM(mkReg(0));
    Vector#(sbsize, Reg#(Bit#(data))) sb_data <- replicateM(mkReg(0));
    Vector#(sbsize, Reg#(Bit#(2))) sb_size <- replicateM(mkReg(0));
    Vector#(sbsize, Reg#(Bool)) sb_valid <- replicateM(mkReg(False));
    Vector#(sbsize, Reg#(Bool)) sb_io <- replicateM(mkReg(False));
    Vector#(sbsize, Reg#(Bit#(TLog#(fbsize)))) sb_fbindex <- replicateM(mkReg(0));

    Reg#(Bit#(TLog#(sbsize))) rg_head <- mkReg(0);
    Reg#(Bit#(TLog#(sbsize))) rg_tail <- mkReg(0);

    Bool sb_full = (all(isTrue, readVReg(sb_valid)));
    Bool sb_empty=!(any(isTrue, readVReg(sb_valid)));

    function Bit#(data) fn_storemask(Bit#(addr) phyaddr, );
      Bit#(TLog#(data)) shiftamt = 
    endfunction

    method ActionValue#(Tuple2#(Bit#(data),Bit#(data))) mav_check_sb_hit (Bit#(addr) phyaddr);

      Vector#(sbsize, Bit#(data)) storemask;
      Bit#(TSub#(addr, wordbits)) wordaddr = truncateLSB(phyaddr);
      for (Integer i = 0; i< valueOf(sbsize); i = i + 1) begin
        
        Bit#(TLog#(respwidth)) shiftamt = {store_addr[i][v_wordbits - 1:0], 3'b0};//TODO parameterize for XLEN
        Bit#(TSub#(paddr, wordbits)) compareaddr = truncateLSB(store_addr[i]);
        storemask[i]=0;
        if(compareaddr == wordaddr)begin
          Bit#(respwidth) temp = store_size[i] == 0?'hff:
                                 store_size[i] == 1?'hffff:
                                 store_size[i] == 2?'hffffffff : '1;
          temp = temp << shiftamt;
          storemask[i] = temp;
        end
      end

      Bit#(TLog#(respwidth)) shiftamt2 = {store_addr[rg_storetail][v_wordbits - 1:0], 3'b0}; //TODO parameterize for XLEN
      Bit#(respwidth) storemask2 = 0;
      Bit#(TSub#(paddr, wordbits)) compareaddr2 = truncateLSB(store_addr[rg_storetail]);
      if(compareaddr2 == wordaddr)begin
        Bit#(respwidth) temp = store_size[rg_storetail] == 0?'hff:
                          store_size[rg_storetail] == 1?'hffff:
                          store_size[rg_storetail] == 2?'hffffffff : '1;
        temp = temp << shiftamt2;
        storemask2 = temp & (~storemask1); // 'h00_00_00_FF
      end

      let data1 = storemask1 & store_data[rg_storetail - 1];
      let data2 = storemask2 & store_data[rg_storetail];
      wr_sb_hitword <= data1|data2;
      wr_sb_mask <= storemask1|storemask2;
  endmodule
endpackage

