/* 
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details: 

This module allows you to create the cache data tag arrays in various configurations. You
can define the number of banks and type of concatenation you would like using the various modules
described in this file. These are implemented as Dual-BRAM modules such that 1-port is a dedicated
read and the other is a dedicated write. This allows easy mapping to SRAM libraries having 1r+1w
configuration.

Three primary parameters are available: 
  n_entries: The total number of BRAM entries for the entire instance.
  datawidth: The total number of bits on a read-response.
  banks: the total number of banks present in an instance.

Four different types of modules are available:

  1. mkmem_config_h: This module banks the BRAM instances horizontally. That is the bit-width of
  each bank is now datawidth/banks. The provisos of the module require that datawidth%banks=0. Each
  bank however has the same number of entries. This module does not support byte-enables.

  2. mkmem_config_hbe: This module banks the BRAM instances horizontally. That is the bit-width of
  each bank is now datawidth/banks. The provisos of the module require that datawidth%banks=0. Each
  bank however has the same number of entries. This module supports byte-enables and the provisos
  require that (datawidth/8)%banks=0.

  3. mkmem_config_v: this module banks the BRAM instances vertically,  i.e. the number of entries
  per bank = n_entries/banks. The bit-width of each bank instances is however the same: datawidth.
  The provisos of this module require that: n_entries%banks=0. This module does not support
  byte-enables.

  4. mkmem_config_v: this module banks the BRAM instances vertically,  i.e. the number of entries
  per bank = n_entries/banks. The bit-width of each bank instances is however the same: datawidth.
  The provisos of this module require that: n_entries%banks=0. This module supports byte-enables and
  has an additional proviso of (datawidth%8)=0
--------------------------------------------------------------------------------------------------
*/
package mem_config_nb;
 
  // import RegFile::*;
  import BRAMCore ::*;
  import DReg::*;
  import FIFOF::*;
  import SpecialFIFOs::*;
  import Assert::*;
  `include "Logger.bsv"           // for logging
  
  interface Ifc_mem_config1r1w#( numeric type n_entries, numeric type datawidth, numeric type sram_width);
    method Action write(Bit#(TLog#(n_entries)) index, Bit#(datawidth) data);
    method Action read(Bit#(TLog#(n_entries)) index);
    method Bit#(datawidth) read_response;
  endinterface
  
  module mkmem_config1r1w#(parameter Bool ramreg, parameter String memname) (Ifc_mem_config1r1w#(n_entries, datawidth, sram_width));

		// Reg#(Bit#(TLog#(n_entries))) rg_index <-mkReg(0);
		// RegFile#(Bit#(TLog#(n_entries)), Bit#(datawidth)) ram <- mkRegFileWCF(0, 'd63);
    BRAM_DUAL_PORT#(Bit#(TLog#(n_entries)), Bit#(datawidth)) ram <- mkBRAMCore2(`dsetsize, False);

    method Action write(Bit#(TLog#(n_entries)) index, Bit#(datawidth) data);
      `logLevel( dcache, 2, $format(memname,": writing data: %h at index: %d", data, index))
      ram.b.put(True,index,data);
			// ram.upd(index, data);
		endmethod

    method Action read(Bit#(TLog#(n_entries)) index);
      `logLevel( dcache, 2, $format(memname,"Read from index: %d", index))
			// rg_index<= index;
      ram.a.put(False,index,'0);
		endmethod

    method Bit#(datawidth) read_response;

			Bit#(datawidth) res= ram.a.read(); //ram.sub(rg_index);
      //`logLevel( dcache, 2, $format(memname,": Reading data: %h from index: %d", res, rg_index))
			return res;
		endmethod
	endmodule
//  module mkmem_config1r1w#(parameter Bool ramreg) (Ifc_mem_config1r1w#(n_entries, datawidth, sram_width))
//    provisos(
//             Div#(datawidth, sram_width, banks)
//						 //Add#(sram_width, x__, datawidth),
//						 //Add#(y__, TSub#(datawidth, TMul#(sram_width, banks)), sram_width)
//    );
//
//		let v_banks= valueOf(banks);
//		let v_datawidth= valueOf(datawidth);
//		let v_sram_width= valueOf(sram_width);
//
//    Ifc_bram_1r1w#(TLog#(n_entries), sram_width, n_entries) ram [v_banks];
//    Reg#(Bit#(sram_width)) rg_output[v_banks][2];
//    for(Integer i=0;i<v_banks;i=i+1) begin
//      ram[i]<- mkbram_1r1w;
//      rg_output[i] <- mkCReg(2,0);
//    end
//
//    for(Integer i=0;i<v_banks;i=i+1)begin
//      rule capture_output(!ramreg);
//        rg_output[i][0]<=ram[i].response;
//      endrule
//      rule capture_output_reg(ramreg);
//        rg_output[i][1]<=ram[i].response;
//      endrule
//    end
//
//    method Action write(Bit#(1) we, Bit#(TLog#(n_entries)) index, Bit#(datawidth) data);
//			Bit#(TMax#(datawidth, sram_width)) temp_data= zeroExtend(data);
//			if(v_datawidth>v_sram_width) begin
//      	for(Integer i=0;i<v_banks-1;i=i+1) begin
//      	  ram[i].write(temp_data[(i*v_sram_width) + v_sram_width-1 : i*v_sram_width], index, we);
//      	end
//				Bit#(TSub#(datawidth, TMul#(sram_width, banks))) remaining_MSB= temp_data[v_datawidth-1:v_sram_width*v_banks];
//				ram[v_banks-1].write(zeroExtend(remaining_MSB), index, we);
//			end
//			else begin
//				ram[v_banks-1].write(truncate(temp_data), index, we);
//			end
//    endmethod
//    method Action read(Bit#(TLog#(n_entries)) index);
//      for(Integer i=0;i<v_banks;i=i+1) begin
//        ram[i].read(index);
//      end
//    endmethod
//    method Bit#(datawidth) read_response;
//      Bit#(datawidth) data_resp=0;
//			Bit#(TMax#(datawidth, sram_width)) temp_data_resp;
//			if(v_datawidth>v_sram_width) begin
//	      for(Integer i=0;i<v_banks-1;i=i+1)begin
//					temp_data_resp= zeroExtend(rg_output[i][1]);
//  	      data_resp[ (i*v_sram_width) + v_sram_width-1 : i*v_sram_width]= truncate(temp_data_resp);
//    	  end
//				Bit#(TSub#(datawidth, TMul#(sram_width, banks))) remaining_MSB= rg_output[v_banks-1][1][v_datawidth-1:v_sram_width*v_banks];
//				temp_data_resp= zeroExtend(remaining_MSB);
//				data_resp[v_datawidth-1 : v_sram_width*v_banks]= truncate(temp_data_resp);
//			end
//			else begin
//				temp_data_resp= zeroExtend(rg_output[0][1]);
//				data_resp= truncate(temp_data_resp);
//			end
//      return data_resp;
//    endmethod
//  endmodule
  
//	(*synthesize*)
//	module mkmem_config(Ifc_mem_config1r1w#(64,22,32));
//    let ifc();
//    mkmem_config1r1w#(False) _temp(ifc);
//    return (ifc);
//  endmodule
endpackage
