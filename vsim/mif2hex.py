#!/usr/bin/env python3
"""Convert an srec_cat Quartus .mif (ADDR: b b b ...;) to a $readmemh file."""
import sys

def main(src, dst):
    depth, data, body = 0, {}, False
    for line in open(src):
        line = line.split('--')[0].strip()
        if not line:
            continue
        if line.upper().startswith('DEPTH'):
            depth = int(line.split('=')[1].strip(' ;'))
        elif line.upper().startswith('CONTENT BEGIN'):
            body = True
        elif line.upper().startswith('END'):
            body = False
        elif body and ':' in line:
            addr, vals = line.rstrip(';').split(':', 1)
            a = int(addr, 16)
            for i, v in enumerate(vals.split()):
                data[a + i] = int(v, 16)
    with open(dst, 'w') as f:
        for a in range(depth):
            f.write('%02X\n' % data.get(a, 0))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
