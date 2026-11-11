#!/usr/bin/env python3
"""Put a 16 KB ROM into one slot of the 112 KB ROM image (ELK.mif or a .bin).

    python3 roms/add_rom.py IMAGE ROM SLOT [OUT]

IMAGE is an srec_cat .mif (roms/ELK.mif; its line layout is kept, so a diff
shows only the ROM's bytes) or a raw 112 KB .bin. SLOT is the image slot
(rtl/electron_mem.sv): 4 = ROM 13, the Plus 3's ADFS. OUT defaults to IMAGE.

Used for ROMs that are not in the repository (the Plus 3 ADFS ROM): build
with a patched copy, never commit it.
"""
import re
import sys


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    image, rom, slot = sys.argv[1], sys.argv[2], int(sys.argv[3])
    out = sys.argv[4] if len(sys.argv) == 5 else image
    data = open(rom, 'rb').read()
    if len(data) == 8192:
        data = data * 2
    if len(data) != 16384:
        sys.exit(f'{rom}: {len(data)} bytes, want 16384 (or 8192)')
    base = slot * 16384
    if not 0 <= slot < 7:
        sys.exit('slot must be 0..6')

    if image.lower().endswith('.mif'):
        raw = open(image, newline='').read()
        nl = '\r\n' if '\r\n' in raw else '\n'
        lines = raw.split(nl)
        done = 0
        for i, l in enumerate(lines):
            m = re.match(r'^([0-9A-Fa-f]+): (.*);$', l)
            if not m:
                continue
            a = int(m.group(1), 16)
            v = m.group(2).split()
            changed = False
            for k in range(len(v)):
                if base <= a + k < base + 16384:
                    v[k] = f'{data[a + k - base]:02X}'
                    changed = True
                    done += 1
            if changed:
                lines[i] = f'{m.group(1)}: ' + ' '.join(v) + ';'
        if done != 16384:
            sys.exit(f'{image}: only {done} bytes of slot {slot} found')
        open(out, 'w', newline='').write(nl.join(lines))
    else:
        img = bytearray(open(image, 'rb').read())
        if len(img) != 7 * 16384:
            sys.exit(f'{image}: {len(img)} bytes, want {7 * 16384}')
        img[base:base + 16384] = data
        open(out, 'wb').write(img)
    print(f'{rom} -> {out} slot {slot}')


if __name__ == '__main__':
    main()
