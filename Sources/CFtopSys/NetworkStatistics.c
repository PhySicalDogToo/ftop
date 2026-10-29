#include "CFtopSys.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <libproc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <time.h>

// Private declarations stay here. Missing implementations fail closed. No
// addresses, packets, payloads, DNS queries, or network writes are involved.
typedef void *NStatManagerRef;
typedef void *NStatSourceRef;
typedef NStatManagerRef (*ManagerCreate)(CFAllocatorRef, dispatch_queue_t, void (^)(NStatSourceRef, int));
typedef void (*ManagerDestroy)(NStatManagerRef);
typedef void (*ManagerAdd)(NStatManagerRef);
typedef void (*ManagerQuery)(NStatManagerRef, void (^)(void));
typedef void (*SourceDictionaryBlock)(NStatSourceRef, void (^)(CFDictionaryRef));
typedef void (*SourceRemovedBlock)(NStatSourceRef, void (^)(void));
// XNU proc_info_private.h: PROC_PIDUNIQIDENTIFIERINFO (17), fixed 56-byte ABI.
typedef struct {
    uint8_t uuid[16];
    uint64_t unique_id, parent_unique_id;
    int32_t version, parent_version;
    uint64_t reserved[2];
} process_unique_info;
_Static_assert(sizeof(process_unique_info) == 56, "process identity ABI");
#define SOURCE_LIMIT 16384
#define QUERY_TIMEOUT 6.0

typedef struct {
    ftop_process_network_counter value;
    bool has_counts;
    uint64_t removal_generation, framed_received, framed_sent;
} network_source;
typedef struct {
    dispatch_queue_t queue;
    dispatch_source_t timer;
    NStatManagerRef manager;
    ManagerDestroy destroy;
    ManagerQuery descriptions, counts;
    SourceDictionaryBlock set_counts, set_description;
    SourceRemovedBlock set_removed;
    CFStringRef pid_key, unique_key, name_key, received_key, sent_key;
    network_source *sources;
    ftop_process_network_counter *frame;
    int frame_count;
    atomic_int failure;
    atomic_bool alive;
    atomic_uint_fast64_t acknowledged;
    pthread_mutex_t snapshot_lock;
    bool pending, had_counts;
    uint64_t next_source, generation;
    double started, query_started, completed;
} network_state;

// Copied blocks retain this toll-free bridged owner. Queued callbacks can test
// alive after teardown without using freed state. Teardown breaks manager/timer
// retain cycles; the larger buffers are freed after alive becomes false.
typedef CFMutableDataRef __attribute__((NSObject)) network_owner;
static network_state *state_of(CFMutableDataRef owner) { return (network_state *)CFDataGetMutableBytePtr(owner); }

double ftop_process_network_clock(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_UPTIME_RAW, &value) != 0) return 0;
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

uint64_t ftop_process_unique_id(int32_t pid) {
    if (pid <= 0) return 0;
    process_unique_info info;
    memset(&info, 0, sizeof(info));
    if (proc_pidinfo(pid, 17, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return info.unique_id;
}

static bool number(CFDictionaryRef dictionary, CFStringRef key, uint64_t *out) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    int64_t integer = 0;
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID() ||
        !CFNumberGetValue(value, kCFNumberSInt64Type, &integer) || integer < 0) return false;
    *out = (uint64_t)integer;
    return true;
}

static CFStringRef key(void *library, const char *name) {
    CFStringRef *value = (CFStringRef *)dlsym(library, name);
    return value ? *value : NULL;
}

static void complete(network_owner owner) {
    network_state *state = state_of(owner);
    if (!state->alive || state->failure) return;
    state->pending = false;
    pthread_mutex_lock(&state->snapshot_lock);
    state->frame_count = 0;
    for (int index = 0; index < SOURCE_LIMIT; index++) {
        network_source *source = &state->sources[index];
        if (source->value.source_id && source->has_counts) state->frame[state->frame_count++] = source->value;
        if (source->value.source_id && source->value.removed) source->removal_generation = state->generation + 1;
        source->framed_received = source->value.received_bytes;
        source->framed_sent = source->value.sent_bytes;
    }
    state->completed = ftop_process_network_clock();
    state->generation++;
    pthread_mutex_unlock(&state->snapshot_lock);
}

