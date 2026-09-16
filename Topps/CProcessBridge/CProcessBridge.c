#include "CProcessBridge.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fts.h>
#include <libproc.h>
#include <limits.h>
#include <mach/host_info.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/vm_statistics.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/sysctl.h>

static void cps_copy_string(char *destination, size_t capacity, const char *source) {
    if (!destination || capacity == 0) return;
    if (!source) { destination[0] = '\0'; return; }
    strlcpy(destination, source, capacity);
}

int32_t cps_list_pids(int32_t *buffer, int32_t capacity) {
    if (!buffer || capacity <= 0) return -1;
    // proc_listallpids returns the number of PIDs written, not the number of
    // bytes written. Dividing this value by sizeof(pid_t) silently discarded
    // three quarters of the system process list.
    int count = proc_listallpids(buffer, capacity * (int)sizeof(int32_t));
    return count < 0 ? -1 : count;
}

int32_t cps_read_process(int32_t pid, CPSProcessInfo *output) {
    if (!output || pid <= 0) return 0;
    memset(output, 0, sizeof(*output));
    output->pid = pid;

    struct proc_bsdinfo bsd = {0};
    int bsd_bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd));
    if (bsd_bytes != sizeof(bsd)) return 0;

    output->ppid = bsd.pbi_ppid;
    output->pgid = bsd.pbi_pgid;
    output->uid = bsd.pbi_uid;
    output->status = bsd.pbi_status;
    output->file_descriptor_count = bsd.pbi_nfiles;
    output->start_seconds = bsd.pbi_start_tvsec;
    output->start_microseconds = bsd.pbi_start_tvusec;
    cps_copy_string(output->name, sizeof(output->name), bsd.pbi_name[0] ? bsd.pbi_name : bsd.pbi_comm);

    struct proc_taskinfo task = {0};
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
        output->user_time_ns = task.pti_total_user;
        output->system_time_ns = task.pti_total_system;
        output->resident_bytes = task.pti_resident_size;
        output->virtual_bytes = task.pti_virtual_size;
        output->thread_count = task.pti_threadnum;
        output->page_faults = task.pti_faults;
        output->accessible = 1;
    }

    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) {
        output->physical_footprint = usage.ri_phys_footprint;
        output->peak_footprint = usage.ri_lifetime_max_phys_footprint;
        output->bytes_read = usage.ri_diskio_bytesread;
        output->bytes_written = usage.ri_diskio_byteswritten;
        output->accessible = 1;
    }

    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) > 0) {
        cps_copy_string(output->path, sizeof(output->path), path);
    }
    return 1;
}

int32_t cps_read_command(int32_t pid, char *buffer, int32_t capacity) {
    if (!buffer || capacity < 2 || pid <= 0) return 0;
    buffer[0] = '\0';
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) return 0;
    if (size > CPS_COMMAND_MAX) size = CPS_COMMAND_MAX;
    char *raw = calloc(1, size);
    if (!raw) return 0;
    if (sysctl(mib, 3, raw, &size, NULL, 0) != 0 || size <= sizeof(int)) { free(raw); return 0; }

    int argc = 0;
    memcpy(&argc, raw, sizeof(argc));
    char *cursor = raw + sizeof(argc);
    char *end = raw + size;
    while (cursor < end && *cursor != '\0') cursor++;
    while (cursor < end && *cursor == '\0') cursor++;

    int written = 0;
    for (int index = 0; index < argc && cursor < end; index++) {
        size_t length = strnlen(cursor, (size_t)(end - cursor));
        if (length == 0) break;
        if (written > 0 && written < capacity - 1) buffer[written++] = ' ';
        for (size_t i = 0; i < length && written < capacity - 1; i++) {
            char c = cursor[i];
            buffer[written++] = (c == '\n' || c == '\r') ? ' ' : c;
        }
        cursor += length + 1;
    }
    buffer[written] = '\0';
    free(raw);
    return written;
}

int32_t cps_read_cwd(int32_t pid, char *buffer, int32_t capacity) {
    if (!buffer || capacity <= 0 || pid <= 0) return 0;
    buffer[0] = '\0';
    struct proc_vnodepathinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    cps_copy_string(buffer, (size_t)capacity, info.pvi_cdir.vip_path);
    return (int32_t)strlen(buffer);
}

