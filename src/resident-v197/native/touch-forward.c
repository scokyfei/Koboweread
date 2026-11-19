// SPDX-License-Identifier: GPL-3.0-or-later
#define _GNU_SOURCE
#include "../runtime-prototype/close-inherited-fds.h"
#include <linux/input.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#define READER_EXE "/mnt/onboard/.adds/koreader/luajit"
#include "reader-identity.h"
#include "../launcher-prototype/handoff-prototype/reading-lease.h"
#include "../libra2-prototype/device-profile.h"
#include "exit-hold.h"
#include "edge-light.h"
#include "rotate-follow.h"
#include "forma-buttons.h"
#include "../libra2-prototype/device-profile.h"
static volatile sig_atomic_t stopped;
/* Libra Colour (N428): the Elan panel's X axis runs the other way. KOReader's
 * Kobo_monza has touch_mirrored_y (screen y = 1679 - raw X) where the Libra 2
 * (Kobo_io) has none. Raw X is mirrored before kobo_touch_map. */
static int touch_mirror_y;
static int raw_x_mirror(int raw){return raw>=KOBO_TOUCH_MAX_X?0:KOBO_TOUCH_MAX_X-1-raw;}
static int model_is(const char *prefix){
 char b[16]={0};FILE *f=fopen("/mnt/onboard/.kobo/version","r");if(!f)return 0;
 int ok=fgets(b,sizeof(b),f)&&!strncmp(b,prefix,strlen(prefix));fclose(f);return ok;
}
static unsigned skipped_events;
static unsigned rejected_events;
static int request_control(const char *path,const char *reason){
 char temporary[256];if(snprintf(temporary,sizeof(temporary),"%s.%ld",path,(long)getpid())>=(int)sizeof(temporary))return -1;
 int fd=open(temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0400);if(fd<0)return -1;
 size_t size=strlen(reason);int ok=write(fd,reason,size)==(ssize_t)size;if(close(fd)<0)ok=0;
 if(ok && link(temporary,path)<0){struct stat st;ok=errno==EEXIST && lstat(path,&st)==0 && S_ISREG(st.st_mode) && st.st_uid==0 && (st.st_mode&0777)==0400;}
 unlink(temporary);return ok?0:-1;
}
static void stop(int sig){(void)sig;stopped=1;}
/* Latency test hook (resident): a root-owned regular file test-page-key
 * (next) or test-page-key-previous acts as one page-key press through the
 * same packet and ack path. Returns the packet action, or 0. */
static int test_page_key(void){
 static const char *const paths[2]={"/tmp/kobo-android-runtime/lab/test-page-key","/tmp/kobo-android-runtime/lab/test-page-key-previous"};
 for(int i=0;i<2;i++){struct stat st;if(lstat(paths[i],&st)||!S_ISREG(st.st_mode)||st.st_uid!=0)continue;unlink(paths[i]);return i?4:5;}
 return 0;
}
/* Tap test hook (resident): a root-owned regular file test-tap holding "X Y"
 * (Android screen pixels) becomes one down/up tap through the gesture path. */
static int test_tap(int *x,int *y){
 static const char path[]="/tmp/kobo-android-runtime/lab/test-tap";
 struct stat st;if(lstat(path,&st)||!S_ISREG(st.st_mode)||st.st_uid!=0||st.st_size>32)return 0;
 FILE *f=fopen(path,"r");int ok=f&&fscanf(f,"%d %d",x,y)==2;if(f)fclose(f);unlink(path);
 return ok&&*x>=0&&*y>=0&&*x<1264&&*y<1680;
}
/* Swipe test hook (resident): a root-owned regular file test-swipe holding
 * "X0 Y0 X1 Y1 MS" (Android screen pixels) becomes one contact moving in a
 * straight line over MS milliseconds, fed through the same event path as the
 * touchscreen (a frame every 20 ms, then a release). */
