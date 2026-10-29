#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) return 64;
    sigset_t mask;
    if (sigprocmask(SIG_SETMASK, NULL, &mask) != 0) return 65;
    int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return 66;
    FILE *out = fdopen(fd, "w");
    if (!out) return 67;
    fprintf(out, "{\"pid\":%d,\"processGroup\":%d,\"blocked\":[", getpid(), getpgrp());
    int count = 0;
    for (int value = 1; value < NSIG; value++) {
        if (sigismember(&mask, value) == 1) {
            fprintf(out, "%s%d", count++ ? "," : "", value);
        }
    }
    fprintf(out, "],\"dispositions\":{");
    int signals[] = {SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM};
    for (int i = 0; i < 5; i++) {
        struct sigaction action;
        if (sigaction(signals[i], NULL, &action) != 0) return 68;
        const char *value = action.sa_handler == SIG_DFL ? "default" :
                            action.sa_handler == SIG_IGN ? "ignored" : "handler";
        fprintf(out, "%s\"%d\":\"%s\"", i ? "," : "", signals[i], value);
    }
    fprintf(out, "}}\n");
    if (fclose(out) != 0) return 69;
    if (argc > 3) {
        fd = open(argv[3], O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0) return 70;
        out = fdopen(fd, "w");
        if (!out) return 71;
        fprintf(out, "%d\n", getpid());
        if (fclose(out) != 0) return 72;
    }
    if (strcmp(argv[1], "sleep") == 0) {
        execl("/bin/sleep", "sleep", "30", NULL);
        return 73;
    }
    return 0;
}
