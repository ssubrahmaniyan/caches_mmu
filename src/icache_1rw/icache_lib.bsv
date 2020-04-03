/*
see LICENSE.incore
see LICENSE.iitm

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
    `endif
      Vector#(ways, Bit#(tagbits)) lv_tags;
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_tags[i] = v_tags[i].read_response;
      `ifdef icache_ecc
        sed[i] = v_tags[i].read_sed;
        ded[i] = v_tags[i].read_ded;
      `endif
      end
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
    `endif
      if (onehot) begin
        Vector#(ways, Bit#(respwidth)) lv_words = ?;
        Vector#(ways, Bit#(linewidth)) lv_lines = ?;
      `ifdef icache_ecc
        Vector#(ways, Bit#(blocksize))     lv_lines_sed = ?;
        Vector#(ways, Bit#(blocksize))     lv_lines_ded = ?;
      `endif
        for (Integer i = 0; i< v_ways ; i = i + 1) begin
          lv_words[i] = truncate(v_data[i].read_response >> block_offset);
          lv_lines[i] = v_data[i].read_response;
        `ifdef icache_ecc
          lv_lines_sed[i] = v_data[i].read_sed;
          lv_lines_ded[i] = v_data[i].read_ded;
        `endif
        end
        lv_selected_word = select(lv_words,unpack(wayselect));
        lv_selected_line = select(lv_lines,unpack(wayselect));
      `ifdef icache_ecc
        lv_line_sed = select(lv_lines_sed,unpack(wayselect));
        lv_line_ded = select(lv_lines_ded,unpack(wayselect));
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
          `endif
          end
        end
      end

      return DataResponse{`ifdef icache_ecc 
                            line_sed: lv_line_sed, line_ded:lv_line_ded, 
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
  endinterface

  (*conflict_free="ma_perform_release,mav_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, mav_allocate_line"*)
  (*conflict_free="ma_fill_from_memory, ma_perform_release"*)
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

    function Bool isTrue(Bool a);
      return a;
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
  endmodule
  (*synthesize*)
  module mkicache_tag#(parameter Bit#(32) id)(Ifc_tagram#(`iwords, `iblocks, `isets, `iways, `paddr));
    let ifc();
    mk_tagram1rw _temp(id,ifc);
    return (ifc);
  endmodule
  (*synthesize*)
  module mkicache_data#(parameter Bit#(32) id)(Ifc_dataram#(`iwords, `iblocks, `isets, `iways));
    let ifc();
    mk_dataram1rw#(id,unpack(`icache_onehot)) _temp(ifc);
    return (ifc);
  endmodule
  (*synthesize*)
  module mkicache_fb_v2#(parameter Bit#(32) id)(Ifc_fillbuffer_v2#(`ifbsize, `iwords, `iblocks, `isets, `paddr,  `ibuswidth));
    let ifc();
    mk_fillbuffer_v2#(id,unpack(`icache_onehot)) _temp(ifc);
    return (ifc);
  endmodule

endpackage

