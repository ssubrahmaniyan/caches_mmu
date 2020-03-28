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
package icache_lib;
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
  import ecc_hamming :: * ;

  import mem_config :: * ;
  import icache_types :: * ;

  typedef struct{
  `ifdef icache_ecc
    Bit#(ways) sed;
    Bit#(ways) ded;
  `endif
    Bit#(ways)    waymask;
    Bit#(a)       address;
  } TagResponse#(numeric type ways, numeric type a) deriving(Bits, Eq, FShow);

  typedef struct{
  `ifdef icache_ecc
    Bit#(b) line_sed;
    Bit#(b) line_ded;
    Bit#(1) word_sed;
    Bit#(1) word_ded;
    Bit#(TMul#(b,TAdd#(2,TLog#(TMul#(8,w))))) stored_parity;
    Bit#(TMul#(b,TAdd#(2,TLog#(TMul#(8,w))))) check_parity;
  `endif
    Bit#(TMul#(TMul#(w,8),b)) line;
    Bit#(TMul#(8,w)) word;
  } DataResponse#(numeric type b, numeric type w) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(l) dataline;
    Bit#(a) address;
    Bit#(1) err;
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
  `ifdef icache_ecc
    method Bit#(paddr) mv_sideband_read (Bit#(TLog#(ways)) way);
  `endif
  endinterface

  module mk_tagram1rw#(parameter Bit#(32) id)(Ifc_tagram#(wordsize, blocksize, sets, ways, paddr))
    provisos(
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr)     // tagbits = 32-(wordbits+blockbits+setbits)
        `ifdef icache_ecc
          // for ecc
          ,Add#(maxsize, 0,TExp#(TLog#(tagbits))),
          // required by bsc
          Add#(TLog#(tagbits), a__, 6),
          Add#(b__, tagbits, 64),
          Add#(c__, TAdd#(2, TLog#(tagbits)), TMul#(1, TAdd#(2, TLog#(tagbits)))),
          Log#(TDiv#(tagbits, 1), TLog#(tagbits)),
          Add#(d__, tagbits, TExp#(TLog#(tagbits)))
        `endif
    );

    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);

    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
  `ifdef icache_ecc
    Vector#(ways, Ifc_mem_config1rw_ecc#(sets, tagbits, 1)) v_tags <-
                                                        replicateM(mkmem_config1rw_ecc(False));
  `else
    Vector#(ways, Ifc_mem_config1rw#(sets, tagbits, 1)) v_tags <-
                                                        replicateM(mkmem_config1rw(False));
  `endif
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
      `logLevel( icache, 0, $format("[%2d]ICACHE: TagReq: Tag:%h RW:%b Way:%d index:%d",id,tag,
      read_write, way, index))
    endmethod

    method TagResponse#(ways, paddr) mv_read_response(Bit#(paddr) address_in,
                                               Bit#(TLog#(ways)) wayselect );

      Bit#(tagbits) tag_in = truncateLSB(address_in);
      Bit#(ways) lv_hitvector = 0;
    `ifdef icache_ecc
      Bit#(ways) sed = 0;
      Bit#(ways) ded = 0;
      Vector#(ways,Bit#(TAdd#(2,TLog#(tagbits)))) lv_chparity;
      Vector#(ways,Bit#(TAdd#(2,TLog#(tagbits)))) lv_stparity;
    `endif
      Vector#(ways, Bit#(tagbits)) lv_tags;
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_tags[i] = v_tags[i].read_response;
      `ifdef icache_ecc
        sed[i] = v_tags[i].read_sed;
        ded[i] = v_tags[i].read_ded;
        lv_chparity[i] = v_tags[i].check_parity;
        lv_stparity[i] = v_tags[i].stored_parity;
      `endif
      end
