/*
see LICENSE.incore
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package icache_types;
// ---------------------- Data Cache types ---------------------------------------------//
  typedef struct{
    Bit#(addr)    address;
    Bool          fence;
    Bit#(esize)   epochs;
  } ICache_core_request#( numeric type addr,
                          numeric type esize) deriving (Bits, Eq, FShow);
  typedef struct{
    Bit#(addr)    address;
    Bit#(8)       burst_len;
    Bit#(3)       burst_size;
    Bool          io;
  } ICache_mem_readreq#( numeric type addr) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(data)    data;
    Bool          last;
    Bool          err;
  } ICache_mem_readresp#(numeric type data) deriving(Bits, Eq, FShow);


  // ---------------------- Types for IMem and Core interaction ------------------------------- //
  typedef struct{
    Bit#(addr)    address;
    Bit#(esize)   epochs;
    Bool          fence;
  `ifdef supervisor
    Bool          sfence;
  `endif
  } IMem_core_request#(numeric type addr,
                  numeric type esize ) deriving(Bits, Eq, FShow);

  typedef struct{
    Bit#(data)        word;
    Bool              trap;
    Bit#(`causesize)  cause;
    Bit#(esize)       epochs;
  } IMem_core_response#( numeric type data, numeric type esize) deriving (Bits, Eq, FShow);
  // -------------------------------------------------------------------------------------------//

// --------------------------- Common Structs ---------------------------------------------------//
  typedef enum {Hit=1, Miss=0, None=2} RespState deriving(Eq,Bits,FShow);
// -------------------------------------------------------------------------------------------//
`ifdef icache_ecc
  typedef struct{
    Bit#(a) address;
    Bit#(w) way;
  } ECC_icache_tag#(numeric type a, numeric type w) deriving(Bits, FShow, Eq);

  typedef struct{
    Bit#(a) address;
    Bit#(b) banks;
    Bit#(w) way;
  } ECC_icache_data#(numeric type a, numeric type w, numeric type b) deriving(Bits, FShow, Eq);


  typedef struct{
    Bit#(TLog#(`isets)) index; 
    Bit#(TLog#(`iways)) way;
    Bit#(TLog#(`iblocks)) banks;
    Bit#(TMul#(`iwords,8)) data;
    Bool read_write; // False: read True: write
    Bool tag_data; // False: tag True: daa
  } IRamAccess deriving (Bits, Eq, FShow);
`endif
endpackage
