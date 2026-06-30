//
//  OCTrashPendingItems.m
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

#import "OCTrashPendingItems.h"
#import "OCConnection+Trash.h"
#import "OCDatabase+Trash.h"

NSString * const OCTrashPendingItemsPathPrefix = @"_pending";

@implementation OCTrashPendingItems

+ (NSString *)pendingTrashPathForSyncRecordID:(OCSyncRecordID)syncRecordID originalLocation:(NSString *)originalLocation
{
	NSString *normalizedLocation = [OCDatabase normalizedTrashPath:originalLocation];

	return ([NSString stringWithFormat:@"%@/%@/%@", OCTrashPendingItemsPathPrefix, syncRecordID, normalizedLocation]);
}

+ (OCItem *)syntheticTrashItemFromDeletedItem:(OCItem *)item syncRecordID:(OCSyncRecordID)syncRecordID
{
	NSData *itemData = [item serializedData];
	OCItem *trashItem = (itemData != nil) ? [OCItem itemFromSerializedData:itemData] : nil;

	if (trashItem == nil) {
		trashItem = [OCItem new];
		trashItem.type = item.type;
		trashItem.mimeType = item.mimeType;
		trashItem.size = item.size;
		trashItem.fileID = item.fileID;
		trashItem.driveID = item.driveID;
	}

	NSString *originalLocation = [OCDatabase normalizedTrashPath:item.path];
	NSString *originalFilename = item.name;

	trashItem.path = [self pendingTrashPathForSyncRecordID:syncRecordID originalLocation:originalLocation];
	trashItem.removed = NO;
	trashItem.databaseID = nil;

	[trashItem setValue:@YES forLocalAttribute:OCLocalAttributeTrashItem];
	[trashItem setValue:originalLocation forLocalAttribute:OCLocalAttributeTrashOriginalLocation];

	if (originalFilename.length > 0) {
		[trashItem setValue:originalFilename forLocalAttribute:OCLocalAttributeTrashOriginalFilename];
	}

	[trashItem setValue:@((long long)NSDate.date.timeIntervalSince1970) forLocalAttribute:OCLocalAttributeTrashDeletionTimestamp];
	[trashItem setValue:syncRecordID forLocalAttribute:OCLocalAttributeTrashPendingSyncRecordID];

	return (trashItem);
}

+ (BOOL)isPendingTrashItem:(OCItem *)item
{
	return ([self pendingSyncRecordIDForTrashItem:item] != nil);
}

+ (nullable OCSyncRecordID)pendingSyncRecordIDForTrashItem:(OCItem *)item
{
	if (item == nil) { return (nil); }

	id pendingSyncRecordID = [item valueForLocalAttribute:OCLocalAttributeTrashPendingSyncRecordID];

	if ([pendingSyncRecordID isKindOfClass:NSNumber.class]) {
		return ((NSNumber *)pendingSyncRecordID);
	}

	NSString *trashPath = [OCDatabase normalizedTrashPath:item.path];

	if ([trashPath hasPrefix:[OCTrashPendingItemsPathPrefix stringByAppendingString:@"/"]]) {
		NSArray<NSString *> *components = [trashPath pathComponents];

		if (components.count >= 2 && [components[0] isEqual:OCTrashPendingItemsPathPrefix]) {
			return (@(components[1].longLongValue));
		}
	}

	return (nil);
}

+ (BOOL)serverTrashItem:(OCItem *)serverItem matchesPendingTrashItem:(OCItem *)pendingItem
{
	if (serverItem == nil || pendingItem == nil) { return (NO); }

	NSString *pendingOriginalLocation = [pendingItem valueForLocalAttribute:OCLocalAttributeTrashOriginalLocation];
	NSString *serverOriginalLocation = [serverItem valueForLocalAttribute:OCLocalAttributeTrashOriginalLocation];

	if (pendingOriginalLocation.length > 0 && serverOriginalLocation.length > 0 &&
	    [pendingOriginalLocation isEqualToString:serverOriginalLocation]) {
		return (YES);
	}

	if (pendingItem.fileID.length > 0 && serverItem.fileID.length > 0 &&
	    [pendingItem.fileID isEqualToString:serverItem.fileID]) {
		return (YES);
	}

	NSString *pendingFilename = [pendingItem valueForLocalAttribute:OCLocalAttributeTrashOriginalFilename];
	NSString *serverFilename = [serverItem valueForLocalAttribute:OCLocalAttributeTrashOriginalFilename];

	if (pendingFilename.length > 0 && serverFilename.length > 0 &&
	    [pendingFilename isEqualToString:serverFilename] &&
	    pendingOriginalLocation.length > 0 && serverOriginalLocation.length > 0 &&
	    [pendingOriginalLocation.lastPathComponent isEqualToString:serverOriginalLocation.lastPathComponent]) {
		return (YES);
	}

	return (NO);
}

@end
