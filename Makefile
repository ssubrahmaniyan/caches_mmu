### Makefile for the devices

include Makefile.inc

BSVBUILDDIR:=./build/
VERILOGDIR:=./verilog/
BSVINCDIR:= .:%/Prelude:%/Libraries:%/Libraries/BlueNoC:$(SUPPORTED):$(DIR)
BSVOUTDIR:=./bin
define_macros:=-D VERBOSITY=2 -D ASSERT=True -D atomic=True -D pmp=True -D PMPSIZE=16 -D IWORDS=4 -D IBLOCKS=8

ifeq (, $(wildcard ${TOOLS_DIR}/shakti-tools/insert_license.sh))
  VERILOG_FILTER:= -verilog-filter ${BLUESPECDIR}/bin/basicinout
else
  VERILOG_FILTER:= -verilog-filter ${BLUESPECDIR}/bin/basicinout -verilog-filter ${TOOLS_DIR}/shakti-tools/insert_license.sh
  VERILOGLICENSE:= cp ${TOOLS_DIR}/shakti-tools/IITM_LICENSE.txt ./verilog
endif

VERILATOR_FLAGS = --stats -O3 -CFLAGS -O3 -LDFLAGS "-static" --x-assign fast --x-initial fast \
--noassert --cc $(TOP_MODULE).v sim_main.cpp --bbox-sys -Wno-STMTDLY -Wno-UNOPTFLAT -Wno-WIDTH \
-Wno-lint -Wno-COMBDLY -Wno-INITIALDLY --autoflush $(coverage) $(trace) --threads $(THREADS) \
-DBSV_RESET_FIFO_HEAD -DBSV_RESET_FIFO_ARRAY

define presim_config
	@cd tb/;python3 gen_test_dcache.py
	@ln -fs tb/*.mem .
endef
default: generate_verilog

.PHONY: compile
compile:
	@echo Compiling $(TOP_MODULE)....
	@mkdir -p $(BSVBUILDDIR)
	@bsc -u -sim -simdir $(BSVBUILDDIR) -bdir $(BSVBUILDDIR) -info-dir $(BSVBUILDDIR) -keep-fires\
  -check-assert $(define_macros) -p $(BSVINCDIR) -g $(TOP_MODULE)  $(TOP_DIR)/$(TOP_FILE)
	@echo Compilation finished

.PHONY: link
link:
	@echo Linking $(TOP_MODULE)...
	@mkdir -p bin
	@bsc -e $(TOP_MODULE) -sim -o ./bin/out -simdir $(BSVBUILDDIR) -p .:%/Prelude:%/Libraries:%/Libraries/BlueNoC -keep-fires -bdir $(BSVBUILDDIR) -keep-fires  
	@echo Linking finished

.PHONY: generate_verilog 
generate_verilog:
	@echo Compiling $(TOP_MODULE) in verilog ...
	@mkdir -p $(BSVBUILDDIR); 
	@mkdir -p $(VERILOGDIR); 
	bsc -u -verilog -show-schedule -sched-dot +RTS -K40000M -RTS -elab -vdir $(VERILOGDIR) -bdir $(BSVBUILDDIR) -info-dir $(BSVBUILDDIR)\
  $(define_macros) -D verilog=True $(BSVCOMPILEOPTS) $(VERILOG_FILTER) \
  -p $(BSVINCDIR) -g $(TOP_MODULE) $(TOP_DIR)/$(TOP_FILE)  || (echo "BSC COMPILE ERROR"; exit 1) 
	@cp ${BLUESPECDIR}/Verilog.Vivado/RegFile.v ./verilog/  
	@cp ${BLUESPECDIR}/Verilog.Vivado/BRAM2BELoad.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog.Vivado/BRAM2BE.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog.Vivado/BRAM2.v ./verilog/
	@cp src/common_verilog/bram_1r1w.v ./verilog/
	@cp src/common_verilog/bram_1rw.v ./verilog/
	@cp src/common_verilog/BRAM1Load.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFO2.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFO1.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFO10.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/RevertReg.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFO20.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/FIFOL1.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/SyncFIFO.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/Counter.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/SizedFIFO.v ./verilog/
	@cp ${BLUESPECDIR}/Verilog/RegFileLoad.v ./verilog/
	@$(VERILOGLICENSE)

.PHONY: link_verilator
link_verilator: 
	@echo "Linking $(TOP_MODULE) using verilator"
	@mkdir -p bin obj_dir
	@echo "#define TOPMODULE V$(TOP_MODULE)" > tb/sim_main.h
	@echo '#include "V$(TOP_MODULE).h"' >> tb/sim_main.h
	@verilator $(VERILATOR_FLAGS) -y $(VERILOGDIR) --exe
	@ln -f -s ../tb/sim_main.cpp obj_dir/sim_main.cpp
	@ln -f -s ../tb/sim_main.h obj_dir/sim_main.h
	@make -j8 -C obj_dir -f V$(TOP_MODULE).mk
	@cp obj_dir/V$(TOP_MODULE) bin/out

.PHONY: simulate
simulate:
	@echo Simulation...
	$(call presim_config)
	@exec ./$(BSVOUTDIR)/out > log
	@echo Simulation finished

.PHONY: clean
clean:
	rm -rf build bin *.jou *.log

.PHONY: full_clean
full_clean: clean
	rm -rf verilog fpga
