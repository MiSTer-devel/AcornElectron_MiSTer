# Acorn Electron Verilator simulation.
#
#   make            build obj_dir/Vemu (GUI + headless)
#   make TRACE=1    with VCD tracing
#   ./obj_dir/Vemu --help
#
# The VHDL core is converted to Verilog with GHDL (--synth) first, so VHDL edits
# flow through on the next make. vsim/rtl/RAM_32k_DualPort_sim.vhd replaces the
# altsyncram RAM. Run the sim from this directory ($readmemh opens ELK.hex here).

.DEFAULT_GOAL := all

V    = verilator
GHDL = ghdl
RTL  = ../rtl
GEN  = obj_dir/gen

# --- GHDL: VHDL -> Verilog -------------------------------------------------
# Analysis order matters (packages first, then users).
VHDL_SRC = \
	$(RTL)/T6502/T65_Pack.vhd \
	$(RTL)/T6502/T65_MCode.vhd \
	$(RTL)/T6502/T65_ALU.vhd \
	$(RTL)/T6502/T65.vhd \
	$(RTL)/via6522.vhd \
	$(RTL)/ps2kybrd/keyboard.vhd \
	rtl/RAM_32k_DualPort_sim.vhd \
	$(RTL)/ElectronULA.vhd \
	$(RTL)/ElectronFpga_core.vhd

GHDL_FLAGS = --std=08 -fsynopsys --workdir=$(GEN)
CORE_V = $(GEN)/electron_core.v

$(CORE_V): $(VHDL_SRC) Makefile
	@mkdir -p $(GEN)
	rm -f $(GEN)/*.cf
	$(GHDL) -a $(GHDL_FLAGS) -Wno-hide $(VHDL_SRC)
	$(GHDL) --synth $(GHDL_FLAGS) --out=verilog ElectronFpga_core > $@.tmp
	mv $@.tmp $@

# --- Verilator -------------------------------------------------------------
TOP = --top-module emu

# GHDL emits plain Verilog that uses SystemVerilog keywords (do, break) as
# names: read .v as Verilog-2005, .sv as SystemVerilog.
V_DEFINE = +define+SIMULATION=1 +1364-2005ext+v +1800-2017ext+sv \
	--timescale-override 1ps/1ps \
	-Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-CASEINCOMPLETE \
	-Wno-UNOPTFLAT -Wno-MULTIDRIVEN

ifeq ($(TRACE),1)
V_DEFINE += --trace
CXX_DEFINE += -DVM_TRACE_VCD=1
else
CXX_DEFINE += -DVM_TRACE_VCD=0
endif

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S), Darwin)
	LIBS += -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo `sdl2-config --libs`
	LIBS += -L/opt/homebrew/lib -L/usr/local/lib
	CXXFLAGS += `sdl2-config --cflags` `sdl2-config --cflags | sed 's|include/SDL2|include/|'`
	CXXFLAGS += -I/opt/homebrew/include -I/usr/local/include
endif
ifeq ($(UNAME_S), Linux)
	LIBS += -lGL -ldl `sdl2-config --libs`
	CXXFLAGS += `sdl2-config --cflags`
endif

CXXFLAGS += -O2 $(CXX_DEFINE) -I../sim/imgui -I../sim -g
V_OPT     = -O3 --x-assign fast --x-initial fast --noassert
EXE       = ./obj_dir/Vemu

V_SRC = \
	sim.vlt \
	sim.v \
	$(CORE_V) \
	$(RTL)/cassette.v \
	$(RTL)/square_gen.v

C_SRC = \
	sim_main.cpp \
	sim/sim_bus.cpp sim/sim_clock.cpp sim/sim_console.cpp sim/sim_video.cpp \
	sim/sim_input.cpp sim/sim_audio.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp \
	sim/imgui/imgui_draw.cpp sim/imgui/imgui_widgets.cpp sim/imgui/imgui_tables.cpp \
	sim/imgui/imgui.cpp sim/imgui/ImGuiFileDialog.cpp \
	sim/imgui/implot.cpp sim/imgui/implot_items.cpp

VOUT = obj_dir/Vemu.cpp

all: ELK.hex $(EXE)

ELK.hex: ../roms/ELK.mif mif2hex.py
	python3 -I mif2hex.py $< $@

$(VOUT): $(V_SRC) Makefile
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS) $(LIBS)" -exe --Mdir ./obj_dir \
		$(V_DEFINE) $(TOP) -CFLAGS "$(CXXFLAGS)" $(V_SRC) $(C_SRC)

$(EXE): $(VOUT) $(C_SRC)
	(cd obj_dir; $(MAKE) -f Vemu.mk OBJCACHE= OPT_FAST="-O2" OPT_SLOW="-O0" OPT_GLOBAL="-O2")

clean:
	rm -rf obj_dir ELK.hex

.PHONY: all clean
