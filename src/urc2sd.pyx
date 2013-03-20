#!/usr/bin/env python
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

RE = 'a-zA-Z0-9^(\)\-_{\}[\]|'
re_CLIENT_PRIVMSG_NOTICE_TOPIC = re.compile('^:['+RE+']+![~'+RE+'.]+@['+RE+'.]+ ((PRIVMSG)|(NOTICE)|(TOPIC)) #['+RE+']+ :.*$',re.IGNORECASE).search
re_CLIENT_PART = re.compile('^:['+RE+']+![~'+RE+'.]+@['+RE+'.]+ PART #['+RE+']+( :)?',re.IGNORECASE).search
re_CLIENT_QUIT = re.compile('^:['+RE+']+![~'+RE+'.]+@['+RE+'.]+ QUIT( :)?',re.IGNORECASE).search
re_CLIENT_PING = re.compile('^PING :?.+$',re.IGNORECASE).search
re_CLIENT_JOIN = re.compile('^:['+RE+']+![~'+RE+'.]+@['+RE+'.]+ JOIN :#['+RE+']+$',re.IGNORECASE).search
re_CLIENT_KICK = re.compile('^:.+ KICK #['+RE+']+ ['+RE+']+',re.IGNORECASE).search
re_BUFFER_X02_X0F = re.compile('[\x02\x0f]',re.IGNORECASE).sub
re_BUFFER_CTCP_DCC = re.compile('\x01(ACTION )?',re.IGNORECASE).sub
re_BUFFER_COLOUR = re.compile('\x03[0-9]?[0-9]?((?<=[0-9]),[0-9]?[0-9]?)?',re.IGNORECASE).sub
re_SERVER_PRIVMSG_NOTICE_TOPIC = re.compile('^:['+RE+']+![~'+RE+'.]+@['+RE+'.]+ ((PRIVMSG)|(NOTICE)|(TOPIC)) #['+RE+']+ :.*$',re.IGNORECASE).search

LIMIT = float(open('env/LIMIT','rb').read().split('\n')[0]) if os.path.exists('env/LIMIT') else 1
user = str(os.getpid())
nick = open('nick','rb').read().split('\n')[0]

channels = collections.deque([],64)
for dst in open('channels','rb').read().split('\n'):
  if dst: channels.append(dst.lower())

auto_cmd = collections.deque([],64)
for cmd in open('auto_cmd','rb').read().split('\n'):
  if cmd: auto_cmd.append(cmd)

def sock_close(sn,sf):
  try:
    os.remove(str(os.getpid()))
  except:
    pass
  if sn: sys.exit(0)

signal.signal(1 ,sock_close)
signal.signal(2 ,sock_close)
signal.signal(15,sock_close)

rd = 0
if os.access('stdin',1):
  p = subprocess.Popen(['./stdin'],stdout=subprocess.PIPE)
  rd = p.stdout.fileno()
  del p

wr = 1
if os.access('stdout',1):
  p = subprocess.Popen(['./stdout'],stdin=subprocess.PIPE)
  wr = p.stdin.fileno()
  del p

uid, gid = pwd.getpwnam('urcd')[2:4]
os.chdir(sys.argv[1])
os.chroot(os.getcwd())
os.setgid(gid)
os.setuid(uid)
root = os.getcwd()
del uid, gid

sock=socket.socket(1,2)
sock_close(0,0)
sock.bind(str(os.getpid()))
sock.setblocking(0)
sd=sock.fileno()

poll=select.poll()
poll.register(rd,select.POLLIN|select.POLLPRI)
poll.register(sd,select.POLLIN)
poll=poll.poll

client_events=select.poll()
client_events.register(rd,select.POLLIN|select.POLLPRI)
def client_revents(): return len(client_events.poll(0))

server_events=select.poll()
server_events.register(sd,select.POLLIN)
def server_revents(): return len(server_events.poll(0))

