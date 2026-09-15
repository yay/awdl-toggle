// Preserves AF_ROUTE + SIOCSIFFLAGS enforcement; uses a serial dispatch source
// instead of the original poll thread and pipe for deterministic request replies.
#import "AWDLMonitor.h"
#import "../Shared/HelperProtocol.h"
#import <net/if.h>
#import <net/route.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <os/log.h>

static NSError *SystemError(NSString *operation) {
    int code = errno;
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %s", operation, strerror(code)]
    }];
}

static NSError *StateError(NSString *message) {
    return [NSError errorWithDomain:AWDL_ERROR_DOMAIN code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation AWDLSystemInterface {
    int _socket;
}
- (instancetype)init {
    if ((self = [super init])) { _socket = socket(AF_INET, SOCK_DGRAM, 0); }
    return self;
}
- (NSNumber *)interfaceUpWithError:(NSError **)error {
    struct ifreq request = {0};
    strlcpy(request.ifr_name, "awdl0", sizeof(request.ifr_name));
    if (_socket < 0 || ioctl(_socket, SIOCGIFFLAGS, &request) < 0) {
        // Absence is normal early in boot. Route notifications trigger another check.
        if (errno != ENXIO && errno != ENODEV && error) { *error = SystemError(@"Cannot read awdl0"); }
        return nil;
    }
    return @((request.ifr_flags & IFF_UP) != 0);
}
- (BOOL)setInterfaceUp:(BOOL)up error:(NSError **)error {
    struct ifreq request = {0};
    strlcpy(request.ifr_name, "awdl0", sizeof(request.ifr_name));
    if (_socket < 0 || ioctl(_socket, SIOCGIFFLAGS, &request) < 0) {
        if (error) { *error = SystemError(@"Cannot read awdl0"); }
        return NO;
    }
    if (((request.ifr_flags & IFF_UP) != 0) == up) { return YES; }
    if (up) { request.ifr_flags |= IFF_UP; }
    else { request.ifr_flags &= ~IFF_UP; }
    if (ioctl(_socket, SIOCSIFFLAGS, &request) < 0) {
        if (error) { *error = SystemError(up ? @"Cannot enable awdl0" : @"Cannot disable awdl0"); }
        return NO;
    }
    return YES;
}
- (void)dealloc { if (_socket >= 0) { close(_socket); } }
@end

BOOL AWDLRouteMessagesNeedReconcile(const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    BOOL relevant = NO;
    while (length >= 4) {
        uint16_t messageLength = 0;
        memcpy(&messageLength, cursor, sizeof(messageLength));
        if (messageLength < 4 || messageLength > length) { return relevant; }
        if (cursor[2] == RTM_VERSION) {
            uint8_t type = cursor[3];
            if (type == RTM_IFINFO && messageLength >= sizeof(struct if_msghdr)) { relevant = YES; }
            if ((type == RTM_NEWADDR || type == RTM_DELADDR) && messageLength >= sizeof(struct ifa_msghdr)) { relevant = YES; }
        }
        cursor += messageLength;
        length -= messageLength;
    }
    return relevant;
}

@implementation AWDLMonitor {
    dispatch_queue_t _queue;
    dispatch_source_t _routeSource;
    NSString *_statePath;
    id<AWDLInterface> _interface;
    NSString *_issue;
    BOOL _watchRoutes;
    BOOL _allowPending;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue statePath:(NSString *)path
                    interface:(id<AWDLInterface>)interface watchRoutes:(BOOL)watchRoutes error:(NSError **)error {
    if (!(self = [super init])) { return nil; }
    _queue = queue;
    _statePath = [path copy];
    _interface = interface;
    _watchRoutes = watchRoutes;
    _enabled = YES;

    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (data) {
        id object = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
        if (![object isKindOfClass:NSDictionary.class] || ![object[@"enabled"] isKindOfClass:NSNumber.class]
            || CFGetTypeID((__bridge CFTypeRef)object[@"enabled"]) != CFBooleanGetTypeID()) {
            if (error) { *error = StateError(@"Saved AWDL state is invalid. Repair the installation."); }
            return nil;
        }
        _enabled = [object[@"enabled"] boolValue];
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    } else if (error) {
        *error = nil;
    }

    _allowPending = _enabled;
    if (watchRoutes) {
        int route = socket(AF_ROUTE, SOCK_RAW, 0);
        if (route < 0) { if (error) { *error = SystemError(@"Cannot monitor network routes"); } return nil; }
        if (fcntl(route, F_SETFL, O_NONBLOCK) < 0 || fcntl(route, F_SETFD, FD_CLOEXEC) < 0) {
            if (error) { *error = SystemError(@"Cannot configure route socket"); }
            close(route);
            return nil;
        }
        // A larger receive buffer reduces overflow when several interfaces change at once.
        int receiveBuffer = 1024 * 1024;
        setsockopt(route, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, sizeof(receiveBuffer));
        _routeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, route, 0, queue);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_routeSource, ^{ [weakSelf drainRouteSocket:route]; });
        dispatch_source_set_cancel_handler(_routeSource, ^{ close(route); });
        dispatch_resume(_routeSource);
    }
    _monitoring = YES;
    [self reconcile];
    return self;
}

- (void)drainRouteSocket:(int)route {
    uint8_t buffer[65536];
    BOOL relevant = NO;
    // Bound each batch so route storms cannot starve manual toggle requests.
    for (NSUInteger count = 0; count < 256; count++) {
        ssize_t length = recv(route, buffer, sizeof(buffer), 0);
        if (length > 0) {
            relevant |= AWDLRouteMessagesNeedReconcile(buffer, (size_t)length);
            continue;
        }
        if (length < 0 && errno == EINTR) { continue; }
        if (length < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { break; }
        if (length < 0 && errno == ENOBUFS) { relevant = YES; break; }
        // A broken read source must never spin or pretend enforcement is working.
        _issue = length == 0 ? @"The route monitor closed unexpectedly." : SystemError(@"Route monitor failed").localizedDescription;
        _monitoring = NO;
        dispatch_source_cancel(_routeSource);
        os_log_error(OS_LOG_DEFAULT, "%{public}@", _issue);
        if (self.failureHandler) { self.failureHandler(); }
        return;
    }
    if (relevant) {
        [self reconcile];
        if (self.changeHandler) { self.changeHandler(); }
    }
}

- (void)reconcile {
    NSError *error = nil;
    NSNumber *up = [_interface interfaceUpWithError:&error];
    if (!up) { if (_monitoring) { _issue = error.localizedDescription; } return; }
    // On restores the interface once, then lets macOS manage its normal lifecycle.
    // Off is enforced for every subsequent interface event.
    if ((!_enabled && up.boolValue) || (_enabled && _allowPending && !up.boolValue)) {
        if (![_interface setInterfaceUp:_enabled error:&error]) {
            _issue = error.localizedDescription;
            os_log_error(OS_LOG_DEFAULT, "%{public}@", _issue);
            return;
        }
    }
    _allowPending = NO;
    if (_monitoring) { _issue = nil; }
}

- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"enabled": @(enabled)}
                                                            format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data) { return NO; }
    // Atomic rename preserves the last good state if a write fails. The containing
    // directory is root-only in production; clients can only mutate through XPC.
    if (![data writeToFile:_statePath options:NSDataWritingAtomic error:error]) { return NO; }
    chmod(_statePath.fileSystemRepresentation, 0600);
    int fd = open(_statePath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd >= 0) { fsync(fd); close(fd); }
    _enabled = enabled;
    _allowPending = enabled;
    [self reconcile];
    if (_issue || !_monitoring) {
        if (error) { *error = StateError(_issue ?: @"The route monitor is unavailable."); }
        return NO;
    }
    return YES;
}

- (NSDictionary<NSString *, id> *)status {
    [self reconcile];
    NSError *error = nil;
    NSNumber *up = [_interface interfaceUpWithError:&error];
    NSMutableDictionary *result = [@{@"enabled": @(_enabled), @"monitoring": @(_monitoring)} mutableCopy];
    if (up) { result[@"interfaceUp"] = up; }
    NSString *issue = _issue ?: error.localizedDescription;
    if (issue) { result[@"issue"] = issue; }
    return result;
}

- (void)invalidate {
    _monitoring = NO;
    if (_routeSource) { dispatch_source_cancel(_routeSource); _routeSource = nil; }
}
- (void)dealloc { [self invalidate]; }
@end
