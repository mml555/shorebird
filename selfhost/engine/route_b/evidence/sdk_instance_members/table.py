#!/usr/bin/env python3
# cspell:words lastindex
"""table.py <ids.txt> <logs dir> <out.tsv>: id, RESOLVES|THROWS|ABORTS|NOT-RUN, detail."""
import sys,re,os
ids=open(sys.argv[1]).read().split(); rows=[]
for i in ids:
    f=os.path.join(sys.argv[2],i+'.log')
    log=open(f).read() if os.path.exists(f) else ''
    m=re.search(r'^P after '+re.escape(i)+r'=(.*)$',log,re.M) or re.search(r'^()ATTACH: C\+\+ invoke (?:of target returned: |error: )(.*)$',log,re.M)
    if m and m.lastindex==2: m=re.match(r'(.*)',m.group(2))
    if m:
        r=m.group(1)
        if r=='OK': st,d='RESOLVES',''
        elif 'NoSuchMethodError' in r: st,d='THROWS',r
        else: st,d='RESOLVES',r   # another error type: the member was found
    elif 'Attempt to compile' in log or 'Abort' in log or 'error:' in log:
        st='ABORTS'; d=(re.search(r'error: (.*)',log) or [None,''])[1][:160]
    else: st,d='NOT-RUN',log[-120:].replace('\n',' ')
    rows.append((i,st,d))
open(sys.argv[3],'w').write(''.join(f'{a}\t{b}\t{c}\n' for a,b,c in rows))
from collections import Counter
print(Counter(b for _,b,_ in rows))