static void cps_format_inet_address(const struct in_sockinfo *info, int local, char *buffer, size_t capacity) {
    if (!info || !buffer || capacity == 0) return;
    buffer[0] = '\0';
    if (info->insi_vflag & INI_IPV4) {
        const struct in_addr *address = local
            ? &info->insi_laddr.ina_46.i46a_addr4
            : &info->insi_faddr.ina_46.i46a_addr4;
        inet_ntop(AF_INET, address, buffer, (socklen_t)capacity);
    } else if (info->insi_vflag & INI_IPV6) {
        const struct in6_addr *address = local ? &info->insi_laddr.ina_6 : &info->insi_faddr.ina_6;
        inet_ntop(AF_INET6, address, buffer, (socklen_t)capacity);
    }
}

int32_t cps_read_network_endpoints(int32_t pid, CPSNetworkEndpoint *buffer, int32_t capacity) {
    if (pid <= 0 || !buffer || capacity <= 0) return 0;
    int required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (required <= 0) return 0;
    struct proc_fdinfo *descriptors = calloc(1, (size_t)required);
    if (!descriptors) return 0;
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, descriptors, required);
    if (bytes <= 0) { free(descriptors); return 0; }

    int descriptor_count = bytes / (int)sizeof(struct proc_fdinfo);
    int output_count = 0;
    for (int index = 0; index < descriptor_count && output_count < capacity; index++) {
        if (descriptors[index].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo socket = {0};
        int socket_bytes = proc_pidfdinfo(pid, descriptors[index].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket));
        if (socket_bytes != sizeof(socket)) continue;

        const struct in_sockinfo *inet = NULL;
        int tcp_state = 0;
        if (socket.psi.soi_kind == SOCKINFO_TCP) {
            inet = &socket.psi.soi_proto.pri_tcp.tcpsi_ini;
            tcp_state = socket.psi.soi_proto.pri_tcp.tcpsi_state;
        } else if (socket.psi.soi_kind == SOCKINFO_IN) {
            inet = &socket.psi.soi_proto.pri_in;
        } else {
            continue;
        }
        if (socket.psi.soi_family != AF_INET && socket.psi.soi_family != AF_INET6) continue;

        CPSNetworkEndpoint *endpoint = &buffer[output_count++];
        memset(endpoint, 0, sizeof(*endpoint));
        endpoint->file_descriptor = descriptors[index].proc_fd;
        endpoint->family = socket.psi.soi_family;
        endpoint->socket_type = socket.psi.soi_type;
        endpoint->protocol_number = socket.psi.soi_protocol;
        endpoint->tcp_state = tcp_state;
        endpoint->local_port = ntohs((uint16_t)inet->insi_lport);
        endpoint->remote_port = ntohs((uint16_t)inet->insi_fport);
        cps_format_inet_address(inet, 1, endpoint->local_address, sizeof(endpoint->local_address));
        cps_format_inet_address(inet, 0, endpoint->remote_address, sizeof(endpoint->remote_address));
    }
    free(descriptors);
    return output_count;
}

int32_t cps_read_system(CPSSystemInfo *output) {
    if (!output) return 0;
    memset(output, 0, sizeof(*output));
    uint64_t memory = 0;
    size_t memory_size = sizeof(memory);
    sysctlbyname("hw.memsize", &memory, &memory_size, NULL, 0);
    output->total_memory = memory;

    uint32_t cpu_count = 1;
    size_t cpu_size = sizeof(cpu_count);
    sysctlbyname("hw.logicalcpu", &cpu_count, &cpu_size, NULL, 0);
    output->logical_cpu_count = cpu_count;

    mach_msg_type_number_t vm_count = HOST_VM_INFO64_COUNT;
    vm_statistics64_data_t vm = {0};
    mach_port_t host = mach_host_self();
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &vm_count) == KERN_SUCCESS) {
        vm_size_t page_size = 0;
        host_page_size(host, &page_size);
        output->free_memory = (vm.free_count + vm.speculative_count) * page_size;
        output->active_memory = vm.active_count * page_size;
        output->inactive_memory = vm.inactive_count * page_size;
        output->wired_memory = vm.wire_count * page_size;
        output->compressed_memory = vm.compressor_page_count * page_size;
        output->purgeable_memory = vm.purgeable_count * page_size;
        output->speculative_memory = vm.speculative_count * page_size;
    }

    mach_msg_type_number_t cpu_count_info = HOST_CPU_LOAD_INFO_COUNT;
    host_cpu_load_info_data_t cpu = {0};
    if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &cpu_count_info) == KERN_SUCCESS) {
        output->cpu_user_ticks = cpu.cpu_ticks[CPU_STATE_USER];
        output->cpu_system_ticks = cpu.cpu_ticks[CPU_STATE_SYSTEM];
        output->cpu_idle_ticks = cpu.cpu_ticks[CPU_STATE_IDLE];
        output->cpu_nice_ticks = cpu.cpu_ticks[CPU_STATE_NICE];
    }
    mach_port_deallocate(mach_task_self(), host);

    struct xsw_usage swap = {0};
    size_t swap_size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &swap_size, NULL, 0) == 0) output->swap_used = swap.xsu_used;
    return 1;
}

