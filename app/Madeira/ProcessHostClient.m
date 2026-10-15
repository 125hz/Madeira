// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// ml1330 process host (docs/PROCESS_HOST.md). See ProcessHostClient.h.

#import "ProcessHostClient.h"
#import "ProcessHostProtocol.h"
#import "WineServerBridge.h"
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>
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

// ml1333: a C string from Wine (argv, a Windows environment block) as an NSString.
// @(cstr) is nil for NULL or non-UTF-8 bytes, and inserting nil into a collection
// threw on a Wine thread (log prev(6): explorer's desktop thread died, the session
// ended). UTF-8 first, else Latin-1, which accepts every byte. NULL stays nil.
static NSString *ph_string(const char *s) {
    if (!s) return nil;
    size_t n = strlen(s);
    NSString *r = [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding];
    return r ?: [[NSString alloc] initWithBytes:s length:n encoding:NSISOLatin1StringEncoding];
}

// ml1333: an Objective-C exception nothing catches (for instance one thrown on a
// Wine thread, where unwinding then fails) is written to the session log before
// the process dies. Chains to a handler installed earlier, if any.
static NSUncaughtExceptionHandler *ph_previous_exception_handler;
static void ph_uncaught_exception(NSException *exception) {
    @try {
        fprintf(stderr, "[crash] ml1333 uncaught Objective-C exception %s: %s (thread mach id %u%s)\n",
                exception.name.UTF8String ?: "?", exception.reason.UTF8String ?: "(no reason)",
                pthread_mach_thread_np(pthread_self()), NSThread.isMainThread ? ", main" : "");
        NSArray<NSString *> *symbols = exception.callStackSymbols;
        for (NSUInteger i = 0; i < symbols.count && i < 24; i++)
            fprintf(stderr, "[crash] ml1333   %s\n", symbols[i].UTF8String ?: "?");
        fflush(stderr);
    } @catch (__unused id e) {}
    if (ph_previous_exception_handler) ph_previous_exception_handler(exception);
}
__attribute__((constructor)) static void ph_install_exception_logger(void) {
    NSUncaughtExceptionHandler *previous = NSGetUncaughtExceptionHandler();
    if (previous == ph_uncaught_exception) return;
    ph_previous_exception_handler = previous;
    NSSetUncaughtExceptionHandler(ph_uncaught_exception);
}

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
        for (int i=0;i<argc;i++) { NSString *s=ph_string(argv[i]); [args addObject:s ?: @""]; }   // keep argv positions
        for (int i=0;env && env[i];i++) { NSString *s=ph_string(env[i]); if(s)[environment addObject:s]; }
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

// ml1332 frames (docs/PROCESS_HOST.md "Phase 3: frames"). A remote window's two
// IOSurfaces, as the extension last announced them. Guarded by the class lock.
@interface PHRemoteSurface : NSObject
@property (nonatomic, strong) IOSurface *buffer0, *buffer1;
@property (nonatomic) int width, height, kind;
@property (nonatomic) uint32_t generation;
@end
@implementation PHRemoteSurface
@end
static NSMutableDictionary<NSNumber *, PHRemoteSurface *> *ph_surfaces;   // hwnd -> buffers
static NSMutableSet<NSNumber *> *ph_remote_windows;                        // hwnds owned by extension clients
static unsigned long long ph_surfaces_received, ph_surfaces_dropped, ph_frames_shown;
static unsigned ph_surface_logs, ph_frame_logs;

// WiniosWindowed.m (any thread): this top-level window belongs to an extension client.
int madeira_process_host_is_remote_window(void *hwnd) {
    @synchronized(MadeiraProcessHostSession.class) {
        return [ph_remote_windows containsObject:@((uintptr_t)hwnd)] ? 1 : 0;
    }
}

