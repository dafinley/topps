#include "CProcessBridge.h"

#include <arpa/inet.h>
#include <libproc.h>
#include <mach/host_info.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/vm_statistics.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
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
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &vm_count) == KERN_SUCCESS) {
        vm_size_t page_size = 0;
        host_page_size(mach_host_self(), &page_size);
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
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &cpu_count_info) == KERN_SUCCESS) {
        output->cpu_user_ticks = cpu.cpu_ticks[CPU_STATE_USER];
        output->cpu_system_ticks = cpu.cpu_ticks[CPU_STATE_SYSTEM];
        output->cpu_idle_ticks = cpu.cpu_ticks[CPU_STATE_IDLE];
        output->cpu_nice_ticks = cpu.cpu_ticks[CPU_STATE_NICE];
    }

    struct xsw_usage swap = {0};
    size_t swap_size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &swap_size, NULL, 0) == 0) output->swap_used = swap.xsu_used;
    return 1;
}
