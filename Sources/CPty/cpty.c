#include "cpty.h"

#include <util.h>        /* forkpty */
#include <unistd.h>      /* execve, chdir, _exit */
#include <sys/ioctl.h>   /* ioctl, TIOCSWINSZ */
#include <termios.h>
#include <stddef.h>

pid_t cpty_spawn(const char *path,
                 char *const argv[],
                 char *const envp[],
                 const char *cwd,
                 unsigned short rows,
                 unsigned short cols,
                 unsigned int width_px,
                 unsigned int height_px,
                 int *out_master_fd) {
    struct winsize ws;
    ws.ws_row = rows ? rows : 24;
    ws.ws_col = cols ? cols : 80;
    ws.ws_xpixel = (unsigned short)width_px;
    ws.ws_ypixel = (unsigned short)height_px;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }

    if (pid == 0) {
        /* Child. Only async-signal-safe calls between fork and exec. */
        if (cwd != NULL) {
            (void)chdir(cwd);
        }
        execve(path, argv, envp);
        _exit(127); /* exec failed */
    }

    if (out_master_fd != NULL) {
        *out_master_fd = master;
    }
    return pid;
}

int cpty_set_winsize(int fd,
                     unsigned short rows,
                     unsigned short cols,
                     unsigned int width_px,
                     unsigned int height_px) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = (unsigned short)width_px;
    ws.ws_ypixel = (unsigned short)height_px;
    return ioctl(fd, TIOCSWINSZ, &ws);
}
