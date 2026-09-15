#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Adapted from James Howard's AWDLControl (MIT), AWDLControlHelper/AWDLMonitor.
// All access is serialized on the queue supplied at initialization.
@protocol AWDLInterface <NSObject>
- (nullable NSNumber *)interfaceUpWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)setInterfaceUp:(BOOL)up error:(NSError * _Nullable * _Nullable)error;
@end

@interface AWDLSystemInterface : NSObject <AWDLInterface>
@end

@interface AWDLMonitor : NSObject
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) BOOL monitoring;
@property(nonatomic, copy, nullable) void (^failureHandler)(void);
- (nullable instancetype)initWithQueue:(dispatch_queue_t)queue
                           statePath:(NSString *)path
                           interface:(id<AWDLInterface>)interface
                         watchRoutes:(BOOL)watchRoutes
                               error:(NSError * _Nullable * _Nullable)error;
- (NSDictionary<NSString *, id> *)status;
- (BOOL)setEnabled:(BOOL)enabled error:(NSError * _Nullable * _Nullable)error;
- (void)reconcile;
- (void)invalidate;
@end

// Pure parser shared with tests; accepts only complete, versioned route messages.
BOOL AWDLRouteMessagesNeedReconcile(const void *bytes, size_t length);

NS_ASSUME_NONNULL_END
