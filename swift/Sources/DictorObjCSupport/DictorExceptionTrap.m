#import "DictorExceptionTrap.h"

NSString *const DictorObjCExceptionDomain = @"DictorObjCException";

@implementation DictorExceptionTrap

+ (BOOL)perform:(NS_NOESCAPE dispatch_block_t)block
          error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: exception.name;
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = reason;
            info[@"DictorExceptionName"] = exception.name;
            if (exception.reason != nil) {
                info[@"DictorExceptionReason"] = exception.reason;
            }
            *error = [NSError errorWithDomain:DictorObjCExceptionDomain
                                         code:-1
                                     userInfo:info];
        }
        return NO;
    }
}

@end
