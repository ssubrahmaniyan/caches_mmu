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
  import BUtils :: * ;
  import ConfigReg :: * ;

  interface Ifc_storebuffer#( numeric type addr, 
                              numeric type wordsize, 
                              numeric type esize,
                              numeric type sbsize, 
                              numeric type fbsize);

    method ActionValue#(Tuple2#(Bit#(TMul#(wordsize,8)),Bit#(TMul#(wordsize,8)))) 
                                                            mav_check_sb_hit (Bit#(addr) phyaddr);
    method Action ma_allocate_entry (Bit#(addr) address, Bit#(TMul#(8,wordsize)) data, 
            Bit#(esize) epochs, Bit#(TLog#(fbsize)) fbindex, Bit#(2) size, Bool io);
    method ActionValue#(Tuple2#(Bool,Storebuffer#(addr, TMul#(wordsize,8), esize, TLog#(fbsize)))) 
                                                                            mav_store_to_commit;
    method Bool mv_sb_full;
    method Bool mv_sb_empty;
    method Bool mv_cacheable_store;
  endinterface

  function Bool isTrue(Bool a);
    return a;
  endfunction

  function Bit#(data) fn_OR(Bit#(data) x, Bit#(data) y);
    return x | y;
  endfunction

  /*doc:struct: this structure holds all the information that the store buffer holds.
  addr: address as requested by the core
  data: as presented by the core to the cache
  epoch: the epoch bits as presented by the core to the cache
  fbindex: the index of the fillbuffer that this store is to be effected on
  mask: all bits one in this field indicate the bits that will be affected by the corresponding
  store
  io: boolean value indicating if the store is to the cache or an MMIO
  */
  typedef struct{
    Bit#(a) addr;
    Bit#(d) data;
    Bit#(e) epoch;
    Bit#(f) fbindex;
    Bit#(d) mask;
    Bool    io;
    Bit#(2) size;
  } Storebuffer#(numeric type a, numeric type d, numeric type e, numeric type f) 
    deriving(Bits, FShow, Eq);

  module mk_storebuffer#(parameter Bit#(32) id)
    (Ifc_storebuffer#(addr, wordsize, esize, sbsize, fbsize))
    provisos( Log#(wordsize,wordbits),
              Mul#(wordsize,8,dataword),
              Add#(b__, wordbits, TMul#(wordbits, 2)),
              Add#(1, c__, sbsize),
              Mul#(16, a__, dataword),
              Mul#(32, d__, dataword)
            );

    let v_wordbits = valueOf(wordbits);
    
    /*doc:reg: A vector of registers indicating if the particular store buffer entry is valid or
     not*/
    Vector#(sbsize, ConfigReg#(Bool)) v_sb_valid <- replicateM(mkConfigReg(False));
    /*doc:reg: A vector of registers holding all the meta data of stores being presented by the core
     * to the cache*/
    Vector#(sbsize, Reg#(Storebuffer#(addr,dataword,esize,TLog#(fbsize)))) v_sb_meta 
                                                                    <- replicateM(mkReg(unpack(0)));

    /*doc:reg: Register to point to the head of the store buffers. Points to the entry that needs to
     * be allotted to a new store request*/
    Reg#(Bit#(TLog#(sbsize))) rg_head <- mkReg(0);
    /*doc:reg: Register to point to the oldest entry that was allotted in the storebuffer and that
     * needs to the be committed first*/
    Reg#(Bit#(TLog#(sbsize))) rg_tail <- mkReg(0);

    /*doc:var: variable to indicate that the storebuffer is full*/
    Bool sb_full = (all(isTrue, readVReg(v_sb_valid)));
    /*dov:var: variable to indicate that the storebuffer is empty*/
    Bool sb_empty=!(any(isTrue, readVReg(v_sb_valid)));

    method ActionValue#(Tuple2#(Bit#(dataword),Bit#(dataword))) mav_check_sb_hit (Bit#(addr) phyaddr);

      Vector#(sbsize, Bit#(dataword)) storemask;
      Vector#(sbsize, Bit#(dataword)) data_values;

      Bit#(TSub#(addr, wordbits)) wordaddr = truncateLSB(phyaddr);
      for (Integer i = 0; i< valueOf(sbsize); i = i + 1) begin
        data_values[i] = v_sb_meta[i].data;
        Bit#(TSub#(addr, wordbits)) compareaddr = truncateLSB(v_sb_meta[i].addr);
        storemask[i] = v_sb_meta[i].mask & duplicate(pack(compareaddr == wordaddr));
      end

      // See if the following can also be written as a vector function
      storemask[rg_tail] = ~storemask[rg_tail-1] & storemask[rg_tail];

      for (Integer i = 0; i<valueOf(sbsize); i = i + 1) begin
        data_values[i] = storemask[i] & data_values[i];
      end
      Bit#(wordbits) zeros = 0;
      Bit#(TMul#(wordbits,2)) shiftamt = {phyaddr[v_wordbits - 1:0], zeros};

      return tuple2(fold(fn_OR,storemask)>>shiftamt,fold(fn_OR,data_values)>>shiftamt);
    endmethod

    method Action ma_allocate_entry (Bit#(addr) address, Bit#(dataword) data, 
            Bit#(esize) epochs, Bit#(TLog#(fbsize)) fbindex, Bit#(2) size, Bool io) if(!sb_full);

      data = case (size[1 : 0])
        'b00 : duplicate(data[7 : 0]);
        'b01 : duplicate(data[15 : 0]);
        'b10 : duplicate(data[31 : 0]);
        default : data;
      endcase;
      Bit#(wordbits) zeros = 0;
      Bit#(TMul#(wordbits,2)) shiftamt = {address[v_wordbits - 1:0], zeros};
      Bit#(dataword) temp =  size == 0?'hff:
                             size == 1?'hffff:
                             size == 2?'hffffffff : '1;

      Bit#(dataword) storemask = temp << shiftamt;
      v_sb_valid[rg_tail] <= True;
      let _s = Storebuffer{addr:address, data: data, epoch: epochs, fbindex: fbindex,
                                      io: io, mask: storemask, size:truncate(size)};
      v_sb_meta[rg_tail] <= _s;
      rg_tail <= rg_tail + 1;
      `logLevel( storebuffer, 0, $format("SB[%2d]: Allocating sbindex:%d with ",id,rg_tail,
                                          fshow(_s)))
    endmethod
    method mv_sb_full = sb_full;
    method mv_sb_empty = sb_empty;
    method ActionValue#(Tuple2#(Bool,Storebuffer#(addr, TMul#(wordsize,8), esize, TLog#(fbsize)))) 
        mav_store_to_commit if(!sb_empty);
      rg_head <= rg_head + 1;
      v_sb_valid[rg_head] <= False;
      return tuple2(v_sb_valid[rg_head], v_sb_meta[rg_head]);
    endmethod
    method mv_cacheable_store = v_sb_meta[rg_head].io;
  endmodule

//  (*synthesize*)
//  module mksb_instance(Ifc_storebuffer#(`paddr, `dwords, `desize, `dsbsize, 1));
//    let ifc();
//    mk_storebuffer#(0) _temp(ifc);
//    return ifc;
//  endmodule
endpackage

