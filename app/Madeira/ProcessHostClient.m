// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// ml1330 process host (docs/PROCESS_HOST.md). See ProcessHostClient.h.

#import "ProcessHostClient.h"
#import "ProcessHostProtocol.h"
#import "WineServerBridge.h"
#import <sys/socket.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <unistd.h>
#import <pthread.h>
#include <stdbool.h>
#import "ProcessHostControl.h"
#include "../../build/madeira_cfg.h"

static pthread_mutex_t ph_control_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { int pid, fd; unsigned int logs; } ph_controls[64];
static PHSpawnHandler ph_spawn_handler;

void madeira_process_host_set_spawn_handler(PHSpawnHandler handler) {
    @synchronized(MadeiraProcessHostSession.class) { ph_spawn_handler = [handler copy]; }
}

static int ph_register(int pid, int fd) {
    int slot = -1;
    pthread_mutex_lock(&ph_control_lock);
    for (int i=0;i<64;i++) if (ph_controls[i].pid==pid) {
        pthread_mutex_unlock(&ph_control_lock); return 0; // extension pid reuse cannot host another Wine instance
    }
    for (int i=0;i<64;i++) if (!ph_controls[i].pid) { slot=i; break; }
    if (slot >= 0) { ph_controls[slot].pid=pid; ph_controls[slot].fd=fd; ph_controls[slot].logs=0; }
    pthread_mutex_unlock(&ph_control_lock);
    return slot >= 0;
}
static void ph_unregister(int pid) {
    pthread_mutex_lock(&ph_control_lock);
    for (int i=0;i<64;i++) if (ph_controls[i].pid == pid) {
        shutdown(ph_controls[i].fd, SHUT_RDWR); close(ph_controls[i].fd); ph_controls[i].pid=0;
    }
    pthread_mutex_unlock(&ph_control_lock);
}

int wine_host_process_control(int pid, PHControlRequest *request, void *payload) {
    int error=ESRCH;
    pthread_mutex_lock(&ph_control_lock);
    for (int i=0;i<64;i++) if (ph_controls[i].pid == pid) {
        int fd=ph_controls[i].fd;
        uint32_t total=request->length, offset=0;
        error=0;
        do {
            PHControlRequest r=*request;
            int memory = r.op == PH_READ || r.op == PH_WRITE;
            if (memory) { r.address += offset; r.length=MIN(total-offset, PH_CONTROL_LIMIT); }
            if (r.length > PH_CONTROL_LIMIT) { error=EINVAL; break; }
            unsigned char *p=payload ? (unsigned char *)payload+offset : NULL;
            if (!ph_control_transfer(fd,&r,sizeof r,1) ||
                ((r.op==PH_WRITE || r.op==PH_SET_CONTEXT) && !ph_control_transfer(fd,p,r.length,1))) {
                error=EPIPE; break;
            }
            PHControlRequest response;
            if (!ph_control_transfer(fd,&response,sizeof response,0) ||
                response.version!=r.version || response.op!=r.op || response.length!=r.length) {
                error=EPIPE; break;
            }
            error=response.status;
            if (!error && (r.op==PH_READ || r.op==PH_GET_CONTEXT) &&
                !ph_control_transfer(fd,p,r.length,0)) { error=EPIPE; break; }
            request->frame=response.frame; request->sequence=response.sequence;
            if (error || !memory) break;
            offset += r.length;
        } while (offset < total);
        if (error==EPIPE) shutdown(fd,SHUT_RDWR); // partial frame cannot be reused
        if (ph_controls[i].logs++ < 48)
            fprintf(stderr,"[ext-proc] ml1331 remote %s pid=%d tid=%u -> %s (%d)\n",
                    ph_control_name(request->op),pid,request->tid,error ? "error" : "ok",error);
        break;
    }
    pthread_mutex_unlock(&ph_control_lock);
    return error;
}

