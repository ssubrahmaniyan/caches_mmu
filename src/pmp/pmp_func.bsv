/* 
see LICENSE.incore
see LICENSE.iitm

Author : Neel Gala
Email id : neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package pmp_func;

  import Vector :: * ;
  `include "Logger.bsv"
  import Reserved :: * ;

  `define Inst_addr_misaligned  0 
  `define Inst_access_fault     1 
  `define Illegal_inst          2 
  `define Breakpoint            3 
  `define Load_addr_misaligned  4 
  `define Load_access_fault     5 
  `define Store_addr_misaligned 6 
  `define Store_access_fault    7 
  `define Ecall_from_user       8 
  `define Ecall_from_supervisor 9 
  `define Ecall_from_machine    11
  `define Inst_pagefault        12
  `define Load_pagefault        13
  `define Store_pagefault       15

  // ------------ PMP related types ----------------//

  typedef enum { OFF=0, TOR=1, NA4=2, NAPOT=3} PMPAddrMode deriving(Bits, Eq, FShow);
  typedef enum {Machine = 3, Supervisor = 1, User = 0} PMP_Priv_mode deriving(Bits, Eq, FShow);

  typedef struct{
    Bool lock;
    ReservedZero#(2) warl;
    PMPAddrMode access;
    Bool exec;
    Bool write;
    Bool read;
  } PMPCfg deriving(Bits, FShow, Eq);

  typedef struct{
    Bit#(`paddr) address;
    Bit#(2)      access_type; // 0-load 1-store 2-fetch
  } PMPReq deriving(Bits, FShow, Eq);

  function PMPCfg fn_unpack_cfg(Bit#(8) cfg);
    return PMPCfg{  read  : unpack(cfg[0]),
                    write : unpack(cfg[1]),
                    exec  : unpack(cfg[2]),
                    access: unpack(cfg[4:3]),
                    warl  : ?,
                    lock  : unpack(cfg[7])};
  endfunction
  // ------------------------------------------------//


  /*doc:func: Function used to find a value address match across the vector of pmps*/
  function Bool fn_compare_elem(Tuple2#(Bool, Bool) a);
    return tpl_1(a);
  endfunction

  (*noinline*)
  /*doc:func: 
  This function will perform a pmp lookup on all entries and return a boolean indicating
  if an access fault occurs along with the respective cause value*/
  function Tuple2#(Bool, Bit#(`causesize)) fn_pmp_lookup( 
          PMPReq req, 
          PMP_Priv_mode priv,
          Vector#(`pmpsize, Bit#(8)) pmpcfg,
          Vector#(`pmpsize, Bit#(TSub#(`paddr, `pmp_grainbits))) pmpaddr);
    Bit#(`causesize) cause = case(req.access_type) 
      'd0 : `Load_access_fault;
      'd1 : `Store_access_fault;
      default : `Inst_access_fault; 
    endcase;
    Bit#(TSub#(`paddr,`pmp_grainbits)) reqbase = truncateLSB(req.address);

    /*doc:func: 
    function to perform a single pmp check. This function is mapped to all entries of the pmp. This
    function will return 2 boolean values. The first boolean value indicates if there is an address
    match on the entry. The second boolean value will indicate if there has been an access fault. 

    For address match: the start address is defined as the corresponding pmp entry (for NAPOT/NA4)
    or the previous pmp entry in case of TOR. The mask is created using the current pmp entry. It is
    set to all-ones if TOR is not selected. The top address is always the current entry. We then
    check if the requested address lies within the start address and the top address, only then a
    match is indicated.

    For access_trap: If lock is cleared and priv == Machine, then no trap is generated. In all other
    cases the access permissions are checked to see if an access fault should be generated or not.
    */
    function Tuple2#(Bool, Bool)
        fn_single_lookup( PMPCfg cfg, Bit#(TSub#(`paddr, `pmp_grainbits)) top, 
                          Bit#(TSub#(`paddr, `pmp_grainbits)) bottom);
                              

      Bit#(TSub#(`paddr,`pmp_grainbits)) start_address = cfg.access == TOR ? bottom : top;
      Bit#(TSub#(`paddr,`pmp_grainbits)) mask = top << 1 | zeroExtend(~pack(cfg.access == NA4));
      mask = cfg.access != NAPOT ? '1 : ~(mask & ~(mask + 1));

      Bool lv_match_low  = reqbase >= (start_address & mask);
      Bool lv_match_high = reqbase <= top;
      Bool address_match = lv_match_low && lv_match_high && cfg.access != OFF;

      Bool access_trap = (!(!cfg.lock && priv == Machine) &&
                           ((req.access_type == 0 && !cfg.read)  ||
                            (req.access_type == 1 && !cfg.write)  ||
                            (req.access_type == 2 && !cfg.exec)
                           ) 
                         );

      return tuple2(address_match, access_trap);  
    endfunction

    /*doc:note: 
    We use the map function on the input 8-bit cfg to convert it to PMPCfg structure type.
    Then the function fn_single_lookup is called for each entry of the pmpcfg and addr. For TOR we
    need to use the previous entry as the base. To achieve this we send the same array as pmpaddr
    but shifting a 0 entry to the top and removing the last entry. The output of the this map is
    a vector containing the address-match and access-trap info.
    Finally, the vector from above is lookedup for any hits and the trap and cause value is
    assigned appropriately.
    */
    let v_pmpcfg = map(fn_unpack_cfg, pmpcfg);
    let pmpmatch = zipWith3(fn_single_lookup, v_pmpcfg, pmpaddr, shiftInAt0(pmpaddr, 0));

    let x = find(fn_compare_elem, pmpmatch);
    let {addrmatch, accesstrap} = fromMaybe(tuple2(False, False), x);

    return (priv == Machine && !addrmatch) ? tuple2(False, cause): 
                                            tuple2((addrmatch && accesstrap), cause);

  endfunction

  /*[>doc:module: <]
  module mkTb (Empty);
    [>doc:reg: <]
    Reg#(Bit#(32)) rg_count <- mkReg(0);
    rule rl_check;
      
      PMPReq req = PMPReq{address: 'hDB4, access_type:0};
      PMP_Priv_mode mode = Supervisor;
      Vector#(`pmpsize, Bit#(8)) v_pmpcfg  = replicate(0);
      Vector#(`pmpsize, Bit#(TSub#(`paddr,`pmp_grainbits))) v_pmpaddr = replicate(0);

      v_pmpcfg[1] = zeroExtend(pack(PMPCfg{read:False, 
                                           write:True, 
                                           exec:True, 
                                           access:NAPOT,
                                           lock:False}));
      v_pmpcfg[3] = zeroExtend(pack(PMPCfg{read:True, 
                                           write:True, 
                                           exec:True, 
                                           access:TOR,
                                           lock:False}));
      v_pmpaddr[0] = 'h401;
      v_pmpaddr[1] = 'h36d;
      v_pmpaddr[2] = 'h400;
      v_pmpaddr[3] = 'h800;
      
      let {trap,cause} <- fn_pmp_lookup(req, mode, v_pmpcfg, v_pmpaddr);
      `logLevel( tb, 0, $format("Trap:%b Cause:%d",trap, cause))

      if (rg_count == 0) begin
        $finish(0);
      end
      rg_count <= rg_count + 1;
      `logLevel( tb, 0, $format("Count:[%5d]",rg_count))
    endrule
  endmodule*/

  /*interface Ifc_dummy;
    method Tuple2#(Bool, Bit#(`causesize)) result_;
    method Action _inputs (Vector#(`pmpsize, Bit#(8)) pmpcfg,
                           Vector#(`pmpsize, Bit#(TSub#(`paddr,2))) pmpaddr,
                           PMPReq req, PMP_Priv_mode priv);
  endinterface: Ifc_dummy
  (*synthesize*)
  module mkdummy(Ifc_dummy);
    Vector#( `pmpsize, Reg#(Bit#(8)) ) v_pmpcfg <- replicateM(mkReg(0));
    Vector#( `pmpsize, Reg#(Bit#(TSub#(`paddr,2))) ) v_pmpaddr <- replicateM(mkReg(0)) ;
    [>doc:reg: <]
    Reg#(PMPReq) rg_req <- mkReg(unpack(0));
    [>doc:reg: <]
    Reg#(PMP_Priv_mode) rg_priv <- mkReg(unpack(0));
    Reg#(Tuple2#(Bool,Bit#(`causesize))) rg_result <- mkReg(unpack(0));

    rule rl_perform_pmp;
      rg_result <= fn_pmp_lookup(rg_req, rg_priv, readVReg(v_pmpcfg), readVReg(v_pmpaddr));
    endrule

    method result_ =  rg_result;
    method Action _inputs (Vector#(`pmpsize, Bit#(8)) pmpcfg,
                           Vector#(`pmpsize, Bit#(TSub#(`paddr,2))) pmpaddr,
                           PMPReq req, PMP_Priv_mode priv);
      rg_req <= req;
      rg_priv <= priv;
      writeVReg(v_pmpaddr, pmpaddr);
      writeVReg(v_pmpcfg, pmpcfg);
    endmethod
  endmodule:mkdummy
*/
endpackage
