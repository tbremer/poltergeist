#ifndef POLTERGEIST_CPTY_H
#define POLTERGEIST_CPTY_H

#include <sys/types.h>

/*
 * Spawn `path` attached to a freshly allocated pseudo-terminal.
 *
 * The child becomes a session leader with the pty slave as its controlling
 * terminal (via forkpty), then optionally chdir(cwd) and execve(path,...).
 * `argv` and `envp` must be NULL-terminated.
 *
 * Returns the child pid (> 0) on success and writes the master fd to
 * `out_master_fd`. Returns -1 if forkpty fails.
 */
pid_t cpty_spawn(const char *path,
                 char *const argv[],
                 char *const envp[],
                 const char *cwd,
                 unsigned short rows,
                 unsigned short cols,
                 unsigned int width_px,
                 unsigned int height_px,
                 int *out_master_fd);

/*
 * Apply a new window size to the pty master fd (TIOCSWINSZ), which raises
 * SIGWINCH in the foreground process group. Returns 0 on success, -1 on error.
 */
int cpty_set_winsize(int fd,
                     unsigned short rows,
                     unsigned short cols,
                     unsigned int width_px,
                     unsigned int height_px);

#endif /* POLTERGEIST_CPTY_H */
