#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <sys/stat.h>
#import <unistd.h>
#import <signal.h>
#import <os/log.h>
#import "AWDLMonitor.h"
#import "../Shared/HelperProtocol.h"

@interface AWDLService : NSObject <AWDLHelperProtocol, NSXPCListenerDelegate>
@property AWDLMonitor *monitor;
@property dispatch_queue_t queue;
@property NSXPCListener *listener;
@property NSHashTable<NSXPCConnection *> *observers;
@property NSDictionary *lastPublishedStatus;
@end

@implementation AWDLService
- (void)publishStatus {
    NSDictionary *status = [self.monitor status];
    if ([status isEqual:self.lastPublishedStatus]) { return; }
    self.lastPublishedStatus = status;
    for (NSXPCConnection *connection in self.observers) {
        [(id<AWDLStatusObserver>)connection.remoteObjectProxy statusDidChange:status];
    }
}
- (void)observeStatus {
    NSXPCConnection *connection = NSXPCConnection.currentConnection;
    if (!connection) { return; }
    dispatch_async(self.queue, ^{
        [self.observers addObject:connection];
        [(id<AWDLStatusObserver>)connection.remoteObjectProxy statusDidChange:[self.monitor status]];
    });
}
- (void)getStatusWithReply:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))reply {
    dispatch_async(self.queue, ^{ reply([self.monitor status], nil); });
}
- (void)setAWDLEnabled:(BOOL)enabled withReply:(void (^)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))reply {
    dispatch_async(self.queue, ^{
        NSError *error = nil;
        [self.monitor setEnabled:enabled error:&error];
        [self publishStatus];
        reply([self.monitor status], error);
    });
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(AWDLHelperProtocol)];
    connection.exportedObject = self;
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(AWDLStatusObserver)];
    __weak AWDLService *weakSelf = self;
    __weak NSXPCConnection *weakConnection = connection;
    connection.invalidationHandler = ^{
        AWDLService *service = weakSelf;
        if (service) { dispatch_async(service.queue, ^{ [service.observers removeObject:weakConnection]; }); }
    };
    // No teardown on disconnect: widgets are ephemeral, the manual policy is not.
    [connection resume];
    return YES;
}
@end

static BOOL IsRootOwned(NSString *path, BOOL directory) {
    struct stat attributes;
    if (lstat(path.fileSystemRepresentation, &attributes) != 0) { return NO; }
    return attributes.st_uid == 0 && !(attributes.st_mode & 0022)
        && (directory ? S_ISDIR(attributes.st_mode) : S_ISREG(attributes.st_mode));
}

static NSString *ClientRequirement(void) {
    NSString *directory = AWDL_STATE_DIRECTORY;
    NSString *path = [directory stringByAppendingPathComponent:@"clients.plist"];
    if (!IsRootOwned(directory, YES) || !IsRootOwned(path, NO)) { return nil; }
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:path];
    NSMutableArray *requirements = [NSMutableArray new];
    for (NSString *identifier in @[@"local.vitaly.AWDLToggle", @"local.vitaly.AWDLToggle.Control"]) {
        NSArray *hashes = manifest[identifier];
        if (![hashes isKindOfClass:NSArray.class] || hashes.count == 0) { return nil; }
        for (id hash in hashes) {
            if (![hash isKindOfClass:NSString.class] || [hash length] != 40
                || [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) { return nil; }
            [requirements addObject:[NSString stringWithFormat:@"(identifier \"%@\" and cdhash H\"%@\")", identifier, hash]];
        }
    }
    return [requirements componentsJoinedByString:@" or "];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0) { fprintf(stderr, "AWDLToggleHelper must run as root.\n"); return 77; }
        if (argc == 2 && strcmp(argv[1], "--restore") == 0) {
            AWDLSystemInterface *interface = [AWDLSystemInterface new];
            NSError *error = nil;
            NSNumber *up = [interface interfaceUpWithError:&error];
            if (!up && !error) { return 0; }
            if (error || ![interface setInterfaceUp:YES error:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
            }
            return 0;
        }
        if (argc != 1) { fprintf(stderr, "Unknown argument.\n"); return 64; }
        umask(0077);
        NSString *requirement = ClientRequirement();
        if (!requirement) { os_log_fault(OS_LOG_DEFAULT, "Invalid or missing root-owned client allowlist."); return 78; }
        SecRequirementRef check = NULL;
        if (SecRequirementCreateWithString((__bridge CFStringRef)requirement, kSecCSDefaultFlags, &check) != errSecSuccess) { return 78; }
        CFRelease(check);

        AWDLService *service = [AWDLService new];
        service.queue = dispatch_queue_create("local.vitaly.AWDLToggle.monitor", DISPATCH_QUEUE_SERIAL);
        service.observers = [NSHashTable weakObjectsHashTable];
        __block NSError *error = nil;
        dispatch_sync(service.queue, ^{
            service.monitor = [[AWDLMonitor alloc] initWithQueue:service.queue
                statePath:[AWDL_STATE_DIRECTORY stringByAppendingPathComponent:@"state.plist"]
                interface:[AWDLSystemInterface new] watchRoutes:YES error:&error];
        });
        if (!service.monitor) { os_log_fault(OS_LOG_DEFAULT, "Cannot start AWDL monitor: %{public}@", error); return 78; }
        service.monitor.failureHandler = ^{ exit(1); }; // launchd reopens the route socket and restores policy.
        __weak AWDLService *weakService = service;
        service.monitor.changeHandler = ^{ [weakService publishStatus]; };
        service.listener = [[NSXPCListener alloc] initWithMachServiceName:AWDL_MACH_SERVICE];
        [service.listener setConnectionCodeSigningRequirement:requirement];
        service.listener.delegate = service;
        [service.listener resume];

        signal(SIGTERM, SIG_IGN);
        signal(SIGINT, SIG_IGN);
        NSMutableArray *signals = [NSMutableArray new];
        for (NSNumber *number in @[@(SIGTERM), @(SIGINT)]) {
            dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, number.intValue, 0, service.queue);
            dispatch_source_set_event_handler(source, ^{
                [service.monitor invalidate];
                // Restore on orderly unload; keep the saved choice for the next boot.
                [[AWDLSystemInterface new] setInterfaceUp:YES error:NULL];
                exit(0);
            });
            dispatch_resume(source);
            [signals addObject:source];
        }
        os_log(OS_LOG_DEFAULT, "AWDL Toggle helper ready");
        dispatch_main();
    }
}
