#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ReceivedFileStorage : NSObject

+ (NSString *)sanitizedFilename:(NSString *)filename NS_SWIFT_NAME(sanitizedFilename(_:));
+ (NSURL * _Nullable)receivedFilesDirectoryURL:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(receivedFilesDirectoryURL());
+ (NSURL * _Nullable)legacyCachesDirectoryURL:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(legacyCachesDirectoryURL());
+ (NSURL * _Nullable)uniqueDestinationURLForFilename:(NSString *)filename error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(uniqueDestinationURL(for:));
/// 收件目录里内容与 fileURL 完全相同、名字是 filename 或其「 (N)」副本的文件；没有则为 nil
+ (NSURL * _Nullable)storedFileMatchingContentsOf:(NSURL *)fileURL filename:(NSString *)filename NS_SWIFT_NAME(storedFile(matchingContentsOf:filename:));

@end

NS_ASSUME_NONNULL_END
