/* pipe2 only exists on iOS 27+, but the iOS 27 SDK makes configure report it,
 * which weak-links a NULL pipe2 on older iOS. Always use pipe + fcntl instead. */
#pragma once
#include <unistd.h>
#include <fcntl.h>

static inline int madeira_pipe2( int fd[2], int flags )
{
    if (pipe( fd )) return -1;
    if (flags & O_CLOEXEC)
    {
        fcntl( fd[0], F_SETFD, FD_CLOEXEC );
        fcntl( fd[1], F_SETFD, FD_CLOEXEC );
    }
    if (flags & O_NONBLOCK)
    {
        fcntl( fd[0], F_SETFL, fcntl( fd[0], F_GETFL ) | O_NONBLOCK );
        fcntl( fd[1], F_SETFL, fcntl( fd[1], F_GETFL ) | O_NONBLOCK );
    }
    return 0;
}
#define pipe2 madeira_pipe2
