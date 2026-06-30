//
//  OCDatabase+Trash.m
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

#import "OCDatabase+Trash.h"
#import "OCDatabase+Schemas.h"
#import "OCTrashPendingItems.h"
#import "OCItem.h"
#import "OCLogger.h"
#import "OCSQLiteTransaction.h"
#import "OCSQLiteQuery.h"

@implementation OCDatabase (Trash)

+ (BOOL)isPendingTrashPath:(NSString *)trashPath
{
	NSString *normalized = [self normalizedTrashPath:trashPath];

	return ([normalized hasPrefix:[OCTrashPendingItemsPathPrefix stringByAppendingString:@"/"]]);
}

+ (NSString *)normalizedTrashPath:(nullable NSString *)path
{
	NSString *normalized = path ?: @"";

	while ([normalized hasPrefix:@"/"]) {
		normalized = [normalized substringFromIndex:1];
	}

	if ([normalized hasSuffix:@"/"]) {
		normalized = [normalized substringToIndex:normalized.length - 1];
	}

	return (normalized);
}

+ (NSString *)parentTrashPathForItem:(OCItem *)item
{
	NSString *trashPath = [self normalizedTrashPath:item.path];
	NSUInteger slashIndex = [trashPath rangeOfString:@"/" options:NSBackwardsSearch].location;

	if (slashIndex == NSNotFound) {
		return (@"");
	}

	return ([trashPath substringToIndex:slashIndex]);
}

- (OCItem *)_trashItemFromResultDict:(NSDictionary<NSString *, id<NSObject>> *)resultDict
{
	NSData *itemData = (NSData *)resultDict[@"itemData"];

	if (itemData == nil) { return (nil); }

	OCItem *item = [OCItem itemFromSerializedData:itemData];

	if (item != nil) {
		item.databaseID = resultDict[@"mdID"];
	}

	return (item);
}

- (void)retrieveTrashCacheItemsWithParentTrashPath:(NSString *)parentTrashPath
					   driveID:(nullable OCDriveID)driveID
			     completionHandler:(OCDatabaseRetrieveCompletionHandler)completionHandler
{
	NSString *sqlQuery = [@"SELECT mdID, itemData FROM trashMetaData WHERE parentTrashPath=? AND removed=0" stringByAppendingString:((driveID == nil) ? @" AND driveID IS NULL" : @" AND driveID=?")];
	NSArray *parameters = ((driveID == nil) ? @[ parentTrashPath ] : @[ parentTrashPath, driveID ]);

	[self.sqlDB executeQuery:[OCSQLiteQuery query:sqlQuery withParameters:parameters resultHandler:^(OCSQLiteDB *db, NSError *error, OCSQLiteTransaction *transaction, OCSQLiteResultSet *resultSet) {
		if (error != nil) {
			completionHandler(self, error, nil, nil);
			return;
		}

		NSMutableArray<OCItem *> *items = [NSMutableArray new];

		[resultSet iterateUsing:^(OCSQLiteResultSet *resultSet, NSUInteger line, NSDictionary<NSString *, id<NSObject>> *resultDict, BOOL *stop) {
			OCItem *item;

			if ((item = [self _trashItemFromResultDict:resultDict]) != nil) {
				[items addObject:item];
			}
		} error:&error];

		completionHandler(self, error, nil, items);
	}]];
}

- (void)replaceTrashCacheItems:(NSArray<OCItem *> *)items
	       parentTrashPath:(NSString *)parentTrashPath
		       driveID:(nullable OCDriveID)driveID
	     completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler
{
	NSNumber *lastUpdated = @((NSUInteger)NSDate.timeIntervalSinceReferenceDate);
	NSMutableArray<OCSQLiteQuery *> *queries = [NSMutableArray new];
	NSString *deleteSQL = ((driveID == nil) ?
			       @"DELETE FROM trashMetaData WHERE parentTrashPath=? AND driveID IS NULL AND trashPath NOT LIKE ?" :
			       @"DELETE FROM trashMetaData WHERE parentTrashPath=? AND driveID=? AND trashPath NOT LIKE ?");
	NSString *pendingPrefix = [OCTrashPendingItemsPathPrefix stringByAppendingString:@"/%"];
	NSArray *deleteParameters = ((driveID == nil) ?
				     @[ parentTrashPath, pendingPrefix ] :
				     @[ parentTrashPath, driveID, pendingPrefix ]);

	[queries addObject:[OCSQLiteQuery query:deleteSQL withParameters:deleteParameters resultHandler:nil]];

	for (OCItem *item in items) {
		NSString *trashPath = [OCDatabase normalizedTrashPath:item.path];

		if (trashPath.length == 0) { continue; }

		[queries addObject:[OCSQLiteQuery queryInsertingIntoTable:OCDatabaseTableNameTrashMetaData rowValues:@{
			@"trashPath" : trashPath,
			@"parentTrashPath" : parentTrashPath,
			@"driveID" : OCSQLiteNullProtect(item.driveID ?: driveID),
			@"fileID" : OCSQLiteNullProtect(item.fileID),
			@"name" : OCSQLiteNullProtect(item.name),
			@"lastUpdated" : lastUpdated,
			@"removed" : @(0),
			@"itemData" : [item serializedData]
		} resultHandler:nil]];
	}

	[self.sqlDB executeTransaction:[OCSQLiteTransaction transactionWithQueries:queries type:OCSQLiteTransactionTypeDeferred completionHandler:^(OCSQLiteDB *db, OCSQLiteTransaction *transaction, NSError *txnError) {
		completionHandler(self, txnError);
	}]];
}

