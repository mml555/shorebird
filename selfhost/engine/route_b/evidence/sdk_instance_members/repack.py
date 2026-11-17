#!/usr/bin/env python3
"""repack.py <container> <selector> <out>: a copy of an SBRBPTCH container
holding only the target whose selector matches. The attach native invokes every
attached target once, so a probe that aborts the process must be alone."""
import sys,json,struct
b=open(sys.argv[1],'rb').read()
assert b[:8]==b'SBRBPTCH'
ver,hl=struct.unpack('<II',b[8:16]); h=json.loads(b[16:16+hl]); base=16+hl
t=[x for x in h['targets'] if x['selector']==sys.argv[2]]
assert len(t)==1,sys.argv[2]
t=dict(t[0]); blob=b[base+t['offset']:base+t['offset']+t['length']]
t['offset']=0; h['targets']=[t]
hb=json.dumps(h).encode()
open(sys.argv[3],'wb').write(b'SBRBPTCH'+struct.pack('<II',ver,len(hb))+hb+blob)
