/* vault-backup-helper — minimal Full-Disk-Access-bearing shim for
 * com.user.vault-backup. Source managed by chezmoi (CTristan/dotfiles);
 * compiled per machine by setup-vault-backup. Contains NO secrets.
 *
 * WHY THIS EXISTS: a launchd job cannot read the third-party iCloud container
 * iCloud~md~obsidian without Full Disk Access. Granting FDA to /bin/zsh would
 * hand it to every background zsh — a supply-chain amplifier. Instead this one
 * fixed-path binary holds the grant; macOS attributes TCC responsibility to it,
 * and the children it spawns (the zsh backup script and the git it runs)
 * inherit that access.
 *
 * WHY SPAWN, NOT EXEC: exec() would replace this image with /bin/zsh, so the
 * TCC responsible process would become zsh again and the narrowing would be
 * lost. posix_spawn keeps THIS binary as the responsible parent; the child
 * inherits FDA and we propagate its exit status.
 *
 * REBUILD INVALIDATES THE GRANT: the ad-hoc signature is a content hash, so any
 * recompile changes the code identity and macOS silently drops the FDA grant.
 * Re-toggle it in System Settings whenever setup-vault-backup rebuilds this.
 *
 * NO ARGV/ENV TARGET: the script path is derived from $HOME only — the grant
 * can't be redirected to arbitrary code via arguments. (The script itself lives
 * at a user-writable path, so the narrowing is any-zsh -> this-one-path, not
 * absolute; that residual is the reason the script fails loud, not silent.)
 */
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        fprintf(stderr, "vault-backup-helper: HOME is unset\n");
        return 1;
    }

    char script[4096];
    int n = snprintf(script, sizeof script, "%s/.local/bin/backup-vault.sh", home);
    if (n < 0 || (size_t)n >= sizeof script) {
        fprintf(stderr, "vault-backup-helper: script path too long\n");
        return 1;
    }

    char *const argv[] = {"/bin/zsh", script, NULL};
    pid_t pid;
    int rc = posix_spawn(&pid, "/bin/zsh", NULL, NULL, argv, environ);
    if (rc != 0) {
        fprintf(stderr, "vault-backup-helper: posix_spawn failed: %s\n", strerror(rc));
        return 1;
    }

    int status;
    if (waitpid(pid, &status, 0) < 0) {
        perror("vault-backup-helper: waitpid");
        return 1;
    }
    if (WIFEXITED(status))   return WEXITSTATUS(status);    /* propagate the 0/1/2 contract */
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}
