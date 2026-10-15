// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// MadeiraProcessHost: an app extension (com.apple.ar.viewer, as LiveContainer's
// LiveProcess and the donor pool are) that runs ONE Wine process in its own iOS
// task and connects it to the wineserver in the app. ml1330, docs/PROCESS_HOST.md.
//
// It links the same native Wine client static libraries as the app (libntdll_unix.a,
// libwin32u_unix.a, libwineserver.a, libdxmt_combined.a, the FEX host libs, gnutls,
// ffmpeg) plus JITAllocator.c (the debugger pool) and wine_stubs.c, and provides the
// handful of app-only UI/exit symbols a headless client needs in ProcessHostStubs.c.
//
// The extension is HEADLESS: the guest's windows live in the app's wineserver. Window
// geometry (ml1331) and, since ml1332, each top-level window's frames (two IOSurfaces
// per window, see "ml1332 frames" below) go to the app over XPC. The feature is off
// unless the app enables it (env.MADEIRA_EXT_PROCESS=1); env.MADEIRA_EXT_PROCESS_FRAMES=0
// keeps the frames black.
//
// Nothing here boots Wine on its own: it waits for the app's prepareGuest/startGuest.
// A full guest boot inside an extension is UNVERIFIED on device; this file is written
// to be honest and to compile/link, logging each step.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <IOSurface/IOSurfaceRef.h>
#import <execinfo.h>
#import <signal.h>
#import <stdarg.h>
#import <sys/ucontext.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <setjmp.h>
#import <pthread.h>
#import <sys/sysctl.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/socket.h>
#import "../Madeira/ProcessHostControl.h"
extern int ios_process_host_control(PHControlRequest *, void *);
#import "../Madeira/ProcessHostProtocol.h"
#import "../Madeira/JITAllocator.h"   // jit26_prepare_region, jit_check_debugged

// Wine entry and logging (libntdll_unix.a / libwineserver.a).
extern void __wine_main(int argc, char *argv[]);
extern void wine_log_set_file(const char *path);
extern void wineserver_set_nls_dir(const char *path);   // unicode_ios.c (unused server side here, harmless)
extern int ios_main_image_i386;                          // ntdll: 0 = the guest EXE is 64-bit

// The exit jmpbuf the Wine Unix side longjmps to (ProcessHostStubs.c defines it).
extern _Thread_local jmp_buf wine_ios_exit_jmpbuf;
extern _Thread_local volatile int wine_ios_exit_code;
extern _Thread_local pthread_t wine_ios_main_thread;
extern _Thread_local int wine_ios_exit_initialized;

// ml1332: IOSurface frame transport for this process's windows (set by prepareGuest).
static int ph_frames_on;

#pragma mark - ml1333 extension log, crash handlers, start milestones

// stderr (Wine's own output included) goes to <shared container>/madeira-shared/ext-logs/
// <pid>.txt when the app group resolves, else to this extension's Documents (unreadable
// from the app). The app appends the shared file to its session log when the extension
// is interrupted or the guest exits ("[ext-proc] ml1333 ext log: ..."). stderr is
// unbuffered and the file is O_APPEND, so every line is on disk when it is written.
static double ph_log_t0;
static void ph_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void ph_log(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    dprintf(STDERR_FILENO, "[ext +%.3fs] %s\n", ph_log_t0 > 0 ? CACurrentMediaTime() - ph_log_t0 : 0.0, buf);
}

// Keeps the newest `keep` logs of earlier extension processes.
static void ph_prune_logs(NSString *dir, NSUInteger keep) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *logs = [NSMutableArray new];
    for (NSURL *url in [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:dir]
                         includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil] ?: @[])
        if ([url.pathExtension isEqualToString:@"txt"]) [logs addObject:url];
    if (logs.count <= keep) return;
    [logs sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da = nil, *db = nil;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [(db ?: NSDate.distantPast) compare:(da ?: NSDate.distantPast)];   // newest first
    }];
    for (NSUInteger i = keep; i < logs.count; i++) [fm removeItemAtURL:logs[i] error:nil];
}

static NSString *ph_open_log(NSURL *container, NSString *ownDocs) {
    NSString *path = nil;
    int fd = -1;
    if (container) {
        NSString *dir = [container.path stringByAppendingPathComponent:@"madeira-shared/ext-logs"];
        if ([NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) {
            ph_prune_logs(dir, 15);
            path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.txt", getpid()]];
            fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0600);
        }
    }
    if (fd < 0) {
        path = [ownDocs stringByAppendingPathComponent:@"madeira-ext-log.txt"];
        fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0600);
    }
    if (fd >= 0) { dup2(fd, STDERR_FILENO); close(fd); }
    setvbuf(stderr, NULL, _IONBF, 0);
    ph_log_t0 = CACurrentMediaTime();
    return fd >= 0 ? path : nil;
}

// Fatal signals before Wine's own handlers exist. ntdll's signal init (signal_arm64_ios.c)
// replaces SIGSEGV/SIGBUS/SIGABRT/SIGILL/SIGTRAP/SIGFPE with Wine's handlers, whose fault
// output then lands in this same file. Async-signal-safe output only, then the default action.
static const int ph_fatal_signals[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
static void ph_fatal_signal(int sig, siginfo_t *info, void *context) {
    char buf[256];
    unsigned long long pc = 0;
    ucontext_t *uc = context;
    if (uc && uc->uc_mcontext) pc = (unsigned long long)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    int n = snprintf(buf, sizeof buf, "[ext-crash] ml1333 signal %d addr=%p pc=0x%llx code=%d thread mach id %u; backtrace:\n",
                     sig, info ? info->si_addr : NULL, pc, info ? info->si_code : 0, pthread_mach_thread_np(pthread_self()));
    if (n > 0) write(STDERR_FILENO, buf, (size_t)MIN(n, (int)sizeof buf - 1));
    void *frames[32];
    int count = backtrace(frames, 32);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    signal(sig, SIG_DFL);
    raise(sig);
}

// Objective-C exceptions nothing catches (Wine does not replace this one).
static void ph_uncaught_exception(NSException *exception) {
    ph_log("[ext-crash] ml1333 uncaught Objective-C exception %s: %s (thread mach id %u)",
           exception.name.UTF8String ?: "?", exception.reason.UTF8String ?: "(no reason)",
           pthread_mach_thread_np(pthread_self()));
    NSArray<NSString *> *symbols = exception.callStackSymbols;
    for (NSUInteger i = 0; i < symbols.count && i < 24; i++) ph_log("[ext-crash] ml1333   %s", symbols[i].UTF8String ?: "?");
}

static void ph_install_crash_handlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = ph_fatal_signal;
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < sizeof ph_fatal_signals / sizeof ph_fatal_signals[0]; i++)
        sigaction(ph_fatal_signals[i], &action, NULL);
    NSSetUncaughtExceptionHandler(ph_uncaught_exception);
}

// process_ios.c stamps every accepted spawn through winios_phase (ProcessHostStubs.c).
void madeira_process_host_phase(const char *name) {
    static unsigned logs;
    if (name && __atomic_fetch_add(&logs, 1, __ATOMIC_RELAXED) < 64) ph_log("ml1333 phase %s", name);
}

static uint64_t ph_footprint(void);
static unsigned ph_thread_count(void) {
    thread_act_array_t list;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &list, &n) != KERN_SUCCESS) return 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), list[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof(*list));
    return n;
}

