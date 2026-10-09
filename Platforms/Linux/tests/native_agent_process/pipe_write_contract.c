#include "CNativeAgentProcess.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    struct sigaction disposition = {0}, observed;
    disposition.sa_handler = SIG_DFL;
    assert(sigaction(SIGPIPE, &disposition, NULL) == 0);
    sigset_t pipe_signal, mask, pending;
    sigemptyset(&pipe_signal);
    sigaddset(&pipe_signal, SIGPIPE);
    assert(pthread_sigmask(SIG_UNBLOCK, &pipe_signal, NULL) == 0);
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    close(descriptors[0]);
    const uint8_t bytes[] = {1, 2, 3};
    assert(threading_pipe_write_no_signal(descriptors[1], bytes, sizeof(bytes)) == EPIPE);
    assert(sigaction(SIGPIPE, NULL, &observed) == 0 && observed.sa_handler == SIG_DFL);
    assert(pthread_sigmask(SIG_BLOCK, NULL, &mask) == 0 && !sigismember(&mask, SIGPIPE));
    assert(sigpending(&pending) == 0 && !sigismember(&pending, SIGPIPE));

    // An already pending signal belongs to the caller, not to this write.
    assert(pthread_sigmask(SIG_BLOCK, &pipe_signal, NULL) == 0);
    assert(raise(SIGPIPE) == 0);
    assert(threading_pipe_write_no_signal(descriptors[1], bytes, sizeof(bytes)) == EPIPE);
    assert(sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE));
    int signal_number;
    assert(sigwait(&pipe_signal, &signal_number) == 0 && signal_number == SIGPIPE);
    close(descriptors[1]);
    puts("PASS pipe write: EPIPE with default SIGPIPE, unchanged disposition/mask, caller-owned pending signal preserved");
}
