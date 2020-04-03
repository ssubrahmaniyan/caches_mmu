/* 
see LICENSE.incore
see LICENSE.iitm

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
  import ecc_hamming :: * ;

  import mem_config :: * ;
  import dcache_types :: * ;

  typedef struct{
  `ifdef dcache_ecc
    Bit#(ways) sed;
    Bit#(ways) ded;
  `endif
    Bit#(ways)    waymask;
    Bit#(a)       address;
  } TagResponse#(numeric type ways, numeric type a) deriving(Bits, Eq, FShow);

  typedef struct{
  `ifdef dcache_ecc
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
    Bit#(1) dirty;
  } ReleaseInfo#(numeric type l, numeric type a) deriving(Bits, FShow, Eq);

  typedef struct{
    Bit#(1) err;
    Bit#(TMul#(w,8)) word;
    Bit#(f) waymask;
    Bool line_hit;
    Bool word_hit;
  } PollingResponse#(numeric type w, numeric type f) deriving(Bits, FShow, Eq);

  interface Ifc_tagram1rw#(numeric type wordsize,
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
  `ifdef dcache_ecc
    method Bit#(paddr) mv_sideband_read (Bit#(TLog#(ways)) way);
  `endif
  endinterface : Ifc_tagram1rw

  module mk_tagram1rw#(parameter Bit#(32) id)(Ifc_tagram1rw#(wordsize, blocksize, sets, ways, paddr))
    provisos(
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr)     // tagbits = 32-(wordbits+blockbits+setbits)
        `ifdef dcache_ecc
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
  `ifdef dcache_ecc
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
      `logLevel( dcache, 0, $format("[%2d]DCACHE: TagReq: Tag:%h RW:%b Way:%d index:%d",id,tag,
      read_write, way, index))
    endmethod

    method TagResponse#(ways, paddr) mv_read_response(Bit#(paddr) address_in,
                                               Bit#(TLog#(ways)) wayselect );

      Bit#(tagbits) tag_in = truncateLSB(address_in);
      Bit#(ways) lv_hitvector = 0;
    `ifdef dcache_ecc
      Bit#(ways) sed = 0;
      Bit#(ways) ded = 0;
      Vector#(ways,Bit#(TAdd#(2,TLog#(tagbits)))) lv_chparity;
      Vector#(ways,Bit#(TAdd#(2,TLog#(tagbits)))) lv_stparity;
    `endif
      Vector#(ways, Bit#(tagbits)) lv_tags;
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_tags[i] = v_tags[i].read_response;
      `ifdef dcache_ecc
        sed[i] = v_tags[i].read_sed;
        ded[i] = v_tags[i].read_ded;
        lv_chparity[i] = v_tags[i].check_parity;
        lv_stparity[i] = v_tags[i].stored_parity;
      `endif
      end
    `ifdef dcache_ecc
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        Bit#(maxsize) _t = zeroExtend(lv_tags[i]);
        lv_tags[i] = truncate(fn_ecc_correct(lv_chparity[i], lv_stparity[i], _t));
      end
    `endif
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_hitvector[i] = pack(truncate(lv_tags[i]) == tag_in);
      end
      Bit#(paddr)  lv_tag = {lv_tags[wayselect],'d0};
      return TagResponse{`ifdef dcache_ecc sed: sed, ded: ded, `endif waymask: lv_hitvector, address: lv_tag };
    endmethod
  `ifdef dcache_ecc
    method Bit#(paddr) mv_sideband_read (Bit#(TLog#(ways)) way);
      return zeroExtend(v_tags[way].read_response);
    endmethod
  `endif
  endmodule : mk_tagram1rw
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
    method ActionValue#(TagResponse#(ways, paddr)) mv_read_response_p1(Bit#(paddr) address_in, 
                                                         Bit#(TLog#(ways)) wayselect);
    method TagResponse#(ways, paddr) mv_read_response_p2(Bit#(TLog#(ways)) wayselect);    
  `ifdef dcache_ecc
    method Bit#(paddr) mv_sideband_read (Bit#(TLog#(ways)) way);
  `endif
  endinterface : Ifc_tagram2rw
  
  module mk_tagram2rw#(parameter Bit#(32) id)(Ifc_tagram2rw#(wordsize, blocksize, sets, ways, paddr))
    provisos(    
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr)     // tagbits = 32-(wordbits+blockbits+setbits)
        `ifdef dcache_ecc
          // for ecc
          ,Add#(maxsize, 0,TExp#(TLog#(tagbits))),
          // required by bsc
          Add#(TLog#(tagbits), a__, 6),
          Add#(b__, tagbits, 64),
          Add#(c__, TAdd#(2, TLog#(tagbits)), TMul#(1, TAdd#(2, TLog#(tagbits)))),
          Log#(TDiv#(tagbits, 1), TLog#(tagbits)),
          Add#(d__, tagbits, TExp#(TLog#(tagbits))),
          Add#(e__, TAdd#(2, TLog#(tagbits)), tagbits)
        `endif
    );
    
    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);

  `ifdef dcache_ecc
    Vector#(ways, Ifc_mem_config2rw_ecc#(sets, tagbits, 1)) v_tags <-
                                                       replicateM(mkmem_config2rw_ecc(False,True));
  `else
    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Vector#(ways, Ifc_mem_config2rw#(sets, tagbits, 1)) v_tags <-
                                                        replicateM(mkmem_config2rw(False,True));
  `endif
    method Action ma_read_p1(Bit#(TLog#(sets)) index);
      `logLevel( dcache, 0, $format("[%2d]DCACHE: TAGP1 Read:%d",id,index))
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        v_tags[i].p1.request(0,index,?, '1);
      end
    endmethod
    method Action ma_request_p2( Bool read_write, 
                                 Bit#(TLog#(sets)) index, 
                                 Bit#(paddr) address, 
                                 Bit#(TLog#(ways)) way);
      Bit#(tagbits) tag = truncateLSB(address);
      `logLevel( dcache, 0, $format("[%2d]DCACHE: TAGs: Req: rw:%b ind:%d tag:%h way:%d",
                                     id, read_write, index, tag, way))
      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_tags[i].p2.request(0, index, tag, '1);
        end
      else
        v_tags[way].p2.request(1, index, tag, '1);
    endmethod

    method ActionValue#(TagResponse#(ways, paddr)) mv_read_response_p1(Bit#(paddr) address_in, 
                                                         Bit#(TLog#(ways)) wayselect);

      Bit#(tagbits) tag_in = truncateLSB(address_in);
      Bit#(ways) lv_hitvector = 0;
    `ifdef dcache_ecc
      Bit#(ways) sed = 0;
      Bit#(ways) ded = 0;
      Vector#(ways,Bit#(TAdd#(2,TLog#(tagbits)))) lv_chparity;
      Vector#(ways,Bit#(TAdd#(2,TLog#(tagbits)))) lv_stparity;
    `endif
      Vector#(ways, Bit#(tagbits)) lv_tags;
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_tags[i] = v_tags[i].p1.read_response;
        let _t = v_tags[i].p1.read_response;
      `ifdef dcache_ecc
        sed[i] = v_tags[i].p1.read_sed;
        ded[i] = v_tags[i].p1.read_ded;
        lv_chparity[i] = v_tags[i].p1.check_parity;
        lv_stparity[i] = v_tags[i].p1.stored_parity;
      `endif
      end
    `ifdef dcache_ecc
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        Bit#(maxsize) _t = zeroExtend(lv_tags[i]);
        lv_tags[i] = truncate(fn_ecc_correct(lv_chparity[i], lv_stparity[i], _t));
      end
    `endif
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_hitvector[i] = pack(truncate(lv_tags[i]) == tag_in);
      end
      Bit#(paddr)  lv_tag = {v_tags[wayselect].p1.read_response,'d0};
      return TagResponse{`ifdef dcache_ecc sed: sed, ded: ded, `endif 
                          waymask: lv_hitvector, address: lv_tag};
    endmethod
  `ifdef dcache_ecc
    method Bit#(paddr) mv_sideband_read (Bit#(TLog#(ways)) way);
      return zeroExtend(v_tags[way].p2.read_response);
    endmethod
  `endif
    method TagResponse#(ways, paddr) mv_read_response_p2(Bit#(TLog#(ways)) wayselect );
      Bit#(tagbits)  lv_tag = v_tags[wayselect].p2.read_response;
    `ifdef dcache_ecc
      Bit#(ways) sed = 0;
      Bit#(ways) ded = 0;
      sed[wayselect] = v_tags[wayselect].p2.read_sed;
      ded[wayselect] = v_tags[wayselect].p2.read_ded;
      Bit#(TAdd#(2,TLog#(tagbits))) lv_chparity = v_tags[wayselect].p2.check_parity;
      Bit#(TAdd#(2,TLog#(tagbits))) lv_stparity = v_tags[wayselect].p2.stored_parity;
      Bit#(maxsize) _t = zeroExtend(lv_tag);
      lv_tag = truncate(fn_ecc_correct(lv_chparity, lv_stparity, _t));
    `endif
        Bit#(paddr) _t1 = {lv_tag, 'd0};
      return TagResponse{`ifdef dcache_ecc sed: sed, ded: ded, `endif waymask: 0, address: _t1 };
    endmethod
  endmodule : mk_tagram2rw


  interface Ifc_dataram1rw#(numeric type wordsize,
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
  `ifdef dcache_ecc
    method Bit#(TMul#(wordsize, 8)) mv_sideband_read (Bit#(TLog#(ways)) way, Bit#(TLog#(blocksize)) bank);
  `endif
  endinterface : Ifc_dataram1rw

  module mk_dataram1rw#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_dataram1rw#(wordsize, blocksize, sets, ways))
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

        `ifdef dcache_ecc
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
  `ifdef dcache_ecc
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
    `ifdef dcache_ecc
      Bit#(blocksize) lv_line_ded = 0;
      Bit#(blocksize) lv_line_sed = 0;
      Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) lv_stored_parity=?;
      Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) lv_check_parity=?;
    `endif
      if (onehot) begin
        Vector#(ways, Bit#(respwidth)) lv_words = ?;
        Vector#(ways, Bit#(linewidth)) lv_lines = ?;
      `ifdef dcache_ecc
        Vector#(ways, Bit#(blocksize))     lv_lines_sed = ?;
        Vector#(ways, Bit#(blocksize))     lv_lines_ded = ?;
        Vector#(ways, Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize)))))) lv_stparity;
        Vector#(ways, Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize)))))) lv_chparity;
      `endif
        for (Integer i = 0; i< v_ways ; i = i + 1) begin
          lv_words[i] = truncate(v_data[i].read_response >> block_offset);
          lv_lines[i] = v_data[i].read_response;
        `ifdef dcache_ecc
          lv_lines_sed[i] = v_data[i].read_sed;
          lv_lines_ded[i] = v_data[i].read_ded;
          lv_stparity[i] = v_data[i].stored_parity;
          lv_chparity[i] = v_data[i].check_parity;
        `endif
        end
        lv_selected_word = select(lv_words,unpack(wayselect));
        lv_selected_line = select(lv_lines,unpack(wayselect));
      `ifdef dcache_ecc
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
          `ifdef dcache_ecc
            lv_line_sed = v_data[i].read_sed;
            lv_line_ded = v_data[i].read_ded;
            lv_stored_parity = v_data[i].stored_parity;
            lv_check_parity = v_data[i].check_parity;
          `endif
          end
        end
      end
      Bit#(1) lv_word_ded = `ifdef dcache_ecc lv_line_ded[blocknum] `else 0 `endif ;
      Bit#(1) lv_word_sed = `ifdef dcache_ecc lv_line_sed[blocknum] `else 0 `endif ;

      return DataResponse{`ifdef dcache_ecc 
                            word_sed: lv_word_sed, word_ded:lv_word_ded,  
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
                            stored_parity: lv_stored_parity, check_parity: lv_check_parity,
                          `endif line: lv_selected_line, word: lv_selected_word};

    endmethod
  `ifdef dcache_ecc
    method Bit#(TMul#(wordsize, 8)) mv_sideband_read (Bit#(TLog#(ways)) way, Bit#(TLog#(blocksize)) bank);
      Bit#(linewidth) _line = v_data[way].read_response;
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth),blockbits))  block_offset = {bank,zeros};
      return truncate(_line>> block_offset);
    endmethod
  `endif
  endmodule : mk_dataram1rw

  interface Ifc_dataram2rw#(
                         numeric type wordsize,
                         numeric type blocksize,
                         numeric type sets,
                         numeric type ways);
    /*doc:method: request method to initiate a read or write on the dataline. A read is latched on all
    * ways. A write is peformed only on a single way.*/
    method Action ma_read_p1(Bit#(TLog#(sets)) index, Bit#(blocksize) banks);
    method Action ma_request_p2(
                              Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(TMul#(TMul#(wordsize, 8),blocksize)) dataline, 
                              Bit#(TLog#(ways)) way,
                              Bit#(blocksize) banks);

    /*doc:method: This method will read the ram output from all ways. Compare with the input tag.
     * and respond with a hit-vector indicating which way was a hit. Also responds if there was a
     * single-error or double-error detected while performing the read across all the ways. */
    method DataResponse#(blocksize,wordsize) mv_read_response_p1(
                                              Bit#(TLog#(blocksize)) blocknum, 
                                              Bit#(ways) wayselect );
    method DataResponse#(blocksize,wordsize) mv_read_response_p2(Bit#(ways) wayselect );
  `ifdef dcache_ecc
    method Bit#(TMul#(wordsize, 8)) mv_sideband_read (Bit#(TLog#(ways)) way, Bit#(TLog#(blocksize)) bank);
  `endif
  endinterface : Ifc_dataram2rw
  module mk_dataram2rw#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_dataram2rw#(wordsize, blocksize, sets, ways))
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
          // required by bsc
        `ifdef dcache_ecc
          ,Add#(b__, 2, TMul#(2, blocksize)),
          Add#(TLog#(TDiv#(linewidth, blocksize)), c__, 6),
          Add#(d__, TDiv#(linewidth, blocksize), 64),
          Add#(e__, TAdd#(2, TLog#(TDiv#(linewidth, blocksize))), TMul#(blocksize,
                                                    TAdd#(2, TLog#(TDiv#(linewidth, blocksize))))),
          Add#(g__, TAdd#(2, TLog#(TDiv#(linewidth, blocksize))), TDiv#(linewidth, blocksize))
        `endif
      );
    let v_wordsize = valueOf(wordsize);
    let v_blocksize = valueOf(blocksize);
    let v_sets = valueOf(sets);
    let v_ways = valueOf(ways);
  `ifdef dcache_ecc
    Vector#(ways, Ifc_mem_config2rw_ecc#(sets, linewidth, blocksize)) v_data 
                                                 <- replicateM(mkmem_config2rw_ecc(False, True));
  `else
    Vector#(ways, Ifc_mem_config2rw#(sets, linewidth, blocksize)) v_data 
                                                 <- replicateM(mkmem_config2rw(False, True));
  `endif
    method Action ma_read_p1(Bit#(TLog#(sets)) index, Bit#(blocksize) banks);
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        v_data[i].p1.request(0, index, ?, banks);
      end
    endmethod
    method Action ma_request_p2( Bool read_write, 
                              Bit#(TLog#(sets)) index, 
                              Bit#(linewidth) dataline, 
                              Bit#(TLog#(ways)) way,
                              Bit#(blocksize) banks);

      `logLevel( dcache, 0, $format("[%2d]DCACHE: DATAs: Req: rw:%b ind:%d way:%d data:%h",
                                     id, read_write, index, way, dataline))
      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_data[i].p2.request(0, index, dataline, banks);
        end
      else
        v_data[way].p2.request(1, index, dataline, banks);
    endmethod

    method DataResponse#(blocksize,wordsize) mv_read_response_p1(
                                              Bit#(blockbits) blocknum, 
                                              Bit#(ways) wayselect );
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth),blockbits))  block_offset = {blocknum,zeros};
      Bit#(respwidth) lv_selected_word = ?;
      Bit#(linewidth) lv_selected_line = ?;
    `ifdef dcache_ecc
      Bit#(blocksize) lv_line_ded = 0;
      Bit#(blocksize) lv_line_sed = 0;
      Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) lv_stored_parity=?;
      Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) lv_check_parity=?;
    `endif
      if (onehot) begin
        Vector#(ways, Bit#(respwidth)) lv_words = ?;
        Vector#(ways, Bit#(linewidth)) lv_lines = ?;
      `ifdef dcache_ecc
        Vector#(ways, Bit#(blocksize))     lv_lines_sed = ?;
        Vector#(ways, Bit#(blocksize))     lv_lines_ded = ?;
        Vector#(ways, Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize)))))) lv_stparity;
        Vector#(ways, Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize)))))) lv_chparity;
      `endif
        for (Integer i = 0; i< v_ways ; i = i + 1) begin
          lv_words[i] = truncate(v_data[i].p1.read_response >> block_offset);
          lv_lines[i] = v_data[i].p1.read_response;
        `ifdef dcache_ecc
          lv_lines_sed[i] = v_data[i].p1.read_sed;
          lv_lines_ded[i] = v_data[i].p1.read_ded;
          lv_stparity[i] = v_data[i].p1.stored_parity;
          lv_chparity[i] = v_data[i].p1.check_parity;
        `endif
        end
        lv_selected_word = select(lv_words,unpack(wayselect));
        lv_selected_line = select(lv_lines,unpack(wayselect));
      `ifdef dcache_ecc
        lv_line_sed = select(lv_lines_sed,unpack(wayselect));
        lv_line_ded = select(lv_lines_ded,unpack(wayselect));
        lv_stored_parity = select(lv_stparity, unpack(wayselect));
        lv_check_parity = select(lv_chparity, unpack(wayselect));
      `endif
      end
      else begin
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          if (wayselect[i] == 1) begin
            lv_selected_line = v_data[i].p1.read_response;
            lv_selected_word = truncate(lv_selected_line>> block_offset);
          `ifdef dcache_ecc
            lv_line_sed = v_data[i].p1.read_sed;
            lv_line_ded = v_data[i].p1.read_ded;
            lv_stored_parity = v_data[i].p1.stored_parity;
            lv_check_parity = v_data[i].p1.check_parity;
          `endif
          end
        end
      end

      Bit#(1) lv_word_ded = `ifdef dcache_ecc lv_line_ded[blocknum] `else 0 `endif ;
      Bit#(1) lv_word_sed = `ifdef dcache_ecc lv_line_sed[blocknum] `else 0 `endif ;

      return DataResponse{`ifdef dcache_ecc 
                            word_sed: lv_word_sed, word_ded:lv_word_ded,  
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
                            stored_parity: lv_stored_parity, check_parity: lv_check_parity,
                          `endif line: lv_selected_line, word: lv_selected_word};

    endmethod
    method DataResponse#(blocksize,wordsize) mv_read_response_p2(Bit#(ways) wayselect );
      Bit#(linewidth) lv_selected_line = ?;
    `ifdef dcache_ecc
      Bit#(blocksize) lv_line_ded = 0;
      Bit#(blocksize) lv_line_sed = 0;
      Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) lv_stored_parity=?;
      Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) lv_check_parity=?;
    `endif
      if (onehot) begin
        Vector#(ways, Bit#(linewidth)) lv_lines = ?;
      `ifdef dcache_ecc
        Vector#(ways, Bit#(blocksize))     lv_lines_sed = ?;
        Vector#(ways, Bit#(blocksize))     lv_lines_ded = ?;
        Vector#(ways, Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize)))))) lv_stparity;
        Vector#(ways, Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize)))))) lv_chparity;
      `endif
        for (Integer i = 0; i< v_ways ; i = i + 1) begin
          lv_lines[i] = v_data[i].p2.read_response;
        `ifdef dcache_ecc
          lv_lines_sed[i] = v_data[i].p2.read_sed;
          lv_lines_ded[i] = v_data[i].p2.read_ded;
          lv_stparity[i] = v_data[i].p2.stored_parity;
          lv_chparity[i] = v_data[i].p2.check_parity;
        `endif
        end
        lv_selected_line = select(lv_lines,unpack(wayselect));
      `ifdef dcache_ecc
        lv_line_sed = select(lv_lines_sed,unpack(wayselect));
        lv_line_ded = select(lv_lines_ded,unpack(wayselect));
        lv_stored_parity = select(lv_stparity, unpack(wayselect));
        lv_check_parity = select(lv_chparity, unpack(wayselect));
      `endif
      end
      else begin
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          if (wayselect[i] == 1) begin
            lv_selected_line = v_data[i].p2.read_response;
          `ifdef dcache_ecc
            lv_line_sed = v_data[i].p2.read_sed;
            lv_line_ded = v_data[i].p2.read_ded;
            lv_stored_parity = v_data[i].p2.stored_parity;
            lv_check_parity = v_data[i].p2.check_parity;
          `endif
          end
        end
      end
      return DataResponse{`ifdef dcache_ecc 
                            word_sed: 0, word_ded:0,  
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
                            stored_parity: lv_stored_parity, check_parity: lv_check_parity,
                          `endif line: lv_selected_line, word: ?};
    endmethod
  `ifdef dcache_ecc
    method Bit#(TMul#(wordsize, 8)) mv_sideband_read (Bit#(TLog#(ways)) way, Bit#(TLog#(blocksize)) bank);
      Bit#(linewidth) _line = v_data[way].p2.read_response;
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth),blockbits))  block_offset = {bank,zeros};
      return truncate(_line>> block_offset);
    endmethod
  `endif
  endmodule : mk_dataram2rw

  // where buswidth = respwidth and banksize = respwidth
  interface Ifc_fillbuffer_v2#(numeric type fbsize,
                            numeric type wordsize,
                            numeric type blocksize,
                            numeric type sets,
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
                                      Bit#(TLog#(blocksize))              init_bank);

    method Action ma_from_storebuffer(Bit#(respwidth) mask, Bit#(respwidth)  dataword,
                                      Bit#(TLog#(fbsize)) fbindex, Bit#(paddr) address);

    method ReleaseInfo#(TMul#(blocksize,TMul#(wordsize,8)), paddr) mv_release_info;
    method Action ma_perform_release;
    method ActionValue#(PollingResponse#(wordsize,fbsize)) mav_polling_response(
      Bit#(paddr) address, Bool fill, Bit#(TLog#(fbsize)) fbindex); 
  `ifdef dcache_ecc
    method Action mav_perform_sec (Bit#(TLog#(fbsize)) fbindex,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) stored_parity,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) check_parity);
  `endif
  endinterface : Ifc_fillbuffer_v2

  (*conflict_free="ma_perform_release,mav_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, mav_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, ma_perform_release"*)
  (*conflict_free="mav_allocate_line, ma_from_storebuffer"*)
  (*conflict_free="ma_fill_from_memory, ma_from_storebuffer"*)
`ifdef dcache_ecc
  (*conflict_free="ma_fill_from_memory, mav_perform_sec"*)
  (*mutually_exclusive="mav_allocate_line, mav_perform_sec"*)
  (*conflict_free="mav_perform_sec, ma_from_storebuffer"*)
`endif
  module mk_fillbuffer_v2#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_fillbuffer_v2#(fbsize, wordsize, blocksize, sets, paddr, respwidth))
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

        `ifdef dcache_ecc
          , Add#(2, TLog#(TMul#(8,wordsize)), ecc_size)
        `endif
          );

    let v_wordsize = valueOf(wordsize);
    let v_blocksize = valueOf(blocksize);
    let v_sets = valueOf(sets);
    let v_wordbits = valueOf(wordbits);
    let v_blockbits = valueOf(blockbits);
    let v_fbsize = valueOf(fbsize);
    let v_respwidth = valueOf(respwidth);
  `ifdef dcache_ecc
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
    Vector#(fbsize,ConfigReg#(Bool))                      v_fb_addr_valid    <- replicateM(mkConfigReg(False));
    /*doc: vec: vector of registers to hold the dataline for fill-buffers.*/
    //Vector#(fbsize,Reg#(Bit#(linewidth)))           v_fb_data     <- replicateM(mkConfigReg(unpack(0)));
    Vector#(fbsize,Vector#(blocksize,ConfigReg#(Bit#(respwidth))))    v_fb_data     
                                                    <- replicateM(replicateM(mkConfigReg(unpack(0))));
    /*doc: vec: vector of registers to indicate that the line fill faced a bus-error*/
    Vector#(fbsize,ConfigReg#(Bit#(1)))                   v_fb_err      <- replicateM(mkConfigReg(0));
    /*doc: vec: vector of registers to indicate that the line in the fill-buffer is dirty*/
    Vector#(fbsize,ConfigReg#(Bit#(1)))                   v_fb_dirty    <- replicateM(mkConfigReg(0));
    /*doc: vec: vector of regisetrs to indicate if the entire line of the fillbuffer entry is
     * available or not*/
    Vector#(fbsize,ConfigReg#(Bool))                   v_fb_line_valid  <- replicateM(mkConfigReg(False));
    /*doc: reg: register to indicate how many bytes of the line have been filled by the
     bus*/
    ConfigReg#(Bit#(blocksize))                  rg_fb_enables    <- mkConfigReg(0);
    /*doc: vec: vector registers indicating the address of the fill-buffer line*/
    Vector#(fbsize,ConfigReg#(Bit#(paddr)))               v_fb_addr     <- replicateM(mkConfigReg(0));

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
      for (Integer i = 0; i< v_blocksize ; i = i + 1) begin
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
                                      Bit#(TLog#(blocksize))              init_bank);
      Bit#(TLog#(blocksize)) lv_current_bank = rg_fb_enables == 0? init_bank: rg_next_bank;
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
      for (Integer i = 0; i<v_blocksize; i = i + 1) begin
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
  `ifdef dcache_ecc
    method Action mav_perform_sec (Bit#(TLog#(fbsize)) fbindex,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) stored_parity,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) check_parity);

      for (Integer i = 0; i< v_blocksize; i = i + 1) begin
        Bit#(ecc_size) _stparity = stored_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
        Bit#(ecc_size) _chparity = check_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
        let _data = fn_ecc_correct(_chparity, _stparity, v_fb_data[fbindex][i]);
        v_fb_data[fbindex][i] <= _data;
      end
    endmethod
  `endif
  endmodule : mk_fillbuffer_v2

  interface Ifc_storebuffer#( numeric type addr, 
                              numeric type wordsize, 
                              numeric type esize,
                              numeric type sbsize, 
                              numeric type fbsize);

    method ActionValue#(Tuple2#(Bit#(TMul#(wordsize,8)),Bit#(TMul#(wordsize,8)))) 
                                                            mav_check_sb_hit (Bit#(addr) phyaddr);
    method Action ma_allocate_entry (Bit#(addr) address, Bit#(TMul#(8,wordsize)) data, 
            Bit#(esize) epochs, Bit#(TLog#(fbsize)) fbindex, Bit#(2) size, Bool io
          `ifdef atomic ,Bool atomic, Bit#(TMul#(8,wordsize)) read_data, Bit#(5) atomic_op `endif );
    method ActionValue#(Tuple2#(Bool,Storebuffer#(addr, TMul#(wordsize,8), esize, TLog#(fbsize)))) 
                                                                            mav_store_to_commit;
    method Bool mv_sb_full;
    method Bool mv_sb_empty;
    method Bool mv_cacheable_store;
    method Bool mv_sb_busy;
  endinterface : Ifc_storebuffer

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

            `ifdef atomic
              ,Add#(e__, 32, dataword)
            `endif
            );

    let v_wordbits = valueOf(wordbits);
   
  `ifdef atomic
    /*doc:func: This function carries out the atomic operations based on the RISC-V ISA spec*/
    function Bit#(dataword) fn_atomic_op (Bit#(5) op,  Bit#(dataword) rs2,  Bit#(dataword) loaded);
      Bit#(dataword) op1 = loaded;
      Bit#(dataword) op2 = rs2;
    `ifdef RV64
      if(op[4]==0)begin
	  		op1=signExtend(loaded[31:0]);
        op2= signExtend(rs2[31:0]);
      end
    `endif
      Int#(dataword) s_op1 = unpack(op1);
	  	Int#(dataword) s_op2 = unpack(op2);

      case (op[3:0])
	  			'b0011:return op2;
	  			'b0000:return (op1+op2);
	  			'b0010:return (op1^op2);
	  			'b0110:return (op1&op2);
	  			'b0100:return (op1|op2);
	  			'b1100:return min(op1,op2);
	  			'b1110:return max(op1,op2);
	  			'b1000:return pack(min(s_op1,s_op2));
	  			'b1010:return pack(max(s_op1,s_op2));
	  			default:return op1;
	  		endcase
    endfunction
  `endif

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

    /*doc:reg: */
    Reg#(Bool) rg_sb_busy <- mkReg(False);

  `ifdef atomic
    /*doc:reg: */
    Reg#(Bit#(dataword)) rg_atomic_readword <- mkReg(0);
    /*doc:reg: */
    Reg#(Bit#(5)) rg_atomic_op <- mkReg(0);
    /*doc:reg: */
    Reg#(Bit#(TLog#(sbsize))) rg_atomic_tail <- mkReg(0);

    /*doc:rule: */
    rule rl_perform_atomic(rg_sb_busy);
      let _s = v_sb_meta[rg_atomic_tail];
      let _newdata = fn_atomic_op(rg_atomic_op, _s.data, rg_atomic_readword);
    `ifdef RV64
      if(rg_atomic_op[4] == 0)begin
        _newdata = duplicate(_newdata[31:0]);
      end
    `endif
      _s.data = _newdata;
      v_sb_meta[rg_atomic_tail] <= _s;
      rg_sb_busy <= False;
      `logLevel( dcache, 0, $format("[%2d]SB: Performing Atomic: Op:%b Wdata:%h Rdata:%h Result:%h",
        id, rg_atomic_op, _s.data, rg_atomic_readword, _newdata))
    endrule
  `endif

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
      for (Integer i = 0; i<valueOf(sbsize); i = i + 1) begin
        `logLevel( dcache, 0, $format("[%2d]SB: Lookup:",id,fshow(v_sb_meta[i])))
      end
  
      return tuple2(fold(fn_OR,storemask)>>shiftamt,fold(fn_OR,data_values)>>shiftamt);
    endmethod

    method Action ma_allocate_entry (Bit#(addr) address, Bit#(dataword) data, 
          Bit#(esize) epochs, Bit#(TLog#(fbsize)) fbindex, Bit#(2) size, Bool io
          `ifdef atomic ,Bool atomic, Bit#(TMul#(8,wordsize)) read_data, 
          Bit#(5) atomic_op `endif ) if(!sb_full `ifdef atomic && !rg_sb_busy `endif );

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
      `logLevel( dcache, 0, $format("[%2d]SB: Allocating sbindex:%d with ",id,rg_tail,
                                          fshow(_s)))
    `ifdef atomic 
      rg_sb_busy <= atomic;
      rg_atomic_tail <= rg_tail;
      rg_atomic_readword <= read_data;
      rg_atomic_op <= atomic_op;
    `endif
    endmethod
    method mv_sb_full = sb_full;
    method mv_sb_empty = sb_empty;
    method ActionValue#(Tuple2#(Bool,Storebuffer#(addr, TMul#(wordsize,8), esize, TLog#(fbsize)))) 
        mav_store_to_commit if(!sb_empty);
      rg_head <= rg_head + 1;
      v_sb_valid[rg_head] <= False;
      `logLevel( dcache, 0, $format("[%2d]SB: Committing store sbindex:%d with ",id,rg_head,
                                          fshow(v_sb_meta[rg_head])))
      return tuple2(v_sb_valid[rg_head], v_sb_meta[rg_head]);
    endmethod
    method mv_cacheable_store = !v_sb_meta[rg_head].io;
    method mv_sb_busy = rg_sb_busy;
  endmodule : mk_storebuffer

