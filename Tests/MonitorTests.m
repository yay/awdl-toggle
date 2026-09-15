#import <Foundation/Foundation.h>
#import <net/if.h>
#import <net/route.h>
#import "../Sources/Helper/AWDLMonitor.h"

static NSUInteger checks = 0;
#define CHECK(condition, message) do { checks++; if (!(condition)) { fprintf(stderr, "FAIL: %s (line %d)\n", message, __LINE__); exit(1); } } while (0)

@interface FakeInterface : NSObject <AWDLInterface>
@property BOOL present;
@property BOOL up;
@property BOOL failWrites;
@property NSUInteger writes;
@end
@implementation FakeInterface
- (NSNumber *)interfaceUpWithError:(NSError **)error { return self.present ? @(self.up) : nil; }
- (BOOL)setInterfaceUp:(BOOL)up error:(NSError **)error {
    self.writes++;
    if (self.failWrites) {
        if (error) { *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]; }
        return NO;
    }
    self.up = up;
    return YES;
}
@end

int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [directory stringByAppendingPathComponent:@"state.plist"];
        dispatch_queue_t queue = dispatch_queue_create("tests", DISPATCH_QUEUE_SERIAL);
        FakeInterface *interface = [FakeInterface new];
        interface.present = YES;
        interface.up = YES;
        NSError *error = nil;
        AWDLMonitor *monitor = [[AWDLMonitor alloc] initWithQueue:queue statePath:path interface:interface watchRoutes:NO error:&error];
        CHECK(monitor && monitor.enabled, "fresh installs allow AWDL");
        CHECK([monitor setEnabled:NO error:&error], "manual off succeeds");
        CHECK(!interface.up && !monitor.enabled, "off lowers the interface");
        interface.up = YES;
        [monitor reconcile];
        CHECK(!interface.up, "an external raise is immediately undone");
        NSUInteger writes = interface.writes;
        [monitor reconcile];
        CHECK(interface.writes == writes, "no redundant ioctl when already down");
        monitor = nil;
        interface.up = YES;
        monitor = [[AWDLMonitor alloc] initWithQueue:queue statePath:path interface:interface watchRoutes:NO error:&error];
        CHECK(!monitor.enabled && !interface.up, "restart restores and enforces saved off");
        CHECK([monitor setEnabled:YES error:&error] && interface.up, "on restores the interface");
        interface.up = NO;
        [monitor reconcile];
        CHECK(!interface.up, "on lets macOS manage subsequent interface state");
        CHECK([monitor setEnabled:YES error:&error] && interface.up, "an explicit repeated on can restore the interface");

        interface.present = NO;
        CHECK([monitor setEnabled:NO error:&error], "off is saved while interface absent");
        CHECK([monitor status][@"interfaceUp"] == nil, "absence is distinct from down");
        interface.present = YES;
        interface.up = YES;
        [monitor reconcile];
        CHECK(!interface.up, "interface appearance applies pending off");
        interface.present = NO;
        CHECK([monitor setEnabled:YES error:&error], "on is saved while absent");
        interface.present = YES;
        interface.up = NO;
        [monitor reconcile];
        CHECK(interface.up, "interface appearance applies pending on");

        interface.failWrites = YES;
        error = nil;
        CHECK(![monitor setEnabled:NO error:&error] && error, "ioctl error reaches caller");
        CHECK(!monitor.enabled && [monitor status][@"issue"], "desired off is retained while enforcement failure is visible");
        interface.failWrites = NO;
        [monitor reconcile];
        CHECK(!interface.up && ![monitor status][@"issue"], "enforcement recovers on next event");

        NSString *badPath = [directory stringByAppendingPathComponent:@"missing/state.plist"];
        AWDLMonitor *badStore = [[AWDLMonitor alloc] initWithQueue:queue statePath:badPath interface:interface watchRoutes:NO error:NULL];
        error = nil;
        CHECK(![badStore setEnabled:NO error:&error] && error && badStore.enabled, "failed save does not commit a new policy");
        [@"invalid plist" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        error = nil;
        CHECK(![[AWDLMonitor alloc] initWithQueue:queue statePath:path interface:interface watchRoutes:NO error:&error] && error, "corrupt saved state is reported");
        [@{@"enabled": @7} writeToFile:path atomically:YES];
        CHECK(![[AWDLMonitor alloc] initWithQueue:queue statePath:path interface:interface watchRoutes:NO error:NULL], "nonboolean persisted state is rejected");

        struct if_msghdr message = {0};
        message.ifm_msglen = sizeof(message);
        message.ifm_version = RTM_VERSION;
        message.ifm_type = RTM_IFINFO;
        CHECK(AWDLRouteMessagesNeedReconcile(&message, sizeof(message)), "complete interface event accepted");
        CHECK(!AWDLRouteMessagesNeedReconcile(&message, sizeof(message) - 1), "truncated event rejected");
        message.ifm_version = 0;
        CHECK(!AWDLRouteMessagesNeedReconcile(&message, sizeof(message)), "wrong route version rejected");
        message.ifm_version = RTM_VERSION;
        message.ifm_msglen = 0;
        CHECK(!AWDLRouteMessagesNeedReconcile(&message, sizeof(message)), "zero length cannot loop");
        message.ifm_msglen = sizeof(message);
        message.ifm_type = RTM_GET;
        CHECK(!AWDLRouteMessagesNeedReconcile(&message, sizeof(message)), "unrelated routing event ignored");
        message.ifm_type = RTM_IFINFO;
        NSMutableData *batch = [NSMutableData dataWithBytes:&message length:sizeof(message)];
        [batch appendBytes:&message length:sizeof(message)];
        CHECK(AWDLRouteMessagesNeedReconcile(batch.bytes, batch.length), "multiple records accepted");
        for (NSUInteger length = 0; length < sizeof(message); length++) {
            CHECK(!AWDLRouteMessagesNeedReconcile(&message, length), "every truncated length handled");
        }
        uint8_t fuzz[512];
        for (NSUInteger iteration = 0; iteration < 10000; iteration++) {
            arc4random_buf(fuzz, sizeof(fuzz));
            AWDLRouteMessagesNeedReconcile(fuzz, arc4random_uniform(sizeof(fuzz)));
        }
        [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
        printf("PASS: %lu monitor/parser checks + 10,000 malformed-message probes\n", (unsigned long)checks);
    }
    return 0;
}
