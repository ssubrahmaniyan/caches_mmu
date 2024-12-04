/* 
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
  /*import List         :: * ;*/
  /*import myZBus         :: * ;*/
`ifdef ovl_assert
  import OVLAssertions    :: * ;
`endif
`ifdef sva_assert
  import SVA              :: * ;
`endif

  import mem_config :: * ;
  import dcache_types :: * ;

  typedef struct{
  `ifdef dcache_ecc
    Bit#(ways) sed;
    Bit#(ways) ded;
  `endif
    Bit#(ways)    waymask;
  } TagResponse#(numeric type ways) deriving(Bits, Eq, FShow);

  typedef struct{
    `ifdef dcache_ecc
      Bit#(ways) sed;
      Bit#(ways) ded;
    `endif
    Bit#(paddr) tag;
  } TagSelectResponse#(numeric type ways, numeric type paddr) deriving(Bits, Eq, FShow);

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
  } DataLineResponse#(numeric type b, numeric type w) deriving(Bits, Eq, FShow);
  
  typedef struct{
  `ifdef dcache_ecc
    Bit#(b) line_sed;
    Bit#(b) line_ded;
    Bit#(1) word_sed;
    Bit#(1) word_ded;
    Bit#(TMul#(b,TAdd#(2,TLog#(TMul#(8,w))))) stored_parity;
    Bit#(TMul#(b,TAdd#(2,TLog#(TMul#(8,w))))) check_parity;
  `endif
    Bit#(TMul#(8,w)) word;
    Bit#(TMul#(TMul#(w,8),b)) line;
  } DataWordResponse#(numeric type b, numeric type w) deriving(Bits, Eq, FShow);

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
    method TagResponse#(ways) mv_tagmatch_resp(Bit#(paddr) address_in);
    method TagSelectResponse#(ways,paddr) mv_tag_select(Bit#(TLog#(ways)) wayselect );
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
      `logLevel( dcache, 0, $format("[%2d]DCACHE: TagRAM: Tag:%h RW:%b Way:%d set:%d",id,tag,
      read_write, way, index))
    endmethod
    method TagSelectResponse#(ways,paddr) mv_tag_select(Bit#(TLog#(ways)) wayselect );

      Vector#(ways, Bit#(tagbits)) lv_tags;
    `ifdef dcache_ecc
      Bit#(ways) sed = 0;
      Bit#(ways) ded = 0;
      Vector#(ways,Bit#(TAdd#(2,TLog#(tagbits)))) lv_chparity;
      Vector#(ways,Bit#(TAdd#(2,TLog#(tagbits)))) lv_stparity;
    `endif
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
      Bit#(paddr)  lv_tag = {lv_tags[wayselect],'d0};
      return  TagSelectResponse{`ifdef dcache_ecc sed: sed, ded: ded, `endif tag:lv_tag}  ;
    endmethod

    method TagResponse#(ways) mv_tagmatch_resp(Bit#(paddr) address_in);

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
      return TagResponse{`ifdef dcache_ecc sed: sed, ded: ded, `endif waymask: lv_hitvector};
    endmethod
  `ifdef dcache_ecc
    method Bit#(paddr) mv_sideband_read (Bit#(TLog#(ways)) way);
      return zeroExtend(v_tags[way].read_response);
    endmethod
  `endif
  endmodule : mk_tagram1rw
  interface Ifc_tagram1r1w#(
                        numeric type wordsize,
                        numeric type blocksize,
                        numeric type sets,
                        numeric type ways,
                        numeric type paddr);

    /*doc:method: request method to initiate a read or write on the tags. A read is latched on all
    * ways. A write is peformed only on a single way.*/
    method Action ma_read_p1(Bit#(TLog#(sets)) index);
    method Action ma_request_p2( Bit#(TLog#(sets)) index, 
                                 Bit#(TLog#(ways)) wayselect,
                                 Bit#(paddr) address );

    /*doc:method: This method will read the ram output from all ways. Compare with the input tag.
     * and respond with a hit-vector indicating which way was a hit. Also responds if there was a
     * single-error or double-error detected while performing the read across all the ways. */
    method ActionValue#(TagResponse#(ways)) mv_tagmatch_p1(Bit#(paddr) address_in,
                                                           Bit#(TLog#(sets)) set_index,
                                                           Bit#(ways) replacement);
    method ActionValue#(Bit#(TSub#(paddr,TAdd#(TLog#(blocksize),TAdd#(TLog#(wordsize), TLog#(sets)))))) mv_select_p1(Bit#(ways) wayselect);
  endinterface : Ifc_tagram1r1w
  
  module mk_tagram1r1w#(parameter Bit#(32) id)(Ifc_tagram1r1w#(wordsize, blocksize, sets, ways, paddr))
    provisos(    
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, paddr),     // tagbits = 32-(wordbits+blockbits+setbits)

          Add#(TLog#(sets), a__, _b)
    );
    
    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);

    /*doc:ram: This the tag array which is dual ported has 'way' number of rams*/
    Vector#(ways, Ifc_mem_config1r1w#(sets, tagbits, 1)) v_tags <-
                                                        replicateM(mkmem_config1r1w(False,False));
    /*Ifc_mem_config1r1w#(sets, TMul#(ways,tagbits), 1) v_tags <- mkmem_config1r1w(False,False);*/
    method Action ma_read_p1(Bit#(TLog#(sets)) index);
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        v_tags[i].read(index);
      end
    endmethod
    method Action ma_request_p2( Bit#(TLog#(sets)) index, 
                                 Bit#(TLog#(ways)) wayselect,
                                 Bit#(paddr) address );

      Bit#(tagbits) tag = truncateLSB(address);
      `logLevel( dcache, 0, $format("[%2d]DCACHE: TAGs: Req: way:%d ind:%d tag:%h", id, wayselect,
                                                                                        index, tag))
      v_tags[wayselect].write(1, index, pack(tag), '1);
    endmethod
    method ActionValue#(TagResponse#(ways)) mv_tagmatch_p1(Bit#(paddr) address_in,
                                                           Bit#(TLog#(sets)) set_index,
                                                           Bit#(ways) replacement);

      Bit#(tagbits) tag_in = truncateLSB(address_in);
      Bit#(ways) lv_hitvector = 0;
      Vector#(ways, Bit#(tagbits)) lv_tags;
      Bit#(TLog#(ways)) replacement_index = fromOInt(unpack(replacement));
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_tags[i] = v_tags[i].read_response;
        lv_hitvector[i] = pack(truncate(lv_tags[i]) == tag_in);
      end
      `logLevel( dcache, 0, $format("TAGS: tag_in:%h",tag_in,fshow(lv_tags)))
      `logLevel( dcache, 0, $format("TAGS: hitvector:%b",lv_hitvector))
      return TagResponse{  // `ifdef dcache_ecc sed: sed, ded: ded, `endif 
                          waymask: lv_hitvector};
    endmethod:mv_tagmatch_p1
    method ActionValue#(Bit#(TSub#(paddr,TAdd#(TLog#(blocksize),TAdd#(TLog#(wordsize), TLog#(sets)))))) mv_select_p1(Bit#(ways) wayselect);
      Bit#(tagbits) lv_tag = ?;
      Vector#(ways, Bit#(tagbits)) lv_tags = ?;
      for (Integer i = 0; i< v_ways ; i = i + 1) begin
        lv_tags[i] = v_tags[i].read_response;
      end
      lv_tag = lv_tags[fromOInt(unpack(wayselect))];
      return lv_tag;
    endmethod:mv_select_p1

  endmodule : mk_tagram1r1w

  interface Ifc_dataram1r1w#(
                         numeric type wordsize,
                         numeric type blocksize,
                         numeric type sets,
                         numeric type ways);
    /*doc:method: request method to initiate a read or write on the dataline. A read is latched on all
    * ways. A write is peformed only on a single way.*/
    method Action ma_read_p1(Bit#(TLog#(sets)) index, Bit#(blocksize) banks);
    method Action ma_request_p2( Bit#(TLog#(sets)) index, 
                              Bit#(TMul#(TMul#(wordsize, 8),blocksize)) dataline, 
                              Bit#(TLog#(ways)) way,
                              Bit#(blocksize) banks);

    /*doc:method: This method will read the ram output from all ways. Compare with the input tag.
     * and respond with a hit-vector indicating which way was a hit. Also responds if there was a
     * single-error or double-error detected while performing the read across all the ways. */
    method DataLineResponse#(blocksize,wordsize) mv_lineselect_p1(Bit#(ways) wayselect );
    method DataWordResponse#(blocksize, wordsize) mv_wordselect_p1( Bit#(TLog#(blocksize)) blocknum,
    Bit#(ways) wayselect);
  endinterface : Ifc_dataram1r1w
  module mk_dataram1r1w#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_dataram1r1w#(wordsize, blocksize, sets, ways))
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
      );
    let v_wordsize = valueOf(wordsize);
    let v_blocksize = valueOf(blocksize);
    let v_sets = valueOf(sets);
    let v_ways = valueOf(ways);
    Vector#(ways, Ifc_mem_config1r1w#(sets, linewidth, 1)) v_data 
                                                 <- replicateM(mkmem_config1r1w(False, False));
    method Action ma_read_p1(Bit#(TLog#(sets)) index, Bit#(blocksize) banks);
      for (Integer i = 0; i< v_ways; i = i + 1) begin
        v_data[i].read(index);
      end
    endmethod
    method Action ma_request_p2( Bit#(TLog#(sets)) index, 
                              Bit#(linewidth) dataline, 
                              Bit#(TLog#(ways)) way,
                              Bit#(blocksize) banks);

      `logLevel( dcache, 0, $format("[%2d]DCACHE: DATAs: Req: rw:%b ind:%d data:%h",
                                     id, index, way, dataline))
      v_data[way].write(1, index, dataline, '1);
    endmethod

    method DataWordResponse#(blocksize, wordsize) mv_wordselect_p1( Bit#(TLog#(blocksize)) blocknum,
    Bit#(ways) wayselect);
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(TAdd#(TLog#(respwidth),blockbits))  block_offset = {blocknum,zeros};
      Bit#(TLog#(ways)) wayindex = fromOInt(unpack(wayselect));
      Bit#(respwidth) lv_selected_word = ?;
      Bit#(linewidth) lv_repl_selected_line = ?;
      Bit#(linewidth) lv_hit_selected_line = ?;
      Vector#(ways, Bit#(respwidth)) lv_words = ?;
      Vector#(ways, Bit#(linewidth)) lv_lines = ?;
      for (Integer i = 0; i< v_ways ; i = i + 1) begin
        Vector#(blocksize, Bit#(respwidth)) _words = unpack(v_data[i].read_response);
        lv_words[i] = _words[blocknum];
        lv_lines[i] = v_data[i].read_response;
      end
      if (onehot) begin
        lv_selected_word = select(lv_words,unpack(wayselect));
        lv_hit_selected_line = select(lv_lines,unpack(wayselect));
      end
      else begin
        lv_selected_word = lv_words[wayindex];
        lv_hit_selected_line = lv_lines[wayindex];
      end

      return DataWordResponse{
                          //replline: lv_repl_selected_line, 
                          word: lv_selected_word
                          ,line: lv_hit_selected_line};
    endmethod

    method DataLineResponse#(blocksize,wordsize) mv_lineselect_p1(
                                              Bit#(ways) wayselect );
      Bit#(TLog#(respwidth)) zeros = 0;
      Bit#(linewidth) lv_selected_line = ?;
      Vector#(ways, Bit#(linewidth)) lv_lines = ?;
      for (Integer i = 0; i< v_ways ; i = i + 1) begin
        lv_lines[i] = v_data[i].read_response;
      end
      if (onehot)
        lv_selected_line = select(lv_lines,unpack(wayselect));
      else 
        lv_selected_line = lv_lines[fromOInt(unpack(wayselect))];

      return DataLineResponse{  line: lv_selected_line};

    endmethod
  endmodule : mk_dataram1r1w

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
    method ActionValue#(TagResponse#(ways)) mv_tagmatch_p1(Bit#(paddr) address_in);
    method ActionValue#(Bit#(paddr))        mv_tagselect_p1(Bit#(TLog#(ways)) wayselect);
    method Bit#(paddr) mv_read_response_p2(Bit#(TLog#(ways)) wayselect);    
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

    method ActionValue#(TagResponse#(ways)) mv_tagmatch_p1(Bit#(paddr) address_in);

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
      return TagResponse{`ifdef dcache_ecc sed: sed, ded: ded, `endif 
                          waymask: lv_hitvector};
    endmethod:mv_tagmatch_p1

    method ActionValue#(Bit#(paddr))        mv_tagselect_p1(Bit#(TLog#(ways)) wayselect);
      Bit#(paddr)  lv_tag = {v_tags[wayselect].p1.read_response,'d0};
      return lv_tag;
    endmethod:mv_tagselect_p1

  `ifdef dcache_ecc
    method Bit#(paddr) mv_sideband_read (Bit#(TLog#(ways)) way);
      return zeroExtend(v_tags[way].p2.read_response);
    endmethod
  `endif
    method Bit#(paddr) mv_read_response_p2(Bit#(TLog#(ways)) wayselect );
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
      return _t1 ;
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
    method ActionValue#(DataWordResponse#(blocksize,wordsize)) mv_word_select(
                                              Bit#(TMax#(1,TLog#(blocksize))) blocknum, 
                                              Bit#(ways) wayselect );
    //method DataLineResponse#(blocksize,wordsize) mv_line_select(Bit#(ways) wayselect );
    method ActionValue#(DataLineResponse#(blocksize,wordsize)) mv_line_select(Bit#(ways) wayselect );
  `ifdef dcache_ecc
    method Bit#(TMul#(wordsize, 8)) mv_sideband_read (Bit#(TLog#(ways)) way, Bit#(TLog#(blocksize)) bank);
  `endif
  endinterface : Ifc_dataram1rw

  module mk_dataram1rw#(parameter Bit#(32) id, parameter Bool onehot)
      (Ifc_dataram1rw#(wordsize, blocksize, sets, ways))
      provisos(
          Mul#(TMul#(wordsize,8),blocksize,linewidth),
          Log#(wordsize, wordbits),
          Log#(blocksize, blockbits1),
          Max#(1,blockbits1,blockbits),
          Log#(sets, setbits),
          Mul#(wordsize,8, respwidth),

          // required by bsc
          Add#(1, c__, TLog#(TAdd#(1, ways))), // ways should be atleast 1
          Add#(a__, respwidth, linewidth), // since the response is truncated version of line
          Mul#(TDiv#(linewidth, blocksize), blocksize, linewidth), // from mem_config
          Add#(d__, TDiv#(linewidth, blocksize), linewidth), // from mem_config
          Add#(f__, TMul#(wordsize, 8), linewidth),
          Add#(1, b__, ways)

        `ifdef dcache_ecc
          ,Add#(g__, 2, TMul#(2, blocksize)),
          Add#(TLog#(TDiv#(linewidth, blocksize)), h__, 6),
          Add#(i__, TDiv#(linewidth, blocksize), 64),
          Add#(e__, TAdd#(2, TLog#(TDiv#(linewidth, blocksize))), TMul#(blocksize,
                                                    TAdd#(2, TLog#(TDiv#(linewidth, blocksize))))),
          Mul#(blocksize, TAdd#(2, TLog#(TMul#(8, wordsize))), TMul#(blocksize,
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
    Vector#(ways, Ifc_mem_config1rw#(sets, linewidth, 1)) v_data
                                                      <- replicateM(mkmem_config1rw(False));
  `endif
  `ifdef dcache_zbus
    Vector#(TAdd#(ways,1), ZBusDualIFC#(Bit#(linewidth))) v_zbus <- replicateM(mkZBusBuffer);
    List#(ZBusBusIFC#(Bit#(linewidth))) ifc_list=List::nil;
    for (Integer i = 0; i<v_ways+1; i = i + 1)
      ifc_list = List::cons(v_zbus[i].busIFC, ifc_list);
    Empty bus_ifc();
    mkZBus#(ifc_list) inst_bus(bus_ifc);
  `endif
    
    method Action ma_request( Bool read_write,
                              Bit#(TLog#(sets)) index,
                              Bit#(linewidth) dataline,
                              Bit#(TLog#(ways)) way,
                              Bit#(blocksize) banks);

      if(!read_write)
        for (Integer i = 0; i< v_ways; i = i + 1) begin
          v_data[i].request(0, index, dataline, '1);
        end
      else
        v_data[way].request(1, index, dataline, '1);
    endmethod
    method ActionValue#(DataLineResponse#(blocksize,wordsize)) mv_line_select(Bit#(ways) wayselect );
    `ifdef ASSERT
      dynamicAssert(countOnes(wayselect)==1,"Wayselect should be one-hot.");
    `endif
      Bit#(TLog#(respwidth)) zeros = 0;
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
          lv_lines[i] = v_data[i].read_response;
        `ifdef dcache_ecc
          lv_lines_sed[i] = v_data[i].read_sed;
          lv_lines_ded[i] = v_data[i].read_ded;
          lv_stparity[i] = v_data[i].stored_parity;
          lv_chparity[i] = v_data[i].check_parity;
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
        /*Vector#(ways, Bit#(linewidth)) lv_lines;
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          lv_lines[i] = duplicate(wayselect[i]) & v_data[i].read_response;
        end
        lv_selected_line = foldl1( \| , lv_lines);*/
      `ifdef dcache_zbus
        lv_selected_line = v_zbus[v_ways].clientIFC.get();
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          if(wayselect[i] ==1)
            v_zbus[i].clientIFC.drive(v_data[i].read_response);
        end
      `else
        for (Integer i = 0; i<v_ways; i = i + 1) begin
          if (wayselect[i] == 1) begin
            lv_selected_line = v_data[i].read_response;
          `ifdef dcache_ecc
            lv_line_sed = v_data[i].read_sed;
            lv_line_ded = v_data[i].read_ded;
            lv_stored_parity = v_data[i].stored_parity;
            lv_check_parity = v_data[i].check_parity;
          `endif
          end
        end
      `endif
      end
      Bit#(1) lv_word_ded = 0 ;//`ifdef dcache_ecc lv_line_ded[blocknum] `else 0 `endif ;
      Bit#(1) lv_word_sed = 0 ;//`ifdef dcache_ecc lv_line_sed[blocknum] `else 0 `endif ;

      return DataLineResponse{`ifdef dcache_ecc 
                            word_sed: lv_word_sed, word_ded:lv_word_ded,  
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
                            stored_parity: lv_stored_parity, check_parity: lv_check_parity,
                          `endif line: lv_selected_line};

    endmethod

    method ActionValue#(DataWordResponse#(blocksize,wordsize)) mv_word_select(
                                              Bit#(blockbits) blocknum,
                                              Bit#(ways) wayselect );
    `ifdef ASSERT
      dynamicAssert(countOnes(wayselect)<=1,"Wayselect should be one-hot.");
    `endif
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

      return DataWordResponse{`ifdef dcache_ecc 
                            word_sed: lv_word_sed, word_ded:lv_word_ded,  
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
                            stored_parity: lv_stored_parity, check_parity: lv_check_parity,
                          `endif word: lv_selected_word, line: lv_selected_line};

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
    method DataLineResponse#(blocksize,wordsize) mv_lineselect_p1(Bit#(ways) wayselect );
    method DataWordResponse#(blocksize,wordsize) mv_wordselect_p1(
                                              Bit#(TLog#(blocksize)) blocknum, 
                                              Bit#(ways) wayselect );
    method DataLineResponse#(blocksize,wordsize) mv_read_response_p2(Bit#(ways) wayselect );
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

    method DataWordResponse#(blocksize, wordsize) mv_wordselect_p1(
                                                                Bit#(blockbits) blocknum,
                                                                Bit#(ways) wayselect);
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

      return DataWordResponse{`ifdef dcache_ecc 
                            word_sed: lv_word_sed, word_ded:lv_word_ded,  
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
                            stored_parity: lv_stored_parity, check_parity: lv_check_parity,
                          `endif line: lv_selected_line, word: lv_selected_word};
    endmethod

    method DataLineResponse#(blocksize,wordsize) mv_lineselect_p1(
                                              Bit#(ways) wayselect );
      Bit#(TLog#(respwidth)) zeros = 0;
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
          lv_lines[i] = v_data[i].p1.read_response;
        `ifdef dcache_ecc
          lv_lines_sed[i] = v_data[i].p1.read_sed;
          lv_lines_ded[i] = v_data[i].p1.read_ded;
          lv_stparity[i] = v_data[i].p1.stored_parity;
          lv_chparity[i] = v_data[i].p1.check_parity;
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
            lv_selected_line = v_data[i].p1.read_response;
          `ifdef dcache_ecc
            lv_line_sed = v_data[i].p1.read_sed;
            lv_line_ded = v_data[i].p1.read_ded;
            lv_stored_parity = v_data[i].p1.stored_parity;
            lv_check_parity = v_data[i].p1.check_parity;
          `endif
          end
        end
      end

      Bit#(1) lv_word_ded = 0 ;
      Bit#(1) lv_word_sed = 0 ;

      return DataLineResponse{`ifdef dcache_ecc 
                            word_sed: lv_word_sed, word_ded:lv_word_ded,  
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
                            stored_parity: lv_stored_parity, check_parity: lv_check_parity,
                          `endif line: lv_selected_line};

    endmethod
    method DataLineResponse#(blocksize,wordsize) mv_read_response_p2(Bit#(ways) wayselect );
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
      return DataLineResponse{`ifdef dcache_ecc 
                            word_sed: 0, word_ded:0,  
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
                            stored_parity: lv_stored_parity, check_parity: lv_check_parity,
                          `endif line: lv_selected_line};
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
                                      Bit#(TMax#(1,TLog#(blocksize)))              init_bank);

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
 //(*conflict_free="ma_fill_from_memory, ma_perform_release"*)
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
          Log#(blocksize, blockbits1),
          Max#(1,blockbits1,blockbits),
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
          Add#(TAdd#(tagbits, setbits), e__, paddr),
          Add#(f__, 1, respwidth)

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
    
    //mav_allocate_line
    Wire#(Bool) wr_v_fb_addr_valid_mav_allocate_line <- mkDWire(False);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_addr_valid_mav_allocate_line <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_addr_valid_mav_allocate_line <- mkDWire(False);

    //ma_perform_release
    Wire#(Bool) wr_v_fb_addr_valid_ma_perform_release <- mkDWire(False);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_addr_valid_ma_perform_release <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_addr_valid_ma_perform_release <- mkDWire(False);
    
    
    
    /*doc: vec: vector of registers to hold the dataline for fill-buffers.*/
    //Vector#(fbsize,Reg#(Bit#(linewidth)))           v_fb_data     <- replicateM(mkConfigReg(unpack(0)));
    Vector#(fbsize,Vector#(blocksize,ConfigReg#(Bit#(respwidth))))    v_fb_data     
                                                    <- replicateM(replicateM(mkConfigReg(unpack(0))));

    //mav_allocate_line
    Vector#(blocksize,Wire#(Bit#(respwidth)))    wr_v_fb_data_mav_allocate_line    
                                                    <- replicateM(mkDWire(0));
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_data_mav_allocate_line <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_data_mav_allocate_line <- mkDWire(False);
    
    //ma_fill_from_memory
    Wire#(Bit#(respwidth)) wr_v_fb_data_ma_fill_from_memory <- mkDWire(0);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_data_ma_fill_from_memory <- mkDWire(0);
    Wire#(Bit#(TMax#(1,blockbits))) wr_block_v_fb_data_ma_fill_from_memory <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_data_ma_fill_from_memory <- mkDWire(False);

    //ma_from_storebuffer
    Wire#(Bit#(respwidth)) wr_v_fb_data_ma_from_storebuffer <- mkDWire(0);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_data_ma_from_storebuffer <- mkDWire(0);
    Wire#(Bit#(TMax#(1,blockbits))) wr_block_v_fb_data_ma_from_storebuffer <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_data_ma_from_storebuffer <- mkDWire(False);

    `ifdef dcache_ecc
    //mav_perform_sec
    Vector#(blocksize,Wire#(Bit#(respwidth)))    wr_v_fb_data_mav_perform_sec    
                                                    <- replicateM(mkDWire(0));
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_data_mav_perform_sec <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_data_mav_perform_sec <- mkDWire(False);
    `endif

    /*doc: vec: vector of registers to indicate that the line fill faced a bus-error*/
    Vector#(fbsize,ConfigReg#(Bit#(1)))                   v_fb_err      <- replicateM(mkConfigReg(0));

    //mav_allocate_line
    Wire#(Bit#(1)) wr_v_fb_err_mav_allocate_line <- mkDWire(0);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_err_mav_allocate_line <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_err_mav_allocate_line <- mkDWire(False);
    
    
    //ma_fill_from_memory
    Wire#(Bit#(1)) wr_v_fb_err_ma_fill_from_memory <- mkDWire(0);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_err_ma_fill_from_memory <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_err_ma_fill_from_memory <- mkDWire(False);    



    /*doc: vec: vector of registers to indicate that the line in the fill-buffer is dirty*/
    Vector#(fbsize,ConfigReg#(Bit#(1)))                   v_fb_dirty    <- replicateM(mkConfigReg(0));

    //mav_allocate_line
    Wire#(Bit#(1)) wr_v_fb_dirty_mav_allocate_line <- mkDWire(0);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_dirty_mav_allocate_line <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_dirty_mav_allocate_line <- mkDWire(False);

    //ma_from_storebuffer
    Wire#(Bit#(1)) wr_v_fb_dirty_ma_from_storebuffer <- mkDWire(0);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_dirty_ma_from_storebuffer <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_dirty_ma_from_storebuffer <- mkDWire(False);

    /*doc: vec: vector of regisetrs to indicate if the entire line of the fillbuffer entry is
     * available or not*/
    Vector#(fbsize,ConfigReg#(Bool))                   v_fb_line_valid  <- replicateM(mkConfigReg(False));
    
    //mav_allocate_line
    Wire#(Bool) wr_v_fb_line_valid_mav_allocate_line <- mkDWire(False);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_line_valid_mav_allocate_line <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_line_valid_mav_allocate_line <- mkDWire(False);

    //ma_perform_release
    Wire#(Bool) wr_v_fb_line_valid_ma_perform_release <- mkDWire(False);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_line_valid_ma_perform_release <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_line_valid_ma_perform_release <- mkDWire(False);
    
    
    //ma_fill_from_memory
    Wire#(Bool) wr_v_fb_line_valid_ma_fill_from_memory <- mkDWire(False);
    Wire#(Bit#(TLog#(fbsize))) wr_fb_index_v_fb_line_valid_ma_fill_from_memory <- mkDWire(0);
    Wire#(Bool) wr_valid_v_fb_line_valid_ma_fill_from_memory <- mkDWire(False);
    
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
    Reg#(Bit#(TMax#(1,TLog#(blocksize))))           rg_next_bank<- mkReg(0);

    
    /*doc:var: variable indicating the fillbuffer is full*/
    Bool fb_full = (all(isTrue, readVReg(v_fb_addr_valid)));
    /*doc:var: variable indicating the fillbuffer is empty*/
    Bool fb_empty=!(any(isTrue, readVReg(v_fb_addr_valid)));

  `ifdef ovl_assert
    let defaults = mkOVLDefaults;  
    defaults.min = 0;
    defaults.max = fromInteger(valueOf(fbsize)-1);
    defaults.severity_level = OVL_FATAL;    
    AssertTest_IFC#(Bit#(TLog#(fbsize))) fbhead_range_check <- bsv_assert_range(defaults);
    AssertTest_IFC#(Bit#(TLog#(fbsize))) fbtail_range_check <- bsv_assert_range(defaults);
    let defaults1 = mkOVLDefaults;  
    defaults1.severity_level = OVL_FATAL;
    AssertTest_IFC#(Bool)                fbenables_check    <- bsv_assert_always(defaults1);

    /*doc:rule: */
    rule rl_ovl_fbhead(True);
      fbhead_range_check.test(rg_fbhead);
      fbtail_range_check.test(rg_fbtail);
      fbenables_check.test(rg_fb_enables != '1);
    endrule
  `endif

    rule rl_print_stats;
      `logLevel( dcache, 3, $format("[%2d]DCACHE: fb_full:%b fb_empty:%b fbhead:%d fbtail:%d\
 fbheadvalid:%b", id, fb_full, fb_empty, rg_fbhead, rg_fbtail, v_fb_line_valid[rg_fbhead]))
    endrule

    Rules re_v_fb_data = emptyRules;
  for(Integer i = 0; i < valueOf(fbsize); i = i+1) begin
    Rules rg_connect_ena_data = emptyRules;
    for (Integer j=0;j < valueOf(blocksize); j = j+1) begin
    Rules rg_connect_ena_data_j = (rules
      rule connect_v_fb_data((wr_valid_v_fb_data_mav_allocate_line  
              && (wr_fb_index_v_fb_data_mav_allocate_line == fromInteger(i))) 
          ||  (wr_valid_v_fb_data_ma_fill_from_memory 
              && (wr_fb_index_v_fb_data_ma_fill_from_memory == fromInteger(i)) 
              && (wr_block_v_fb_data_ma_fill_from_memory == fromInteger(j))) 
        `ifdef dcache_ecc
          || (wr_valid_v_fb_data_mav_perform_sec  
              && (wr_fb_index_v_fb_data_mav_perform_sec == fromInteger(i)))
        `endif
          ||  (wr_valid_v_fb_data_ma_from_storebuffer 
              && (wr_fb_index_v_fb_data_ma_from_storebuffer == fromInteger(i)) 
              && (wr_block_v_fb_data_ma_from_storebuffer == fromInteger(j)))
              );
        v_fb_data[i][j] <= ((wr_v_fb_data_mav_allocate_line[j] & signExtend(pack(wr_valid_v_fb_data_mav_allocate_line 
                              && (wr_fb_index_v_fb_data_mav_allocate_line == fromInteger(i)))))
                          | (wr_v_fb_data_ma_fill_from_memory & signExtend(pack(wr_valid_v_fb_data_ma_fill_from_memory 
                              && (wr_fb_index_v_fb_data_ma_fill_from_memory == fromInteger(i)) 
                              && (wr_block_v_fb_data_ma_fill_from_memory == fromInteger(j)))))
                        `ifdef dcache_ecc
                          | (wr_v_fb_data_mav_perform_sec[j] & signExtend(pack(wr_valid_v_fb_data_mav_perform_sec 
                              && (wr_fb_index_v_fb_data_mav_perform_sec == fromInteger(i)))))
                        `endif
                          | (wr_v_fb_data_ma_from_storebuffer & signExtend(pack(wr_valid_v_fb_data_ma_from_storebuffer 
                              && (wr_fb_index_v_fb_data_ma_from_storebuffer == fromInteger(i)) 
                              && (wr_block_v_fb_data_ma_from_storebuffer == fromInteger(j)))))
                            );
      endrule
    endrules);
    rg_connect_ena_data = rJoinConflictFree(rg_connect_ena_data_j,rg_connect_ena_data);
    end
    re_v_fb_data = rJoinConflictFree(rg_connect_ena_data, re_v_fb_data);
  end

  addRules(re_v_fb_data);

  Rules re_v_fb_dirty = emptyRules;
  for(Integer i = 0; i < valueOf(fbsize); i = i+1) begin
    Rules rg_connect_ena_data_dirty = (rules
    rule connect_v_fb_dirty((wr_valid_v_fb_dirty_mav_allocate_line
                              && (wr_fb_index_v_fb_dirty_mav_allocate_line == fromInteger(i)))
                           || (wr_valid_v_fb_dirty_ma_from_storebuffer
                              && (wr_fb_index_v_fb_dirty_ma_from_storebuffer == fromInteger(i) )));
      v_fb_dirty[i] <= ((wr_v_fb_dirty_mav_allocate_line & signExtend(pack(wr_valid_v_fb_dirty_mav_allocate_line
      && (wr_fb_index_v_fb_dirty_mav_allocate_line == fromInteger(i))))) 
                      | (wr_v_fb_dirty_ma_from_storebuffer & signExtend(pack(wr_valid_v_fb_dirty_ma_from_storebuffer
                      && (wr_fb_index_v_fb_dirty_ma_from_storebuffer == fromInteger(i) )))));
    endrule
    endrules);
    re_v_fb_dirty = rJoinConflictFree(rg_connect_ena_data_dirty, re_v_fb_dirty);
  end

addRules(re_v_fb_dirty);

Rules re_v_fb_addr_valid = emptyRules;
for(Integer i = 0; i < valueOf(fbsize); i = i+1) begin
  Rules rg_connect_ena_data_addr_valid = (rules
  rule connect_v_fb_addr_valid((wr_valid_v_fb_addr_valid_mav_allocate_line
                            && (wr_fb_index_v_fb_addr_valid_mav_allocate_line == fromInteger(i)))
                         || (wr_valid_v_fb_addr_valid_ma_perform_release
                            && (wr_fb_index_v_fb_addr_valid_ma_perform_release == fromInteger(i) )));
    v_fb_addr_valid[i] <= ((wr_v_fb_addr_valid_mav_allocate_line && wr_valid_v_fb_addr_valid_mav_allocate_line
    && (wr_fb_index_v_fb_addr_valid_mav_allocate_line == fromInteger(i))) 
                        || (wr_v_fb_addr_valid_ma_perform_release && wr_valid_v_fb_addr_valid_ma_perform_release
                        && (wr_fb_index_v_fb_addr_valid_ma_perform_release == fromInteger(i) )));
  endrule
  endrules);
  re_v_fb_addr_valid = rJoinConflictFree(rg_connect_ena_data_addr_valid, re_v_fb_addr_valid);
end

addRules(re_v_fb_addr_valid);

Rules re_v_fb_line_valid = emptyRules;
for(Integer i = 0; i < valueOf(fbsize); i = i+1) begin
  Rules rg_connect_ena_data_line_valid = (rules
  rule connect_v_fb_line_valid((wr_valid_v_fb_line_valid_mav_allocate_line
                            && (wr_fb_index_v_fb_line_valid_mav_allocate_line == fromInteger(i)))
                         || (wr_valid_v_fb_line_valid_ma_fill_from_memory
                            && (wr_fb_index_v_fb_line_valid_ma_fill_from_memory == fromInteger(i) ))
                        || (wr_valid_v_fb_line_valid_ma_perform_release
                            && (wr_fb_index_v_fb_line_valid_ma_perform_release == fromInteger(i) )));
    v_fb_line_valid[i] <= ((wr_v_fb_line_valid_mav_allocate_line && wr_valid_v_fb_line_valid_mav_allocate_line
    && (wr_fb_index_v_fb_line_valid_mav_allocate_line == fromInteger(i)) ) 
                          || (wr_v_fb_line_valid_ma_fill_from_memory &&  wr_valid_v_fb_line_valid_ma_fill_from_memory
                          && (wr_fb_index_v_fb_line_valid_ma_fill_from_memory == fromInteger(i) ) ) 
                          || (wr_v_fb_line_valid_ma_perform_release && wr_valid_v_fb_line_valid_ma_perform_release
                          && (wr_fb_index_v_fb_line_valid_ma_perform_release == fromInteger(i) ) ));
  endrule
  endrules);
  re_v_fb_line_valid = rJoinConflictFree(rg_connect_ena_data_line_valid, re_v_fb_line_valid);
end

addRules(re_v_fb_line_valid);

Rules re_v_fb_err = emptyRules;
for(Integer i = 0; i < valueOf(fbsize); i = i+1) begin
  Rules rg_connect_ena_data_err = (rules
  rule connect_v_fb_err((wr_valid_v_fb_err_mav_allocate_line
                            && (wr_fb_index_v_fb_err_mav_allocate_line == fromInteger(i)))
                         || (wr_valid_v_fb_err_ma_fill_from_memory
                            && (wr_fb_index_v_fb_err_ma_fill_from_memory == fromInteger(i) )));
    v_fb_err[i] <= ( (wr_v_fb_err_mav_allocate_line & signExtend(pack(wr_valid_v_fb_err_mav_allocate_line
    && (wr_fb_index_v_fb_err_mav_allocate_line == fromInteger(i))) )) 
                    | (wr_v_fb_err_ma_fill_from_memory & signExtend(pack(wr_valid_v_fb_err_ma_fill_from_memory
                    && (wr_fb_index_v_fb_err_ma_fill_from_memory == fromInteger(i) ))) ) );
  endrule
  endrules);
  re_v_fb_err = rJoinConflictFree(rg_connect_ena_data_err, re_v_fb_err);
end

addRules(re_v_fb_err);

    method mv_fbfull = fb_full;
    method mv_fbempty = fb_empty;
    method mv_fbhead_valid = v_fb_line_valid[rg_fbhead];
    method ActionValue#(Bit#(TLog#(fbsize))) mav_allocate_line( 
                                    Bool                                      from_ram,
                                    Bit#(TMul#(TMul#(wordsize,8),blocksize))  dataline,
                                    Bit#(paddr)                               address,
                                    Bit#(1)                                   dirty );

      Bit#(1) _temp = pack(from_ram);

      // v_fb_addr_valid[rg_fbtail] <= True;
      wr_valid_v_fb_addr_valid_mav_allocate_line <= True;
      wr_fb_index_v_fb_addr_valid_mav_allocate_line <= rg_fbtail;
      wr_v_fb_addr_valid_mav_allocate_line <= True;
      
      
      v_fb_addr[rg_fbtail] <= address;

      // v_fb_dirty[rg_fbtail] <= _temp & dirty;
      wr_v_fb_dirty_mav_allocate_line <= _temp & dirty;
      wr_fb_index_v_fb_dirty_mav_allocate_line <= rg_fbtail;
      wr_valid_v_fb_dirty_mav_allocate_line <= True;

      // v_fb_line_valid[rg_fbtail] <= from_ram;
      wr_valid_v_fb_line_valid_mav_allocate_line <= True;
      wr_fb_index_v_fb_line_valid_mav_allocate_line<=rg_fbtail;
      wr_v_fb_line_valid_mav_allocate_line <= from_ram;

      // v_fb_err[rg_fbtail] <= 0;
      wr_v_fb_err_mav_allocate_line <= 0;
      wr_fb_index_v_fb_err_mav_allocate_line <= rg_fbtail;
      wr_valid_v_fb_err_mav_allocate_line <= True;
      
      wr_valid_v_fb_data_mav_allocate_line <= True;
      wr_fb_index_v_fb_data_mav_allocate_line <= rg_fbtail;
      for (Integer i = 0; i< v_blocksize ; i = i + 1) begin
        //v_fb_data[rg_fbtail][i] <= dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth];
        wr_v_fb_data_mav_allocate_line[i] <= dataline[i*v_respwidth+v_respwidth-1:i*v_respwidth];
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
                                      Bit#(TMax#(1,TLog#(blocksize)))              init_bank);
      Bit#(TMax#(1,TLog#(blocksize))) lv_current_bank = rg_fb_enables == 0? init_bank: rg_next_bank;
      //v_fb_data[fbindex][lv_current_bank] <= mem_resp.data;
      wr_v_fb_data_ma_fill_from_memory <= mem_resp.data;
      wr_fb_index_v_fb_data_ma_fill_from_memory <= fbindex;
      wr_block_v_fb_data_ma_fill_from_memory <= lv_current_bank;
      wr_valid_v_fb_data_ma_fill_from_memory <= True ;
      rg_next_bank <= lv_current_bank + ((v_blocksize>1)?1:0);
      if(mem_resp.last) begin
        // v_fb_line_valid[fbindex] <= True;
        wr_v_fb_line_valid_ma_fill_from_memory <= True;
        wr_fb_index_v_fb_line_valid_ma_fill_from_memory <= fbindex;
        wr_valid_v_fb_line_valid_ma_fill_from_memory <= True;
        rg_fb_enables <= 0;
      end
      else
        rg_fb_enables[lv_current_bank] <= 1;

      // v_fb_err[fbindex] <= pack(mem_resp.err);
      wr_v_fb_err_ma_fill_from_memory <= pack(mem_resp.err);
      wr_fb_index_v_fb_err_ma_fill_from_memory <= fbindex;
      wr_valid_v_fb_err_ma_fill_from_memory <= True;

      `logLevel( dcache, 0, $format("[%2d]DCACHE: FB FILL MemResp :",id,fshow(mem_resp)))
      `logLevel(dcache , 0, $format("[%2d]DCACHE: FB FILL fbaddr:%h fbindex:%d initbank:%d currbank:%d fben:%b", id,
        v_fb_addr[fbindex], fbindex, init_bank, lv_current_bank, rg_fb_enables))
    endmethod
    method Action ma_from_storebuffer(Bit#(respwidth) mask, Bit#(respwidth)  dataword,
                                      Bit#(TLog#(fbsize)) fbindex, Bit#(paddr) address);

      Bit#(TMax#(1,blockbits)) block_offset = {address[v_blockbits+v_wordbits-1:v_wordbits]};
      //v_fb_data[fbindex][block_offset] <= (v_fb_data[fbindex][block_offset]& ~mask) | (mask & dataword);
      wr_v_fb_data_ma_from_storebuffer <= (v_fb_data[fbindex][block_offset]& ~mask) | (mask & dataword);
      wr_fb_index_v_fb_data_ma_from_storebuffer <= fbindex;
      wr_block_v_fb_data_ma_from_storebuffer <= block_offset;
      wr_valid_v_fb_data_ma_from_storebuffer <= True;

      // v_fb_dirty[fbindex] <= 1;
      wr_v_fb_dirty_ma_from_storebuffer <= 1;
      wr_fb_index_v_fb_dirty_ma_from_storebuffer <= fbindex;
      wr_valid_v_fb_dirty_ma_from_storebuffer <= True;

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

      // v_fb_addr_valid[rg_fbhead] <= False;
      wr_valid_v_fb_addr_valid_ma_perform_release <= True;
      wr_v_fb_addr_valid_ma_perform_release <= False;
      wr_fb_index_v_fb_addr_valid_ma_perform_release <= rg_fbhead;

      // v_fb_line_valid[rg_fbhead] <= False;
      wr_v_fb_line_valid_ma_perform_release <= False;
      wr_fb_index_v_fb_line_valid_ma_perform_release <= rg_fbhead;
      wr_valid_v_fb_line_valid_ma_perform_release <= True;
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
      Bool lv_wordhit = (lv_linevalid || lv_hit_in_fill);
      return PollingResponse{err: lv_err, word:lv_selected_word, waymask: lv_hitvector,
                             line_hit: unpack(|lv_hitvector), word_hit: lv_wordhit};
    endmethod
  `ifdef dcache_ecc
    method Action mav_perform_sec (Bit#(TLog#(fbsize)) fbindex,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) stored_parity,
                        Bit#(TMul#(blocksize,TAdd#(2,TLog#(TMul#(8,wordsize))))) check_parity);

      wr_valid_v_fb_data_mav_perform_sec <= True;
      wr_fb_index_v_fb_data_mav_perform_sec <= fbindex;
      for (Integer i = 0; i< v_blocksize; i = i + 1) begin
        Bit#(ecc_size) _stparity = stored_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
        Bit#(ecc_size) _chparity = check_parity[i*v_ecc_size+v_ecc_size-1:i*v_ecc_size];
        let _data = fn_ecc_correct(_chparity, _stparity, v_fb_data[fbindex][i]);
        // v_fb_data[fbindex][i] <= _data;
        wr_v_fb_data_mav_perform_sec[i] <= _data;
      end
    endmethod
  `endif
  endmodule : mk_fillbuffer_v2

  typedef struct{
    Bit#(addr) address;
    Bit#(TMul#(8,wordsize)) data;
    Bit#(3) size;
    Bit#(esize) epoch;
  `ifndef atomic
    Bit#(1) access;
  `else
    Bit#(2) access;
    Bit#(5) atomic_op;
  `endif
  `ifdef supervisor
    Bit#(`vaddr) vaddr;
    Bool is_ptw_req;
  `endif
  } IoEntry#(numeric type addr, numeric type wordsize, numeric type esize) deriving(Bits, FShow, Eq);
  interface Ifc_iobuffer#(numeric type addr, 
                          numeric type wordsize,
                          numeric type iosize,
                          numeric type esize);
    method Bool mv_io_full;
    method Bool mv_io_empty;
    method Bool mv_io_head_valid;
    method Action ma_increment_head;
    method Action ma_commit_io;
    method IoEntry#(addr,wordsize,esize) mv_io_head;
    method Action ma_allocate_io ( IoEntry#(addr, wordsize, esize) entry);
  endinterface:Ifc_iobuffer

  /*doc:module: */
  (*conflict_free="ma_allocate_io, ma_increment_head"*)
  (*conflict_free="ma_commit_io, ma_allocate_io"*)
  module mk_iobuffer#(parameter Bit#(32) id)(Ifc_iobuffer#(addr, wordsize, iosize, esize));
   
    let v_iosize = valueOf(iosize);
    Vector#( iosize, Reg#(IoEntry#(addr, wordsize, esize)) ) v_iobuffer <- replicateM(mkRegA(unpack(0)));
    Vector#( iosize, Reg#(Bool))                      v_iobuff_valid <- replicateM(mkRegA(False));
    Vector#( iosize, Reg#(Bool))                      v_iobuff_commit <- replicateM(mkRegA(False));

    /*doc:reg: */
    Reg#(Bit#(TLog#(iosize))) rg_head <- mkRegA(0);
    /*doc:reg: */
    Reg#(Bit#(TLog#(iosize))) rg_tail <- mkRegA(0);
    /*doc:var: variable to indicate that the storebuffer is full*/
    Bool iobuff_full = (all(isTrue, readVReg(v_iobuff_valid)));
    /*dov:var: variable to indicate that the storebuffer is empty*/
    Bool iobuff_empty=!(any(isTrue, readVReg(v_iobuff_valid)));
    rule rl_print_stats;
      `logLevel( dcache, 3, $format("[%2d]DCACHE: io_full:%b io_empty:%b iohead:%d iotail:%d", 
        id, iobuff_full, iobuff_empty, rg_head, rg_tail))
    endrule

  `ifdef sva_assert
    property headOverflow();
      (rg_head <= fromInteger(v_iosize-1)) |-> True;
    endproperty
    property tailOverflow();
      (rg_tail <= fromInteger(v_iosize-1)) |-> True;
    endproperty
    property fullEmpty;
      iobuff_empty && iobuff_full |-> False;
    endproperty
    always assert property(headOverflow()) else $fatal(0, "FAIL: rg_head overflowed for IO Buffer");
    always assert property(tailOverflow()) else $fatal(0, "FAIL: rg_tail overflowed in IO Buffer");
    always assert property(fullEmpty()) else $fatal(0, "FAIL: iobuff is empty and full at the same time");
  `endif

    method mv_io_full = iobuff_full;
    method mv_io_empty = iobuff_empty;
    method mv_io_head_valid = v_iobuff_valid[rg_head] && v_iobuff_commit[rg_head];

    method Action ma_allocate_io ( IoEntry#(addr, wordsize, esize) entry);
    `ifdef ASSERT
      dynamicAssert(!v_iobuff_valid[rg_tail],"Valid IO Entry Allocated");
    `endif
      v_iobuffer[rg_tail] <= entry;
      v_iobuff_valid[rg_tail] <= True;
      if(rg_tail == fromInteger(v_iosize -1))
        rg_tail <= 0;
      else
        rg_tail <= rg_tail + 1;
    `ifdef supervisor
      if (entry.is_ptw_req)
        v_iobuff_commit[rg_tail] <= True;
      else
    `endif
        v_iobuff_commit[rg_tail] <= False;

      `logLevel( dcache, 0, $format("DCACHE: Allocating IO Buff tail:%d",rg_tail, fshow(entry)))
    endmethod: ma_allocate_io

    method Action ma_increment_head;
      v_iobuff_valid[rg_head] <= False;
      if (rg_head == fromInteger(v_iosize-1))
        rg_head <= 0;
      else
        rg_head <= rg_head + 1;
    endmethod: ma_increment_head

    method mv_io_head = v_iobuffer[rg_head];
    method Action ma_commit_io;
      v_iobuff_commit[rg_head]<=True;
    endmethod:ma_commit_io

      
  endmodule:mk_iobuffer
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
    Bit#(2) size;
  } Storebuffer#(numeric type a, numeric type d, numeric type e, numeric type f) 
    deriving(Bits, FShow, Eq);
  


  interface Ifc_storebuffer#( numeric type addr, 
                              numeric type wordsize, 
                              numeric type esize,
                              numeric type sbsize, 
                              numeric type fbsize);

    method ActionValue#(Tuple2#(Bit#(TMul#(wordsize,8)),Bit#(TMul#(wordsize,8)))) 
                                                            mav_check_sb_hit (Bit#(addr) phyaddr);
    method Action ma_allocate_entry (Bit#(addr) address, Bit#(TMul#(8,wordsize)) data, 
      Bit#(esize) epochs, Bit#(TLog#(fbsize)) fbindex, Bit#(2) size
          `ifdef atomic ,Bool atomic, Bit#(TMul#(8,wordsize)) read_data, Bit#(5) atomic_op `endif );
    //method Action ma_commit_store;
    method Action ma_commit_store(Bit#(TLog#(sbsize)) sbid);
    method Action ma_increment_head;
    method Storebuffer#(addr, TMul#(wordsize,8), esize, TLog#(fbsize)) mv_sb_head;
    method Bool mv_sb_full;
    method Bool mv_sb_empty;
    method Bool mv_sb_busy;
    method Bool mv_sb_head_commit;
    method Bool mv_sb_head_valid;
    method Bit#(TLog#(sbsize)) mv_sb_curr_tail;
  endinterface : Ifc_storebuffer

  /*(*conflict_free="ma_allocate_entry, ma_increment_head"*)
  (*conflict_free="ma_commit_store, ma_increment_head"*)*/
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
    let v_sbsize   = valueOf(sbsize);
   
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
    
    // ma_allocate_entry
    Wire#(Bool) wr_v_sb_valid_ma_allocate_entry <- mkDWire(False);
    Wire#(Bit#(TLog#(sbsize))) wr_sb_index_v_sb_valid_ma_allocate_entry <- mkDWire(0);
    Wire#(Bool) wr_valid_v_sb_valid_ma_allocate_entry <- mkDWire(False);

    // ma_increment_head
    Wire#(Bool) wr_v_sb_valid_ma_increment_head <- mkDWire(False);
    Wire#(Bit#(TLog#(sbsize))) wr_sb_index_v_sb_valid_ma_increment_head <- mkDWire(0);
    Wire#(Bool) wr_valid_v_sb_valid_ma_increment_head <- mkDWire(False);
    
    /*doc:reg: A vector of registers indicating if the particular store buffer entry is valid or
     not*/
    Vector#(sbsize, Array#(Reg#(Bool))) v_sb_commit <- replicateM(mkCReg(2,False));
    /*doc:reg: A vector of registers holding all the meta data of stores being presented by the core
     * to the cache*/
    Vector#(sbsize, Reg#(Storebuffer#(addr,dataword,esize,TLog#(fbsize)))) v_sb_meta 
                                                                    <- replicateM(mkReg(unpack(0)));
    /*doc:reg: A vector of wires holding the head of stores being presented by the core
     * to the cache*/
     Wire#(Storebuffer#(addr,dataword,esize,TLog#(fbsize))) wr_sb_meta <- mkDWire(unpack(0));

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
    ConfigReg#(Bool) rg_sb_busy <- mkConfigReg(False);
  
  `ifdef sva_assert
    property headOverflow();
      rg_head >=0 && rg_head < fromInteger(v_sbsize-1) |-> True;
    endproperty
    property tailOverflow();
      rg_tail >=0 && rg_tail < fromInteger(v_sbsize-1) |-> True;
    endproperty
    property fullEmpty;
      sb_empty && sb_full |-> False;
    endproperty
    always assert property(headOverflow()) else $fatal(0, "FAIL: rg_head overflowed for IO Buffer");
    always assert property(tailOverflow()) else $fatal(0, "FAIL: rg_tail overflowed in IO Buffer");
    always assert property(fullEmpty()) else $fatal(0, "FAIL: iobuff is empty and full at the same time");
  `endif
    
    rule rl_print_stats;
      `logLevel( dcache, 3, $format("[%2d]DCACHE: sb_full:%b sb_empty:%b sbhead:%d sbtail:%d", 
        id, sb_full, sb_empty, rg_head, rg_tail))
    endrule

    rule assign_head;
      wr_sb_meta <= v_sb_meta[rg_head];
    endrule 

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

  Rules re_v_sb_valid = emptyRules;
for(Integer i = 0; i < valueOf(sbsize); i = i+1) begin
  Rules rg_connect_ena_data_valid = (rules
  rule connect_v_sb_valid((wr_valid_v_sb_valid_ma_allocate_entry
                            && (wr_sb_index_v_sb_valid_ma_allocate_entry == fromInteger(i)))
                         || (wr_valid_v_sb_valid_ma_increment_head
                            && (wr_sb_index_v_sb_valid_ma_increment_head == fromInteger(i) )));
    v_sb_valid[i] <= (  (wr_v_sb_valid_ma_allocate_entry && wr_valid_v_sb_valid_ma_allocate_entry && (wr_sb_index_v_sb_valid_ma_allocate_entry == fromInteger(i)))
                      || (wr_v_sb_valid_ma_increment_head && wr_valid_v_sb_valid_ma_increment_head && (wr_sb_index_v_sb_valid_ma_increment_head == fromInteger(i) )));
  endrule
  endrules);
  re_v_sb_valid = rJoinConflictFree(rg_connect_ena_data_valid, re_v_sb_valid);
end

addRules(re_v_sb_valid);

    method ActionValue#(Tuple2#(Bit#(dataword),Bit#(dataword))) mav_check_sb_hit (Bit#(addr) phyaddr);

      Vector#(sbsize, Bit#(dataword)) storemask;
      Vector#(sbsize, Bit#(dataword)) data_values;

      Bit#(TSub#(addr, wordbits)) wordaddr = truncateLSB(phyaddr);
      for (Integer i = 0; i< valueOf(sbsize); i = i + 1) begin
        data_values[i] = v_sb_meta[i].data;
        Bit#(TSub#(addr, wordbits)) compareaddr = truncateLSB(v_sb_meta[i].addr);
        storemask[i] = v_sb_meta[i].mask & duplicate(pack(compareaddr == wordaddr && v_sb_valid[i]));
      end

      // See if the following can also be written as a vector function
      storemask[rg_tail] = ~storemask[rg_tail-1] & storemask[rg_tail];

      for (Integer i = 0; i<valueOf(sbsize); i = i + 1) begin
        data_values[i] = storemask[i] & data_values[i];
      end
      Bit#(3) zeros = 0;
      Bit#(TAdd#(wordbits,3)) shiftamt = {phyaddr[v_wordbits - 1:0], zeros};
      for (Integer i = 0; i<valueOf(sbsize); i = i + 1) begin
        `logLevel( dcache, 0, $format("[%2d]SB: Lookup[%2d]:valid: %b ",id,i,v_sb_valid[i],fshow(v_sb_meta[i])))
      end
  
      return tuple2(fold(fn_OR,storemask)>>shiftamt,fold(fn_OR,data_values)>>shiftamt);
    endmethod

    method Action ma_allocate_entry (Bit#(addr) address, Bit#(dataword) data, 
          Bit#(esize) epochs, Bit#(TLog#(fbsize)) fbindex, Bit#(2) size
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
    `ifdef ASSERT
      dynamicAssert(!v_sb_valid[rg_tail],"Valid SB Entry Allocated");
    `endif
      // v_sb_valid[rg_tail] <= True;
      wr_valid_v_sb_valid_ma_allocate_entry <= True;
      wr_v_sb_valid_ma_allocate_entry <= True;
      wr_sb_index_v_sb_valid_ma_allocate_entry <= rg_tail;

      let _s = Storebuffer{addr:address, data: data, epoch: epochs, fbindex: fbindex,
                                      mask: storemask, size:truncate(size)};
      v_sb_meta[rg_tail] <= _s;
      if(rg_tail == fromInteger(v_sbsize -1))
        rg_tail <= 0;
      else
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

    method Action ma_commit_store(Bit#(TLog#(sbsize)) sbid);
    `ifdef ASSERT
      dynamicAssert(v_sb_valid[rg_head],"SB commit to invalid entry.");
      dynamicAssert(!v_sb_commit[sbid][0],"SB commit to already commit entry.");
    `endif
      v_sb_commit[sbid][0]<=True;
    endmethod:ma_commit_store

    method Action ma_increment_head;
      // v_sb_valid[rg_head] <= False;
      wr_v_sb_valid_ma_increment_head <= False;
      wr_sb_index_v_sb_valid_ma_increment_head <= rg_head;
      wr_valid_v_sb_valid_ma_increment_head <= True;

      v_sb_commit[rg_head][1] <= False;
      if (rg_head == fromInteger(v_sbsize-1))
        rg_head <= 0;
      else
        rg_head <= rg_head + 1;
      `logLevel( dcache, 0, $format("SB: incrementing HEAD to :%d",rg_head+1))
    endmethod: ma_increment_head

    method Storebuffer#(addr, TMul#(wordsize,8), esize, TLog#(fbsize)) mv_sb_head;
      return wr_sb_meta;
    endmethod:mv_sb_head

    method mv_sb_busy = rg_sb_busy;
    method mv_sb_head_commit = v_sb_commit[rg_head][1]; 
    method mv_sb_head_valid = v_sb_valid[rg_head];
    method mv_sb_curr_tail = rg_tail;
  endmodule : mk_storebuffer

  typedef struct{
    Bool release_ready;
    Bit#(TMul#(blocksize,TMul#(wordsize,8))) line;
    Bit#(paddr) address;
  } StoreRelease#(numeric type wordsize, 
                  numeric type blocksize, 
                  numeric type paddr) deriving(Bits, Eq);

  instance FShow#(StoreRelease#(w,b,p));
    function Fmt fshow(StoreRelease#(w,b,p) value);
      Fmt result = ?;
      if (value.release_ready)
        result = $format("StoreRelease ready [%h]=%h",value.address,value.line);
      else 
        result = $format("StoreRelease not ready");
      return result;
    endfunction: fshow
  endinstance

  typedef struct{
    Bit#(a) address;
    Bit#(d) data;
    Bit#(e) epoch;
    Bit#(l) lbindex;
    Bit#(d) mask;
    Bit#(2) size;
  } SBEntry#(numeric type a, numeric type d, numeric type e, numeric type l) deriving(Bits, Eq);

  instance FShow#(SBEntry#(a,d,e,l));
    function Fmt fshow (SBEntry#(a,d,e,l) value);
      Fmt result = ?;
      result = $format("SBEntry: {%s@[%h]=%h(mask:%h) to lb@[%d]",size2str({1'b0,value.size}),value.address,
        value.data,value.mask, value.lbindex);
      return result;
    endfunction: fshow
  endinstance

  typedef struct{
    Bool hit;
    Bit#(TMul#(wordsize,8)) word;
    Bit#(TLog#(lbsize)) lbindex;
  } SBLookup#(numeric type wordsize, numeric type lbsize) deriving (Bits, Eq, FShow);

  interface Ifc_storebuffer_v2#( numeric type paddr,
                                numeric type wordsize,
                                numeric type blocksize,
                                numeric type esize,
                                numeric type sbsize,
                                numeric type lbsize);
    method Action ma_allocate_line (Bit#(paddr) address, Bit#(TMul#(blocksize,TMul#(wordsize,8))) line);
    method Action ma_allocate_store (Bit#(paddr) address, Bit#(TMul#(wordsize,8)) data,
                                    Bit#(esize) epochs, Bit#(2) size , Bit#(TLog#(lbsize)) lbindex);
    method ActionValue#(SBLookup#(wordsize, lbsize)) mav_core_lookup (Bit#(paddr) address);
    method Bool mv_sb_empty;
    method Bool mv_sb_full;
    method Bool mv_line_empty;
    method Bool mv_line_full;
    method Bool mv_sb_busy;
    //method Action ma_commit_store(Bit#(esize) epoch);
    method Action ma_commit_store(Tuple2#(Bit#(esize),Bit#(1)) c);
    method Bit#(TLog#(lbsize)) mv_lb_tail;
    method Bit#(TLog#(sbsize)) mv_sb_tail;
    method StoreRelease#(wordsize, blocksize, paddr) mv_release_head;
    method Action ma_release();
  `ifdef atomic
    method Action ma_perform_atomic(Bit#(5) atomic_op, Bit#(TMul#(8,wordsize)) rdata, 
      Bit#(TMul#(8,wordsize)) wdata, Bit#(TLog#(sbsize)) sbindex);
  `endif
  endinterface:Ifc_storebuffer_v2

  (*conflict_free="ma_allocate_store, ma_commit_store"*)
  (*conflict_free="ma_allocate_line, ma_commit_store"*)
  (*conflict_free="ma_release, ma_allocate_line"*)
  (*conflict_free="ma_commit_store, rl_commit_from_sb_to_line"*)
  (*conflict_free="ma_allocate_line, rl_commit_from_sb_to_line"*)
  (*conflict_free="ma_allocate_store, rl_commit_from_sb_to_line"*)
  module mk_storebuffer_v2#(parameter Bit#(32) id, parameter Bool onehot)
    (Ifc_storebuffer_v2#(paddr, wordsize, blocksize, esize, sbsize, lbsize))
    provisos( Log#(wordsize,wordbits),
              Log#(blocksize,blockbits),
              Mul#(wordsize,8,dataword),
              Add#(blockbits, wordbits,_a),
              Add#(tagbits, _a, paddr),
              Log#(lbsize, lbbits),
              Mul#(TMul#(wordsize,8), blocksize, linebits),
              Add#(b__, wordbits, TMul#(wordbits, 2)),
              Add#(1, c__, sbsize),
              Mul#(16, a__, dataword),
              Mul#(32, d__, dataword),

              Add#(1, e__, TLog#(TAdd#(1, lbsize))),
              Mul#(2, f__, wordsize),
              Mul#(4, g__, wordsize),
              Add#(h__, 32, dataword)


            );

    let v_wordbits = valueOf(wordbits);
    let v_sbsize   = valueOf(sbsize);
    let v_lbsize   = valueOf(lbsize);
    let v_blockbits = valueOf(blockbits);

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
          'b0111:return op2;
          default:return op1;
        endcase
    endfunction
  `endif

    /*doc:reg: A vector of registers indicating if the particular store buffer entry is valid or
     not*/
    Vector#( sbsize, ConfigReg#(Bool) ) v_sb_valid <- replicateM(mkConfigRegA(False)) ;
    /*doc:reg: A vector of registers indicating if the particular store buffer entry is valid or
     not*/
    //Vector#(sbsize, ConfigReg#(Bool)) v_sb_commit <- replicateM(mkConfigRegA(False));
    Vector#(sbsize, Array#(Reg#(Bool))) v_sb_commit <- replicateM(mkCRegA(2,False));
    /*doc:reg: A vector of registers holding all the meta data of stores being presented by the core
     * to the cache*/
    Vector#( sbsize, ConfigReg#(SBEntry#(paddr, dataword, esize, lbbits))) v_sb_meta <- replicateM(mkConfigRegU);
    /*doc:reg: Register to point to the head of the store buffers. Points to the entry that needs to
     * be allotted to a new store request*/
    Reg#(Bit#(TLog#(sbsize))) rg_sb_head <- mkRegA(0);
    /*doc:reg: Register to point to the oldest entry that was allotted in the storebuffer and that
     * needs to the be committed first*/
    Reg#(Bit#(TLog#(sbsize))) rg_sb_tail <- mkRegA(0);

    Vector#( lbsize, ConfigReg#(Bool) ) v_lb_valid <- replicateM(mkConfigRegA(False)) ;
    Vector#( lbsize, ConfigReg#(Bit#(linebits))) v_lb_line <- replicateM(mkConfigRegU);
    Vector#( lbsize, ConfigReg#(Bit#(tagbits))) v_lb_tag <- replicateM(mkConfigRegU);
    Vector#( lbsize, Vector#(sbsize, Array#(Reg#(Bit#(1))))) v_lb_sbpending <-replicateM(replicateM(mkCRegA(2,0)));
    /*doc:reg: Register to point to the head of the store buffers. Points to the entry that needs to
     * be allotted to a new store request*/
    Reg#(Bit#(TLog#(lbsize))) rg_lb_head <- mkRegA(0);
    /*doc:reg: Register to point to the oldest entry that was allotted in the storebuffer and that
     * needs to the be committed first*/
    Reg#(Bit#(TLog#(lbsize))) rg_lb_tail <- mkRegA(0);
    ConfigReg#(Bool) rg_sb_busy <- mkConfigRegA(False);

    /*doc:var: variable to indicate that the storebuffer is full*/
    Bool sb_full = (all(isTrue, readVReg(v_sb_valid)));
    /*dov:var: variable to indicate that the storebuffer is empty*/
    Bool sb_empty=!(any(isTrue, readVReg(v_sb_valid)));
    /*doc:var: variable to indicate that the linebuffer is full*/
    Bool lb_full = (all(isTrue, readVReg(v_lb_valid)));
    /*dov:var: variable to indicate that the linebuffer is empty*/
    Bool lb_empty=!(any(isTrue, readVReg(v_lb_valid)));
    rule rl_print_stats;
      `logLevel( dcache, 3, $format("[%2d]DCACHE: lb_full:%b lb_empty:%b sb_full:%b sb_empty:%b", 
        id, lb_full, lb_empty, sb_full, sb_empty))
    endrule
  `ifdef atomic
    /*doc:reg: */
    Reg#(Bit#(dataword)) rg_atomic_readword <- mkRegA(0);
    /*doc:reg: */
    Reg#(Bit#(dataword)) rg_atomic_writeword <- mkRegA(0);
    /*doc:reg: */
    Reg#(Bit#(5)) rg_atomic_op <- mkRegA(0);
    /*doc:reg: */
    Reg#(Bit#(TLog#(sbsize))) rg_atomic_tail <- mkRegA(0);

    /*doc:rule: */
    rule rl_perform_atomic(rg_sb_busy);
      let _newdata = fn_atomic_op(rg_atomic_op, rg_atomic_writeword, rg_atomic_readword);
    `ifdef RV64
      if(rg_atomic_op[4] == 0)begin
        _newdata = duplicate(_newdata[31:0]);
      end
    `endif
      let _s = v_sb_meta[rg_atomic_tail];
      _s.data = _newdata;
      v_sb_meta[rg_atomic_tail] <= _s;
      rg_sb_busy <= False;
      `logLevel( dcache, 0, $format("[%2d]SB: Performing Atomic: Op:%b Wdata:%h Rdata:%h Result:%h",
        id, rg_atomic_op, rg_atomic_writeword, rg_atomic_readword, _newdata))
    endrule:rl_perform_atomic
  `endif

    /*doc:rule: */
    rule rl_commit_from_sb_to_line(v_sb_valid[rg_sb_head] && v_sb_commit[rg_sb_head][1] && 
      v_lb_valid[v_sb_meta[rg_sb_head].lbindex] && !rg_sb_busy);
    `ifdef ASSERT
      dynamicAssert(v_lb_valid[v_sb_meta[rg_sb_head].lbindex] ,"SB: commiting STORE to an empty line");
    `endif
      v_sb_valid[rg_sb_head] <= False;
      v_sb_commit[rg_sb_head][1] <= False;
      let sb = v_sb_meta[rg_sb_head];
      `logLevel( dcache, 0, $format("[%2d]SB: Commiting Store from entry@[%2d]: ",id, rg_sb_head, fshow(sb)))

      Bit#(TMax#(1,blockbits)) block_offset = {sb.address[v_blockbits+v_wordbits-1:v_wordbits]};
      Vector#(blocksize, Bit#(dataword)) lv_word_arr = unpack(v_lb_line[sb.lbindex]);
      lv_word_arr[block_offset] = (lv_word_arr[block_offset] & ~sb.mask) | (sb.mask & sb.data);
      v_lb_sbpending[sb.lbindex][rg_sb_head][1] <= 0;
      v_lb_line[sb.lbindex] <= pack(lv_word_arr);
      if (rg_sb_head == fromInteger(v_sbsize - 1))
        rg_sb_head <= 0;
      else
        rg_sb_head <= rg_sb_head + 1;
    endrule:rl_commit_from_sb_to_line
   
    method mv_lb_tail = rg_lb_tail;
    method mv_sb_tail = rg_sb_tail;
    method mv_line_full = lb_full;
    method mv_line_empty = lb_empty;
    method mv_sb_full = sb_full;
    method mv_sb_empty = sb_empty;
    method mv_sb_busy = rg_sb_busy;
    method Action ma_allocate_line (Bit#(paddr) address, Bit#(TMul#(blocksize,TMul#(wordsize,8))) line)
      if (!rg_sb_busy);
    `ifdef ASSERT
      dynamicAssert(!lb_full, "SB: Allocating line when its full");
      dynamicAssert(!v_lb_valid[rg_lb_tail], "SB: Allocating line which is already valid");
    `endif
      v_lb_line[rg_lb_tail] <= line;
      v_lb_tag[rg_lb_tail] <= truncateLSB(address);
      v_lb_valid[rg_lb_tail] <= True; 
      if(rg_lb_tail == fromInteger(v_lbsize -1))
        rg_lb_tail <= 0;
      else
        rg_lb_tail <= rg_lb_tail + 1;
      `logLevel( dcache, 0, $format("[%2d]SB: Allocating Line@[%2d]",id,rg_lb_tail))
    endmethod:ma_allocate_line

    method Action ma_allocate_store (Bit#(paddr) address, Bit#(TMul#(wordsize,8)) data,
        Bit#(esize) epochs, Bit#(2) size , Bit#(TLog#(lbsize)) lbindex) if (!rg_sb_busy);
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
    `ifdef ASSERT
      dynamicAssert(!v_sb_valid[rg_sb_tail],"Valid SB Entry Allocated");
      dynamicAssert(!v_sb_commit[rg_sb_tail][1],"Commit field of SB is already set");
    `endif
      v_sb_valid[rg_sb_tail] <= True;
      //v_sb_commit[rg_sb_tail] <= False;
      let _s = SBEntry{address:address, data: data, epoch: epochs, lbindex: lbindex,
                                      mask: storemask, size:truncate(size)};
      v_sb_meta[rg_sb_tail] <= _s;
      `logLevel( dcache, 0, $format("[%2d]SB: SB Allocation@[%d]:",id,rg_sb_tail,fshow(_s)))

      Bit#(sbsize) sbindex_OH= pack(toOInt(rg_sb_tail));
      v_lb_sbpending[lbindex][rg_sb_tail][0] <= 1;
      if(rg_sb_tail == fromInteger(v_sbsize -1))
        rg_sb_tail <= 0;
      else
        rg_sb_tail <= rg_sb_tail + 1;
    endmethod: ma_allocate_store

  `ifdef atomic 
    method Action ma_perform_atomic(Bit#(5) atomic_op, Bit#(TMul#(8,wordsize)) rdata, 
        Bit#(TMul#(8,wordsize)) wdata, Bit#(TLog#(sbsize)) sbindex)if(!rg_sb_busy);

      rg_sb_busy <= True;
      rg_atomic_tail <= sbindex;
      rg_atomic_readword <= rdata;
      rg_atomic_writeword <= wdata;
      rg_atomic_op <= atomic_op;
      `logLevel( dcache, 0, $format("[%2d]SB: initiating atomic op sbindex:%d",id,sbindex))
    endmethod:ma_perform_atomic
  `endif

    method ActionValue#(SBLookup#(wordsize, lbsize)) mav_core_lookup (Bit#(paddr) address);
      Bit#(lbsize) hit_arr;
      Bit#(blockbits) lv_blocknum = address[v_blockbits+v_wordbits-1:v_wordbits];
      Vector#(lbsize, Bit#(dataword)) lv_word_arr;
      for(Integer i = 0; i < v_lbsize; i = i + 1) begin
        Vector#(blocksize,Bit#(dataword)) _line = unpack(v_lb_line[i]);
        lv_word_arr[i] = _line[lv_blocknum];
        hit_arr[i] = pack(v_lb_valid[i] && v_lb_tag[i]==truncateLSB(address));
      end
      Bit#(lbbits) lv_index = fromOInt(unpack(hit_arr));
      Bit#(TMul#(8,wordsize)) lv_word;
      if(onehot) begin
        lv_word = select(lv_word_arr,unpack(hit_arr));
      end
      else begin
        lv_word = lv_word_arr[lv_index];
      end
    `ifdef ASSERT
      dynamicAssert(countOnes(hit_arr)<=1, "SB: Multiple lines indicate a hit");
    `endif

      Vector#(sbsize, Bit#(dataword)) storemask;
      Vector#(sbsize, Bit#(dataword)) data_values;

      Bit#(TSub#(paddr, wordbits)) wordaddr = truncateLSB(address);
      for (Integer i = 0; i< valueOf(sbsize); i = i + 1) begin
        data_values[i] = v_sb_meta[i].data;
        Bit#(TSub#(paddr, wordbits)) compareaddr = truncateLSB(v_sb_meta[i].address);
        storemask[i] = v_sb_meta[i].mask & duplicate(pack(compareaddr == wordaddr && v_sb_valid[i]));
      end

      // See if the following can also be written as a vector function
      storemask[rg_sb_tail] = ~storemask[rg_sb_tail-1] & storemask[rg_sb_tail];

      for (Integer i = 0; i<valueOf(sbsize); i = i + 1) begin
        data_values[i] = storemask[i] & data_values[i];
      end
      for (Integer i = 0; i<valueOf(sbsize); i = i + 1) begin
        `logLevel( dcache, 0, $format("[%2d]SB: Lookup[%2d]:valid: %b ",id,i,v_sb_valid[i],fshow(v_sb_meta[i])))
      end
      let {lv_storemask, lv_storedata} = tuple2(fold(fn_OR,storemask),fold(fn_OR,data_values));
      lv_word = (lv_word & ~lv_storemask) | (lv_storemask & lv_storedata);
      `logLevel( dcache, 0, $format("[%2d]DCACHE: SB lookup response:%h",id,lv_word))
      return SBLookup{hit: unpack(|hit_arr), word: lv_word, lbindex: lv_index};
    endmethod:mav_core_lookup

    method StoreRelease#(wordsize, blocksize, paddr) mv_release_head;
      Bit#(sbsize) sbpending;
      for (Integer i = 0; i<valueOf(sbsize); i = i + 1) begin
        sbpending[i] = v_lb_sbpending[rg_lb_head][i][1];
      end
      let temp = StoreRelease{line: v_lb_line[rg_lb_head], 
                              address: {v_lb_tag[rg_lb_head],'d0}, 
                              release_ready: !unpack(|sbpending) &&
                                                     v_lb_valid[rg_lb_head] };
      return temp;
    endmethod: mv_release_head

    method Action ma_release;
      Bit#(sbsize) sbpending;
      for (Integer i = 0; i<valueOf(sbsize); i = i + 1) begin
        sbpending[i] = v_lb_sbpending[rg_lb_head][i][1];
      end
    `ifdef ASSERT
      dynamicAssert(v_lb_valid[rg_lb_head] && !unpack(|sbpending),"SB release of empty line");
    `endif
      if (rg_lb_head == fromInteger(v_lbsize - 1))
        rg_lb_head <= 0;
      else
        rg_lb_head <= rg_lb_head + 1;
      v_lb_valid[rg_lb_head] <= False;
    endmethod:ma_release

    method Action ma_commit_store(Tuple2#(Bit#(esize),Bit#(1)) c);
      let {epoch, sbid} = c;
    `ifdef ASSERT
      dynamicAssert(v_sb_valid[sbid] ,"SB: commiting STORE from empty entry");
      dynamicAssert(!v_sb_commit[sbid][0] ,"SB: commit field not False");
    `endif
      `logLevel( dcache, 0, $format("[%2d]SB: making entry ready for commit [%2d]: ",id, sbid))
      let sb = v_sb_meta[sbid];
      if (epoch == sb.epoch)
        v_sb_commit[sbid][0] <= True;
      else begin
        v_sb_valid[sbid] <= False;
        v_sb_commit[sbid][0] <= False;
        v_lb_sbpending[sb.lbindex][sbid][1] <= 0;
        if (rg_sb_head == fromInteger(v_sbsize - 1))
          rg_sb_head <= 0;
        else
          rg_sb_head <= rg_sb_head + 1;
      end
    endmethod: ma_commit_store
  endmodule: mk_storebuffer_v2

`ifdef dcache_2rw
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
  (*synthesize*)
  module mkdcache_fb_v2#(parameter Bit#(32) id)(Ifc_fillbuffer_v2#(`dfbsize, `dwords, `dblocks, `dsets, `paddr,  `dbuswidth));
    let ifc();
    mk_fillbuffer_v2#(id,unpack(`dcache_onehot)) _temp(ifc);
    return (ifc);
  endmodule : mkdcache_fb_v2
//  (*synthesize*)
  module mkstorebuffer#(parameter Bit#(32) id)(Ifc_storebuffer#(`paddr, `dwords, `desize, `dsbsize, `dfbsize));
    let ifc();
    mk_storebuffer#(id) _temp(ifc);
    return (ifc);
  endmodule: mkstorebuffer
`elsif dcache_1r1w
  //(*synthesize*)
  module mkdcache_tag#(parameter Bit#(32) id)(Ifc_tagram1r1w#(`dwords, `dblocks, `dsets, `dways, `paddr));
    let ifc();
    mk_tagram1r1w _temp(id,ifc);
    return (ifc);
  endmodule : mkdcache_tag
  //(*synthesize*)
  module mkdcache_data#(parameter Bit#(32) id)(Ifc_dataram1r1w#(`dwords, `dblocks, `dsets, `dways));
    let ifc();
    mk_dataram1r1w#(id,unpack(`dcache_onehot)) _temp(ifc);
    return (ifc);
  endmodule : mkdcache_data
  (*synthesize*)
  module mkstorebuffer#(parameter Bit#(32) id)(Ifc_storebuffer_v2#(`paddr, `dwords, `dblocks, `desize, `dsbsize, `dlbsize));
    let ifc();
    mk_storebuffer_v2#(id, False) _temp(ifc);
    return (ifc);
  endmodule: mkstorebuffer
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
  (*synthesize*)
  module mkdcache_fb_v2#(parameter Bit#(32) id)(Ifc_fillbuffer_v2#(`dfbsize, `dwords, `dblocks, `dsets, `paddr,  `dbuswidth));
    let ifc();
    mk_fillbuffer_v2#(id,unpack(`dcache_onehot)) _temp(ifc);
    return (ifc);
  endmodule : mkdcache_fb_v2
(*synthesize*)
  module mkstorebuffer#(parameter Bit#(32) id)(Ifc_storebuffer#(`paddr, `dwords, `desize, `dsbsize, `dfbsize));
    let ifc();
    mk_storebuffer#(id) _temp(ifc);
    return (ifc);
  endmodule: mkstorebuffer
`endif
  (*synthesize*)
  module mkiobuffer#(parameter Bit#(32) id)(Ifc_iobuffer#(`paddr, `dwords, `dibsize, `desize));
    let ifc();
    mk_iobuffer#(id) _temp(ifc);
    return (ifc);
  endmodule: mkiobuffer

endpackage

