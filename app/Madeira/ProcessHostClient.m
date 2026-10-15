// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// ml1330 process host (docs/PROCESS_HOST.md). See ProcessHostClient.h.

#import "ProcessHostClient.h"
#import "ProcessHostProtocol.h"
#import "WineServerBridge.h"      // wineserver_inject_client_fd
#import <sys/socket.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <unistd.h>

// Registered in the wineserver (build/wineserver/mach_ios.c, in libwineserver.a).
extern int ios_remote_task_register(int unix_pid, mach_port_t task);
extern void ios_remote_task_unregister(int unix_pid);

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
    int _appSocketFD;              // the wineserver side (injected); -1 if unused
    int _extSocketFD;             // the extension side (handed over); -1 once passed
}

- (instancetype)init {
    if ((self = [super init])) {
        _connected = dispatch_semaphore_create(0);
        _appSocketFD = -1;
        _extSocketFD = -1;
        _extensionPID = 0;
        _taskPortRegistered = NO;
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
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PHProcessClient)];
    connection.exportedObject = self;
    [connection resume];
    _connection = connection;
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
    [(id<PHNSExtension>)extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        NSLog(@"[ext-proc] ml1330 extension interrupted");
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
                         env:(NSArray<NSString *> *)env
                      prefix:(NSString *)prefix
                  completion:(void (^)(BOOL, int, NSString *_Nullable))completion {
    if (!_connection) { completion(NO, 0, @"no connection to the extension"); return; }

    // The wineserver socketpair: appEnd is injected into the wineserver event loop
    // (it picks it up like wine_process_start does), extEnd is handed to the extension.
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == -1) {
        completion(NO, PHStageStarted, @"socketpair failed");
        return;
    }
    _appSocketFD = pair[0];
    _extSocketFD = pair[1];
    wineserver_inject_client_fd(_appSocketFD);
    [self emit:[NSString stringWithFormat:@"server socketpair: app=%d ext=%d (injected app end)", pair[0], pair[1]]];

    xpc_object_t info = xpc_dictionary_create(NULL, NULL, 0);
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
    for (NSString *e in env) xpc_array_set_string(xenv, XPC_ARRAY_APPEND, e.UTF8String ?: "");
    xpc_dictionary_set_value(info, PH_INFO_ENV, xenv);
    xpc_dictionary_set_fd(info, PH_INFO_FD, _extSocketFD);

    id<PHProcessServer> proxy = [_connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
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
        // Task-port transfer: real on platforms that allow sending a task port; a
        // documented host-routed fallback (stub) otherwise.
        mach_port_t task = xpc_dictionary_copy_mach_send(result, PH_REPLY_TASK);
        BOOL taskOk = xpc_dictionary_get_bool(result, PH_REPLY_TASKOK);
        if (s && task != MACH_PORT_NULL && pid > 0 && ios_remote_task_register(pid, task)) {
            s->_taskPortRegistered = YES;
            [s emit:[NSString stringWithFormat:@"task port yes (registered for pid=%d); remote memory is direct", pid]];
        } else if (s) {
            if (task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), task);
            [s emit:[NSString stringWithFormat:@"task port no (sent=%d); thread/memory ops are host-routed (phase-1 stub)",
                     taskOk]];
        }
        if (s) [s emit:[NSString stringWithFormat:@"pool mapped / server connected: ok=%d stage=%d%s%s",
                        ok, stage, err && *err ? " error=" : "", err && *err ? err : ""]];
        completion(ok, stage, err ? [NSString stringWithUTF8String:err] : nil);
    }];
}

- (void)startGuestWithCompletion:(void (^)(BOOL, int, NSString *_Nullable))completion {
    if (!_connection) { completion(NO, 0, @"no connection to the extension"); return; }
    id<PHProcessServer> proxy = [_connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
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

- (void)invalidate {
    if (_extensionPID > 0 && _taskPortRegistered) ios_remote_task_unregister(_extensionPID);
    if (_appSocketFD >= 0) { /* owned by the wineserver now; leave it */ }
    if (_extSocketFD >= 0) { close(_extSocketFD); _extSocketFD = -1; }
    [_connection invalidate];
    _connection = nil;
}

@end
