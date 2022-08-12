package MergeSortAccel;

import Cur_Cycle     :: *;
import GetPut_Aux    :: *;
import Semi_FIFOF    :: *;
import BRAMCore      :: *;
import FIFOF         :: *;
import GetPut        :: *;
import ClientServer  :: *;
import Connectable   :: *;

// ================================================================
// Project imports

import AXI4_Types    :: *;
import Fabric_Defs   :: *;
import AXI4_Accel_IFC:: *;
import AXI4_Accel    :: *;
import SoC_Map       :: *;
import ATCM_Decls    :: *;

// ================================================================
// BRAM config constants

Bool config_output_register_BRAM = False;    // i.e., no output register
Bool load_file_is_binary_BRAM = False;       // file to be loaded is in hex format

// ================================================================
// Interface Definitions

interface Accel_IFC;
   method Action init (Bit# (Wd_Id) axi4_id, Bit #(Wd_Addr) addr_base, Bit #(Wd_Addr) addr_lim);
   interface AXI4_Slave_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) ctrl_server;
   interface AXI4_Slave_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) mem_server;
   (* always_ready *) method Bool interrupt_req;
endinterface

interface AXI4_Mem_IFC;
   interface AXI4_Slave_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) sys_server;
   interface AXI4_Slave_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) core_server;
endinterface

// ================================================================
// Wraps the accelerator core with a local memory to integrate into the system
// as a target-only device. The two targets are not strictly necessary but
// there to minimise changes to the accelerator core. Requests on the ctrl
// interface are sent directly to the core, while requests on the mem
// interface are serviced by the mem module.
(* synthesize *)
module mkMergeSortAccel (Accel_IFC);
   let soc_map <- mkSoC_Map;
   AXI4_Accel_IFC core <- mkAXI4_Accel;
   AXI4_Mem_IFC mem <- mkAXI4_DP_Mem;
   Reg #(Bool) rg_done_once <- mkReg (False);

   mkConnection (core.master, mem.core_server);

   // Interface
   method Bool interrupt_req = core.interrupt_req;
   method Action init (Bit #(Wd_Id) i, Bit #(Wd_Addr) a, Bit #(Wd_Addr) l);
      core.init (i, a, l);
   endmethod
   interface AXI4_Slave_IFC ctrl_server = core.slave;
   interface AXI4_Slave_IFC mem_server = mem.sys_server;
endmodule


// ================================================================
// The accelerator's local memory. Mostly services requests from the
// accelerator core. But also provides an interface to the system.
// Only supports bus-width accesses. No strobing.
//
(* synthesize *)
module mkAXI4_DP_Mem (AXI4_Mem_IFC);
   AXI4_Slave_Xactor_IFC #(
      Wd_Id, Wd_Addr, Wd_Data, Wd_User) coreXActor <- mkAXI4_Slave_Xactor;
   AXI4_Slave_Xactor_IFC #(
      Wd_Id, Wd_Addr, Wd_Data, Wd_User) sysXActor <- mkAXI4_Slave_Xactor;

   BRAM_DUAL_PORT #(ATCM_INDEX, ATCM_Word) ram <-
      mkBRAMCore2 (n_words_BRAM, config_output_register_BRAM);

   FIFOF #(Tuple2 #(Bit#(Wd_Id), Bit #(Wd_User))) core_rsp_pnd_f <- mkSizedFIFOF (4);
   FIFOF #(Tuple2 #(Bit#(Wd_Id), Bit #(Wd_User))) sys_rsp_pnd_f  <- mkSizedFIFOF (4);

   // 0: quiet. 1: rule firings. 2: details
   Integer verbosity = 2;

   let rd_ram = ram.a;
   let wr_ram = ram.b;

   function Rules fn_gen_axi4_rules (
        AXI4_Slave_Xactor_IFC #(Wd_Id, Wd_Addr, Wd_Data, Wd_User) xactor
      , BRAM_PORT# (ATCM_INDEX, ATCM_Word) rdram
      , BRAM_PORT# (ATCM_INDEX, ATCM_Word) wrram
      , FIFOF#(Tuple2 #(Bit#(Wd_Id), Bit #(Wd_User))) rsp_pnd_f);
      return ( rules
         rule rl_rd_req;
            let rda = xactor.o_rd_addr.first; xactor.o_rd_addr.deq;
            ATCM_INDEX rd_ram_word_addr = truncate (
               rda.araddr >> bits_per_byte_in_atcm_word);
            rdram.put (False, rd_ram_word_addr, ?);
            rsp_pnd_f.enq (tuple2 (rda.arid, rda.aruser));
            if (verbosity > 0) begin
               $display ("%0d: %m.rl_rd_req: ", cur_cycle);
               if (verbosity > 1) begin
                  $display ("    rda: ", fshow (rda));
                  $display ("    ram addr: %0h", rd_ram_word_addr);
               end
            end
         endrule

         rule rl_rd_rsp;
            match {.id, .user} = rsp_pnd_f.first; rsp_pnd_f.deq;
            Bit#(Wd_Data) word = pack (rdram.read);
            let rdr = AXI4_Rd_Data {
                 rid  : id
               , rresp: axi4_resp_okay
               , rdata: word
               , rlast: True
               , ruser: user
            };
            xactor.i_rd_data.enq (rdr);
            if (verbosity > 0) begin
               $display ("%0d: %m.rl_rd_rsp: ", cur_cycle);
               if (verbosity > 1) begin
                  $display ("    rdr: ", fshow (rdr));
               end
            end
         endrule

         rule rl_wr_req;
            let wra = xactor.o_wr_addr.first; xactor.o_wr_addr.deq;
            let wrd = xactor.o_wr_data.first; xactor.o_wr_data.deq;
            ATCM_INDEX wr_ram_word_addr = truncate (
               wra.awaddr >> bits_per_byte_in_atcm_word);
            wrram.put (True, wr_ram_word_addr, wrd.wdata);

            // Send response
            let wrr = AXI4_Wr_Resp {
                 bid:   wra.awid
               , bresp: axi4_resp_okay
               , buser: wra.awuser};
            xactor.i_wr_resp.enq (wrr);

            if (verbosity > 0) begin
               $display ("%0d: %m.rl_wr_req: ", cur_cycle);
               if (verbosity > 1) begin
                  $display ("    wra: ", fshow (wra));
                  $display ("    wrd: ", fshow (wrd));
                  $display ("    ram addr: %0h", wr_ram_word_addr);
                  $display ("    wdata: %0h", wrd.wdata);
               end
            end

         endrule
      endrules );
   endfunction

   Rules rls_axi4 = emptyRules;
   rls_axi4 = rJoin (rls_axi4, fn_gen_axi4_rules (coreXActor, rd_ram, wr_ram, core_rsp_pnd_f));
   rls_axi4 = rJoin (rls_axi4, fn_gen_axi4_rules (sysXActor, rd_ram, wr_ram, sys_rsp_pnd_f));
   addRules (rls_axi4);

   // Interface 
   interface core_server = coreXActor.axi_side;
   interface sys_server = sysXActor.axi_side;
endmodule

endpackage
