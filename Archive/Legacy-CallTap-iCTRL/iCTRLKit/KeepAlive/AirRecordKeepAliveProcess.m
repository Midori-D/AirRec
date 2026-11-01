// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#import "AirRecordKeepAliveProcess.h"
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <unistd.h>

// Security exports these APIs on iOS, but its public iOS headers omit SecTask.
// Keep the private declarations local instead of adding them to Swift's bridge.
typedef struct __SecTask *AirRecordSecTaskRef;
extern AirRecordSecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(AirRecordSecTaskRef task,
                                              CFStringRef entitlement,
                                              CFErrorRef *error);

bool airrecord_process_is_traced(void) {
    struct kinfo_proc process = {0};
    size_t length = sizeof(process);
    int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(query, 4, &process, &length, NULL, 0) != 0 || length != sizeof(process)) {
        return false;
    }
    return (process.kp_proc.p_flag & P_TRACED) != 0;
}

bool airrecord_process_allows_debugging(void) {
    AirRecordSecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) { return false; }
    CFErrorRef error = NULL;
    CFTypeRef entitlement = SecTaskCopyValueForEntitlement(task, CFSTR("get-task-allow"), &error);
    bool allowed = error == NULL && entitlement != NULL
        && CFGetTypeID(entitlement) == CFBooleanGetTypeID()
        && CFBooleanGetValue((CFBooleanRef)entitlement);
    if (error) { CFRelease(error); }
    if (entitlement) { CFRelease(entitlement); }
    CFRelease(task);
    return allowed;
}
