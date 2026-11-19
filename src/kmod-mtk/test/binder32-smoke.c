/* binder32-smoke: checks ashmem and a protocol-7 (32-bit) binder device,
 * including a real ping/pong transaction between two processes.
 * Usage: binder32-smoke /path/to/binder-node */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <linux/ioctl.h>

typedef uint32_t bsize_t; /* binder_size_t / binder_uintptr_t in 32-bit protocol */
struct binder_write_read { bsize_t write_size, write_consumed, write_buffer, read_size, read_consumed, read_buffer; };
struct binder_version { int32_t protocol_version; };
struct btd {
	union { uint32_t handle; bsize_t ptr; } target;
	bsize_t cookie; uint32_t code, flags; int32_t sender_pid; uint32_t sender_euid;
	bsize_t data_size, offsets_size;
	union { struct { bsize_t buffer, offsets; } ptr; uint8_t buf[8]; } data;
};
_Static_assert(sizeof(struct binder_write_read) == 24, "bwr");
_Static_assert(sizeof(struct btd) == 40, "btd");

#define BINDER_WRITE_READ      _IOWR('b', 1, struct binder_write_read)
#define BINDER_SET_MAX_THREADS _IOW('b', 5, uint32_t)
#define BINDER_SET_CONTEXT_MGR _IOW('b', 7, int32_t)
#define BINDER_THREAD_EXIT     _IOW('b', 8, int32_t)
#define BINDER_VERSION         _IOWR('b', 9, struct binder_version)
#define BC_TRANSACTION   _IOW('c', 0, struct btd)
#define BC_REPLY         _IOW('c', 1, struct btd)
#define BC_FREE_BUFFER   _IOW('c', 3, bsize_t)
#define BC_ENTER_LOOPER  _IO('c', 12)
#define BR_ERROR         _IOR('r', 0, int32_t)
#define BR_TRANSACTION   _IOR('r', 2, struct btd)
#define BR_REPLY         _IOR('r', 3, struct btd)
#define BR_DEAD_REPLY    _IO('r', 5)
#define BR_TRANSACTION_COMPLETE _IO('r', 6)
#define BR_NOOP          _IO('r', 12)
#define BR_SPAWN_LOOPER  _IO('r', 13)
#define BR_FAILED_REPLY  _IO('r', 17)

#define ASHMEM_SET_NAME _IOW(0x77, 1, char[256])
#define ASHMEM_SET_SIZE _IOW(0x77, 3, size_t)
#define ASHMEM_GET_SIZE _IO(0x77, 4)

static const char *who = "parent";
static void check(int ok, const char *msg) { if (!ok) { fprintf(stderr, "FAIL [%s]: ", who); perror(msg); exit(1); } }

static int open_binder(const char *path) {
	int fd = open(path, O_RDWR | O_CLOEXEC); check(fd >= 0, "open binder");
	void *m = mmap(NULL, 128 * 1024, PROT_READ, MAP_PRIVATE, fd, 0); check(m != MAP_FAILED, "binder mmap");
	return fd;
}
static void bwrite(int fd, void *buf, size_t len) {
	struct binder_write_read b = {0};
	b.write_size = len; b.write_buffer = (bsize_t)(uintptr_t)buf;
	check(ioctl(fd, BINDER_WRITE_READ, &b) == 0 && b.write_consumed == len, "binder write");
}
/* Read until a command of interest arrives; copies its btd into *out. */
static uint32_t bread_until(int fd, uint32_t want1, uint32_t want2, struct btd *out) {
	for (;;) {
		uint32_t rb[64]; struct binder_write_read b = {0};
		b.read_size = sizeof rb; b.read_buffer = (bsize_t)(uintptr_t)rb;
		check(ioctl(fd, BINDER_WRITE_READ, &b) == 0, "binder read");
		uint8_t *p = (uint8_t *)rb, *end = p + b.read_consumed;
		while (p < end) {
			uint32_t cmd; memcpy(&cmd, p, 4); p += 4;
			if (cmd == BR_TRANSACTION || cmd == BR_REPLY) { if (out) memcpy(out, p, sizeof *out); }
			if (cmd == BR_DEAD_REPLY || cmd == BR_FAILED_REPLY || cmd == BR_ERROR) {
				fprintf(stderr, "FAIL [%s]: binder returned error cmd 0x%x\n", who, cmd); exit(1);
			}
			p += _IOC_SIZE(cmd);
			if (cmd == want1 || cmd == want2) return cmd;
		}
	}
}