//    `ifdef icache_ecc
//      for (Integer i = 0; i< v_ways; i = i + 1) begin
//        Bit#(maxsize) _t = zeroExtend(lv_tags[i]);
//        lv_tags[i] = truncate(fn_ecc_correct(lv_chparity[i], lv_stparity[i], _t));
//      end
//    `endif
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_hitvector[i] = pack(truncate(lv_tags[i]) == tag_in);
      end
      Bit#(paddr)  lv_tag = {lv_tags[wayselect],'d0};
      return TagResponse{`ifdef icache_ecc sed: sed, ded: ded, `endif waymask: lv_hitvector, address: lv_tag };
    endmethod
  `ifdef icache_ecc
    method Bit#(paddr) mv_sideband_read (Bit#(TLog#(ways)) way);
      return zeroExtend(v_tags[way].read_response);
    endmethod
  `endif
  endmodule


  interface Ifc_dataram#(numeric type wordsize,
                         numeric type blocksize,
                         numeric type sets,
                         numeric type ways);
    /*doc:method: request method to initiate a read or write on the dataline. A read is latched on all
    * ways. A write is peformed only on a single way.*/
    method Action ma_request( Bool read_write,
                              Bit#(TLog#(sets)) index,
                              Bit#(TMul#(TMul#(wordsize, 8),blocksize)) dataline,
                              Bit#(TLog#(ways)) way,
                              Bit#(blocksize) banks);

    /*doc:method: This method will read the ram output from all ways. Compare with the input tag.
     * and respond with a hit-vector indicating which way was a hit. Also responds if there was a
     * single-error or double-error detected while performing the read across all the ways. */
    method DataResponse#(blocksize,wordsize) mv_read_response(
                                              Bit#(TLog#(blocksize)) blocknum,
                                              Bit#(ways) wayselect );
  `ifdef icache_ecc
    method Bit#(TMul#(wordsize, 8)) mv_sideband_read (Bit#(TLog#(ways)) way, Bit#(TLog#(blocksize)) bank);
  `endif
  endinterface

  module mk_dataram1rw#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_dataram#(wordsize, blocksize, sets, ways))
      provisos(
          Mul#(TMul#(wordsize,8),blocksize,linewidth),
          Log#(wordsize, wordbits),
          Log#(blocksize, blockbits),
          Log#(sets, setbits),
          Mul#(wordsize,8, respwidth),

          // required by bsc
          Add#(a__, respwidth, linewidth), // since the response is truncated version of line
          Mul#(TDiv#(linewidth, blocksize), blocksize, linewidth), // from mem_config
          Add#(a__, TDiv#(linewidth, blocksize), linewidth), // from mem_config
          Add#(f__, TMul#(wordsize, 8), linewidth)

        `ifdef icache_ecc
          ,Add#(b__, 2, TMul#(2, blocksize)),
          Add#(TLog#(TDiv#(linewidth, blocksize)), c__, 6),
          Add#(d__, TDiv#(linewidth, blocksize), 64),
          Add#(e__, TAdd#(2, TLog#(TDiv#(linewidth, blocksize))), TMul#(blocksize,
                                                    TAdd#(2, TLog#(TDiv#(linewidth, blocksize)))))
        `endif
      );
    let v_wordsize = valueOf(wordsize);
    let v_blocksize = valueOf(blocksize);
    let v_sets = valueOf(sets);
    let v_ways = valueOf(ways);
  `ifdef icache_ecc
    Vector#(ways, Ifc_mem_config1rw_ecc#(sets, linewidth, blocksize)) v_data
                                                      <- replicateM(mkmem_config1rw_ecc(False));
  `else
    Vector#(ways, Ifc_mem_config1rw#(sets, linewidth, blocksize)) v_data
                                                      <- replicateM(mkmem_config1rw(False));
  `endif
    method Action ma_request( Bool read_write,
                              Bit#(TLog#(sets)) index,
                              Bit#(linewidth) dataline,
                              Bit#(TLog#(ways)) way,
                              Bit#(blocksize) banks);

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
    `ifdef icache_ecc
      Bit#(blocksize) lv_line_ded = 0;
      Bit#(blocksize) lv_line_sed = 0;
      Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) lv_stored_parity=?;
      Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) lv_check_parity=?;
    `endif
      if (onehot) begin
        Vector#(ways, Bit#(respwidth)) lv_words = ?;
        Vector#(ways, Bit#(linewidth)) lv_lines = ?;
      `ifdef icache_ecc
        Vector#(ways, Bit#(blocksize))     lv_lines_sed = ?;
        Vector#(ways, Bit#(blocksize))     lv_lines_ded = ?;
        Vector#(ways, Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize)))))) lv_stparity;
        Vector#(ways, Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize)))))) lv_chparity;
      `endif
        for (Integer i = 0; i< v_ways ; i = i + 1) begin
          lv_words[i] = truncate(v_data[i].read_response >> block_offset);
          lv_lines[i] = v_data[i].read_response;
        `ifdef icache_ecc
          lv_lines_sed[i] = v_data[i].read_sed;
          lv_lines_ded[i] = v_data[i].read_ded;
          lv_stparity[i] = v_data[i].stored_parity;
          lv_chparity[i] = v_data[i].check_parity;
        `endif
        end
        lv_selected_word = select(lv_words,unpack(wayselect));
        lv_selected_line = select(lv_lines,unpack(wayselect));
      `ifdef icache_ecc
        lv_line_sed = select(lv_lines_sed,unpack(wayselect));
        lv_line_ded = select(lv_lines_ded,unpack(wayselect));
        lv_stored_parity = select(lv_stparity, unpack(wayselect));
        lv_check_parity = select(lv_chparity, unpack(wayselect));
      `endif
      end
      else begin
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          if (wayselect[i] == 1) begin
            lv_selected_line = v_data[i].read_response;
            lv_selected_word = truncate(lv_selected_line>> block_offset);
          `ifdef icache_ecc
            lv_line_sed = v_data[i].read_sed;
            lv_line_ded = v_data[i].read_ded;
            lv_stored_parity = v_data[i].stored_parity;
            lv_check_parity = v_data[i].check_parity;
          `endif
          end
        end
      end
      Bit#(1) lv_word_ded = `ifdef icache_ecc lv_line_ded[blocknum] `else 0 `endif ;
      Bit#(1) lv_word_sed = `ifdef icache_ecc lv_line_sed[blocknum] `else 0 `endif ;

      return DataResponse{`ifdef icache_ecc 
                            word_sed: lv_word_sed, word_ded:lv_word_ded,  
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
                            stored_parity: lv_stored_parity, check_parity: lv_check_parity,
                          `endif line: lv_selected_line, word: lv_selected_word};

    endmethod
  `ifdef icache_ecc
    method Bit#(TMul#(wordsize, 8)) mv_sideband_read (Bit#(TLog#(ways)) way, Bit#(TLog#(blocksize)) bank);
      Bit#(linewidth) _line = v_data[way].read_response;
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth),blockbits))  block_offset = {bank,zeros};
      return truncate(_line>> block_offset);
    endmethod
  `endif
  endmodule


  // where buswidth = respwidth and banksize = respwidth
  interface Ifc_fillbuffer_v2#(numeric type fbsize,
                            numeric type wordsize,
                            numeric type blocksize,
                            numeric type sets,
                            numeric type paddr,
                            numeric type buswidth);
    (*always_ready*)
    method Bool mv_fbfull ;
    (*always_ready*)
    method Bool mv_fbempty ;
    (*always_ready*)
    method Bool mv_fbhead_valid;
    method ActionValue#(Bit#(TLog#(fbsize))) mav_allocate_line(
                                    Bool                                      from_ram,
                                    Bit#(TMul#(TMul#(wordsize,8),blocksize))  dataline,
                                    Bit#(paddr)                               address);

    method Action ma_fill_from_memory(ICache_mem_readresp#(buswidth) mem_resp,
                                      Bit#(TLog#(fbsize))             fbindex,
                                      Bit#(TLog#(blocksize))          init_bank);

    method ReleaseInfo#(TMul#(blocksize,TMul#(wordsize,8)), paddr) mv_release_info;
    method Action ma_perform_release;
    method ActionValue#(PollingResponse#(wordsize,fbsize)) mav_polling_response(
      Bit#(paddr) address, Bool fill, Bit#(TLog#(fbsize)) fbindex);
  `ifdef icache_ecc
    method Action mav_perform_sec (Bit#(TLog#(fbsize)) fbindex,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) stored_parity,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) check_parity);
  `endif
  endinterface

  (*conflict_free="ma_perform_release,mav_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, mav_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, ma_perform_release"*)
`ifdef icache_ecc
  (*conflict_free="ma_fill_from_memory, mav_perform_sec"*)
  (*mutually_exclusive="mav_allocate_line, mav_perform_sec"*)
`endif
  module mk_fillbuffer_v2#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_fillbuffer_v2#(fbsize, wordsize, blocksize, sets, paddr, buswidth))
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
          Add#(a__, blockbits, paddr),
          Add#(b__, respwidth, buswidth),
          Add#(TAdd#(tagbits, setbits), c__, paddr),
          Add#(d__, respwidth, linewidth)

        `ifdef icache_ecc
          , Add#(2, TLog#(TMul#(8,wordsize)), ecc_size)
        `endif
          );

    let v_wordsize = valueOf(wordsize);
    let v_blocksize = valueOf(blocksize);
    let v_sets = valueOf(sets);
    let v_banks = valueOf(blocksize);
    let v_wordbits = valueOf(wordbits);
    let v_blockbits = valueOf(blockbits);
    let v_fbsize = valueOf(fbsize);
    let v_respwidth = valueOf(respwidth);
    let v_buswidth = valueOf(buswidth);
  `ifdef icache_ecc
    let v_ecc_size = valueOf(ecc_size);
  `endif

    Integer lv_offset = case(valueOf(respwidth)) 32: 4;      64: 8;      128: 16;   endcase;
    function Bool isTrue(Bool a);
      return a;
    endfunction

    /*doc:func: This function generates the byte-enable for a data-line sized vector based on the
    request made by the core */
    function Bit#(blocksize) fn_enable (Bit#(blockbits) blockindex);
      Bit#(blocksize) lv_temp = '1;
      return lv_temp << blockindex;
    endfunction

    /*doc: vec: vector of registers to maintain the valid bit for fill-buffers*/
    Vector#(fbsize,Reg#(Bool))                      v_fb_addr_valid    <- replicateM(mkReg(False));
    /*doc: vec: vector of registers to hold the dataline for fill-buffers.*/
    //Vector#(fbsize,Reg#(Bit#(linewidth)))           v_fb_data     <- replicateM(mkReg(unpack(0)));
    Vector#(fbsize,Vector#(blocksize,ConfigReg#(Bit#(respwidth))))    v_fb_data
                                                    <- replicateM(replicateM(mkConfigReg(unpack(0))));
    /*doc: vec: vector of registers to indicate that the line fill faced a bus-error*/
    Vector#(fbsize,ConfigReg#(Bit#(1)))                   v_fb_err      <- replicateM(mkConfigReg(0));
    /*doc: vec: vector of regisetrs to indicate if the entire line of the fillbuffer entry is
     * available or not*/
    Vector#(fbsize,ConfigReg#(Bool))                   v_fb_line_valid  <- replicateM(mkConfigReg(False));
    /*doc: reg: register to indicate how many bytes of the line have been filled by the
     bus*/
    Reg#(Bit#(blocksize))                  rg_fb_enables    <- mkReg(0);
    /*doc: vec: vector registers indicating the address of the fill-buffer line*/
    Vector#(fbsize,Reg#(Bit#(paddr)))               v_fb_addr     <- replicateM(mkReg(0));

    /*doc:reg: register pointing to the next entry being released from the fillbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbhead     <- mkReg(0);
    /*doc:reg: register pointing to next entry being allotted on the filbuffer*/
    Reg#(Bit#(TLog#(fbsize)))                       rg_fbtail     <- mkReg(0);
    /*doc:reg: temporary register holding the WE for the data to be updated in the fillbuffer from
    the memory response*/
    Reg#(Bit#(TLog#(blocksize)))           rg_next_bank<- mkReg(0);


    /*doc:var: variable indicating the fillbuffer is full*/
    Bool fb_full = (all(isTrue, readVReg(v_fb_addr_valid)));
    /*doc:var: variable indicating the fillbuffer is empty*/
    Bool fb_empty=!(any(isTrue, readVReg(v_fb_addr_valid)));
    rule rl_print_stats;
      `logLevel( icache, 3, $format("[%2d]ICACHE: fb_full:%b fb_empty:%b fbhead:%d fbtail:%d\
 fbheadvalid:%b", id, fb_full, fb_empty, rg_fbhead, rg_fbtail, v_fb_line_valid[rg_fbhead]))
    endrule

    method mv_fbfull = fb_full;
    method mv_fbempty = fb_empty;
    method mv_fbhead_valid = v_fb_line_valid[rg_fbhead];
    method ActionValue#(Bit#(TLog#(fbsize))) mav_allocate_line(
                                    Bool                                      from_ram,
                                    Bit#(TMul#(TMul#(wordsize,8),blocksize))  dataline,
                                    Bit#(paddr)                               address );

      v_fb_addr_valid[rg_fbtail] <= True;
      v_fb_addr[rg_fbtail] <= address;
      v_fb_line_valid[rg_fbtail] <= from_ram;
      v_fb_err[rg_fbtail] <= 0;
      for (Integer i = 0; i< v_banks ; i = i + 1) begin
        v_fb_data[rg_fbtail][i] <= dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth];
      end
      if(rg_fbtail == fromInteger(v_fbsize -1))
        rg_fbtail <= 0;
      else
        rg_fbtail <= rg_fbtail + 1;
      `logLevel( icache, 0, $format("[%2d]ICACHE: FB: Allocating: fromram:%b address:%h ",
                                        id, from_ram, address))
      `logLevel( icache, 0, $format("[%2d]ICACHE: FB: Allocating fbindex:%d", id, rg_fbtail))
      return rg_fbtail;
    endmethod
    method Action ma_fill_from_memory(ICache_mem_readresp#(buswidth) mem_resp,
                                      Bit#(TLog#(fbsize))             fbindex,
                                      Bit#(TLog#(blocksize))          init_bank);
      Bit#(TLog#(blocksize)) lv_current_bank = rg_fb_enables == 0? init_bank: rg_next_bank;
      let banks_per_response = v_buswidth / v_respwidth;
      Bit#(buswidth) _data = mem_resp.data;
      Bit#(blocksize) _enables = rg_fb_enables;
      for (Integer i = 0; i< (v_buswidth/v_respwidth) ; i = i + 1) begin
        v_fb_data[fbindex][lv_current_bank + fromInteger(i)] <= truncate(_data);
        _data = _data >> v_respwidth;
        _enables [lv_current_bank + fromInteger(i)] = 1;
      end
      rg_next_bank <= lv_current_bank + fromInteger(banks_per_response);
      if(mem_resp.last) begin
        v_fb_line_valid[fbindex] <= True;
        rg_fb_enables <= 0;
      end
      else
        rg_fb_enables <= _enables;
      v_fb_err[fbindex] <= pack(mem_resp.err);
      `logLevel(icache , 0, $format("[%2d]ICACHE: FB Fill: fbindex:%d ibank:%d cbank:%d fben:%b", id,
      fbindex, init_bank, lv_current_bank, rg_fb_enables))
    endmethod
    method ReleaseInfo#(TMul#(blocksize,TMul#(wordsize,8)), paddr) mv_release_info;
      Bit#(linewidth) lv_dataline=?;
      for (Integer i = 0; i<v_banks; i = i + 1) begin
        lv_dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth] = v_fb_data[rg_fbhead][i];
      end
      return ReleaseInfo{dataline:lv_dataline, err:v_fb_err[rg_fbhead],
                          address: v_fb_addr[rg_fbhead]};
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
      `logLevel( icache, 0, $format("[%2d]ICACHE: FB: Polling: linevalid:%b blockoffset:%d",id,
                                    lv_linevalid, block_offset))
      Bool lv_wordhit = (lv_linevalid || lv_hit_in_fill);
      return PollingResponse{err: lv_err, word:lv_selected_word, waymask: lv_hitvector,
                             line_hit: unpack(|lv_hitvector), word_hit: lv_wordhit};
    endmethod
  `ifdef icache_ecc
    method Action mav_perform_sec (Bit#(TLog#(fbsize)) fbindex,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) stored_parity,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) check_parity);

      for (Integer i = 0; i< v_banks; i = i + 1) begin
        Bit#(ecc_size) _stparity = stored_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
        Bit#(ecc_size) _chparity = check_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
        let _data = fn_ecc_correct(_chparity, _stparity, v_fb_data[fbindex][i]);
        v_fb_data[fbindex][i] <= _data;
      end
    endmethod
  `endif
  endmodule
  (*synthesize*)
  module mkinst_tag#(parameter Bit#(32) id)(Ifc_tagram#(`iwords, `iblocks, `isets, `iways, `paddr));
    let ifc();
    mk_tagram1rw _temp(id,ifc);
    return (ifc);
  endmodule
  (*synthesize*)
  module mkinst_data#(parameter Bit#(32) id)(Ifc_dataram#(`iwords, `iblocks, `isets, `iways));
    let ifc();
    mk_dataram1rw#(id,unpack(`icache_onehot)) _temp(ifc);
    return (ifc);
  endmodule
  (*synthesize*)
  module mkinst_fb_v2#(parameter Bit#(32) id)(Ifc_fillbuffer_v2#(`ifbsize, `iwords, `iblocks, `isets, `paddr,  `ibuswidth));
    let ifc();
    mk_fillbuffer_v2#(id,unpack(`icache_onehot)) _temp(ifc);
    return (ifc);
  endmodule

endpackage