// Class lock held. The app's references to a window's buffers go; CA releases the
// one its layer shows when the layer is removed (winios_pDestroyWindow).
static void ph_drop_surface_locked(NSNumber *hwnd) {
    if (ph_surfaces[hwnd]) { [ph_surfaces removeObjectForKey:hwnd]; ph_surfaces_dropped += 2; }
}
static NSString *ph_surface_stats_locked(void) {
    return [NSString stringWithFormat:@"[ext-proc] ml1332 stats remote windows=%lu surfaces live=%llu received=%llu "
            "dropped=%llu frames=%llu", (unsigned long)ph_remote_windows.count,
            ph_surfaces_received - ph_surfaces_dropped, ph_surfaces_received, ph_surfaces_dropped, ph_frames_shown];
}
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
    NSMutableSet<NSNumber *> *_windows;   // ml1332: this extension's top-level windows (class lock)
    BOOL _extLogRead;                     // ml1333: its shared-container log was appended once
}

// ml1333: the extension writes its stderr (Wine's own output, its milestones, fatal
// signals and uncaught exceptions) to <shared>/ext-logs/<pid>.txt. When the extension
// is interrupted or its guest exits, that file goes into this session's log as
// "[ext-proc] ml1333 ext log: ..." (the first 60 and last 140 lines of a longer file).
- (void)appendExtensionLog:(NSString *)why {
    int pid=_extensionPID;
    @synchronized(self) { if (_extLogRead || pid <= 0) return; _extLogRead=YES; }
    NSString *shared;
    @synchronized(MadeiraProcessHostSession.class) { shared=ph_shared; }
    NSString *path=shared ? [[shared stringByAppendingPathComponent:@"ext-logs"]
                             stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.txt",pid]] : nil;
    NSData *data=path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data) {
        fprintf(stderr,"[ext-proc] ml1333 ext log pid=%d (%s): no file%s%s\n",pid,why.UTF8String ?: "",
                path ? " at " : " (no shared container)",path ? path.UTF8String : "");
        return;
    }
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                   ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
    NSMutableArray<NSString *> *lines=[[text componentsSeparatedByString:@"\n"] mutableCopy];
    while (lines.count && !lines.lastObject.length) [lines removeLastObject];
    NSUInteger total=lines.count;
    fprintf(stderr,"[ext-proc] ml1333 ext log pid=%d (%s): %lu lines, %lu bytes, %s\n",pid,why.UTF8String ?: "",
            (unsigned long)total,(unsigned long)data.length,path.UTF8String);
    for (NSUInteger i=0;i<total;i++) {
        if (total>200 && i==60) {
            fprintf(stderr,"[ext-proc] ml1333 ext log: ... %lu lines omitted ...\n",(unsigned long)(total-200));
            i=total-140;
        }
        NSString *line=[lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        if (line.length>400) line=[[line substringToIndex:400] stringByAppendingString:@" ..."];
        fprintf(stderr,"[ext-proc] ml1333 ext log: %s\n",line.UTF8String ?: "");
    }
    fflush(stderr);
}

- (instancetype)init {
    if ((self = [super init])) {
        _windows = [NSMutableSet new];
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
    connection.interruptionHandler=^{ [weakSelf appendExtensionLog:@"connection interrupted"]; [weakSelf invalidate]; };
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
        [interruptSelf appendExtensionLog:@"interrupted"];
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
            xpc_array_set_string(xenv,XPC_ARRAY_APPEND,e.UTF8String ?: "");
    }
    xpc_dictionary_set_value(info, PH_INFO_ENV, xenv);
    xpc_dictionary_set_fd(info, PH_INFO_FD, _extSocketFD);
    xpc_dictionary_set_fd(info, PH_INFO_CONTROL, pair[1]); close(pair[1]);
    if (directoryFD >= 0) xpc_dictionary_set_fd(info, PH_INFO_CWD, directoryFD);
    NSString *group=madeira_process_host_shared_group();
    if (group) xpc_dictionary_set_string(info,PH_INFO_GROUP,group.UTF8String);
    // MADEIRA_EXT_PROCESS_FRAMES=0: extension clients' windows stay black (no IOSurface frames, ml1332).
    xpc_dictionary_set_bool(info,PH_INFO_FRAMES,flag("MADEIRA_EXT_PROCESS_FRAMES",true));
    const char *desktop=getenv("MADEIRA_DESKTOP");
    if (desktop) xpc_dictionary_set_string(info,PH_INFO_DESKTOP,desktop);

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
        if(xpc_get_type(v)==XPC_TYPE_STRING) { NSString *s=ph_string(xpc_string_get_string_ptr(v)); [argv addObject:s ?: @""]; }
        return true; });
    if (xe && xpc_get_type(xe)==XPC_TYPE_ARRAY) xpc_array_apply(xe,^bool(size_t i,xpc_object_t v){
        if(xpc_get_type(v)==XPC_TYPE_STRING) { NSString *s=ph_string(xpc_string_get_string_ptr(v)); if(s)[env addObject:s]; }
        return true; });
    if (!handler || fd < 0 || !argv.count) { if(fd>=0)close(fd); if(cwd>=0)close(cwd); reply(NO); return; }
    handler(argv,env,fd,cwd,^(BOOL ok){
        if(!ok)shutdown(fd,SHUT_RDWR);
        close(fd); if(cwd>=0)close(cwd); reply(ok);
    });
}
- (void)windowChanged:(NSDictionary *)window {
    NSNumber *hwnd=window[@"hwnd"];
    if(![hwnd isKindOfClass:NSNumber.class] || !hwnd.unsignedLongLongValue)return;
    NSString *stats=nil;
    @synchronized(MadeiraProcessHostSession.class) {
        if(!ph_window_changes)ph_window_changes=[NSMutableDictionary new];
        if(ph_window_changes.count<512 || ph_window_changes[hwnd])ph_window_changes[hwnd]=window;
        if(!ph_remote_windows)ph_remote_windows=[NSMutableSet new];
        if([window[@"destroy"] boolValue]) {
            BOOL had=ph_surfaces[hwnd]!=nil;
            ph_drop_surface_locked(hwnd);
            [ph_remote_windows removeObject:hwnd]; [_windows removeObject:hwnd];
            static unsigned logs;
            if(had && logs++<32) stats=ph_surface_stats_locked();
        } else if(ph_remote_windows.count<1024) {
            [ph_remote_windows addObject:hwnd]; [_windows addObject:hwnd];
        }
    }
    if(stats) fprintf(stderr,"%s (window destroyed)\n",stats.UTF8String);
}

