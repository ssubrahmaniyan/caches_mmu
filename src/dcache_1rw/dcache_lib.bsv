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
package dcache_lib;
  `include "Logger.bsv"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import Vector :: * ;
  import GetPut :: * ;
  import Assert  :: * ;
  import OInt :: * ;
  import BUtils :: * ;
  import Memory :: * ; // only for the updateDataWithMask function
  import DReg :: * ;

  import mem_config :: * ;

  typedef struct{
    Bool sed;
    Bool ded;
    Bit#(ways)    waymask;
  } TagResponse#(numeric type ways) deriving(Bits, Eq, FShow);

  interface Ifc_tagram#(numeric type sets, 
                        numeric type tagbits,
                        numeric type ways);

    /*doc:method: request method to initiate a read or write on the tags. A read is latched on all
    * ways. A write is peformed only on a single way.*/
    method Action ma_request( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(tagbits) tag, 
                              Bit#(TLog#(ways)) way);

    /*doc:method: This method will read the ram output from all ways. Compare with the input tag.
     * and respond with a hit-vector indicating which way was a hit. Also responds if there was a
     * single-error or double-error detected while performing the read across all the ways. */
    method TagResponse#(ways) mv_read_response(Bit#(tagbits) tag_in, 
                                                        Bit#(TLog#(ways)) wayselect,
                                                        Bool comp_select );    
  endinterface

  module mk_tagram(Ifc_tagram#(sets, tagbits, ways));
    
    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);

    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Vector#(ways, Ifc_mem_config1rw#(sets, tagbits, 1)) v_tags <-
                                                        replicateM(mkmem_config1rw(False));
    method Action ma_request( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(tagbits) tag, 
                              Bit#(TLog#(ways)) way);
    `ifdef ASSERT
      dynamicAssert(countOnes(way) <= 1,"TAGRAM: More than one way provided in inputs");
    `endif
      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_tags[i].request(0, index, tag, '1);
        end
      else
        v_tags[way].request(1, index, tag, '1);
    endmethod

    method TagResponse#(ways) mv_read_response(Bit#(tagbits) tag_in, 
                                                      Bit#(TLog#(ways)) wayselect,
                                                      Bool comp_select );    
      Vector#(ways, Bit#(tagbits)) lv_rd_tags;
      Bit#(ways) lv_hitvector = 0;
      Bool sed = False;
      Bool ded = False;
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_rd_tags[i] = v_tags[i].read_response;
      end
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_hitvector[i] = pack(lv_rd_tags[i] == tag_in);
      end
      return TagResponse{sed: sed, ded: ded, waymask: lv_hitvector};
    endmethod
  endmodule

  /* (*synthesize*)
  module mkinst(Ifc_tagram#(64, 20, 4));
    let ifc();
    mk_tagram _temp(ifc);
    return (ifc);
  endmodule */
endpackage

