/* hwprobe: read-only dump of the input devices and framebuffer geometry the
 * WeRead launcher depends on (touch ranges, key codes, fb format).
 * Build: arm-linux-gnueabi-gcc -static -O2 -o hwprobe hwprobe.c */
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BITS(n) (((n) + 8 * sizeof(long) - 1) / (8 * sizeof(long)))
static int test_bit(int b, const unsigned long *a) { return (a[b / (8 * sizeof(long))] >> (b % (8 * sizeof(long)))) & 1; }

int main(void) {
	for (int i = 0; i < 16; i++) {
		char path[32], name[128] = {0};
		snprintf(path, sizeof path, "/dev/input/event%d", i);
		int fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0) continue;
		ioctl(fd, EVIOCGNAME(sizeof name - 1), name);
		printf("%s name=\"%s\"\n", path, name);
		unsigned long ev[BITS(EV_MAX + 1)] = {0}, abs[BITS(ABS_MAX + 1)] = {0}, key[BITS(KEY_MAX + 1)] = {0}, msc[BITS(MSC_MAX + 1)] = {0};
		ioctl(fd, EVIOCGBIT(0, sizeof ev), ev);
		printf("  ev:");
		for (int b = 0; b <= EV_MAX; b++) if (test_bit(b, ev)) printf(" %d", b);
		printf("\n");
		if (test_bit(EV_ABS, ev)) {
			ioctl(fd, EVIOCGBIT(EV_ABS, sizeof abs), abs);
			for (int b = 0; b <= ABS_MAX; b++) if (test_bit(b, abs)) {
				struct input_absinfo a; ioctl(fd, EVIOCGABS(b), &a);
				printf("  abs 0x%02x min=%d max=%d res=%d\n", b, a.minimum, a.maximum, a.resolution);
			}
		}
		if (test_bit(EV_KEY, ev)) {
			ioctl(fd, EVIOCGBIT(EV_KEY, sizeof key), key);
			printf("  keys:");
			for (int b = 0; b <= KEY_MAX; b++) if (test_bit(b, key)) printf(" %d", b);
			printf("\n");
		}
		if (test_bit(EV_MSC, ev)) {
			ioctl(fd, EVIOCGBIT(EV_MSC, sizeof msc), msc);
			printf("  msc:");
			for (int b = 0; b <= MSC_MAX; b++) if (test_bit(b, msc)) printf(" %d", b);
			printf("\n");
		}
		struct input_id id; if (!ioctl(fd, EVIOCGID, &id)) printf("  id bus=%d vendor=0x%x product=0x%x\n", id.bustype, id.vendor, id.product);
		close(fd);
	}
	int fb = open("/dev/fb0", O_RDONLY);
	if (fb >= 0) {
		struct fb_var_screeninfo v; struct fb_fix_screeninfo f;
		if (!ioctl(fb, FBIOGET_VSCREENINFO, &v) && !ioctl(fb, FBIOGET_FSCREENINFO, &f))
			printf("fb id=\"%s\" xres=%u yres=%u vxres=%u vyres=%u bpp=%u gray=%u rotate=%u line=%u smem=%u pixclock=%u\n"
			       "   red=%u/%u green=%u/%u blue=%u/%u transp=%u/%u width_mm=%u height_mm=%u\n",
			       f.id, v.xres, v.yres, v.xres_virtual, v.yres_virtual, v.bits_per_pixel, v.grayscale, v.rotate,
			       f.line_length, f.smem_len, v.pixclock, v.red.offset, v.red.length, v.green.offset, v.green.length,
			       v.blue.offset, v.blue.length, v.transp.offset, v.transp.length, v.width, v.height);
		close(fb);
	}
	return 0;
}
