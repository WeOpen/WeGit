#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

static void record_command(const char *marker, char command) {
    char *path = NULL;
    if (asprintf(&path, "%s-commands", marker) < 0) return;
    int file = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (file >= 0) { (void)write(file, &command, 1); close(file); }
    free(path);
}

// Test-bundle helper only. Forward every byte of stdin/stdout and every Git
// argument; hold the first history read until ProcessRunner cancels its group.
int main(int argc, char *argv[]) {
    const char *git = "/Applications/Xcode.app/Contents/Developer/usr/bin/git";
    const char *marker = getenv("WEGIT_HISTORY_DELAY_MARKER");
    bool history = false;
    bool push = false;
    bool query = false;
    bool config = false;
    for (int index = 1; index < argc; index++) {
        if (argv[index][0] == '-') continue;
        history = strcmp(argv[index], "rev-list") == 0;
        push = strcmp(argv[index], "push") == 0;
        query = strcmp(argv[index], "ls-remote") == 0;
        config = strcmp(argv[index], "config") == 0;
        break;
    }
    const char *config_marker = getenv("WEGIT_CONFIG_WRITE_DELAY_MARKER");
    bool config_write = false;
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--replace-all") == 0 || strcmp(argv[index], "--unset-all") == 0) config_write = true;
    }
    if (config && config_write && config_marker) {
        int file = open(config_marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (file >= 0) { close(file); sleep(60); }
    }
    if (history && marker) {
        int file = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (file >= 0) {
            signal(SIGTERM, SIG_IGN);
            close(file);
            sleep(15);
        }
    }
    const char *reply_marker = getenv("WEGIT_PUSH_REPLY_LOSS_MARKER");
    if (reply_marker && (push || query)) record_command(reply_marker, push ? 'P' : 'Q');
    argv[0] = (char *)git;
    if (push && reply_marker) {
        pid_t child = fork();
        if (child < 0) return 127;
        if (child == 0) { execv(git, argv); _exit(127); }
        int status;
        while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 127; }
        if (!WIFEXITED(status)) return 128;
        int result = WEXITSTATUS(status);
        if (result == 0) {
            int file = open(reply_marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (file >= 0) {
                close(file);
                fputs("fatal: fixture lost the push response\n", stderr);
                return 128;
            }
        }
        return result;
    }
    execv(git, argv);
    return 127;
}