// Called on the spawning Wine thread. The async Swift pipeline runs elsewhere;
// timeout shuts down every duplicate of the exec-child socket, waking process_info.
int wine_host_spawn_process(int argc, char **argv, int socketFD, int directoryFD, char **env) {
    @autoreleasepool {
        PHSpawnHandler handler;
        @synchronized(MadeiraProcessHostSession.class) { handler=ph_spawn_handler; }
        if (!handler) return 0;
        NSMutableArray *args=[NSMutableArray new], *environment=[NSMutableArray new];
        for (int i=0;i<argc;i++) [args addObject:@(argv[i])];
        for (int i=0;env && env[i];i++) [environment addObject:@(env[i])];
        int fd=dup(socketFD), cwd=directoryFD < 0 ? -1 : dup(directoryFD);
        if (fd < 0 || (directoryFD >= 0 && cwd < 0)) { if(fd>=0)close(fd); return 0; }
        dispatch_semaphore_t sem=dispatch_semaphore_create(0);
        __block BOOL ok=NO;
        handler(args,environment,fd,cwd,^(BOOL result){ ok=result; dispatch_semaphore_signal(sem); });
        BOOL timedOut=dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC)) != 0;
        if (timedOut || !ok) shutdown(fd,SHUT_RDWR);
        close(fd); if(cwd>=0)close(cwd);
        return !timedOut && ok;
    }
}

static NSString *ph_group;
static NSString *ph_shared;
static NSString *ph_prefix;
static NSString *ph_original;

static BOOL flag(const char *name, BOOL fallback) {
    char key[160], cfg[64]; snprintf(key,sizeof key,"env.%s",name);
    if(madeira_cfg_get(key,cfg,sizeof cfg))return strcmp(cfg,"0") != 0;
    const char *value=getenv(name);
    return value ? strcmp(value,"0") != 0 : fallback;
}

NSString *madeira_process_host_shared_group(void) { @synchronized(MadeiraProcessHostSession.class) { return ph_group; } }

