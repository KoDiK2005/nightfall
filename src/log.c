/*
 * NIGHTFALL — a local session log.
 *
 * Writes a plain-text `nightfall_log.txt` next to the executable: the seed,
 * key floor/chest events, and how the run ended. Nothing is sent over the
 * network -- this exists purely so a player who hits a bug can attach the
 * file to a GitHub issue. It's appended to (not overwritten) so it can
 * carry a small history of recent sessions if something intermittent is
 * being tracked down. If the file can't be opened (e.g. a read-only
 * install directory) logging just silently no-ops.
 */
#include "game.h"
#include <stdarg.h>

static FILE *nf_logfile = NULL;

static void log_timestamp(void) {
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    if (t) fprintf(nf_logfile, "[%02d:%02d:%02d] ", t->tm_hour, t->tm_min, t->tm_sec);
}

void nf_log_init(void) {
    nf_logfile = fopen("nightfall_log.txt", "a");
    if (!nf_logfile) return;
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    if (t) fprintf(nf_logfile, "\n==== session start %04d-%02d-%02d %02d:%02d:%02d ====\n",
                   t->tm_year + 1900, t->tm_mon + 1, t->tm_mday, t->tm_hour, t->tm_min, t->tm_sec);
    fflush(nf_logfile);
}

void nf_log(const char *fmt, ...) {
    if (!nf_logfile) return;
    log_timestamp();
    va_list ap;
    va_start(ap, fmt);
    vfprintf(nf_logfile, fmt, ap);
    va_end(ap);
    fputc('\n', nf_logfile);
    fflush(nf_logfile);              /* flushed every line so a crash doesn't lose it */
}

void nf_log_close(void) {
    if (!nf_logfile) return;
    fclose(nf_logfile);
    nf_logfile = NULL;
}

/* Read the whole log back off disk and hand it to the OS clipboard, so a
 * player can paste it straight into a GitHub issue -- no file attachment,
 * no network call, just Ctrl+V. Returns 1 on success, 0 if there's nothing
 * to copy yet (or the read/clipboard call failed).                        */
int nf_log_copy_to_clipboard(void) {
    FILE *f = fopen("nightfall_log.txt", "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return 0; }
    char *buf = malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return 0; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[got] = 0;
    int ok = (SDL_SetClipboardText(buf) == 0);
    free(buf);
    return ok;
}