struct test_swipe { int active,x0,y0,x1,y1,steps,step;double next; };
static int test_swipe_start(struct test_swipe *s){
 static const char path[]="/tmp/kobo-android-runtime/lab/test-swipe";
 struct stat st;if(lstat(path,&st)||!S_ISREG(st.st_mode)||st.st_uid!=0||st.st_size>64)return 0;
 FILE *f=fopen(path,"r");int ms=0,ok=f&&fscanf(f,"%d %d %d %d %d",&s->x0,&s->y0,&s->x1,&s->y1,&ms)==5;if(f)fclose(f);unlink(path);
 ok=ok&&s->x0>=0&&s->y0>=0&&s->x1>=0&&s->y1>=0&&s->x0<KOBO_FB_WIDTH&&s->x1<KOBO_FB_WIDTH&&s->y0<KOBO_FB_HEIGHT&&s->y1<KOBO_FB_HEIGHT&&ms>=0&&ms<=10000;
 if(!ok)return 0;
 s->active=1;s->step=0;s->steps=ms/20+1;s->next=0;return 1;
}
/* Raw Elan events for one step (inverse of kobo_touch_map); returns the count. */
static int test_swipe_frame(struct test_swipe *s,struct input_event *ev){
 int n=0;
#define TS_EV(t,c,v) do{memset(&ev[n],0,sizeof(ev[n]));ev[n].type=(t);ev[n].code=(c);ev[n].value=(v);n++;}while(0)
 if(s->step>s->steps){TS_EV(EV_ABS,ABS_MT_SLOT,0);TS_EV(EV_ABS,ABS_MT_TRACKING_ID,-1);TS_EV(EV_SYN,SYN_REPORT,0);s->active=0;return n;}
 int x=s->x0+(s->x1-s->x0)*s->step/s->steps,y=s->y0+(s->y1-s->y0)*s->step/s->steps;
 TS_EV(EV_ABS,ABS_MT_SLOT,0);
 if(!s->step)TS_EV(EV_ABS,ABS_MT_TRACKING_ID,4242);
 TS_EV(EV_ABS,ABS_MT_POSITION_X,touch_mirror_y?raw_x_mirror(y*KOBO_FB_SCALE):y*KOBO_FB_SCALE);TS_EV(EV_ABS,ABS_MT_POSITION_Y,x*KOBO_FB_SCALE);TS_EV(EV_SYN,SYN_REPORT,0);
#undef TS_EV
 s->step++;return n;
}
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int send_event(int fd,int action,int x,int y,unsigned *sequence){
 uint32_t words[]={htonl(0x4b545031),htonl(action),htonl(x),htonl(y),htonl(++*sequence)},reply;
 if(action==1 && access("/mnt/onboard/.adds/kobo-android-lab/fast-v197/ime-trace-enabled",F_OK)==0)
  printf("IME_LATENCY host_up_ms=%.0f seq=%u\n",now()*1000,*sequence);
 size_t offset=0;
 while(offset<sizeof(words)){
  ssize_t n=send(fd,(char*)words+offset,sizeof(words)-offset,MSG_NOSIGNAL);
  if(n<0 && errno==EINTR)continue;if(n<=0){fprintf(stderr,"HOST_TOUCH_SEND_FAILED action=%d serial=%u errno=%d closed=%d\n",action,*sequence,n<0?errno:0,n==0);return -1;}offset+=(size_t)n;
 }
 offset=0;while(offset<sizeof(reply)){
  ssize_t n=recv(fd,(char*)&reply+offset,sizeof(reply)-offset,0);
  if(n<0 && errno==EINTR)continue;if(n<=0){fprintf(stderr,"HOST_TOUCH_ACK_FAILED action=%d serial=%u errno=%d closed=%d\n",action,*sequence,n<0?errno:0,n==0);return -1;}offset+=(size_t)n;
 }
 if(ntohl(reply)==2){skipped_events++;return 2;}
 if(ntohl(reply)==3){rejected_events++;return 3;}
 if(ntohl(reply)!=1){fprintf(stderr,"HOST_TOUCH_ACK_REJECTED action=%d serial=%u\n",action,*sequence);return -1;}return 0;
}
/* Input devices by name, not by number: a firmware may add devices (4.38
 * adds uhid/hidraw, e.g. for Bluetooth page turners) and shift the numbers.
 * The callers still check the name, axes and keys of what this returns. */