def try_write(fd,buffer):
  try:
    os.write(fd,buffer)
  except:
    sock_close(15,0)

def sock_write(buffer):
  for path in os.listdir(root):
    try:
      if path != user: sock.sendto(buffer,path)
    except:
      pass

def INIT():
  global INIT
  INIT = 0

  for cmd in auto_cmd:
    time.sleep(len(auto_cmd))
    try_write(wr,cmd+'\n')

  for dst in channels:
    time.sleep(len(channels)*2)
    try_write(wr,'JOIN '+dst+'\n')

try_write(wr,
  'USER '+nick+' '+nick+' '+nick+' :'+nick+'\n'
  'NICK '+nick+'\n'
)

while 1:

  poll(-1)

  if client_revents():

    time.sleep(LIMIT)

    buffer = str()
    while 1:
      byte = os.read(rd,1)
      if byte == '': sock_close(15,0)
      if byte == '\n': break
      if byte != '\r' and len(buffer)<768: buffer+=byte

    if re_CLIENT_PRIVMSG_NOTICE_TOPIC(buffer):
      src = buffer[1:].split('!',1)[0]
      if src == nick: continue
      sock_write(buffer+'\n')

    elif re_CLIENT_PART(buffer):
      if len(buffer.split(' :'))<2: buffer += ' :'
      sock_write(buffer+'\n')

    elif re_CLIENT_QUIT(buffer):
      if len(buffer.split(' :'))<2: buffer += ' :'
      sock_write(buffer+'\n')

    elif re_CLIENT_PING(buffer):
      dst = buffer.split(' ',1)[1]
      try_write(wr,'PONG '+dst+'\n')

    elif re_CLIENT_JOIN(buffer):
      sock_write(buffer+'\n')
      dst = buffer.split(':')[2].lower()
      if not dst in channels: channels.append(dst)

    elif re.search('^:'+re.escape(nick).upper()+'!.+ NICK ',buffer.upper()):
      nick = buffer.split(' ')[2]

    elif re.search('^:.+ 433 .+ '+re.escape(nick),buffer):
      nick+='_'
      try_write(wr,'NICK '+nick+'\n')

    elif re_CLIENT_KICK(buffer):

      if len(buffer.split(' :'))<2: buffer += ' :'

      sock_write(buffer+'\n')

      if buffer.split(' ')[3].lower() == nick.lower():
        dst = buffer.split(' ')[2].lower()
        try_write(wr,'JOIN '+dst+'\n')
        channels.remove(dst)

    elif re.search('^:['+RE+']+![~'+RE+'.]+@['+RE+'.]+ INVITE '+re.escape(nick).upper()+' :#['+RE+']+$',buffer.upper()):
      dst = buffer.split(':',2)[2].lower()
      if not dst in channels:
        try_write(wr,'JOIN '+dst+'\n')

    if INIT: INIT()

  while server_revents():

    time.sleep(LIMIT)

    buffer = os.read(sd,1024)
    if not buffer: break

    buffer = codecs.ascii_encode(unicodedata.normalize('NFKD',unicode(buffer,'utf-8','replace')),'ignore')[0]
    buffer = re_BUFFER_X02_X0F('',buffer)
    buffer = re_BUFFER_CTCP_DCC('*',buffer)
    buffer = re_BUFFER_COLOUR('',buffer)
    buffer = str({str():buffer})[6:-4]+'\n'
    buffer = buffer.replace("\\'","'")
    buffer = buffer.replace('\\\\','\\')

    if re_SERVER_PRIVMSG_NOTICE_TOPIC(buffer):
      dst = buffer.split(' ',3)[2].lower()
      if dst in channels:
        cmd = buffer.split(' ',3)[1].upper()
        src = buffer[1:].split('!',1)[0] + '> ' if cmd != 'TOPIC' else str()
        msg = buffer.split(':',2)[2]
        buffer = cmd + ' ' + dst + ' :' + src + msg + '\n'
        try_write(wr,buffer)
