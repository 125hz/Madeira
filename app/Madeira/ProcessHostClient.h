// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// ml1330 process host (docs/PROCESS_HOST.md). App-side launch of the
// MadeiraProcessHost extension and the XPC conversation with it. Exposed to Swift
// (MadeiraExtProcess.swift) through the bridging header. Objective-C because the
// handoff carries the exec-child and control file descriptors in XPC dictionaries.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One attempt to run a Wine process in the process-host extension. Each call logs
/// its own [ext-proc] ml1330 lines through the logger block. All completion blocks
/// arrive on an arbitrary queue.
@interface MadeiraProcessHostSession : NSObject

/// Lines to surface in Madeira's log (already tagged "[ext-proc] ml1330 …").
@property (nonatomic, copy, nullable) void (^logger)(NSString *line);
@property (nonatomic, copy, nullable) void (^exitHandler)(int status);

/// The extension's pid once it has started and connected back (0 before that).
@property (nonatomic, readonly) int extensionPID;

/// The app registered a private control socket for this extension pid.
@property (nonatomic, readonly) BOOL controlRegistered;

/// Start the extension (NSExtension on the app's bundle id + ".ProcessHost") and wait
/// for it to connect back. completion gets the pid, or 0 on failure.
- (void)startWithCompletion:(void (^)(int pid))completion;

/// Hand the child socket from NtCreateUserProcess and a separate control socket
/// to the extension. Both fd arguments are borrowed; no parentless connection is
/// injected. Completion reports the environment/JIT preparation stage.
- (void)prepareGuestWithArgv:(NSArray<NSString *> *)argv
                    socketFD:(int)socketFD
                 directoryFD:(int)directoryFD
                         env:(NSArray<NSString *> *)env
                      prefix:(NSString *)prefix
                  completion:(void (^)(BOOL ok, int stage, NSString *_Nullable error))completion;

/// Start __wine_main in the extension for the prepared process.
- (void)startGuestWithCompletion:(void (^)(BOOL ok, int stage, NSString *_Nullable error))completion;

/// Cancel the owned extension and close all remaining sockets.
- (void)invalidate;

@end

// ntdll calls this after the normal process gate, with its exec-child socket.
typedef void (^PHSpawnHandler)(NSArray<NSString *> *argv, NSArray<NSString *> *env,
                              int socketFD, int directoryFD, void (^done)(BOOL));
void madeira_process_host_set_spawn_handler(PHSpawnHandler _Nullable handler);
NSString *_Nullable madeira_process_host_shared_drive(NSString *prefix);
NSString *_Nullable madeira_process_host_shared_prefix(NSString *prefix);
NSString *madeira_process_host_active_prefix(NSString *prefix);
NSString *_Nullable madeira_process_host_shared_group(void);

NS_ASSUME_NONNULL_END