static void query(network_owner owner) {
    network_state *state = state_of(owner);
    if (!state->alive || state->failure) return;
    uint64_t acknowledged = atomic_load(&state->acknowledged);
    for (int index = 0; index < SOURCE_LIMIT; index++) {
        network_source *source = &state->sources[index];
        if (source->value.removed && source->removal_generation && source->removal_generation <= acknowledged &&
            source->framed_received == source->value.received_bytes && source->framed_sent == source->value.sent_bytes)
            memset(source, 0, sizeof(*source));
    }
    double now = ftop_process_network_clock();
    if (state->pending) {
        if (now - state->query_started > QUERY_TIMEOUT) state->failure = -4;
        return;
    }
    if (!state->had_counts && now - state->started > QUERY_TIMEOUT) { state->failure = -2; return; }
    state->pending = true;
    state->query_started = now;
    state->descriptions(state->manager, NULL);
    state->counts(state->manager, ^{ complete(owner); });
}

ftop_process_network_sampler *ftop_process_network_create(void) {
    // Shared-cache framework loading is retained; every observer is destroyed.
    static void *library;
    static dispatch_once_t load_once;
    dispatch_once(&load_once, ^{
        library = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY | RTLD_LOCAL);
    });
    if (!library) return NULL;
    ManagerCreate create = (ManagerCreate)dlsym(library, "NStatManagerCreate");
    ManagerAdd tcp = (ManagerAdd)dlsym(library, "NStatManagerAddAllTCP");
    ManagerAdd udp = (ManagerAdd)dlsym(library, "NStatManagerAddAllUDP");
    network_owner owner = CFDataCreateMutable(kCFAllocatorDefault, sizeof(network_state));
    if (!owner) return NULL;
    CFDataSetLength(owner, sizeof(network_state));
    network_state *state = state_of(owner);
    memset(state, 0, sizeof(*state));
    atomic_init(&state->failure, 0);
    atomic_init(&state->alive, false);
    atomic_init(&state->acknowledged, 0);
    pthread_mutex_init(&state->snapshot_lock, NULL);
    state->destroy = (ManagerDestroy)dlsym(library, "NStatManagerDestroy");
    state->descriptions = (ManagerQuery)dlsym(library, "NStatManagerQueryAllSourcesDescriptions");
    state->counts = (ManagerQuery)dlsym(library, "NStatManagerQueryAllSources");
    state->set_counts = (SourceDictionaryBlock)dlsym(library, "NStatSourceSetCountsBlock");
    state->set_description = (SourceDictionaryBlock)dlsym(library, "NStatSourceSetDescriptionBlock");
    state->set_removed = (SourceRemovedBlock)dlsym(library, "NStatSourceSetRemovedBlock");
    state->pid_key = key(library, "kNStatSrcKeyPID"); state->unique_key = key(library, "kNStatSrcKeyUPID");
    state->name_key = key(library, "kNStatSrcKeyProcessName");
    state->received_key = key(library, "kNStatSrcKeyRxBytes"); state->sent_key = key(library, "kNStatSrcKeyTxBytes");
    if (!create || !tcp || !udp || !state->destroy || !state->descriptions || !state->counts ||
        !state->set_counts || !state->set_description || !state->set_removed ||
        !state->pid_key || !state->unique_key || !state->name_key || !state->received_key || !state->sent_key) {
        pthread_mutex_destroy(&state->snapshot_lock); CFRelease(owner); return NULL;
    }
    state->sources = calloc(SOURCE_LIMIT, sizeof(network_source));
    state->frame = calloc(SOURCE_LIMIT, sizeof(ftop_process_network_counter));
    if (!state->sources || !state->frame) {
        free(state->sources); free(state->frame); pthread_mutex_destroy(&state->snapshot_lock); CFRelease(owner); return NULL;
    }
    state->queue = dispatch_queue_create("dev.ftop.process-network", DISPATCH_QUEUE_SERIAL);
    state->alive = true;
    state->started = ftop_process_network_clock();
    state->manager = create(kCFAllocatorDefault, state->queue, ^(NStatSourceRef reference, int unused) {
        (void)unused;
        network_state *current = state_of(owner);
        if (!current->alive || current->failure) return;
        int slot = 0;
        while (slot < SOURCE_LIMIT && current->sources[slot].value.source_id) slot++;
        if (slot == SOURCE_LIMIT) { current->failure = -3; return; }
        uint64_t source_id = ++current->next_source;
        current->sources[slot].value.source_id = source_id;
        current->set_description(reference, ^(CFDictionaryRef dictionary) {
            network_state *value = state_of(owner);
            if (!value->alive || value->sources[slot].value.source_id != source_id || !dictionary) return;
            network_source *source = &value->sources[slot];
            uint64_t pid = 0, unique = 0;
            if (!number(dictionary, value->pid_key, &pid) || pid == 0 || pid > INT32_MAX ||
                !number(dictionary, value->unique_key, &unique) || unique == 0) return;
            if (source->value.pid != (int32_t)pid || source->value.process_unique_id != unique) {
                source->value.initial_received_bytes = 0;
                source->value.initial_sent_bytes = 0;
                source->value.initial_timestamp = 0;
                source->has_counts = false;
            }
            source->value.pid = (int32_t)pid;
            source->value.process_unique_id = unique;
            CFTypeRef name = CFDictionaryGetValue(dictionary, value->name_key);
            if (name && CFGetTypeID(name) == CFStringGetTypeID() &&
                !CFStringGetCString(name, source->value.name, sizeof(source->value.name), kCFStringEncodingUTF8)) source->value.name[0] = 0;
        });
        current->set_counts(reference, ^(CFDictionaryRef dictionary) {
            network_state *value = state_of(owner);
            if (!value->alive || value->sources[slot].value.source_id != source_id || !dictionary) return;
            network_source *source = &value->sources[slot];
            uint64_t received = 0, sent = 0;
            if (!number(dictionary, value->received_key, &received) || !number(dictionary, value->sent_key, &sent)) {
                value->failure = -2; return;
            }
            if (!source->has_counts) {
                source->value.initial_received_bytes = received;
                source->value.initial_sent_bytes = sent;
                source->value.initial_timestamp = ftop_process_network_clock();
            }
            source->value.received_bytes = received; source->value.sent_bytes = sent;
            source->has_counts = true; value->had_counts = true;
        });
        current->set_removed(reference, ^{
            network_state *value = state_of(owner);
            if (!value->alive || value->sources[slot].value.source_id != source_id) return;
            value->sources[slot].value.removed = 1;
        });
    });
    if (!state->manager) {
        state->alive = false; dispatch_release(state->queue);
        free(state->sources); free(state->frame); pthread_mutex_destroy(&state->snapshot_lock); CFRelease(owner); return NULL;
    }
    dispatch_sync(state->queue, ^{
        tcp(state->manager); udp(state->manager);
        state->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, state->queue);
        dispatch_source_set_timer(state->timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(state->timer, ^{ query(owner); });
        dispatch_resume(state->timer);
    });
    return (ftop_process_network_sampler *)owner;
}