// What __wine_main is about to use, then a heartbeat through the first seconds, so a
// silent death is bracketed in time (the last "alive" line before the end of the file).
static void ph_log_start_milestones(int argc, char **argv) {
    for (int i = 0; i < argc && i < 8; i++) ph_log("ml1333 start argv[%d]=%s", i, argv[i] ? argv[i] : "(null)");
    char cwd[1024];
    ph_log("ml1333 start cwd=%s", getcwd(cwd, sizeof cwd) ? cwd : "(unknown)");
    const char *prefix = getenv("WINEPREFIX"), *dlls = getenv("WINEDLLPATH"), *sock = getenv("WINESERVERSOCKET");
    NSFileManager *fm = NSFileManager.defaultManager;
    if (prefix) {
        NSString *p = @(prefix);
        NSString *c = [fm destinationOfSymbolicLinkAtPath:[p stringByAppendingPathComponent:@"dosdevices/c:"] error:nil];
        ph_log("ml1333 start prefix=%s exists=%d system.reg=%d c:->%s drive_c=%d", prefix,
               [fm fileExistsAtPath:p], [fm isReadableFileAtPath:[p stringByAppendingPathComponent:@"system.reg"]],
               c.UTF8String ?: "(none)", [fm fileExistsAtPath:[p stringByAppendingPathComponent:@"drive_c/windows/system32"]]);
    } else ph_log("ml1333 start WINEPREFIX unset");
    if (dlls) {
        NSString *d = @(dlls);
        for (NSString *arch in @[@"aarch64-windows", @"arm64ec-windows", @"i386-windows"]) {
            NSString *ntdll = [[d stringByAppendingPathComponent:arch] stringByAppendingPathComponent:@"ntdll.dll"];
            ph_log("ml1333 start ntdll %s readable=%d", arch.UTF8String, [fm isReadableFileAtPath:ntdll]);
        }
    } else ph_log("ml1333 start WINEDLLPATH unset");
    int fd = sock ? atoi(sock) : -1;
    ph_log("ml1333 start server socket fd=%d open=%d desktop=%s fastsync=%s footprint=%lluMB available=%zuMB threads=%u",
           fd, fd >= 0 && fcntl(fd, F_GETFD) != -1, getenv("MADEIRA_DESKTOP") ?: "(unset)",
           getenv("MADEIRA_FASTSYNC") ?: "(unset)", ph_footprint() >> 20, (size_t)os_proc_available_memory() >> 20,
           ph_thread_count());
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        static const unsigned marks[] = { 50, 100, 200, 400, 800, 1600, 3200, 6400 };
        double t0 = CACurrentMediaTime();
        for (size_t i = 0; i < sizeof marks / sizeof marks[0]; i++) {
            double wait = t0 + marks[i] / 1000.0 - CACurrentMediaTime();
            if (wait > 0) usleep((useconds_t)(wait * 1e6));
            ph_log("ml1333 alive +%ums footprint=%lluMB available=%zuMB threads=%u", marks[i], ph_footprint() >> 20,
                   (size_t)os_proc_available_memory() >> 20, ph_thread_count());
        }
    });
}

static uint64_t ph_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

// FEX host feature probe, exactly as WineProcessBridge.m publishes it for the app's
// guest (the ARM64EC module reads FEX_MADEIRA_HOSTPROBE).
static void ph_publish_host_probe(void) {
    static const struct { const char *key, *sysctl; } probes[] = {
        { "AFP", "hw.optional.arm.FEAT_AFP" }, { "FLAGM", "hw.optional.arm.FEAT_FlagM" },
        { "FLAGM2", "hw.optional.arm.FEAT_FlagM2" }, { "FCMA", "hw.optional.arm.FEAT_FCMA" },
        { "RCPC", "hw.optional.arm.FEAT_LRCPC" }, { "LRCPC2", "hw.optional.arm.FEAT_LRCPC2" },
        { "AES", "hw.optional.arm.FEAT_AES" }, { "PMULL", "hw.optional.arm.FEAT_PMULL" },
        { "SHA", "hw.optional.arm.FEAT_SHA256" }, { "CRC", "hw.optional.armv8_crc32" },
        { "ATOMICS", "hw.optional.arm.FEAT_LSE" },
    };
    char buf[256]; size_t len = 0; buf[0] = 0;
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        int32_t v = 0; size_t sz = sizeof(v);
        const char *val = sysctlbyname(probes[i].sysctl, &v, &sz, NULL, 0) == 0 ? (v ? "1" : "0") : "?";
        len += snprintf(buf + len, sizeof(buf) - len, "%s%s=%s", i ? "," : "", probes[i].key, val);
        if (len >= sizeof(buf)) return;
    }
    setenv("FEX_MADEIRA_HOSTPROBE", buf, 1);
}

static void *ph_control_thread(void *arg) {
    int fd=(int)(intptr_t)arg;
    // Allocate before any client thread can be suspended; no malloc in the RPC loop.
    unsigned char *payload=calloc(1,PH_CONTROL_LIMIT);
    PHControlRequest request;
    while (payload && ph_control_transfer(fd,&request,sizeof request,0)) {
        if(request.version!=PH_CONTROL_VERSION || request.length>PH_CONTROL_LIMIT)break;
        if((request.op==PH_WRITE || request.op==PH_SET_CONTEXT) &&
           !ph_control_transfer(fd,payload,request.length,0))break;
        request.status=ios_process_host_control(&request,payload);
        if(!ph_control_transfer(fd,&request,sizeof request,1))break;
        if(!request.status && (request.op==PH_READ || request.op==PH_GET_CONTEXT) &&
           !ph_control_transfer(fd,payload,request.length,1))break;
    }
    shutdown(fd,SHUT_RDWR); close(fd); free(payload);
    return NULL;
}

#pragma mark - The server object

@interface PHServer : NSObject <PHProcessServer>
@property (nonatomic, weak) NSXPCConnection *connection;
@end

@implementation PHServer {
    char **_argv;
    int _argc;
    int _serverFD;
    BOOL _prepared;
    BOOL _started;
    int _controlFD;
    size_t _poolMB;
}

- (instancetype)init {
    if ((self=[super init])) { _serverFD=-1; _controlFD=-1; }
    return self;
}
- (void)abortGuest {
    if(_serverFD>=0)shutdown(_serverFD,SHUT_RDWR);
    if(_controlFD>=0)shutdown(_controlFD,SHUT_RDWR);
}
- (void)clientLog:(NSString *)line {
    id<PHProcessClient> client = (id<PHProcessClient>)self.connection.remoteObjectProxy;
    @try { [client log:line]; } @catch (__unused id e) {}
    NSLog(@"[ext-proc] ml1330 %@", line);
    ph_log("%s", line.UTF8String ?: "");   // ml1333: also in the shared-container log
}

- (void)statusWithReply:(void (^)(int, uint64_t, uint64_t))reply {
    reply(getpid(), ph_footprint(), os_proc_available_memory());
}

