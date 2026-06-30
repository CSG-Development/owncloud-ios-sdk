//
//  OCConnection+Trash.h
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

#import "OCConnection.h"
#import "OCItem.h"
#import "OCEventTarget.h"
#import "OCEvent.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^OCConnectionTrashListCompletionHandler)(NSError * _Nullable error, NSArray<OCItem *> * _Nullable items);
typedef void(^OCConnectionTrashModificationCompletionHandler)(NSError * _Nullable error);

extern OCLocalAttribute OCLocalAttributeTrashItem;
extern OCLocalAttribute OCLocalAttributeTrashOriginalLocation;
extern OCLocalAttribute OCLocalAttributeTrashOriginalFilename;
extern OCLocalAttribute OCLocalAttributeTrashDeletionTimestamp;
extern OCLocalAttribute OCLocalAttributeTrashPendingSyncRecordID;

FOUNDATION_EXPORT NSNotificationName const OCTrashDebugLogNotification;
FOUNDATION_EXPORT NSString * const OCTrashDebugLogMessageKey;

FOUNDATION_EXPORT void OCTrashDebugLog(NSString *message);

@interface OCConnection (Trash)

- (BOOL)isTrashedItem:(OCItem *)item;

- (BOOL)trashedItemSupportsRawImageDownload:(OCItem *)item;

- (nullable NSString *)classicTrashPreviewFileParameterForItem:(OCItem *)item;

- (nullable NSString *)classicTrashPreviewCacheParameterForItem:(OCItem *)item;

- (nullable NSURL *)previewURLForTrashedItem:(OCItem *)item;

- (nullable NSURL *)previewURLForTrashedItemThumbnail:(OCItem *)item;

/**
 * Returns YES when trash content must be fetched by temporarily restoring the item to a
 * hidden files location, downloading it, then deleting it (which re-trashes it on classic ownCloud).
 * Classic ownCloud trash-bin WebDAV does not support GET for raw file content.
 */
- (BOOL)requiresTemporaryRestoreForTrashContentDownload:(OCItem *)item;

typedef void(^OCConnectionTrashDownloadCompletionHandler)(NSError * _Nullable error, NSURL * _Nullable localFileURL);

/**
 * Downloads the actual content of a trashed item to a local directory.
 * Uses temporary restore on classic ownCloud, direct trash-bin GET on oCIS/spaces.
 */
- (nullable NSProgress *)downloadTrashedItemContent:(OCItem *)item
                                   toLocalDirectory:(NSURL *)localDirectoryURL
                                    completionHandler:(OCConnectionTrashDownloadCompletionHandler)completionHandler;

/**
 * Builds a GET request for downloading trashed item content via trash-bin WebDAV (oCIS/spaces).
 */
- (nullable OCHTTPRequest *)trashItemContentDownloadRequestForItem:(OCItem *)item;

- (nullable NSProgress *)retrieveTrashedItemsWithCompletionHandler:(OCConnectionTrashListCompletionHandler)completionHandler;

- (nullable NSProgress *)retrieveTrashedItemsInFolder:(nullable OCItem *)folderItem completionHandler:(OCConnectionTrashListCompletionHandler)completionHandler;

- (nullable NSProgress *)restoreTrashedItem:(OCItem *)item completionHandler:(OCConnectionTrashModificationCompletionHandler)completionHandler;

- (nullable NSProgress *)restoreTrashedItem:(OCItem *)item resultTarget:(OCEventTarget *)eventTarget;

- (nullable NSProgress *)permanentlyDeleteTrashedItem:(OCItem *)item completionHandler:(OCConnectionTrashModificationCompletionHandler)completionHandler;

- (nullable NSProgress *)permanentlyDeleteTrashedItem:(OCItem *)item resultTarget:(OCEventTarget *)eventTarget;

@end

NS_ASSUME_NONNULL_END
