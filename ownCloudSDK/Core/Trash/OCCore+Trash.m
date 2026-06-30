//
//  OCCore+Trash.m
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

#import "OCCore+Trash.h"
#import "OCCore+Internal.h"
#import "OCCore+SyncEngine.h"
#import "OCConnection+Trash.h"
#import "OCDatabase+Trash.h"
#import "OCDrive.h"
#import "OCTrashPendingItems.h"
#import "OCSyncActionTrashRestore.h"
#import "OCSyncActionTrashPurge.h"
#import "OCLogger.h"
#import "OCMacros.h"
#import "NSError+OCError.h"

@implementation OCCore (Trash)

- (OCDriveID)_trashDriveIDForFolderItem:(nullable OCItem *)folderItem items:(nullable NSArray<OCItem *> *)items
{
	if (folderItem.driveID.length > 0) {
		return (folderItem.driveID);
	}

	for (OCItem *item in items) {
		if (item.driveID.length > 0) {
			return (item.driveID);
		}
	}

	return (self.personalDrive.identifier);
}

- (NSString *)_parentTrashPathForFolderItem:(nullable OCItem *)folderItem
{
	return ([OCDatabase normalizedTrashPath:folderItem.path]);
}

- (void)_deliverTrashListFromCacheForFolderItem:(nullable OCItem *)folderItem
					  driveID:(nullable OCDriveID)driveID
			      completionHandler:(OCCoreTrashListCompletionHandler)completionHandler
{
	NSString *parentTrashPath = [self _parentTrashPathForFolderItem:folderItem];

	[self.vault.database retrieveTrashCacheItemsWithParentTrashPath:parentTrashPath driveID:driveID completionHandler:^(OCDatabase *db, NSError *error, OCSyncAnchor syncAnchor, NSArray<OCItem *> *items) {
		if (completionHandler != nil) {
			completionHandler(error, items, YES);
		}
	}];
}

- (nullable NSProgress *)retrieveTrashedItemsInFolder:(nullable OCItem *)folderItem
				     completionHandler:(OCCoreTrashListCompletionHandler)completionHandler
{
	__block OCDriveID driveID = folderItem.driveID;

	[self queueBlock:^{
		if (driveID.length == 0) {
			driveID = self.personalDrive.identifier;
		}

		[self _deliverTrashListFromCacheForFolderItem:folderItem driveID:driveID completionHandler:completionHandler];

		if (self.connectionStatus != OCCoreConnectionStatusOnline) {
			return;
		}

		NSString *parentTrashPath = [self _parentTrashPathForFolderItem:folderItem];

		[self queueConnectivityBlock:^{
			NSProgress *progress = [self.connection retrieveTrashedItemsInFolder:folderItem completionHandler:^(NSError *error, NSArray<OCItem *> *serverItems) {
				[self queueBlock:^{
					OCDriveID resolvedDriveID = [self _trashDriveIDForFolderItem:folderItem items:serverItems];

					if (resolvedDriveID.length == 0) {
						resolvedDriveID = driveID;
					}

					if (error != nil) {
						if (completionHandler != nil) {
							completionHandler(error, serverItems, NO);
						}
						return;
					}

					void (^replaceCache)(void) = ^{
						[self.vault.database replaceTrashCacheItems:(serverItems ?: @[])
									      parentTrashPath:parentTrashPath
										      driveID:resolvedDriveID
									    completionHandler:^(OCDatabase *db, NSError *cacheError) {
							if (completionHandler != nil) {
								completionHandler(cacheError, serverItems, NO);
							}
						}];
					};

					if (parentTrashPath.length == 0) {
						[self.vault.database removePendingTrashCacheItemsMatchingServerItems:(serverItems ?: @[])
											     driveID:resolvedDriveID
										       completionHandler:^(OCDatabase *db, NSError *reconcileError) {
							replaceCache();
						}];
					} else {
						replaceCache();
					}
				}];
			}];

			if (progress == nil && completionHandler != nil) {
				completionHandler(OCError(OCErrorInternal), nil, NO);
			}
		}];
	}];

	return (nil);
}

- (nullable NSProgress *)restoreTrashedItem:(OCItem *)item
			      resultHandler:(OCCoreActionResultHandler)resultHandler
{
	if (item == nil) {
		if (resultHandler != nil) {
			resultHandler(OCError(OCErrorInvalidParameter), self, nil, nil);
		}
		return (nil);
	}

	return ([self _enqueueSyncRecordWithAction:[[OCSyncActionTrashRestore alloc] initWithItem:item] cancellable:NO resultHandler:resultHandler]);
}

- (nullable NSProgress *)permanentlyDeleteTrashedItem:(OCItem *)item
					resultHandler:(OCCoreActionResultHandler)resultHandler
{
	if (item == nil) {
		if (resultHandler != nil) {
			resultHandler(OCError(OCErrorInvalidParameter), self, nil, nil);
		}
		return (nil);
	}

	return ([self _enqueueSyncRecordWithAction:[[OCSyncActionTrashPurge alloc] initWithItem:item] cancellable:NO resultHandler:resultHandler]);
}

- (nullable NSProgress *)downloadTrashedItem:(OCItem *)item
                               resultHandler:(OCCoreTrashDownloadResultHandler)resultHandler
{
	if (item == nil) {
		if (resultHandler != nil) {
			resultHandler(OCError(OCErrorInvalidParameter), nil);
		}
		return (nil);
	}

	NSURL *tempDirURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
		URLByAppendingPathComponent:[[NSUUID UUID] UUIDString]
		isDirectory:YES];

	NSError *mkdirError = nil;
	[[NSFileManager defaultManager] createDirectoryAtURL:tempDirURL
					 withIntermediateDirectories:YES
						      attributes:nil
							   error:&mkdirError];
	if (mkdirError != nil) {
		OCLogError(@"[Trash] downloadTrashedItem: failed to create temp dir: %@", mkdirError);
		if (resultHandler != nil) {
			resultHandler(mkdirError, nil);
		}
		return (nil);
	}

	OCLogDebug(@"[Trash] downloadTrashedItem: item=%@ tempRestore=%@",
		item.path,
		[self.connection requiresTemporaryRestoreForTrashContentDownload:item] ? @"YES" : @"NO");

	return ([self.connection downloadTrashedItemContent:item
				       toLocalDirectory:tempDirURL
				    completionHandler:resultHandler]);
}

@end
