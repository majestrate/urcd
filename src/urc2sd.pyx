#!/usr/bin/env python

USAGE='''\
urc2sd: help: This NOTICE can be disabled if env/HELP is set \
to 0. /INVITE adds temporary relay if env/INVITE is set to 1. \
Contact the urc2sd admin for permenance. ChanOp BAN/EXCEPT \
masks also filter relay traffic. I.E.: *!sign@* represent \
signed messages and *!urcd@* represents nonverified messages. \
Thanks for supporting URC, the anonymous decentralized \
alternative to IRC.\n'''

from binascii import hexlify
from nacltaia import *
from taia96n import *
import unicodedata
import collections
import subprocess
import codecs
import select
import socket
import signal
import time
import pwd
import sys
import re
import os

RE = 'a-zA-Z0-9^(\)\-_{\}[\]|\\\\'
re_USER = re.compile('!\S+@',re.IGNORECASE).sub
re_SPLIT = re.compile(' +',re.IGNORECASE).split
re_CLIENT_HELP = re.compile('^:['+RE+']+![~:#'+RE+'.]+@[:#'+RE+'.]+ PRIVMSG [#&!+]['+RE+']+ :['+RE+']+[:,]? help$',re.IGNORECASE).search
re_CLIENT_PRIVMSG_NOTICE_TOPIC = re.compile('^:['+RE+']+![~:#'+RE+'.]+@[:#'+RE+'.]+ ((PRIVMSG)|(NOTICE)|(TOPIC)) [#&!+]['+RE+']+ :.*$',re.IGNORECASE).search
re_CLIENT_PART = re.compile('^:['+RE+']+![~:#'+RE+'.]+@[:#'+RE+'.]+ PART [#&!+]['+RE+']+( :)?',re.IGNORECASE).search
re_CLIENT_QUIT = re.compile('^:['+RE+']+![~:#'+RE+'.]+@[:#'+RE+'.]+ QUIT( :)?',re.IGNORECASE).search
re_CLIENT_PING = re.compile('^PING :?.+$',re.IGNORECASE).search
re_CLIENT_JOIN = re.compile('^:['+RE+']+![~:#'+RE+'.]+@[:#'+RE+'.]+ JOIN :[#&!+]['+RE+']+$',re.IGNORECASE).search
re_CLIENT_KICK = re.compile('^:.+ KICK [#&!+]['+RE+']+ ['+RE+']+',re.IGNORECASE).search
re_CLIENT_CHANMODE = re.compile('^:['+RE+']+![~:#'+RE+'.]+@[:#'+RE+'.]+ MODE [#&!+]['+RE+']+ [-+][be] \S+ ?',re.IGNORECASE).search
re_CLIENT_BAN_EXCEPT = re.compile('^:['+RE+'!@~.]+ ((367)|(348)) ['+RE+']+ [#&!+]['+RE+']+ \S+ ',re.IGNORECASE).search
re_BUFFER_CTCP_DCC = re.compile('\x01(ACTION )?',re.IGNORECASE).sub
re_BUFFER_COLOUR = re.compile('(\x03[0-9][0-9]?((?<=[0-9]),[0-9]?[0-9]?)?)|[\x02\x03\x0f\x1d\x1f]',re.IGNORECASE).sub
re_SERVER_PRIVMSG_NOTICE_TOPIC = re.compile('^:['+RE+']+![~:#'+RE+'.]+@[:#'+RE+'.]+ ((PRIVMSG)|(NOTICE)|(TOPIC)) [#&!+]['+RE+']+ :.*$',re.IGNORECASE).search

### some operating systems do not set atime reliably ###
if os.path.exists('env/HELP') \
and time.time() - os.stat('env/HELP')[7] >= 2048 \
and int(open('env/HELP','rb').read().split('\n')[0]):
 os.utime('env/HELP',(time.time(),time.time()))
 HELP = 1
else: HELP = 0

LIMIT = float(open('env/LIMIT','rb').read().split('\n')[0]) if os.path.exists('env/LIMIT') else 1
INVITE = int(open('env/INVITE','rb').read().split('\n')[0]) if os.path.exists('env/INVITE') else 0
COLOUR = int(open('env/COLOUR','rb').read().split('\n')[0]) if os.path.exists('env/COLOUR') else 0
UNICODE = int(open('env/UNICODE','rb').read().split('\n')[0]) if os.path.exists('env/UNICODE') else 0
TIMEOUT = int(open('env/TIMEOUT','rb').read().split('\n')[0]) if os.path.exists('env/TIMEOUT') else 128
PRESENCE = int(open('env/PRESENCE','rb').read().split('\n')[0]) if os.path.exists('env/PRESENCE') else 0
URCSIGNDB = open('env/URCSIGNDB','rb').read().split('\n')[0] if os.path.exists('env/URCSIGNDB') else str()
CHANLIMIT = int(open('env/CHANLIMIT','rb').read().split('\n')[0]) if os.path.exists('env/CHANLIMIT') else 16
URCSIGNPUBKEYDIR = open('env/URCSIGNPUBKEYDIR','rb').read().split('\n')[0] if os.path.exists('env/URCSIGNPUBKEYDIR') else str()

