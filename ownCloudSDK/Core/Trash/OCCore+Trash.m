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
#import "OCSyncRecord.h"
#import "OCLogger.h"
#import "OCMacros.h"
#import "NSError+OCError.h"
#import <objc/runtime.h>

static const void *OCCorePendingTrashPurgeItemsKey = &OCCorePendingTrashPurgeItemsKey;
static const void *OCCorePendingTrashPurgeLockKey = &OCCorePendingTrashPurgeLockKey;

static NSString *OCTrashIdentityPath(NSString *path)
{
	return ([OCDatabase normalizedTrashPath:path]);
}

static BOOL OCTrashItemMatchesPurgedItem(OCItem *item, OCItem *purgedItem)
{
	if (item == nil || purgedItem == nil) { return (NO); }

	NSString *itemPath = OCTrashIdentityPath(item.path);
	NSString *purgedPath = OCTrashIdentityPath(purgedItem.path);

	if ((itemPath.length > 0) && (purgedPath.length > 0) && [itemPath isEqualToString:purgedPath]) {
		return (YES);
	}

	if ((item.fileID.length > 0) && (purgedItem.fileID.length > 0) && [item.fileID isEqualToString:purgedItem.fileID]) {
		return (YES);
	}

	if ((item.eTag.length > 0) && (purgedItem.eTag.length > 0) && [item.eTag isEqualToString:purgedItem.eTag]) {
		return (YES);
	}

	NSString *itemLeaf = itemPath.lastPathComponent;
	NSString *purgedLeaf = purgedPath.lastPathComponent;

	if ((item.fileID.length > 0) && (purgedLeaf.length > 0) && [item.fileID isEqualToString:purgedLeaf]) {
		return (YES);
	}

	if ((purgedItem.fileID.length > 0) && (itemLeaf.length > 0) && [purgedItem.fileID isEqualToString:itemLeaf]) {
		return (YES);
	}

	return (NO);
}

@implementation OCCore (Trash)

- (NSLock *)_pendingTrashPurgeLock
{
	@synchronized (self) {
		NSLock *lock = objc_getAssociatedObject(self, OCCorePendingTrashPurgeLockKey);

		if (lock == nil) {
			lock = [NSLock new];
			objc_setAssociatedObject(self, OCCorePendingTrashPurgeLockKey, lock, OBJC_ASSOCIATION_RETAIN);
		}

		return (lock);
	}
}

- (void)_mutatePendingTrashPurges:(void (^)(NSMutableArray<OCItem *> *items))block
{
	if (block == nil) { return; }

	NSLock *lock = [self _pendingTrashPurgeLock];
	[lock lock];

	NSMutableArray<OCItem *> *items = objc_getAssociatedObject(self, OCCorePendingTrashPurgeItemsKey);

	if (items == nil) {
		items = [NSMutableArray new];
		objc_setAssociatedObject(self, OCCorePendingTrashPurgeItemsKey, items, OBJC_ASSOCIATION_RETAIN);
	}

	block(items);
	[lock unlock];
}

- (NSArray<OCItem *> *)_pendingTrashPurgeSnapshot
{
	__block NSArray<OCItem *> *snapshot = nil;

	[self _mutatePendingTrashPurges:^(NSMutableArray<OCItem *> *items) {
		snapshot = [items copy];
	}];

	return (snapshot ?: @[]);
}

- (OCItem *)_trashPurgeSnapshotOfItem:(OCItem *)item
{
	if (item == nil) { return (nil); }

	OCItem *snapshot = [OCItem itemFromSerializedData:[item serializedData]];

	return (snapshot ?: item);
}

- (void)noteTrashPurgeScheduledForItem:(OCItem *)item
{
	OCItem *snapshot = [self _trashPurgeSnapshotOfItem:item];

	if (snapshot == nil) { return; }

	[self _mutatePendingTrashPurges:^(NSMutableArray<OCItem *> *items) {
		for (OCItem *existing in items) {
			if (OCTrashItemMatchesPurgedItem(existing, snapshot)) {
				return;
			}
		}

		[items addObject:snapshot];
	}];
}