/* The input helper acknowledges page keys only in the reader window. */
static void page_wipe_request(int previous){
 char request[64];
 snprintf(request,sizeof(request),"%c %.6f\n",previous?'p':'n',now());
 request_control("/tmp/kobo-android-runtime/lab/resident-page-wipe",request);
}
static int open_input_named(const char *want,int flags){
 for(int i=0;i<32;i++){
  char path[32],name[128]={0};snprintf(path,sizeof(path),"/dev/input/event%d",i);
  int fd=open(path,flags|O_CLOEXEC|O_NOFOLLOW);if(fd<0)continue;
  if(ioctl(fd,EVIOCGNAME(sizeof(name)-1),name)>=0 && !strcmp(name,want)){printf("HOST_INPUT_DEVICE name=%s path=%s\n",want,path);return fd;}
  close(fd);
 }
 return -1;
}
int main(int argc,char **argv){
 if((argc!=2 && argc!=3) || geteuid()!=0)return 2;
 // --resident: one foreground period of the resident launcher (up to 12 h).
 int resident=argc==3&&!strcmp(argv[2],"--resident");
 int long_session=resident||(argc==3&&!strcmp(argv[2],"--interactive-long"));
 int interactive=long_session || (argc==3&&!strcmp(argv[2],"--interactive"));
 int one_gesture=argc==3&&!strcmp(argv[2],"--one-gesture");if(argc==3&&!interactive&&!one_gesture)return 2;
 char *end;long seconds=strtol(argv[1],&end,10);if(*end || seconds<5 || seconds>(resident?43200:(long_session?1800:180)))return 2;
 if(close_inherited_fds()<0)return 3;setvbuf(stdout,NULL,_IOLBF,0);
 touch_mirror_y=model_is("N428");
 int independent=access(HANDOFF_LEASE,F_OK)==0;
 struct reader readers[2]={{0}};
 if((independent&&!reading_valid())||(!independent&&find_readers(readers,'T')<0)){
  fprintf(stderr,"HOST_TOUCH_OWNER_REJECTED independent=%d\n",independent);return 4;
 }
 printf("HOST_TOUCH_HANDOFF independent=%d\n",independent);
 int fd=open_input_named(KOBO_TOUCH_NAME,O_RDONLY|O_NONBLOCK);if(fd<0)return 5;
 char name[128]={0};struct input_absinfo ax,ay;
 if(ioctl(fd,EVIOCGNAME(sizeof(name)),name)<0 || strcmp(name,KOBO_TOUCH_NAME) ||
    ioctl(fd,EVIOCGABS(ABS_MT_POSITION_X),&ax)<0 || ioctl(fd,EVIOCGABS(ABS_MT_POSITION_Y),&ay)<0 ||
    ax.minimum!=0 || ax.maximum!=KOBO_TOUCH_MAX_X || ay.minimum!=0 || ay.maximum!=KOBO_TOUCH_MAX_Y)return 6;
 const char *path="/tmp/kobo-android-runtime/dev/socket/kobo_touch_probe";struct stat st;
 if(lstat(path,&st)<0 || !S_ISSOCK(st.st_mode) || st.st_uid!=0 || (st.st_mode&0777)!=0600)return 7;
 int sock=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0);if(sock<0)return 8;
 struct sockaddr_un address={.sun_family=AF_UNIX};strcpy(address.sun_path,path);
 if(connect(sock,(struct sockaddr*)&address,sizeof(address))<0)return 9;
 struct ucred peer;socklen_t peer_size=sizeof(peer);
 if(getsockopt(sock,SOL_SOCKET,SO_PEERCRED,&peer,&peer_size)<0 || peer.uid!=0)return 10;
 struct timeval timeout={interactive?15:2,0};setsockopt(sock,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(sock,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
 signal(SIGINT,stop);signal(SIGTERM,stop);signal(SIGHUP,stop);signal(SIGPIPE,SIG_IGN);
 if(ioctl(fd,EVIOCGRAB,1)<0)return 11;
 unsigned long keys[(KEY_MAX+8*sizeof(long))/(8*sizeof(long))];memset(keys,0,sizeof(keys));
 if(ioctl(fd,EVIOCGKEY(sizeof(keys)),keys)<0){ioctl(fd,EVIOCGRAB,0);return 12;}
 int button=(keys[BTN_TOUCH/(8*sizeof(long))]>>(BTN_TOUCH%(8*sizeof(long))))&1;
 unsigned raw_events=0,blocked_frames=0,multi_frames=0;int initial_contact=button;
 int blocked=button,down=0,current=0,xraw=ax.value,yraw=ay.value,lastx=0,lasty=0,rc=0;unsigned mask=0,sequence=0,gestures=0;
#ifdef KOBO_TARGET_LIBRA2
 int slot=0;unsigned active_slots=0;
#endif
 int coords[16][2];for(int i=0;i<16;i++){coords[i][0]=xraw;coords[i][1]=yraw;}
#ifdef KOBO_TARGET_LIBRA2
 // Kernel may omit an unchanged slot selector or coordinate. Seed all slots,
 // and suppress contacts that were already held before taking ownership.
 struct input_absinfo selected;int tracking[11]={ABS_MT_TRACKING_ID};
 int slot_x[11]={ABS_MT_POSITION_X},slot_y[11]={ABS_MT_POSITION_Y};
 if(ioctl(fd,EVIOCGABS(ABS_MT_SLOT),&selected)<0 || selected.value<0 || selected.value>=10 ||
    ioctl(fd,EVIOCGMTSLOTS(sizeof(tracking)),tracking)<0 || ioctl(fd,EVIOCGMTSLOTS(sizeof(slot_x)),slot_x)<0 || ioctl(fd,EVIOCGMTSLOTS(sizeof(slot_y)),slot_y)<0){ioctl(fd,EVIOCGRAB,0);return 12;}
 slot=selected.value;
 for(int i=0;i<10;i++){coords[i][0]=slot_x[i+1];coords[i][1]=slot_y[i+1];if(tracking[i+1]>=0)active_slots|=1u<<i;}
 if(active_slots){blocked=1;initial_contact=1;}
#endif
 // Declared before any goto cleanup: the cleanup path reads them.
 struct edge_light edge={0};struct test_swipe swipe={0};struct rotate_follow rot;rotate_init(&rot,resident);
 int key_fd=-1,pwr_fd=-1;struct forma_buttons physical_keys={0};unsigned page_keys=0,key_refreshes=0,key_exits=0,exit_holds=0;int key_refreshed=0,power_home=0;
 if(interactive){
  key_fd=open_input_named("gpio-keys",O_RDONLY|O_NONBLOCK);
  char key_name[128]={0};unsigned long key_bits[(KEY_MAX+8*sizeof(long))/(8*sizeof(long))]={0};
  if(key_fd<0 || ioctl(key_fd,EVIOCGNAME(sizeof(key_name)),key_name)<0 || strcmp(key_name,"gpio-keys") || ioctl(key_fd,EVIOCGBIT(EV_KEY,sizeof(key_bits)),key_bits)<0){rc=24;goto cleanup;}
  const int required[]={193,194,116};
#define KEY_BIT(bits,c) (((bits)[(c)/(8*sizeof(long))]>>((c)%(8*sizeof(long))))&1)
  unsigned long pwr_bits[(KEY_MAX+8*sizeof(long))/(8*sizeof(long))]={0};
  if(!KEY_BIT(key_bits,116)){
   // Libra Colour (MTK): the power key is its own input device, not part of gpio-keys.
   pwr_fd=open_input_named("bd71828-pwrkey",O_RDONLY|O_NONBLOCK);
   if(pwr_fd<0 || ioctl(pwr_fd,EVIOCGBIT(EV_KEY,sizeof(pwr_bits)),pwr_bits)<0 || !KEY_BIT(pwr_bits,116)){rc=24;goto cleanup;}
  }
  for(unsigned k=0;k<2;k++)if(!KEY_BIT(key_bits,required[k])){rc=24;goto cleanup;}
  if(ioctl(key_fd,EVIOCGRAB,1)<0 || ioctl(key_fd,EVIOCGKEY(sizeof(key_bits)),key_bits)<0){rc=24;goto cleanup;}
  if(pwr_fd>=0 && (ioctl(pwr_fd,EVIOCGRAB,1)<0 || ioctl(pwr_fd,EVIOCGKEY(sizeof(pwr_bits)),pwr_bits)<0)){rc=24;goto cleanup;}
  if(pwr_fd>=0 && KEY_BIT(pwr_bits,116))key_bits[116/(8*sizeof(long))]|=1ul<<(116%(8*sizeof(long)));
  unsigned held=0;for(unsigned k=0;k<3;k++)if(KEY_BIT(key_bits,required[k]))held|=1u<<k;
  forma_buttons_init(&physical_keys,held);puts("HOST_FORMA_BUTTONS_READY upper=next lower=previous next_hold_1s=refresh previous_release_3s=screenshot chord_hold_2s=home power_release=exit");
 }
 const char *wipe_setting=getenv("KOBO_PAGE_WIPE");
 int page_wipe=resident && wipe_setting && !strcmp(wipe_setting,"1");
 const char *idle_seconds=getenv("KOBO_IDLE_SUSPEND_SECONDS");
 unsigned idle_timeout=0;
 if(resident && idle_seconds){
  char *end;
  long value=strtol(idle_seconds,&end,10);
  if(!*end && (value==60 || value==180 || value==300 || value==600 || value==900 || value==1800))
   idle_timeout=(unsigned)value;
 }
 double last_input=now(),next_power_check=last_input;
 double deadline=last_input+seconds;struct exit_hold hold={0};
 edge_init(&edge,resident);
 if(resident)printf("HOST_ROTATE_READY follow=%s\n",rot.enabled?"upright,upside-down":"off");
 if(resident)printf("HOST_EDGE_LIGHT_READY brightness=%s warmth=%s\n",edge.path[0]?edge.path[0]:"off",edge.path[1]?edge.path[1]:"off");
#ifdef KOBO_TARGET_LIBRA2
 printf("HOST_TOUCH_FORWARD_READY protocol=elan-type-b single-finger=1 axis-transform=swap-profile-scale-clamp%s\n",touch_mirror_y?"-mirror-y":"");
#else
 puts("HOST_TOUCH_FORWARD_READY protocol=forma-snow single-finger=1 axis-transform=mirror-y-swap-divide-two");
#endif
 while(!stopped && now()<deadline){
  if(independent&&!reading_valid()){fprintf(stderr,"HOST_TOUCH_HANDOFF_LEASE_LOST\n");rc=13;goto cleanup;}
  for(int i=0;!independent&&i<2;i++){struct reader r={0};if(identity(readers[i].pid,&r,0)<0 || r.started!=readers[i].started || r.state!='T'){rc=13;goto cleanup;}}
  if(edge_tick(&edge,now())){
   // Still edge contact held long enough: hand it to Android as it began.
   if(send_event(sock,0,edge.x0,edge.y0,&sequence)<0){rc=20;goto cleanup;}
   puts("HOST_TOUCH_GESTURE_DOWN");down=1;lastx=edge.x0;lasty=edge.y0;
  }
  struct input_event events[64];ssize_t n;
  if(swipe.active){
   if(now()<swipe.next){struct timespec step={0,5000000};nanosleep(&step,NULL);continue;}
   swipe.next=now()+0.02;n=(ssize_t)(test_swipe_frame(&swipe,events)*sizeof(*events));
   if(!swipe.active)printf("HOST_TEST_SWIPE_DONE at=%.3f\n",now());
   goto process;
  }
  unsigned next_bit=rot.applied==2?2u:1u;
  if(resident && physical_keys.pressed==next_bit && !physical_keys.blocked &&
     !physical_keys.chord && !key_refreshed &&
     now()-physical_keys.single_began[next_bit==1?0:1]>=1.0){
   if(request_control("/tmp/kobo-android-runtime/lab/interactive-refresh-request","refresh\n")<0){rc=26;goto cleanup;}
   key_refreshed=1;key_refreshes++;puts("HOST_FORMA_KEY_REFRESH_REQUESTED");
  }
  struct pollfd pollers[3]={{.fd=fd,.events=POLLIN},{.fd=key_fd,.events=POLLIN},{.fd=pwr_fd,.events=POLLIN}};int ready=poll(pollers,3,100);
  if(ready<0){if(errno==EINTR)continue;rc=14;break;}if(!ready){
   double tick=now();
   if(idle_timeout && tick-last_input>=idle_timeout && tick>=next_power_check &&
      !button && !down && !hold.state && !edge.state && !physical_keys.pressed){
    next_power_check=tick+5;
    char status[32];
    FILE *battery=fopen("/sys/class/power_supply/bd71827_bat/status","r");
    if(!battery)battery=fopen("/sys/class/power_supply/mc13892_bat/status","r");
    if(battery){
     int discharging=fgets(status,sizeof(status),battery) && !strcmp(status,"Discharging\n");
     fclose(battery);
     if(discharging){
      if(request_control("/tmp/kobo-android-runtime/lab/interactive-session-finish","reason=idle-suspend\n")<0){rc=23;goto cleanup;}
      puts("HOST_IDLE_SUSPEND_REQUESTED");goto cleanup;
     }
    }
   }
   exit_hold_tick(&hold,tick);
   int report;
   if(resident && (report=test_rotate())>=0){printf("HOST_TEST_ROTATE value=0x%x\n",report);rotate_report(&rot,report,now());}
   if(resident && !button && !down && !hold.state && !edge.state && rotate_due(&rot,now())){
    double sent=now();int result=send_event(sock,7,rot.wanted,0,&sequence);if(result<0){rc=30;goto cleanup;}
    rotate_result(&rot,result==0,now());
    printf("HOST_ROTATE to=%d applied=%d ack=%d sent=%.3f ack_at=%.3f\n",rot.wanted,rot.applied,result,sent,now());
   }
   int tap_x,tap_y;
   if(resident && !button && !down && !hold.state && test_tap(&tap_x,&tap_y)){
    double sent=now();int r0=send_event(sock,0,tap_x,tap_y,&sequence);if(r0<0){rc=20;goto cleanup;}
    struct timespec press={0,80000000};nanosleep(&press,NULL);
    int r1=send_event(sock,r0==0?1:3,tap_x,tap_y,&sequence);if(r1<0){rc=18;goto cleanup;}
    printf("HOST_TEST_TAP x=%d y=%d sent=%.3f ack=%.3f down_result=%d up_result=%d\n",tap_x,tap_y,sent,now(),r0,r1);
   }
   if(resident && !button && !down && !hold.state && !edge.state && test_swipe_start(&swipe)){
    printf("HOST_TEST_SWIPE x0=%d y0=%d x1=%d y1=%d steps=%d at=%.3f\n",swipe.x0,swipe.y0,swipe.x1,swipe.y1,swipe.steps,now());continue;
   }
   int test_action;
   if(resident && !button && !down && !hold.state && (test_action=test_page_key())){
    double sent=now();int result=send_event(sock,test_action,0,0,&sequence);if(result<0){rc=27;goto cleanup;}
    if(page_wipe && result==0)page_wipe_request(test_action==4);
    page_keys++;printf("HOST_TEST_PAGE_KEY direction=%s sent=%.3f ack=%.3f ack_result=%d\n",test_action==4?"previous":"next",sent,now(),result);
   }
   continue;
  }
  for(int kp=1;kp<=2;kp++){
  int kfd=kp==1?key_fd:pwr_fd;
  if(kfd>=0 && (pollers[kp].revents&(POLLERR|POLLHUP|POLLNVAL))){rc=25;goto cleanup;}
  if(kfd>=0 && (pollers[kp].revents&POLLIN)){
   struct input_event key_events[32];ssize_t count=read(kfd,key_events,sizeof(key_events));
   if(count<=0 || count%sizeof(*key_events)){rc=25;goto cleanup;}
   for(size_t k=0;k<(size_t)count/sizeof(*key_events);k++){
    struct input_event *key=&key_events[k];
    if(key->type==EV_SYN && key->code==SYN_DROPPED){rc=25;goto cleanup;}
    if(key->type==EV_MSC && key->code==MSC_RAW){printf("HOST_GYRO value=0x%x\n",key->value);rotate_report(&rot,key->value,now());continue;}
    if(key->type!=EV_KEY)continue;
    last_input=now();
    if(!physical_keys.pressed && key->value==1)key_refreshed=0;
    // Claim only a fresh power press preceded by the current next-page key.
    if(resident && key->code==116 && key->value==1 &&
       physical_keys.pressed==next_bit && !physical_keys.blocked && !physical_keys.chord)
     power_home=1;
    int power_exit=physical_keys.power_armed;
    int action=forma_button_event(&physical_keys,key->code,key->value,now());
    if(power_home && key->code==116 && key->value==0 && power_exit){
     power_home=0;
     // Keep the remaining page key blocked until release, but consume power exit.
     physical_keys.chord_action=FORMA_NONE;
     if(button || down || hold.state){puts("HOST_RESIDENT_HOME_SKIPPED_TOUCH_ACTIVE");continue;}
     int result=send_event(sock,6,0,0,&sequence);if(result<0){rc=29;goto cleanup;}
     printf("HOST_RESIDENT_POWER_HOME_RELEASED ack=%d\n",result);continue;
    }
    if(resident && action==FORMA_REFRESH){
     int previous=(key->code==194)!=(rot.applied==2);
     double held=now()-physical_keys.single_began[key->code==193?0:1];
     if(previous && held>=3.0){
      if(request_control("/tmp/kobo-android-runtime/lab/interactive-screenshot-request","screenshot\n")<0)
       puts("HOST_FORMA_KEY_SCREENSHOT_REQUEST_FAILED");
      else puts("HOST_FORMA_KEY_SCREENSHOT_REQUESTED");
      continue;
     }
     if(previous)action=key->code==194?FORMA_PREVIOUS:FORMA_NEXT;
     else if(held>=5.0){
      if(button || down || hold.state){puts("HOST_RESIDENT_HOME_SKIPPED_TOUCH_ACTIVE");continue;}
      int result=send_event(sock,6,0,0,&sequence);if(result<0){rc=29;goto cleanup;}
      printf("HOST_RESIDENT_KEY_HOME_RELEASED ack=%d\n",result);continue;
     }else if(key_refreshed)continue;
    }
    if(resident && action==FORMA_EXIT && !power_exit){
     if(button || down || hold.state){puts("HOST_RESIDENT_HOME_SKIPPED_TOUCH_ACTIVE");continue;}
     int result=send_event(sock,6,0,0,&sequence);if(result<0){rc=29;goto cleanup;}
     printf("HOST_RESIDENT_CHORD_HOME_RELEASED ack=%d\n",result);continue;
    }
    if(action==FORMA_EXIT){if(request_control("/tmp/kobo-android-runtime/lab/interactive-session-finish","reason=physical-keys\n")<0){rc=23;goto cleanup;}key_exits++;puts("HOST_FORMA_KEY_EXIT_RELEASED");goto cleanup;}
    if(action==FORMA_REFRESH){if(request_control("/tmp/kobo-android-runtime/lab/interactive-refresh-request","refresh\n")<0){rc=26;goto cleanup;}key_refreshes++;puts("HOST_FORMA_KEY_REFRESH_REQUESTED");}
    if(action==FORMA_PREVIOUS || action==FORMA_NEXT){
     if(button || down || hold.state || (pollers[0].revents&POLLIN)){puts("HOST_FORMA_KEY_SKIPPED_TOUCH_ACTIVE");continue;}
     // Upside down the keys swap places, so they swap meanings (KOReader's rotation_map).
     int previous=(action==FORMA_PREVIOUS)!=(rot.applied==2);
     double sent=now();int result=send_event(sock,previous?4:5,0,0,&sequence);
     if(result<0){rc=27;goto cleanup;}
     if(page_wipe && result==0)page_wipe_request(previous);
     page_keys++;printf("HOST_FORMA_PAGE_KEY direction=%s ack=%d sent=%.3f ack_at=%.3f\n",previous?"previous":"next",result,sent,now());
    }
   }
  }
  }
  if(!(pollers[0].revents&POLLIN))continue;
  n=read(fd,events,sizeof(events));
  if(n<0){if(errno==EINTR || errno==EAGAIN)continue;rc=15;break;}
  if(n<=0 || n%sizeof(struct input_event)){rc=16;break;}
  last_input=now();
 process:
  for(size_t i=0;i<(size_t)n/sizeof(*events);i++){
   struct input_event *ev=&events[i];raw_events++;
#ifdef KOBO_TARGET_LIBRA2
   if(!interactive && raw_events<=256 && ((ev->type==EV_ABS && (ev->code==ABS_MT_SLOT || ev->code==ABS_MT_TRACKING_ID || ev->code==ABS_MT_PRESSURE)) || (ev->type==EV_KEY && ev->code==BTN_TOUCH)))
    printf("ELAN_CONTROL_EVENT type=%u code=%u value=%d slot=%d active=%x down=%d blocked=%d\n",ev->type,ev->code,ev->value,slot,active_slots,down,blocked);
#endif
   if(ev->type==EV_KEY && ev->code==BTN_TOUCH)button=!!ev->value;
   else if(ev->type==EV_ABS){
#ifdef KOBO_TARGET_LIBRA2
    // Elan uses protocol B: tracking IDs are identities, never array indexes.
    if(ev->code==ABS_MT_SLOT){if(ev->value<0 || ev->value>=10){rc=28;goto cleanup;}slot=ev->value;}
    else if(ev->code==ABS_MT_TRACKING_ID){
     if(ev->value==-1)active_slots&=~(1u<<slot);
     else if(ev->value>=0 && ev->value<=65535){
      // A reported tracking ID does not itself mean an additional finger.
      // Slot occupancy is authoritative; reject overlapping occupied slots.
      active_slots|=1u<<slot;
     }
     else {rc=28;goto cleanup;}
     if(active_slots&(active_slots-1))blocked=1;
    }else if(ev->code==ABS_MT_POSITION_X){coords[slot][0]=ev->value;}
    else if(ev->code==ABS_MT_POSITION_Y){coords[slot][1]=ev->value;}
#else
    if(ev->code==ABS_MT_SLOT){blocked=1;}
    else if(ev->code==ABS_MT_TRACKING_ID){
     if(ev->value<0 || ev->value>15){blocked=1;continue;}
     current=ev->value;mask|=1u<<current;
     if(mask&(mask-1))blocked=1;
    }else if(ev->code==ABS_MT_POSITION_X){coords[current][0]=ev->value;}
    else if(ev->code==ABS_MT_POSITION_Y){coords[current][1]=ev->value;}
#endif
   }else if(ev->type==EV_SYN && ev->code==SYN_DROPPED){
    // Stop on lost kernel events: do not invent a gesture state.
    rc=17;goto cleanup;
   }else if(ev->type==EV_SYN && ev->code==SYN_REPORT){
#ifdef KOBO_TARGET_LIBRA2
    mask=active_slots;button=active_slots!=0;
    if(active_slots){for(current=0;current<10 && !(active_slots&(1u<<current));current++);}
#endif
    if(blocked)exit_hold_cancel(&hold);
    if(!button){
     if(edge.state && edge_end(&edge,now())==EDGE_FLUSH){
      // Tap or short contact on an edge: replay it now that it is over.
      if(send_event(sock,0,edge.x0,edge.y0,&sequence)<0){rc=20;goto cleanup;}
      if((edge.x!=edge.x0 || edge.y!=edge.y0) && send_event(sock,2,edge.x,edge.y,&sequence)<0){rc=20;goto cleanup;}
      if(send_event(sock,1,edge.x,edge.y,&sequence)<0){rc=18;goto cleanup;}
      gestures++;puts("HOST_TOUCH_GESTURE_DOWN");puts("HOST_TOUCH_GESTURE_UP");
      down=0;blocked=0;mask=0;current=0;continue;
     }
     if(interactive){int held=exit_hold_release(&hold,now());
      if(held==HOLD_EXIT){if(request_control("/tmp/kobo-android-runtime/lab/interactive-session-finish","reason=corner-hold\n")<0){rc=23;goto cleanup;}exit_holds++;puts("HOST_EXIT_CORNER_HOLD_RELEASED");goto cleanup;}
      if(held==HOLD_FLUSH){if(send_event(sock,0,hold.x,hold.y,&sequence)<0){rc=20;goto cleanup;}down=1;lastx=hold.x;lasty=hold.y;}
     }
     if(down){if(send_event(sock,1,lastx,lasty,&sequence)<0){rc=18;goto cleanup;}gestures++;puts("HOST_TOUCH_GESTURE_UP");down=0;if(one_gesture)goto cleanup;}
     down=0;blocked=0;mask=0;current=0;continue;
    }
    if(blocked){exit_hold_cancel(&hold);if(edge.state==EDGE_PENDING)edge.state=EDGE_IDLE;else edge_end(&edge,now());blocked_frames++;if(mask&(mask-1))multi_frames++;if(down){if(send_event(sock,3,lastx,lasty,&sequence)<0){rc=19;goto cleanup;}down=0;}continue;}
    xraw=coords[current][0];yraw=coords[current][1];
    if(touch_mirror_y)xraw=raw_x_mirror(xraw);
    int x,y;if(kobo_touch_map(xraw,yraw,&x,&y)<0){blocked=1;exit_hold_cancel(&hold);continue;}
    rotate_point(&rot,&x,&y);
    if(resident && !down && !hold.state && !edge.state)edge_begin(&edge,x,y,KOBO_FB_WIDTH,60*KOBO_EXIT_HOLD_SCALE,rot.applied==2,now());
    if(edge.state){
     if(edge_move(&edge,x,y,now())==EDGE_BUFFER)continue;
     // Not a light gesture: replay from where it began, then carry on.
     if(send_event(sock,0,edge.x0,edge.y0,&sequence)<0){rc=20;goto cleanup;}
     puts("HOST_TOUCH_GESTURE_DOWN");down=1;lastx=edge.x0;lasty=edge.y0;
    }
    if(interactive && (!down || hold.state)){
     int held=exit_hold_contact(&hold,x,y,now());
     if(held==HOLD_BUFFER)continue;
     if(held==HOLD_FLUSH){if(send_event(sock,0,hold.x,hold.y,&sequence)<0){rc=20;goto cleanup;}down=1;lastx=hold.x;lasty=hold.y;}
    }
    if(!down || x!=lastx || y!=lasty){
     if(send_event(sock,down?2:0,x,y,&sequence)<0){rc=20;goto cleanup;}
     if(!down)puts("HOST_TOUCH_GESTURE_DOWN");
     down=1;lastx=x;lasty=y;
    }
   }
  }
 }
cleanup:
 if(down && send_event(sock,3,lastx,lasty,&sequence)<0)rc=21;
 if(ioctl(fd,EVIOCGRAB,0)<0)rc=22;
 if(key_fd>=0){ioctl(key_fd,EVIOCGRAB,0);close(key_fd);}
 if(pwr_fd>=0){ioctl(pwr_fd,EVIOCGRAB,0);close(pwr_fd);}
 if(edge.state==EDGE_ACTIVE)edge_end(&edge,now());
 if(resident)printf("HOST_ROTATE_CLOSED applied=%d reports=%u changes=%u failures=%u\n",rot.applied,rot.reports,rot.changes,rot.failures);
 if(resident)printf("HOST_EDGE_LIGHT_CLOSED gestures=%u writes=%u replayed=%u\n",edge.gestures,edge.writes,edge.flushes);
 printf("HOST_FORMA_BUTTONS_CLOSED page_keys=%u refresh_requests=%u exit_requests=%u\n",page_keys,key_refreshes,key_exits);
 close(fd);close(sock);
 printf("HOST_TOUCH_FORWARD_CLOSED gestures=%u events=%u result=%d raw_events=%u blocked_frames=%u multi_frames=%u initial_contact=%d skipped_events=%u rejected_events=%u exit_holds=%u\n",gestures,sequence,rc,raw_events,blocked_frames,multi_frames,initial_contact,skipped_events,rejected_events,exit_holds);return rc;
}
