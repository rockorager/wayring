#ifndef WAYRING_XDG_INTEROP_H
#define WAYRING_XDG_INTEROP_H

int xdg_client_fd(int fd);
int xdg_server_fd(int fd);
int shm_client_fd(int fd);

#endif
