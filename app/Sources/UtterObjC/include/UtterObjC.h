#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching an Objective-C exception (AVAudioEngine raises them
/// for format mismatches after a device change). Returns the exception's reason,
/// or nil when the block finished normally.
NSString *_Nullable UtterCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
