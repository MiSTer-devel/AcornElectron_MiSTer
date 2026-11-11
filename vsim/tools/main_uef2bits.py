#!/usr/bin/env python3
"""Convert a UEF the way Main_MiSTer does for the AcornElectron core
(support/uef/uef_reader.cpp, UEF_FileSend), so the sim can be fed exactly
what the core receives on MiSTer:  main_uef2bits.py in.uef out.bin

One tape bit per bit, first bit in the MSB. Chunks: &0100 data (start 0,
8 data bits LSB first, stop 1); &0110 carrier and &0112 gap: the 2-byte value
times 1201.9/1000 bits of 1s / 0s; &0111: pre-carrier, the byte 'A',
post-carrier. Everything else is ignored, as in Main."""
import gzip, struct, sys

BAUD = 1000000.0 / (16.0 * 52.0)
d = open(sys.argv[1], 'rb').read()
if d[:2] == b'\x1f\x8b':
    d = gzip.decompress(d)
assert d[:10] == b'UEF File!\0', 'not a UEF'
bits = []
def byte_bits(v):
    return [0] + [(v >> i) & 1 for i in range(8)] + [1]
p = 12
while p + 6 <= len(d):
    cid, ln = struct.unpack('<HI', d[p:p + 6]); body = d[p + 6:p + 6 + ln]; p += 6 + ln
    if cid == 0x0100:
        for b in body: bits += byte_bits(b)
    elif cid in (0x0110, 0x0112):
        n = int(struct.unpack('<H', body[:2])[0] * (BAUD / 1000.0))
        bits += [1 if cid == 0x0110 else 0] * n
    elif cid == 0x0111:
        pre, post = struct.unpack('<HH', body[:4])
        bits += [1] * int(pre * (BAUD / 1000.0)) + byte_bits(ord('A')) * 2 + [1] * int(post * (BAUD / 1000.0))
out = bytearray()
for i in range(0, len(bits), 8):
    v = 0
    for b in (bits[i:i + 8] + [0] * 8)[:8]: v = (v << 1) | b
    out.append(v)
open(sys.argv[2], 'wb').write(out)
print(f'{len(bits)} bits, {len(out)} bytes')
