/*
see LICENSE.iitm

Author : Sujay Pandit, Nitya Ranganathan
Email id : contact.sujaypandit@gmail.com, nitya.ranganathan@gmail.com
Details : ITLB types

--------------------------------------------------------------------------------------------------
*/

package itlb_types;
  import Vector :: * ;
  `include "common_tlb.defines"
  `include "icache_parameters.bsv"

    // --------------------------------- Instruction TLB types -----------------------------------//

    // ITLB tag
    typedef struct{
      TLB_permissions permissions;
      Bit#(`vpnsize) vpn;
      Bit#(`asidwidth) asid;
      Bit#(TMul#(TSub#(`varpages,1), `subvpn)) pagemask;
    } ITLB_tag deriving(Bits, FShow, Eq);

    // ITLB data
    typedef struct{
      Bit#(`ppnsize) ppn;
    } ITLB_data deriving(Bits, FShow, Eq);

    typedef struct{
        Bit#(addr)        address;
        Bool              sfence;
    } ITLB_core_request# (numeric type addr) deriving(Bits, Eq, FShow);
    
    typedef struct{
        Bool              hit;
        Bit#(addr)        address;
        Bool              trap;
        Bit#(`causesize)  cause;
    } ITLB_core_response# (numeric type addr) deriving(Bits, Eq, FShow);

    
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
endpackage