### nacl-20110221's randombytes() not compatible with chroot ###
devurandomfd = os.open("/dev/urandom",os.O_RDONLY)
def randombytes(n): return try_read(devurandomfd,n)

if URCSIGNDB or URCSIGNPUBKEYDIR:

 ### NaCl's crypto_sign / crypto_sign_open API sucks ###
 def _crypto_sign(m,sk):
  s = crypto_sign(m,sk)
  return s[:32]+s[-32:]

 def _crypto_sign_open(m,s,pk):
  return 1 if crypto_sign_open(s[:32]+m+s[32:],pk) != 0 else 0

if URCSIGNPUBKEYDIR:
 urcsignpubkeydb = dict()
 for dst in os.listdir(URCSIGNPUBKEYDIR):
  dst = dst.lower()
  urcsignpubkeydb[dst] = dict()
  for src in os.listdir(URCSIGNPUBKEYDIR+'/'+dst):
   urcsignpubkeydb[dst][src.lower()] = open(URCSIGNPUBKEYDIR+'/'+dst+'/'+src,'rb').read(64).decode('hex')

if URCSIGNDB:
 urcsigndb = dict()
 for src in os.listdir(URCSIGNDB):
  urcsigndb[src.lower()] = open(URCSIGNDB+'/'+src,'rb').read(64).decode('hex')

BAN = dict()
EXCEPT = dict()
seen = time.time()
ping = time.time()
user = str(os.getpid())
bytes = [(chr(i),i) for i in xrange(0,256)]
nick = open('nick','rb').read().split('\n')[0]

channels = collections.deque([],CHANLIMIT)
for dst in open('channels','rb').read().lower().split('\n'):
 if dst: channels.append(dst)

auto_cmd = list()
for cmd in open('auto_cmd','rb').read().split('\n'):
 if cmd: auto_cmd.append(cmd)

def sock_close(sn,sf):
 try: os.remove(str(os.getpid()))
 except: pass
 if sn: sys.exit(sn&255)

signal.signal(signal.SIGHUP,sock_close)
signal.signal(signal.SIGINT,sock_close)
signal.signal(signal.SIGTERM,sock_close)
signal.signal(signal.SIGCHLD,sock_close)

rd = 0
if os.access('stdin',os.X_OK):
 p = subprocess.Popen(['./stdin'],stdout=subprocess.PIPE)
 rd = p.stdout.fileno()
 del p

