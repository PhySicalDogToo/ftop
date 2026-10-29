#include "CFtopSys.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Read-only production-interface smoke; no PIDs, names, addresses, or counters
// are persisted. Repeated teardown exercises late callback ownership.
int main(void) {
    ftop_process_network_counter *rows = calloc(16384, sizeof(*rows));
    if (!rows) return 2;
    for (int cycle = 0; cycle < 2; cycle++) {
        ftop_process_network_sampler *sampler = ftop_process_network_create();
        if (!sampler) { puts("observer_unavailable"); free(rows); return 3; }
        uint64_t last = 0;
        int completed = 0, peak = 0, matched = 0;
        for (int tick = 0; tick < 24; tick++) {
            usleep(250000);
            uint64_t generation = 0;
            double time = 0;
            int count = ftop_process_network_copy(sampler, rows, 16384, &generation, &time);
            if (count < -1) { printf("observer_failure=%d\n", count); ftop_process_network_destroy(sampler); free(rows); return 4; }
            if (count >= 0 && generation != last) {
                completed++; last = generation;
                if (count > peak) peak = count;
                for (int index = 0; index < count; index++) {
                    if (rows[index].process_unique_id && ftop_process_unique_id(rows[index].pid) == rows[index].process_unique_id) matched++;
                }
            }
        }
        ftop_process_network_destroy(sampler);
        printf("cycle=%d completed=%d peak_sources=%d identity_matches=%d\n", cycle + 1, completed, peak, matched);
        usleep(250000);
        if (!completed || !matched) { free(rows); return 5; }
    }
    free(rows);
    return 0;
}