// Set up the JIT pool from this process's OWN debugger (the app enabled JIT for this
// pid before calling us), its RW alias, and publish WINE_IOS_JIT_* in this process's
// OWN environment (competitor patch 0036: never inherited from the parent).
// Returns YES and fills rx/rw/size on success.
- (BOOL)setUpPoolRX:(void **)rxOut RW:(void **)rwOut size:(size_t *)sizeOut {
    const size_t size = _poolMB * 1024 * 1024;   // phase-1 test pool; the app uses far more
    if (!jit_check_debugged()) {
        [self clientLog:@"JIT pool: CS_DEBUGGED not set — the app did not enable JIT for this extension"];
        return NO;
    }
    // FEX dispatcher encoding needs a high pool base (StikJITHelper uses >= 0x119000000);
    // here we simply re-roll a few times rather than steering the allocator.
    void *rx = NULL;
    for (int attempt = 0; attempt < 4; attempt++) {
        void *p = jit26_prepare_region(NULL, size);
        if (!p) continue;
        if ((uintptr_t)p >= 0x119000000ull) { rx = p; break; }
        vm_deallocate(mach_task_self(), (vm_address_t)p, size);   // too low, let it go
    }
    if (!rx) { [self clientLog:@"JIT pool: the debugger did not return a usable RX region"]; return NO; }

    vm_address_t rw = 0; vm_prot_t cur = 0, max = 0;
    kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE,
                                mach_task_self(), (vm_address_t)rx, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) { [self clientLog:[NSString stringWithFormat:@"JIT pool: vm_remap kr=%d", kr]]; return NO; }
    if (vm_protect(mach_task_self(), rw, size, FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
        vm_deallocate(mach_task_self(), rw, size);
        [self clientLog:@"JIT pool: vm_protect RW failed"];
        return NO;
    }
    char v[32];
    snprintf(v, sizeof v, "%lx", (unsigned long)(uintptr_t)rx); setenv("WINE_IOS_JIT_RX", v, 1);
    snprintf(v, sizeof v, "%lx", (unsigned long)rw);            setenv("WINE_IOS_JIT_RW", v, 1);
    snprintf(v, sizeof v, "%lx", (unsigned long)size);          setenv("WINE_IOS_JIT_SIZE", v, 1);
    *rxOut = rx; *rwOut = (void *)rw; *sizeOut = size;
    [self clientLog:[NSString stringWithFormat:@"JIT pool: RX=%p RW=0x%lx size=%zuMB", rx, (unsigned long)rw, size >> 20]];
    return YES;
}

- (void)prepareGuest:(xpc_object_t)info reply:(void (^)(xpc_object_t))reply {
    xpc_object_t result = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(result, PH_REPLY_PID, getpid());
    xpc_dictionary_set_int64(result, PH_REPLY_STAGE, PHStageStarted);

    const char *prefix = xpc_dictionary_get_string(info, PH_INFO_PREFIX);
    const char *bundle = xpc_dictionary_get_string(info, PH_INFO_BUNDLE);
    const char *nls = xpc_dictionary_get_string(info, PH_INFO_NLS);
    int fd = xpc_dictionary_dup_fd(info, PH_INFO_FD);
    if (fd < 0 || !prefix || !*prefix) {
        xpc_dictionary_set_bool(result, PH_REPLY_OK, false);
        xpc_dictionary_set_string(result, PH_REPLY_ERROR, "missing server socket or prefix");
        reply(result); return;
    }
    _serverFD = fd;
    _controlFD=xpc_dictionary_dup_fd(info,PH_INFO_CONTROL);
    if (_controlFD < 0) { close(fd); xpc_dictionary_set_string(result,PH_REPLY_ERROR,"missing control socket"); reply(result); return; }
    int noSigPipe=1; setsockopt(_controlFD,SOL_SOCKET,SO_NOSIGPIPE,&noSigPipe,sizeof noSigPipe);
    const char *group=xpc_dictionary_get_string(info,PH_INFO_GROUP);
    if (!group || ![NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@(group)]) {
        close(fd); close(_controlFD);
        xpc_dictionary_set_string(result,PH_REPLY_ERROR,"extension cannot resolve the shared container"); reply(result); return;
    }
    int cwd=xpc_dictionary_get_value(info,PH_INFO_CWD) ? xpc_dictionary_dup_fd(info,PH_INFO_CWD) : -1;
    if (cwd>=0) { fchdir(cwd); close(cwd); }
    pthread_t control;
    if (pthread_create(&control,NULL,ph_control_thread,(void *)(intptr_t)_controlFD)) {
        close(fd); close(_controlFD); xpc_dictionary_set_string(result,PH_REPLY_ERROR,"control thread failed"); reply(result); return;
    }
    pthread_detach(control);

    // The extension cannot access the app's Documents directory. ml1333: its log goes
    // to the shared container, where the app can read it (ph_open_log). Wine's own log
    // lines also go to stderr, so wine_log_set_file is not used (it would double them).
    NSString *ownDocs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *log=ph_open_log([NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@(group)],ownDocs);
    ph_install_crash_handlers();
    ph_log("ml1333 extension pid=%d log=%s; crash handlers installed until ntdll installs its own",
           getpid(),log.UTF8String ?: "(none)");
    setenv("MADEIRA_DOCS_DIR",ownDocs.UTF8String,1);
    size_t cfgSize=0; const void *cfg=xpc_dictionary_get_data(info,"cfg",&cfgSize);
    if(cfg && cfgSize<=65536) [[NSData dataWithBytes:cfg length:cfgSize] writeToFile:[ownDocs stringByAppendingPathComponent:@"madeira.cfg"] atomically:YES];
    else [NSFileManager.defaultManager removeItemAtPath:[ownDocs stringByAppendingPathComponent:@"madeira.cfg"] error:nil];

    // Set up the JIT pool from this process's own debugger before any env that depends on it.
    void *rx = NULL, *rw = NULL; size_t sz = 0;
    _poolMB=(size_t)xpc_dictionary_get_int64(info,"pool_mb");
    if(_poolMB<128 || _poolMB>1152)_poolMB=512;
    BOOL pool = [self setUpPoolRX:&rx RW:&rw size:&sz];
    xpc_dictionary_set_int64(result, PH_REPLY_STAGE, pool ? PHStageJITPool : PHStageStarted);

    // Base environment for the Wine client.
    setenv("MADEIRA_EXT_PROCESS_ROLE", "host", 1);   // server_ios.c marks this a remote instance
    setenv("WINEPREFIX", prefix, 1);
    setenv("HOME", prefix, 1);
    setenv("WINELOADERNOEXEC", "1", 1);
    if (bundle && *bundle) setenv("WINEDLLPATH", bundle, 1);
    if (nls && *nls) wineserver_set_nls_dir(nls);
    char fds[16]; snprintf(fds, sizeof fds, "%d", _serverFD);
    setenv("WINESERVERSOCKET", fds, 1);
    setenv("WINEDEBUG", "err+all,err-virtual", 0);
    ph_publish_host_probe();

    // Transfer only independent native options. The caller has refused madsync;
    // server-side fastsync may remain enabled. Pool/socket/prefix values are owned here.
    xpc_object_t xenv = xpc_dictionary_get_value(info, PH_INFO_ENV);
    if (xenv && xpc_get_type(xenv) == XPC_TYPE_ARRAY) {
        xpc_array_apply(xenv, ^bool(size_t i, xpc_object_t v) {
            const char *s = xpc_string_get_string_ptr(v);
            if (s && strncmp(s,"WINE_IOS_JIT_",13) && strncmp(s,"WINESERVERSOCKET=",17) &&
                strncmp(s,"WINE_IOS_FD_SOCKET=",19) && strncmp(s,"MADEIRA_EXT_PROCESS_ROLE=",24) &&
                strncmp(s,"WINEPREFIX=",11) && strncmp(s,"HOME=",5) && strncmp(s,"MADEIRA_DOCS_DIR=",17)) { char *eq = strchr(s, '='); if (eq) { char k[128];
                size_t kl = (size_t)(eq - s); if (kl < sizeof k) { memcpy(k, s, kl); k[kl] = 0; setenv(k, eq + 1, 1); } } }
            return true;
        });
    }

    // Client-side cells live in the app's image and are not shared across tasks.
    // The app server may keep its cells: this client uses ordinary server requests.
    setenv("MADEIRA_FASTSYNC","0",1);

    // ml1332: frame transport, and the session's surface mode for the win32u driver
    // (desktop sessions give every window a GDI surface that reaches winios_surface_present).
    ph_frames_on =xpc_dictionary_get_value(info, PH_INFO_FRAMES) && xpc_dictionary_get_bool(info, PH_INFO_FRAMES);
    const char *desktop = xpc_dictionary_get_string(info, PH_INFO_DESKTOP);
    if (desktop && *desktop) setenv("MADEIRA_DESKTOP", desktop, 1);

    // Save argv for startGuest.
    xpc_object_t xargv = xpc_dictionary_get_value(info, PH_INFO_ARGV);
    _argc = (xargv && xpc_get_type(xargv) == XPC_TYPE_ARRAY) ? (int)xpc_array_get_count(xargv) : 0;
    if (_argc > 0) {
        _argv = calloc(_argc + 1, sizeof(char *));
        for (int i = 0; i < _argc; i++) _argv[i] = strdup(xpc_array_get_string(xargv, i) ?: "");
    }
    ios_main_image_i386 = 0;   // phase-1 test guest is 64-bit (cmd.exe)
    _prepared = pool && (_argc > 0);
    if (!_prepared || _started) { shutdown(_serverFD,SHUT_RDWR); close(_serverFD); _serverFD=-1; shutdown(_controlFD,SHUT_RDWR); }

    xpc_dictionary_set_int64(result, PH_REPLY_STAGE, _prepared ? PHStageEnvReady : PHStageJITPool);
    xpc_dictionary_set_bool(result, PH_REPLY_OK, pool && _prepared);
    if (!pool) xpc_dictionary_set_string(result, PH_REPLY_ERROR, "JIT pool not available (enable JIT for the extension)");
    else if (!_prepared) xpc_dictionary_set_string(result, PH_REPLY_ERROR, "no argv supplied");
    [self clientLog:[NSString stringWithFormat:@"prepared: pool=%d argv=%d control ready frames=%d footprint=%lluMB",
                     pool, _argc, ph_frames_on, ph_footprint() >> 20]];
    reply(result);
}

