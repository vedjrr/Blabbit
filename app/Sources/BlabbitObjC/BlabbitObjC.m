#import "BlabbitObjC.h"

NSString *_Nullable BlabbitCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"no reason"];
    }
}
