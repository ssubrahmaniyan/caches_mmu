/*
see LICENSE.iitm

Author : Nitya Ranganathan
Email id : nitya.ranganathan@gmail.com
Details : I-Cache Replacement Array

--------------------------------------------------------------------------------------------------
*/
package icache_replacement;
import Vector ::*;
import DReg  ::*;
import nb_icache_types ::*;
`include "icache_parameters.bsv"
`include "Logger.bsv"


// Replacement bits (implemented as array of registers)
interface Ifc_icache_replacement;
  method Action ma_reset();
  method ActionValue#(Bit#(TLog#(`numways))) mav_replace_way(Bit#(`setbits) set, Vector#(`numways, Bit#(1)) way_valid);
  method Action ma_update(Bit#(`setbits) set, Bit#(TLog#(`numways)) way, Bool hit);
  // TODO: fill time: correction
endinterface

(*synthesize*)
module mkicache_replacement(Ifc_icache_replacement);
  // NOTE: Support 2, 4, 8 ways currently
  // TODO: add assertion: way = 1 (handled in nb_icache) or 2 or 4 or 8

  // lru
  `ifdef irepl_lru // Least Recently Used
    Vector#(`numsets, Vector#(`numways,Reg#(Bit#(TLog#(`numways))))) rg_replace <- replicateM(replicateM(mkReg(0)));
    Vector#(`numsets, Vector#(`numways,Wire#(Bit#(TLog#(`numways))))) wr_replace <- replicateM(replicateM(mkDWire(0)));

  // round robin
  `elsif irepl_rrobin // Round-Robin
    Vector#(`numsets, Reg#(Bit#(TLog#(`numways)))) rg_replace <- replicateM(mkReg(0));
    Vector#(`numsets, Wire#(Bit#(TLog#(`numways)))) wr_replace <- replicateM(mkDWire(0));

  // plru
  `else // Pseudo-LRU
    Vector#(`numsets, Reg#(Bit#(TSub#(`numways, 1)))) rg_replace <- replicateM(mkReg(truncate(16'haaaa)));
    Vector#(`numsets, Wire#(Bit#(TSub#(`numways, 1)))) wr_replace <- replicateM(mkDWire(0));
  `endif // plru

  Reg#(Bit#(1)) rg_prev_valid <- mkDReg(0);
  Reg#(Bit#(`setbits)) rg_prev_set_index <- mkReg(0);
  Reg#(Bit#(TLog#(`numways))) rg_prev_replace_way <- mkReg(0);

  Wire#(Bit#(1)) wr_update_valid <- mkDWire(0);
  Wire#(Bit#(`setbits)) wr_update_set <- mkDWire(0);
  Wire#(Bit#(TLog#(`numways))) wr_update_way <- mkDWire(0);
  Wire#(Bool) wr_update_hit <- mkDWire(False);


  // read registers
  rule rl_read_registers;
    // lru
    `ifdef irepl_lru
      for (Integer i=0; i<`numsets; i=i+1) begin
        for (Integer j=0; j<`numways; j=j+1) begin
          wr_replace[i][j] <= rg_replace[i][j];
        end
      end

    // round robin
    `elsif irepl_rrobin
      for (Integer i=0; i<`numsets; i=i+1) begin
        wr_replace[i] <= rg_replace[i];
      end

    // plru
    `else
      for (Integer i=0; i<`numsets; i=i+1) begin
        wr_replace[i] <= rg_replace[i];
      end
    `endif // plru

  endrule

  // update replacement bits
  rule rl_update;
    // TODO: 1. optimize lookup time replace way selection
    //       2. add fill time alternative

    if (wr_update_valid == 1) begin
      // cache or mhb hit
      if (wr_update_hit) begin
        // lru
        `ifdef irepl_lru
          for (Integer j=0; j<`numways; j=j+1) begin
            if (wr_update_way == fromInteger(j)) begin
              rg_replace[wr_update_set][j] <= '1;
            end
            else if (wr_replace[wr_update_set][j] != '0) begin
              rg_replace[wr_update_set][j] <= wr_replace[wr_update_set][j] - 1;
            end
          end // for
          `logLevel( icache, 2, $format("ICACHE: REPL: Update on hit: set %d way %d", wr_update_set, wr_update_way))

        // round robin
        `elsif irepl_rrobin
          // Note: current impl.: strict round robin with no update on hit
          //rg_replace[wr_update_set] <= wr_replace[wr_update_set] + 1;
          `logLevel( icache, 2, $format("ICACHE: REPL: No Update on hit: set %d way %d # current_repl_way %d", wr_update_set, wr_update_way, wr_replace[wr_update_set]))

        // plru
        `else
          Bit#(TSub#(`numways, 1)) lv_repl = wr_replace[wr_update_set];
          Bit#(7) lv_erepl = zeroExtend(lv_repl); // max. 8 ways
          Bit#(7) lv_erepl_new = '0; // max. 8 ways
          Bit#(3) lv_update_way = zeroExtend(wr_update_way);

          // points to the other way
          // 0
          if (valueOf(`numways) == 2) begin
            lv_erepl_new = zeroExtend(~lv_update_way);
            rg_replace[wr_update_set] <= truncate(lv_erepl_new);
          end
          // change pointers for every node on the path
          //    0
          //  1   2
          else if (valueOf(`numways) == 4) begin
            lv_erepl_new = zeroExtend((lv_update_way[1:0] == 2'b00) ? {lv_erepl[2], 1'b1, 1'b1}
                                        : ((lv_update_way[1:0] == 2'b01) ? {lv_erepl[2], 1'b0, 1'b1}
                                          : ((lv_update_way[1:0] == 2'b10) ? {1'b1, lv_erepl[1], 1'b0} : {1'b0, lv_erepl[1], 1'b0})));
            rg_replace[wr_update_set] <= truncate(lv_erepl_new);
          end
          // change pointers for every node on the path
          //       0
          //   1       2
          // 3   4   5   6
          else if (valueOf(`numways) == 8) begin
            lv_erepl_new = zeroExtend((lv_update_way[2:1] == 2'b00) ? {lv_erepl[6], lv_erepl[5], lv_erepl[4], ~lv_update_way[0], lv_erepl[2], 1'b1, 1'b1}
                                        : ((lv_update_way[2:1] == 2'b01) ? {lv_erepl[6], lv_erepl[5], ~lv_update_way[0], lv_erepl[3], lv_erepl[2], 1'b1, 1'b1}
                                          : ((lv_update_way[2:1] == 2'b10) ? {lv_erepl[6], ~lv_update_way[0], lv_erepl[4], lv_erepl[3], 1'b1, lv_erepl[1], 1'b0}
                                             : {~lv_update_way[0], lv_erepl[5], lv_erepl[4], lv_erepl[3], 1'b1, lv_erepl[1], 1'b0})));
            rg_replace[wr_update_set] <= truncate(lv_erepl_new);
          end
          else begin
            // TODO
          end
          `logLevel( icache, 2, $format("ICACHE: REPL: Update on hit: set %d way %d", wr_update_set, wr_update_way))
        `endif // plru
      end // hit

      // miss (TODO: when replace_way picked is invalid)
      else if (rg_prev_valid == 1) begin // check valid == 0
        // lru
        `ifdef irepl_lru
          for (Integer j=0; j<`numways; j=j+1) begin
            if (rg_prev_replace_way == fromInteger(j)) begin
              rg_replace[wr_update_set][j] <= '1;
            end
            else if (wr_replace[wr_update_set][j] != '0) begin
              rg_replace[wr_update_set][j] <= wr_replace[wr_update_set][j] - 1;
            end
          end // for
          `logLevel( icache, 2, $format("ICACHE: REPL: Update on miss: set %d way %d", wr_update_set, rg_prev_replace_way))

        // round robin
        `elsif irepl_rrobin
          rg_replace[wr_update_set] <= rg_prev_replace_way + 1;
          `logLevel( icache, 2, $format("ICACHE: REPL: Update on miss: set %d way %d", wr_update_set, rg_prev_replace_way))

        // plru
        `else
          Bit#(TSub#(`numways, 1)) lv_repl = wr_replace[wr_update_set];
          Bit#(7) lv_erepl = zeroExtend(lv_repl); // max. 8 ways
          Bit#(7) lv_erepl_new = '0; // max. 8 ways
          Bit#(3) lv_update_way = zeroExtend(rg_prev_replace_way);

          // points to the other way
          // 0
          if (valueOf(`numways) == 2) begin
            lv_erepl_new = zeroExtend(~lv_update_way);
            rg_replace[wr_update_set] <= truncate(lv_erepl_new);
          end
          // change pointers for every node on the path
          //    0
          //  1   2
          else if (valueOf(`numways) == 4) begin
            lv_erepl_new = zeroExtend((lv_update_way[1:0] == 2'b00) ? {lv_erepl[2], 1'b1, 1'b1}
                                        : ((lv_update_way[1:0] == 2'b01) ? {lv_erepl[2], 1'b0, 1'b1}
                                          : ((lv_update_way[1:0] == 2'b10) ? {1'b1, lv_erepl[1], 1'b0} : {1'b0, lv_erepl[1], 1'b0})));
            rg_replace[wr_update_set] <= truncate(lv_erepl_new);
          end
          // change pointers for every node on the path
          //       0
          //   1       2
          // 3   4   5   6
          else if (valueOf(`numways) == 8) begin
            lv_erepl_new = zeroExtend((lv_update_way[2:1] == 2'b00) ? {lv_erepl[6], lv_erepl[5], lv_erepl[4], ~lv_update_way[0], lv_erepl[2], 1'b1, 1'b1}
                                        : ((lv_update_way[2:1] == 2'b01) ? {lv_erepl[6], lv_erepl[5], ~lv_update_way[0], lv_erepl[3], lv_erepl[2], 1'b1, 1'b1}
                                          : ((lv_update_way[2:1] == 2'b10) ? {lv_erepl[6], ~lv_update_way[0], lv_erepl[4], lv_erepl[3], 1'b1, lv_erepl[1], 1'b0}
                                             : {~lv_update_way[0], lv_erepl[5], lv_erepl[4], lv_erepl[3], 1'b1, lv_erepl[1], 1'b0})));
            rg_replace[wr_update_set] <= truncate(lv_erepl_new);
          end
          else begin
            // TODO
          end
          `logLevel( icache, 2, $format("ICACHE: REPL: Update on miss: set %d way %d", wr_update_set, rg_prev_replace_way))
        `endif // plru
      end // miss
    end // update
  endrule // rl_update

  // reset replacement bits
  method Action ma_reset();
    // lru
    `ifdef irepl_lru
      for (Integer i=0; i<`numsets; i=i+1) begin
        for (Integer j=0; j<`numways; j=j+1) begin
          rg_replace[i][j] <= '0;
        end
      end

    // round robin
    `elsif irepl_rrobin
      for (Integer i=0; i<`numsets; i=i+1) begin
        rg_replace[i] <= '0;
      end

    // plru
    `else
      for (Integer i=0; i<`numsets; i=i+1) begin
        rg_replace[i] <= truncate(16'haaaa);
      end
    `endif // plru

    `logLevel( icache, 2, $format("ICACHE: REPL: Reset all."))
  endmethod // reset

  // select way to replace and return way number (invoked in stage1)
  method ActionValue#(Bit#(TLog#(`numways))) mav_replace_way(Bit#(`setbits) set, Vector#(`numways, Bit#(1)) way_valid);
    Bit#(1) lv_picked = 0;
    Bit#(TLog#(`numways)) lv_way = 0;

    // TODO: rare: 1. fix back-to-back same set lookup (check prev set)
    //             2. for lookup-time selection, mark selected way if invalid way selected (will affect next selection to same set until fill marks valid)

    for (Integer i=0; i<`numways; i=i+1) begin
      if (way_valid[i] == 0) begin
        lv_way = fromInteger(i);
        lv_picked = 1;
      end
    end

    // all ways are valid
    if (lv_picked == 0) begin
      // lru
      `ifdef irepl_lru
        for (Integer j=1; j<`numways; j=j+1) begin
          if (wr_replace[set][j] < wr_replace[set][j-1]) begin
            lv_way = fromInteger(j);
          end
        end

      // round robin
      `elsif irepl_rrobin
        lv_way = wr_replace[set];

      // plru
      `else
        Bit#(3) lv_eway = 0; // max. 8 ways
        Bit#(TSub#(`numways, 1)) lv_repl = wr_replace[set];

        if (valueOf(`numways) == 2) begin
          lv_eway = zeroExtend(lv_repl[0]);
        end
        else if (valueOf(`numways) == 4) begin
          lv_eway = zeroExtend( (lv_repl[1:0] == 2'b00) ? 2'b00
                    : ((lv_repl[1:0] == 2'b10) ? 2'b01
                      : (({lv_repl[2],lv_repl[0]} == 2'b01) ? 2'b10 : 2'b11)));
        end
        else if (valueOf(`numways) == 8) begin
          lv_eway = zeroExtend( ({lv_repl[3],lv_repl[1],lv_repl[0]} == 3'b000) ? 3'b000
                    : (({lv_repl[3],lv_repl[1],lv_repl[0]} == 3'b100) ? 3'b001
                      : (({lv_repl[4],lv_repl[1],lv_repl[0]} == 3'b010) ? 3'b010
                        : (({lv_repl[4],lv_repl[1],lv_repl[0]} == 3'b110) ? 3'b011
                          : (({lv_repl[5],lv_repl[2],lv_repl[0]} == 3'b001) ? 3'b100
                            : (({lv_repl[5],lv_repl[2],lv_repl[0]} == 3'b101) ? 3'b101
                              : (({lv_repl[6],lv_repl[2],lv_repl[0]} == 3'b011) ? 3'b110 : 3'b111)))))) );
        end
        else begin
          lv_eway = '0;
        end
        lv_way = truncate (lv_eway);
      `endif // plru
      `logLevel( icache, 2, $format("ICACHE: REPL: Replace way (all valid) for set %d: %d", set, lv_way))
    end // pick replacement way

    else begin
      `logLevel( icache, 2, $format("ICACHE: REPL: Replace way (invalid) for set %d: %d", set, lv_way))
    end

    // save for next cycle
    rg_prev_valid <= 1;
    rg_prev_set_index <= set;
    rg_prev_replace_way <= lv_way;

    return lv_way;
  endmethod // replace_way

  // update replacement bits based on hit or miss (invoked in stage2)
  method Action ma_update(Bit#(`setbits) set, Bit#(TLog#(`numways)) way, Bool hit);
    wr_update_valid <= 1;
    wr_update_set <= set;
    wr_update_way <= way;
    wr_update_hit <= hit;
  endmethod // update

endmodule // mkicache_replacement

endpackage

