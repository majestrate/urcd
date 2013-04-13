#define USAGE "Usage: urchubstream /path/to/sockets/\n"
#include <sys/socket.h>
#include <sys/fcntl.h>
#include <sys/types.h>
#include <strings.h>
#include <unistd.h>
#include <sys/un.h>
#include <stdlib.h>
#include <signal.h>
#include <stdio.h>
#include <poll.h>
#include <pwd.h>

#ifndef UNIX_PATH_MAX
#define UNIX_PATH_MAX 108
#endif

int itoa(char *s, int n, int slen)
{
  int fd[2], ret = 0;
  if (pipe(fd)<0) return -1;
  if ((dprintf(fd[1],"%d",n)<0) || (read(fd[0],s,slen)<0)) --ret;
  close(fd[0]);
  close(fd[1]);
  return ret;
}

main(int argc, char **argv)
{

  if (argc<2)
  {
    write(2,USAGE,strlen(USAGE));
    exit(64);
  }

  int rd = 0, wr = 1;
  if (getenv("TCPCLIENT")){ rd = 6; wr = 7; }

  char buffer[2+16+8+1024] = {0};
  char user[UNIX_PATH_MAX] = {0};
  if (itoa(user,getpid(),UNIX_PATH_MAX)<0) exit(1);

  if (chdir(argv[1])) exit(64);
  struct passwd *urcd = getpwnam("urcd");
  if ((!urcd) || ((chroot(argv[1])) || (setgid(urcd->pw_gid)) || (setuid(urcd->pw_uid)))) exit(64);

  struct sockaddr_un sock;
  bzero(&sock,sizeof(sock));
  sock.sun_family = AF_UNIX;

  void sock_close(int signum)
  {
    unlink(sock.sun_path);
    exit(signum);
  } signal(SIGINT,sock_close); signal(SIGHUP,sock_close); signal(SIGTERM,sock_close); 

  if (socket(AF_UNIX,SOCK_DGRAM,0)!=3) exit(2);
  int n = 1;
  if (setsockopt(3,SOL_SOCKET,SO_REUSEADDR,&n,sizeof(n))<0) exit(3);
  int userlen = strlen(user);
  if (userlen > UNIX_PATH_MAX) exit(4);
  memcpy(&sock.sun_path,user,userlen+1);
  unlink(sock.sun_path);
  if (bind(3,(struct sockaddr *)&sock,sizeof(sock.sun_family)+userlen)<0) exit(5);
  if (fcntl(3,F_SETFL,O_NONBLOCK)<0) sock_close(6);

  struct pollfd fds[2];
  fds[0].fd = rd; fds[0].events = POLLIN | POLLPRI;
  fds[1].fd = 3; fds[1].events = POLLIN;

  struct sockaddr_un hub;
  bzero(&hub,sizeof(hub));
  hub.sun_family = AF_UNIX;
  memcpy(&hub.sun_path,"hub\0",4);

  int i, l;

  while (1)
  {

    poll(fds,2,-1);

    if (fds[0].revents)
    {

      if (read(rd,buffer,2)<2) sock_close(7);

      n = 2;
      l = 2 + 16 + 8 + buffer[0] * 256 + buffer[1];
      if (l>2+16+8+1024) sock_close(8);

      while (n<l)
      {
        i = read(rd,buffer+n,l-n);
        if (i<1) sock_close(9);
        n += i;
      } if (sendto(3,buffer,n,0,(struct sockaddr *)&hub,sizeof(hub))<0) usleep(250000);

    }

    while (poll(fds+1,1,0))
    {
      n = read(3,buffer,2+16+8+1024);
      if (n<1) sock_close(10);
      if (n != (int) 2 + 16 + 8 + buffer[0] * 256 + buffer[1]) continue;
      if (write(wr,buffer,n)<0) sock_close(11);
    }

  }
}
