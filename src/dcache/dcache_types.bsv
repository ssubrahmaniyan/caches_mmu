/*
see LICENSE.incore
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package dcache_types;
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
                      numeric type esize) deriving (Bits, Eq, FShow);
  typedef struct{
    Bit#(addr)    address;
    Bit#(8)       burst_len;
    Bit#(3)       burst_size;
    Bool          io;
  } DCache_mem_readreq#( numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(data)    data;
    Bool          last;
    Bool          err;
  } DCache_mem_readresp#(numeric type data) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(addr)      address;
    Bit#(data)      data;
    Bit#(8)         burst_len;
    Bit#(3)         burst_size;
    Bool            io;
  } DCache_mem_writereq#(numeric type addr, numeric type data) deriving(Bits, Eq, FShow);

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
  } DMem_core_response#( numeric type data, numeric type esize) deriving (Bits, Eq, FShow);
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