static void *ph_wine_thread(void *arg) {
    PHServer *server = (__bridge PHServer *)arg;
    @autoreleasepool {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        wine_ios_main_thread = pthread_self();
        wine_ios_exit_initialized = 1;
        int argc = server->_argc; char **argv = server->_argv;
        NSLog(@"[ext-proc] ml1330 starting __wine_main argc=%d argv[1]=%s", argc, argc > 1 ? argv[1] : "(none)");
        ph_log_start_milestones(argc, argv);   // ml1333
        ph_log("ml1333 entering __wine_main");
        if (setjmp(wine_ios_exit_jmpbuf) == 0) {
            __wine_main(argc, argv);
            ph_log("ml1333 __wine_main returned");
        } else {
            ph_log("ml1333 guest exited code=%d", wine_ios_exit_code);
        }
    }
    return NULL;
}

- (void)startGuestWithReply:(void (^)(xpc_object_t))reply {
    xpc_object_t result = xpc_dictionary_create(NULL, NULL, 0);
    if (!_prepared) {
        xpc_dictionary_set_bool(result, PH_REPLY_OK, false);
        xpc_dictionary_set_int64(result, PH_REPLY_STAGE, PHStageStarted);
        xpc_dictionary_set_string(result, PH_REPLY_ERROR, "not prepared");
        reply(result); return;
    }
    pthread_t t; pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    int rc = pthread_create(&t, &attr, ph_wine_thread, (__bridge void *)self);
    pthread_attr_destroy(&attr);
    if (rc == 0) { _started=YES; pthread_detach(t); }
    else { shutdown(_serverFD,SHUT_RDWR); close(_serverFD); _prepared=NO; }
    xpc_dictionary_set_bool(result, PH_REPLY_OK, rc == 0);
    xpc_dictionary_set_int64(result, PH_REPLY_STAGE, rc == 0 ? PHStageProcessRun : PHStageEnvReady);
    if (rc != 0) xpc_dictionary_set_string(result, PH_REPLY_ERROR, "pthread_create failed");
    [self clientLog:[NSString stringWithFormat:@"startGuest: __wine_main thread rc=%d", rc]];
    reply(result);
}

@end

static NSXPCConnection *ph_connection;
// Both executables link the same server archive. The extension has no registry
// of other tasks: its host hook can service only its own task, through the same
// dispatcher used by the control thread. The app's hook owns remote routing.
int wine_host_process_control(int pid,PHControlRequest *request,void *payload) {
    return pid == getpid() ? ios_process_host_control(request,payload) : ESRCH;
}
int wine_host_spawn_process(int argc,char **argv,int fd,int cwd,char **env) {
    @autoreleasepool {
        xpc_object_t info=xpc_dictionary_create(NULL,NULL,0);
        xpc_object_t xa=xpc_array_create(NULL,0), xe=xpc_array_create(NULL,0);
        for(int i=0;i<argc;i++)xpc_array_set_string(xa,XPC_ARRAY_APPEND,argv[i]);
        for(int i=0;env && env[i];i++)xpc_array_set_string(xe,XPC_ARRAY_APPEND,env[i]);
        xpc_dictionary_set_value(info,PH_INFO_ARGV,xa); xpc_dictionary_set_value(info,PH_INFO_ENV,xe);
        xpc_dictionary_set_fd(info,PH_INFO_FD,fd);
        if(cwd>=0)xpc_dictionary_set_fd(info,PH_INFO_CWD,cwd);
        dispatch_semaphore_t sem=dispatch_semaphore_create(0); __block BOOL ok=NO;
        id<PHProcessClient> proxy=[ph_connection remoteObjectProxyWithErrorHandler:^(NSError *e){dispatch_semaphore_signal(sem);}];
        [proxy spawnGuest:info reply:^(BOOL result){ok=result;dispatch_semaphore_signal(sem);}];
        if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC)))ok=NO;
        if(!ok)shutdown(fd,SHUT_RDWR);
        return ok;
    }
}
void madeira_process_host_window_frame(void *hwnd,int x,int y,int w,int h,int visible,int cx,int cy,int cw,int ch) {
    @autoreleasepool {
        [(id<PHProcessClient>)ph_connection.remoteObjectProxy windowChanged:@{
            @"hwnd":@((uintptr_t)hwnd),@"x":@(x),@"y":@(y),@"w":@(w),@"h":@(h),@"visible":@(visible),
            @"cx":@(cx),@"cy":@(cy),@"cw":@(cw),@"ch":@(ch)}];
    }
}
#pragma mark - ml1332 frames (docs/PROCESS_HOST.md "Phase 3: frames")

