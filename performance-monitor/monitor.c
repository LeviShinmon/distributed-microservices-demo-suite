#include <stdio.h>
#include <unistd.h>

void get_system_load() {
    long double a[4], b[4], load;
    FILE *fp;

    while(1) {
        fp = fopen("/proc/stat", "r");[cite: 1]
        fscanf(fp, "%*s %Lf %Lf %Lf %Lf", &a[0], &a[1], &a[2], &a[3]);
        fclose(fp);
        sleep(1);
        fp = fopen("/proc/stat", "r");
        fscanf(fp, "%*s %Lf %Lf %Lf %Lf", &b[0], &b[1], &b[2], &b[3]);
        fclose(fp);

        load = ((b[0]+b[1]+b[2]) - (a[0]+a[1]+a[2])) / ((b[0]+b[1]+b[2]+b[3]) - (a[0]+a[1]+a[2]+a[3]));
        printf("Current CPU Load: %.2Lf%%\n", load * 100);[cite: 1]
    }
}

int main() {
    get_system_load();
    return 0;
}