// ml1332: a remote window's (re)allocated buffer pair.
- (void)windowSurface:(NSDictionary *)info buffer0:(IOSurface *)buffer0 buffer1:(IOSurface *)buffer1 {
    NSNumber *hwnd=info[PH_FRAME_HWND];
    if(![hwnd isKindOfClass:NSNumber.class] || !hwnd.unsignedLongLongValue ||
       ![buffer0 isKindOfClass:IOSurface.class] || ![buffer1 isKindOfClass:IOSurface.class])return;
    PHRemoteSurface *surface=[PHRemoteSurface new];
    surface.buffer0=buffer0; surface.buffer1=buffer1;
    surface.width=[info[@"w"] intValue]; surface.height=[info[@"h"] intValue];
    surface.kind=[info[PH_FRAME_KIND] intValue]; surface.generation=[info[PH_FRAME_GEN] unsignedIntValue];
    BOOL log=NO;
    @synchronized(MadeiraProcessHostSession.class) {
        if(!ph_surfaces)ph_surfaces=[NSMutableDictionary new];
        if(!ph_remote_windows)ph_remote_windows=[NSMutableSet new];
        if(!ph_surfaces[hwnd] && ph_surfaces.count>=256)return;
        ph_drop_surface_locked(hwnd);
        ph_surfaces[hwnd]=surface; ph_surfaces_received+=2;
        [ph_remote_windows addObject:hwnd]; [_windows addObject:hwnd];
        log=ph_surface_logs++<64;
    }
    if(log)
        fprintf(stderr,"[ext-proc] ml1332 surface hwnd=%p %dx%d iosurface id=%u,%u (buffers 0,1) kind=%s gen=%u\n",
                (void *)(uintptr_t)hwnd.unsignedLongLongValue,surface.width,surface.height,
                IOSurfaceGetID((__bridge IOSurfaceRef)buffer0),IOSurfaceGetID((__bridge IOSurfaceRef)buffer1),
                surface.kind ? "metal" : "gdi",surface.generation);
}

