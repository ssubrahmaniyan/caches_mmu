package nb_icache_types;
  import Vector :: * ;
  import itlb_types ::*;
  `include "icache_parameters.bsv"

    typedef struct{
        Bool cache_busy;
        Bit#(TAdd#(1,TLog#(`mhb_size))) mshr_status;
    } ICache_status deriving(Bits,Eq,FShow);
    
    typedef struct{
        Bool valid;
        Bit#(`reqid_width) req_id;
        Bit#(`vaddr) vaddr;
        Bool fence;
        Bool sfence;
        Bool flush;
        Bool prefetch;
    } ICache_core_request deriving(Bits,Eq,FShow);
    
    typedef struct{
        Bool valid;
        Bit#(`reqid_width) req_id;
        Bit#(`fetch_width) packet;
        Bool trap;
        Bit#(`causesize) cause;
    } ICache_core_response deriving(Bits,Eq,FShow);
    
    typedef struct{
        Bool valid;
        Bit#(`fetch_width) packet;
        Bool trap;
        Bit#(`causesize) cause;
    } CRQ_core_response deriving(Bits,Eq,FShow);
    
    typedef struct{
        Bool valid;
        Bit#(`paddr) paddr;
        Bit#(TLog#(`mhb_size)) mhb_id;
        Bit#(8)       burst_len;
        Bit#(3)       burst_size;
        Bool          io;
    } Mem_request deriving(Bits,Eq,FShow);

    typedef struct{
        Bool valid;
        Bit#(`ibuswidth)    data;
        Bool          last;
        Bool          err;
        Bit#(TLog#(`mhb_size)) mhb_id;
    } Mem_response deriving(Bits, Eq, FShow);

    //
    typedef struct{
        Bool valid;
        Bool hit_mhb;
        Bool free_secondary;
        Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth))) mhb_index;
        Bool fb_valid;
        Bit#(`wordsize) fb_data;
    } MHB_lookup_resp deriving(Bits, Eq,FShow);
    //    
    typedef struct{
        Bool tag_hit;
        Bit#(`reqid_width) req_id;
        Bit#(`paddr) paddr;
        Bit#(`wordsize) data;
        Bit#(TLog#(`numways)) replacement_way;
        Vector#(`numways,Bit#(1)) way_valid;
    } Stage2 deriving(Bits,Eq,FShow);
    
    typedef struct{
        ICache_core_request core_req;
        Bit#(`paddr) paddr;
        Bool is_io;
    } Replay deriving(Bits,Eq,FShow);
    //
    function Bit#(`setbits) fn_extract_set(Bit#(`vaddr) address);
        return address[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset];
    endfunction
    //
endpackage

