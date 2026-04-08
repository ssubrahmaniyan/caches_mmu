package LLCache_lib;

  import bram_1rw       :: *;
  import LLCache_types  :: *;

  interface Ifc_mem_1rw#(
    numeric type n_entries  ,
    numeric type data_width ,
    numeric type banks
  );

    /*
      doc: method: request
      description: This method is used to send
      the request to the memory for read and write operation.
    */
    method Action request(
      AccessType_t            access,
      Bit#(TLog#(n_entries))  index,
      Bit#(data_width)        data,
      Bit#(banks)             bank_en
    );

    /* doc: method: read_response
      description: This method is used to get the read response from the memory.
    */
    method Bit#(data_width) read_response;

  endinterface: Ifc_mem_1rw

  /* doc: module: mkmem_1rw
      description: This module is the implementation of the memory with 1 read/write port.
      Memory is banked to achieve the required data width.
  */
  module mkmem_1rw
    (Ifc_mem_1rw#(
      n_entries,
      data_width,
      banks))
    provisos(
      Div#(data_width, banks, bpb),
      Add#(a_, bpb, data_width)
    );

    let v_bpb = valueOf(bpb); // bits per bank

    // Interface for each bank
    Ifc_bram_1rw#(
      TLog#(n_entries), // address width
      bpb,              // data width
      n_entries)        // memory size
      ram_single [valueOf(banks)];

    Reg#(Bit#(bpb)) rg_output [valueOf(banks)];

    for (Integer i = 0; i < valueOf(banks); i = i + 1) begin
      ram_single[i] <- mkbram_1rw ;
      rg_output[i]  <- mkReg(0);
    end

    // rules
    for (Integer i = 0; i < valueOf(banks); i = i + 1) begin
      rule rl_capture_output;
        rg_output[i] <= ram_single[i].response;
      endrule
    end

    method Action request(
      AccessType_t            access, 
      Bit#(TLog#(n_entries))  index, 
      Bit#(data_width)        data, 
      Bit#(banks)             bank_en);

      for (Integer i = 0; i < valueOf(banks); i = i + 1) begin
        if (bank_en[i] == 1'b1) begin
          ram_single[i].request(pack(access), 
                                index       ,
                                data[(i+1)*v_bpb-1 : i*v_bpb]);
        end
      end
    endmethod: request

    method Bit#(data_width) read_response;
      Bit#(data_width) response;
      for (Integer i = 0; i < valueOf(banks); i = i + 1) begin
        response[(i+1)*v_bpb-1 : i*v_bpb] = rg_output[i];
      end
      return response;
    endmethod: read_response

  endmodule: mkmem_1rw

endpackage: LLCache_lib