// ml1332: one buffer holds a complete frame. The reply (the extension's permission
// to write the other buffer again) goes once Core Animation has the new contents.
- (void)windowFrame:(NSDictionary *)frame reply:(void (^)(void))reply {
    NSNumber *hwnd=frame[PH_FRAME_HWND];
    int buffer=[frame[PH_FRAME_BUFFER] intValue];
    PHRemoteSurface *surface=nil;
    BOOL log=NO;
    @synchronized(MadeiraProcessHostSession.class) {
        if([hwnd isKindOfClass:NSNumber.class]) surface=ph_surfaces[hwnd];
        if(surface && surface.generation==[frame[PH_FRAME_GEN] unsignedIntValue] && (buffer==0 || buffer==1)) {
            ph_frames_shown++;
            log=ph_frame_logs<400 && (ph_frame_logs++<96 || ph_frames_shown%256==0);
        } else surface=nil;
    }
    if(!surface) { reply(); return; }
    IOSurface *contents=buffer ? surface.buffer1 : surface.buffer0;
    void *window=(void *)(uintptr_t)hwnd.unsignedLongLongValue;
    if(log)
        fprintf(stderr,"[ext-proc] ml1332 frame hwnd=%p buffer %d dirty %d,%d %dx%d (#%llu)\n",window,buffer,
                [frame[@"x"] intValue],[frame[@"y"] intValue],[frame[@"w"] intValue],[frame[@"h"] intValue],ph_frames_shown);
    dispatch_async(dispatch_get_main_queue(), ^{
        // A destroy that overtook this frame leaves no layer to recreate.
        if(!madeira_process_host_is_remote_window(window)) { reply(); return; }
        extern void winios_remote_surface_frame(void *,void *,int,int,int);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setCompletionBlock:^{ reply(); }];
        winios_remote_surface_frame(window,(__bridge void *)contents,surface.width,surface.height,surface.kind);
        [CATransaction commit];
    });
}

// ml1332: the remote process's cursor (driver_ios.c winios_drv_set_cursor there).
- (void)windowCursor:(NSDictionary *)cursor {
    extern void winios_cursor_set(unsigned int,int,int,int,int,const void *);
    extern void winios_cursor_show(int);
    NSData *bits=cursor[@"bits"];
    int w=[cursor[@"w"] intValue], h=[cursor[@"h"] intValue];
    if([bits isKindOfClass:NSData.class]) {
        if(w>0 && h>0 && w<=256 && h<=256 && bits.length==(NSUInteger)w*h*4)
            winios_cursor_set([cursor[@"id"] unsignedIntValue],w,h,[cursor[@"hx"] intValue],[cursor[@"hy"] intValue],bits.bytes);
    } else if([cursor[@"show"] isKindOfClass:NSNumber.class]) {
        winios_cursor_show([cursor[@"show"] intValue]);
    }
}
- (void)guestExited:(int)status {
    [self emit:[NSString stringWithFormat:@"exit code %d",status]];
    [self appendExtensionLog:[NSString stringWithFormat:@"exit code %d",status]];
    if (self.exitHandler) self.exitHandler(status);
    [self invalidate];
}
- (void)invalidate {
    // ml1332: windows of an extension that ended without destroying them lose their
    // buffers and, through the Wine-thread pump, their layers and windowed frames.
    NSString *stats=nil;
    @synchronized(MadeiraProcessHostSession.class) {
        if(_windows.count || _extensionPID) {
            if(!ph_window_changes)ph_window_changes=[NSMutableDictionary new];
            for(NSNumber *hwnd in _windows) {
                ph_drop_surface_locked(hwnd);
                [ph_remote_windows removeObject:hwnd];
                ph_window_changes[hwnd]=@{@"hwnd":hwnd,@"destroy":@YES};
            }
            if(_windows.count || _controlRegistered) stats=ph_surface_stats_locked();
            [_windows removeAllObjects];
        }
    }
    if(stats) fprintf(stderr,"%s (session pid=%d ended)\n",stats.UTF8String,_extensionPID);
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
