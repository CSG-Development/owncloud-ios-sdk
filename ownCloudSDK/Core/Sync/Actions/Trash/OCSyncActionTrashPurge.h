//
//  OCSyncActionTrashPurge.h
//  ownCloudSDK
//
//  Copyright © 2025 ownCloud GmbH. All rights reserved.
//

#import "OCSyncAction.h"

NS_ASSUME_NONNULL_BEGIN

@interface OCSyncActionTrashPurge : OCSyncAction

@property(strong) NSString *parentTrashPath;
@property(nullable,strong) OCDriveID driveID;

- (instancetype)initWithItem:(OCItem *)item;

@end

NS_ASSUME_NONNULL_END
