package nb_icache_types;
`include "icache_parameters.bsv"

    function Bit#(`setbits) fn_extract_set(Bit#(`paddr) address);
        return address[`setbits+`wordoffset+`byteoffset-1:`wordoffset+`byteoffset];
    endfunction
    //
    typedef struct{
        Bit#(`ibus_width)    data;
        Bool          last;
        Bool          err;
        Bit#(TLog#(`mhb_size)) mhb_id;
    } ICache_mem_readresp deriving(Bits, Eq, FShow);
    //
    typedef struct{
        Bool valid;
        Bool hit_mhb;
        Bool free_secondary;
        Bit#(TAdd#(TLog#(`mhb_size),TLog#(`imshr_depth))) mhb_index;
        Bool fb_valid;
        Bit#(`wordsize) fb_data;
    } MHB_lookup_resp deriving(Bits, Eq,FShow);

endpackage