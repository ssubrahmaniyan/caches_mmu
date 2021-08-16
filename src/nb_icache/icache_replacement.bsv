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
    Vector#(`numsets, Reg#(Bit#(TSub#(`numways, 1)))) rg_replace <- replicateM(mkReg(0)); // TODO
    Vector#(`numsets, Wire#(Bit#(TSub#(`numways, 1)))) wr_replace <- replicateM(mkDWire(0)); // TODO
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
    `elsif
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

        // round robin
        `elsif irepl_rrobin
          rg_replace[wr_update_set] <= wr_replace[wr_update_set] + 1;

        // plru
        `else
          // TODO
        `endif // plru

        `logLevel( icache, 2, $format("ICACHE: REPL: Update on hit: set %d way %d", wr_update_set, wr_update_way))
      end // hit

      // miss
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

        // round robin
        `elsif irepl_rrobin
          rg_replace[wr_update_set] <= rg_prev_replace_way + 1;

        // plru
        `else
          // TODO
        `endif // plru

        `logLevel( icache, 2, $format("ICACHE: REPL: Update on miss: set %d way %d", wr_update_set, rg_prev_replace_way))
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
        rg_replace[i] <= truncate(7'b1010101);
      end
    `endif // plru

    `logLevel( icache, 2, $format("ICACHE: REPL: Reset all."))
  endmethod // reset

  // select way to replace and return way number (invoked in stage1)
  method ActionValue#(Bit#(TLog#(`numways))) mav_replace_way(Bit#(`setbits) set, Vector#(`numways, Bit#(1)) way_valid);
    Bit#(1) lv_picked = 0;
    Bit#(TLog#(`numways)) lv_way = 0;

    // TODO: 1. fix back-to-back same set lookup (check prev set)

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
        // TODO
        lv_way = 0;
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

