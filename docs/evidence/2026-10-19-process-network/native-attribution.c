#include "CFtopSys.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { int32_t pid; uint64_t uid, received, sent; int matches, baseline_only; double peak_down, peak_up; } role;

int main(void) {
    ftop_process_network_sampler *sampler = ftop_process_network_create();
    if (!sampler) { puts("unavailable"); return 2; }
    ftop_process_network_counter *previous = calloc(16384, sizeof(*previous));
    ftop_process_network_counter *current = calloc(16384, sizeof(*current));
    if (!previous || !current) return 3;
    uint64_t old_generation = 0;
    double old_time = 0;
    int old_count = 0;
    usleep(4250000);
    int first = ftop_process_network_copy(sampler, previous, 16384, &old_generation, &old_time);
    if (first >= 0) old_count = first;
    puts("ready"); fflush(stdout);
    char command[128] = {0};
    size_t used = 0;
    while (used + 1 < sizeof(command)) {
        if (read(STDIN_FILENO, command + used, 1) != 1) return 4;
        if (command[used++] == '\n') break;
    }
    role roles[2] = {{0}, {0}};
    if (sscanf(command, "%d %d", &roles[0].pid, &roles[1].pid) != 2) return 5;
    for (int index = 0; index < 2; index++) roles[index].uid = ftop_process_unique_id(roles[index].pid);
    fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK);
    int completed = 0;
    double started = ftop_process_network_clock();
    while (ftop_process_network_clock() - started < 42) {
        char stop;
        if (read(STDIN_FILENO, &stop, 1) == 1 && stop == 'q') break;
        uint64_t generation = 0;
        double now = 0;
        int count = ftop_process_network_copy(sampler, current, 16384, &generation, &now);
        if (count >= 0 && generation != old_generation) {
            completed++;
            double seconds = now - old_time;
            uint64_t received[2] = {0}, sent[2] = {0};
            if (seconds > 0 && seconds <= 6) for (int index = 0; index < count; index++) {
                ftop_process_network_counter *row = &current[index];
                int target = -1;
                for (int role_index = 0; role_index < 2; role_index++) {
                    if (roles[role_index].uid && roles[role_index].pid == row->pid && roles[role_index].uid == row->process_unique_id) target = role_index;
                }
                if (target < 0) continue;
                role *value = &roles[target];
                if (ftop_process_unique_id(value->pid) == value->uid) value->matches++;
                ftop_process_network_counter *baseline = NULL;
                for (int item = 0; item < old_count; item++) if (previous[item].source_id == row->source_id && previous[item].process_unique_id == row->process_unique_id) { baseline = &previous[item]; break; }
                if (baseline && row->received_bytes >= baseline->received_bytes && row->sent_bytes >= baseline->sent_bytes) {
                    received[target] += row->received_bytes - baseline->received_bytes;
                    sent[target] += row->sent_bytes - baseline->sent_bytes;
                } else if (row->initial_timestamp >= old_time && row->initial_timestamp <= now && row->received_bytes >= row->initial_received_bytes && row->sent_bytes >= row->initial_sent_bytes) {
                    received[target] += row->received_bytes - row->initial_received_bytes;
                    sent[target] += row->sent_bytes - row->initial_sent_bytes;
                } else value->baseline_only++;
            }
            for (int index = 0; index < 2; index++) {
                roles[index].received += received[index]; roles[index].sent += sent[index];
                if (seconds > 0 && (double)received[index] / seconds > roles[index].peak_down) roles[index].peak_down = (double)received[index] / seconds;
                if (seconds > 0 && (double)sent[index] / seconds > roles[index].peak_up) roles[index].peak_up = (double)sent[index] / seconds;
            }
            memcpy(previous, current, count * sizeof(*current));
            old_count = count; old_generation = generation; old_time = now;
        }
        usleep(100000);
    }
    ftop_process_network_destroy(sampler);
    printf("{\"completed_frames\":%d,\"roles\":[", completed);
    for (int index = 0; index < 2; index++) {
        role *value = &roles[index];
        printf("%s{\"received_delta\":%llu,\"sent_delta\":%llu,\"live_uid_matches\":%d,\"baseline_only_sources\":%d,\"peak_download_Bps\":%.2f,\"peak_upload_Bps\":%.2f}", index ? "," : "", value->received, value->sent, value->matches, value->baseline_only, value->peak_down, value->peak_up);
    }
    puts("]}");
    free(previous); free(current);
    return completed ? 0 : 6;
}