NSString *madeira_process_host_shared_drive(NSString *prefix) {
    // MADEIRA_SHARED_DRIVE=1 opts into storage readable by every app entitled to
    // this group (including SideStore). Default off; no private files are moved.
    if (!flag("MADEIRA_SHARED_DRIVE", false)) return nil;
    @synchronized(MadeiraProcessHostSession.class) {
        if (!ph_shared) {
            NSMutableArray *groups=[NSMutableArray new];
            void *security=dlopen("/System/Library/Frameworks/Security.framework/Security",RTLD_NOW);
            CFTypeRef (*create)(CFAllocatorRef)=dlsym(security ?: RTLD_DEFAULT,"SecTaskCreateFromSelf");
            CFTypeRef (*value)(CFTypeRef,CFStringRef,CFErrorRef *)=dlsym(security ?: RTLD_DEFAULT,"SecTaskCopyValueForEntitlement");
            CFTypeRef task=create ? create(NULL) : NULL;
            if (task && value) {
                CFTypeRef v=value(task,CFSTR("com.apple.security.application-groups"),NULL);
                if(v) { if(CFGetTypeID(v)==CFArrayGetTypeID()) [groups addObjectsFromArray:(__bridge NSArray *)v]; CFRelease(v); }
            }
            if(task)CFRelease(task);
            [groups addObject:@"group.com.SideStore.SideStore"];
            for(id group in groups) if([group isKindOfClass:NSString.class]) {
                NSURL *container=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
                if(container) { ph_group=[group copy]; ph_shared=[[container.path stringByAppendingPathComponent:@"madeira-shared"] copy]; break; }
            }
            fprintf(stderr,"[ext-proc] ml1331 shared container: %s\n",ph_shared.UTF8String ?: "none");
        }
        if (!ph_shared) return nil;
        NSError *error=nil;
        if(![NSFileManager.defaultManager createDirectoryAtPath:ph_shared withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]) return nil;
        NSString *devices=[prefix stringByAppendingPathComponent:@"dosdevices"];
        [NSFileManager.defaultManager createDirectoryAtPath:devices withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *link=[devices stringByAppendingPathComponent:@"d:"];
        NSString *existing=[NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:link error:nil];
        if(existing && ![existing isEqualToString:ph_shared]) {
            fprintf(stderr,"[ext-proc] ml1331 D: already mapped; shared drive refused\n"); return nil;
        }
        if(!existing && ![NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:ph_shared error:&error]) return nil;
        return ph_shared;
    }
}

NSString *madeira_process_host_shared_prefix(NSString *prefix) {
    // MADEIRA_EXT_PROCESS=1 enables app-extension Wine clients; default off.
    if(!flag("MADEIRA_EXT_PROCESS", false) || !flag("MADEIRA_SHARED_DRIVE", false)) return nil;
    @synchronized(MadeiraProcessHostSession.class) {
        if(ph_prefix && [ph_original isEqualToString:prefix]) return ph_prefix;
        NSString *shared=madeira_process_host_shared_drive(prefix);
        if(!shared)return nil;
        NSString *target=[shared stringByAppendingPathComponent:@"prefix"];
        NSFileManager *fm=NSFileManager.defaultManager;
        NSError *error=nil;
        if(![fm fileExistsAtPath:target]) {
            // A separate persistent prefix: copy once, preserve the private original.
            // C: and registry paths then agree for server and every client; Wine also
            // opens files locally, so serving handles alone is insufficient.
            extern void madeira_seed_prefix_if_needed(const char *);
            madeira_seed_prefix_if_needed(prefix.UTF8String);
            extern int wineserver_is_running(void);
            if(wineserver_is_running()) { fprintf(stderr,"[ext-proc] ml1331 shared prefix copy refused during a running session\n"); return nil; }
            NSString *stage=[shared stringByAppendingPathComponent:[@"prefix-stage-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            if(![fm createDirectoryAtPath:stage withIntermediateDirectories:NO attributes:nil error:&error])return nil;
            for(NSString *name in [fm contentsOfDirectoryAtPath:prefix error:&error]) {
                if([name isEqualToString:@".wineserver"])continue;
                if(![fm copyItemAtPath:[prefix stringByAppendingPathComponent:name] toPath:[stage stringByAppendingPathComponent:name] error:&error])break;
            }
            if(error) {
                [fm removeItemAtPath:stage error:nil];
                fprintf(stderr,"[ext-proc] ml1331 shared prefix copy failed (%ld)\n",(long)error.code); return nil;
            }
            // c: is relative, z: points at the common Unix namespace. d: is rebuilt
            // after the copy; absolute system32 bundle links remain valid.
            NSString *devices=[stage stringByAppendingPathComponent:@"dosdevices"];
            for(NSString *drive in @[@"c:",@"d:"]) [fm removeItemAtPath:[devices stringByAppendingPathComponent:drive] error:nil];
            [fm createSymbolicLinkAtPath:[devices stringByAppendingPathComponent:@"c:"] withDestinationPath:@"../drive_c" error:nil];
            if(![fm moveItemAtPath:stage toPath:target error:&error]) {
                [fm removeItemAtPath:stage error:nil]; return nil;
            }
        }
        if(!madeira_process_host_shared_drive(target)) return nil;
        ph_original=[prefix copy]; ph_prefix=[target copy];
        fprintf(stderr,"[ext-proc] ml1331 shared prefix ready (private prefix preserved)\n");
        return ph_prefix;
    }
}

NSString *madeira_process_host_active_prefix(NSString *prefix) {
    if(!flag("MADEIRA_EXT_PROCESS", false) || !flag("MADEIRA_SHARED_DRIVE", false))return prefix;
    @synchronized(MadeiraProcessHostSession.class) {
        if(ph_prefix && [ph_original isEqualToString:prefix])return ph_prefix;
        NSString *shared=madeira_process_host_shared_drive(prefix);
        NSString *target=[shared stringByAppendingPathComponent:@"prefix"];
        return target && [NSFileManager.defaultManager fileExistsAtPath:target] ? target : prefix;
    }
}

static NSMutableDictionary<NSNumber *,NSDictionary *> *ph_window_changes;
// Wine-thread pump: metadata queries need a valid TEB, never an XPC worker.
void madeira_process_host_pump_windows(void) {
    NSArray *changes;
    @synchronized(MadeiraProcessHostSession.class) { changes=ph_window_changes.allValues; [ph_window_changes removeAllObjects]; }
    extern void winios_window_frame(void *,int,int,int,int,int,int,int,int,int);
    extern void winios_pDestroyWindow(void *);
    for(NSDictionary *window in changes) {
        void *hwnd=(void *)(uintptr_t)[window[@"hwnd"] unsignedLongLongValue];
        if([window[@"destroy"] boolValue]) { winios_pDestroyWindow(hwnd); continue; }
        winios_window_frame(hwnd,[window[@"x"] intValue],[window[@"y"] intValue],[window[@"w"] intValue],
            [window[@"h"] intValue],[window[@"visible"] intValue],[window[@"cx"] intValue],
            [window[@"cy"] intValue],[window[@"cw"] intValue],[window[@"ch"] intValue]);
    }
}

// The private NSExtension API (ExtensionFoundation), the same calls LiveContainer's
// LiveProcess and the donor pool (DonorPool.m) use to start a Madeira-owned extension.
@protocol PHNSExtensionClass
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
@end
@protocol PHNSExtension
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *identifier))completion;
- (void)cancelExtensionRequestWithIdentifier:(NSUUID *)identifier;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *identifier))block;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
@end

