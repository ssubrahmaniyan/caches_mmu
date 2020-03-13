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

  typedef struct{
    Bool line_sed;
    Bool line_ded;
    Bit#(TMul#(TMul#(w,8),b)) line;
    Bool word_sed;
    Bool word_ded;
    Bit#(TMul#(8,w)) word;
  } DataResponse#(numeric type b, numeric type w) deriving(Bits, Eq, FShow);

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

  interface Ifc_dataram#(numeric type wordsize,
                         numeric type blocksize,
                         numeric type sets,
                         numeric type ways,
                         numeric type banks);
    /*doc:method: request method to initiate a read or write on the dataline. A read is latched on all
    * ways. A write is peformed only on a single way.*/
    method Action ma_request( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(TMul#(TMul#(wordsize, 8),blocksize)) dataline, 
                              Bit#(TLog#(ways)) way,
                              Bit#(banks) banks);

    /*doc:method: This method will read the ram output from all ways. Compare with the input tag.
     * and respond with a hit-vector indicating which way was a hit. Also responds if there was a
     * single-error or double-error detected while performing the read across all the ways. */
    method DataResponse#(blocksize,wordsize) mv_read_response(
                                              Bit#(TLog#(blocksize)) blocknum, 
                                              Bit#(ways) wayselect );
  endinterface

  module mk_dataram(Ifc_dataram#(wordsize, blocksize, sets, ways, banks))
      provisos(
          Mul#(TMul#(wordsize,8),blocksize,linewidth),
          Log#(wordsize, wordbits),
          Log#(blocksize, blockbits),
          Log#(sets, setbits),
          Mul#(wordsize,8, respwidth),

          // required by bsc
          Add#(a__, respwidth, linewidth), // since the response is truncated version of line
          Mul#(TDiv#(linewidth, banks), banks, linewidth), // from mem_config
          Add#(a__, TDiv#(linewidth, banks), linewidth) // from mem_config
      );
    let v_wordsize = valueOf(wordsize);
    let v_blocksize = valueOf(blocksize);
    let v_sets = valueOf(sets);
    let v_ways = valueOf(ways);
    let v_banks = valueOf(banks);

    Vector#(ways, Ifc_mem_config1rw#(sets, linewidth, banks)) v_data 
                                                            <- replicateM(mkmem_config1rw(False));
    method Action ma_request( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(linewidth) dataline, 
                              Bit#(TLog#(ways)) way,
                              Bit#(banks) banks);

      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_data[i].request(0, index, dataline, banks);
        end
      else
        v_data[way].request(1, index, dataline, banks);
    endmethod

    method DataResponse#(blocksize,wordsize) mv_read_response(
                                              Bit#(blockbits) blocknum, 
                                              Bit#(ways) wayselect );
      Vector#(ways, Bit#(respwidth)) lv_words = ?;
      Vector#(ways, Bit#(linewidth)) lv_lines = ?;
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth),blockbits))  block_offset = {blocknum,zeros};
      Bit#(respwidth) lv_selected_word = ?;
      Bit#(linewidth) lv_selected_line = ?;
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        if (wayselect[i] == 1) begin
          lv_selected_line = v_data[i].read_response;
          lv_selected_word = truncate(lv_selected_line>> block_offset);
        end
      end
      //for (Integer i = 0; i< v_ways ; i = i + 1) begin
      //  lv_words[i] = truncate(v_data[i].read_response >> block_offset);
      //  lv_lines[i] = v_data[i].read_response;
      //end
      //lv_selected_word = select(lv_words,unpack(wayselect));
      //lv_selected_line = select(lv_lines,unpack(wayselect));

      return DataResponse{word_sed: False, word_ded:False, word: lv_selected_word,
                          line_sed: False, line_ded:False, line: lv_selected_line};

    endmethod
  endmodule

  (*synthesize*)
  module mkinst_tag(Ifc_tagram#(64, 20, 4));
    let ifc();
    mk_tagram _temp(ifc);
    return (ifc);
  endmodule
  (*synthesize*)
  module mkinst_data(Ifc_dataram#(4, 4, 64, 4, 4));
    let ifc();
    mk_dataram _temp(ifc);
    return (ifc);
  endmodule


endpackage