void ftop_process_network_destroy(ftop_process_network_sampler *sampler) {
    if (!sampler) return;
    network_owner owner = (CFMutableDataRef)sampler;
    network_state *state = state_of(owner);
    dispatch_queue_t queue = state->queue;
    dispatch_sync(queue, ^{
        state->alive = false;
        if (state->timer) { dispatch_source_cancel(state->timer); dispatch_release(state->timer); state->timer = NULL; }
        state->destroy(state->manager); state->manager = NULL;
        free(state->sources); state->sources = NULL;
        free(state->frame); state->frame = NULL;
        pthread_mutex_destroy(&state->snapshot_lock);
    });
    CFRelease(owner);
    dispatch_release(queue);
}

int ftop_process_network_copy(ftop_process_network_sampler *sampler,
    ftop_process_network_counter *out, int capacity, uint64_t *generation, double *timestamp) {
    if (!sampler || !out || capacity <= 0 || !generation || !timestamp) return -2;
    network_state *state = state_of((CFMutableDataRef)sampler);
    if (!state->alive) return -2;
    int failure = atomic_load(&state->failure);
    if (failure) return failure;
    if (pthread_mutex_trylock(&state->snapshot_lock) != 0) return -1;
    int result = -1;
    if (state->generation) {
        if (ftop_process_network_clock() - state->completed > QUERY_TIMEOUT) result = -4;
        else if (state->frame_count > capacity) result = -3;
        else {
            memcpy(out, state->frame, state->frame_count * sizeof(*out));
            *generation = state->generation; *timestamp = state->completed;
            result = state->frame_count;
            atomic_store(&state->acknowledged, state->generation);
        }
    }
    pthread_mutex_unlock(&state->snapshot_lock);
    return result;
}
