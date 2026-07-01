#include "CLoomShellSupport.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stddef.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <unistd.h>
#include <util.h>

static void loom_shell_reset_signals(void) {
    static const int signals_to_reset[] = {
        SIGHUP,
        SIGINT,
        SIGQUIT,
        SIGPIPE,
        SIGALRM,
        SIGTERM,
        SIGCHLD,
        SIGTSTP,
        SIGTTIN,
        SIGTTOU,
    };

    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);

    for (size_t index = 0; index < sizeof(signals_to_reset) / sizeof(signals_to_reset[0]); index += 1) {
        (void)sigaction(signals_to_reset[index], &action, NULL);
    }
}

static void loom_shell_reset_signal_mask(void) {
    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    (void)sigprocmask(SIG_SETMASK, &empty_mask, NULL);
}

__attribute__((noreturn))
static void loom_shell_child_fail(int file_descriptor, const char *message, size_t length) {
    int output_file_descriptor = file_descriptor >= 0 ? file_descriptor : STDERR_FILENO;
    while (length > 0) {
        ssize_t written = write(output_file_descriptor, message, length);
        if (written <= 0) {
            break;
        }
        message += written;
        length -= (size_t)written;
    }
    _exit(127);
}

static int loom_shell_claim_foreground_terminal(int file_descriptor) {
    struct sigaction ignore_action = {0};
    struct sigaction previous_action = {0};
    ignore_action.sa_handler = SIG_IGN;
    sigemptyset(&ignore_action.sa_mask);

    if (sigaction(SIGTTOU, &ignore_action, &previous_action) != 0) {
        return -1;
    }

    int result = tcsetpgrp(file_descriptor, getpgrp());
    int saved_errno = errno;

    (void)sigaction(SIGTTOU, &previous_action, NULL);
    errno = saved_errno;
    return result;
}

static void loom_shell_close_inherited_file_descriptors(void) {
    struct rlimit limit;
    rlim_t max_file_descriptor = 256;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY) {
        max_file_descriptor = limit.rlim_cur;
    }
    if (max_file_descriptor > INT_MAX) {
        max_file_descriptor = INT_MAX;
    }
    for (int file_descriptor = STDERR_FILENO + 1; file_descriptor < (int)max_file_descriptor; file_descriptor += 1) {
        (void)close(file_descriptor);
    }
}

pid_t loom_shell_forkpty_spawn(
    int *master_fd,
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    const struct winsize *window_size
) {
    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, NULL, NULL, (struct winsize *)window_size) != 0) {
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        int saved_errno = errno;
        close(master);
        close(slave);
        errno = saved_errno;
        return -1;
    }

    if (pid != 0) {
        close(slave);
        *master_fd = master;
        return pid;
    }

    close(master);
    loom_shell_reset_signal_mask();
    loom_shell_reset_signals();

    if (setsid() < 0) {
        loom_shell_child_fail(
            slave,
            "loom-shell: failed to create session\r\n",
            sizeof("loom-shell: failed to create session\r\n") - 1
        );
    }

    if (ioctl(slave, TIOCSCTTY, 0) != 0) {
        loom_shell_child_fail(
            slave,
            "loom-shell: failed to claim controlling terminal\r\n",
            sizeof("loom-shell: failed to claim controlling terminal\r\n") - 1
        );
    }

    if (loom_shell_claim_foreground_terminal(slave) != 0) {
        loom_shell_child_fail(
            slave,
            "loom-shell: failed to claim foreground terminal\r\n",
            sizeof("loom-shell: failed to claim foreground terminal\r\n") - 1
        );
    }

    if (dup2(slave, STDIN_FILENO) < 0 ||
        dup2(slave, STDOUT_FILENO) < 0 ||
        dup2(slave, STDERR_FILENO) < 0) {
        loom_shell_child_fail(
            slave,
            "loom-shell: failed to wire stdio\r\n",
            sizeof("loom-shell: failed to wire stdio\r\n") - 1
        );
    }

    if (slave > STDERR_FILENO) {
        close(slave);
    }

    if (working_directory != NULL && chdir(working_directory) != 0) {
        loom_shell_child_fail(
            STDERR_FILENO,
            "loom-shell: failed to change working directory\r\n",
            sizeof("loom-shell: failed to change working directory\r\n") - 1
        );
    }

    loom_shell_close_inherited_file_descriptors();
    execve(path, argv, envp);
    loom_shell_child_fail(
        STDERR_FILENO,
        "loom-shell: failed to exec login shell\r\n",
        sizeof("loom-shell: failed to exec login shell\r\n") - 1
    );
}
