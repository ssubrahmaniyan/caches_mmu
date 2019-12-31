package llc_cache;

import llc_types:: *;
import GetPut ::*;
import mem_config ::*;
import Vector ::*;
import FIFO ::*;
import SpecialFIFOs ::*;
import replacement_cache ::*;
import BUtils ::*;
import Randomizable ::*;
import coherence_types ::*;
import cache_controller ::*;
import ShaktiLink_Types ::*;
import Semi_FIFOF ::*;
`include "coherence.defines"
`include "llc.defines"
`include "Logger.bsv"

typedef enum {Idle, Cache_read, Multi_cast, Memory_wait} LLC_state deriving(Bits, Eq);

interface Ifc_llc_bank#(numeric type a, numeric type w, numeric type o, 
                        numeric type i, numeric type op, numeric type acks, numeric type u);
    interface Ifc_slc_master#(a,w,o,i,op,acks,u) master_side;
    interface Ifc_slc_slave#(a,w,o,i,op,acks,u) slave_side;
endinterface

function Integer toInteger(Bit#(TLog#(`ways)) ways);
	Integer return_ways=0;
	for(Integer i=0; i<`ways; i=i+1) begin
		if(ways == fromInteger(i)) begin
			return_ways = i;	
		end
	end
	return return_ways;
endfunction

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

typedef SizeOf#(ENTRY_Dict#(TDiv#(`linesize,8))) V_dir_size;
module mkllc_bank#(parameter Integer id)(Ifc_llc_bank#(a,w,o,i,op,acks,u))
  provisos(
    Log#(w, b_offset),
    Log#(`sets,index),
    Add#(b_offset, index, _a),
    Add#(tag_width,_a,a),
    Add#(tag_width,index,line_addr),
    Mul#(`linesize,8,_b),
    Div#(_b,`bus_width,no_bursts),
    Bits#(coherence_types::ENTRY_Dict#(w), 74),

    Add#(a__, 1, TMul#(w, 8)),
    Add#(c__, 4, op),
    Add#(d__, 2, o),
    Add#(e__, 2, i),
    Add#(f__, 1, acks),
    Add#(i,0,o)

  );
	let v_tag_width = valueOf(tag_width);
	let v_index = valueOf(index);
	let v_b_offset = valueOf(b_offset);
	let v_bus_mask = valueOf(TDiv#(`bus_width,8));
	let v_size_line = valueOf(TLog#(TDiv#(`linesize, 9)));
	let v_a = valueOf(a);
	//let v_dir_size = SizeOf(ENTRY_Dict_info);
	//let v_dir_bits = valueOf(TSub#(v_dir_size,`linesize));

	Ifc_mem_config1r1w#(`sets, TAdd#(2,tag_width), 1)  tag[`ways];
	Ifc_mem_config1r1w#(`sets, V_dir_size, 1)  	 dir[`ways];	

	//replacement way
	Ifc_replace#(`sets, `ways) repl <- mkreplace("RROBIN");

	for(Integer i=0; i<`ways; i=i+1) begin
		tag[i] <- mkmem_config1r1w(False, "double");
		dir[i] <- mkmem_config1r1w(False, "double");
	end

	FIFO#(Req_channel#(a,w, o,i,op,u)) ff_llc_req <- mkPipelineFIFO();
	Reg#(LLC_state) rg_state <- mkReg(Idle);
	Reg#(Bit#(`NrCaches)) rg_sv <- mkReg(0);
	Reg#(Message#(a,w)) rg_multi_cast <- mkRegU();
	Reg#(Bit#(index)) rg_indirection_index <- mkReg(0);
	Reg#(Bit#(TMul#(w,8))) rg_data <- mkReg(?);
	Vector#(no_bursts, Reg#(Bit#(`bus_width))) rg_data_burst <- replicateM(mkReg(?));
	Reg#(Bit#(TLog#(`ways))) rg_replace_way_l1 <- mkReg(0);
	Reg#(Bit#(TLog#(`ways))) rg_replace_way <- mkReg(0);
	Reg#(Bool) rg_evict <- mkReg(False);
	Reg#(Bit#(TLog#(`sets))) rg_flush_set <- mkReg(0);
	Reg#(Bool) rg_full_flush <- mkReg(False);
	Reg#(Line_metadata#(a, TMul#(w,8))) rg_metadata <- mkReg(?);
	//Random replacement
  Ifc_slc_slave_agent#(a,w,o,i, op,acks,u) slave <- mkslc_slave_agent;
  Ifc_slc_master_agent#(a,w, o, i, op,acks,u) master <- mkslc_master_agent;


	Vector#(no_bursts, Reg#(Bit#(`bus_width))) rg_cache <- replicateM(mkReg(0)); 
	Reg#(Bool) rg_cache_full <- mkReg(False); 
	rule rl_read_cache(rg_state==Cache_read);
		Req_channel#(a,w,o,i,op,u) req = ff_llc_req.first;
		`logLevel( llc, 0, $format("LLC[%2d]: Processing Req:",id,fshow(req)))
		Bool hit;
		Bit#(tag_width) in_tag=req.address[v_a-1:v_b_offset+v_index];
		Bit#(`ways) hit_way;
		Bit#(`ways) valid;
		for(Integer i=0; i<`ways; i=i+1) begin
			valid[i]=truncateLSB(tag[i].read_response);
		end
		for(Integer i=0; i<`ways; i=i+1) begin
			hit_way[i]=pack(in_tag==truncate(tag[i].read_response)) & valid[i];
		end
		Vector#(`ways, Bit#(TMul#(w,8))) data_sram;
		hit = unpack(|hit_way);
		for(Integer i=0; i<`ways; i=i+1) begin
			ENTRY_Dict#(w) data_frm_way = unpack(dir[i].read_response);
			data_sram[i] = (signExtend(hit_way[i])|data_frm_way.cl);
		end
		Bit#(TLog#(`ways)) hit_way_id=truncate(pack(countZerosLSB(hit_way))); 
		Bit#(TMul#(w,8)) data_resp=0; 
		for(Integer i=0; i<`ways; i=i+1) begin
			data_resp = data_resp | data_sram[i];
		end
		Bit#(`ways) is_valid='1;
		for(Integer i=0; i<`ways; i=i+1) begin
			Bit#(tag_width) sram_tag = truncate(tag[i].read_response);
			ENTRY_Dict#(w) lv_dir_info = unpack(dir[i].read_response);	
			if(lv_dir_info.state!=Dict_I) begin	
				is_valid[i]=0;
			end
		  //`logLevel( llc, 2, $format("LLC[%2d]:tags %h in the way %d valid %b",id, 
			//																											sram_tag, i, valid[i]))
		end
		if(hit) begin
  		Message#(a,w) inmsg = fn_from_req_pkt(req); 
			ENTRY_Dict#(w) lv_dir_info = unpack(dir[hit_way_id].read_response);	
			let {dir_entry, resp, fwd, multi_cast} = func_Dict(inmsg, lv_dir_info);
			dir[hit_way_id].write('1, req.address[v_a-v_tag_width-1:v_b_offset], pack(dir_entry));
			`logLevel( llc, 0, $format("LLC[%2d]: DirEntry:",id, fshow(lv_dir_info)))
			`logLevel( llc, 0, $format("LLC[%2d]: New DirEntry:",id, fshow(dir_entry)))
			if(fwd matches tagged Valid. send_fwd) begin
				let packet = fn_gen_fwd_pkt(send_fwd);
				slave.i_fwd_channel.enq(packet);
				`logLevel( llc, 0, $format("LLC[%2d]: Sending FWD:",id,fshow(send_fwd)))
			end
			else if(resp matches tagged Valid .send_resp) begin
				let packet = fn_gen_resp_pkt(send_resp); 
				slave.i_resp_channel.enq(packet);
				`logLevel( llc, 0, $format("LLC[%2d]: Sending RESP:",id, fshow(send_resp)))
			end
			if(multi_cast matches tagged Valid .send_multi_cast) begin
				let {msg, sv} = send_multi_cast;
				if(sv !=0 ) begin
  				rg_state <= Multi_cast; 
	  			rg_multi_cast <= msg;
		  		rg_sv <= sv;
			  	`logLevel( llc, 0, $format("LLC[%2d]: Initiating Multicast:",id,fshow(send_multi_cast)))
			  end
			  else 
			    rg_state <= Idle;
			end
			else begin
				rg_state<=Idle;
			end
			ff_llc_req.deq;
			repl.update_set(req.address[v_a-v_tag_width-1:v_b_offset], hit_way_id);
		end
		else begin
			Req_channel#(a,w,o,i,op,u) req_rd = Req_channel { opcode : zeroExtend(pack(GetS)), 
																												len    : 0,
																												size   : fromInteger(v_size_line), 
																												mode   : 0,//TODO  
																												source : req.dest, 
																												dest 	 : 4,
																												address : req.address,
																												mask : 0,
																												data : ?, 
																												user : ?};
			master.i_req_channel.enq(req_rd);
		  `logLevel( llc, 2, $format("LLC[%2d]:Miss for address %h ",id, req.address))
			`logLevel( llc, 0, $format("LLC[%2d]: Sending Req on Master:",id,fshow(req_rd)))
			rg_state<=Memory_wait;
			Bit#(TLog#(`ways)) replace_way<-repl.line_replace(req.address[v_a-v_tag_width-1:v_b_offset], 
																											 is_valid);
			repl.update_set(req.address[v_a-v_tag_width-1:v_b_offset], replace_way);
			rg_replace_way<= replace_way;
      Bit#(2) vd=truncateLSB(tag[replace_way].read_response);
      Bit#(1) dirty = vd[0];
			Bit#(tag_width) tag_metadata=truncate(tag[replace_way].read_response);
			Line_metadata#(a, TMul#(w,8)) metadata;
			ENTRY_Dict#(w) dict_entry = unpack(dir[replace_way].read_response);
			metadata.data=dict_entry.cl;
			Bit#(b_offset) _b_offset=0;
			Bit#(index) index=req.address[v_index+v_b_offset-1:v_b_offset];
			metadata.addr={tag_metadata, index, 0}; 
			metadata.dirty=unpack(dirty);
			rg_metadata <= metadata;
			`logLevel( llc, 2, $format("LLC[%2d]:Address %h, way %d index %d redirected",id, 
																																metadata.addr, replace_way, index))
			if(&(valid)==1 && dirty==1) begin
				rg_evict<=True;
			end
		end
	endrule

	rule rl_access_cache(rg_state==Idle);
		let req <- pop_o(slave.o_req_channel);
		for(Integer i=0; i<`ways; i=i+1) begin
			let index = req.address[v_index+v_b_offset-1:v_b_offset];
			tag[i].read(index);
			dir[i].read(index);
		end
		rg_state<=Cache_read;
		ff_llc_req.enq(req);
		`logLevel( llc, 0, $format("LLC[%2d]: Received Req: ",id, fshow(req)))
	endrule

	rule rl_send_write_req(rg_state==Memory_wait);
		Req_channel#(a,w,o,i,op,u) req = ff_llc_req.first;
		Bit#(index) index=req.address[v_index+v_b_offset-1:v_b_offset];
		Bit#(tag_width) in_tag=truncateLSB(req.address);
		ff_llc_req.deq;
  	Message#(a,w) inmsg = fn_from_req_pkt(req); 
		let mem_resp <- pop_o(master.o_resp_channel);
		ENTRY_Dict#(w) cle = ENTRY_Dict { state : Dict_I, 
																	perm  : None,	
																	cl    : mem_resp.data,
																	sv    : 0,
																	owner : tagged Directory,
																	id 		: tagged Directory}; //TODO need to check this
	
		let {dir_entry, resp, fwd, multi_cast} = func_Dict(inmsg, cle);
		if(resp matches tagged Valid .send_resp) begin
			`logLevel( llc, 0, $format("LLC[%2d]: Sending Response: ",id,fshow(send_resp)))
			`logLevel( llc, 0, $format("LLC[%2d]: NewCLE:",id,fshow(dir_entry)))
			`logLevel( llc, 0, $format("LLC[%2d]: Allocating Addr:%h set:%d way:%d tag:%h",id,req.address,
			    index, rg_replace_way,in_tag))
			let packet = fn_gen_resp_pkt(send_resp);
			slave.i_resp_channel.enq(packet);
			tag[rg_replace_way].write(1,index,{2'b10,in_tag});
			dir[rg_replace_way].write(1,index,pack(dir_entry));
		end
		if(rg_evict) begin
			Req_channel#(a,w,o,i,op,u) req_rd = Req_channel { opcode : zeroExtend(pack(PutM)), 
																												len    : 0,
																												size   : fromInteger(v_size_line), 
																												mode   : 0,//TODO specify
																												source : req.dest, 
																												dest 	 : 4,
																												address : rg_metadata.addr,
																												mask : '1,
																												data : rg_metadata.data, 
																												user : ?};
			master.i_req_channel.enq(req_rd);
			`logLevel( llc, 0, $format("LLC[%2d]: Evicting Addr:%h Data:%h",id,
                          			  rg_metadata.addr,rg_metadata.data))
			rg_evict <= False;
		end
		rg_state <= Idle;
	endrule

	rule rl_send_multi_cast(rg_state==Multi_cast && rg_sv!=0);
		let msg = rg_multi_cast;
		let lv_sv = rg_sv;
		let lv_shift_sv = countZerosLSB(rg_sv);
		if(lv_sv[0]==1) begin
			msg.dst = tagged Caches truncate(pack(lv_shift_sv));	
			msg.src = msg.src;	
			lv_sv[0]=1;
		end
		if(lv_sv==0) begin
			rg_state <= Idle;
		end
	  rg_sv <= rg_sv >> (lv_shift_sv+1);
		let packet = fn_gen_fwd_pkt(msg);
		`logLevel( llc, 0, $format("LLC[%2d]: Sending FWD:",id,fshow(msg)))
		slave.i_fwd_channel.enq(packet);
	endrule

	interface slave_side = slave.shaktilink_side;
	interface master_side = master.shaktilink_side;

	
												
endmodule

//(*synthesize*)
//module mkllc_coherence_bank(Ifc_llc_bank#(`paddr, TDiv#(`linesize, 8), TAdd#(`NrCaches,1), 
//																TAdd#(`NrCaches,1), 14, TLog#(`NrCaches), 0));
//	let  ifc();
//	mkllc_bank _temp(ifc);
//	return (ifc);
//endmodule

endpackage
