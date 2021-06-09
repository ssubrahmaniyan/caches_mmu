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
        Bit#(`reqid_size) req_id;
    } ICache_mem_readresp deriving(Bits, Eq, FShow);

endpackage