//
//  OCCoreDeviceAvailabilityGate.h
//  ownCloudSDK
//

#import <ownCloudSDK/OCCore.h>
#import <ownCloudSDK/OCCoreConnectionStatusSignalProvider.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCCore (DeviceAvailabilityGate)

- (void)addDeviceAvailabilitySignalProvider:(OCCoreConnectionStatusSignalProvider *)provider;

@end

NS_ASSUME_NONNULL_END
