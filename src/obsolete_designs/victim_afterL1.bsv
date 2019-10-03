/* 
Copyright (c) 2018, IIT Madras All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions
  and the following disclaimer.  
* Redistributions in binary form must reproduce the above copyright notice, this list of 
  conditions and the following disclaimer in the documentation and/or other materials provided 
 with the distribution.  
* Neither the name of IIT Madras  nor the names of its contributors may be used to endorse or 
  promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT 
OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--------------------------------------------------------------------------------------------------

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package victim_afterL1;
  import Vector::*;
  import FIFOF::*;
  import DReg::*;
  import SpecialFIFOs::*;
  import BRAMCore::*;
  import FIFO::*;
  import BUtils::*;

  import cache_types::*;

 
  typedef enum {RespondFromVB, RespondFromMemory} RespType deriving(Eq,Bits,FShow);

  interface Ifc_victim_afterL1#(
                      numeric type wordsize, 
                      numeric type blocksize,  
                      numeric type sets,
                      numeric type ways,
                      numeric type paddr,
                      numeric type size
                      );

    method Action req_frm_cache ( Tuple2#(Bit#(paddr),Bool) read_req ,
                                  Tuple2#(Bit#(paddr),Bool) evict_req);
    method Action data_from_cache(Tuple2#(Bit#(TMul#(wordsize,8)),Bool) wdata);
    method ActionValue#(DMem_read_response#(TMul#(wordsize,8))) response_to_cache;

    method ActionValue#(DMem_write_request#(paddr)) memory_request;
    method ActionValue#(DMem_write_data#(TMul#(wordsize,8))) memory_data;

    method ActionValue#(DMem_read_request#(paddr)) read_mem_req;
    method Action read_mem_resp (DMem_read_response#(TMul#(wordsize,8)) resp);

    method Bool vb_is_full; 
    method Bool vb_is_empty;
    method Action empty_vb;
    method Action diablevictim (Bool d);
  endinterface

  (*conflict_free="evict_entry_to_memory,vb_fill_lines"*)
  module mkvictim_afterL1(Ifc_victim_afterL1#(wordsize,blocksize,sets, ways, paddr, size))
      provisos(
            Mul#(wordsize, 8, respwidth),        // respwidth is the total bits in a word
            Mul#(blocksize, respwidth,linewidth),// linewidth is the total bits in a cache line
            Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
            Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
            Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
            Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
            Add#(_a, setbits, _b),        // _b total bits for index+offset, 
            Add#(tagbits, _b, paddr),     // tagbits = 32-(wordbits+blockbits+setbits)

            Add#(a__, respwidth, linewidth),
            Add#(TAdd#(tagbits, setbits), b__, paddr),
            Add#(c__, TLog#(size), TLog#(TAdd#(1, size))),
            Add#(d__, respwidth, TSub#(linewidth, respwidth))
          );

    let v_sets=valueOf(sets);
    let v_setbits=valueOf(setbits);
    let v_wordbits=valueOf(wordbits);
    let v_blockbits=valueOf(blockbits);
    let v_linewidth=valueOf(linewidth);
    let v_tagbits=valueOf(tagbits);
    let verbosity=`VERBOSITY;
    let v_paddr=valueOf(paddr);
    let v_ways=valueOf(ways);
    let v_wordsize=valueOf(wordsize);
    let v_blocksize=valueOf(blocksize);
    let v_size=valueOf(size);

    // The following register is used enable or disable the VB.
    // When disabled all requests from the cache are redirected to the next level of memory.
    Reg#(Bool) rg_enable_vb <-mkReg(True);

    // The following three registers hold the data and control bits of the lines present in the VB.
    Reg#(Bit#(linewidth)) vb_datalines [v_size]; 
    Reg#(Bit#(TAdd#(tagbits,setbits))) vb_tagbits [v_size];
    Reg#(Bit#( size )) vb_valid <- mkReg(0);
    for (Integer i=0; i<v_size ; i=i+1) begin
      vb_datalines[i]<-mkReg(0);
      vb_tagbits[i]<-mkReg(0);
    end

    // The following register is used during the process of removing an entry from the VB and
    // writing it back to the memory.
    Reg#(Bit#(linewidth)) rg_writeback <- mkReg(0);
    // The following register is used during the process of filling up a line in the VB from the
    // cache.
    Reg#(Bit#(TSub#(linewidth,respwidth))) rg_swap_line <- mkReg(0);

    // The following 2 registers are used to index in the VB. The rg_enq buffer allocates a new
    // entry in the VB for a dirty line evicted from the cache. The rg_evict provides the index of
    // the line that needs to be removed from the VB when it is full or when it needs to be emptied.
    Reg#(Bit#(TLog#( size ))) rg_enq <- mkReg(0);
    Reg#(Bit#(TLog#( size ))) rg_evict <- mkReg(0);

    // The following 2 fifos are used to hold the requests to the memory for the line which is being
    // emptied from the VB when full or when being emptied
    FIFOF#(DMem_write_request#(paddr)) ff_write_request <- mkSizedFIFOF(2);
    FIFOF#(DMem_write_data#(respwidth)) ff_write_data <-mkSizedFIFOF(2);

    // The following 2 fifos hold a read requests for lines which were requested by the core and
    // were not present in the VB.
    FIFOF#(DMem_read_request#(paddr)) ff_read_request <- mkSizedFIFOF(2);
    FIFOF#(DMem_read_response#(respwidth)) ff_read_response <- mkSizedFIFOF(2);

    // The following fifo holds the response to the cache. When there is a hit in VB, one of the
    // vb_datalines is sent to the cache one-word at a time.
    FIFOF#(DMem_read_response#(respwidth)) ff_resp_to_cache <-mkSizedFIFOF(2);

    // The following fifo receives the data of a dirty line (one-word at a time) when cache
    // generates an eviction.
    FIFOF#(Tuple2#(Bit#(respwidth),Bool)) ff_data_frm_cache <-mkSizedFIFOF(2);


    // The following fifo is used to describe whether the cache request will be served by the memory
    // or by a line in the VB
    FIFOF#(RespType) ff_resp_type <-mkSizedFIFOF(1);

    // The following fifo holds the VB dataline which was found to be a hit for the line requested
    // the cache.
    FIFOF#(Bit#(linewidth)) ff_hit_line <-mkSizedFIFOF(2);

    // The following FIFO holds the tagbits and the index of the VB that correspond to the fill
    // requested by the cache. 
    FIFOF#(Tuple2#(Bit#(TAdd#(tagbits,setbits)),Bit#(TLog#(size)))) ff_vb_fill <-mkSizedFIFOF(2);

    // The following 2 registers are used to manage the word count while evicting line from the VB
    // or while filling up the VB from the cache respectively.
    Reg#(Bit#(TLog#(blocksize))) rg_evict_word_count<-mkReg(0);
    Reg#(Bit#(TLog#(blocksize))) rg_resp_word_count<-mkReg(0);

    // The following register is set when the cache is being fenced.
    Reg#(Bool) rg_perform_empty <-mkReg(False);


    // following are local variables to notify if the VB is full or empty. If both are false then VB
    // contains valid lines.
    Bool full = unpack(&vb_valid);
    Bool empty = !unpack(|vb_valid);

    // This rule is fired when the VB becomes full or when the cache has generated a fence
    // operation. When full a line indexed by rg_evict is removed and sent to memory. On a fence all
    // the lines are evicted and sent to the memory. 
    // The fence operation will only start when all previous requests before setting the
    // rg_perform_empty have been served.
    rule evict_entry_to_memory(full || rg_perform_empty);
      if(rg_evict_word_count==0)begin
        ff_write_request.enq(tuple3({vb_tagbits[rg_evict],'d0},
                                    fromInteger(v_blocksize-1),
                                    fromInteger(v_wordbits)));
        rg_writeback<=vb_datalines[rg_evict];
      end
      else begin
        if(rg_evict_word_count==fromInteger(v_blocksize-1))begin
          vb_valid[rg_evict]<=0;
          rg_evict<=rg_evict+1;
        end
        ff_write_data.enq(tuple2(rg_evict_word_count==fromInteger(v_blocksize-1),
                                 truncate(rg_writeback)));
        rg_evict_word_count<=rg_evict_word_count+1;
        rg_writeback<=rg_writeback>>(v_wordsize*8);
        if(rg_perform_empty)begin
          if(empty && !ff_data_frm_cache.notEmpty && !ff_vb_fill.notEmpty)
            rg_perform_empty<=False;
            rg_enq<=rg_evict;
        end
      end
    endrule

    // The following rule responds to the cache with the line which is a hit in the VB
    rule respond_to_core_frmVB(ff_resp_type.first()==RespondFromVB);
        Bit#(respwidth) l=truncate(rg_swap_line);
        if(rg_resp_word_count==fromInteger(v_blocksize-1))begin
          ff_resp_type.deq;
          ff_hit_line.deq;
        end
        if (rg_resp_word_count==0) begin
          l = truncate(ff_hit_line.first());
          rg_swap_line<=truncate(ff_hit_line.first()>>(v_wordsize*8));
        end
        else
          rg_swap_line<=rg_swap_line>>(v_wordsize*8);
          
        ff_resp_to_cache.enq(tuple3(l,
                                    False,
                                    rg_resp_word_count==fromInteger(v_blockbits-1)));
        rg_resp_word_count<=rg_resp_word_count+1;
    endrule
    
    // The following line responds to the cache with the data received by a read request to the next
    // level memory.
    rule respond_to_core_frmMem(ff_resp_type.first()==RespondFromMemory);
      let {data,err,last}=ff_read_response.first;
      ff_resp_to_cache.enq(ff_read_response.first);
      ff_read_response.deq;
      if(last)
        ff_resp_type.deq;
    endrule

    // The following rule is fired to fill an entry pf VB with a line evicted by the cache.
    rule vb_fill_lines(!full);
      let {data,last}=ff_data_frm_cache.first;
      let {evict_tag,evict_index}=ff_vb_fill.first;
      ff_data_frm_cache.deq;
      vb_datalines[evict_index]<=(vb_datalines[evict_index]<<(v_wordsize*8))|zeroExtend(data);
      if(last) begin
        vb_valid[evict_index]<=1'b1;
        vb_tagbits[evict_index]<=evict_tag;
        ff_vb_fill.deq;
      end
    endrule

    // This method checks if the request from the cache is a hit in the VB, if so, then capture the
    // hit line and initiate the response to the cache. This method also identifies the index in the
    // VB where a new dirty line from the cache should be placed.
    method Action req_frm_cache (Tuple2#(Bit#(paddr),Bool) read_req ,
                                Tuple2#(Bit#(paddr),Bool) evict_req)if(!full && !rg_perform_empty);
      let {read_addr, isRead}  = read_req;
      let {evict_addr,isEvict} = evict_req;

      Bit#(tagbits) read_tag = read_addr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) read_set = read_addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      Bit#(TAdd#(tagbits,setbits)) t={read_tag,read_set};
      Bit#(size) vb_hit=0;
      Bit#(linewidth) hitline=0;
      /*
      Bit#(linewidth) data_t [v_size];
      for (Integer i=0; i<v_size ; i=i+1) begin
        vb_hit[i]=pack( vb_valid[i]==1 && vb_tagbits[i]==t );
        data_t[i]=duplicate(vb_hit[i])&vb_datalines[i];
      end
      for(Integer i=0; i<v_size ;i=i+1)
        hitline=hitline|data_t[i];
      */
      for (Integer i=0;i<v_size;i=i+1)begin
        if( vb_valid[i]==1 && vb_tagbits[i]==t )begin
          vb_hit[i]=1;
          hitline=vb_datalines[i];
        end          
      end
      
      if(isRead)begin
        if(|vb_hit == 1 && rg_enable_vb)begin
          ff_hit_line.enq(hitline); // this is the line that needs to be responded to the cache
          ff_resp_type.enq(RespondFromVB);
        end
        else begin // There is a miss in the VB for requested line. send request to memory.
          ff_read_request.enq(tuple3(read_addr,fromInteger(valueOf(blocksize)-1),
                  fromInteger(valueOf(TLog#(wordsize))) ));
          ff_resp_type.enq(RespondFromMemory);
        end
      end      
      Bit#(tagbits) evict_tag = evict_addr[v_paddr-1:v_paddr-v_tagbits];
      Bit#(setbits) evict_set = evict_addr[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
      if(isEvict && rg_enable_vb) begin // If there is an eviction request from cache
        Bit#(TLog#(size)) evict_index=rg_enq;
        if(|vb_hit == 1 && isRead) // This will cause a swap
          evict_index=truncate(pack(countZerosLSB(vb_hit)));
        else // Else allocate a new line to fill the VB.
          rg_enq<=rg_enq+1;
        ff_vb_fill.enq(tuple2({evict_tag,evict_set},evict_index));
      end
    endmethod

    // this method receives the the dirtly line from the cache one word at a time.
    method Action data_from_cache(Tuple2#(Bit#(respwidth),Bool) wdata);
      ff_data_frm_cache.enq(wdata);
    endmethod

    // This method sends a write request to the memory.
    method ActionValue#(DMem_write_request#(paddr)) memory_request;
      ff_write_request.deq;
      return ff_write_request.first;
    endmethod
    // This method send the data for the corresponding write request.
    method ActionValue#(DMem_write_data#(respwidth)) memory_data;
      ff_write_data.deq;
      return ff_write_data.first;
    endmethod

    // This method sends the line back to the cache.
    method ActionValue#(DMem_read_response#(respwidth)) response_to_cache;
      ff_resp_to_cache.deq();
      return ff_resp_to_cache.first();
    endmethod
    
    // This method sends a read request to the memory.
    method ActionValue#(DMem_read_request#(paddr)) read_mem_req;
      ff_read_request.deq;
      return ff_read_request.first;
    endmethod
    
    // This methos receives the respons for the corresponding read request which was initiated.
    method Action read_mem_resp (DMem_read_response#(respwidth) resp);
      ff_read_response.enq(resp);
    endmethod

    // The following methods indicate the capcacity of the VB
    method vb_is_full=full; 
    method vb_is_empty=empty;

    // This method is fired when a fence operation is initiated by the cache.
    method Action empty_vb if(!rg_perform_empty);
      rg_perform_empty<=True;
    endmethod
    // This method is fired when the victim buffer needs to be enabled or disabled.
    method Action diablevictim (Bool d);
      rg_enable_vb<=d;
    endmethod
  endmodule

  (*synthesize*)
  (*conflict_free="empty_vb,evict_entry_to_memory"*)
  module mkvictim_afterL1_buffer(Ifc_victim_afterL1#(4 , 8 , 64 , 4 ,32, 32));
    let ifc();
    mkvictim_afterL1 _temp(ifc);
    return (ifc);
  endmodule
endpackage