// Each presenting top-level window gets TWO IOSurfaces (BGRA, alpha forced opaque).
// The app receives both once per creation/resize (windowSurface:) and then, per frame,
// the index of the buffer that holds it (windowFrame:reply:). One frame per window is
// in flight: neither buffer is written until the app acknowledges, and its reply means
// its layer now shows that buffer, so the buffer the app shows is never written.
//
// GDI: winios_surface_present's bits are valid only during Wine's flush, so the dirty
// rect is copied into a private mirror of the window surface first. A frame then copies
// into the back buffer the region it lacks (its own stale rect: everything dirtied since
// it was last written). A flush during a flight only updates the mirror; the app's
// acknowledgement sends the newest state, so the last frame never waits for another
// Wine flush and nothing returns FALSE to Wine except an allocation failure.
//
// Metal: a swapchain in this process cannot present into the app's layer, so it gets an
// extension-owned CAMetalLayer subclass (madeira_vulkan_layer_for_hwnd and the macdrv
// shim below). Its drawables are presented normally; -[MTLCommandBuffer presentDrawable*]
// is hooked on the device's command-buffer classes to add one blit of the drawable into
// the back buffer on the same command buffer (one extra GPU copy per frame), and the
// command buffer's completion sends the frame. Presents during a flight are not copied.

typedef struct { int l, t, r, b; } PHFrameRect;
static inline BOOL ph_rect_empty(PHFrameRect r) { return r.r <= r.l || r.b <= r.t; }
static inline PHFrameRect ph_rect_union(PHFrameRect a, PHFrameRect b) {
    if (ph_rect_empty(a)) return b;
    if (ph_rect_empty(b)) return a;
    return (PHFrameRect){ MIN(a.l, b.l), MIN(a.t, b.t), MAX(a.r, b.r), MAX(a.b, b.b) };
}

@interface PHFrameWindow : NSObject {
@public
    uintptr_t hwnd;
    int kind, w, h;            // kind 0: GDI window surface, 1: Metal drawable copy
    uint32_t gen;              // new on every (re)allocation
    IOSurfaceRef surface[2];
    id<MTLTexture> texture[2]; // Metal: the IOSurface-backed copy targets
    int front, inflight;       // buffer the app shows / buffer sent, not yet acknowledged (-1 none)
    double sentAt;
    PHFrameRect stale[2];      // GDI: per buffer, the region older than the mirror
    BOOL dirty;                // GDI: the mirror changed since the last frame
    uint32_t *mirror;          // GDI: the window surface, opaque BGRA, w * 4 bytes per row
}
@end
@implementation PHFrameWindow
- (void)dealloc {
    for (int i = 0; i < 2; i++) if (surface[i]) CFRelease(surface[i]);
    free(mirror);
}
@end

static pthread_mutex_t ph_frames_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSNumber *, PHFrameWindow *> *ph_frames;
static uint32_t ph_frames_gen;
static struct { unsigned long long created, released, frames, coalesced, dropped, lost; } ph_fstat;
static unsigned ph_frame_logs;

static void ph_frames_client_log(NSString *line) {
    @try { [(id<PHProcessClient>)ph_connection.remoteObjectProxy log:line]; } @catch (__unused id e) {}
    fprintf(stderr, "[ext-proc] %s\n", line.UTF8String);
}

static IOSurfaceRef ph_surface_create(int w, int h) {
    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)w * 4);
    NSDictionary *properties = @{
        (__bridge NSString *)kIOSurfaceWidth: @(w), (__bridge NSString *)kIOSurfaceHeight: @(h),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @4, (__bridge NSString *)kIOSurfaceBytesPerRow: @(bpr),
        (__bridge NSString *)kIOSurfaceAllocSize: @(bpr * (size_t)h),
        (__bridge NSString *)kIOSurfacePixelFormat: @(0x42475241u) };   // 'BGRA'
    return IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}

// Lock held. Drops a window's buffers (the app keeps its own references until it
// processes the destroy message or a newer windowSurface:).
static void ph_frame_release_locked(PHFrameWindow *win) {
    for (int i = 0; i < 2; i++) {
        if (win->surface[i]) { CFRelease(win->surface[i]); win->surface[i] = NULL; ph_fstat.released++; }
        win->texture[i] = nil;
    }
    free(win->mirror); win->mirror = NULL;
}

static NSString *ph_frame_stats_locked(void) {
    return [NSString stringWithFormat:@"ml1332 stats windows=%lu surfaces live=%llu created=%llu released=%llu "
            "frames=%llu coalesced=%llu dropped=%llu lost=%llu", (unsigned long)ph_frames.count,
            ph_fstat.created - ph_fstat.released, ph_fstat.created, ph_fstat.released, ph_fstat.frames,
            ph_fstat.coalesced, ph_fstat.dropped, ph_fstat.lost];
}

// Lock held. The window's buffers for this kind and size, (re)allocated when either
// changed; *announce says the app must be sent the new pair before any frame.
static PHFrameWindow *ph_frame_window_locked(uintptr_t hwnd, int kind, int w, int h, BOOL *announce) {
    *announce = NO;
    if (!ph_frames) ph_frames = [NSMutableDictionary new];
    PHFrameWindow *win = ph_frames[@(hwnd)];
    if (win && win->surface[0] && win->kind == kind && win->w == w && win->h == h) return win;
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return nil;
    if (!win) {
        if (ph_frames.count >= 256) return nil;
        win = [PHFrameWindow new];
        win->hwnd = hwnd;
        ph_frames[@(hwnd)] = win;
    } else {
        ph_frame_release_locked(win);
    }
    win->kind = kind; win->w = w; win->h = h; win->gen = ++ph_frames_gen;
    win->front = win->inflight = -1;
    win->dirty = NO;
    win->stale[0] = win->stale[1] = (PHFrameRect){ 0, 0, w, h };
    for (int i = 0; i < 2; i++) {
        if (!(win->surface[i] = ph_surface_create(w, h))) {
            ph_frame_release_locked(win);
            [ph_frames removeObjectForKey:@(hwnd)];
            ph_frames_client_log([NSString stringWithFormat:@"ml1332 IOSurface %dx%d allocation failed hwnd=%p; "
                                  "this window stays black", w, h, (void *)hwnd]);
            return nil;
        }
        ph_fstat.created++;
    }
    *announce = YES;
    return win;
}

// Lock held. NSXPC encodes the IOSurfaces while sending (their public NSSecureCoding).
static void ph_frame_announce_locked(PHFrameWindow *win) {
    [(id<PHProcessClient>)ph_connection.remoteObjectProxy windowSurface:@{
        PH_FRAME_HWND: @(win->hwnd), PH_FRAME_GEN: @(win->gen), PH_FRAME_KIND: @(win->kind),
        @"w": @(win->w), @"h": @(win->h) }
        buffer0:(__bridge IOSurface *)win->surface[0] buffer1:(__bridge IOSurface *)win->surface[1]];
    if (ph_frame_logs < 64) {
        ph_frame_logs++;
        fprintf(stderr, "[ext-proc] ml1332 surface hwnd=%p %dx%d iosurface id=%u,%u (buffers 0,1) kind=%s gen=%u\n",
                (void *)win->hwnd, win->w, win->h, IOSurfaceGetID(win->surface[0]), IOSurfaceGetID(win->surface[1]),
                win->kind ? "metal" : "gdi", win->gen);
    }
}

