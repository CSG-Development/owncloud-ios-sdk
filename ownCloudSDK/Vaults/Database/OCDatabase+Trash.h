//
//  OCDatabase+Trash.h
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

#import "OCDatabase.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^OCDatabaseTrashCacheCompletionHandler)(OCDatabase *db, NSError * _Nullable error);

@interface OCDatabase (Trash)

- (void)retrieveTrashCacheItemsWithParentTrashPath:(NSString *)parentTrashPath
					   driveID:(nullable OCDriveID)driveID
			     completionHandler:(OCDatabaseRetrieveCompletionHandler)completionHandler;

- (void)replaceTrashCacheItems:(NSArray<OCItem *> *)items
	       parentTrashPath:(NSString *)parentTrashPath
		       driveID:(nullable OCDriveID)driveID
	     completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler;

- (void)addTrashCacheItems:(NSArray<OCItem *> *)items
	       parentTrashPath:(NSString *)parentTrashPath
		       driveID:(nullable OCDriveID)driveID
	     completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler;

- (void)removeTrashCacheItem:(OCItem *)item
	     completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler;

- (void)removeTrashCacheItems:(NSArray<OCItem *> *)items
	      completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler;

- (void)removePendingTrashCacheItemForSyncRecordID:(OCSyncRecordID)syncRecordID
				   completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler;

- (void)removePendingTrashCacheItemsMatchingServerItems:(NSArray<OCItem *> *)serverItems
						driveID:(nullable OCDriveID)driveID
					      completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler;

+ (BOOL)isPendingTrashPath:(NSString *)trashPath;

+ (NSString *)normalizedTrashPath:(nullable NSString *)path;

+ (NSString *)parentTrashPathForItem:(OCItem *)item;

@end

NS_ASSUME_NONNULL_END
