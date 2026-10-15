// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// ml1330 process host (docs/PROCESS_HOST.md). The XPC contract shared by Madeira
// and its MadeiraProcessHost app extension, which runs ONE Wine process in its own
// iOS task and connects it to the wineserver in the app. Modelled on the donor
// pool's MemoryHostProtocol.h: the extension connects back to an anonymous listener
// endpoint the app passes in the NSExtension request, the app is the XPC client,
// and the extension exports the server object.
//
// ml1331: the owned extension has a dedicated control socket. Window geometry
// is forwarded to the app; IOSurface presentation is deferred to phase 3.
// Both MADEIRA_EXT_PROCESS and MADEIRA_SHARED_DRIVE default off.

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>

// Keys in the prepareGuest info dictionary (an xpc dictionary, so it can carry the
// socket fd by value).
#define PH_INFO_PREFIX   "prefix"   // string: the Wine prefix path (…/Documents/wine)
#define PH_INFO_BUNDLE   "bundle"   // string: the app bundle path (WINEDLLPATH / gl dir)
#define PH_INFO_DOCS     "docs"     // string: the app Documents dir (MADEIRA_DOCS_DIR, logs)
#define PH_INFO_NLS      "nls"      // string: the bundle's nls dir
#define PH_INFO_ARGV     "argv"     // xpc array of strings: argv for __wine_main (argv[0]="wine")
#define PH_INFO_ENV      "env"      // xpc array of "KEY=VALUE" strings exported before Wine
#define PH_INFO_CONTROL "control" // dedicated control socket (no task-port transfer)
#define PH_INFO_CWD "cwd" // inherited working directory, passed as an fd
#define PH_INFO_GROUP "group" // app group the extension must resolve before opening the shared prefix
#define PH_INFO_FD       "fd"       // the wineserver client socket (xpc_dictionary_set_fd)

// Keys in a reply dictionary.
#define PH_REPLY_OK      "ok"       // bool
#define PH_REPLY_PID     "pid"      // int64: the extension process pid
#define PH_REPLY_STAGE   "stage"    // int64: how far it got (see PHStage)
#define PH_REPLY_ERROR   "error"    // string: a human message when ok is false
typedef NS_ENUM(int, PHStage) {
    PHStageStarted      = 1,   // extension running, connected back
    PHStageJITPool      = 2,   // JIT pool mapped in the extension
    PHStageEnvReady     = 3,   // environment + server socket set
    PHStageServerBound  = 4,   // (reserved) client bound to the wineserver
    PHStageProcessRun   = 5,   // __wine_main started
    PHStageExited       = 6,   // the guest process returned
};

// The extension exports this; the app calls it.
@protocol PHProcessServer
/// The extension's pid, phys_footprint and os_proc_available_memory().
- (void)statusWithReply:(void (^)(int pid, uint64_t footprint, uint64_t available))reply;
/// Set up the JIT pool and the environment for one Wine process (does not start it).
/// `info` carries the prefix/bundle/argv/env and the wineserver client fd. The reply
/// carries the extension's pid, control-service readiness and the stage reached.
- (void)prepareGuest:(xpc_object_t)info reply:(void (^)(xpc_object_t result))reply;
/// Start __wine_main for the prepared process. Called after the app has registered
/// the control socket with the wineserver, so remote memory/thread ops are ready.
- (void)startGuestWithReply:(void (^)(xpc_object_t result))reply;
@end

// The app exports this; the extension calls extensionReady first (an NSXPCConnection
// made from an endpoint reaches the listener only with its first message).
@protocol PHProcessClient
- (void)extensionReady:(int)pid available:(uint64_t)available;
/// A line the extension wants shown in Madeira's log (prefixed [ext-proc] there).
- (void)log:(NSString *)line;
- (void)spawnGuest:(xpc_object_t)info reply:(void (^)(BOOL ok))reply;
- (void)guestExited:(int)status;
- (void)windowChanged:(NSDictionary *)window;
@end

static inline NSXPCInterface *PHProcessServerInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(PHProcessServer)];
    [interface setXPCType:XPC_TYPE_DICTIONARY forSelector:@selector(prepareGuest:reply:)
             argumentIndex:0 ofReply:NO];
    [interface setXPCType:XPC_TYPE_DICTIONARY forSelector:@selector(prepareGuest:reply:)
             argumentIndex:0 ofReply:YES];
    [interface setXPCType:XPC_TYPE_DICTIONARY forSelector:@selector(startGuestWithReply:)
             argumentIndex:0 ofReply:YES];
    return interface;
}

static inline NSXPCInterface *PHProcessClientInterface(void) {
    NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:@protocol(PHProcessClient)];
    [interface setXPCType:XPC_TYPE_DICTIONARY forSelector:@selector(spawnGuest:reply:) argumentIndex:0 ofReply:NO];
    return interface;
}
