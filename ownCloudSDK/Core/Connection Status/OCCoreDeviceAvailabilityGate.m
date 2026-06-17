//
//  OCCoreDeviceAvailabilityGate.m
//  ownCloudSDK
//

#import "OCCoreDeviceAvailabilityGate.h"
#import "OCCore+ConnectionStatus.h"

@implementation OCCore (DeviceAvailabilityGate)

- (void)addDeviceAvailabilitySignalProvider:(OCCoreConnectionStatusSignalProvider *)provider
{
	[self addSignalProvider:provider];
}

@end
