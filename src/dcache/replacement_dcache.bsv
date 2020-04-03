/* 
see LICENSE.incore
see LICENSE.iitm

Author: Neel Gala
Email id: neelgala@gmail.com
Details:

--------------------------------------------------------------------------------------------------
*/
package replacement_dcache;
  import Vector::*;
  import LFSR::*;
  import Assert::*;

  interface Ifc_replace#(numeric type sets, numeric type ways);
    method ActionValue#(Bit#(TLog#(ways))) line_replace (Bit#(TLog#(sets))
        index, Bit#(ways) valid, Bit#(ways) dirty);
    method Action update_set (Bit#(TLog#(sets)) index, Bit#(TLog#(ways)) way);
    method Action reset_repl;
  endinterface

  module mkreplace#(parameter Bit#(2) alg)(Ifc_replace#(sets,ways))
    provisos(Add#(a__, TLog#(ways), 4));

    let v_ways = valueOf(ways);
    let v_sets = valueOf(sets);
    staticAssert(alg==0 || alg==1 || alg==2,"Invalid replacement Algorithm");
    if(alg == 0)begin // RANDOM
      LFSR#(Bit#(4)) random <- mkLFSR_4();
      Reg#(Bool) rg_init <- mkReg(True);
      rule initialize_lfsr(rg_init);
        random.seed(1);
        rg_init<=False;
      endrule

    method ActionValue#(Bit#(TLog#(ways))) line_replace (Bit#(TLog#(sets))
            index, Bit#(ways) valid, Bit#(ways) dirty);
        if (&(valid)==1 && &(dirty)==1)begin // if all lines are valid and dirty choose one to randomly replace
          return truncate(random.value());
        end
        else if(&(valid)!=1) begin // if any line is not valid
          Bit#(TLog#(ways)) temp=0;
          for(Bit#(TAdd#(1,TLog#(ways))) i=0;i<fromInteger(v_ways);i=i+1) begin
            if(valid[i]==0)begin
              temp=truncate(i);
            end
          end
          return temp;
        end
        else begin // if any non-dirty line
          Bit#(TLog#(ways)) temp=0;
          for(Bit#(TAdd#(1,TLog#(ways))) i=0;i<fromInteger(v_ways);i=i+1) begin
            if(dirty[i]==0)begin
              temp=truncate(i);
            end
          end
          return temp;
        end
      endmethod
      method Action update_set (Bit#(TLog#(sets)) index, Bit#(TLog#(ways)) way)if(!rg_init);
        random.next();
      endmethod
      method Action reset_repl;
        random.seed(1);
      endmethod
    end
    else if(alg== 1)begin // RRBIN
      Vector#(sets,Reg#(Bit#(TLog#(ways)))) v_count <- replicateM(mkReg(fromInteger(v_ways-1)));
    method ActionValue#(Bit#(TLog#(ways))) line_replace (Bit#(TLog#(sets))
            index, Bit#(ways) valid, Bit#(ways) dirty);

        Bool alldirty =  (&valid == 1 && &dirty == 1);
        Bool somedirty = (&valid == 1 && &dirty != 1);
        Bool nonedirty = (&valid == 1 && |dirty == 0);

        Bit#(TLog#(ways)) temp=fromInteger(v_ways-1);
        if(alldirty || nonedirty) begin // all lines are valid and dirty
          return readVReg(v_count)[index];
        end
        else if (somedirty) begin // all lines valid but not all dirty
          for(Bit#(TAdd#(1,TLog#(ways))) i=0;i<fromInteger(v_ways);i=i+1)
            if(dirty[i]==0)
              temp = truncate(i);
          return temp;
        end
        else begin // some lines are invalid
          for(Bit#(TAdd#(1,TLog#(ways))) i=0;i<fromInteger(v_ways);i=i+1)
            if(valid[i]==0)
              temp =  truncate(i);
          return temp;
        end
      endmethod
      method Action update_set (Bit#(TLog#(sets)) index, Bit#(TLog#(ways)) way);
        v_count[index]<=v_count[index]-1;
      endmethod
      method Action reset_repl;
        for(Integer i=0;i<v_sets;i=i+1)
          v_count[i]<=fromInteger(v_ways-1);
      endmethod
    end
    else if(alg== 2)begin // PLRU
      Vector#(sets,Reg#(Bit#(TSub#(ways,1)))) v_count <- replicateM(mkReg(5));
    method ActionValue#(Bit#(TLog#(ways))) line_replace (Bit#(TLog#(sets))
            index, Bit#(ways) valid, Bit#(ways) dirty);
        if (&(valid)==1)begin // if all lines are valid choose one to randomly replace
          case (v_count[index]) matches
            'b?00:    begin return 0; end 
            'b?10:    begin return 1; end
            'b0?1:    begin return 2; end
            default:  begin return 3; end
          endcase
        end
        else begin // if any line empty then send that
          Bit#(TLog#(ways)) temp=0;
          for(Bit#(TAdd#(1,TLog#(ways))) i=0;i<fromInteger(v_ways);i=i+1) begin
            if(valid[i]==0)begin
              temp=truncate(i);
            end
          end
          return temp;
        end
      endmethod
      method Action update_set (Bit#(TLog#(sets)) index, Bit#(TLog#(ways)) way);
        Bit#(TSub#(ways,1)) mask='b000;
        Bit#(TSub#(ways,1)) val='b000;
        case (way) matches
          'd0:begin val='b011; mask='b011;end
          'd1:begin val='b001; mask='b011;end
          'd2:begin val='b100; mask='b101;end
          'd3:begin val='b000; mask='b101;end  
        endcase
        v_count[index]<=(v_count[index]&~mask)|(val&mask);
      endmethod
      method Action reset_repl;
        for(Integer i=0;i<v_sets;i=i+1)
          v_count[i]<=5;
      endmethod
    end
    else begin
    method ActionValue#(Bit#(TLog#(ways))) line_replace (Bit#(TLog#(sets))
            index, Bit#(ways) valid, Bit#(ways) dirty);
        return ?;
      endmethod
      method Action update_set (Bit#(TLog#(sets)) index, Bit#(TLog#(ways)) way);
        noAction;
      endmethod
      method Action reset_repl;
        noAction;
      endmethod
    end
  endmodule
endpackage

