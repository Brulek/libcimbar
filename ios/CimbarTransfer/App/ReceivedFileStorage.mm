#import "ReceivedFileStorage.h"

static NSString * const kReceivedFilesRelativeDirectory = @"CimbarTransfer/Inbox";
static NSString * const kLegacyCachesRelativeDirectory = @"CimbarTransfer/ReceivedFiles";

@implementation ReceivedFileStorage

+ (NSString *)sanitizedFilename:(NSString *)filename {
    NSMutableCharacterSet *invalid = [NSMutableCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:"];
    // 文件名来自解码出的外部数据，换行/控制字符也一并过滤
    [invalid formUnionWithCharacterSet:[NSCharacterSet controlCharacterSet]];
    [invalid formUnionWithCharacterSet:[NSCharacterSet newlineCharacterSet]];
    NSArray<NSString *> *parts = [filename componentsSeparatedByCharactersInSet:invalid];
    NSString *merged = [parts componentsJoinedByString:@"_"];
    NSString *trimmed = [merged stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return @"cimbar-output.bin";
    }
    if ([trimmed hasPrefix:@"."]) {
        trimmed = [@"_" stringByAppendingString:trimmed];
    }
    return [self truncatedFilename:trimmed maxBytes:200];
}

// APFS 文件名上限 255 字节（UTF-8）。外部可控的文件名最长可达 511 字节，
// 截断到 200 字节并保留扩展名，给 uniqueDestinationURL 的 " (N)" 后缀留余量。
+ (NSString *)truncatedFilename:(NSString *)name maxBytes:(NSUInteger)maxBytes {
    if ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maxBytes) {
        return name;
    }

    NSString *extension = name.pathExtension;
    NSString *base = name.stringByDeletingPathExtension;
    NSString *suffix = (extension.length > 0 && extension.length <= 16)
        ? [@"." stringByAppendingString:extension]
        : @"";
    NSUInteger suffixBytes = [suffix lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSUInteger budget = maxBytes > suffixBytes ? maxBytes - suffixBytes : 0;

    // 按「组合字符序列」边界截断，避免把多字节字符或 emoji 切成半个
    NSMutableString *result = [NSMutableString string];
    NSUInteger usedBytes = 0;
    NSUInteger index = 0;
    while (index < base.length) {
        NSRange range = [base rangeOfComposedCharacterSequenceAtIndex:index];
        NSString *character = [base substringWithRange:range];
        NSUInteger characterBytes = [character lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (usedBytes + characterBytes > budget) {
            break;
        }
        [result appendString:character];
        usedBytes += characterBytes;
        index = NSMaxRange(range);
    }

    if (result.length == 0) {
        return suffix.length > 0 ? [@"cimbar-output" stringByAppendingString:suffix] : @"cimbar-output.bin";
    }
    return [result stringByAppendingString:suffix];
}

+ (NSURL * _Nullable)receivedFilesDirectoryURL:(NSError * _Nullable * _Nullable)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *baseDirectory = [fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (baseDirectory == nil) {
        baseDirectory = fileManager.temporaryDirectory;
    }

    NSURL *directory = [baseDirectory URLByAppendingPathComponent:kReceivedFilesRelativeDirectory isDirectory:YES];
    if (![fileManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }
    return directory;
}

+ (NSURL * _Nullable)legacyCachesDirectoryURL:(NSError * _Nullable * _Nullable)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *baseDirectory = [fileManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    if (baseDirectory == nil) {
        if (error != nil) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return nil;
    }
    NSURL *directory = [baseDirectory URLByAppendingPathComponent:kLegacyCachesRelativeDirectory isDirectory:YES];
    return directory;
}

+ (NSURL * _Nullable)uniqueDestinationURLForFilename:(NSString *)filename error:(NSError * _Nullable * _Nullable)error {
    NSURL *directory = [self receivedFilesDirectoryURL:error];
    if (directory == nil) {
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *safeName = [self sanitizedFilename:filename];
    NSString *baseName = [safeName stringByDeletingPathExtension];
    NSString *extension = [safeName pathExtension];

    NSURL *candidate = [directory URLByAppendingPathComponent:safeName isDirectory:NO];
    NSUInteger suffix = 1;
    while ([fileManager fileExistsAtPath:candidate.path]) {
        NSString *next = extension.length > 0
            ? [NSString stringWithFormat:@"%@ (%lu).%@", baseName, (unsigned long)suffix, extension]
            : [NSString stringWithFormat:@"%@ (%lu)", baseName, (unsigned long)suffix];
        candidate = [directory URLByAppendingPathComponent:next isDirectory:NO];
        suffix += 1;
        if (suffix > 9999) {
            break;
        }
    }
    return candidate;
}

@end
