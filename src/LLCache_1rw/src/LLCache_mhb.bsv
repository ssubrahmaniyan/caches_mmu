package LLCache_mhb;
  // library imports
  import Vector         :: *;
  import ConfigReg      :: *;
  import LLCache_types  :: *;
  import DefaultValue   :: *;

  interface     Ifc_LLCache_mhb#(
    numeric type mhbsize,
    numeric type datawidth,
    numeric type ncores,
    numeric type paddr
  );
    (*always_ready*)
    method Bool mv_mhb_full();

    (*always_ready*)
    method Bool mv_mhb_empty();
  
    /*
      doc: method: ma_allocate_mhb_entry
      description: Allocates an entry in the MHB for the given address and hart_id.
    */
    method Action ma_allocate_mhb_entry(
      Bit#(paddr) address,
      Bit#(TLog#(ncores)) hart_id);

    /*
      doc: method: ma_update_mhb_entry
      description: Updates the data field of the current MHB entry being filled.
    */
    method Action ma_update_mhb_entry(
      Bit#(datawidth) data);

    /*
      doc: method: mav_mhb_release
      description: Releases the head entry of the MHB and returns it.
    */
    method ActionValue#(LLCache_mhb_entry#(paddr, datawidth, ncores))
      mav_mhb_release();


  endinterface: Ifc_LLCache_mhb

  module mkLLCache_mhb 
    (Ifc_LLCache_mhb#(
      mhbsize,
      datawidth,
      ncores,
      paddr));


    /*
      doc: variable: v_mhb
      description: Vector representing the MHB, where each entry 
      is a ConfigReg containing an LLCache_mhb_entry struct.
    */
    Vector#(mhbsize, ConfigReg#(LLCache_mhb_entry#(paddr, datawidth, ncores))) 
        v_mhb <- replicateM(mkConfigReg(unpack(0)));
    /*
      doc: variable: rg_mhb_head
      description: Head pointer of the MHB. 
    */
    Reg#(Bit#(TLog#(mhbsize))) rg_mhb_head <- mkReg(0);

    /*
      doc: variable: rg_mhb_tail
      description: Tail pointer of the MHB. 
    */
    Reg#(Bit#(TLog#(mhbsize))) rg_mhb_tail <- mkReg(0);

    /*
      doc: variable: rg_mhb_current_fill
      description: Pointer to the current MHB entry being filled with data.
    */
    Reg#(Bit#(TLog#(mhbsize))) rg_mhb_current_fill <- mkReg(0);

    function Bool is_mhb_full();
      return v_mhb[rg_mhb_tail].valid;
    endfunction

    method Bool mv_mhb_full();
      return is_mhb_full();
    endmethod: mv_mhb_full

    method Bool mv_mhb_empty();
      return !v_mhb[rg_mhb_head].valid;
    endmethod: mv_mhb_empty

    method Action ma_allocate_mhb_entry(
      Bit#(paddr) address,
      Bit#(TLog#(ncores)) hart_id) if (!is_mhb_full());

      v_mhb[rg_mhb_tail] <=  LLCache_mhb_entry{
        address : address,
        data    : 0, 
        hart_id : hart_id,
        valid   : True,
        filled  : False
      };
      rg_mhb_tail <= rg_mhb_tail + 1;

    endmethod: ma_allocate_mhb_entry

    method Action ma_update_mhb_entry(
      Bit#(datawidth) data);
      
      let lv_entry = v_mhb[rg_mhb_current_fill];
      lv_entry.data = data;
      lv_entry.filled = True;

      v_mhb[rg_mhb_current_fill] <= lv_entry;
      rg_mhb_current_fill <= rg_mhb_current_fill + 1;
    endmethod: ma_update_mhb_entry

    method ActionValue#(LLCache_mhb_entry#(paddr, datawidth, ncores))
      mav_mhb_release() if (v_mhb[rg_mhb_head].valid && v_mhb[rg_mhb_head].filled);
      LLCache_mhb_entry#(paddr, datawidth, ncores) lv_entry = v_mhb[rg_mhb_head];

      v_mhb[rg_mhb_head] <= LLCache_mhb_entry{
        address : 0,
        data    : 0,
        hart_id : 0,
        valid   : False,
        filled  : False
      };
      rg_mhb_head <= rg_mhb_head + 1;
      return lv_entry;
    endmethod: mav_mhb_release
  endmodule: mkLLCache_mhb

endpackage: LLCache_mhb
