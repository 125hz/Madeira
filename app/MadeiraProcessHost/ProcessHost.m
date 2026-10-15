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
// Phase 1 is HEADLESS: the guest's windows live in the app's wineserver; nothing is
// presented here (frames over IOSurface are phase 2). The feature is off unless the
// app asks (env.MADEIRA_EXT_PROCESS_TEST=1) and the whole thing is killed by
// env.MADEIRA_EXT_PROCESS=0 on the app side.
//
// Nothing here boots Wine on its own: it waits for the app's prepareGuest/startGuest.
// A full guest boot inside an extension is UNVERIFIED on device; this file is written
// to be honest and to compile/link, logging each step.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
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

    // The extension cannot access the app's Documents directory.
    NSString *ownDocs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSString *log=[ownDocs stringByAppendingPathComponent:@"madeira-ext-log.txt"];
    wine_log_set_file(log.UTF8String);
    int lf=open(log.UTF8String,O_WRONLY|O_CREAT|O_APPEND,0600);
    if(lf>=0){dup2(lf,STDERR_FILENO);close(lf);}
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
    [self clientLog:[NSString stringWithFormat:@"prepared: pool=%d argv=%d control ready footprint=%lluMB",
                     pool, _argc, ph_footprint() >> 20]];
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
        if (setjmp(wine_ios_exit_jmpbuf) == 0) {
            __wine_main(argc, argv);
            NSLog(@"[ext-proc] ml1330 __wine_main returned");
        } else {
            NSLog(@"[ext-proc] ml1330 guest exited code=%d", wine_ios_exit_code);
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
void madeira_process_host_window_destroy(void *hwnd) {
    [(id<PHProcessClient>)ph_connection.remoteObjectProxy windowChanged:@{@"hwnd":@((uintptr_t)hwnd),@"destroy":@YES}];
}
void madeira_process_host_did_exit(int status) {
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