@interface MadeiraProcessHostSession () <NSXPCListenerDelegate, PHProcessClient>
@end

@implementation MadeiraProcessHostSession {
    id _extension;                 // the NSExtension, kept alive for the request
    NSUUID *_request;
    NSXPCListener *_listener;
    NSXPCConnection *_connection;  // the connection the extension made back
    dispatch_semaphore_t _connected;
    int _controlFD;
    int _extSocketFD;             // the extension side (handed over); -1 once passed
}

- (instancetype)init {
    if ((self = [super init])) {
        _connected = dispatch_semaphore_create(0);
        _controlFD = -1;
        _extSocketFD = -1;
        _extensionPID = 0;
        _controlRegistered = NO;
    }
    return self;
}

- (void)emit:(NSString *)line {
    if (self.logger) self.logger(line);
    NSLog(@"[ext-proc] ml1330 %@", line);
}

#pragma mark - PHProcessClient (the extension calls these)

- (void)extensionReady:(int)pid available:(uint64_t)available {
    _extensionPID = pid;
    [self emit:[NSString stringWithFormat:@"extension started pid=%d available=%lluMB", pid, available >> 20]];
    dispatch_semaphore_signal(_connected);
}

- (void)log:(NSString *)line {
    [self emit:[NSString stringWithFormat:@"ext: %@", line]];
}

#pragma mark - NSXPCListenerDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.remoteObjectInterface = PHProcessServerInterface();
    connection.exportedInterface = PHProcessClientInterface();
    connection.exportedObject = self;
    [connection resume];
    _connection = connection;
    __weak typeof(self) weakSelf=self;
    connection.interruptionHandler=^{ [weakSelf invalidate]; };
    connection.invalidationHandler=^{ [weakSelf invalidate]; };
    return YES;
}

#pragma mark - Launch

- (void)startWithCompletion:(void (^)(int pid))completion {
    NSString *identifier = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".ProcessHost"];
    Class<PHNSExtensionClass> cls = (Class<PHNSExtensionClass>)NSClassFromString(@"NSExtension");
    if (!cls) {
        // ExtensionFoundation may not be loaded yet.
        dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
        cls = (Class<PHNSExtensionClass>)NSClassFromString(@"NSExtension");
    }
    NSError *err = nil;
    id extension = cls ? [cls extensionWithIdentifier:identifier error:&err] : nil;
    if (!extension) {
        [self emit:[NSString stringWithFormat:@"no extension %@ (%@)", identifier,
                    err.localizedDescription ?: @"unavailable"]];
        completion(0);
        return;
    }
    _extension = extension;
    __weak typeof(self) interruptSelf=self;
    [(id<PHNSExtension>)extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [interruptSelf emit:@"extension interrupted"];
        [interruptSelf invalidate];
    }];

    _listener = [NSXPCListener anonymousListener];
    _listener.delegate = self;
    [_listener resume];

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{ @"endpoint": _listener.endpoint };
    __weak typeof(self) weakSelf = self;
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    [(id<PHNSExtension>)extension beginExtensionRequestWithInputItems:@[item]
                                                          completion:^(NSUUID *uuid) {
        typeof(self) s = weakSelf;
        if (s) s->_request = uuid;
        dispatch_semaphore_signal(started);
    }];

    const int64_t timeout = 15 * NSEC_PER_SEC;
    if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, timeout)) || !_request) {
        [self emit:@"extension did not start"];
        completion(0);
        return;
    }
    if (dispatch_semaphore_wait(_connected, dispatch_time(DISPATCH_TIME_NOW, timeout))) {
        [self emit:@"extension started but did not connect back"];
        completion(0);
        return;
    }
    completion(_extensionPID);
}

#pragma mark - Prepare / start the guest

