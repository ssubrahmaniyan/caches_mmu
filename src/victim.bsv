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
package victim;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import BUtils::*;

  import cache_types::*;

  `define size 2
  
  interface Ifc_victim#(
                      numeric type wordsize, 
                      numeric type blocksize,  
                      numeric type sets,
                      numeric type ways,
                      numeric type respwidth, 
                      numeric type paddr,
                      numeric type size
                      );
    // The following method is called when there is a line to be evicted from the cache.
    method Action line_from_cache(Bit#(TMul#(blocksize,TMul#(wordsize,8))) dataline,Bit#(paddr) addr);
    // The following method is called by the core side to check if the requested word lies in the VB
    method Action read_req (Bit#(paddr) addr);
    // This method will carry the response if there is a word in the VB
    method Tuple2#(Bool,Bit#(respwidth)) read_response;
    // The following method will send a request to the memory to write the dirty line back to
    // memory. This shuold be triggered when the VB is full.
    method ActionValue#(DMem_write_request#(paddr)) memory_request;
    method ActionValue#(DMem_write_data#(respwidth)) memory_data;
    // The following method is called when a store from the write-back stage needs to be performed
    method Action store_from_core (Bit#(TLog#(size) ) index, Bit#(respwidth) data, Bit#(2) access_size,
                                   Bit#(TAdd#(TLog#(wordsize),TLog#(blocksize))) offset);
    method Bool vb_is_full; 
  endinterface

  module mkvictim(Ifc_victim#(wordsize,blocksize,sets, ways, respwidth, paddr, size))
      provisos(
            Mul#(wordsize, 8, _w),        // _w is the total bits in a word
            Mul#(blocksize, _w,linewidth),// linewidth is the total bits in a cache line
            Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
            Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
            Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
            Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
            Add#(_a, setbits, _b),        // _b total bits for index+offset, 
            Add#(tagbits, _b, paddr),     // tagbits = 32-(wordbits+blockbits+setbits)

            // required by compiler
            Add#(a__, respwidth, linewidth),
            Add#(d__, respwidth, TSub#(linewidth, respwidth)),
            Add#(TAdd#(tagbits, setbits), b__, paddr),
            Mul#(respwidth, c__, linewidth)
          );

    let v_sets=valueOf(sets);
    let v_setbits=valueOf(setbits);
    let v_wordbits=valueOf(wordbits);
    let v_blockbits=valueOf(blockbits);
    let v_linewidth=valueOf(linewidth);
    let v_tagbits=valueOf(tagbits);
    let verbosity=`VERBOSITY;
    let v_paddr=valueOf(paddr);
    let v_ways=valueOf(ways);
    let v_wordsize=valueOf(wordsize);
    let v_blocksize=valueOf(blocksize);
    let v_size=valueOf(size);

    Reg#(Bit#(linewidth)) vb_datalines [v_size]; 
    Reg#(Bit#(TAdd#(tagbits,setbits))) vb_tagbits [v_size];
    Reg#(Bit#( size )) vb_valid <- mkReg(0);
    for (Integer i=0; i<v_size ; i=i+1) begin
      vb_datalines[i]<-mkReg(0);
      vb_tagbits[i]<-mkReg(0);
    end

    Reg#(Tuple2#(Bool,Bit#(respwidth))) rg_response<- mkReg(tuple2(False,0));
    Reg#(Bit#(TSub#(linewidth,respwidth))) rg_evict_temp <- mkReg(0);

    Reg#(Bit#(TLog#( size ))) rg_enq <- mkReg(0);
    Reg#(Bit#(TLog#( size ))) rg_evict <- mkReg(0);
    Reg#(Bit#( size )) rg_evictmask <- mkReg('b1);

    FIFOF#(DMem_write_request#(paddr)) ff_write_request <- mkSizedFIFOF(2);
    FIFOF#(DMem_write_data#(respwidth)) ff_write_data <-mkSizedFIFOF(2);
    Reg#(Bit#(TLog#(blocksize))) rg_word_count<-mkReg(0);

    Bool full = unpack(&vb_valid);

    rule evict_entry(full);
      if(rg_word_count==0)begin
        ff_write_request.enq(tuple3({vb_tagbits[rg_evict],'d0},
                                    fromInteger(v_blocksize-1),
                                    fromInteger(v_wordbits)));
        ff_write_data.enq(tuple2(False,truncate(vb_datalines[rg_evict])));
        rg_word_count<=rg_word_count+1;
        rg_evict_temp<=truncate(vb_datalines[rg_evict]>>(v_wordsize*8));
      end
      else begin
        if(rg_word_count==fromInteger(v_blocksize-1))begin
          vb_valid[rg_evict]<=0;
          rg_evict<=rg_evict+1;
        end
        ff_write_data.enq(tuple2(rg_word_count==fromInteger(v_blocksize-1),
                                 truncate(rg_evict_temp)));
        rg_word_count<=rg_word_count+1;
        rg_evict_temp<=rg_evict_temp>>(v_wordsize*8);
      end
    endrule

    method Action line_from_cache(Bit#(TMul#(blocksize,TMul#(wordsize,8))) dataline, 
                                  Bit#(paddr) addr)if(!full);
      Bit#(tagbits) tag = addr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set = addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      vb_datalines[rg_enq]<=dataline;
      vb_tagbits[rg_enq]<={tag,set};
      vb_valid[rg_enq]<=1'b1;
      rg_enq<=rg_enq+1;
    endmethod

    method Action read_req (Bit#(paddr) addr);
      Bit#(TAdd#(3,TAdd#(wordbits,blockbits)))block_offset=
                                                        {addr[v_blockbits+v_wordbits-1:0],3'b0};
      Bit#(tagbits) tag = addr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) set = addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(TAdd#(tagbits,setbits)) t={tag,set};
      Bit#( size ) vb_hit=0;
      Bit#(linewidth) data_t [ v_size ];
      for (Integer i=0; i<v_size ; i=i+1) begin
        vb_hit[i]=pack( vb_valid[i]==1 && vb_tagbits[i]==t );
        data_t[i]=duplicate(vb_hit[i])&vb_datalines[i];
      end
      Bit#(linewidth) hitline=0;
      for(Integer i=0; i<v_size ;i=i+1)
        hitline=hitline|data_t[i];
      rg_response<=tuple2(unpack(|vb_hit),truncate(hitline>>block_offset));
    endmethod

    method ActionValue#(DMem_write_request#(paddr)) memory_request;
      ff_write_request.deq;
      return ff_write_request.first;
    endmethod
    method ActionValue#(DMem_write_data#(respwidth)) memory_data;
      ff_write_data.deq;
      return ff_write_data.first;
    endmethod
    method Action store_from_core (Bit#(TLog#( size) ) index, Bit#(respwidth) data, Bit#(2) access_size,
                                   Bit#(TAdd#(TLog#(wordsize),TLog#(blocksize))) offset);
      Bit#(respwidth) m=(access_size==0)?'hFF:
                            (access_size=='b01)?'hFFFF:'hFFFFFFFF;
                            //(access_size=='b10)?'hFFFFFFFF:'hFFFFFFFFFFFFFFFF;
      Bit#(linewidth) mask=duplicate(m)<<offset;                            
      Bit#(linewidth) data_mask=duplicate(data)&mask;
      vb_datalines[index]<=(vb_datalines[index]&~mask)|(data_mask);
    endmethod                                

    method read_response=rg_response;
    method vb_is_full=full;
  endmodule

  (*synthesize*)
  (*conflict_free="line_from_cache,store_from_core"*)
  module mkvictim_buffer(Ifc_victim#(4 , 8 , 64 , 4 ,32, 32, 4 ));
    let ifc();
    mkvictim _temp(ifc);
    return (ifc);
  endmodule
endpackage