- (void)noteTrashPurgeCancelledForItem:(OCItem *)item
{
	if (item == nil) { return; }

	[self _mutatePendingTrashPurges:^(NSMutableArray<OCItem *> *items) {
		NSIndexSet *indexes = [items indexesOfObjectsPassingTest:^BOOL(OCItem *existing, NSUInteger idx, BOOL *stop) {
			return (OCTrashItemMatchesPurgedItem(existing, item));
		}];

		if (indexes.count > 0) {
			[items removeObjectsAtIndexes:indexes];
		}
	}];

	[NSNotificationCenter.defaultCenter postNotificationName:@"OCTrashPendingPurgeCancelled" object:self userInfo:@{ @"item" : item }];
}

- (void)_absorbPendingTrashPurgeRecords:(NSArray<OCSyncRecord *> *)records
{
	for (OCSyncRecord *record in records) {
		[self noteTrashPurgeScheduledForItem:record.action.localItem];
	}
}

- (void)_retrievePendingTrashPurgeRecords:(void (^)(NSArray<OCSyncRecord *> *records))completionHandler
{
	[self.vault.database retrieveSyncRecordsForPath:nil action:OCSyncActionIdentifierTrashPurge inProgressSince:nil completionHandler:^(OCDatabase *db, NSError *error, NSArray<OCSyncRecord *> *syncRecords) {
		if (completionHandler != nil) {
			completionHandler(syncRecords ?: @[]);
		}
	}];
}

- (BOOL)_trashItem:(OCItem *)item isPendingPermanentDeletion:(NSArray<OCItem *> *)pendingItems
{
	for (OCItem *pendingItem in pendingItems) {
		if (OCTrashItemMatchesPurgedItem(item, pendingItem)) {
			return (YES);
		}
	}

	return (NO);
}

- (NSArray<OCItem *> *)trashItemsByHidingPendingPermanentDeletions:(NSArray<OCItem *> *)items
{
	NSArray<OCItem *> *pendingItems = [self _pendingTrashPurgeSnapshot];

	if (pendingItems.count == 0 || items.count == 0) {
		return (items ?: @[]);
	}

	NSMutableArray<OCItem *> *visibleItems = [NSMutableArray arrayWithCapacity:items.count];
	NSUInteger hiddenCount = 0;

	for (OCItem *item in items) {
		if ([self _trashItem:item isPendingPermanentDeletion:pendingItems]) {
			hiddenCount += 1;
		} else {
			[visibleItems addObject:item];
		}
	}

	if (hiddenCount > 0) {
		OCLogDebug(@"[Trash] hid %lu item(s) with a pending permanent deletion", (unsigned long)hiddenCount);
	}

	return (visibleItems);
}