if os.access('stdout',os.X_OK):
 p = subprocess.Popen(['./stdout'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
 pipefd = ( p.stdout.fileno(), p.stdin.fileno() )
 del p
else: pipefd = os.pipe()

### nacl-20110221's randombytes() not compatible with chroot ###
devurandomfd = os.open("/dev/urandom",os.O_RDONLY)
def randombytes(n): return try_read(devurandomfd,n)

uid, gid = pwd.getpwnam('urcd')[2:4]
os.chdir(sys.argv[1])
os.chroot(os.getcwd())
os.setgroups(list())
os.setgid(gid)
os.setuid(uid)
root = os.getcwd()
del uid, gid

sock=socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM)
sock_close(0,0)
sock.bind(str(os.getpid()))
sock.setblocking(0)
sd=sock.fileno()

poll=select.poll()
poll.register(rd,select.POLLIN|select.POLLPRI)
poll.register(pipefd[0],select.POLLIN)
poll.register(sd,select.POLLIN)
poll=poll.poll

client_revents=select.poll()
client_revents.register(rd,select.POLLIN|select.POLLPRI)
client_revents=client_revents.poll

pipe_revents=select.poll()
pipe_revents.register(pipefd[0],select.POLLIN)
pipe_revents=pipe_revents.poll

server_revents=select.poll()
server_revents.register(sd,select.POLLIN)
server_revents=server_revents.poll

def try_read(fd,buffer_len):
 try: return os.read(fd,buffer_len)
 except: sock_close(1,0)

def try_write(fd,buffer):
 try: return os.write(fd,buffer)
 except: sock_close(2,0)

def sock_write(buffer):
 buflen = len(buffer)
 buffer = chr(buflen>>8)+chr(buflen%256)+taia96n_pack(taia96n_now())+'\x00\x00\x00\x00'+randombytes(8)+buffer
 try: sock.sendto(buffer,'hub')
 except: pass

try_write(1,'USER '+nick+' '+nick+' '+nick+' :'+nick+'\nNICK '+nick+'\n')

def INIT():
 if client_revents(8192): return
 global INIT, auto_cmd, channels
 INIT = 0
 for cmd in auto_cmd:
  time.sleep(LIMIT)
  try_write(1,cmd+'\n')
 for dst in channels:
  time.sleep(LIMIT)
  try_write(1,'JOIN '+dst+'\n')
  if HELP:
   time.sleep(LIMIT)
   try_write(1,'NOTICE '+dst+' :'+USAGE)
 channels = collections.deque([],CHANLIMIT)
 del auto_cmd

while 1:

 if poll(TIMEOUT<<10) and not INIT: time.sleep(LIMIT)
 now = time.time()

 if not client_revents(0):
  if now - seen >= TIMEOUT: sock_close(3,0)
  if now - ping >= TIMEOUT >> 4:
   try_write(1,'PING :LAG\n')
   ping = now

 else:
  buffer, seen, ping = str(), now, now
  while 1:
   byte = try_read(rd,1)
   if byte == '': sock_close(4,0)
   if byte == '\n': break
   if byte != '\r' and len(buffer)<768: buffer += byte

  if re_CLIENT_HELP(buffer): try_write(1,'NOTICE '+re_SPLIT(buffer,3)[2]+' :'+USAGE)

  if re_CLIENT_PRIVMSG_NOTICE_TOPIC(buffer):
   if buffer[1:].split('!',1)[0] != nick: sock_write(buffer+'\n')

  elif PRESENCE and re_CLIENT_PART(buffer):
   if len(buffer.split(' :'))<2: buffer += ' :'
   sock_write(buffer+'\n')

  elif PRESENCE and re_CLIENT_QUIT(buffer):
   if len(buffer.split(' :'))<2: buffer += ' :'
   sock_write(buffer+'\n')

  elif re_CLIENT_PING(buffer): try_write(1,'PONG '+re_SPLIT(buffer,1)[1]+'\n')

  elif re_CLIENT_JOIN(buffer):
   if PRESENCE: sock_write(buffer+'\n')
   dst = buffer.split(' :')[1].lower()
   if not dst in channels:
    if len(channels) - 1 < CHANLIMIT:
     BAN[dst], EXCEPT[dst] = list(), list()
     channels.append(dst)
     try_write(1,'MODE '+dst+' b\n')
     time.sleep(LIMIT)
     try_write(1,'MODE '+dst+' e\n')
    else: try_write(1,'PART '+dst+' :CHANLIMIT\n')

  elif re.search('^:'+re.escape(nick).upper()+'!.+ NICK ',buffer.upper()):
   nick = re_SPLIT(buffer)[2]
   re_CLIENT_HELP = re.compile('^:['+RE+']+![~:#'+RE+'.]+@[:#'+RE+'.]+ PRIVMSG [#&!+]['+RE+']+ :['+re.escape(nick)+']+[:,]? help$',re.IGNORECASE).search

  elif re.search('^:.+ 433 .+ '+re.escape(nick),buffer):
   nick+='_'
   try_write(1,'NICK '+nick+'\n')

  elif re_CLIENT_KICK(buffer):
   if len(buffer.split(' :'))<2: buffer += ' :'
   sock_write(buffer+'\n')
   if re_SPLIT(buffer,4)[3].lower() == nick.lower():
    try_write(1,'JOIN '+re_SPLIT(buffer,4)[2]+'\n')
    del EXCEPT[dst], BAN[dst]
    channels.remove(dst)

  elif INVITE and len(channels) < CHANLIMIT and re.search('^:['+RE+']+![~'+RE+'.]+@['+RE+'.]+ INVITE '+re.escape(nick).upper()+' :[#&!+]['+RE+']+$',buffer.upper()):
   dst = buffer[1:].split(':',1)[1].lower()
   if not dst in channels: try_write(1,'JOIN '+dst+'\n')

  elif re_CLIENT_CHANMODE(buffer):
   try:
    src, cmd, dst = re_SPLIT(buffer,5)[2:5]
    dst = re.compile('^'+re.escape(dst).replace('\\*','.*')+'$',re.IGNORECASE).search
    src = src.lower()
    if cmd[1] == 'b':
     BAN[src].append(dst) if cmd[0] == '+' and not dst in BAN[src] else BAN[src].remove(dst)
    elif cmd[1] == 'e':
     EXCEPT[src].append(dst) if cmd[0] == '+' and not dst in EXCEPT[src] else EXCEPT[src].remove(dst)
   except: pass

  elif re_CLIENT_BAN_EXCEPT(buffer):
   try:
    cmd, src, dst, msg = re_SPLIT(buffer,5)[1:5]
    msg = re.compile('^'+re.escape(msg).replace('\\*','.*')+'$',re.IGNORECASE).search
    dst = dst.lower()
    if cmd == '367':
     if not msg in BAN[dst]: BAN[dst].append(msg)
    elif cmd == '348':
     if not msg in EXCEPT[dst]: EXCEPT.append(msg)
   except: pass

 if INIT:
  INIT()
  continue

 if server_revents(0):
  buffer = try_read(sd,2+12+4+8+1024)

  ### URCSIGN ###
  if buffer[2+12:2+12+4] == '\x01\x00\x00\x00':
   buflen = len(buffer)
   try:
    src, cmd, dst = re_SPLIT(buffer[2+12+4+8+1:].lower(),3)[:3]
    src = src.split('!',1)[0]
   except: src, cmd, dst = buffer[2+12+4+8+1:].split('!',1)[0].lower(), str(), str()

   if URCSIGNPUBKEYDIR \
   and dst in urcsignpubkeydb.keys() \
   and src in urcsignpubkeydb[dst].keys():
    try:
     if _crypto_sign_open(buffer[:buflen-64],buffer[-64:],urcsignpubkeydb[dst][src]):
      buffer = re_USER('!sign@',buffer[2+12+4+8:].split('\n',1)[0],1)
     else: buffer = re_USER('!urcd@',buffer[2+12+4+8:].split('\n',1)[0],1)
    except: buffer = re_USER('!urcd@',buffer[2+12+4+8:].split('\n',1)[0],1)
   elif URCSIGNDB:
    try:
     if _crypto_sign_open(buffer[:buflen-64],buffer[-64:],urcsigndb[src]):
      buffer = re_USER('!sign@',buffer[2+12+4+8:].split('\n',1)[0],1)
     else: buffer = re_USER('!urcd@',buffer[2+12+4+8:].split('\n',1)[0],1)
    except: buffer = re_USER('!urcd@',buffer[2+12+4+8:].split('\n',1)[0],1)
   else: buffer = re_USER('!urcd@',buffer[2+12+4+8:].split('\n',1)[0],1)

  ### URCHUB ###
  else: buffer = re_USER('!urcd@',buffer[2+12+4+8:].split('\n',1)[0],1)

  if buffer: try_write(pipefd[1],buffer+'\n')

 if pipe_revents(0):

  buffer = str()
  while 1:
   byte = try_read(pipefd[0],1)
   if byte == '': sock_close(5,0)
   if byte == '\n': break
   if byte != '\r' and len(buffer)<768: buffer += byte

  action, buffer = (1, re_BUFFER_CTCP_DCC('',buffer) + '\x01') if '\x01ACTION ' in buffer.upper() else (0, re_BUFFER_CTCP_DCC('',buffer))
  if not COLOUR: buffer = re_BUFFER_COLOUR('',buffer)
  if not UNICODE:
   buffer = codecs.ascii_encode(unicodedata.normalize('NFKD',unicode(buffer,'utf-8','replace')),'ignore')[0]
   buffer = ''.join(byte for byte in buffer if 127 > ord(byte) > 31 or byte in ['\x01','\x02','\x03','\x0f','\x1d','\x1f'])
  buffer += '\n'

  poll(ord(randombytes(1))<<4) ### may reduce some side channels ###

  if re_SERVER_PRIVMSG_NOTICE_TOPIC(buffer):
   dst = re_SPLIT(buffer,3)[2].lower()
   if dst in channels:
    cmd, src = 1, re_SPLIT(buffer[1:],1)[0]
    for cmd in EXCEPT[dst]:
     if cmd(src):
      cmd = 0
      break
    if cmd:
     for cmd in BAN[dst]:
      if cmd(src):
       cmd = 0
       break
     if cmd == 0: continue
    cmd = re_SPLIT(buffer,3)[1].upper()
    src = src.split('@',1)[0]+'@'+hexlify(crypto_hash_sha256(src.split('@',1)[1])[:4])+'> '
    if cmd == 'TOPIC':
     try_write(1,'NOTICE '+dst+' :'+src+'/TOPIC\n')
     time.sleep(LIMIT)
     src = str()
    if action: src = '\x01ACTION ' + src
    msg = buffer.split(' :',1)[1]
    buffer = cmd + ' ' + dst + ' :' + src + msg + '\n'
    try_write(1,buffer)
