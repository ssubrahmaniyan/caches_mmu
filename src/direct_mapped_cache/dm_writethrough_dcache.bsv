package dm_writethrough_dcache;

//library packages 
import BRAM::*;
import FIFOF::*;
import SpecialFIFOs :: * ;
import FIFO::*;
import Vector::*;
import GetPut::*;
import BUtils :: * ; 

//project packages 
`include "Logger.bsv"

//--------------------------------local type definitions-----------------------------------------//
typedef enum {Load=0, Store=1} Op deriving(Bits, Eq, FShow);//denotes if load or store

//This structure defines the contents of a Core request 
typedef struct {
Op op;                                   //denotes the operation 
Bit#(addr_width) data_addr;             //physical address sent by the core 
Bit#(data_width) data_write;            //the data to be written, if the operation is a Store
Bit#(3) size;   //the last two bits denotes the size of the data in the operation
                                                                     // (0:8, 1:16, 2:32, 3:64)
Bool fence;     //denotes if the cache needs to cleared 
Bool cache_enable;  //enables cache 
} Core_Req#(numeric type addr_width,numeric type data_width) deriving(Bits, Eq, FShow);

//This structure defines the contents of a Core response 
typedef struct {
Bit#(data_width) data_read;  //data read from the cache 
Bool bus_err;               //bus error 
} Core_Resp#(numeric type data_width) deriving(Bits, Eq, FShow);

//This structure defines the contents of a Memory request
typedef struct {
Op op;                   //denotes the operation          
Bit#(addr_width) l_addr;  //address of a line in the memory 
Bit#(bus_width) write_data; //data to be written to the memory, in case of a Store 
Bit#(3) burst_size; //size of the data transferred in a single burst (0:8, 1:16, 2:32, 3:64)
Bit#(8) burst_len;  //number of bursts 
} Mem_Req#(numeric type addr_width, numeric type bus_width) deriving(Bits, Eq, FShow);

//This structure defines the contents of a Memory response
typedef struct {
Bit#(bus_width) line_read;   //data read from the memory in a single burst 
Bool last;          //denotes the last burst 
Bool bus_err;          //bus error 
} Mem_Resp#(numeric type bus_width) deriving(Bits, Eq, FShow);
//-----------------------------------------------------------------------------------------------//

//Interface for cache implementation 
interface Ifc_cache#( numeric type addr_width, //size of the address in bits 
                      numeric type bus_width,  //size of the system bus in bits 
                      numeric type words, // number of bytes per word
                      numeric type blocks, // number of words per line
                      numeric type sets); // number of sets/lines
    // (*doc = "method: receives core request from core" *)
    method Action ma_core_request(Core_Req#(addr_width, TMul#(8,words)) req);
    // (*doc = "method: receives the response from the cache" *)  
    method ActionValue#(Core_Resp#(TMul#(8,words))) mav_core_resp();
    // (*doc = "method: issues a request to the memory" *)
    method ActionValue#(Mem_Req#(addr_width, bus_width)) mav_mem_req;
    // (*doc = "method: receives the response from the memory" *)
    method Action ma_mem_resp(Mem_Resp#(bus_width) resp);
endinterface

(*doc = "module: implements the fetch + decode + operand-fetch"*)
module mk_cache(Ifc_cache#(addr_width, bus_width, words, blocks, sets))
  provisos(
    //provisos used
    Mul#(words, 8, w_data),                       // w_data is the total bits in a word
    Mul#(blocks, w_data, w_line),                 // w_line is the total bits in a cache line
    Log#(sets,index_bits),                        // index_bits is no. of bits used as index
    Log#(blocks, word_offset),                    // word_offset is no. of bits to index a word in a block
    Log#(words, byte_offset),                     // byte_offset is the no. of bits used as index in BRAMs.
    Add#(byte_offset, word_offset,_a),            // _a total bits to index a byte in a cache line.
    Add#(_a, index_bits, _b),                     // _b total bits for index+offset, 
    Add#(tag_bits, _b, addr_width),               //no. of tagbits
    Div#(w_line, 8, besize),                      // size of byteenable for data_bram
    Div#(bus_width, 8, bebus),                    // no of bytes in the system bus  
  

    // provisos required by compiler
    Add#(a__, 8, w_data),
    Add#(b__, 16, w_data),
    Mul#(TDiv#(w_line, besize), besize, w_line),
    Add#(c__, TMul#(8, words), bus_width),
    Add#(d__, TMul#(8, words), w_line),
    Add#(e__, 32, w_data),
    Add#(f__, w_data, w_line),
    Mul#(16, g__, w_data),
    Mul#(32, h__, w_data),
    Add#(i__, w_data, bus_width),
    Add#(j__, bebus, besize),
    Add#(k__, bus_width, w_line),
    Mul#(bus_width, l__, w_line),
    Add#(m__, bus_width, w_data),
    Add#(n__, 32, bus_width),
    Add#(o__, 16, bus_width),
    Add#(p__, 8, bus_width)
  );    

  String dcache = ""; // Logger

  //------------------type conversions from numeric type to Integer type------------------------// 
  let value_index = valueOf(index_bits);   
  let value_tag = valueOf(tag_bits);
  let value_wordoff = valueOf(word_offset); 
  let value_byteoff = valueOf(byte_offset);
  let value_addr = valueOf(addr_width);
  let value_blocks = valueOf(blocks);
  let value_buswidth = valueOf(bus_width);
  let value_sets = valueOf(sets);
  let value_bebus = valueOf(bebus);
  let value_words = valueOf(words);
//-----------------------------------------------------------------------------------------------//

// (*doc = "func: function to issue request to tag BRAM" *)
  function BRAMRequest#(Bit#(index_bits), Bit#(TAdd#(1, tag_bits))) makeRequest(Bool write,
                                  Bit#(index_bits) addr, Bit#(TAdd#(1, tag_bits)) data);

    return 
      BRAMRequest
      {
        write: write,
        responseOnWrite:False,
        address: addr,
        datain: data
      };
  
  endfunction

// (*doc = "func: function to issue request to byte enabled data BRAM" *)
  function BRAMRequestBE#(Bit#(index_bits), Bit#(w_line), n) makeRequestBE(Bit#(n) write,
                                     Bit#(index_bits) addr, Bit#(w_line) data);

    return 
      BRAMRequestBE
      {
        writeen: write,
        responseOnWrite:False,
        address: addr,
        datain: data
      };
  
  endfunction

// (*doc = "func: function to left rotate byte_enable by the required amount" *)
  function Bit#(n) fn_rotate_up( Bit#(n) inData, UInt#(m) inx)

  provisos( Log#(n,m) );
  return rotateBitsBy( inData, inx );

  endfunction

  //--------------------------------------Start instantiations-----------------------------------//
  //BRAM instantiations  
  BRAM_Configure cfg2 = defaultValue;
  BRAM_Configure cfg1 = defaultValue;
  cfg2.memorySize = value_sets ;
  cfg2.allowWriteResponseBypass = False;
  cfg1.memorySize = value_sets ;
  BRAM2Port#(Bit#(index_bits), Bit#(TAdd#(1, tag_bits))) 
                          tag_bram <- mkBRAM2Server(cfg2); //BRAM that holds the tag and valid bits
  BRAM2PortBE#(Bit#(index_bits), Bit#(w_line), besize)
                          data_bram <- mkBRAM2ServerBE(cfg1); //BE BRAM that holds data

  //FIFO instantiations 
  //(*doc = "fifo: this fifo holds core responses"*)
  FIFOF#(Core_Resp#(w_data)) ff_core_resp <- mkBypassFIFOF;
  //(*doc = "fifo: this fifo holds core requests"*)
  FIFOF#(Core_Req#(addr_width, w_data)) ff_core_req <- mkLFIFOF;
  //(*doc = "fifo: this fifo holds memory requests"*)
  FIFOF#(Mem_Req#(addr_width, bus_width))ff_linereq_queue <- mkFIFOF;
  //(*doc = "fifo: this fifo holds memory responses"*)
  FIFOF#(Mem_Resp#(bus_width)) ff_lineresp_queue <- mkFIFOF;

  Bit#(bebus) random = '1;         //used to initialise rg_byte_enable1 and rg_be_temp

  //Register instantiations 
  // (*doc = "reg: this register acts as the guard among the rules"*)
  Reg#(Bool) rg_miss_ongoing <- mkReg(False);
  //(*doc = "reg: this register holds the byte enable used to update the BRAM on a miss"*)
  Reg#(Bit#(besize)) rg_byte_enable1<- mkReg(zeroExtend(random));
  //(*doc = "reg: this register is used to reset the byte enable on a miss"*)
  Reg#(Bit#(besize)) rg_be_temp<- mkReg(zeroExtend(random));
  //(*doc = "reg: this register is used to fence the cache "*)
  Reg#(Bool) rg_initialize <- mkReg(True);
  /*(*doc = "reg: this register is used as a counter to address all the elements of the tag BRAM \       
                                                                                while fencing"*)*/
  Reg#(Bit#(index_bits)) rg_index <- mkReg(0);

 //--------------------------------------End instantiations-----------------------------------//

/*(*doc = "rule :This rule is used for initializing the cache upon receiving a request where         
  fence is true. This is done by making the valid bit in the tag BRAM invalid for all entries.       
  This rule fires when rg_miss_ongoing is false and rg_initialize is true. At the end of this        
  rule, after updating all the valid bits, rg_initialize is set to false"*)*/
  rule fence_op(!rg_miss_ongoing && rg_initialize );
    tag_bram.portB.request.put(makeRequest(True,truncate(rg_index),0 ));   
    rg_index <= rg_index+1;
    `logLevel( dcache, 0, $format("DCACHE: Fencing index:%d", rg_index))
    if(rg_index == fromInteger(value_sets-1)) begin
      rg_initialize <= False;
    end
  endrule
 
  /*(*doc = "rule :This rule takes care of the processing required upon receiving the requests           
    from the core. This is done based on whether the request is a hit or a miss, in case                
    cache_enable is true. Otherwise, request is directly sent to the memory.                           
                                                                                                       
    1. First, the tag & index bits are extracted from the request address in ff_core_req.               
       The extracted tag bits are compared with the pre-existing stored tag bits in the required       
       index of the tag BRAM & the validity of the indexed cache line is also checked.                 
       This gives rise to two cases : Hit & Miss                                                       
                                                                                                       
    2. In the case of a Hit, first the operation is checked.                                           
       2a. If the operation is Load, the data is extracted from the data BRAM. The size of             
           data extracted depends on the last two bits of request.size & the data is zero-             
           extended/sign-extended depending on the MSB of request.size. The manipulated response       
           data is then enqueued into the FIFO ff_core_resp.                                           
       2b. If the operation is Store, a write request is sent to the data BRAM via PORTB.              
           The data is written at the correct bytes of the cache line by using the mask variable       
           lv_byte_enable. The size of the byte enable is set according to the last two bits of        
           request.size. It is then shifted by an amount lv_block_offset. A write request is also        
           sent to the memory by enqueuing in ff_linereq_queue where the burst size depends on the       
           last two bits of request.size & the burst length is 1. The data originally stored in        
           memory is enqueued into ff_core_resp in a similar way to that in Load operation.             
       The FIFO ff_core_req is dequeued at the end of this.                                             
                                                                                                        
    3. In the case of a Miss, a Load request is sent to the memory to fill the indexed cache line        
       with the data corresponding to the correct tag bits and rg_miss_ongoing is made true to           
       fire a rule in the next cycle which will fetch the data from the memory and start writing          
       to the cache line.  
                                                                                                         
    4. The above operations are bypassed if the cache_enable field of the request being served is        
       false. And a direct channel between the core and the memory is made."*) */                    
 
  rule update_reqreg(!rg_miss_ongoing && !ff_core_req.first.fence && !rg_initialize);
      let lv_request = ff_core_req.first;
      `logLevel( dcache, 0, $format("DCACHE: Analysing Request: ",fshow(lv_request)))
      Bit#(tag_bits) lv_request_tag = lv_request.data_addr[value_addr-1:value_addr-value_tag];

      Bit#(w_data) lv_storedata = lv_request.data_write;
      Bit#(index_bits) lv_index = lv_request.data_addr
                        [value_index +value_wordoff +value_byteoff-1:value_wordoff +value_byteoff];
      Bit#(TAdd#(3,TAdd#(byte_offset,word_offset))) lv_block_offset = 
                                            lv_request.data_addr[value_byteoff+value_wordoff -1:0];
      Bit#(besize) lv_byte_enable=0;
      case (lv_request.size[1:0]) 
        0: begin
          lv_storedata = duplicate(lv_storedata[7:0]);
          lv_byte_enable = 'b1;
        end
        1: begin
          lv_storedata = duplicate(lv_storedata[15:0]);
          lv_byte_enable = 'b11;
        end
        2: begin
          lv_storedata = duplicate(lv_storedata[31:0]);
          lv_byte_enable = 'b1111;
        end
        default: begin
          lv_byte_enable = 'b11111111;
        end
      endcase
      lv_byte_enable = lv_byte_enable << lv_block_offset;
      let lv_tag_read <- tag_bram.portA.response.get;
      Bit#(tag_bits) lv_stored_tag = truncate(lv_tag_read);
      Bit#(1) lv_valid = truncateLSB(lv_tag_read);
  
      let lv_data_read <- data_bram.portA.response.get;
      `logLevel( dcache, 1, $format("DCACHE:The data in BRAM is :%h ",lv_data_read))

  
      lv_data_read = lv_data_read >> (lv_block_offset << 3);
 
      `logLevel( dcache, 1, $format("DCACHE: StoredTag:%h ReqTag:%h index:%d", lv_stored_tag,      
                                                                        lv_request_tag, lv_index))
      Bool lv_hit = ((lv_stored_tag == lv_request_tag) && (lv_valid==1));
  
      Bit#(w_data) lv_response_data = truncate(lv_data_read);
      if (lv_request.cache_enable) begin 
        if(lv_hit) begin // Load operation
          `logLevel( dcache, 0, $format("DCACHE: Hit detected: "))
          if(lv_request.op == Load) begin
            case(lv_request.size)
              'b000 :  lv_response_data = signExtend(lv_response_data[7:0]);
              'b001 :  lv_response_data = signExtend(lv_response_data[15:0]);
              'b010 :  lv_response_data = signExtend(lv_response_data[31:0]);
              'b100 :  lv_response_data = zeroExtend(lv_response_data[7:0]);
              'b101 :  lv_response_data = zeroExtend(lv_response_data[15:0]);
              'b110 :  lv_response_data = zeroExtend(lv_response_data[31:0]);
              default: lv_response_data = lv_response_data;
            endcase
            `logLevel( dcache, 1, $format("DCACHE:The data found in the cache is :%h ",
                                                                               lv_response_data)) 
            ff_core_resp.enq(Core_Resp{data_read: lv_response_data, bus_err:False});
          end
          else begin // Store operation
            `logLevel( dcache, 1, $format("DCACHE: Byte enable to facilitate \
                                                         the requested write:%h ", lv_byte_enable))
                                                                                    
            `logLevel( dcache, 1, $format("DCACHE: The date to be written in  \
                                                            the memory line is :%h ",lv_storedata))
                                                                             
            data_bram.portB.request.put(makeRequestBE(lv_byte_enable, lv_index, 
                                                                         duplicate(lv_storedata)));
            ff_linereq_queue.enq(Mem_Req{op: Store, 
                                      l_addr: lv_request.data_addr,
                                      write_data: zeroExtend(lv_request.data_write),
                                      burst_size: zeroExtend(lv_request.size[1:0]),
                                      burst_len : 'b1});    
                                      case(lv_request.size)
                                      'b000 :lv_response_data = signExtend(lv_response_data[7:0]);
                                      'b001 :lv_response_data = signExtend(lv_response_data[15:0]);
                                      'b010 :lv_response_data = signExtend(lv_response_data[31:0]);
                                      'b100 :lv_response_data = zeroExtend(lv_response_data[7:0]);
                                      'b101 :lv_response_data = zeroExtend(lv_response_data[15:0]);
                                      'b110 :lv_response_data = zeroExtend(lv_response_data[31:0]);
                                      default:lv_response_data = lv_response_data;
                                    endcase
            ff_core_resp.enq(Core_Resp{data_read: lv_response_data, bus_err:False});
          `logLevel( dcache, 0, $format("DCACHE: A request to store \
                                                                the data in memory has been sent"))
          end
          ff_core_req.deq;
        end
        else begin // on a miss;
          rg_miss_ongoing <= True;
          let lv_value_wordoff = 
                        unpack(lv_request.data_addr[value_wordoff +value_byteoff-1:value_byteoff]);
          rg_byte_enable1<= fn_rotate_up(rg_be_temp,lv_value_wordoff*fromInteger(value_words)); 
          Bit#(addr_width) lv_line_req = (lv_request.data_addr >> value_byteoff)<<value_byteoff;
          `logLevel( dcache, 0, $format("DCACHE: Miss. Sending Address:%h ", lv_line_req))
          ff_linereq_queue.enq(Mem_Req{op: Load, 
                                    l_addr: lv_line_req,
                                    write_data: ?,
                                    burst_size: fromInteger(value_byteoff),
                                    burst_len : fromInteger(value_blocks-1)});
        end
      end
      else begin 
      rg_miss_ongoing <= True;
      `logLevel( dcache, 0, $format("DCACHE received non-cacheable request. \
                                                Bypassing cache for request: ", fshow(lv_request)))
      ff_linereq_queue.enq(Mem_Req{op: lv_request.op, 
                                l_addr: lv_request.data_addr,
                                write_data: zeroExtend(lv_request.data_write),
                                burst_size: zeroExtend(lv_request.size[1:0]),
                                burst_len : 0});
      end
  endrule        
  
  /*(*doc = "rule :This rule fires whenever the memory needs to be accessed i.e, in case of a miss 
    due to which the cache will have to be updated with a cache line from memory or in the case of
    a request where the cache_enable field is set to false, which would require the cache to be 
    bypassed.                        
                                                                                                       
    1. If the cache_enable field of the core request is set to true, the operation is a miss, 
       the packets of data received from the memory over the various bursts are written to the data
       BRAM at the required places. Over the course of this operation the byte enable is rotated so
       that the packets of data are written in their correct positions. If the lv_update.last field
       is set to true the writing operation terminates since the last burst of data would have been
       received by the cache, following which rg_miss_ongoing is set to false exiting the rule. In 
       case a bus error occurs, the bus_err field of update would have been set to true under which
       case an error message is displayed, rg_miss_ongoing is set to false and ff_core_req is 
       dequeued removing the faulty request.                                                 
                                                                                                       
    2. If the cache_enable is set to false, i.e the cache is disabled, the data received from the 
        memory is sent to the core very similarly to how a load operation is carried out. Based on
        the size field of the core request the requested amount of the received data is transferred
        to the core. Following this rg_miss_ongoing is set to false and ff_core_request is 
        dequeued"*) */    

  rule update_bram_on_miss(rg_miss_ongoing);
    let lv_request = ff_core_req.first;
    Bit#(index_bits) lv_index = lv_request.data_addr
                        [value_index +value_wordoff +value_byteoff-1:value_wordoff +value_byteoff];
     Bit#(tag_bits) lv_writetag = lv_request.data_addr[value_addr-1:value_addr-value_tag];

    let lv_update = ff_lineresp_queue.first;
   
    ff_lineresp_queue.deq;
    rg_byte_enable1<= fn_rotate_up(rg_byte_enable1,fromInteger(value_bebus));
    `logLevel( dcache, 0, $format("DCACHE:  byte-enable %h",  rg_byte_enable1)) 
    if (lv_request.cache_enable) begin   
      if(!lv_update.bus_err)begin
        `logLevel( dcache, 1, $format("DCACHE: writing data: %h index:%d",
                                                                    lv_update.line_read, lv_index))
         data_bram.portB.request.put(makeRequestBE(rg_byte_enable1,
                                                         lv_index,duplicate(lv_update.line_read)));

        `logLevel( dcache, 1, $format("DCACHE: writing tag: %h index:%d", lv_writetag, lv_index))
        tag_bram.portB.request.put(makeRequest(True,lv_index,{1'b1,lv_writetag}));   
        if (lv_update.last) begin 
         `logLevel( dcache, 0, $format("DCACHE: Sending the last burst of data and updating tag"))   
          rg_miss_ongoing <= False;
          tag_bram.portA.request.put(makeRequest(False, lv_index, ?));
          data_bram.portA.request.put(makeRequestBE(0, lv_index, ?));
        end 
      end
      else begin // in case of bus_error
        rg_miss_ongoing <= False;
        ff_core_resp.enq(Core_Resp{bus_err: True, data_read: ?});
        ff_core_req.deq;
        `logLevel( dcache, 0, $format("DCACHE: A bus error has been detected "))
      end 
    end 
    else begin
        Bit#(TAdd#(byte_offset,3)) temp1 = {lv_request.data_addr[value_byteoff-1:0], 3'b0} ;
        lv_update.line_read = lv_update.line_read >> temp1; 
        Bit#(w_data) lv_tempdata =
        case(lv_request.size)
          'b000 : signExtend(lv_update.line_read[7:0]);
          'b001 : signExtend(lv_update.line_read[15:0]);
          'b010 : signExtend(lv_update.line_read[31:0]);
          'b100 : zeroExtend(lv_update.line_read[7:0]);
          'b101 : zeroExtend(lv_update.line_read[15:0]);
          'b110 : zeroExtend(lv_update.line_read[31:0]);
          default: truncate(lv_update.line_read);
        endcase;
        ff_core_resp.enq(Core_Resp{bus_err: False, data_read: lv_tempdata });
        ff_core_req.deq;
        rg_miss_ongoing <= False;
    end 
  endrule

  /*(*doc = "method :This method receives the core request from the core. The tag and index bits
     are extracted following which requests are sent to the tag and data BRAMs. The request is 
     also enqueued into ff_core_req.*)*/
  method Action ma_core_request(Core_Req#(addr_width, TMul#(8,words)) req) if(!rg_miss_ongoing &&
                                                                                  !rg_initialize);
    `logLevel( dcache, 0, $format("DCACHE: Request from Core: ",fshow(req)))
    if(req.fence)
      rg_initialize <= True;
    else begin
      ff_core_req.enq(req);
      Bit#(index_bits) lv_index = 
           req.data_addr[value_index +value_wordoff +value_byteoff-1:value_wordoff +value_byteoff];
      `logLevel( dcache, 1, $format("DCACHE: Index:%d", lv_index))
      tag_bram.portA.request.put(makeRequest(False, lv_index, ?));
      data_bram.portA.request.put(makeRequestBE(0, lv_index, ?));
    end
  endmethod
  
  /*(*doc = "method :This method responds back to the core with the requested result. Here
    ff_core_resp is dequeued and the first element is returned to the core.*)*/
  method ActionValue#(Core_Resp#(TMul#(8,words))) mav_core_resp();
    ff_core_resp.deq;
    return ff_core_resp.first;
  endmethod

  /*(*doc = "method :This method issues a request to the memory in the case a miss occurs or if the
    cache is disabled. The queue ff_linereq_queue is dequeued and the first element is returned to 
    the cache."*)*/
  method ActionValue#(Mem_Req#(addr_width, bus_width)) mav_mem_req;
    ff_linereq_queue.deq();
    return ff_linereq_queue.first();
  endmethod
   
  /*(*doc = "method :This method method receives a response from the memory for the issued request.
    The received data is enqueued into ff_lineresp_queue."*)*/
  method Action ma_mem_resp(Mem_Resp#(bus_width) resp);
    `logLevel( dcache, 0, $format("DCACHE: Mem response: ", fshow(resp)))
     ff_lineresp_queue.enq(resp);
  endmethod
  
endmodule
endpackage



