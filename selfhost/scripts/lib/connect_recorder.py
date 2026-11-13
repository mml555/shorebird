# cspell:words getpeername lsof Fc sendall RDWR
"""A forwarding proxy that records every outbound CONNECT (host, port, process).

    connect_recorder.py <port> <logPath>

Listens on 127.0.0.1 and logs one JSON line per CONNECT (or plain HTTP request)
with the name of the client process, so a run can show which hosts a toolchain
reached. Used by selfhost/ci/ios_device_e2e.sh when E2E_ARTIFACT_UPSTREAM is set.
"""
import socket, threading, sys, json, time
PORT=int(sys.argv[1]); LOG=sys.argv[2]; lk=threading.Lock()
def rec(**k):
    with lk, open(LOG,'a') as f: f.write(json.dumps(dict(t=time.time(),**k))+'\n')
def pipe(a,b):
    try:
        while (d:=a.recv(65536)): b.sendall(d)
    except Exception: pass
    for s in (a,b):
        try: s.shutdown(socket.SHUT_RDWR)
        except Exception: pass
import subprocess
def who(c):
    try:
        port=c.getpeername()[1]
        o=subprocess.run(['/usr/sbin/lsof','-nP','-a','-iTCP:%d'%port,'-sTCP:ESTABLISHED','-Fc'],capture_output=True,text=True,timeout=3).stdout
        return ' '.join(x[1:] for x in o.split() if x.startswith('c'))
    except Exception as e: return str(e)
def h(c):
    try:
        buf=b''
        while b'\r\n\r\n' not in buf:
            d=c.recv(65536)
            if not d: return
            buf+=d
        line=buf.split(b'\r\n')[0].decode()
        m,target,_=line.split(' ',2)
        if m=='CONNECT':
            host,port=target.rsplit(':',1)
            u=socket.create_connection((host,int(port)),timeout=30)
            rec(kind='CONNECT',host=host,port=port,proc=who(c))
            c.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
        else:
            from urllib.parse import urlparse
            p=urlparse(target); host=p.hostname; port=p.port or 80
            u=socket.create_connection((host,port),timeout=30)
            rec(kind=m,host=host,port=port,url=target)
            u.sendall(buf)
        threading.Thread(target=pipe,args=(c,u),daemon=True).start(); pipe(u,c)
    except Exception as e: rec(kind='ERR',err=str(e))
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',PORT)); s.listen(128)
while True:
    c,_=s.accept(); threading.Thread(target=h,args=(c,),daemon=True).start()
