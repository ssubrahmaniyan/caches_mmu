/*
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package dcache_types;
  `include "dcache.defines"
  function String access2str (Bit#(2) access);
    case(access)
      0: return "L";
      1: return "S";
      2: return "A";
      default: return "UNKNOWN ACCESS";
    endcase
  endfunction

  function String size2str (Bit#(3) size);
    case(size)
      'b000: return "B";
      'b001: return "H";
      'b010: return "W";
      'b011: return "D";
      'b100: return "BU";
      'b101: return "HU";
      'b110: return "WU";
    endcase
  endfunction

  function String amo2str (Bit#(5) atomic_op);
    String postfix = atomic_op[4]==0?".W":".D";
    case(atomic_op[3:0])
      'b0011:return "AMOSWAP"+postfix;
      'b0000:return "AMOADD"+postfix;
      'b0010:return "AMOXOR"+postfix;
      'b0110:return "AMOAND"+postfix;
      'b0100:return "AMOOR"+postfix;
      'b1100:return "AMOMINU"+postfix;
      'b1110:return "AMOMAXU"+postfix;
      'b1000:return "AMOMIN"+postfix;
      'b1010:return "AMOMAX"+postfix;
      default:return "UNKNOWN OP";
    endcase
  endfunction
  
  function String cause2str (Bit#(`causesize) cause);
    case (cause)
      `Inst_addr_misaligned  : return "Instruction-Address-Misaligned-Trap";
      `Inst_access_fault     : return "Instruction-Access-Fault-Trap";
      `Load_addr_misaligned  : return "Load-Address-Misaligned-Trap";
      `Load_access_fault     : return "Load-Access-Fault-Trap";
      `Store_addr_misaligned : return "Store-Address-Misaligned-Trap";
      `Store_access_fault    : return "Store-Access-Fault-Trap";  
      `Inst_pagefault        : return "Instruction-Page-Fault-Trap";  
      `Load_pagefault        : return "Load-Page-Fault-Trap";  
      `Store_pagefault       : return "Store-Page-Fault-Trap";  
      default: return "UNKNOWN CAUSE VALUE";
    endcase
  endfunction

// ---------------------- Data Cache types ---------------------------------------------//
  typedef struct{
    Bit#(addr)    address;
    Bool          fence;
    Bit#(esize)   epochs;
    Bit#(2)       access;
    Bit#(3)       size;
    Bit#(data)    data;
  `ifdef atomic
    Bit#(5)       atomic_op;
  `endif
  `ifdef supervisor
    Bool          ptwalk_req;
  `endif
  } DCache_core_request#( numeric type addr,
                      numeric type data,
                      numeric type esize) deriving (Bits, Eq);

  instance FShow#(DCache_core_request#(addr, data, esize));
    /*doc:func: */
    function Fmt fshow (DCache_core_request#(addr, data, esize) value );
      Fmt result = $format("{va:%h",value.address);
      if (value.fence)
        result = result + $format(" is a Fence op");
      else if (value.access !=2 `ifdef supervisor && !value.ptwalk_req `endif )
        result = result + $format(" is a %s%s op", access2str(value.access), size2str(value.size));
    `ifdef atomic
      else if (value.access == 2 `ifdef supervisor && !value.ptwalk_req `endif )
        result = result + $format(" is a %s op",amo2str(value.atomic_op));
    `endif
      
      if (value.access != 0)
        result = result + $format(", data:%h",value.data);
    `ifdef supervisor
      if (value.ptwalk_req)
        result = result + $format(" coming from PTWALK");
    `endif
      else 
        result = result + $format(" coming from CORE");
    return result + $format("}"); 
    endfunction
  endinstance

  typedef struct{
    Bit#(addr)    address;
    Bit#(8)       burst_len;
    Bit#(3)       burst_size;
  } DCache_mem_readreq#( numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(data)    data;
    Bool          last;
    Bool          err;
  } DCache_mem_readresp#(numeric type data) deriving(Bits, Eq);

  instance FShow#(DCache_mem_readresp#(data));
    /*doc:func: */
    function Fmt fshow (DCache_mem_readresp#(data) value);
      Fmt result= $format("{data:%h",value.data);
      if (value.last)
        result = result + $format(" Last");
      else
        result = result + $format(" NotLast");
      if (value.err)
        result = result + $format(" Error");
      else
        result = result + $format(" NoError");
      return result + $format("}");
    endfunction
  endinstance

  typedef struct{
    Bit#(addr)      address;
    Bit#(data)      data;
    Bit#(8)         burst_len;
    Bit#(3)         burst_size;
  } DCache_mem_writereq#(numeric type addr, numeric type data) deriving(Bits, Eq);

  instance FShow#(DCache_mem_writereq#(addr, data));
    function Fmt fshow(DCache_mem_writereq#(addr, data) value);
      Fmt result = $format("{pa:%h, data:\n",value.address);
      for (Integer i = 0; i<valueOf(data)/`dbuswidth; i = i + 1) begin
        Bit#(64) _data = value.data[i*`dbuswidth+`dbuswidth-1:i*`dbuswidth];
        result = result + $format(" \t\t\t\t\t- %h\n",_data);
      end
      return result + $format("}");
    endfunction
  endinstance

  typedef struct{
    Bit#(addr) address;
    Bool read_write;
    Bit#(data) data;
    Bit#(3) size;
  } DCache_io_req#(numeric type addr, numeric type data) deriving(Bits, FShow, Eq);
  
  typedef struct{
    Bit#(data) data;
    Bool error;
  } DCache_io_response#(numeric type data) deriving(Bits, FShow, Eq);

  typedef Bool DCache_mem_writeresp;

  // ---------------------- Types for DMem and Core interaction ------------------------------- //
  typedef struct{
    Bit#(addr)    address;
    Bit#(esize)   epochs;
    Bit#(3)       size;
    Bool          fence;
    Bit#(2)       access;
    Bit#(data)    writedata;
  `ifdef atomic
    Bit#(5)       atomic_op;
  `endif
  `ifdef supervisor
    Bool          sfence;
    Bool          ptwalk_req;
    Bool          ptwalk_trap;
  `endif
  } DMem_request#(numeric type addr,
                  numeric type data,
                  numeric type esize ) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(data)        word;
    Bool              trap;
    Bit#(`causesize)  cause;
    Bit#(esize)       epochs;
    Bool              is_io;
    Bool              entry_alloc;
    Bit#(TLog#(`dsbsize)) sb_id;
  } DMem_core_response#( numeric type data, numeric type esize) deriving (Bits, Eq);

  instance FShow#(DMem_core_response#(data,esize));
    /*doc:func: */
    function Fmt fshow (DMem_core_response#(data, esize) value);
      Fmt result;
      if (value.trap) begin
        result = $format("{%s with mtval:%h",cause2str(value.cause),value.word);
      end
      else begin
        result = $format("{data:%h",value.word);
        if (value.is_io)
          result = result + $format(" is IO");
        if (value.entry_alloc)
          result = result + $format(" and entry allocated");
      end
      return result + $format("}");
    endfunction
  endinstance

  // -------------------------------------------------------------------------------------------//

// --------------------------- Common Structs ---------------------------------------------------//
  typedef enum {Hit=1, Miss=0, None=2} RespState deriving(Eq,Bits,FShow);
// -------------------------------------------------------------------------------------------//
`ifdef dcache_ecc
  typedef struct{
    Bit#(a) address;
    Bit#(w) way;
  } ECC_dcache_tag#(numeric type a, numeric type w) deriving(Bits, FShow, Eq);

  typedef struct{
    Bit#(a) address;
    Bit#(b) banks;
    Bit#(w) way;
  } ECC_dcache_data#(numeric type a, numeric type w, numeric type b) deriving(Bits, FShow, Eq);


  typedef struct{
    Bit#(TLog#(`dsets)) index; 
    Bit#(TLog#(`dways)) way;
    Bit#(TLog#(`dblocks)) banks;
    Bit#(TMul#(`dwords,8)) data;
    Bool read_write; // False: read True: write
    Bool tag_data; // False: tag True: daa
  } DRamAccess deriving (Bits, Eq, FShow);
`endif
endpackage
