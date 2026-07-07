#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ReceivedFileStorage : NSObject

+ (NSString *)sanitizedFilename:(NSString *)filename NS_SWIFT_NAME(sanitizedFilename(_:));
+ (NSURL * _Nullable)receivedFilesDirectoryURL:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(receivedFilesDirectoryURL());
+ (NSURL * _Nullable)legacyCachesDirectoryURL:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(legacyCachesDirectoryURL());
+ (NSURL * _Nullable)uniqueDestinationURLForFilename:(NSString *)filename error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(uniqueDestinationURL(for:));

@end

NS_ASSUME_NONNULL_END