`ifdef dcache_dualport
  (*synthesize*)
  module mkdcache_tag#(parameter Bit#(32) id)(Ifc_tagram2rw#(`dwords, `dblocks, `dsets, `dways, `paddr));
    let ifc();
    mk_tagram2rw _temp(id,ifc);
    return (ifc);
  endmodule : mkdcache_tag
  (*synthesize*)
  module mkdcache_data#(parameter Bit#(32) id)(Ifc_dataram2rw#(`dwords, `dblocks, `dsets, `dways));
    let ifc();
    mk_dataram2rw#(id,unpack(`dcache_onehot)) _temp(ifc);
    return (ifc);
  endmodule : mkdcache_data
`else
  (*synthesize*)
  module mkdcache_tag#(parameter Bit#(32) id)(Ifc_tagram1rw#(`dwords, `dblocks, `dsets, `dways, `paddr));
    let ifc();
    mk_tagram1rw _temp(id,ifc);
    return (ifc);
  endmodule : mkdcache_tag
  (*synthesize*)
  module mkdcache_data#(parameter Bit#(32) id)(Ifc_dataram1rw#(`dwords, `dblocks, `dsets, `dways));
    let ifc();
    mk_dataram1rw#(id,unpack(`dcache_onehot)) _temp(ifc);
    return (ifc);
  endmodule : mkdcache_data
`endif
  (*synthesize*)
  module mkdcache_fb_v2#(parameter Bit#(32) id)(Ifc_fillbuffer_v2#(`dfbsize, `dwords, `dblocks, `dsets, `paddr,  `dbuswidth));
    let ifc();
    mk_fillbuffer_v2#(id,unpack(`dcache_onehot)) _temp(ifc);
    return (ifc);
  endmodule : mkdcache_fb_v2

endpackage