- (void)_dropConfirmedTrashPurgesForServerItems:(NSArray<OCItem *> *)serverItems
				parentTrashPath:(NSString *)parentTrashPath
				  protectedItems:(NSArray<OCItem *> *)protectedItems
{
	NSString *folderPath = parentTrashPath ?: @"";

	[self _mutatePendingTrashPurges:^(NSMutableArray<OCItem *> *items) {
		NSIndexSet *indexes = [items indexesOfObjectsPassingTest:^BOOL(OCItem *pendingItem, NSUInteger idx, BOOL *stop) {
			NSString *pendingParentPath = [OCDatabase parentTrashPathForItem:pendingItem] ?: @"";

			if (![pendingParentPath isEqualToString:folderPath]) {
				return (NO);
			}

			for (OCItem *protectedItem in protectedItems) {
				if (OCTrashItemMatchesPurgedItem(pendingItem, protectedItem)) {
					return (NO);
				}
			}

			for (OCItem *serverItem in serverItems) {
				if (OCTrashItemMatchesPurgedItem(serverItem, pendingItem)) {
					return (NO);
				}
			}

			return (YES);
		}];

		if (indexes.count > 0) {
			[items removeObjectsAtIndexes:indexes];
		}
	}];
}

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

	[self _retrievePendingTrashPurgeRecords:^(NSArray<OCSyncRecord *> *records) {
		[self _absorbPendingTrashPurgeRecords:records];

		[self.vault.database retrieveTrashCacheItemsWithParentTrashPath:parentTrashPath driveID:driveID completionHandler:^(OCDatabase *db, NSError *error, OCSyncAnchor syncAnchor, NSArray<OCItem *> *items) {
			if (completionHandler != nil) {
				NSArray<OCItem *> *visibleItems = (error == nil) ? [self trashItemsByHidingPendingPermanentDeletions:(items ?: @[])] : items;
				completionHandler(error, visibleItems, YES);
			}
		}];
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

					[self _retrievePendingTrashPurgeRecords:^(NSArray<OCSyncRecord *> *records) {
						NSMutableArray<OCItem *> *protectedItems = [NSMutableArray new];

						for (OCSyncRecord *record in records) {
							if (record.action.localItem != nil) {
								[protectedItems addObject:record.action.localItem];
							}
						}

						[self _absorbPendingTrashPurgeRecords:records];

						NSArray<OCItem *> *visibleItems = [self trashItemsByHidingPendingPermanentDeletions:(serverItems ?: @[])];

						void (^replaceCache)(void) = ^{
							[self.vault.database replaceTrashCacheItems:visibleItems
										      parentTrashPath:parentTrashPath
											      driveID:resolvedDriveID
										    completionHandler:^(OCDatabase *db, NSError *cacheError) {
								if (cacheError == nil) {
									[self _dropConfirmedTrashPurgesForServerItems:(serverItems ?: @[])
												       parentTrashPath:parentTrashPath
													 protectedItems:protectedItems];
								}

								if (completionHandler != nil) {
									completionHandler(cacheError, visibleItems, NO);
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
	return ([self permanentlyDeleteTrashedItem:item enqueueCompletionHandler:nil resultHandler:resultHandler]);
}

- (nullable NSProgress *)permanentlyDeleteTrashedItem:(OCItem *)item
			   enqueueCompletionHandler:(OCCoreCompletionHandler)enqueueCompletionHandler
					resultHandler:(OCCoreActionResultHandler)resultHandler
{
	if (item == nil) {
		if (enqueueCompletionHandler != nil) {
			enqueueCompletionHandler(OCError(OCErrorInvalidParameter));
		}
		if (resultHandler != nil) {
			resultHandler(OCError(OCErrorInvalidParameter), self, nil, nil);
		}
		return (nil);
	}

	[self noteTrashPurgeScheduledForItem:item];

	return ([self _enqueueSyncRecordWithAction:[[OCSyncActionTrashPurge alloc] initWithItem:item]
					  cancellable:NO
			     preflightResultHandler:^(NSError *error) {
		if (error != nil) {
			[self noteTrashPurgeCancelledForItem:item];
		}

		if (enqueueCompletionHandler != nil) {
			enqueueCompletionHandler(error);
		}
	}
					 resultHandler:resultHandler]);
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

- (void)removeTrashedItemFromCache:(OCItem *)item
		 completionHandler:(void (^)(NSError * _Nullable))completionHandler
{
	if (item == nil)
	{
		if (completionHandler != nil)
		{
			completionHandler(OCError(OCErrorInvalidParameter));
		}

		return;
	}

	[self queueBlock:^{
		[self.vault.database removeTrashCacheItem:item completionHandler:^(OCDatabase *db, NSError *error) {
			if (completionHandler != nil)
			{
				completionHandler(error);
			}
		}];
	}];
}

@end
