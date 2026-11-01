// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns one app-provided extension object. The private Foundation class is
/// resolved at runtime so unsupported installations fail without a class link.
@interface AirRecordKeepAliveExtension : NSObject

- (nullable instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                          error:(NSError * _Nullable * _Nullable)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// These callbacks and begin's completion are always delivered on the main
/// queue. Each callback identifies the request; the caller owns generation checks.
@property (nonatomic, copy, nullable) void (^cancellationHandler)(NSUUID *requestIdentifier,
                                                               NSError * _Nullable error);
@property (nonatomic, copy, nullable) void (^interruptionHandler)(NSUUID *requestIdentifier);

- (void)beginWithItems:(NSArray<NSExtensionItem *> *)items
           completion:(void (^)(NSUUID * _Nullable requestIdentifier,
                                NSError * _Nullable error))completion NS_SWIFT_NAME(begin(items:completion:));
- (pid_t)pidForRequest:(NSUUID *)requestIdentifier NS_SWIFT_NAME(pid(for:));

/// Requests cancellation only if the runtime exposes the cancellation method.
/// This method never sends a signal or calls the private process-kill method.
- (void)cancelRequest:(NSUUID *)requestIdentifier NS_SWIFT_NAME(cancel(request:));

@end

NS_ASSUME_NONNULL_END
