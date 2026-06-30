//
//  OCSyncActionTrashPurge.m
//  ownCloudSDK
//
//  Copyright © 2025 ownCloud GmbH. All rights reserved.
//

#import "OCSyncActionTrashPurge.h"
#import "OCConnection+Trash.h"
#import "OCDatabase+Trash.h"
#import "OCTrashPendingItems.h"
#import "OCCore+SyncEngine.h"
#import "OCMacros.h"
#import "NSError+OCError.h"

@implementation OCSyncActionTrashPurge

OCSYNCACTION_REGISTER_ISSUETEMPLATES

+ (OCSyncActionIdentifier)identifier
{
	return (OCSyncActionIdentifierTrashPurge);
}

- (instancetype)initWithItem:(OCItem *)item
{
	if ((self = [super initWithItem:item]) != nil)
	{
		_parentTrashPath = [OCDatabase parentTrashPathForItem:item];
		_driveID = item.driveID;
		self.actionEventType = OCEventTypeDelete;
		self.localizedDescription = [NSString stringWithFormat:OCLocalizedString(@"Deleting %@…", nil), item.name];
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
		[syncContext completeWithError:nil core:self.core item:self.localItem parameter:nil];
		[syncContext transitionToState:OCSyncRecordStateCompleted withWaitConditions:nil];

		return (OCCoreSyncInstructionDeleteLast);
	}

	OCProgress *progress;

	if ((progress = [self.core.connection permanentlyDeleteTrashedItem:self.localItem resultTarget:[self.core _eventTargetWithSyncRecord:syncContext.syncRecord]]) != nil)
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
		[self _addIssueForCancellationAndDeschedulingToContext:syncContext title:[NSString stringWithFormat:OCLocalizedString(@"Couldn't delete %@", nil), self.localItem.name] description:event.error.localizedDescription impact:OCSyncIssueChoiceImpactDataLoss];
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
