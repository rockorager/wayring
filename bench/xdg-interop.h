#ifndef WAYRING_XDG_INTEROP_H
#define WAYRING_XDG_INTEROP_H

int xdg_client_fd(int fd);
int xdg_server_fd(int fd);
int shm_client_fd(int fd);
int shm_server_fd(int fd);
int dmabuf_client_fd(int fd);
int dmabuf_server_fd(int fd);
int data_device_client_fd(int fd);
int data_device_server_fd(int fd);
int output_client_fd(int fd);
int output_server_fd(int fd);
int pointer_client_fd(int fd);
int pointer_server_fd(int fd);
int keyboard_client_fd(int fd);
int keyboard_server_fd(int fd);
int touch_client_fd(int fd);
int touch_server_fd(int fd);

#endif