- (void)prepareGuestWithArgv:(NSArray<NSString *> *)argv
                    socketFD:(int)socketFD
                 directoryFD:(int)directoryFD
                         env:(NSArray<NSString *> *)env
                      prefix:(NSString *)prefix
                  completion:(void (^)(BOOL, int, NSString *_Nullable))completion {
    if (!_connection) { completion(NO, 0, @"no connection to the extension"); return; }

    _extSocketFD=dup(socketFD);
    int pair[2];
    if (_extSocketFD < 0 || socketpair(AF_UNIX,SOCK_STREAM,0,pair)) {
        [self invalidate]; completion(NO,PHStageStarted,@"socket duplication failed"); return;
    }
    _controlFD=pair[0];
    int noSigPipe=1; struct timeval timeout={10,0};
    setsockopt(_controlFD,SOL_SOCKET,SO_NOSIGPIPE,&noSigPipe,sizeof noSigPipe);
    setsockopt(_controlFD,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);
    setsockopt(_controlFD,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof timeout);
    if (!ph_register(_extensionPID,_controlFD)) {
        close(pair[1]); close(_controlFD); _controlFD=-1;
        [self invalidate]; completion(NO,PHStageStarted,@"control registry full or extension pid reused"); return;
    }
    _controlRegistered=YES;
    xpc_object_t info = xpc_dictionary_create(NULL, NULL, 0);
    NSData *cfg=[NSData dataWithContentsOfFile:[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"madeira.cfg"]];
    if(cfg && cfg.length <= 65536) xpc_dictionary_set_data(info,"cfg",cfg.bytes,cfg.length);
    // MADEIRA_EXT_PROCESS_POOL_MB: private image/JIT pool in each extension (128..1152 MiB, default 512).
    xpc_dictionary_set_int64(info,"pool_mb",madeira_cfg_int("env.MADEIRA_EXT_PROCESS_POOL_MB",512));
    xpc_dictionary_set_string(info, PH_INFO_PREFIX, prefix.UTF8String ?: "");
    xpc_dictionary_set_string(info, PH_INFO_BUNDLE, NSBundle.mainBundle.bundlePath.UTF8String ?: "");
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    xpc_dictionary_set_string(info, PH_INFO_DOCS, docs.UTF8String ?: "");
    xpc_dictionary_set_string(info, PH_INFO_NLS,
                              [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"nls"].UTF8String ?: "");
    xpc_object_t xargv = xpc_array_create(NULL, 0);
    for (NSString *a in argv) xpc_array_set_string(xargv, XPC_ARRAY_APPEND, a.UTF8String ?: "");
    xpc_dictionary_set_value(info, PH_INFO_ARGV, xargv);
    xpc_object_t xenv = xpc_array_create(NULL, 0);
    for (NSString *e in env) {
        if (([e hasPrefix:@"MADEIRA_"] || [e hasPrefix:@"FEX_"] || [e hasPrefix:@"WINEDEBUG="]) &&
            ![e hasPrefix:@"MADEIRA_DOCS_DIR="] && ![e hasPrefix:@"MADEIRA_CFG_GAME="] &&
            ![e hasPrefix:@"MADEIRA_JIT"] && ![e hasPrefix:@"MADEIRA_DONOR"])
            xpc_array_set_string(xenv,XPC_ARRAY_APPEND,e.UTF8String);
    }
    xpc_dictionary_set_value(info, PH_INFO_ENV, xenv);
    xpc_dictionary_set_fd(info, PH_INFO_FD, _extSocketFD);
    xpc_dictionary_set_fd(info, PH_INFO_CONTROL, pair[1]); close(pair[1]);
    if (directoryFD >= 0) xpc_dictionary_set_fd(info, PH_INFO_CWD, directoryFD);
    NSString *group=madeira_process_host_shared_group();
    if (group) xpc_dictionary_set_string(info,PH_INFO_GROUP,group.UTF8String);

    id<PHProcessServer> proxy = [_connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
        [self invalidate];
        completion(NO, PHStageStarted, e.localizedDescription);
    }];
    __weak typeof(self) weakSelf = self;
    [proxy prepareGuest:info reply:^(xpc_object_t result) {
        typeof(self) s = weakSelf;
        // The extension holds its own dup of the fd now.
        if (s && s->_extSocketFD >= 0) { close(s->_extSocketFD); s->_extSocketFD = -1; }
        BOOL ok = xpc_dictionary_get_bool(result, PH_REPLY_OK);
        int stage = (int)xpc_dictionary_get_int64(result, PH_REPLY_STAGE);
        int pid = (int)xpc_dictionary_get_int64(result, PH_REPLY_PID);
        const char *err = xpc_dictionary_get_string(result, PH_REPLY_ERROR);
        if (!ok) [s invalidate];
        else [s emit:[NSString stringWithFormat:@"ml1331 control socket registered pid=%d",pid]];
        if (s) [s emit:[NSString stringWithFormat:@"pool mapped / server connected: ok=%d stage=%d%s%s",
                        ok, stage, err && *err ? " error=" : "", err && *err ? err : ""]];
        completion(ok, stage, err ? [NSString stringWithUTF8String:err] : nil);
    }];
}

