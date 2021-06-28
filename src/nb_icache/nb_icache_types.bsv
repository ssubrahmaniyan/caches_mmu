package nb_icache_types;
`include "icache_parameters.bsv"
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
        Vector#(`nuwmays,Bit#(1)) way_valid;
    } Stage2 deriving(Bits,Eq,FShow);
    
    typedef struct{
        ICache_core_request core_req;
        Bit#(`paddr) paddr;
        Bool is_io;
    } Replay deriving(Bits,Eq,FShow);
    // --------------------------------- Instruction TLB types -----------------------------------//
    typedef struct{
        Bit#(addr)        address;
        Bool              sfence;
    }ITLB_core_request# (numeric type addr) deriving(Bits, Eq, FShow);
    
    typedef struct{
        Bit#(addr)        address;
        Bool              trap;
        Bit#(`causesize)  cause;
    }ITLB_core_response# (numeric type addr) deriving(Bits, Eq, FShow);

    
    // --------------------------------- PTwalk types -----------------------------------//
    typedef struct{
        Bit#(addr)        address;
        Bit#(2)           access;
    }PTWalk_tlb_request#(numeric type addr) deriving(Bits, Eq, FShow);
    
    typedef struct{
        Bit#(addr)            pte;
        Bit#(TLog#(level))    levels;
        Bool                  trap;
        Bit#(`causesize)      cause;
    }PTWalk_tlb_response#(numeric type addr, numeric type level) deriving(Bits, Eq, FShow);
    
    typedef struct{
        Bit#(addr)            address;
        Bit#(3)               size;
        Bit#(2)               access;
        Bool                  ptwalk_trap;
        Bool                  ptwalk_req;
        Bit#(`causesize)      cause;
    }PTwalk_mem_request# (numeric type addr) deriving(Bits, Eq, FShow);
    // -------------------------- TLB Structs ----------------------------------------------------//
    typedef struct {
        Bool v;					//valid
        Bool r;					//allow reads
        Bool w;					//allow writes
        Bool x;					//allow execute(instruction read)
        Bool u;					//allow supervisor
        Bool g;					//global page
        Bool a;					//accessed already
        Bool d;					//dirty
    } TLB_permissions deriving(Eq, FShow);
    
    instance Bits#(TLB_permissions,8);
        /*doc:func: */
        function Bit#(8) pack (TLB_permissions p);
        return {pack(p.d), pack(p.a), pack(p.g), pack(p.u), 
                pack(p.x), pack(p.w), pack(p.r), pack(p.v)};
        endfunction
        /*doc:func: */
        function TLB_permissions unpack (Bit#(8) perms);
            return TLB_permissions { v : unpack(perms[0]),
                                                            r : unpack(perms[1]),
                                                            w : unpack(perms[2]),
                                                            x : unpack(perms[3]),
                                                            u : unpack(perms[4]),
                                                            g : unpack(perms[5]),
                                                            a : unpack(perms[6]),
                                                            d : unpack(perms[7])};
        endfunction
    endinstance
    
    function TLB_permissions bits_to_permission(Bit#(8) perms);
            return TLB_permissions { v : unpack(perms[0]),
                                                            r : unpack(perms[1]),
                                                            w : unpack(perms[2]),
                                                            x : unpack(perms[3]),
                                                            u : unpack(perms[4]),
                                                            g : unpack(perms[5]),
                                                            a : unpack(perms[6]),
                                                            d : unpack(perms[7])};
        endfunction
    // -------------------------------------------------------------------------------------------//
    // 
    function Bit#(`setbits) fn_extract_set(Bit#(`paddr) address);
        return address[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset];
    endfunction
    //
    function ITLB_core_request#(`vaddr) fn_get_tlb_packet(ICache_core_request req);
        return ITLB_core_request{   address   : req.vaddr,
                                    sfence    : req.sfence
                                    };
    endfunction
endpackage