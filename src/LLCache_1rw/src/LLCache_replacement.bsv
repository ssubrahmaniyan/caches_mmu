package LLCache_replacement;

// library imports
  import Vector         :: *;

  interface Ifc_replace
    #(numeric type nsets,
      numeric type nways);

      /* 
        doc: method: mav_line_replace
        description: This method is used to get the replacement way for a given index.
      */
      method ActionValue#(
        Bit#(TLog#(nways))
      ) mav_line_replace(
        Bit#(TLog#(nsets))  index,
        Bit#(ways)          valid
      );

      /*
        doc: method: ma_update_set
        description: This method is used to update a way's replacement state for a given index
        when it is accessed.
      */
      method Action
        ma_update_set(
          Bit#(TLog#(nsets))  index,
          Bit#(ways)          way
        );

      /*
        doc: method: ma_reset_replacement
        description: This method is used to reset the replacement policy.
      */
      method Action
        ma_reset_replacement;


    endinterface: Ifc_replace

    /*
      doc: module: mkLLCache_replacement
      description: This module implements the replacement policy for the cache. 
      It implements pLRU policy.
    */
    module mkLLCache_replacement
      (Ifc_replace#(
        nsets,
        nways))
      provisos (
        Log#(nsets, setbits),
        Log#(nways, waysbits),
        Add#(a__, 1, TLog#(nways))
      );

      // For a tree with nways leaves, 
      // there are nways - 1 internal nodes, and each node has a bit to 
      // indicate which subtree is more recently used.
      Vector#(nsets, Reg#(Bit#(TSub#(nways,1)))) v_count  <- replicateM(mkReg(0));

      method ActionValue#(
        Bit#(TLog#(nways))
      ) mav_line_replace(
        Bit#(TLog#(nsets))  index,
        Bit#(ways)          valid  //valid bit vector
      );

        let tree = v_count[index];

        function Tuple2#(Bit#(TLog#(nways)), Bit#(1)) 
          traverse(Bit#(TLog#(nways)) node, Integer _i);
          // the next node in the tree is determined by the current node 
          // and the value of the current node.
          // If the current node is 0, we go to the left child,
          // otherwise we go to the right child.
          // next index is node * 2 + 1 + tree[node]
         return tuple2((node << 1) + 1 + zeroExtend(tree[node]), tree[node]);
        endfunction

        // MapAccumL traverses the tree and updates the bits along the way. 
        // It returns the index of the way to be replaced and the updated tree.
        // Threads a state (accumulator) from left-to-right while simultaneously 
        // mapping each element.
        match {.*, .victim_bits} = mapAccumL(
         traverse,
         0, genVector()
        );

        return pack(victim_bits);

      endmethod: mav_line_replace

      method Action 
        ma_update_set(
          Bit#(setbits)  index,
          Bit#(waybits)  accessed_way
        );

        let tree = v_count[index];

        function Tuple2#(Bit#(TLog#(nways)), Bit#(TSub#(nways,1))) 
          update_step (
            Tuple2#(Bit#(TLog#(nways)), Bit#(TSub#(nways,1))) acc, 
            Integer i);

            match {.node, .t} = acc;
            Bit#(1) dir       = accessed_way[i];
            t[node] = ~dir;
            let next_node = (node << 1) + 1 + zeroExtend(dir);

            return tuple2(next_node, t);
        endfunction: update_step

        match {.*, .final_tree} = foldl(
          update_step,
          tuple2(0, tree),
          Vector#(TLog#(nways), Integer)'(genVector())
        );
        v_count[index] <= final_tree;
      endmethod: ma_update_set

      method Action
        ma_reset_replacement;
        writeVReg(v_count, replicate(0));
      endmethod: ma_reset_replacement
    endmodule: mkLLCache_replacement


endpackage: LLCache_replacement
