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
  import ConfigReg :: * ;
  import io_func::*;

  import mem_config :: * ;
  import dcache_types :: * ;

  typedef struct{
    Bool sed;
    Bool ded;
    Bit#(ways)    waymask;
    Bit#(a)       address;
  } TagResponse#(numeric type ways, numeric type a) deriving(Bits, Eq, FShow);

  typedef struct{
    Bool line_sed;
    Bool line_ded;
    Bool word_sed;
    Bool word_ded;
    Bit#(TMul#(TMul#(w,8),b)) line;
    Bit#(TMul#(8,w)) word;
  } DataResponse#(numeric type b, numeric type w) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(l) dataline;
    Bit#(a) address;
    Bit#(1) err;
    Bit#(1) dirty;
  } ReleaseInfo#(numeric type l, numeric type a) deriving(Bits, FShow, Eq);

  typedef struct{
    Bit#(1) err;
    Bit#(TMul#(w,8)) word;
    Bit#(f) waymask;
    Bool line_hit;
    Bool word_hit;
  } PollingResponse#(numeric type w, numeric type f) deriving(Bits, FShow, Eq);

  interface Ifc_tagram#(numeric type wordsize,
                        numeric type blocksize,
                        numeric type sets,
                        numeric type ways,
                        numeric type paddr);

    /*doc:method: request method to initiate a read or write on the tags. A read is latched on all
    * ways. A write is peformed only on a single way.*/
    method Action ma_request( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(paddr) address, 
                              Bit#(TLog#(ways)) way);

    /*doc:method: This method will read the ram output from all ways. Compare with the input tag.
     * and respond with a hit-vector indicating which way was a hit. Also responds if there was a
     * single-error or double-error detected while performing the read across all the ways. */
    method TagResponse#(ways, paddr) mv_read_response(Bit#(paddr) address_in, 
                                               Bit#(TLog#(ways)) wayselect);    
  endinterface

  module mk_tagram1rw#(parameter Bit#(32) id)(Ifc_tagram#(wordsize, blocksize, sets, ways, paddr))
    provisos(    
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr)     // tagbits = 32-(wordbits+blockbits+setbits)
    );
    
    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);

    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Vector#(ways, Ifc_mem_config1rw#(sets, tagbits, 1)) v_tags <-
                                                        replicateM(mkmem_config1rw(False));
    method Action ma_request( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(paddr) address, 
                              Bit#(TLog#(ways)) way);
      Bit#(tagbits) tag = truncateLSB(address);
      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_tags[i].request(0, index, tag, '1);
        end
      else
        v_tags[way].request(1, index, tag, '1);
    endmethod

    method TagResponse#(ways, paddr) mv_read_response(Bit#(paddr) address_in, 
                                               Bit#(TLog#(ways)) wayselect );

      Bit#(tagbits) tag_in = truncateLSB(address_in);
      Bit#(ways) lv_hitvector = 0;
      Bool sed = False;
      Bool ded = False;
      Bit#(paddr)  lv_tag = {v_tags[wayselect].read_response,'d0};
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_hitvector[i] = pack(v_tags[i].read_response == tag_in);
      end
      return TagResponse{sed: sed, ded: ded, waymask: lv_hitvector, address: lv_tag };
    endmethod
  endmodule
  
  module mk_tagram1r1w#(parameter Bit#(32) id)(Ifc_tagram#(wordsize, blocksize, sets, ways, paddr))
    provisos(    
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr)     // tagbits = 32-(wordbits+blockbits+setbits)
    );
    
    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);

    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Vector#(ways, Ifc_mem_config1r1w#(sets, tagbits, 1)) v_tags 
                                                            <- replicateM(mkmem_config1r1w(False,False));
    method Action ma_request( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(paddr) address, 
                              Bit#(TLog#(ways)) way);
      Bit#(tagbits) tag = truncateLSB(address);
      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_tags[i].read(index);
        end
      else
        v_tags[way].write(1, index, tag, '1);
    endmethod

    method TagResponse#(ways, paddr) mv_read_response(Bit#(paddr) address_in, 
                                               Bit#(TLog#(ways)) wayselect );

      Bit#(tagbits) tag_in = truncateLSB(address_in);
      Bit#(ways) lv_hitvector = 0;
      Bool sed = False;
      Bool ded = False;
      Bit#(paddr)  lv_tag = {v_tags[wayselect].read_response,'d0};
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_hitvector[i] = pack(v_tags[i].read_response == tag_in);
      end
      return TagResponse{sed: sed, ded: ded, waymask: lv_hitvector, address: lv_tag };
    endmethod
  endmodule
  
  interface Ifc_tagram2rw#(
                        numeric type wordsize,
                        numeric type blocksize,
                        numeric type sets,
                        numeric type ways,
                        numeric type paddr);

    /*doc:method: request method to initiate a read or write on the tags. A read is latched on all
    * ways. A write is peformed only on a single way.*/
    method Action ma_read_p1(Bit#(TLog#(sets)) index);
    method Action ma_request_p2( Bool read_write, 
                                 Bit#(TLog#(sets)) index, 
                                 Bit#(paddr) address, 
                                 Bit#(TLog#(ways)) way);

    /*doc:method: This method will read the ram output from all ways. Compare with the input tag.
     * and respond with a hit-vector indicating which way was a hit. Also responds if there was a
     * single-error or double-error detected while performing the read across all the ways. */
    method TagResponse#(ways, paddr) mv_read_response_p1(Bit#(paddr) address_in, 
                                                         Bit#(TLog#(ways)) wayselect);    
    method TagResponse#(ways, paddr) mv_read_response_p2(Bit#(TLog#(ways)) wayselect);    
  endinterface
  
  module mk_tagram2rw#(parameter Bit#(32) id)(Ifc_tagram2rw#(wordsize, blocksize, sets, ways, paddr))
    provisos(    
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr)     // tagbits = 32-(wordbits+blockbits+setbits)
    );
    
    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);

    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Vector#(ways, Ifc_mem_config2rw#(sets, tagbits, 1)) v_tags <-
                                                        replicateM(mkmem_config2rw(False,True));
    method Action ma_read_p1(Bit#(TLog#(sets)) index);
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        v_tags[i].p1.request(0,index,?, '1);
      end
    endmethod
    method Action ma_request_p2( Bool read_write, 
                                 Bit#(TLog#(sets)) index, 
                                 Bit#(paddr) address, 
                                 Bit#(TLog#(ways)) way);
      Bit#(tagbits) tag = truncateLSB(address);
      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_tags[i].p2.request(0, index, tag, '1);
        end
      else
        v_tags[way].p2.request(1, index, tag, '1);
    endmethod

    method TagResponse#(ways, paddr) mv_read_response_p1(Bit#(paddr) address_in, 
                                               Bit#(TLog#(ways)) wayselect );

      Bit#(tagbits) tag_in = truncateLSB(address_in);
      Bit#(ways) lv_hitvector = 0;
      Bool sed = False;
      Bool ded = False;
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_hitvector[i] = pack(v_tags[i].p1.read_response == tag_in);
      end
      return TagResponse{sed: sed, ded: ded, waymask: lv_hitvector, address: ?};
    endmethod
    method TagResponse#(ways, paddr) mv_read_response_p2(Bit#(TLog#(ways)) wayselect );
      Bool sed = False;
      Bool ded = False;
      Bit#(paddr)  lv_tag = {v_tags[wayselect].p2.read_response,'d0};
      return TagResponse{sed: sed, ded: ded, waymask: 0, address: lv_tag };
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

  module mk_dataram1rw#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_dataram#(wordsize, blocksize, sets, ways, banks))
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
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth),blockbits))  block_offset = {blocknum,zeros};
      Bit#(respwidth) lv_selected_word = ?;
      Bit#(linewidth) lv_selected_line = ?;
      if (onehot) begin
        Vector#(ways, Bit#(respwidth)) lv_words = ?;
        Vector#(ways, Bit#(linewidth)) lv_lines = ?;
        for (Integer i = 0; i< v_ways ; i = i + 1) begin
          lv_words[i] = truncate(v_data[i].read_response >> block_offset);
          lv_lines[i] = v_data[i].read_response;
        end
        lv_selected_word = select(lv_words,unpack(wayselect));
        lv_selected_line = select(lv_lines,unpack(wayselect));
      end
      else begin
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          if (wayselect[i] == 1) begin
            lv_selected_line = v_data[i].read_response;
            lv_selected_word = truncate(lv_selected_line>> block_offset);
          end
        end
      end

      return DataResponse{word_sed: False, word_ded:False, word: lv_selected_word,
                          line_sed: False, line_ded:False, line: lv_selected_line};

    endmethod
  endmodule
  module mk_dataram1r1w#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_dataram#(wordsize, blocksize, sets, ways, banks))
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

//    Vector#(ways, Ifc_mem_config1rw#(sets, linewidth, banks)) v_data 
//                                                            <- replicateM(mkmem_config1rw(False));
    Vector#(ways, Ifc_mem_config1r1w#(sets, linewidth, banks)) v_data 
                                                            <- replicateM(mkmem_config1r1w(False,False));
    method Action ma_request( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(linewidth) dataline, 
                              Bit#(TLog#(ways)) way,
                              Bit#(banks) banks);

      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_data[i].read(index);
        end
      else
        v_data[way].write(1, index, dataline, banks);
    endmethod

    method DataResponse#(blocksize,wordsize) mv_read_response(
                                              Bit#(blockbits) blocknum, 
                                              Bit#(ways) wayselect );
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth),blockbits))  block_offset = {blocknum,zeros};
      Bit#(respwidth) lv_selected_word = ?;
      Bit#(linewidth) lv_selected_line = ?;
      if (onehot) begin
        Vector#(ways, Bit#(respwidth)) lv_words = ?;
        Vector#(ways, Bit#(linewidth)) lv_lines = ?;
        for (Integer i = 0; i< v_ways ; i = i + 1) begin
          lv_words[i] = truncate(v_data[i].read_response >> block_offset);
          lv_lines[i] = v_data[i].read_response;
        end
        lv_selected_word = select(lv_words,unpack(wayselect));
        lv_selected_line = select(lv_lines,unpack(wayselect));
      end
      else begin
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          if (wayselect[i] == 1) begin
            lv_selected_line = v_data[i].read_response;
            lv_selected_word = truncate(lv_selected_line>> block_offset);
          end
        end
      end

      return DataResponse{word_sed: False, word_ded:False, word: lv_selected_word,
                          line_sed: False, line_ded:False, line: lv_selected_line};

    endmethod
  endmodule
  
  interface Ifc_dataram2rw#(
                         numeric type wordsize,
                         numeric type blocksize,
                         numeric type sets,
                         numeric type ways,
                         numeric type banks);
    /*doc:method: request method to initiate a read or write on the dataline. A read is latched on all
    * ways. A write is peformed only on a single way.*/
    method Action ma_read_p1(Bit#(TLog#(sets)) index, Bit#(banks) banks);
    method Action ma_request_p2(
                              Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(TMul#(TMul#(wordsize, 8),blocksize)) dataline, 
                              Bit#(TLog#(ways)) way,
                              Bit#(banks) banks);

    /*doc:method: This method will read the ram output from all ways. Compare with the input tag.
     * and respond with a hit-vector indicating which way was a hit. Also responds if there was a
     * single-error or double-error detected while performing the read across all the ways. */
    method DataResponse#(blocksize,wordsize) mv_read_response_p1(
                                              Bit#(TLog#(blocksize)) blocknum, 
                                              Bit#(ways) wayselect );
    method DataResponse#(blocksize,wordsize) mv_read_response_p2(Bit#(ways) wayselect );
  endinterface
  module mk_dataram2rw#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_dataram2rw#(wordsize, blocksize, sets, ways, banks))
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

    Vector#(ways, Ifc_mem_config2rw#(sets, linewidth, banks)) v_data 
                                                 <- replicateM(mkmem_config2rw(False, False));
    method Action ma_read_p1(Bit#(TLog#(sets)) index, Bit#(banks) banks);
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        v_data[i].p1.request(0, index, ?, banks);
      end
    endmethod
    method Action ma_request_p2( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(linewidth) dataline, 
                              Bit#(TLog#(ways)) way,
                              Bit#(banks) banks);

      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_data[i].p2.request(0, index, dataline, banks);
        end
      else
        v_data[way].p1.request(1, index, dataline, banks);
    endmethod

    method DataResponse#(blocksize,wordsize) mv_read_response_p1(
                                              Bit#(blockbits) blocknum, 
                                              Bit#(ways) wayselect );
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth),blockbits))  block_offset = {blocknum,zeros};
      Bit#(respwidth) lv_selected_word = ?;
      Bit#(linewidth) lv_selected_line = ?;
      if (onehot) begin
        Vector#(ways, Bit#(respwidth)) lv_words = ?;
        Vector#(ways, Bit#(linewidth)) lv_lines = ?;
        for (Integer i = 0; i< v_ways ; i = i + 1) begin
          lv_words[i] = truncate(v_data[i].p1.read_response >> block_offset);
          lv_lines[i] = v_data[i].p1.read_response;
        end
        lv_selected_word = select(lv_words,unpack(wayselect));
        lv_selected_line = select(lv_lines,unpack(wayselect));
      end
      else begin
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          if (wayselect[i] == 1) begin
            lv_selected_line = v_data[i].p1.read_response;
            lv_selected_word = truncate(lv_selected_line>> block_offset);
          end
        end
      end

      return DataResponse{word_sed: False, word_ded:False, word: lv_selected_word,
                          line_sed: False, line_ded:False, line: lv_selected_line};

    endmethod
    method DataResponse#(blocksize,wordsize) mv_read_response_p2(Bit#(ways) wayselect );
      Bit#(linewidth) lv_selected_line = ?;
      if (onehot) begin
        Vector#(ways, Bit#(linewidth)) lv_lines = ?;
        for (Integer i = 0; i< v_ways ; i = i + 1) begin
          lv_lines[i] = v_data[i].p1.read_response;
        end
        lv_selected_line = select(lv_lines,unpack(wayselect));
      end
      else begin
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          if (wayselect[i] == 1) begin
            lv_selected_line = v_data[i].p1.read_response;
          end
        end
      end
      return DataResponse{word_sed: False, word_ded:False, word: ?,
                          line_sed: False, line_ded:False, line: lv_selected_line};
    endmethod
  endmodule

  interface Ifc_fillbuffer#(numeric type fbsize,
                            numeric type wordsize,
                            numeric type blocksize,
                            numeric type sets,
                            numeric type banks,
                            numeric type paddr,
                            numeric type buswidth);
    (*always_ready*)
    method Bool mv_fbfull ;
    (*always_ready*)
    method Bool mv_fbempty ;
    (*always_ready*)
    method Bool mv_fbhead_valid;
    (*always_ready*)
    method Bit#(paddr) mv_fbhead_address;
    method Action ma_allocate_line( Bool                                      from_ram,
                                    Bit#(TMul#(TMul#(wordsize,8),blocksize))  dataline,
                                    Bit#(paddr)                               address,
                                    Bit#(1)                                   dirty );

    method Action ma_fill_from_memory(DCache_mem_readresp#(buswidth)  mem_resp,
                                      Bit#(TLog#(fbsize))             fbindex,
                                      Bit#(TMul#(wordsize,blocksize)) init_enable);

    method Action ma_from_storebuffer(Bit#(TMul#(blocksize,wordsize))          byte_enable,
                                     Bit#(TMul#(TMul#(wordsize,8),blocksize))  dataline,
                                     Bit#(TLog#(fbsize)) fbindex);

    method ActionValue#(ReleaseInfo#(TMul#(blocksize,TMul#(wordsize,8)), paddr))
                                                                      mav_release_info;
    method PollingResponse#(wordsize,fbsize) mav_polling_response(
      Bit#(paddr) address); 

  endinterface

  (*conflict_free="mav_release_info,ma_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, ma_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, mav_release_info"*)
  (*conflict_free="ma_allocate_line, ma_from_storebuffer"*)
  module mk_fillbuffer#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_fillbuffer#(fbsize, wordsize, blocksize, sets, banks, paddr, buswidth))
      provisos(
          Mul#(TMul#(wordsize,8),blocksize,linewidth),
          Log#(wordsize, wordbits),
          Log#(blocksize, blockbits),
          Log#(sets, setbits),
          Mul#(wordsize,8, respwidth),
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr),     // tagbits = 32-(wordbits+blockbits+setbits)
          
          // required by bsc
          Add#(a__, TLog#(TMul#(blocksize, wordsize)), TAdd#(TLog#(TMul#(wordsize,
    blocksize)), 1)),
          Mul#(blocksize, wordsize, TDiv#(linewidth, 8)),
          Mul#(buswidth, b__, linewidth),
          Add#(c__, respwidth, linewidth),
          Add#(d__, blockbits, paddr),
          Add#(TAdd#(tagbits, setbits), e__, paddr)
          );

    let v_wordsize = valueOf(wordsize);
    let v_blocksize = valueOf(blocksize);
    let v_sets = valueOf(sets);
    let v_banks = valueOf(banks);
    let v_wordbits = valueOf(wordbits);
    let v_blockbits = valueOf(blockbits);
    let v_buswidth = valueOf(buswidth);
    let v_fbsize = valueOf(fbsize);
    Integer lv_offset = case(valueOf(respwidth)) 32: 4;      64: 8;      128: 16;   endcase;
    Integer lv_offset1 = case(valueOf(buswidth)) 32: 4;      64: 8;      128: 16;   endcase;
    function Bool isTrue(Bool a);
      return a;
    endfunction

    /*doc:func: This function generates the byte-enable for a data-line sized vector based on the
    request made by the core */
    function Bit#(TDiv#(linewidth,8)) fn_enable(Bit#(blockbits) word_index);
      Bit#(TDiv#(linewidth,8)) write_enable = 'hF << ({4'b0,word_index}*fromInteger(lv_offset));
      return write_enable;
    endfunction

    /*doc: vec: vector of registers to maintain the valid bit for fill-buffers*/
    Vector#(fbsize,Reg#(Bool))                      v_fb_addr_valid    <- replicateM(mkReg(False));
    /*doc: vec: vector of registers to hold the dataline for fill-buffers.*/
    Vector#(fbsize,Reg#(Bit#(linewidth)))           v_fb_data     <- replicateM(mkReg(unpack(0)));
    /*doc: vec: vector of registers to indicate that the line fill faced a bus-error*/
    Vector#(fbsize,Reg#(Bit#(1)))                   v_fb_err      <- replicateM(mkReg(0));
    /*doc: vec: vector of registers to indicate that the line in the fill-buffer is dirty*/
    Vector#(fbsize,Reg#(Bit#(1)))                   v_fb_dirty    <- replicateM(mkReg(0));
    /*doc: vec: vector of regisetrs to indicate if the entire line of the fillbuffer entry is
     * available or not*/
    Vector#(fbsize,Reg#(Bool))                   v_fb_line_valid  <- replicateM(mkReg(False));
    /*doc: reg: register to indicate how many bytes of the line have been filled by the
     bus*/
    Reg#(Bit#(TDiv#(linewidth,8)))                  rg_fb_enables    <- mkReg(0);
    /*doc: vec: vector registers indicating the address of the fill-buffer line*/
    Vector#(fbsize,Reg#(Bit#(paddr)))               v_fb_addr     <- replicateM(mkReg(0));

    /*doc:reg: register pointing to the next entry being released from the fillbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbhead     <- mkReg(0);
    /*doc:reg: register pointing to next entry being allotted on the filbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbtail     <- mkReg(0);
    /*doc:reg: temporary register holding the WE for the data to be updated in the fillbuffer from
    the memory response*/
    Reg#(Bit#(TMul#(blocksize, wordsize)))           rg_temp_enable<- mkReg(0);
    /*doc:wire: holds the byte-enables for the store operation being performed*/
    Wire#(Bit#(TMul#(blocksize,wordsize)))          wr_store_be <- mkDWire(0);
    /*doc:wire: holds the data to be updated in the fill-buffer*/
    Wire#(Bit#(linewidth))                          wr_store_data <- mkDWire(0);

    
    /*doc:var: variable indicating the fillbuffer is full*/
    Bool fb_full = (all(isTrue, readVReg(v_fb_addr_valid)));
    /*doc:var: variable indicating the fillbuffer is empty*/
    Bool fb_empty=!(any(isTrue, readVReg(v_fb_addr_valid)));

    method mv_fbfull = fb_full;
    method mv_fbempty = fb_empty;
    method mv_fbhead_valid = v_fb_line_valid[rg_fbhead];
    method mv_fbhead_address = v_fb_addr[rg_fbhead];
    method Action ma_allocate_line( Bool                                      from_ram,
                                    Bit#(TMul#(TMul#(wordsize,8),blocksize))  dataline,
                                    Bit#(paddr)                               address,
                                    Bit#(1)                                   dirty );
      Bit#(1) _temp = pack(from_ram);
      v_fb_addr_valid[rg_fbtail] <= True;
      v_fb_addr[rg_fbtail] <= address;
      v_fb_dirty[rg_fbtail] <= _temp & dirty;
      v_fb_line_valid[rg_fbtail] <= from_ram;
      v_fb_err[rg_fbtail] <= 0;
      v_fb_data[rg_fbtail] <= dataline;
      if(!from_ram)
        rg_fb_enables <= 0;
      if(rg_fbtail == fromInteger(v_fbsize -1))
        rg_fbtail <= 0;
      else
        rg_fbtail <= rg_fbtail + 1;
    endmethod
    method Action ma_fill_from_memory(DCache_mem_readresp#(buswidth)  mem_resp,
                                      Bit#(TLog#(fbsize))             fbindex,
                                      Bit#(TMul#(wordsize,blocksize)) init_enable);
      
      let lv_fb_enable = rg_fb_enables;
      v_fb_err[fbindex] <= pack(mem_resp.err);
      Bit#(TMul#(blocksize,wordsize)) lv_current_enable = lv_fb_enable == 0? init_enable:
                                                                            rg_temp_enable;
      Bit#(linewidth) lv_new_word = duplicate(mem_resp.data);
      Bit#(TAdd#(TLog#(TMul#(wordsize,blocksize)),1)) rotate_amount =
                                                (fromInteger(valueOf(TDiv#(buswidth,8))));

      // using a special function here from Memory library of Bluespec to update data
      let lv_fb_linedata = updateDataWithMask(v_fb_data[fbindex], lv_new_word, lv_current_enable);
      lv_fb_linedata = updateDataWithMask(lv_fb_linedata, wr_store_data, wr_store_be);
      rg_temp_enable <= rotateBitsBy(lv_current_enable,unpack(truncate(rotate_amount)));
      v_fb_data[fbindex] <=  lv_fb_linedata;
      if(mem_resp.last)begin
        v_fb_line_valid[fbindex] <= True;
        rg_fb_enables <= 0;
      end
      else
        rg_fb_enables <= lv_fb_enable | lv_current_enable;

    endmethod
    method Action ma_from_storebuffer(Bit#(TMul#(blocksize,wordsize))          byte_enable,
                                     Bit#(TMul#(TMul#(wordsize,8),blocksize))  dataline,
                                     Bit#(TLog#(fbsize)) fbindex);
      if(v_fb_line_valid[fbindex]) begin
        let lv_fbline = updateDataWithMask(v_fb_data[fbindex], dataline, byte_enable);
        v_fb_data[fbindex] <= lv_fbline;
      end
      else begin
        wr_store_data <= dataline;
        wr_store_be <= byte_enable;
      end
    endmethod
    method ActionValue#(ReleaseInfo#(TMul#(blocksize,TMul#(wordsize,8)), paddr))
                                                                      mav_release_info;
      if(rg_fbhead == fromInteger(v_fbsize -1))
        rg_fbhead <= 0;
      else
        rg_fbhead <= rg_fbhead + 1;
      v_fb_addr_valid[rg_fbhead] <= False;
      v_fb_line_valid[rg_fbhead] <= False;
      return ReleaseInfo{dataline:v_fb_data[rg_fbhead], err:v_fb_err[rg_fbhead],
                          dirty:v_fb_dirty[rg_fbhead], address: v_fb_addr[rg_fbhead]};
    endmethod
    method PollingResponse#(wordsize,fbsize) mav_polling_response(
      Bit#(paddr) address); 

      Bit#(TAdd#(tagbits, setbits)) input_tag = truncateLSB(address);

      Bit#(blockbits) word_index = truncate(address >> v_wordbits);
      let required_enable = fn_enable(word_index);
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth), blockbits)) block_offset = 
                                            {address[v_blockbits+v_wordbits-1:v_wordbits], zeros};
      Bit#(fbsize) lv_hitvector = 0; 
      Bit#(respwidth) lv_selected_word = ?;
      Bit#(1) lv_err = ?;
      Bool lv_linevalid = False;
      for (Integer i = 0; i<v_fbsize; i = i + 1) begin
        lv_hitvector[i] = pack((truncateLSB(v_fb_addr[i]) == input_tag) && v_fb_addr_valid[i]);
      end
      if (onehot) begin
        Vector#(fbsize, Bit#(respwidth)) lv_words = ?;
        for (Integer i = 0; i< v_fbsize; i = i + 1) begin
          lv_words[i] = truncate(v_fb_data[i] >> block_offset);
        end
        lv_selected_word = select(lv_words,unpack(lv_hitvector));
        lv_err = select(readVReg(v_fb_err), unpack(lv_hitvector));
        lv_linevalid = select(readVReg(v_fb_line_valid), unpack(lv_hitvector));
      end
      else begin
        for (Integer i = 0; i<v_fbsize; i = i + 1) begin
          if (lv_hitvector[i] == 1) begin
            lv_selected_word = truncate(v_fb_data[i] >> block_offset);
            lv_err = v_fb_err[i];
            lv_linevalid = v_fb_line_valid[i];
          end
        end
      end
      Bool lv_wordhit = (lv_linevalid || ((required_enable & rg_fb_enables) != 0));
      return PollingResponse{err: lv_err, word:lv_selected_word, waymask: lv_hitvector,
                             line_hit: unpack(|lv_hitvector), word_hit: lv_wordhit};
    endmethod
  endmodule

  // where buswidth = respwidth and banksize = respwidth
  interface Ifc_fillbuffer_v2#(numeric type fbsize,
                            numeric type wordsize,
                            numeric type blocksize,
                            numeric type sets,
                            numeric type banks,
                            numeric type paddr,
                            numeric type respwidth);
    (*always_ready*)
    method Bool mv_fbfull ;
    (*always_ready*)
    method Bool mv_fbempty ;
    (*always_ready*)
    method Bool mv_fbhead_valid;
    method ActionValue#(Bit#(TLog#(fbsize))) mav_allocate_line( 
                                    Bool                                      from_ram,
                                    Bit#(TMul#(TMul#(wordsize,8),blocksize))  dataline,
                                    Bit#(paddr)                               address,
                                    Bit#(1)                                   dirty );

    method Action ma_fill_from_memory(DCache_mem_readresp#(respwidth) mem_resp,
                                      Bit#(TLog#(fbsize))             fbindex,
                                      Bit#(TLog#(banks))              init_bank);

    method Action ma_from_storebuffer(Bit#(respwidth) mask, Bit#(respwidth)  dataword,
                                      Bit#(TLog#(fbsize)) fbindex, Bit#(paddr) address);

    method ReleaseInfo#(TMul#(blocksize,TMul#(wordsize,8)), paddr) mv_release_info;
    method Action ma_perform_release;
    method ActionValue#(PollingResponse#(wordsize,fbsize)) mav_polling_response(
      Bit#(paddr) address, Bool fill, Bit#(TLog#(fbsize)) fbindex); 

  endinterface

  (*conflict_free="ma_perform_release,mav_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, mav_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, ma_perform_release"*)
  (*conflict_free="mav_allocate_line, ma_from_storebuffer"*)
  (*conflict_free="ma_fill_from_memory, ma_from_storebuffer"*)
  module mk_fillbuffer_v2#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_fillbuffer_v2#(fbsize, wordsize, blocksize, sets, banks, paddr, respwidth))
      provisos(
          Mul#(TMul#(wordsize,8),blocksize,linewidth),
          Log#(wordsize, wordbits),
          Log#(blocksize, blockbits),
          Log#(sets, setbits),
          Mul#(wordsize,8, respwidth),
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr),     // tagbits = 32-(wordbits+blockbits+setbits)
          
          // required by bsc
          Add#(a__, TLog#(TMul#(blocksize, wordsize)), TAdd#(TLog#(TMul#(wordsize,
    blocksize)), 1)),
          Mul#(blocksize, wordsize, TDiv#(linewidth, 8)),
          Mul#(respwidth, b__, linewidth),
          Add#(c__, respwidth, linewidth),
          Add#(d__, blockbits, paddr),
          Add#(TAdd#(tagbits, setbits), e__, paddr)
          );

    let v_wordsize = valueOf(wordsize);
    let v_blocksize = valueOf(blocksize);
    let v_sets = valueOf(sets);
    let v_banks = valueOf(banks);
    let v_wordbits = valueOf(wordbits);
    let v_blockbits = valueOf(blockbits);
    let v_fbsize = valueOf(fbsize);
    let v_respwidth = valueOf(respwidth);

    Integer lv_offset = case(valueOf(respwidth)) 32: 4;      64: 8;      128: 16;   endcase;
    function Bool isTrue(Bool a);
      return a;
    endfunction

    /*doc:func: This function generates the byte-enable for a data-line sized vector based on the
    request made by the core */
    function Bit#(banks) fn_enable (Bit#(blockbits) blockindex);
      Bit#(banks) lv_temp = '1;
      return lv_temp << blockindex;
    endfunction

    /*doc: vec: vector of registers to maintain the valid bit for fill-buffers*/
    Vector#(fbsize,Reg#(Bool))                      v_fb_addr_valid    <- replicateM(mkReg(False));
    /*doc: vec: vector of registers to hold the dataline for fill-buffers.*/
    //Vector#(fbsize,Reg#(Bit#(linewidth)))           v_fb_data     <- replicateM(mkReg(unpack(0)));
    Vector#(fbsize,Vector#(banks,ConfigReg#(Bit#(respwidth))))    v_fb_data     
                                                    <- replicateM(replicateM(mkConfigReg(unpack(0))));
    /*doc: vec: vector of registers to indicate that the line fill faced a bus-error*/
    Vector#(fbsize,ConfigReg#(Bit#(1)))                   v_fb_err      <- replicateM(mkConfigReg(0));
    /*doc: vec: vector of registers to indicate that the line in the fill-buffer is dirty*/
    Vector#(fbsize,Reg#(Bit#(1)))                   v_fb_dirty    <- replicateM(mkReg(0));
    /*doc: vec: vector of regisetrs to indicate if the entire line of the fillbuffer entry is
     * available or not*/
    Vector#(fbsize,ConfigReg#(Bool))                   v_fb_line_valid  <- replicateM(mkConfigReg(False));
    /*doc: reg: register to indicate how many bytes of the line have been filled by the
     bus*/
    Reg#(Bit#(banks))                  rg_fb_enables    <- mkReg(0);
    /*doc: vec: vector registers indicating the address of the fill-buffer line*/
    Vector#(fbsize,Reg#(Bit#(paddr)))               v_fb_addr     <- replicateM(mkReg(0));

    /*doc:reg: register pointing to the next entry being released from the fillbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbhead     <- mkReg(0);
    /*doc:reg: register pointing to next entry being allotted on the filbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbtail     <- mkReg(0);
    /*doc:reg: temporary register holding the WE for the data to be updated in the fillbuffer from
    the memory response*/
    Reg#(Bit#(TLog#(banks)))           rg_next_bank<- mkReg(0);

    
    /*doc:var: variable indicating the fillbuffer is full*/
    Bool fb_full = (all(isTrue, readVReg(v_fb_addr_valid)));
    /*doc:var: variable indicating the fillbuffer is empty*/
    Bool fb_empty=!(any(isTrue, readVReg(v_fb_addr_valid)));
    rule rl_print_stats;
      `logLevel( dcache, 3, $format("[%2d]DCACHE: fb_full:%b fb_empty:%b fbhead:%d fbtail:%d\
 fbheadvalid:%b", id, fb_full, fb_empty, rg_fbhead, rg_fbtail, v_fb_line_valid[rg_fbhead]))
    endrule

    method mv_fbfull = fb_full;
    method mv_fbempty = fb_empty;
    method mv_fbhead_valid = v_fb_line_valid[rg_fbhead];
    method ActionValue#(Bit#(TLog#(fbsize))) mav_allocate_line( 
                                    Bool                                      from_ram,
                                    Bit#(TMul#(TMul#(wordsize,8),blocksize))  dataline,
                                    Bit#(paddr)                               address,
                                    Bit#(1)                                   dirty );

      Bit#(1) _temp = pack(from_ram);
      v_fb_addr_valid[rg_fbtail] <= True;
      v_fb_addr[rg_fbtail] <= address;
      v_fb_dirty[rg_fbtail] <= _temp & dirty;
      v_fb_line_valid[rg_fbtail] <= from_ram;
      v_fb_err[rg_fbtail] <= 0;
      for (Integer i = 0; i< v_banks ; i = i + 1) begin
        v_fb_data[rg_fbtail][i] <= dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth];
      end
      if(rg_fbtail == fromInteger(v_fbsize -1))
        rg_fbtail <= 0;
      else
        rg_fbtail <= rg_fbtail + 1;
      `logLevel( dcache, 0, $format("[%2d]DCACHE: FB: Allocating: fromram:%b address:%h dirty:%b",
                                        id, from_ram, address, dirty))
      `logLevel( dcache, 0, $format("[%2d]DCACHE: FB: Allocating fbindex:%d", id, rg_fbtail))
      return rg_fbtail;
    endmethod
    method Action ma_fill_from_memory(DCache_mem_readresp#(respwidth) mem_resp,
                                      Bit#(TLog#(fbsize))             fbindex,
                                      Bit#(TLog#(banks))              init_bank);
      Bit#(TLog#(banks)) lv_current_bank = rg_fb_enables == 0? init_bank: rg_next_bank;
      v_fb_data[fbindex][lv_current_bank] <= mem_resp.data;
      rg_next_bank <= lv_current_bank + 1;
      if(mem_resp.last) begin
        v_fb_line_valid[fbindex] <= True;
        rg_fb_enables <= 0;
      end
      else
        rg_fb_enables[lv_current_bank] <= 1;
      v_fb_err[fbindex] <= pack(mem_resp.err);
      `logLevel(dcache , 0, $format("[%2d]DCACHE: FB Fill: fbindex:%d ibank:%d cbank:%d fben:%b", id,
      fbindex, init_bank, lv_current_bank, rg_fb_enables))
    endmethod
    method Action ma_from_storebuffer(Bit#(respwidth) mask, Bit#(respwidth)  dataword,
                                      Bit#(TLog#(fbsize)) fbindex, Bit#(paddr) address);

      Bit#(blockbits) block_offset = {address[v_blockbits+v_wordbits-1:v_wordbits]};
      v_fb_data[fbindex][block_offset] <= (v_fb_data[fbindex][block_offset]& ~mask) |
                                         (mask & dataword);
      v_fb_dirty[fbindex] <= 1;
    endmethod
    method ReleaseInfo#(TMul#(blocksize,TMul#(wordsize,8)), paddr) mv_release_info;
      Bit#(linewidth) lv_dataline=?;
      for (Integer i = 0; i<v_banks; i = i + 1) begin
        lv_dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth] = v_fb_data[rg_fbhead][i];
      end
      return ReleaseInfo{dataline:lv_dataline, err:v_fb_err[rg_fbhead],
                          dirty:v_fb_dirty[rg_fbhead], address: v_fb_addr[rg_fbhead]};
    endmethod

    method Action ma_perform_release;
      if(rg_fbhead == fromInteger(v_fbsize -1))
        rg_fbhead <= 0;
      else
        rg_fbhead <= rg_fbhead + 1;
      v_fb_addr_valid[rg_fbhead] <= False;
      v_fb_line_valid[rg_fbhead] <= False;
    endmethod

    method ActionValue#(PollingResponse#(wordsize,fbsize)) mav_polling_response(
      Bit#(paddr) address, Bool fill, Bit#(TLog#(fbsize)) fbindex); 

      Bit#(TAdd#(tagbits, setbits)) input_tag = truncateLSB(address);

      Bit#(blockbits) word_index = truncate(address >> v_wordbits);
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(blockbits) block_offset = {address[v_blockbits+v_wordbits-1:v_wordbits]};
      Bit#(fbsize) lv_hitvector = 0; 
      Bit#(respwidth) lv_selected_word = ?;
      Bit#(1) lv_err = ?;
      Bool lv_linevalid = False;
      for (Integer i = 0; i<v_fbsize; i = i + 1) begin
        lv_hitvector[i] = pack((truncateLSB(v_fb_addr[i]) == input_tag) && v_fb_addr_valid[i]);
      end
      if (onehot) begin
        Vector#(fbsize, Bit#(respwidth)) lv_words = ?;
        for (Integer i = 0; i< v_fbsize; i = i + 1) begin
          lv_words[i] = truncate(v_fb_data[i][block_offset]);
        end
        lv_selected_word = select(lv_words,unpack(lv_hitvector));
        lv_err = select(readVReg(v_fb_err), unpack(lv_hitvector));
        lv_linevalid = select(readVReg(v_fb_line_valid), unpack(lv_hitvector));
      end
      else begin
        for (Integer i = 0; i<v_fbsize; i = i + 1) begin
          if (lv_hitvector[i] == 1) begin
            lv_selected_word = truncate(v_fb_data[i][block_offset]);
            lv_err = v_fb_err[i];
            lv_linevalid = v_fb_line_valid[i];
          end
        end
      end
      Bool lv_hit_in_fill = fill && lv_hitvector[fbindex] == 1 &&
                            (rg_fb_enables[block_offset] == 1);
      `logLevel( dcache, 0, $format("[%2d]DCACHE: FB: Polling: linevalid:%b blockoffset:%d",id,
                                    lv_linevalid, block_offset))
      Bool lv_wordhit = (lv_linevalid || lv_hit_in_fill);
      return PollingResponse{err: lv_err, word:lv_selected_word, waymask: lv_hitvector,
                             line_hit: unpack(|lv_hitvector), word_hit: lv_wordhit};
    endmethod
  endmodule
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
      Bit#(3) zeros = 0;
      Bit#(TAdd#(wordbits,3)) shiftamt = {phyaddr[v_wordbits - 1:0], zeros};
  
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
      Bit#(3) zeros = 0;
      Bit#(TAdd#(wordbits,3)) shiftamt = {address[v_wordbits - 1:0], zeros};
      Bit#(dataword) temp =  size == 0?'hff:
                             size == 1?'hffff:
                             size == 2?'hffffffff : '1;

      Bit#(dataword) storemask = temp << shiftamt;
      v_sb_valid[rg_tail] <= True;
      let _s = Storebuffer{addr:address, data: data, epoch: epochs, fbindex: fbindex,
                                      io: io, mask: storemask, size:truncate(size)};
      v_sb_meta[rg_tail] <= _s;
      rg_tail <= rg_tail + 1;
      `logLevel( storebuffer, 0, $format("[%2d]SB: Allocating sbindex:%d with ",id,rg_tail,
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
    method mv_cacheable_store = !v_sb_meta[rg_head].io;
  endmodule
      

  (*synthesize*)
  module mkinst_tag#(parameter Bit#(32) id)(Ifc_tagram#(`dwords, `dblocks, `dsets, `dways, `paddr));
    let ifc();
    mk_tagram1rw _temp(id,ifc);
    return (ifc);
  endmodule
  (*synthesize*)
  module mkinst_data#(parameter Bit#(32) id)(Ifc_dataram#(`dwords, `dblocks, `dsets, `dways, `ddbanks));
    let ifc();
    mk_dataram1rw#(id,unpack(`dcache_onehot)) _temp(ifc);
    return (ifc);
  endmodule
//  (*synthesize*)
//  module mkinst_fb#(parameter Bit#(32) id)(Ifc_fillbuffer#(`dfbsize, `dwords, `dblocks, `dsets, `ddbanks, `paddr, `dbuswidth));
//    let ifc();
//    mk_fillbuffer#(id,False) _temp(ifc);
//    return (ifc);
//  endmodule
  (*synthesize*)
  module mkinst_fb_v2#(parameter Bit#(32) id)(Ifc_fillbuffer_v2#(`dfbsize, `dwords, `dblocks, `dsets, `ddbanks, `paddr,  `dbuswidth));
    let ifc();
    mk_fillbuffer_v2#(id,unpack(`dcache_onehot)) _temp(ifc);
    return (ifc);
  endmodule

  /* (*synthesize*)
  module mkinst_sb#(parameter Bit#(32) id)(Ifc_storebuffer#(`paddr, `dwords, `desize, `dsbsize, `dfbsize));
    let ifc();
    mk_storebuffer#(id) _temp(ifc);
    return (ifc);
  endmodule */


endpackage

