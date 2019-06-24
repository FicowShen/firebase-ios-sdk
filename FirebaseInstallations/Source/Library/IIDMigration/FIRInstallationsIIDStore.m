/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FIRInstallationsIIDStore.h"

#if __has_include(<FBLPromises/FBLPromises.h>)
#import <FBLPromises/FBLPromises.h>
#else
#import "FBLPromises.h"
#endif

#import <CommonCrypto/CommonDigest.h>

static NSString *const kFIRInstallationsIIDKeyPairPublicTagPrefix = @"com.google.iid.keypair.public-";
static NSString *const kFIRInstallationsIIDKeyPairPrivateTagPrefix = @"com.google.iid.keypair.private-";
static NSString *const kFIRInstallationsIIDCreationTimePlistKey = @"|S|cre";

@implementation FIRInstallationsIIDStore

- (FBLPromise<NSString *> *)existingIID {
  return [FBLPromise onQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) do:^id _Nullable {
    if (![self hasPlistIIDFlag]) {
      return nil;
    }

    NSData *IIDPublicKeyData = [self IIDPublicKeyData];
    return [self IIDWithPublicKeyData:IIDPublicKeyData];
  }]
  .validate(^BOOL(NSString * _Nullable IID) {
    return IID.length > 0;
  });
}

- (FBLPromise<NSNull *> *)deleteExistingIID {
  return [FBLPromise onQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) do:^id _Nullable{
    NSError *error;
    return [self deleteIIDFlagFromPlist:&error] ? [NSNull null] : error;
  }];
}

#pragma mark - IID decoding

- (NSString *)IIDWithPublicKeyData:(NSData *)publicKeyData {
  NSData *publicKeySHA1 = [self sha1WithData:publicKeyData];

  const uint8_t *bytes = publicKeySHA1.bytes;
  NSMutableData *identityData = [NSMutableData dataWithData:publicKeySHA1];

  uint8_t b0 = bytes[0];
  // Take the first byte and make the initial four 7 by initially making the initial 4 bits 0
  // and then adding 0x70 to it.
  b0 = 0x70 + (0xF & b0);
  // failsafe should give you back b0 itself
  b0 = (b0 & 0xFF);
  [identityData replaceBytesInRange:NSMakeRange(0, 1) withBytes:&b0];
  NSData *data = [identityData subdataWithRange:NSMakeRange(0, 8 * sizeof(Byte))];
  return [self base64URLEncodedStringWithData:data];
}

- (NSData *)sha1WithData:(NSData *)data {
  unsigned int outputLength = CC_SHA1_DIGEST_LENGTH;
  unsigned char output[outputLength];
  unsigned int length = (unsigned int)[data length];

  CC_SHA1(data.bytes, length, output);
  return [NSData dataWithBytes:output length:outputLength];
}

- (NSString *)base64URLEncodedStringWithData:(NSData *)data {
  NSString *string = [data base64EncodedStringWithOptions:0];
  string = [string stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  string = [string stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
  string = [string stringByReplacingOccurrencesOfString:@"=" withString:@""];
  return string;
}

#pragma mark - Keychain

- (NSData *)IIDPublicKeyData {
  NSDictionary *query = [self keyPairQueryWithTag:[self keychainPublicKeyTag]];

  CFTypeRef keyRef = NULL;
  OSStatus status =
  SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&keyRef);

  if (status != noErr) {
    if (keyRef) {
      CFRelease(keyRef);
    }
    return nil;
  }

  return (__bridge NSData *)keyRef;
}

- (NSDictionary *)keyPairQueryWithTag:(NSString *)tag {
  NSMutableDictionary *queryKey = [NSMutableDictionary dictionary];
  NSData *tagData = [tag dataUsingEncoding:NSUTF8StringEncoding];

  queryKey[(__bridge id)kSecClass] = (__bridge id)kSecClassKey;
  queryKey[(__bridge id)kSecAttrApplicationTag] = tagData;
  queryKey[(__bridge id)kSecAttrKeyType] = (__bridge id)kSecAttrKeyTypeRSA;
  queryKey[(__bridge id)kSecReturnData] = @(YES);
  return queryKey;
}

- (NSString *)keychainPublicKeyTag {
  NSString *mainAppBundleID = [[NSBundle mainBundle] bundleIdentifier];
  if (mainAppBundleID.length == 0) {
    return nil;
  }
  return [NSString stringWithFormat:@"%@%@", kFIRInstallationsIIDKeyPairPublicTagPrefix, mainAppBundleID];
}

- (NSString *)mainbundleIdentifier {
  NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
  if (!bundleIdentifier.length) {
    return nil;
  }
  return bundleIdentifier;
}

#pragma mark - Plist

- (BOOL)deleteIIDFlagFromPlist:(NSError **)outError {
  NSString *path = [self plistPath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return YES;
  }

  NSMutableDictionary *plistContent = [[NSMutableDictionary alloc] initWithContentsOfFile:path];
  plistContent[kFIRInstallationsIIDCreationTimePlistKey] = nil;

  if (@available(macOS 10.13, iOS 11.0, tvOS 11.0, *)) {
    return [plistContent writeToURL:[NSURL fileURLWithPath:path] error:outError];
  }

  return [plistContent writeToFile:path atomically:YES];
}

- (BOOL)hasPlistIIDFlag {
  NSString *path = [self plistPath];
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return NO;
  }

  NSDictionary *plistContent = [[NSDictionary alloc] initWithContentsOfFile:path];
  return plistContent[kFIRInstallationsIIDCreationTimePlistKey] != nil;
}

- (NSString *)plistPath {
  NSString *plistNameWithExtension = @"com.google.iid-keypair.plist";
  NSString *_subDirectoryName = @"Google/FirebaseInstanceID";

  NSArray *directoryPaths =
  NSSearchPathForDirectoriesInDomains([self supportedDirectory], NSUserDomainMask, YES);
  NSArray *components = @[ directoryPaths.lastObject, _subDirectoryName, plistNameWithExtension ];

  return [NSString pathWithComponents:components];
}

- (NSSearchPathDirectory)supportedDirectory {
#if TARGET_OS_TV
  return NSCachesDirectory;
#else
  return NSApplicationSupportDirectory;
#endif
}

@end
