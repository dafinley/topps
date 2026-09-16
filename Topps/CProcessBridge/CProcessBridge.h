#ifndef CProcessBridge_h
#define CProcessBridge_h

#include <stdint.h>
#include <sys/types.h>

#define CPS_NAME_MAX 256
#define CPS_PATH_MAX 1024
#define CPS_COMMAND_MAX 8192
#define CPS_ADDRESS_MAX 64
#define CPS_STORAGE_PATH_MAX 1024

typedef struct {
    int32_t pid;
    int32_t ppid;
    int32_t pgid;
    uint32_t uid;
    uint32_t status;
    uint32_t thread_count;
    uint32_t file_descriptor_count;
    uint64_t start_seconds;
    uint64_t start_microseconds;
    uint64_t user_time_ns;
    uint64_t system_time_ns;
    uint64_t resident_bytes;
    uint64_t virtual_bytes;
    uint64_t physical_footprint;
    uint64_t peak_footprint;
    uint64_t bytes_read;
    uint64_t bytes_written;
    uint64_t page_faults;
    int32_t accessible;
    char name[CPS_NAME_MAX];
    char path[CPS_PATH_MAX];
} CPSProcessInfo;

typedef struct {
    uint64_t total_memory;
    uint64_t free_memory;
    uint64_t active_memory;
    uint64_t inactive_memory;
    uint64_t wired_memory;
    uint64_t compressed_memory;
    uint64_t purgeable_memory;
    uint64_t speculative_memory;
    uint64_t swap_used;
    uint64_t cpu_user_ticks;
    uint64_t cpu_system_ticks;
    uint64_t cpu_idle_ticks;
    uint64_t cpu_nice_ticks;
    uint32_t logical_cpu_count;
    uint32_t process_count;
    uint32_t running_process_count;
    uint32_t thread_count;
} CPSSystemInfo;

typedef struct {
    int32_t file_descriptor;
    int32_t family;
    int32_t socket_type;
    int32_t protocol_number;
    int32_t tcp_state;
    uint16_t local_port;
    uint16_t remote_port;
    char local_address[CPS_ADDRESS_MAX];
    char remote_address[CPS_ADDRESS_MAX];
} CPSNetworkEndpoint;

typedef struct {
    uint64_t allocated_bytes;
    uint64_t logical_bytes;
    uint64_t file_count;
    int64_t modified_seconds;
    int32_t is_directory;
    char path[CPS_STORAGE_PATH_MAX];
} CPSStorageEntry;

typedef struct {
    uint64_t allocated_bytes;
    uint64_t logical_bytes;
    uint64_t file_count;
    uint64_t unreadable_item_count;
    int32_t cancellation_reason;
    int32_t error_code;
} CPSStorageSummary;

typedef int32_t (*CPSStorageCancellationCallback)(void);

int32_t cps_list_pids(int32_t *buffer, int32_t capacity);
int32_t cps_read_process(int32_t pid, CPSProcessInfo *output);
int32_t cps_read_command(int32_t pid, char *buffer, int32_t capacity);
int32_t cps_read_cwd(int32_t pid, char *buffer, int32_t capacity);
int32_t cps_read_network_endpoints(int32_t pid, CPSNetworkEndpoint *buffer, int32_t capacity);
int32_t cps_read_system(CPSSystemInfo *output);
int32_t cps_scan_storage(const char *root_path, CPSStorageEntry *buffer, int32_t capacity, CPSStorageSummary *summary, CPSStorageCancellationCallback should_cancel);

#endif
