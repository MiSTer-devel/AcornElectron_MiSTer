# Standalone test for rtl/inflate.sv (gzip decompressor).
#   make && ./run.sh
all: obj_dir/Vinflate
obj_dir/Vinflate: ../../rtl/inflate.sv tb_inflate.cpp
	verilator -cc -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH --top-module inflate \
		../../rtl/inflate.sv --exe tb_inflate.cpp -CFLAGS -O2 --build -j 8 > obj_dir.log 2>&1 || (cat obj_dir.log; false)
clean:
	rm -rf obj_dir obj_dir.log vectors
.PHONY: all clean
