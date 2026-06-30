//
//  OCTrashPendingItems.h
//  ownCloudSDK
//
//  Copyright © 2025 ownCloud GmbH. All rights reserved.
//

/*
 * Copyright (C) 2025, ownCloud GmbH.
 *
 * This code is covered by the GNU Public License Version 3.
 *
 * For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 * You should have received a copy of this license along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 *
 */

#import <Foundation/Foundation.h>
#import "OCItem.h"
#import "OCTypes.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const OCTrashPendingItemsPathPrefix;

@interface OCTrashPendingItems : NSObject

+ (NSString *)pendingTrashPathForSyncRecordID:(OCSyncRecordID)syncRecordID originalLocation:(NSString *)originalLocation;

+ (OCItem *)syntheticTrashItemFromDeletedItem:(OCItem *)item syncRecordID:(OCSyncRecordID)syncRecordID;

+ (BOOL)isPendingTrashItem:(OCItem *)item;

+ (nullable OCSyncRecordID)pendingSyncRecordIDForTrashItem:(OCItem *)item;

+ (BOOL)serverTrashItem:(OCItem *)serverItem matchesPendingTrashItem:(OCItem *)pendingItem;

@end

NS_ASSUME_NONNULL_END