static void ph_frame_ack(uintptr_t hwnd, uint32_t gen, int buffer);

// Lock held. One frame in flight per window; the reply is the app's acknowledgement.
static void ph_frame_send_locked(PHFrameWindow *win, int buffer, PHFrameRect r) {
    win->inflight = buffer;
    win->sentAt = CACurrentMediaTime();
    ph_fstat.frames++;
    uintptr_t hwnd = win->hwnd;
    uint32_t gen = win->gen;
    id<PHProcessClient> proxy = [ph_connection remoteObjectProxyWithErrorHandler:^(NSError *e) { (void)e; }];
    [proxy windowFrame:@{ PH_FRAME_HWND: @(hwnd), PH_FRAME_GEN: @(gen), PH_FRAME_BUFFER: @(buffer),
                          @"x": @(r.l), @"y": @(r.t), @"w": @(r.r - r.l), @"h": @(r.b - r.t) }
                 reply:^{ ph_frame_ack(hwnd, gen, buffer); }];
}

// Lock held. Bring the back buffer up to the mirror and send it.
static void ph_gdi_submit_locked(PHFrameWindow *win) {
    if (win->inflight >= 0 || !win->mirror || (!win->dirty && win->front >= 0)) return;
    int b = win->front < 0 ? 0 : 1 - win->front;
    PHFrameRect r = win->stale[b];
    if (!ph_rect_empty(r)) {
        if (IOSurfaceLock(win->surface[b], 0, NULL) != 0) return;   // kIOReturnSuccess
        uint8_t *base = IOSurfaceGetBaseAddress(win->surface[b]);
        size_t bpr = IOSurfaceGetBytesPerRow(win->surface[b]), row = (size_t)(r.r - r.l) * 4;
        for (int y = r.t; y < r.b; y++)
            memcpy(base + (size_t)y * bpr + (size_t)r.l * 4, win->mirror + (size_t)y * win->w + r.l, row);
        IOSurfaceUnlock(win->surface[b], 0, NULL);
    }
    win->stale[b] = (PHFrameRect){ 0, 0, 0, 0 };
    win->dirty = NO;
    ph_frame_send_locked(win, b, r);
}

// An acknowledgement can be lost only with the connection; after 2 s the next frame
// stops waiting for it (the app may then briefly show a buffer being written).
static void ph_frame_check_lost_locked(PHFrameWindow *win) {
    if (win->inflight >= 0 && CACurrentMediaTime() - win->sentAt > 2.0) { win->inflight = -1; ph_fstat.lost++; }
}

static void ph_frame_ack(uintptr_t hwnd, uint32_t gen, int buffer) {
    @autoreleasepool {
        pthread_mutex_lock(&ph_frames_lock);
        PHFrameWindow *win = ph_frames[@(hwnd)];
        if (win && win->gen == gen && win->inflight == buffer) {
            win->front = buffer;
            win->inflight = -1;
            if (win->kind == 0) ph_gdi_submit_locked(win);   // a flush that came during the flight
        }
        pthread_mutex_unlock(&ph_frames_lock);
    }
}

// winios_surface_present (ProcessHostStubs.c), on the flushing Wine thread with Wine's
// surface lock held: the whole 32bpp BGRX DIB (sw x sh, `stride` bytes per row) and the
// dirty rect. Returns 0 only when the mirror cannot be allocated (Wine keeps the bounds).
int madeira_process_host_gdi_present(void *hwnd, int dx, int dy, int dw, int dh,
                                     int sw, int sh, int stride, const void *bits) {
    if (!ph_frames_on || !hwnd || !bits || sw <= 0 || sh <= 0 || stride < sw * 4) return 1;
    int ok = 1;
    @autoreleasepool {
        pthread_mutex_lock(&ph_frames_lock);
        BOOL announce;
        PHFrameWindow *win = ph_frame_window_locked((uintptr_t)hwnd, 0, sw, sh, &announce);
        if (win) {
            PHFrameRect d = { MAX(dx, 0), MAX(dy, 0), MIN(dx + dw, sw), MIN(dy + dh, sh) };
            if (!win->mirror) {
                win->mirror = malloc((size_t)sw * (size_t)sh * 4);
                d = (PHFrameRect){ 0, 0, sw, sh };
            }
            if (!win->mirror) {
                ok = 0;
            } else {
                if (!ph_rect_empty(d)) {
                    // GDI's 32bpp DIB is BGRX; its alpha byte is often 0, so it is forced opaque.
                    for (int y = d.t; y < d.b; y++) {
                        const uint32_t *s = (const uint32_t *)((const uint8_t *)bits + (size_t)y * stride) + d.l;
                        uint32_t *m = win->mirror + (size_t)y * sw + d.l;
                        for (int x = 0; x < d.r - d.l; x++) m[x] = s[x] | 0xff000000u;
                    }
                    win->stale[0] = ph_rect_union(win->stale[0], d);
                    win->stale[1] = ph_rect_union(win->stale[1], d);
                    win->dirty = YES;
                }
                if (announce) ph_frame_announce_locked(win);
                ph_frame_check_lost_locked(win);
                if (win->inflight >= 0) ph_fstat.coalesced++;
                else ph_gdi_submit_locked(win);
            }
        }
        pthread_mutex_unlock(&ph_frames_lock);
    }
    return ok;
}

static NSMutableDictionary *ph_metal_layers_locked(void);

// A window was destroyed (or the process exits): free its buffers.
static void ph_frames_forget(uintptr_t hwnd, BOOL all) {
    NSString *stats = nil;
    @autoreleasepool {
        pthread_mutex_lock(&ph_frames_lock);
        NSArray<NSNumber *> *keys = all ? ph_frames.allKeys : @[ @(hwnd) ];
        BOOL any = NO;
        for (NSNumber *key in keys) {
            PHFrameWindow *win = ph_frames[key];
            if (win) { ph_frame_release_locked(win); [ph_frames removeObjectForKey:key]; any = YES; }
        }
        if (all) [ph_metal_layers_locked() removeAllObjects];
        else [ph_metal_layers_locked() removeObjectForKey:@(hwnd)];
        static unsigned logs;
        if ((any && logs++ < 32) || all) stats = ph_frame_stats_locked();
        pthread_mutex_unlock(&ph_frames_lock);
        if (stats && all) ph_frames_client_log(stats);
        else if (stats) fprintf(stderr, "[ext-proc] %s\n", stats.UTF8String);
    }
}

#pragma mark ml1332 Metal: extension-owned layers, one blit per present

@interface PHRemoteMetalLayer : CAMetalLayer
@property (nonatomic) uintptr_t phWindow;
@end
@implementation PHRemoteMetalLayer
// Each frame is copied out of the drawable, which needs a readable texture.
- (void)setFramebufferOnly:(BOOL)framebufferOnly { (void)framebufferOnly; [super setFramebufferOnly:NO]; }
@end

static NSMutableDictionary<NSNumber *, PHRemoteMetalLayer *> *ph_metal_layers;
static NSMutableDictionary *ph_metal_layers_locked(void) {
    if (!ph_metal_layers) ph_metal_layers = [NSMutableDictionary new];
    return ph_metal_layers;
}