typedef struct {
    uint64_t allocated_bytes;
    uint64_t logical_bytes;
    uint64_t file_count;
    int64_t modified_seconds;
} CPSDirectoryUsage;

typedef struct {
    CPSStorageEntry *values;
    int32_t count;
    int32_t capacity;
} CPSStorageHeap;

static uint64_t cps_storage_add(uint64_t lhs, uint64_t rhs) {
    return UINT64_MAX - lhs < rhs ? UINT64_MAX : lhs + rhs;
}

static int cps_storage_entry_less(const CPSStorageEntry *lhs, const CPSStorageEntry *rhs) {
    if (lhs->allocated_bytes != rhs->allocated_bytes) return lhs->allocated_bytes < rhs->allocated_bytes;
    return lhs->file_count < rhs->file_count;
}

static void cps_storage_heap_swap(CPSStorageEntry *lhs, CPSStorageEntry *rhs) {
    CPSStorageEntry temporary = *lhs;
    *lhs = *rhs;
    *rhs = temporary;
}

static void cps_storage_heap_sift_up(CPSStorageHeap *heap, int32_t index) {
    while (index > 0) {
        int32_t parent = (index - 1) / 2;
        if (!cps_storage_entry_less(&heap->values[index], &heap->values[parent])) break;
        cps_storage_heap_swap(&heap->values[index], &heap->values[parent]);
        index = parent;
    }
}

static void cps_storage_heap_sift_down(CPSStorageHeap *heap, int32_t index) {
    while (1) {
        int32_t left = index * 2 + 1;
        int32_t right = left + 1;
        int32_t smallest = index;
        if (left < heap->count && cps_storage_entry_less(&heap->values[left], &heap->values[smallest])) smallest = left;
        if (right < heap->count && cps_storage_entry_less(&heap->values[right], &heap->values[smallest])) smallest = right;
        if (smallest == index) break;
        cps_storage_heap_swap(&heap->values[index], &heap->values[smallest]);
        index = smallest;
    }
}

static void cps_storage_heap_add(CPSStorageHeap *heap, const CPSStorageEntry *entry) {
    if (!heap || heap->capacity <= 0 || !entry) return;
    if (heap->count < heap->capacity) {
        heap->values[heap->count] = *entry;
        cps_storage_heap_sift_up(heap, heap->count);
        heap->count++;
        return;
    }
    if (!cps_storage_entry_less(&heap->values[0], entry)) return;
    heap->values[0] = *entry;
    cps_storage_heap_sift_down(heap, 0);
}

static int cps_storage_name_in(const char *name, const char *const *names, size_t count) {
    if (!name) return 0;
    for (size_t index = 0; index < count; index++) {
        if (strcasecmp(name, names[index]) == 0) return 1;
    }
    return 0;
}

