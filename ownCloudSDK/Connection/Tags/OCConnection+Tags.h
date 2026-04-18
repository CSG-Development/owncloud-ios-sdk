//
//  OCConnection+Tags.h
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
#import "OCSystemTag.h"
#import "OCItem.h"
#import "OCEvent.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^OCConnectionTagsListCompletionHandler)(NSError * _Nullable error, NSArray<OCSystemTag *> * _Nullable tags);
typedef void(^OCConnectionTagCompletionHandler)(NSError * _Nullable error, OCSystemTag * _Nullable tag);
typedef void(^OCConnectionTagModificationCompletionHandler)(NSError * _Nullable error);
typedef void(^OCConnectionFileTagsCompletionHandler)(NSError * _Nullable error, NSArray<OCSystemTag *> * _Nullable tags);

@interface OCConnection (Tags)

#pragma mark - List Tags
- (nullable NSProgress *)retrieveSystemTagsWithCompletionHandler:(OCConnectionTagsListCompletionHandler)completionHandler;

#pragma mark - Create Tag
- (nullable NSProgress *)createSystemTagWithName:(NSString *)name userVisible:(BOOL)userVisible userAssignable:(BOOL)userAssignable completionHandler:(OCConnectionTagCompletionHandler)completionHandler;

#pragma mark - Update Tag
- (nullable NSProgress *)updateSystemTag:(OCSystemTag *)tag withDisplayName:(NSString *)displayName completionHandler:(OCConnectionTagModificationCompletionHandler)completionHandler;

#pragma mark - Delete Tag
- (nullable NSProgress *)deleteSystemTag:(OCSystemTag *)tag completionHandler:(OCConnectionTagModificationCompletionHandler)completionHandler;

#pragma mark - Tags for File
- (nullable NSProgress *)retrieveTagsForFileWithID:(OCFileID)fileID completionHandler:(OCConnectionFileTagsCompletionHandler)completionHandler;

#pragma mark - Assign Tag to File
- (nullable NSProgress *)assignTag:(OCSystemTag *)tag toFileWithID:(OCFileID)fileID completionHandler:(OCConnectionTagModificationCompletionHandler)completionHandler;

#pragma mark - Unassign Tag from File
- (nullable NSProgress *)unassignTag:(OCSystemTag *)tag fromFileWithID:(OCFileID)fileID completionHandler:(OCConnectionTagModificationCompletionHandler)completionHandler;

#pragma mark - Create and Assign Tag to File
- (nullable NSProgress *)createAndAssignTagWithName:(NSString *)name userVisible:(BOOL)userVisible userAssignable:(BOOL)userAssignable toFileWithID:(OCFileID)fileID completionHandler:(OCConnectionTagCompletionHandler)completionHandler;

#pragma mark - Retrieve Files by Tag
- (nullable OCProgress *)retrieveFilesWithTag:(OCSystemTag *)tag resultTarget:(OCEventTarget *)eventTarget;

@end

NS_ASSUME_NONNULL_END
