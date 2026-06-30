//
//  OCSyncActionTrashRestore.m
//  ownCloudSDK
//
//  Copyright © 2025 ownCloud GmbH. All rights reserved.
//

#import "OCSyncActionTrashRestore.h"
#import "OCConnection+Trash.h"
#import "OCDatabase+Trash.h"
#import "OCTrashPendingItems.h"
#import "OCCore+SyncEngine.h"
#import "OCMacros.h"
#import "NSError+OCError.h"

@implementation OCSyncActionTrashRestore

OCSYNCACTION_REGISTER_ISSUETEMPLATES

+ (OCSyncActionIdentifier)identifier
{
	return (OCSyncActionIdentifierTrashRestore);
}

- (instancetype)initWithItem:(OCItem *)item
{
	if ((self = [super initWithItem:item]) != nil)
	{
		_parentTrashPath = [OCDatabase parentTrashPathForItem:item];
		_driveID = item.driveID;
		self.actionEventType = OCEventTypeMove;
		self.localizedDescription = [NSString stringWithFormat:OCLocalizedString(@"Restoring %@…", nil), item.name];
	}

	return (self);
}

- (void)preflightWithContext:(OCSyncContext *)syncContext
{
	OCSyncExec(trashPreflight, {
		[self.core.vault.database removeTrashCacheItem:self.localItem completionHandler:^(OCDatabase *db, NSError *error) {
			if (error != nil) {
				syncContext.error = error;
			}

			OCSyncExecDone(trashPreflight);
		}];
	});
}

- (void)descheduleWithContext:(OCSyncContext *)syncContext
{
	OCSyncExec(trashDeschedule, {
		[self.core.vault.database addTrashCacheItems:@[ self.localItem ]
				     parentTrashPath:self.parentTrashPath
						 driveID:self.driveID
					   completionHandler:^(OCDatabase *db, NSError *error) {
			if (error != nil) {
				syncContext.error = error;
			}

			OCSyncExecDone(trashDeschedule);
		}];
	});
}

- (OCCoreSyncInstruction)scheduleWithContext:(OCSyncContext *)syncContext
{
	if ([OCTrashPendingItems isPendingTrashItem:self.localItem])
	{
		OCSyncRecordID pendingSyncRecordID = [OCTrashPendingItems pendingSyncRecordIDForTrashItem:self.localItem];

		OCSyncExec(trashRestorePending, {
			[self.core.vault.database retrieveSyncRecordForID:pendingSyncRecordID completionHandler:^(OCDatabase *db, NSError *error, OCSyncRecord *deleteSyncRecord) {
				if (deleteSyncRecord != nil)
				{
					[self.core descheduleSyncRecord:deleteSyncRecord completeWithError:nil parameter:nil];
				}

				OCSyncExecDone(trashRestorePending);
			}];
		});

		[syncContext completeWithError:nil core:self.core item:self.localItem parameter:nil];
		[syncContext transitionToState:OCSyncRecordStateCompleted withWaitConditions:nil];

		return (OCCoreSyncInstructionDeleteLast);
	}

	OCProgress *progress;

	if ((progress = [self.core.connection restoreTrashedItem:self.localItem resultTarget:[self.core _eventTargetWithSyncRecord:syncContext.syncRecord]]) != nil)
	{
		[syncContext.syncRecord addProgress:progress];
	}

	[syncContext transitionToState:OCSyncRecordStateProcessing withWaitConditions:nil];

	return (OCCoreSyncInstructionStop);
}

- (OCCoreSyncInstruction)handleResultWithContext:(OCSyncContext *)syncContext
{
	OCEvent *event = syncContext.event;
	OCCoreSyncInstruction resultInstruction = OCCoreSyncInstructionNone;

	[syncContext completeWithError:event.error core:self.core item:self.localItem parameter:event.result];

	if (event.error == nil)
	{
		[syncContext transitionToState:OCSyncRecordStateCompleted withWaitConditions:nil];
		resultInstruction = OCCoreSyncInstructionDeleteLast;
	}
	else if (event.error.isOCError && event.error.code == OCErrorResourceDoesNotExist)
	{
		[syncContext transitionToState:OCSyncRecordStateCompleted withWaitConditions:nil];
		resultInstruction = OCCoreSyncInstructionDeleteLast;
	}
	else if (event.error != nil)
	{
		[self _addIssueForCancellationAndDeschedulingToContext:syncContext title:[NSString stringWithFormat:OCLocalizedString(@"Couldn't restore %@", nil), self.localItem.name] description:event.error.localizedDescription impact:OCSyncIssueChoiceImpactNonDestructive];
		[syncContext transitionToState:OCSyncRecordStateProcessing withWaitConditions:nil];
	}

	return (resultInstruction);
}

- (NSSet<OCSyncLaneTag> *)generateLaneTags
{
	return ([self generateLaneTagsFromItems:@[ OCSyncActionWrapNullableItem(self.localItem) ]]);
}

- (void)decodeActionData:(NSCoder *)decoder
{
	_parentTrashPath = [decoder decodeObjectOfClass:[NSString class] forKey:@"parentTrashPath"];
	_driveID = [decoder decodeObjectOfClass:[NSString class] forKey:@"driveID"];
}

- (void)encodeActionData:(NSCoder *)coder
{
	[coder encodeObject:_parentTrashPath forKey:@"parentTrashPath"];
	[coder encodeObject:_driveID forKey:@"driveID"];
}

@end
