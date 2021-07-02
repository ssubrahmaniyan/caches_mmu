package nb_icache_types;
  import Vector :: * ;
  `include "common_tlb.defines"
  `include "icache_parameters.bsv"
  `include "itlb_types.bsv"

    typedef struct{
        Bool cache_busy;
        Bit#(TLog#(`mhb_size)) mshr_status;
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
        Bit#(2) excp_type;
    } ICache_core_response deriving(Bits,Eq,FShow);
    
    typedef struct{
        Bool valid;
        Bit#(`paddr) paddr;
        Bit#(TLog#(`mhb_size)) mhb_id;
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
    
    typedef struct{
        Bool tag_hit;
        Bit#(`reqid_width) req_id;
        Bit#(`paddr) paddr;
        Bit#(`blocksize) data;
        Bit#(TLog#(`numways)) replacement_way;
        Vector#(`numways,Bit#(1)) way_valid;
    } Stage2 deriving(Bits,Eq,FShow);
    
    typedef struct{
        ICache_core_request core_req;
        Bit#(`paddr) paddr;
        Bool is_io;
    } Replay deriving(Bits,Eq,FShow);

    // -------------------------------------------------------------------------------------------//
    // 

    function Bit#(`setbits) fn_extract_set(Bit#(`paddr) address);
        return address[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset];
    endfunction
    //
//    function ITLB_core_request#(`vaddr) fn_get_tlb_packet(ICache_core_request req);
//        return ITLB_core_request{   address   : req.vaddr,
//                                    sfence    : req.sfence
//                                    };
    endfunction
endpackage

