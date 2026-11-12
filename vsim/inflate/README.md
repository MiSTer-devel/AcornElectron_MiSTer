# inflate.sv test

`rtl/inflate.sv` is the gzip decompressor for gzipped `.uef` tapes. This
testbench feeds `.gz` files through it with random input latency and output
back-pressure and compares every byte with Python's zlib.

```bash
./run.sh                 # synthetic cases + every gzipped UEF in software/mister11/tapes/*.zip
```

Synthetic cases: empty, stored blocks (level 0, two blocks), fixed and
dynamic Huffman, long runs (distance 1/2), distances near 32 KB, and the gzip
FEXTRA/FNAME/FCOMMENT/FHCRC header fields.

2026-11-10: 1006/1006 pass (998 STH UEFs, up to 534 KB); 3.5-12.5 clocks per
output byte (mean 8.8), so the largest tape inflates in about 0.3 s at 16 MHz.
