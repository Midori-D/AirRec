// Copyright 2026 AirRecord contributors. SPDX-License-Identifier: Apache-2.0
#import "AirRecordKeepAliveExtension.h"
#import <objc/message.h>

static NSError *AirRecordExtensionError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"AirRecord.KeepAlive.Extension"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface AirRecordKeepAliveExtension ()
@property (nonatomic, strong) id extensionObject;
@end

@implementation AirRecordKeepAliveExtension

- (nullable instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier
                                          error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (!self) { return nil; }

    Class extensionClass = NSClassFromString(@"NSExtension");
    SEL factory = NSSelectorFromString(@"extensionWithIdentifier:error:");
    if (bundleIdentifier.length == 0 || !extensionClass || ![extensionClass respondsToSelector:factory]) {
        if (error) { *error = AirRecordExtensionError(1, @"Helper extension runtime is unavailable."); }
        return nil;
    }

    NSError *creationError = nil;
    @try {
        _extensionObject = ((id (*)(id, SEL, NSString *, NSError **))objc_msgSend)(
            extensionClass, factory, bundleIdentifier, &creationError);
    } @catch (__unused NSException *exception) {
        if (error) { *error = AirRecordExtensionError(2, @"Helper extension could not be opened."); }
        return nil;
    }
    if (!_extensionObject) {
        if (error) {
            *error = creationError ?: AirRecordExtensionError(2, @"Helper extension is not installed.");
        }
        return nil;
    }

    NSArray<NSString *> *requiredMethods = @[
        @"beginExtensionRequestWithInputItems:completion:",
        @"pidForRequestIdentifier:",
        @"setRequestCancellationBlock:",
        @"setRequestInterruptionBlock:"
    ];
    for (NSString *method in requiredMethods) {
        if (![_extensionObject respondsToSelector:NSSelectorFromString(method)]) {
            if (error) { *error = AirRecordExtensionError(3, @"Helper extension lifecycle API is unavailable."); }
            return nil;
        }
    }

    __weak AirRecordKeepAliveExtension *weakSelf = self;
    void (^cancelled)(NSUUID *, NSError *) = ^(NSUUID *identifier, NSError *nativeError) {
        if (![identifier isKindOfClass:NSUUID.class]) { return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            AirRecordKeepAliveExtension *owner = weakSelf;
            void (^handler)(NSUUID *, NSError *) = owner.cancellationHandler;
            if (handler) { handler(identifier, nativeError); }
        });
    };
    void (^interrupted)(NSUUID *) = ^(NSUUID *identifier) {
        if (![identifier isKindOfClass:NSUUID.class]) { return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            AirRecordKeepAliveExtension *owner = weakSelf;
            void (^handler)(NSUUID *) = owner.interruptionHandler;
            if (handler) { handler(identifier); }
        });
    };
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(
            _extensionObject, NSSelectorFromString(@"setRequestCancellationBlock:"), cancelled);
        ((void (*)(id, SEL, id))objc_msgSend)(
            _extensionObject, NSSelectorFromString(@"setRequestInterruptionBlock:"), interrupted);
    } @catch (__unused NSException *exception) {
        if (error) { *error = AirRecordExtensionError(3, @"Helper extension lifecycle setup failed."); }
        return nil;
    }
    return self;
}

- (void)beginWithItems:(NSArray<NSExtensionItem *> *)items
           completion:(void (^)(NSUUID * _Nullable, NSError * _Nullable))completion {
    NSObject *completionLock = [NSObject new];
    __block BOOL delivered = NO;
    void (^deliver)(NSUUID *, NSError *) = ^(NSUUID *identifier, NSError *error) {
        @synchronized (completionLock) {
            if (delivered) { return; }
            delivered = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(identifier, error); });
    };
    void (^finished)(NSUUID *) = ^(NSUUID *identifier) {
        NSUUID *validIdentifier = [identifier isKindOfClass:NSUUID.class] ? identifier : nil;
        NSError *error = validIdentifier ? nil : AirRecordExtensionError(4, @"Helper extension did not create a request.");
        deliver(validIdentifier, error);
    };
    @try {
        ((void (*)(id, SEL, NSArray *, id))objc_msgSend)(
            self.extensionObject, NSSelectorFromString(@"beginExtensionRequestWithInputItems:completion:"),
            items, finished);
    } @catch (__unused NSException *exception) {
        NSError *error = AirRecordExtensionError(5, @"Helper extension request failed.");
        deliver(nil, error);
    }
}

- (pid_t)pidForRequest:(NSUUID *)requestIdentifier {
    if (![requestIdentifier isKindOfClass:NSUUID.class]) { return 0; }
    @try {
        pid_t pid = ((pid_t (*)(id, SEL, NSUUID *))objc_msgSend)(
            self.extensionObject, NSSelectorFromString(@"pidForRequestIdentifier:"), requestIdentifier);
        return pid > 0 ? pid : 0;
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

- (void)cancelRequest:(NSUUID *)requestIdentifier {
    if (![requestIdentifier isKindOfClass:NSUUID.class]) { return; }
    SEL cancel = NSSelectorFromString(@"cancelExtensionRequestWithIdentifier:");
    if (![self.extensionObject respondsToSelector:cancel]) { return; }
    @try {
        ((void (*)(id, SEL, NSUUID *))objc_msgSend)(self.extensionObject, cancel, requestIdentifier);
    } @catch (__unused NSException *exception) {
        // The host's independent session cancellation closes its debug stream.
        // Never kill a helper or host process as a cancellation fallback.
    }
}

@end
