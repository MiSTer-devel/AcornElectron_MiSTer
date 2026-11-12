# make gzip test vectors: <name>.gz + <name>.out
import gzip, zlib, os, sys, random, zipfile, struct, glob
out = sys.argv[1]; src = sys.argv[2]
def gz(name, data, level=9, flags=b'', extra=None, fname=None, comment=None, hcrc=False):
    # build a gzip member by hand so we control the header flags
    flg = 0; tail = b''
    if extra is not None: flg |= 4; tail += struct.pack('<H', len(extra)) + extra
    if fname is not None: flg |= 8; tail += fname + b'\0'
    if comment is not None: flg |= 16; tail += comment + b'\0'
    hdr = b'\x1f\x8b\x08' + bytes([flg | (2 if hcrc else 0)]) + b'\0\0\0\0\x00\x03' + tail
    if hcrc: hdr += struct.pack('<H', zlib.crc32(hdr) & 0xffff)
    c = zlib.compressobj(level, zlib.DEFLATED, -15)
    body = c.compress(data) + c.flush()
    open(f'{out}/{name}.gz','wb').write(hdr + body + struct.pack('<II', zlib.crc32(data) & 0xffffffff, len(data) & 0xffffffff))
    open(f'{out}/{name}.out','wb').write(data)
r = random.Random(1)
gz('empty', b'')
gz('hello', b'Hello, Electron!\n')
gz('stored', bytes(r.randrange(256) for _ in range(70000)), level=0)       # two stored blocks
gz('random_l9', bytes(r.randrange(256) for _ in range(5000)))
gz('runs', b'A' * 100000 + b'B' * 3 + b'AB' * 5000)                           # long matches, dist 1/2
gz('text', open('/usr/share/dict/words','rb').read()[:400000] if os.path.exists('/usr/share/dict/words') else b'x'*1000)
gz('flags', b'flags test ' * 300, extra=b'XY\x04\x00abcd', fname=b'name.uef', comment=b'a comment', hcrc=True)
gz('far', bytes(r.randrange(256) for _ in range(32000)) * 2)                # distance ~32000
# real tapes: gzipped UEFs from the STH zips
n = 0
for z in sorted(glob.glob(src + '/*.zip')):
    with zipfile.ZipFile(z) as zf:
        for m in zf.namelist():
            if m.lower().endswith('.uef'):
                d = zf.read(m)
                if d[:2] == b'\x1f\x8b':
                    base = 'uef_' + os.path.basename(m)[:-4].replace(' ', '_')
                    open(f'{out}/{base}.gz','wb').write(d)
                    open(f'{out}/{base}.out','wb').write(gzip.decompress(d))
                    n += 1
print('vectors written; real UEFs:', n)
