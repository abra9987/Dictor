#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const DictorObjCExceptionDomain;

/// Runs a block, turning any Objective-C exception it raises into an
/// `NSError`.
///
/// Swift's `try` only sees Swift errors, and AVFoundation still
/// reports invalid audio formats the old way — by raising
/// `NSException`. Such an exception does not crash a background
/// thread either: AppKit swallows it and leaves the thread suspended
/// forever. That is how audio startup once froze with a status line
/// that kept claiming "Starting audio input…" and not a word in the
/// log. Anything that can raise goes through here so the failure
/// comes back as an ordinary error the caller can report and retry.
@interface DictorExceptionTrap : NSObject

+ (BOOL)perform:(NS_NOESCAPE dispatch_block_t)block
          error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