static int cps_storage_is_opportunity_directory(const FTSENT *entry) {
    if (!entry || !entry->fts_name) return 0;
    static const char *const cache_names[] = {"cache", "caches", ".cache", ".npm", ".yarn", ".pnpm-store"};
    static const char *const dependency_names[] = {"node_modules", "vendor", "pods", ".venv", "venv", ".gradle"};
    static const char *const build_names[] = {"build", ".build", "target", "deriveddata", "dist", ".next", ".nuxt", "out", "coverage"};
    const FTSENT *parent = entry->fts_parent;
    const FTSENT *grandparent = parent ? parent->fts_parent : NULL;

    if (cps_storage_name_in(entry->fts_name, cache_names, sizeof(cache_names) / sizeof(cache_names[0]))) return 1;
    if (cps_storage_name_in(entry->fts_name, dependency_names, sizeof(dependency_names) / sizeof(dependency_names[0]))) return 1;
    if (cps_storage_name_in(entry->fts_name, build_names, sizeof(build_names) / sizeof(build_names[0]))) return 1;
    if (strcasecmp(entry->fts_name, "downloads") == 0) return 1;
    if (parent && cps_storage_name_in(parent->fts_name, cache_names, sizeof(cache_names) / sizeof(cache_names[0]))) return 1;
    if (parent && strcasecmp(parent->fts_name, "downloads") == 0) return 1;
    if (parent && grandparent && strcasecmp(parent->fts_name, "Application Support") == 0 && strcasecmp(grandparent->fts_name, "Library") == 0) return 1;
    if (parent && strcasecmp(entry->fts_name, "Application Support") == 0 && strcasecmp(parent->fts_name, "Library") == 0) return 1;
    if (parent && strcasecmp(parent->fts_name, ".cargo") == 0 && (strcasecmp(entry->fts_name, "registry") == 0 || strcasecmp(entry->fts_name, "git") == 0)) return 1;
    return 0;
}

static CPSStorageEntry cps_storage_make_entry(const char *path, int32_t is_directory, const CPSDirectoryUsage *usage) {
    CPSStorageEntry entry;
    memset(&entry, 0, sizeof(entry));
    entry.is_directory = is_directory;
    entry.allocated_bytes = usage->allocated_bytes;
    entry.logical_bytes = usage->logical_bytes;
    entry.file_count = usage->file_count;
    entry.modified_seconds = usage->modified_seconds;
    cps_copy_string(entry.path, sizeof(entry.path), path);
    return entry;
}

