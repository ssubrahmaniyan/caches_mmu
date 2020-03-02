/* 
Copyright (c) 2019, IIT Madras All rights reserved.

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
package llc_bank;
  `include "Logger.bsv"
  import FIFO :: * ;
  import FIFOF :: * ;
  import SpecialFIFOs :: * ;
  import Vector :: * ;
  import OInt :: * ;
  
  import mem_config :: * ;
  
  import ShaktiLink_Types ::*;
  import Semi_FIFOF ::*;
  import coherence_types :: * ;
  import llc_bank_replacement :: * ;

  `include "coherence.defines"
  
  interface Ifc_llc_bank#(numeric type a, numeric type w, numeric type o, 
                        numeric type i, numeric type op, numeric type acks, numeric type u,
                        numeric type wordsize, numeric type blocksize, numeric type sets,
                        numeric type ways);
    interface Ifc_slc_master#(a,w,o,i,op,acks,u) master_side;
    interface Ifc_slc_slave#(a,w,o,i,op,acks,u) slave_side;
  endinterface

  typedef enum {Idle, Cache_read, Multi_cast, Memory_wait} LLC_state deriving(Bits, Eq, FShow);
  typedef SizeOf#(ENTRY_Dict#(TDiv#(`linesize,8))) V_dir_size;

  typedef struct{
    Bit#(a) address;
    ENTRY_Dict#(w) dataline;
  } EvictMeta#(numeric type a, numeric type w, numeric type ways) deriving(Bits, FShow, Eq);

  function Message#(a,w) fn_from_req_pkt(Req_channel#(a,w,o,i,op,u) r)
    provisos(
      Add#(a__, 2, i),
      Add#(b__, 2, o),
      Add#(c__, 4, op)
    );
  
    let m = Message {address: r.address,
                        msgtype: unpack(truncate(r.opcode)),
                        src : unpack(truncate(r.source)),
                        dst : unpack(truncate(r.dest)),
                        acksExpected : 0,
                        cl : r.data};
    return m;
  endfunction
  function Fwd_channel#(a,w,o,i,op,u) fn_gen_fwd_pkt(Message#(a,w) m, Bit#(u) user)
    provisos(Add#(a__, 2, i),Add#(b__, 2, o),Add#(c__, 4, op));
    let _r = Fwd_channel{ opcode: zeroExtend(pack(m.msgtype)),
                          source: zeroExtend(pack(m.src)), 
                          dest:signExtend(pack(m.dst)), 
                          address:m.address, 
                          mask:'1,
                          data:m.cl, 
                          user: user}; 
    return _r;
  endfunction
  
  function Resp_channel#(a,w,o,i,op,acks,u) fn_gen_resp_pkt(Message#(a,w) m, Bit#(u) user)
    provisos(Add#(a__, 2, i),Add#(c__, 4, op),Add#(d__, 2, o),Add#(e__, 1, acks));
    let _r = Resp_channel{ opcode: zeroExtend(pack(m.msgtype)),
                          acksExpected:zeroExtend(m.acksExpected),
                          last: True,
                          source: zeroExtend(pack(m.src)), 
                          dest: signExtend(pack(m.dst)), 
                          address:m.address, 
                          corrupt:0,
                          data:m.cl,
                          user: user}; 
    return _r;
  endfunction
  function Message#(a,w) fn_from_resp_pkt(Resp_channel#(a,w,o,i,op,acks,u) r)
    provisos(Add#(a__, 2, i),Add#(c__, 4, op),Add#(d__, 2, o),Add#(e__, 1, acks));
    let m = Message {address: r.address,
                        msgtype: unpack(truncate(r.opcode)),
                        src : unpack(truncate(r.source)),
                        dst : unpack(truncate(r.dest)),
                        acksExpected : truncate(r.acksExpected),
                        cl : r.data};
    return m;
  endfunction
  

  (*conflict_free="rl_receive_io_response, rl_pick_request_on_slave"*)
  module mkllc_bank#(parameter Bit#(32) id)
    (Ifc_llc_bank#(a,w,o,i,op,acks,u, wordsize, blocksize, sets, ways))
    provisos(
          Mul#(wordsize, 8, respwidth),        // respwidth is the total bits in a word
          Mul#(blocksize, respwidth,linewidth),// linewidth is the total bits in a cache line
          Log#(wordsize,wordbits),      // wordbits is no. of bits to index a byte in a word
          Log#(blocksize, blockbits),   // blockbits is no. of bits to index a word in a block
          Log#(sets, setbits),           // setbits is the no. of bits used as index in BRAMs.
          Add#(wordbits,blockbits,_a),  // _a total bits to index a byte in a cache line.
          Add#(_a, setbits, _b),        // _b total bits for index+offset,
          Add#(tagbits, _b, a),     // tagbits = 32-(wordbits+blockbits+setbits)
          Bits#(coherence_types::ENTRY_Dict#(w), _c),

          Add#(a__, 4, op),
          Add#(i,0,o),
          Add#(b__, TLog#(ways), TLog#(TAdd#(1, ways))),
          Add#(c__, 2, o),
          Add#(d__, 1, acks)
        );

    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);
    let v_setbits=valueOf(setbits);
    let v_wordbits=valueOf(wordbits);
    let v_blockbits=valueOf(blockbits);
 
    // --------------------------- sub module instantiations ------------------------------------//
    Ifc_slc_slave_agent#(a,w,o,i, op,acks,u) slave <- mkslc_slave_agent;
    Ifc_slc_master_agent#(a,w, o, i, op,acks,u) master <- mkslc_master_agent;
    Ifc_replace#(sets,ways) replacement <- mkreplace("RROBIN");
    Ifc_mem_config2rw#(sets, TAdd#(1,tagbits),1) tag [v_ways];
    Ifc_mem_config2rw#(sets, _c,1) data [v_ways];
    for (Integer i = 0; i<v_ways; i = i + 1) begin
      tag[i] <- mkmem_config2rw(False, "double");
      data[i] <- mkmem_config2rw(False, "double");
    end
    // ------------------------------------------------------------------------------------------//


    // --------------------------- registers instantiations ------------------------------------//
    /*doc:reg: controls the state of the LLC controller*/
    Reg#(LLC_state) rg_state <- mkReg(Idle);
    /*doc:reg: set True on reset. initializes fencing op*/
    Reg#(Bool) rg_init <- mkReg(True);
    /*doc:reg: index to access the rams in fencing stage.*/
    Reg#(Bit#(TLog#(sets))) rg_init_index <- mkReg(0);
    /*doc:reg: when true indicates a multicast op needs to be handled.*/
    Reg#(Message#(a,w)) rg_multi_cast <- mkReg(unpack(0));
    /*doc:reg: the shared-vector for a multi-cast op*/
    Reg#(Bit#(`NrCaches)) rg_sv <- mkReg(0);
    /*doc:reg: */
    Reg#(Bit#(u)) rg_user <- mkReg(unpack(0));
    /*doc:reg: holds the information for performing an eviction*/
    Reg#(EvictMeta#(a,w,ways)) rg_evict_meta <- mkReg(unpack(0));
    /*doc:reg: indicates the way that needs to be replaced to fill the response from memory*/
    Reg#(Bit#(TLog#(ways))) rg_replace_way <- mkReg(0);
    /*doc:reg: when true will evict line to the memory*/
    Reg#(Bool) rg_perform_evict <- mkReg(False);
    /*doc:reg: */
    Reg#(Bool) rg_read_phase <- mkReg(False);
    /*doc:reg: */
    Reg#(Bit#(TLog#(`NrCaches))) rg_dest_count <- mkReg(0);

	
	  /*doc:fifo: holds the current request from the fabric*/
	  FIFOF#(Req_channel#(a,w,o,i,op,u)) ff_llc_req <- mkUGSizedFIFOF(2);
  
    /*doc:rule: */
    rule rl_display_stuff;
      `logLevel( llc_bank, 0, $format("LLC[%2d]: rg_state:",id,fshow(rg_state)))
      `logLevel( llc_bank, 0, $format("LLC[%2d]: RESPNE:%b FWDNF:%b RESPNF:%b REQNF:%b",id,
        master.o_resp_channel.notEmpty,slave.i_fwd_channel.notFull, slave.i_resp_channel.notFull
        , master.i_req_channel.notFull))
    endrule
    /*doc:rule: initializes the entire RAM to a default state.*/
    rule rl_initialise(rg_init && rg_state == Idle);
      ENTRY_Dict#(w) def = ENTRY_Dict{state:Dict_I, perm:None, sv:0,cl:0,owner:tagged Directory,
                                      id:tagged Directory};
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        tag[i].p1.request(1,rg_init_index,0);
        data[i].p1.request(1,rg_init_index, pack(def));
      end
      if(rg_init_index == fromInteger(v_sets-1))
        rg_init <= False;
      rg_init_index <= rg_init_index + 1;
      `logLevel( llc_bank, 0, $format("LLC[%2d]: Fencing Index:%d",id,rg_init_index))
    endrule

    /*doc:rule: processes the request from the fabric. If a hit is detected then the corresponding
    * response, fwd, multicast is initiated. On a miss, the request is sent to the Memory*/
    rule rl_process_request(rg_state == Cache_read && !rg_init && ff_llc_req.notEmpty);
      let req = ff_llc_req.first;
      Bit#(tagbits) intag = truncateLSB(req.address);
			Bit#(setbits) index = req.address[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
			`logLevel( llc_bank, 0, $format("LLC[%2d]: Processing Req. set:%d tag:%h",id,index,intag))
      Bit#(ways) lv_hit;
      Vector#(ways, ENTRY_Dict#(w)) datalines;
      Vector#(ways, Bit#(TAdd#(1,tagbits))) tags;
      Vector#(ways, Dict) states;
      Bit#(ways) valids;

      for (Integer i = 0; i<v_ways; i = i + 1) begin
        lv_hit[i] = pack(intag == truncate(tag[i].p1.read_response) && 
                          truncateLSB(tag[i].p1.read_response) == 1'b1);
        datalines[i] = unpack(data[i].p1.read_response);
        tags[i] = tag[i].p1.read_response;
        valids[i] = truncateLSB(tag[i].p1.read_response);
      end
      for (Integer i = 0; i<v_ways; i = i + 1) begin
        states[i] = datalines[i].state;
      end

      let dataline = select(datalines,unpack(lv_hit));
      let tag_entry = select(tags, unpack(lv_hit));
      Bit#(1) lv_tag_valid = truncateLSB(tag_entry);
      Bit#(tagbits) lv_tag= truncate(tag_entry);
		
		  Bit#(TLog#(ways)) hit_way_id=truncate(pack(countZerosLSB(lv_hit))); 

      Bool hit = unpack(|lv_hit);
     
  		Message#(a,w) inmsg = fn_from_req_pkt(req); 
			`logLevel( llc_bank, 0, $format("LLC[%2d]: valids:%b states:",id,valids,fshow(states)))
      if( hit )begin
			  replacement.update_set(index,hit_way_id);
			  let lv_update = func_Dict(inmsg, dataline);
			  let new_cle = lv_update.new_cle;
			  let resp = lv_update.send_resp1;
			  let fwd = lv_update.send_fwd1;
			  let multi_cast = lv_update.send_multicast;
			  data[hit_way_id].p1.request('1, index, pack(new_cle));
			  if(fwd matches tagged Valid. send_fwd) begin
			  	let packet = fn_gen_fwd_pkt(send_fwd, req.user);
			  	slave.i_fwd_channel.enq(packet);
			  	`logLevel( llc_bank, 0, $format("LLC[%2d]: Sending FWD:",id,fshow(send_fwd)))
			  end
			  else if(resp matches tagged Valid .send_resp) begin
			  	let packet = fn_gen_resp_pkt(send_resp, req.user); 
			  	slave.i_resp_channel.enq(packet);
			  	`logLevel( llc_bank, 0, $format("LLC[%2d]: Sending RESP:",id, fshow(send_resp)))
			  end
			  if(multi_cast matches tagged Valid .send_multi_cast) begin
			  	let {msg, sv} = send_multi_cast;
			  	if(sv !=0 ) begin
  		  		rg_state <= Multi_cast; 
	  	  		rg_multi_cast <= msg;
		    		rg_sv <= sv;
		    		rg_user <= req.user;
		    		rg_dest_count <= 0;
			    	`logLevel( llc_bank, 0, $format("LLC[%2d]: Initiating Multicast: sv:%b",id,
			    	  sv,fshow(send_multi_cast)))
			    end
			    else 
			      rg_state <= Idle;
			  end
			  else begin
			  	rg_state<=Idle;
			  end
        `logLevel( llc_bank, 0, $format("LLC[%2d]: HIT for Req: ",id, fshow(req)))
        `logLevel( llc_bank, 0, $format("LLC[%2d]: Hit vector:%b valid:%b",id,lv_hit,lv_tag_valid))
        `logLevel( llc_bank, 0, $format("LLC[%2d]: Hit DirEntry:",id,fshow(dataline)))
        `logLevel( llc_bank, 0, $format("LLC[%2d]: New DirEntry:",id,fshow(new_cle)))
        

			  ff_llc_req.deq;
      end
      else begin
			  let replace_way <- replacement.line_replace(index, valids, states);
			  rg_replace_way <= replace_way;
			  Req_channel#(a,w,o,i,op,u) req_rd = Req_channel { opcode : zeroExtend(pack(GetS)), 
			  																									len    : 0,
			  																									size   : 3, 
			  																									mode   : 0,//TODO  
			  																									source : req.dest, 
			  																									dest 	 : 4,
			  																									address : req.address,
			  																									mask : 0,
			  																									data : ?, 
			  																									user : req.user};
			  master.i_req_channel.enq(req_rd);
			  rg_state<=Memory_wait;

			  // Eviction data
			  if(valids[replace_way] == 1) begin
			    rg_perform_evict<= True;
			    Bit#(tagbits) e_tag = truncate(tags[replace_way]);
			    Bit#(setbits) e_index = index;
			    Bit#(TSub#(a,TAdd#(tagbits, setbits))) zeros = 0;
			    EvictMeta#(a,w,ways) lv_meta = EvictMeta{address:{e_tag, e_index, zeros},
                          			    dataline:datalines[replace_way]};
          rg_evict_meta <= lv_meta;
          `logLevel( llc_bank, 0, $format("LLC[%2d]: Will Evict:",id,fshow(lv_meta)))
			  end
		  
        `logLevel( llc_bank, 0, $format("LLC[%2d]: Choosing Way:%d for Replacement",id,replace_way))
		    `logLevel( llc_bank, 2, $format("LLC[%2d]: Miss for Req ",id, fshow(req)))
			  `logLevel( llc_bank, 0, $format("LLC[%2d]: Sending Req on Master:",id,fshow(req_rd)))
      end
    endrule

    /*doc:rule: Receives the response from the Memory for a missed line. Updates the line and
    * thereby initiates the response, fwd or multicast. If the line being replaced is dirty then it
    * needs to be evicted.*/
    rule rl_receive_io_response(!rg_init && rg_state != Multi_cast && rg_state != Cache_read);
      let resp = master.o_resp_channel.first;
      //master.o_resp_channel.deq;
      let req = ff_llc_req.first;
      `logLevel( llc_bank, 0, $format("LLC[%2d]: Received response on Master. readphase:%b state:",
        id, rg_read_phase, fshow(rg_state)))

      if(ff_llc_req.notEmpty && rg_state == Memory_wait && resp.address == ff_llc_req.first.address) begin
        Bit#(tagbits) intag = truncateLSB(req.address);
  			Bit#(setbits) index = req.address[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
  	    ff_llc_req.deq;
  	    Message#(a,w) inmsg = fn_from_req_pkt(req); 
		    ENTRY_Dict#(w) cle = ENTRY_Dict { state : Dict_I, 
			  														perm  : None,	
			  														cl    : resp.data,
			  														sv    : 0,
			  														owner : tagged Directory,
			  														id 		: tagged Directory}; //TODO need to check this
			  let lv_update = func_Dict(inmsg, cle);
			  let new_cle = lv_update.new_cle;
			  let cle_resp = lv_update.send_resp1;
			  let fwd = lv_update.send_fwd1;
			  let multi_cast = lv_update.send_multicast;
			  tag[rg_replace_way].p1.request(1,index,{1'b1,intag});
			  data[rg_replace_way].p1.request(1,index,pack(new_cle));
			  if(fwd matches tagged Valid. send_fwd) begin
			  	let packet = fn_gen_fwd_pkt(send_fwd, req.user);
			  	slave.i_fwd_channel.enq(packet);
			  	`logLevel( llc_bank, 0, $format("LLC[%2d]: MemResp: Sending FWD:",id,fshow(send_fwd)))
			  end
			  else if(cle_resp matches tagged Valid .send_resp) begin
			  	let packet = fn_gen_resp_pkt(send_resp, req.user); 
			  	slave.i_resp_channel.enq(packet);
			  	`logLevel( llc_bank, 0, $format("LLC[%2d]: MemResp: Sending RESP:",id, fshow(send_resp)))
			  end
			  if(multi_cast matches tagged Valid .send_multi_cast) begin
			  	let {msg, sv} = send_multi_cast;
			  	if(sv !=0 ) begin
  		  		rg_state <= Multi_cast; 
	  	  		rg_multi_cast <= msg;
		    		rg_sv <= sv;
		    		rg_user <= req.user;
		    		rg_dest_count <= 0;
			    	`logLevel( llc_bank, 0, $format("LLC[%2d]: MemResp: Initiating Multicast:",id,
			    	                                fshow(send_multi_cast)))
			    end
			    else 
			      rg_state <= Idle;
			  end
			  else begin
			  	rg_state<=Idle;
			  end
			  master.o_resp_channel.deq;
 
        `logLevel( llc_bank, 0, $format("LLC[%2d]: MemResp: ",id,fshow(resp)))
        `logLevel( llc_bank, 0, $format("LLC[%2d]: Resp for Req:",id,fshow(req)))
        `logLevel( llc_bank, 0, $format("LLC[%2d]: Upd index:%d tag:%h ways:%d CLE:",id,index,intag,
                                          rg_replace_way, fshow(new_cle)))
		    if(rg_perform_evict) begin
		    	Req_channel#(a,w,o,i,op,u) req_rd = Req_channel { opcode : zeroExtend(pack(PutM)), 
		    																										len    : 0,
		    																										size   : 3, 
		    																										mode   : 0,//TODO specify
		    																										source : req.dest, 
		    																										dest 	 : 4,
		    																										address : rg_evict_meta.address,
		    																										mask : '1,
		    																										data : rg_evict_meta.dataline.cl, 
		    																										user : req.user};
		    	master.i_req_channel.enq(req_rd);
		    	rg_perform_evict<= False;
		    	`logLevel( llc_bank, 0, $format("LLC[%2d]: Evicting :",id,fshow(rg_evict_meta)))
		    end
		  end
		  else begin
        Bit#(tagbits) intag = truncateLSB(resp.address);
  			Bit#(setbits) index = resp.address[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
		    if(rg_read_phase) begin
			    master.o_resp_channel.deq;
          Bit#(ways) lv_hit;
          Vector#(ways, ENTRY_Dict#(w)) datalines;
          Vector#(ways, Bit#(TAdd#(1,tagbits))) tags;
          Vector#(ways, Dict) states;
          Bit#(ways) valids;

          for (Integer i = 0; i<v_ways; i = i + 1) begin
            lv_hit[i] = pack(intag == truncate(tag[i].p2.read_response) && 
                                     truncateLSB(tag[i].p2.read_response) == 1'b1);
            datalines[i] = unpack(data[i].p2.read_response);
            tags[i] = tag[i].p2.read_response;
            valids[i] = truncateLSB(tag[i].p2.read_response);
          end
          for (Integer i = 0; i<v_ways; i = i + 1) begin
            states[i] = datalines[i].state;
          end

          let dataline = select(datalines,unpack(lv_hit));
          let tag_entry = select(tags, unpack(lv_hit));
          Bit#(1) lv_tag_valid = truncateLSB(tag_entry);
          Bit#(tagbits) lv_tag= truncate(tag_entry);
		
		      Bit#(TLog#(ways)) hit_way_id=truncate(pack(countZerosLSB(lv_hit))); 

          Bool hit = unpack(|lv_hit);
     
  		    Message#(a,w) inmsg = fn_from_resp_pkt(resp); 
  		    `logLevel( llc_bank, 0, $format("LLC[%2d]: InMsg:",id,fshow(inmsg)))
			    let lv_update = func_Dict(inmsg, dataline);
			    let new_cle = lv_update.new_cle;
			    let resp1 = lv_update.send_resp1;
			    let fwd = lv_update.send_fwd1;
			    let multi_cast = lv_update.send_multicast;
			    `logLevel( llc_bank, 0, $format("LLC[%2d]: OldCLE:",id,fshow(dataline)))
			    `logLevel( llc_bank, 0, $format("LLC[%2d]: NewCLE:",id,fshow(new_cle)))
			    data[hit_way_id].p2.request('1, index, pack(new_cle));
			    if(fwd matches tagged Valid. send_fwd) begin
			    	let packet = fn_gen_fwd_pkt(send_fwd, resp.user);
			    	slave.i_fwd_channel.enq(packet);
			    	`logLevel( llc_bank, 0, $format("LLC[%2d]: Sending FWD:",id,fshow(send_fwd)))
			    end
			    else if(resp1 matches tagged Valid .send_resp) begin
			    	let packet = fn_gen_resp_pkt(send_resp, resp.user); 
			    	slave.i_resp_channel.enq(packet);
			    	`logLevel( llc_bank, 0, $format("LLC[%2d]: Sending RESP:",id, fshow(send_resp)))
			    end
			    rg_read_phase <= False;
		    end
		    else begin
	        for (Integer i = 0; i<v_ways; i = i + 1) begin
	          tag[i].p2.request(0,index,?);
	          data[i].p2.request(0,index,?);
	        end
	        rg_read_phase <= True;
	        `logLevel( llc_bank, 0, $format("LLC[%2d]: performing read of BRAMs. Index:%d",id,index))
		    end
		  end
    endrule

	  rule rl_send_multi_cast(rg_state==Multi_cast && !rg_init);
      `logLevel( llc_bank, 0, $format("LLV[%2d]: RGSV:%b",id,rg_sv))
	  	let msg = rg_multi_cast;
	  	if(rg_sv[0]==1) begin
	  		msg.dst = tagged Caches rg_dest_count;	
	  		msg.src = msg.src;	
	  	  let packet = fn_gen_fwd_pkt(msg, rg_user);
	  	  slave.i_fwd_channel.enq(packet);
	  	  `logLevel( llc_bank, 0, $format("LLC[%2d]: Sending MultiCast FWD:",id,fshow(msg)))
	  	end
	  	if(rg_sv==0) begin
	  		rg_state <= Idle;
	  	end
	  	rg_sv <= rg_sv >> 1;
	  	rg_dest_count <= rg_dest_count + 1;
	  endrule

	  /*doc:rule: this rule receives the request from the fabric initiated by any of the caches*/
	  rule rl_pick_request_on_slave(rg_state == Idle && !rg_init && ff_llc_req.notFull);
	    let req <- pop_o(slave.o_req_channel);
			let index = req.address[v_setbits+v_blockbits+v_wordbits-1:v_blockbits+v_wordbits];
	    for (Integer i = 0; i<v_ways; i = i + 1) begin
	      tag[i].p1.request(0,index,?);
	      data[i].p1.request(0,index,?);
	    end
		  rg_state<=Cache_read;
  		ff_llc_req.enq(req);
  		`logLevel( llc_bank, 0, $format("LLC[%2d]: Received New req:",id,fshow(req)))
	  endrule

	  interface slave_side = slave.shaktilink_side;
  	interface master_side = master.shaktilink_side;

  endmodule
  

endpackage

