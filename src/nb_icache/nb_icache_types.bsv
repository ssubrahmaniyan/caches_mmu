package nb_icache_types;
`include "icache_parameters.bsv"

    function Bit#(`setbits) fn_extract_set(Bit#(`paddr) address);
        return address[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset];
    endfunction
    //
    typedef struct{
        Bool cache_busy;
        Bit#(TLog#(`mhb_width)) mshr_status;
    } ICache_status deriving(Bits,Eq,FShow);
    //
    typedef struct{
        Bool valid;
        Bit#(`reqid_width) req_id;
        Bit#(`vaddr) vaddr;
        Bool fence;
        Bool sfence;
        Bool flush;
        Bool prefetch;
    } ICache_core_request deriving(Bits,Eq,FShow);
    //
    typedef struct{
        Bool valid;
        Bit#(`reqid_width) req_id;
        Bit#(`fetch_width) packet;
        Bool trap;
        Bit#(2) excp_type;
    } ICache_core_response deriving(Bits,Eq,FShow);
    //
    typedef struct{
        Bool valid;
        Bit#(`paddr) paddr;
        Bit#(`reqid_width) rid;
        Bool is_io; // io or cacheable
        Bool burst;
    } Mem_request deriving(Bits,Eq,FShow);
    typedef struct{
        Bool valid;
        Bit#(`ibus_width)    data;
        Bool          last;
        Bool          err;
        Bit#(TLog#(`mhb_size)) mhb_id;
    } Mem_response deriving(Bits, Eq, FShow);
    //
    typedef struct{
        Bool valid;
        Bit#(`vaddr) vaddr;
        Bit#(2) access;
    } PTW_request deriving(Bits,Eq,FShow);
    //
    typedef struct{
        Bool valid;
        Bit#(`xlen) pte;
        Bit#(2) levels; // (2 bits for sv39)
        Bool trap;
        Bit#(2) excp_type;
    } PTW_response deriving(Bits,Eq,FShow);
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
        ICache_core_request core_req;
        Bool is_io;
    } Stage1 deriving(Bits,Eq,FShow);
    //
    typedef struct{
        ICache_core_request core_req;
        Bit#(`paddr) paddr;
        //TODO tag response
        //TODO data response
        //TODO replacement response
        //TODO status response
        //TODO tlb response
    } Stage2 deriving(Bits,Eq,FShow);
    //
    typedef struct{
        ICache_core_request core_req;
        Bit#(`paddr) paddr;
        Bool is_io;
    } Replay deriving(Bits,Eq,FShow);

endpackage