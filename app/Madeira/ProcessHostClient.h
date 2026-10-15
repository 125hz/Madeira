// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// ml1330 process host (docs/PROCESS_HOST.md). App-side launch of the
// MadeiraProcessHost extension and the XPC conversation with it. Exposed to Swift
// (MadeiraExtProcess.swift) through the bridging header. Objective-C because the
// handoff carries a file descriptor and a Mach send right, which travel in xpc
// dictionaries the way the donor pool's MemoryHost does.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One attempt to run a Wine process in the process-host extension. Each call logs
/// its own [ext-proc] ml1330 lines through the logger block. All completion blocks
/// arrive on an arbitrary queue.
@interface MadeiraProcessHostSession : NSObject

/// Lines to surface in Madeira's log (already tagged "[ext-proc] ml1330 …").
@property (nonatomic, copy, nullable) void (^logger)(NSString *line);

/// The extension's pid once it has started and connected back (0 before that).
@property (nonatomic, readonly) int extensionPID;

/// Whether the extension's task port reached the app (false → thread/memory ops are
/// host-routed, which is a documented phase-1 stub).
@property (nonatomic, readonly) BOOL taskPortRegistered;

/// Start the extension (NSExtension on the app's bundle id + ".ProcessHost") and wait
/// for it to connect back. completion gets the pid, or 0 on failure.
- (void)startWithCompletion:(void (^)(int pid))completion;

/// Create the wineserver socketpair, inject the app end into the wineserver, and ask
/// the extension to set up its JIT pool and environment with the other end plus the
/// given argv/env. Registers the extension's task port with the wineserver if it
/// arrived. completion's ok is YES when the extension reached the env-ready stage.
- (void)prepareGuestWithArgv:(NSArray<NSString *> *)argv
                         env:(NSArray<NSString *> *)env
                      prefix:(NSString *)prefix
                  completion:(void (^)(BOOL ok, int stage, NSString *_Nullable error))completion;

/// Start __wine_main in the extension for the prepared process.
- (void)startGuestWithCompletion:(void (^)(BOOL ok, int stage, NSString *_Nullable error))completion;

/// Tear down the XPC connection (does not kill a running guest).
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