static void ph_metal_frame_done(uintptr_t hwnd, uint32_t gen, int buffer, int w, int h, BOOL ok) {
    @autoreleasepool {
        pthread_mutex_lock(&ph_frames_lock);
        PHFrameWindow *win = ph_frames[@(hwnd)];
        if (win && win->gen == gen && win->inflight == buffer) {
            win->inflight = -1;
            if (ok) ph_frame_send_locked(win, buffer, (PHFrameRect){ 0, 0, w, h });
        }
        pthread_mutex_unlock(&ph_frames_lock);
    }
}

// Inside -[MTLCommandBuffer presentDrawable*], before the original: the drawable's
// rendering is encoded and its encoders ended (DXMT's presenter ends its encoder first),
// so a blit encoder on the same command buffer copies the finished image.
static void ph_metal_capture(id<MTLCommandBuffer> cb, id drawable) {
    if (!ph_frames_on || ![drawable conformsToProtocol:@protocol(CAMetalDrawable)]) return;
    id<CAMetalDrawable> metalDrawable = drawable;
    CAMetalLayer *layer = metalDrawable.layer;
    if (![layer isKindOfClass:PHRemoteMetalLayer.class]) return;
    id<MTLTexture> src = metalDrawable.texture;
    MTLPixelFormat format = src.pixelFormat;
    if ((format != MTLPixelFormatBGRA8Unorm && format != MTLPixelFormatBGRA8Unorm_sRGB) || src.framebufferOnly) {
        static int said;
        if (!__atomic_exchange_n(&said, 1, __ATOMIC_RELAXED))
            ph_frames_client_log([NSString stringWithFormat:@"ml1332 metal frames not copied: drawable pixel format %lu "
                                  "framebufferOnly=%d (only BGRA8 is transported)", (unsigned long)format, src.framebufferOnly]);
        return;
    }
    uintptr_t hwnd = ((PHRemoteMetalLayer *)layer).phWindow;
    int w = (int)src.width, h = (int)src.height, buffer = -1;
    uint32_t gen = 0;
    id<MTLTexture> dst = nil;
    pthread_mutex_lock(&ph_frames_lock);
    BOOL announce;
    PHFrameWindow *win = ph_frame_window_locked(hwnd, 1, w, h, &announce);
    if (win) {
        if (announce) ph_frame_announce_locked(win);
        ph_frame_check_lost_locked(win);
        if (win->inflight >= 0) {
            ph_fstat.dropped++;
        } else {
            buffer = win->front < 0 ? 0 : 1 - win->front;
            if (!win->texture[buffer] || win->texture[buffer].pixelFormat != format) {
                MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                                width:w height:h mipmapped:NO];
                desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                desc.storageMode = MTLStorageModeShared;
                win->texture[buffer] = [cb.device newTextureWithDescriptor:desc iosurface:win->surface[buffer] plane:0];
            }
            if ((dst = win->texture[buffer])) {
                win->inflight = buffer;   // reserved until the copy completes
                win->sentAt = CACurrentMediaTime();
                gen = win->gen;
            }
        }
    }
    pthread_mutex_unlock(&ph_frames_lock);
    if (!dst) return;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (!blit) { ph_metal_frame_done(hwnd, gen, buffer, w, h, NO); return; }
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)dst;   // the IOSurface texture outlives the copy
        ph_metal_frame_done(hwnd, gen, buffer, w, h, done.status == MTLCommandBufferStatusCompleted);
    }];
}

// The original IMPs, per class (a subclass of a hooked class finds its superclass's entry).
static struct { Class cls; SEL sel; IMP original; } ph_present_hooks[24];
static int ph_present_hook_count;
static IMP ph_present_original(id self, SEL sel) {
    int n = __atomic_load_n(&ph_present_hook_count, __ATOMIC_ACQUIRE);
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c))
        for (int i = 0; i < n; i++)
            if (ph_present_hooks[i].cls == c && sel_isEqual(ph_present_hooks[i].sel, sel)) return ph_present_hooks[i].original;
    return NULL;
}
static void ph_hook_present(id self, SEL cmd, id drawable) {
    ph_metal_capture(self, drawable);
    IMP original = ph_present_original(self, cmd);
    if (original) ((void (*)(id, SEL, id))original)(self, cmd, drawable);
}
static void ph_hook_present_time(id self, SEL cmd, id drawable, CFTimeInterval time) {
    ph_metal_capture(self, drawable);
    IMP original = ph_present_original(self, cmd);
    if (original) ((void (*)(id, SEL, id, CFTimeInterval))original)(self, cmd, drawable, time);
}
static void ph_hook_present_after(id self, SEL cmd, id drawable, CFTimeInterval duration) {
    ph_metal_capture(self, drawable);
    IMP original = ph_present_original(self, cmd);
    if (original) ((void (*)(id, SEL, id, CFTimeInterval))original)(self, cmd, drawable, duration);
}
static void ph_hook_command_buffer_class(Class cls) {
    const struct { SEL sel; IMP hook; } list[] = {
        { @selector(presentDrawable:), (IMP)ph_hook_present },
        { @selector(presentDrawable:atTime:), (IMP)ph_hook_present_time },
        { @selector(presentDrawable:afterMinimumDuration:), (IMP)ph_hook_present_after },
    };
    for (size_t i = 0; i < sizeof(list) / sizeof(list[0]); i++) {
        Method m = class_getInstanceMethod(cls, list[i].sel);
        int n = ph_present_hook_count;
        if (!m || n >= 24) continue;
        IMP current = method_getImplementation(m);
        if (current == list[i].hook) continue;   // inherited from a hooked superclass
        ph_present_hooks[n].cls = cls; ph_present_hooks[n].sel = list[i].sel; ph_present_hooks[n].original = current;
        __atomic_store_n(&ph_present_hook_count, n + 1, __ATOMIC_RELEASE);
        class_replaceMethod(cls, list[i].sel, list[i].hook, method_getTypeEncoding(m));
    }
}
static void ph_install_present_hooks(id<MTLDevice> device) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLCommandQueue> queue = [device newCommandQueue];
        NSMutableSet *classes = [NSMutableSet new];
        id<MTLCommandBuffer> sample = [queue commandBuffer];
        if (sample) [classes addObject:[sample class]];
        if ((sample = [queue commandBufferWithUnretainedReferences])) [classes addObject:[sample class]];
        if ((sample = [queue commandBufferWithDescriptor:[MTLCommandBufferDescriptor new]])) [classes addObject:[sample class]];
        NSMutableArray *names = [NSMutableArray new];
        for (Class cls in classes) { ph_hook_command_buffer_class(cls); [names addObject:NSStringFromClass(cls)]; }
        ph_frames_client_log([NSString stringWithFormat:@"ml1332 metal present copy hooked on %@ (%d methods)",
                              [names componentsJoinedByString:@","], ph_present_hook_count]);
    });
}