- (void)addTrashCacheItems:(NSArray<OCItem *> *)items
	       parentTrashPath:(NSString *)parentTrashPath
		       driveID:(nullable OCDriveID)driveID
	     completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler
{
	if (items.count == 0) {
		completionHandler(self, nil);
		return;
	}

	NSNumber *lastUpdated = @((NSUInteger)NSDate.timeIntervalSinceReferenceDate);
	NSMutableArray<OCSQLiteQuery *> *queries = [NSMutableArray new];

	for (OCItem *item in items) {
		NSString *trashPath = [OCDatabase normalizedTrashPath:item.path];

		if (trashPath.length == 0) { continue; }

		[queries addObject:[OCSQLiteQuery queryInsertingIntoTable:OCDatabaseTableNameTrashMetaData rowValues:@{
			@"trashPath" : trashPath,
			@"parentTrashPath" : parentTrashPath,
			@"driveID" : OCSQLiteNullProtect(item.driveID ?: driveID),
			@"fileID" : OCSQLiteNullProtect(item.fileID),
			@"name" : OCSQLiteNullProtect(item.name),
			@"lastUpdated" : lastUpdated,
			@"removed" : @(0),
			@"itemData" : [item serializedData]
		} resultHandler:nil]];
	}

	[self.sqlDB executeTransaction:[OCSQLiteTransaction transactionWithQueries:queries type:OCSQLiteTransactionTypeDeferred completionHandler:^(OCSQLiteDB *db, OCSQLiteTransaction *transaction, NSError *txnError) {
		completionHandler(self, txnError);
	}]];
}

- (void)removeTrashCacheItem:(OCItem *)item
	     completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler
{
	[self removeTrashCacheItems:((item != nil) ? @[ item ] : @[]) completionHandler:completionHandler];
}

- (void)removeTrashCacheItems:(NSArray<OCItem *> *)items
	      completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler
{
	if (items.count == 0) {
		completionHandler(self, nil);
		return;
	}

	NSMutableArray<OCSQLiteQuery *> *queries = [NSMutableArray new];

	for (OCItem *item in items) {
		NSString *trashPath = [OCDatabase normalizedTrashPath:item.path];

		if (trashPath.length == 0) { continue; }

		NSDictionary *where = ((item.driveID == nil) ?
				       @{ @"trashPath" : trashPath, @"driveID" : NSNull.null } :
				       @{ @"trashPath" : trashPath, @"driveID" : item.driveID });

		[queries addObject:[OCSQLiteQuery queryDeletingRowsWhere:where fromTable:OCDatabaseTableNameTrashMetaData completionHandler:nil]];
	}

	[self.sqlDB executeTransaction:[OCSQLiteTransaction transactionWithQueries:queries type:OCSQLiteTransactionTypeDeferred completionHandler:^(OCSQLiteDB *db, OCSQLiteTransaction *transaction, NSError *txnError) {
		completionHandler(self, txnError);
	}]];
}

- (void)removePendingTrashCacheItemForSyncRecordID:(OCSyncRecordID)syncRecordID
				   completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler
{
	if (syncRecordID == nil) {
		completionHandler(self, nil);
		return;
	}

	NSString *deleteSQL = @"DELETE FROM trashMetaData WHERE trashPath LIKE ?";
	NSString *pathPattern = [NSString stringWithFormat:@"%@/%@/%%", OCTrashPendingItemsPathPrefix, syncRecordID];

	[self.sqlDB executeQuery:[OCSQLiteQuery query:deleteSQL withParameters:@[ pathPattern ] resultHandler:^(OCSQLiteDB *db, NSError *error, OCSQLiteTransaction *transaction, OCSQLiteResultSet *resultSet) {
		completionHandler(self, error);
	}]];
}

- (void)removePendingTrashCacheItemsMatchingServerItems:(NSArray<OCItem *> *)serverItems
						driveID:(nullable OCDriveID)driveID
					      completionHandler:(OCDatabaseTrashCacheCompletionHandler)completionHandler
{
	if (serverItems.count == 0) {
		completionHandler(self, nil);
		return;
	}

	NSString *selectSQL = [@"SELECT mdID, itemData FROM trashMetaData WHERE parentTrashPath='' AND removed=0 AND trashPath LIKE ?" stringByAppendingString:((driveID == nil) ? @" AND driveID IS NULL" : @" AND driveID=?")];
	NSString *pendingPrefix = [OCTrashPendingItemsPathPrefix stringByAppendingString:@"/%"];
	NSArray *selectParameters = ((driveID == nil) ? @[ pendingPrefix ] : @[ pendingPrefix, driveID ]);

	[self.sqlDB executeQuery:[OCSQLiteQuery query:selectSQL withParameters:selectParameters resultHandler:^(OCSQLiteDB *db, NSError *error, OCSQLiteTransaction *transaction, OCSQLiteResultSet *resultSet) {
		if (error != nil) {
			completionHandler(self, error);
			return;
		}

		NSMutableArray<OCItem *> *pendingItemsToRemove = [NSMutableArray new];

		[resultSet iterateUsing:^(OCSQLiteResultSet *resultSet, NSUInteger line, NSDictionary<NSString *, id<NSObject>> *resultDict, BOOL *stop) {
			OCItem *pendingItem;

			if ((pendingItem = [self _trashItemFromResultDict:resultDict]) != nil) {
				for (OCItem *serverItem in serverItems) {
					if ([OCTrashPendingItems serverTrashItem:serverItem matchesPendingTrashItem:pendingItem]) {
						[pendingItemsToRemove addObject:pendingItem];
						break;
					}
				}
			}
		} error:&error];

		if (error != nil || pendingItemsToRemove.count == 0) {
			completionHandler(self, error);
			return;
		}

		[self removeTrashCacheItems:pendingItemsToRemove completionHandler:completionHandler];
	}]];
}

@end
