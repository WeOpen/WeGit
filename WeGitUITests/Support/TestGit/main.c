#include <fcntl.h>
#include <limits.h>
#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

static void record_command(const char *marker, char command) {
    char *path = NULL;
    if (asprintf(&path, "%s-commands", marker) < 0) return;
    int file = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (file >= 0) { (void)write(file, &command, 1); close(file); }
    free(path);
}

static bool selected_git(char path[PATH_MAX]) {
    // xcrun cannot run in an App Sandbox. Use the same build-time receipt as
    // UITestGit, kept adjacent to both the standalone and embedded helper.
    char executable[PATH_MAX], resolved[PATH_MAX], receipt[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, resolved)) return false;
    char *separator = strrchr(resolved, '/');
    if (!separator) return false;
    *separator = '\0';
    int length = snprintf(receipt, sizeof(receipt), "%s/WeGitTestGitPath.txt", resolved);
    if (length < 0 || length >= sizeof(receipt)) return false;
    FILE *record = fopen(receipt, "r");
    if (!record) return false;
    bool received = fgets(path, PATH_MAX, record) != NULL;
    fclose(record);
    if (!received) return false;
    path[strcspn(path, "\r\n")] = '\0';
    return path[0] == '/' && access(path, X_OK) == 0;
}

// New feedback faults are accepted only for the explicitly selected private
// fixture, while Git is executing in it, and for one exact .git marker name.
static const char *feedback_marker(const char *key, const char *name) {
    const char *marker = getenv(key);
    const char *fixture = getenv("WEGIT_OPERATION_FEEDBACK_FIXTURE");
    char cwd[PATH_MAX], resolved[PATH_MAX], expected[PATH_MAX];
    if (!marker || !fixture || !getcwd(cwd, sizeof(cwd)) || !realpath(fixture, resolved)
        || strcmp(cwd, resolved) != 0) return NULL;
    const char *basename = strrchr(cwd, '/');
    const char prefix[] = "WeGitFeedbackUI-";
    if (!basename || strncmp(basename + 1, prefix, sizeof(prefix) - 1) != 0) return NULL;
    int length = snprintf(expected, sizeof(expected), "%s/.git/%s", fixture, name);
    if (length < 0 || length >= sizeof(expected) || strcmp(marker, expected) != 0) return NULL;
    return marker;
}

static bool create_marker(const char *marker) {
    int file = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (file < 0) return false;
    close(file);
    return true;
}

static int forward_and_wait(const char *git, char *argv[]) {
    pid_t child = fork();
    if (child < 0) return 127;
    if (child == 0) { execv(git, argv); _exit(127); }
    int status;
    while (waitpid(child, &status, 0) < 0) { if (errno != EINTR) return 127; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

// Test-bundle helper only. Forward every byte of stdin/stdout and every Git
// argument; hold the first history read until ProcessRunner cancels its group.
int main(int argc, char *argv[]) {
    char git[PATH_MAX];
    if (!selected_git(git)) {
        fputs("Build-time selected Xcode Git is missing or unavailable.\n", stderr);
        return 127;
    }
    const char *marker = getenv("WEGIT_HISTORY_DELAY_MARKER");
    bool history = false;
    bool push = false;
    bool query = false;
    bool config = false;
    bool commit = false;
    bool stash_drop = false;
    bool branch = false;
    for (int index = 1; index < argc; index++) {
        if (argv[index][0] == '-') continue;
        history = strcmp(argv[index], "rev-list") == 0;
        push = strcmp(argv[index], "push") == 0;
        query = strcmp(argv[index], "ls-remote") == 0;
        config = strcmp(argv[index], "config") == 0;
        commit = strcmp(argv[index], "commit") == 0;
        stash_drop = strcmp(argv[index], "stash") == 0 && index + 1 < argc
            && strcmp(argv[index + 1], "drop") == 0;
        branch = strcmp(argv[index], "branch") == 0;
        break;
    }
    const char *commit_delay = feedback_marker("WEGIT_COMMIT_DELAY_MARKER", "feedback-commit-delay");
    if (commit && commit_delay && create_marker(commit_delay)) sleep(60);
    const char *upstream_failure = feedback_marker(
        "WEGIT_UPSTREAM_WRITE_FAILURE_MARKER", "feedback-upstream-write");
    bool set_upstream = false;
    for (int index = 1; index < argc; index++) {
        if (strncmp(argv[index], "--set-upstream-to=", 18) == 0) set_upstream = true;
    }
    if (branch && set_upstream && upstream_failure && create_marker(upstream_failure)) {
        fputs("fatal: fixture rejected only the upstream configuration write\n", stderr);
        return 128;
    }
    const char *stash_failure = feedback_marker(
        "WEGIT_STASH_DROP_FAILURE_MARKER", "feedback-stash-drop");
    const char *stash_point = getenv("WEGIT_STASH_DROP_FAILURE_POINT");
    if (stash_drop && stash_failure && stash_point && strcmp(stash_point, "before") == 0
        && create_marker(stash_failure)) {
        fputs("fatal: fixture lost the stash deletion receipt before removal\n", stderr);
        return 128;
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
    if (stash_drop && stash_failure && stash_point && strcmp(stash_point, "after") == 0) {
        int result = forward_and_wait(git, argv);
        if (result == 0 && create_marker(stash_failure)) {
            fputs("fatal: fixture lost the stash deletion receipt after removal\n", stderr);
            return 128;
        }
        return result;
    }
    const char *commit_reply = feedback_marker(
        "WEGIT_COMMIT_REPLY_LOSS_MARKER", "feedback-commit-reply");
    if (commit && commit_reply) {
        int result = forward_and_wait(git, argv);
        if (result == 0 && create_marker(commit_reply)) {
            fputs("fatal: fixture lost the commit response\n", stderr);
            return 128;
        }
        return result;
    }
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