int main(int argc, char **argv) {
	const char *dev = argc > 1 ? argv[1] : "/dev/binder";

	/* --- ashmem (built into the Kobo kernel) --- */
	int fd = open("/dev/ashmem", O_RDWR); check(fd >= 0, "open ashmem");
	char name[256] = "kobo-android-smoke";
	check(ioctl(fd, ASHMEM_SET_NAME, name) == 0, "ashmem name");
	check(ioctl(fd, ASHMEM_SET_SIZE, 4096) == 0, "ashmem size");
	check(ioctl(fd, ASHMEM_GET_SIZE) == 4096, "ashmem get size");
	char *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); check(p != MAP_FAILED, "ashmem mmap");
	strcpy(p, "parent"); pid_t c = fork(); check(c >= 0, "fork");
	if (!c) { strcpy(p, "child-shared-ok"); _exit(0); }
	int st = 0; check(waitpid(c, &st, 0) == c && WIFEXITED(st) && !WEXITSTATUS(st), "wait child");
	check(strcmp(p, "child-shared-ok") == 0, "ashmem shared data"); munmap(p, 4096); close(fd);
	puts("PASS: ashmem name, size, mmap, cross-process shared writes");

	/* --- binder basics --- */
	fd = open_binder(dev);
	struct binder_version v = {0};
	check(ioctl(fd, BINDER_VERSION, &v) == 0, "binder version");
	printf("Binder protocol: %d\n", v.protocol_version);
	if (v.protocol_version != 7) { fprintf(stderr, "FAIL: expected protocol 7\n"); return 1; }
	uint32_t threads = 1; check(ioctl(fd, BINDER_SET_MAX_THREADS, &threads) == 0, "set max threads");
	struct binder_write_read empty = {0}; check(ioctl(fd, BINDER_WRITE_READ, &empty) == 0, "empty write/read");
	puts("PASS: binder protocol 7, mmap, thread configuration, empty ioctl");

	/* --- real transaction: parent = context manager, child = client --- */
	int32_t zero = 0; check(ioctl(fd, BINDER_SET_CONTEXT_MGR, &zero) == 0, "set context manager");
	int sync[2]; check(pipe(sync) == 0, "pipe");
	c = fork(); check(c >= 0, "fork client");
	if (!c) {
		who = "client"; close(fd); close(sync[1]); char go; check(read(sync[0], &go, 1) == 1, "sync");
		int cfd = open_binder(dev);
		static char ping[] = "ping";
		struct { uint32_t cmd; struct btd t; } __attribute__((packed)) w = { BC_TRANSACTION, {0} };
		w.t.target.handle = 0; w.t.code = 0x1234; w.t.data_size = sizeof ping;
		w.t.data.ptr.buffer = (bsize_t)(uintptr_t)ping;
		bwrite(cfd, &w, sizeof w);
		struct btd r; bread_until(cfd, BR_REPLY, BR_REPLY, &r);
		const char *rd = (const char *)(uintptr_t)r.data.ptr.buffer;
		if (r.data_size != 5 || strcmp(rd, "pong")) { fprintf(stderr, "FAIL [client]: bad reply\n"); _exit(1); }
		struct { uint32_t cmd; bsize_t buf; } __attribute__((packed)) fb = { BC_FREE_BUFFER, r.data.ptr.buffer };
		bwrite(cfd, &fb, sizeof fb);
		_exit(0);
	}
	close(sync[0]);
	uint32_t enter = BC_ENTER_LOOPER; bwrite(fd, &enter, sizeof enter);
	check(write(sync[1], "g", 1) == 1, "sync");
	struct btd t; bread_until(fd, BR_TRANSACTION, BR_TRANSACTION, &t);
	const char *td = (const char *)(uintptr_t)t.data.ptr.buffer;
	if (t.code != 0x1234 || t.data_size != 5 || strcmp(td, "ping")) { fprintf(stderr, "FAIL: bad transaction\n"); return 1; }
	printf("Received transaction code=0x%x data=\"%s\" from pid %d\n", t.code, td, t.sender_pid);
	static char pong[] = "pong";
	struct { uint32_t c1; bsize_t buf; uint32_t c2; struct btd r; } __attribute__((packed)) w = { BC_FREE_BUFFER, t.data.ptr.buffer, BC_REPLY, {0} };
	w.r.data_size = sizeof pong; w.r.data.ptr.buffer = (bsize_t)(uintptr_t)pong;
	bwrite(fd, &w, sizeof w);
	bread_until(fd, BR_TRANSACTION_COMPLETE, BR_TRANSACTION_COMPLETE, NULL);
	check(waitpid(c, &st, 0) == c, "wait client");
	if (!WIFEXITED(st) || WEXITSTATUS(st)) { fprintf(stderr, "FAIL: client exited with status %d\n", st); return 1; }
	puts("PASS: binder transaction ping -> pong between two processes");
	close(fd);

	/* --- epoll + BINDER_THREAD_EXIT + close: the sequence of CVE-2019-2215.
	 * In this (pre-4.14) driver an idle thread polls on proc->wait, so this
	 * checks that the POLLFREE/synchronize_rcu change does not break the
	 * normal path; the vulnerable case is a thread polled while it has
	 * thread work (thread->wait). --- */
	fd = open_binder(dev);
	int ep = epoll_create1(EPOLL_CLOEXEC); check(ep >= 0, "epoll_create");
	struct epoll_event ev = { .events = EPOLLIN };
	check(epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev) == 0, "epoll_ctl add");
	int32_t dummy = 0; check(ioctl(fd, BINDER_THREAD_EXIT, &dummy) == 0, "thread exit");
	struct epoll_event out; check(epoll_wait(ep, &out, 1, 0) >= 0, "epoll_wait after exit");
	close(ep); close(fd);
	puts("PASS: epoll + BINDER_THREAD_EXIT + close");
	return 0;
}