- (void)startGuestWithCompletion:(void (^)(BOOL, int, NSString *_Nullable))completion {
    if (!_connection) { completion(NO, 0, @"no connection to the extension"); return; }
    id<PHProcessServer> proxy = [_connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
        [self invalidate];
        completion(NO, PHStageEnvReady, e.localizedDescription);
    }];
    __weak typeof(self) weakSelf = self;
    [proxy startGuestWithReply:^(xpc_object_t result) {
        typeof(self) s = weakSelf;
        BOOL ok = xpc_dictionary_get_bool(result, PH_REPLY_OK);
        int stage = (int)xpc_dictionary_get_int64(result, PH_REPLY_STAGE);
        const char *err = xpc_dictionary_get_string(result, PH_REPLY_ERROR);
        if (s) [s emit:[NSString stringWithFormat:@"process started: ok=%d stage=%d", ok, stage]];
        completion(ok, stage, err ? [NSString stringWithUTF8String:err] : nil);
    }];
}

- (void)spawnGuest:(xpc_object_t)info reply:(void (^)(BOOL))reply {
    PHSpawnHandler handler;
    @synchronized(MadeiraProcessHostSession.class) { handler=ph_spawn_handler; }
    int fd=xpc_dictionary_dup_fd(info,PH_INFO_FD);
    int cwd=xpc_dictionary_get_value(info,PH_INFO_CWD) ? xpc_dictionary_dup_fd(info,PH_INFO_CWD) : -1;
    NSMutableArray *argv=[NSMutableArray new], *env=[NSMutableArray new];
    xpc_object_t xa=xpc_dictionary_get_value(info,PH_INFO_ARGV), xe=xpc_dictionary_get_value(info,PH_INFO_ENV);
    if (xa && xpc_get_type(xa)==XPC_TYPE_ARRAY) xpc_array_apply(xa,^bool(size_t i,xpc_object_t v){
        if(xpc_get_type(v)==XPC_TYPE_STRING) [argv addObject:@(xpc_string_get_string_ptr(v))]; return true; });
    if (xe && xpc_get_type(xe)==XPC_TYPE_ARRAY) xpc_array_apply(xe,^bool(size_t i,xpc_object_t v){
        if(xpc_get_type(v)==XPC_TYPE_STRING) [env addObject:@(xpc_string_get_string_ptr(v))]; return true; });
    if (!handler || fd < 0 || !argv.count) { if(fd>=0)close(fd); if(cwd>=0)close(cwd); reply(NO); return; }
    handler(argv,env,fd,cwd,^(BOOL ok){
        if(!ok)shutdown(fd,SHUT_RDWR);
        close(fd); if(cwd>=0)close(cwd); reply(ok);
    });
}
- (void)windowChanged:(NSDictionary *)window {
    NSNumber *hwnd=window[@"hwnd"];
    if(![hwnd isKindOfClass:NSNumber.class] || !hwnd.unsignedLongLongValue)return;
    @synchronized(MadeiraProcessHostSession.class) {
        if(!ph_window_changes)ph_window_changes=[NSMutableDictionary new];
        if(ph_window_changes.count<512 || ph_window_changes[hwnd])ph_window_changes[hwnd]=window;
    }
}
- (void)guestExited:(int)status {
    [self emit:[NSString stringWithFormat:@"exit code %d",status]];
    if (self.exitHandler) self.exitHandler(status);
    [self invalidate];
}
- (void)invalidate {
    @synchronized(self) {
        if (_controlRegistered) { ph_unregister(_extensionPID); _controlRegistered=NO; _controlFD=-1; }
        if (_extSocketFD>=0) { shutdown(_extSocketFD,SHUT_RDWR); close(_extSocketFD); _extSocketFD=-1; }
        NSXPCConnection *connection=_connection; _connection=nil;
        connection.invalidationHandler=nil; connection.interruptionHandler=nil;
        [connection invalidate];
        if (_request) { [(id<PHNSExtension>)_extension cancelExtensionRequestWithIdentifier:_request]; _request=nil; }
        [_listener invalidate]; _listener=nil;
    }
}
@end
