//
//  OCCore+Trash.h
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

#import "OCCore.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^OCCoreTrashListCompletionHandler)(NSError * _Nullable error, NSArray<OCItem *> * _Nullable items, BOOL fromCache);
typedef void(^OCCoreTrashDownloadResultHandler)(NSError * _Nullable error, NSURL * _Nullable localFileURL);

@interface OCCore (Trash)

- (nullable NSProgress *)retrieveTrashedItemsInFolder:(nullable OCItem *)folderItem
				     completionHandler:(OCCoreTrashListCompletionHandler)completionHandler;

- (nullable NSProgress *)restoreTrashedItem:(OCItem *)item
			      resultHandler:(nullable OCCoreActionResultHandler)resultHandler;

- (nullable NSProgress *)permanentlyDeleteTrashedItem:(OCItem *)item
					resultHandler:(nullable OCCoreActionResultHandler)resultHandler;

/**
 * Downloads a trashed item's actual file content to a temporary local directory.
 * Classic ownCloud temporarily restores the item to a hidden folder, downloads via
 * the regular files WebDAV endpoint, then deletes the copy (which re-trashes it).
 * oCIS / spaces accounts download directly from the trash-bin WebDAV endpoint.
 */
- (nullable NSProgress *)downloadTrashedItem:(OCItem *)item
                               resultHandler:(OCCoreTrashDownloadResultHandler)resultHandler;

@end

NS_ASSUME_NONNULL_END