// The layer a swapchain on `hwnd` presents to in this process; nil with frames off.
static PHRemoteMetalLayer *ph_metal_layer_for_hwnd(void *hwnd) {
    if (!ph_frames_on || !hwnd) return nil;
    NSNumber *key = @((uintptr_t)hwnd);
    pthread_mutex_lock(&ph_frames_lock);
    PHRemoteMetalLayer *layer = ph_metal_layers_locked()[key];
    pthread_mutex_unlock(&ph_frames_lock);
    if (layer) return layer;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return nil;
    ph_install_present_hooks(device);
    PHRemoteMetalLayer *made = [PHRemoteMetalLayer layer];   // never in a layer tree
    made.phWindow = (uintptr_t)hwnd;
    made.device = device;
    made.pixelFormat = MTLPixelFormatBGRA8Unorm;
    made.opaque = YES;
    made.framebufferOnly = NO;
    pthread_mutex_lock(&ph_frames_lock);
    if (!(layer = ph_metal_layers_locked()[key])) ph_metal_layers_locked()[key] = layer = made;
    pthread_mutex_unlock(&ph_frames_lock);
    static unsigned logs;
    if (layer == made && __atomic_fetch_add(&logs, 1, __ATOMIC_RELAXED) < 16)
        ph_frames_client_log([NSString stringWithFormat:@"ml1332 metal layer for hwnd=%p (extension-owned; "
                              "each present is copied to the app)", hwnd]);
    return layer;
}

// winevulkan's window surfaces (build/win32u-unix/vulkan_ios.c): VK_EXT_metal_surface
// retains the layer. Frames reach the app only if the Vulkan driver presents through
// -[MTLCommandBuffer presentDrawable*].
void *madeira_vulkan_layer_for_hwnd(void *hwnd) { return (__bridge void *)ph_metal_layer_for_hwnd(hwnd); }

// DXMT's winemetal unix side looks this table up with dlsym(RTLD_DEFAULT,
// "macdrv_functions") (app/Madeira/IOSDisplayShim.m is the app's version; this is the
// extension's). `used` keeps it under dead-strip; client_cocoa_view carries the HWND.
struct ph_macdrv_win_data { void *hwnd, *cocoa_window, *cocoa_view, *client_cocoa_view; };
static struct ph_macdrv_win_data *ph_macdrv_get_win_data(void *hwnd) {
    struct ph_macdrv_win_data *data = calloc(1, sizeof *data);
    if (data) { data->hwnd = hwnd; data->cocoa_view = data->client_cocoa_view = hwnd; }
    return data;
}
static void ph_macdrv_release_win_data(struct ph_macdrv_win_data *data) { free(data); }
static void *ph_macdrv_create_device(void) { return (void *)(uintptr_t)1; }
static void ph_macdrv_release_device(void *device) { (void)device; }
static void *ph_macdrv_create_metal_view(void *view, void *device) {
    (void)device;
    PHRemoteMetalLayer *layer = ph_metal_layer_for_hwnd(view);
    return layer ? (void *)CFBridgingRetain(layer) : NULL;
}
static void *ph_macdrv_get_metal_layer(void *view) { return view; }
static void ph_macdrv_release_metal_view(void *view) { if (view) CFBridgingRelease(view); }
static void ph_macdrv_on_main_thread(dispatch_block_t block) {
    if (NSThread.isMainThread) block(); else dispatch_async(dispatch_get_main_queue(), block);
}
__attribute__((used, visibility("default")))
struct {
    void (*init_display_devices)(BOOL);
    struct ph_macdrv_win_data *(*get_win_data)(void *);
    void (*release_win_data)(struct ph_macdrv_win_data *);
    void *(*get_cocoa_window)(void *, BOOL);
    void *(*create_metal_device)(void);
    void (*release_metal_device)(void *);
    void *(*view_create_metal_view)(void *, void *);
    void *(*view_get_metal_layer)(void *);
    void (*view_release_metal_view)(void *);
    void (*on_main_thread)(dispatch_block_t);
} macdrv_functions = {
    NULL, ph_macdrv_get_win_data, ph_macdrv_release_win_data, NULL, ph_macdrv_create_device,
    ph_macdrv_release_device, ph_macdrv_create_metal_view, ph_macdrv_get_metal_layer,
    ph_macdrv_release_metal_view, ph_macdrv_on_main_thread,
};

#pragma mark ml1332 cursor

// driver_ios.c winios_drv_set_cursor (desktop sessions): a new cursor image, straight-alpha BGRA.
void madeira_process_host_cursor_image(unsigned int cursor, int w, int h, int hx, int hy, const void *bits) {
    if (!ph_frames_on || !bits || w <= 0 || h <= 0 || w > 256 || h > 256) return;
    @autoreleasepool {
        [(id<PHProcessClient>)ph_connection.remoteObjectProxy windowCursor:@{
            @"id": @(cursor), @"w": @(w), @"h": @(h), @"hx": @(hx), @"hy": @(hy),
            @"bits": [NSData dataWithBytes:bits length:(size_t)w * (size_t)h * 4] }];
    }
}
// Visibility is reported on every WM_SETCURSOR; only changes are sent.
void madeira_process_host_cursor_show(int show) {
    static int last = -1;
    show = show != 0;
    if (!ph_frames_on || __atomic_exchange_n(&last, show, __ATOMIC_RELAXED) == show) return;
    @autoreleasepool { [(id<PHProcessClient>)ph_connection.remoteObjectProxy windowCursor:@{ @"show": @(show) }]; }
}

void madeira_process_host_window_destroy(void *hwnd) {
    ph_frames_forget((uintptr_t)hwnd, NO);   // before the app drops its references
    [(id<PHProcessClient>)ph_connection.remoteObjectProxy windowChanged:@{@"hwnd":@((uintptr_t)hwnd),@"destroy":@YES}];
}
void madeira_process_host_did_exit(int status) {
    ph_frames_forget(0, YES);
    [(id<PHProcessClient>)ph_connection.remoteObjectProxy guestExited:status];
}

#pragma mark - Extension entry

@interface MadeiraProcessHostHandler : NSObject <NSExtensionRequestHandling>
@end

static PHServer *ph_server;

@implementation MadeiraProcessHostHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSXPCListenerEndpoint *endpoint = [context.inputItems.firstObject userInfo][@"endpoint"];
    if (![endpoint isKindOfClass:NSXPCListenerEndpoint.class]) {
        NSLog(@"[ext-proc] ml1330 no endpoint in the request");
        return;
    }
    if(ph_server) {
        NSLog(@"[ext-proc] ml1331 extension process reused; refusing a second Wine instance");
        [context completeRequestReturningItems:@[] completionHandler:nil];
        return;
    }
    ph_server = [PHServer new];
    ph_connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
    ph_connection.exportedInterface = PHProcessServerInterface();
    ph_connection.exportedObject = ph_server;
    ph_connection.remoteObjectInterface = PHProcessClientInterface();
    ph_server.connection = ph_connection;
    ph_connection.invalidationHandler=^{ [ph_server abortGuest]; };
    ph_connection.interruptionHandler=^{ [ph_server abortGuest]; };
    [ph_connection resume];
    [(id<PHProcessClient>)ph_connection.remoteObjectProxy extensionReady:getpid()
                                                              available:os_proc_available_memory()];
    NSLog(@"[ext-proc] ml1330 connected, pid %d, available %zuMB", getpid(), (size_t)os_proc_available_memory() >> 20);
}

@end

// An extension request's items are decoded with only property-list classes allowed,
// and NSXPCListenerEndpoint is not one; LiveContainer's LiveProcess and the donor pool
// lift the check the same way before NSExtensionMain runs.
static BOOL ph_allow_class(id self, SEL _cmd, Class cls, id key, BOOL allowingInvocations) { return YES; }

__attribute__((constructor)) static void ph_allow_endpoint_decoding(void) {
    Method method = class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"),
                                            NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:"));
    if (method) method_setImplementation(method, (IMP)ph_allow_class);
}
