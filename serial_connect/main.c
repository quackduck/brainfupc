#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <IOKit/serial/ioss.h>

speed_t baud = 2125000;

static struct termios orig_tio;

void restore_terminal(void) { // doesnt actually run on signals..
    tcsetattr(STDIN_FILENO, TCSANOW, &orig_tio);
    fprintf(stderr, "Restored terminal settings.\n");
}

void stdout_write(const char* buf, ssize_t n) {
    for (ssize_t i = 0; i < n; i++) {
        if (buf[i] == '\r' || buf[i] == '\n') {
            write(STDOUT_FILENO, "\r\n", 2);
            continue;
        }
        if (buf[i] < 32 || buf[i] > 126) {
            char hex[5];
            snprintf(hex, sizeof(hex), "[%02X]", (unsigned char) buf[i]);
            write(STDOUT_FILENO, hex, 4);
            continue;
        }
        write(STDOUT_FILENO, &buf[i], 1);
    }
}

void device_write(int fd, const char* buf, ssize_t n) {
    for (ssize_t i = 0; i < n; i++) {
        usleep(1000); // 1 ms delay. picocom doesnt have this feature.
        if (buf[i] == '\r') {
            write(fd, "\n", 1);
            continue;
        }
        write(fd, &buf[i], 1);
    }
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s /dev/cu.<smth>\n", argv[0]);
        return 1;
    }

    int fd;
    { // setup device.
        fd = open(argv[1], O_RDWR | O_NOCTTY | O_NONBLOCK);
        if (fd < 0) {
            perror("open");
            return 1;
        }
        fcntl(fd, F_SETFL, 0);

        struct termios tio;
        tcgetattr(fd, &tio);
        cfmakeraw(&tio);
        tio.c_cflag |= CLOCAL;
        cfsetspeed(&tio, B9600);
        tcsetattr(fd, TCSANOW, &tio);

        if (ioctl(fd, IOSSIOSPEED, &baud) < 0) {
            perror("ioctl IOSSIOSPEED");
            return 1;
        }
    }

    { // setup stdin (raw mode)
        tcgetattr(STDIN_FILENO, &orig_tio);
        atexit(restore_terminal);
        struct termios raw = orig_tio;
        cfmakeraw(&raw);
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    }

    char buf[1024];
    fd_set rfds; // read fds
    int maxfd = fd > STDIN_FILENO ? fd : STDIN_FILENO;
    
    FD_ZERO(&rfds);
    FD_SET(fd, &rfds);
    FD_SET(STDIN_FILENO, &rfds);

    while (1) {
        fd_set copy = rfds;
        // check up to maxfd inclusive, use read set, no write or except sets, no timeout.
        if (select(maxfd + 1, &copy, NULL, NULL, NULL) < 0) break;

        if (FD_ISSET(fd, &copy)) {
            ssize_t n = read(fd, buf, sizeof(buf));
            if (n <= 0) break;
            stdout_write(buf, n);
        }

        if (FD_ISSET(STDIN_FILENO, &copy)) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n <= 0) break;
            stdout_write(buf, n); // echo.
            device_write(fd, buf, n);
        }
    }

    close(fd);
    return 0;
}