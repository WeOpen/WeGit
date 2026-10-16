#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    int history=0; for(int i=1;i<argc;i++) if(strcmp(argv[i],"rev-list")==0) history=1;
    const char *marker=getenv("WEGIT_HOLD_HISTORY_MARKER");
    if(history && marker) {
        int f=open(marker,O_WRONLY|O_CREAT|O_EXCL,0600);
        if(f>=0) {
            dprintf(f,"%d",getpid()); close(f);
            char *release=NULL; asprintf(&release,"%s-release",marker);
            for(int i=0;i<30000 && access(release,F_OK)!=0;i++) usleep(10000);
            free(release);
        }
    }
    argv[0]="/Applications/Xcode.app/Contents/Developer/usr/bin/git";
    execv(argv[0],argv); return 127;
}
