#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define AWDL_MACH_SERVICE @"local.vitaly.AWDLToggle.Helper"
#define AWDL_STATE_DIRECTORY @"/Library/Application Support/AWDL Toggle"
#define AWDL_ERROR_DOMAIN @"local.vitaly.AWDLToggle"

@protocol AWDLHelperProtocol
- (void)observeStatus;
- (void)getStatusWithReply:(void (^)(NSDictionary<NSString *, id> * _Nullable status, NSError * _Nullable error))reply;
- (void)setAWDLEnabled:(BOOL)enabled withReply:(void (^)(NSDictionary<NSString *, id> * _Nullable status, NSError * _Nullable error))reply;
@end

@protocol AWDLStatusObserver
- (void)statusDidChange:(NSDictionary<NSString *, id> *)status;
@end

NS_ASSUME_NONNULL_END