int32_t cps_scan_storage(const char *root_path, CPSStorageEntry *buffer, int32_t capacity, CPSStorageSummary *summary, CPSStorageCancellationCallback should_cancel) {
    if (!root_path || !buffer || capacity <= 0 || !summary) return -1;
    memset(summary, 0, sizeof(*summary));

    struct stat root_stat;
    if (stat(root_path, &root_stat) != 0 || !S_ISDIR(root_stat.st_mode)) {
        summary->error_code = errno ? errno : ENOTDIR;
        return -1;
    }

    int32_t largest_capacity = capacity < 800 ? capacity : 800;
    int32_t opportunity_capacity = capacity - largest_capacity;
    if (opportunity_capacity > 400) opportunity_capacity = 400;
    int32_t large_file_capacity = capacity - largest_capacity - opportunity_capacity;
    if (large_file_capacity > 200) large_file_capacity = 200;
    CPSStorageEntry *heap_storage = calloc((size_t)(largest_capacity + opportunity_capacity + large_file_capacity), sizeof(CPSStorageEntry));
    if (!heap_storage) { summary->error_code = ENOMEM; return -1; }
    CPSStorageHeap largest = { heap_storage, 0, largest_capacity };
    CPSStorageHeap opportunities = { heap_storage + largest_capacity, 0, opportunity_capacity };
    CPSStorageHeap large_files = { heap_storage + largest_capacity + opportunity_capacity, 0, large_file_capacity };

    size_t usage_capacity = 32;
    CPSDirectoryUsage *usages = calloc(usage_capacity, sizeof(CPSDirectoryUsage));
    char *root_copy = strdup(root_path);
    char *paths[] = { root_copy, NULL };
    if (!usages || !root_copy) {
        free(heap_storage);
        free(usages);
        free(root_copy);
        summary->error_code = ENOMEM;
        return -1;
    }

    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR | FTS_COMFOLLOW, NULL);
    if (!tree) {
        summary->error_code = errno;
        free(heap_storage);
        free(usages);
        free(root_copy);
        return -1;
    }

    uint64_t visited = 0;
    FTSENT *item = NULL;
    while (1) {
        errno = 0;
        item = fts_read(tree);
        if (!item) {
            if (!summary->cancellation_reason && !summary->error_code && errno != 0) summary->error_code = errno;
            break;
        }
        visited++;
        if ((visited & 1023) == 0 && should_cancel) {
            int32_t reason = should_cancel();
            if (reason != 0) { summary->cancellation_reason = reason; break; }
        }
        if (item->fts_level < 0) continue;
        size_t level = (size_t)item->fts_level;
        if (level >= usage_capacity) {
            size_t new_capacity = usage_capacity;
            while (level >= new_capacity) new_capacity *= 2;
            CPSDirectoryUsage *resized = realloc(usages, new_capacity * sizeof(CPSDirectoryUsage));
            if (!resized) { summary->error_code = ENOMEM; break; }
            memset(resized + usage_capacity, 0, (new_capacity - usage_capacity) * sizeof(CPSDirectoryUsage));
            usages = resized;
            usage_capacity = new_capacity;
        }

        if (item->fts_info == FTS_D) {
            memset(&usages[level], 0, sizeof(CPSDirectoryUsage));
            if (item->fts_statp) usages[level].modified_seconds = item->fts_statp->st_mtime;
            continue;
        }
        if (item->fts_info == FTS_DNR || item->fts_info == FTS_ERR || item->fts_info == FTS_NS) {
            summary->unreadable_item_count = cps_storage_add(summary->unreadable_item_count, 1);
            continue;
        }
        if (item->fts_info == FTS_DP) {
            CPSDirectoryUsage completed = usages[level];
            if (level > 0) {
                usages[level - 1].allocated_bytes = cps_storage_add(usages[level - 1].allocated_bytes, completed.allocated_bytes);
                usages[level - 1].logical_bytes = cps_storage_add(usages[level - 1].logical_bytes, completed.logical_bytes);
                usages[level - 1].file_count = cps_storage_add(usages[level - 1].file_count, completed.file_count);
                if (completed.modified_seconds > usages[level - 1].modified_seconds) usages[level - 1].modified_seconds = completed.modified_seconds;
                CPSStorageEntry entry = cps_storage_make_entry(item->fts_path, 1, &completed);
                cps_storage_heap_add(&largest, &entry);
                if (cps_storage_is_opportunity_directory(item)) cps_storage_heap_add(&opportunities, &entry);
            } else {
                summary->allocated_bytes = completed.allocated_bytes;
                summary->logical_bytes = completed.logical_bytes;
                summary->file_count = completed.file_count;
            }
            continue;
        }
        if (!item->fts_statp || !S_ISREG(item->fts_statp->st_mode) || level == 0) continue;

        CPSDirectoryUsage file_usage = {0};
        file_usage.allocated_bytes = item->fts_statp->st_blocks > 0 ? (uint64_t)item->fts_statp->st_blocks * 512 : 0;
        file_usage.logical_bytes = item->fts_statp->st_size > 0 ? (uint64_t)item->fts_statp->st_size : 0;
        file_usage.file_count = 1;
        file_usage.modified_seconds = item->fts_statp->st_mtime;
        usages[level - 1].allocated_bytes = cps_storage_add(usages[level - 1].allocated_bytes, file_usage.allocated_bytes);
        usages[level - 1].logical_bytes = cps_storage_add(usages[level - 1].logical_bytes, file_usage.logical_bytes);
        usages[level - 1].file_count = cps_storage_add(usages[level - 1].file_count, 1);
        if (file_usage.modified_seconds > usages[level - 1].modified_seconds) usages[level - 1].modified_seconds = file_usage.modified_seconds;
        if (file_usage.allocated_bytes >= 100000000ULL) {
            CPSStorageEntry entry = cps_storage_make_entry(item->fts_path, 0, &file_usage);
            cps_storage_heap_add(&large_files, &entry);
        }
    }

    fts_close(tree);
    int32_t output_count = 0;
    for (int32_t index = 0; index < largest.count && output_count < capacity; index++) buffer[output_count++] = largest.values[index];
    for (int32_t index = 0; index < opportunities.count && output_count < capacity; index++) buffer[output_count++] = opportunities.values[index];
    for (int32_t index = 0; index < large_files.count && output_count < capacity; index++) buffer[output_count++] = large_files.values[index];
    free(heap_storage);
    free(usages);
    free(root_copy);
    if (summary->error_code) return -1;
    return output_count;
}
