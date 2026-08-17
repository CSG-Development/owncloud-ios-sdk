//
//  OCSyncActionUpload.m
//  ownCloudSDK
//
//  Created by Felix Schwarz on 06.09.18.
//  Copyright © 2018 ownCloud GmbH. All rights reserved.
//

/*
 * Copyright (C) 2018, ownCloud GmbH.
 *
 * This code is covered by the GNU Public License Version 3.
 *
 * For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 * You should have received a copy of this license along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 *
 */

#import "OCCore.h"
#import "OCCore+SyncEngine.h"
#import "OCCore+Internal.h"
#import "OCSyncActionUpload.h"
#import "OCSyncAction+FileProvider.h"
#import "OCSyncContext.h"
#import "OCChecksum.h"
#import "OCChecksumAlgorithmSHA1.h"
#import "NSDate+OCDateParser.h"
#import "OCCellularManager.h"
#import "OCMacros.h"
#import "OCLogger.h"

static OCMessageTemplateIdentifier OCMessageTemplateIdentifierUploadKeepBoth = @"upload.keep-both";
static OCMessageTemplateIdentifier OCMessageTemplateIdentifierUploadRetry = @"upload.retry";

@implementation OCSyncActionUpload

@synthesize options;

OCSYNCACTION_REGISTER_ISSUETEMPLATES

+ (OCSyncActionIdentifier)identifier
{
	return(OCSyncActionIdentifierUpload);
}

+ (NSArray<OCMessageTemplate *> *)actionIssueTemplates
{
	return (@[
		// Keep both
		[OCMessageTemplate templateWithIdentifier:OCMessageTemplateIdentifierUploadKeepBoth categoryName:nil choices:@[
			[OCSyncIssueChoice cancelChoiceWithImpact:OCSyncIssueChoiceImpactDataLoss],
			[OCSyncIssueChoice choiceOfType:OCIssueChoiceTypeDestructive impact:OCSyncIssueChoiceImpactDataLoss identifier:@"replaceExisting" label:OCLocalizedString(@"Replace",nil) metaData:nil],
			[OCSyncIssueChoice choiceOfType:OCIssueChoiceTypeDefault impact:OCSyncIssueChoiceImpactNonDestructive identifier:@"keepBoth" label:OCLocalizedString(@"Keep both",nil) metaData:nil]
		] options:nil],

		// Retry
		[OCMessageTemplate templateWithIdentifier:OCMessageTemplateIdentifierUploadRetry categoryName:nil choices:@[
			[OCSyncIssueChoice cancelChoiceWithImpact:OCSyncIssueChoiceImpactDataLoss],
			[OCSyncIssueChoice retryChoice]
		] options:nil]
	]);
}

#pragma mark - Initializer
- (instancetype)initWithUploadItem:(OCItem *)uploadItem parentItem:(OCItem *)parentItem filename:(NSString *)filename importFileURL:(NSURL *)importFileURL isTemporaryCopy:(BOOL)isTemporaryCopy options:(NSDictionary<OCCoreOption,id> *)options
{
	if ((self = [super initWithItem:uploadItem]) != nil)
	{
		self.parentItem = parentItem;

		self.importFileURL = importFileURL;
		self.importFileIsTemporaryAlongsideCopy = isTemporaryCopy;
		self.filename = filename;

		self.actionEventType = OCEventTypeUpload;
		self.localizedDescription = [NSString stringWithFormat:OCLocalizedString(@"Uploading %@…",nil), ((filename!=nil) ? filename : uploadItem.name)];

		self.options = options;
		self.syncReason = options[OCCoreOptionSyncReason];

		self.categories = @[
			OCSyncActionCategoryAll, OCSyncActionCategoryTransfer,

			OCSyncActionCategoryUpload,

			([OCCellularManager.sharedManager cellularAccessAllowedFor:options[OCCoreOptionDependsOnCellularSwitch] transferSize:uploadItem.size] ?
				OCSyncActionCategoryUploadWifiAndCellular :
				OCSyncActionCategoryUploadWifiOnly)
		];
	}

	return (self);
}

#pragma mark - Action implementation
- (void)preflightWithContext:(OCSyncContext *)syncContext
{
	OCItem *uploadItem;

	if ((uploadItem = self.localItem) != nil)
	{
		uploadItem.lastUsed = [NSDate new];
		[uploadItem addSyncRecordID:syncContext.syncRecord.recordID activity:OCItemSyncActivityUploading];

		self.actionTrackingID = OCActionTrackingIDFromSyncRecordID(syncContext.syncRecord.recordID); // achieve consistency with generated ActionTrackingID in -scheduleWithContext: options dictionary

		if (uploadItem.isPlaceholder && (uploadItem.databaseID == nil))
		{
			syncContext.addedItems = @[ uploadItem ];
		}
		else
		{
			syncContext.updatedItems = @[ uploadItem ];
		}

		syncContext.updateStoredSyncRecordAfterItemUpdates = YES; // Update syncRecord, so the updated uploadItem (now with databaseID) will be stored in the database and can later be used to remove the uploadItem again.
	}
}

- (void)descheduleWithContext:(OCSyncContext *)syncContext
{
	OCItem *uploadItem;

	if ((uploadItem = self.localItem) != nil)
	{
		[uploadItem removeSyncRecordID:syncContext.syncRecord.recordID activity:OCItemSyncActivityUploading];

		if (uploadItem.isPlaceholder)
		{
			// Import descheduled - delete entire item
			syncContext.removedItems = @[ uploadItem ];

			[self.core deleteDirectoryForItem:uploadItem];
		}
		else
		{
			// Remove temporary copy (main file should remain intact)
			if ((_importFileURL!=nil) && _importFileIsTemporaryAlongsideCopy)
			{
				NSError *error = nil;

				[[NSFileManager defaultManager] removeItemAtURL:_importFileURL error:&error];

				OCFileOpLog(@"rm", error, @"Deleted descheduled import at %@", _importFileURL.path);
			}

			// Remove local copy
			uploadItem.locallyModified = NO;
			[uploadItem clearLocalCopyProperties];

			[self.core deleteDirectoryForItem:uploadItem];

			// Update item
			syncContext.updatedItems = @[ uploadItem ];
		}
	}
}

- (OCCoreSyncInstruction)scheduleWithContext:(OCSyncContext *)syncContext
{
	OCPath remoteFileName;
	OCItem *parentItem, *uploadItem;
	NSURL *uploadURL;

	if (((remoteFileName = self.filename) != nil) &&
	    ((parentItem = self.parentItem) != nil) &&
	    ((uploadItem = self.localItem) != nil) &&
	    ((uploadURL = self.importFileURL) != nil))
	{
		if (self.importFileIsTemporaryAlongsideCopy)
		{
			// uploadURL already is a copy of the file alongside item, so we can use it right away
			_uploadCopyFileURL = uploadURL;
		}
		else
		{
			// Find unoccupied filename to make a copy of the file before upload
			if ((_uploadCopyFileURL = [self.core availableTemporaryURLAlongsideItem:self.localItem fileName:NULL]) != nil)
			{
				NSError *error = nil;

				// Make a copy of the file before upload (utilizing APFS cloning, this should be both almost instant as well as cost no actual disk space thanks to APFS copy-on-write)
				BOOL success = [[NSFileManager defaultManager] copyItemAtURL:uploadURL toURL:_uploadCopyFileURL error:&error];

				OCFileOpLog(@"cp", error, @"Cloning file to import %@ as %@", uploadURL.path, _uploadCopyFileURL.path);

				if (success)
				{
					// Cloning succeeded - upload from the clone
					uploadURL = _uploadCopyFileURL;
					_importFileURL = _uploadCopyFileURL;
					_importFileIsTemporaryAlongsideCopy = YES;
				}
				else
				{
					// Cloning failed - report error and offer to cancel upload
					OCLogError(@"error cloning file to import from %@ to %@: %@", uploadURL, _uploadCopyFileURL, error);

					_uploadCopyFileURL = nil;

					[self _addIssueForCancellationAndDeschedulingToContext:syncContext title:[NSString stringWithFormat:OCLocalizedString(@"Error uploading %@",nil), self.localItem.name] description:error.localizedDescription impact:OCSyncIssueChoiceImpactDataLoss];
					[syncContext transitionToState:OCSyncRecordStateProcessing withWaitConditions:nil]; // updates the sync record with the issue wait condition

					// Wait for result
					return (OCCoreSyncInstructionStop);
				}
			}
		}

		// Check for pre-existing item
		{
			OCItem *preExistingItem;

			if ((preExistingItem = [self _preExistingItem]) != nil)
			{
				// Create issue with other options for all other errors
				OCSyncIssue *issue;

				issue = [OCSyncIssue issueFromTemplate:OCMessageTemplateIdentifierUploadKeepBoth
							 forSyncRecord:syncContext.syncRecord
								 level:OCIssueLevelError
								 title:[NSString stringWithFormat:OCLocalizedString(@"Couldn't upload %@",nil), self.localItem.name]
							   description:[NSString stringWithFormat:OCLocalizedString(@"Another item named %@ already exists in %@.",nil), self.localItem.name, self.parentItem.name]
							      metaData:nil];

				[syncContext addSyncIssue:issue];
				[syncContext transitionToState:OCSyncRecordStateProcessing withWaitConditions:nil]; // updates the sync record with the issue wait condition

				// Wait for result
				return (OCCoreSyncInstructionStop);
			}
		}

		// Compute checksum asynchronously so hashing does not block the serial core queue
		// (which also serves ItemList / PROPFIND result application).
		if (_uploadCopyFileURL != nil)
		{
			OCSyncRecord *syncRecord = syncContext.syncRecord;
			NSURL *fileURLForUpload = uploadURL;
			OCPath capturedRemoteFileName = remoteFileName;
			OCItem *capturedUploadItem = uploadItem;
			OCItem *capturedParentItem = parentItem;
			NSURL *capturedCopyURL = _uploadCopyFileURL;
			OCChecksumAlgorithmIdentifier algorithmIdentifier = self.core.preferredChecksumAlgorithm;

			// Park the record in Processing so the scheduler does not re-enter schedule
			// while the checksum runs off-queue.
			[syncContext transitionToState:OCSyncRecordStateProcessing withWaitConditions:nil];

			__weak OCSyncActionUpload *weakSelf = self;
			__weak OCCore *weakCore = self.core;

			[OCChecksum computeForFile:capturedCopyURL checksumAlgorithm:algorithmIdentifier completionHandler:^(NSError *checksumError, OCChecksum *computedChecksum) {
				OCSyncActionUpload *strongSelf = weakSelf;
				OCCore *core = weakCore;

				if ((strongSelf == nil) || (core == nil))
				{
					return;
				}

				[core queueBlock:^{
					if ((strongSelf.core == nil) || syncRecord.removed || syncRecord.progress.cancelled)
					{
						return;
					}

					if ((core.state != OCCoreStateRunning) && (core.state != OCCoreStateReady))
					{
						OCLogDebug(@"Skipping async upload start for %@ — core state is %lu", syncRecord.recordID, (unsigned long)core.state);
						return;
					}

					if (syncRecord.state != OCSyncRecordStateProcessing)
					{
						OCLogDebug(@"Skipping async upload start for %@ — sync record state is %ld", syncRecord.recordID, (long)syncRecord.state);
						return;
					}

					if (core.connection == nil)
					{
						OCLogDebug(@"Skipping async upload start for %@ — connection gone", syncRecord.recordID);
						return;
					}

					if ((checksumError != nil) || (computedChecksum == nil))
					{
						OCLogError(@"error computing upload checksum for %@: %@", capturedCopyURL, checksumError);

						OCSyncContext *issueContext = [OCSyncContext schedulerContextWithSyncRecord:syncRecord];
						[strongSelf _addIssueForCancellationAndDeschedulingToContext:issueContext title:[NSString stringWithFormat:OCLocalizedString(@"Error uploading %@",nil), strongSelf.localItem.name] description:(checksumError.localizedDescription ?: OCLocalizedString(@"Checksum computation failed",nil)) impact:OCSyncIssueChoiceImpactDataLoss];
						[issueContext transitionToState:OCSyncRecordStateProcessing withWaitConditions:nil];
						[core performSyncContextActions:issueContext];
						return;
					}

					strongSelf.importFileChecksum = computedChecksum;

					OCCellularSwitchIdentifier cellularSwitchID;

					if ((cellularSwitchID = strongSelf.options[OCCoreOptionDependsOnCellularSwitch]) == nil)
					{
						cellularSwitchID = OCCellularSwitchIdentifierMain;
					}

					NSURL *segmentFolderURL = [[core.vault.rootURL URLByAppendingPathComponent:@"TUS"] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];

					NSDate *lastModificationDate = ((capturedUploadItem.lastModified != nil) ? capturedUploadItem.lastModified : [NSDate new]);
					NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
									segmentFolderURL,								OCConnectionOptionTemporarySegmentFolderURLKey,
									lastModificationDate,								OCConnectionOptionLastModificationDateKey,
									cellularSwitchID,								OCConnectionOptionRequiredCellularSwitchKey,
									@(((NSNumber *)strongSelf.options[OCConnectionOptionForceReplaceKey]).boolValue),	OCConnectionOptionForceReplaceKey,
									OCActionTrackingIDFromSyncRecordID(syncRecord.recordID),				OCConnectionOptionActionTrackingID,
									syncRecord.recordID,								OCConnectionOptionSyncRecordID,
									computedChecksum, 	 								OCConnectionOptionChecksumKey,
								nil];

					OCSyncContext *uploadContext = [OCSyncContext schedulerContextWithSyncRecord:syncRecord];
					[strongSelf setupProgressSupportForItem:strongSelf.latestVersionOfLocalItem options:&options syncContext:uploadContext];

					OCProgress *progress;

					if ((progress = [core.connection uploadFileFromURL:fileURLForUpload
										 withName:capturedRemoteFileName
										       to:capturedParentItem
									    replacingItem:(strongSelf.replaceItem != nil) ? strongSelf.replaceItem : (strongSelf.localItem.isPlaceholder ? nil : strongSelf.latestVersionOfLocalItem)
										  options:options
									     resultTarget:[core _eventTargetWithSyncRecord:syncRecord]]) != nil)
					{
						[syncRecord addProgress:progress];

						if (syncRecord.progress.progress != nil)
						{
							[core registerProgress:syncRecord.progress.progress forItem:strongSelf.localItem];
						}
					}

					[uploadContext transitionToState:OCSyncRecordStateProcessing withWaitConditions:nil];
					[core performSyncContextActions:uploadContext];
				}];
			}];

			// Wait for checksum + upload result
			return (OCCoreSyncInstructionStop);
		}
	}

	// Remove record as its action is not sufficiently specified
	return (OCCoreSyncInstructionDeleteLast);
}

- (OCCoreSyncInstruction)handleResultWithContext:(OCSyncContext *)syncContext
{
	OCEvent *event = syncContext.event;
	OCCoreSyncInstruction resultInstruction = OCCoreSyncInstructionNone;

	if ((event.error == nil) && (event.result != nil))
	{
		OCItem *uploadItem;
		OCItem *uploadedItem = (OCItem *)event.result;

		if ((uploadItem = self.latestVersionOfLocalItem) != nil)
		{
			// Propagate previousPlaceholderFileID
			if (![uploadedItem.fileID isEqual:uploadItem.fileID])
			{
				uploadedItem.previousPlaceholderFileID = uploadItem.fileID;
			}

			// Prepare uploadedItem to replace uploadItem
			[uploadedItem prepareToReplace:uploadItem];
			uploadedItem.lastUsed = uploadItem.lastUsed;

			// Update uploaded item with local relative path
			uploadedItem.localRelativePath = [self.core.vault relativePathForItem:uploadedItem];

			// Compute checksum asynchronously so result handling does not block the core queue.
			OCChecksum *expectedChecksum = self.importFileChecksum;
			NSURL *localFileURL = [self.core localURLForItem:uploadedItem];
			OCSyncRecord *syncRecord = syncContext.syncRecord;
			BOOL importFileIsTemporaryAlongsideCopy = _importFileIsTemporaryAlongsideCopy;
			NSURL *importFileURL = _importFileURL;

			if ((expectedChecksum != nil) && (localFileURL != nil))
			{
				__weak OCSyncActionUpload *weakSelf = self;
				__weak OCCore *weakCore = self.core;

				[OCChecksum computeForFile:localFileURL checksumAlgorithm:expectedChecksum.algorithmIdentifier completionHandler:^(NSError *checksumError, OCChecksum *computedChecksum) {
					OCSyncActionUpload *strongSelf = weakSelf;
					OCCore *core = weakCore;

					if ((strongSelf == nil) || (core == nil) || syncRecord.removed)
					{
						return;
					}

					[core queueBlock:^{
						if (syncRecord.removed)
						{
							return;
						}

						if ((core.state != OCCoreStateRunning) && (core.state != OCCoreStateReady))
						{
							OCLogDebug(@"Skipping async upload result finalize for %@ — core state is %lu", syncRecord.recordID, (unsigned long)core.state);
							return;
						}

						OCItem *finalUploadedItem = uploadedItem;

						if ((checksumError == nil) && (computedChecksum != nil))
						{
							finalUploadedItem.locallyModified = ![expectedChecksum isEqual:computedChecksum];
						}
						else
						{
							OCLogWarning(@"Upload result checksum failed (%@) — treating as locallyModified", checksumError);
							finalUploadedItem.locallyModified = YES;
						}

						if (!finalUploadedItem.locallyModified)
						{
							finalUploadedItem.localCopyVersionIdentifier = finalUploadedItem.itemVersionIdentifier;
						}

						NSArray<OCItemPolicy *> *availableOfflineItemPoliciesCoveringItem;

						if (((availableOfflineItemPoliciesCoveringItem = [core retrieveAvailableOfflinePoliciesCoveringItem:finalUploadedItem completionHandler:nil]) != nil) && (availableOfflineItemPoliciesCoveringItem.count > 0))
						{
							finalUploadedItem.downloadTriggerIdentifier = OCItemDownloadTriggerIDAvailableOffline;
						}

						[finalUploadedItem removeSyncRecordID:syncRecord.recordID activity:OCItemSyncActivityUploading];

						strongSelf.localItem = finalUploadedItem;

						if (importFileIsTemporaryAlongsideCopy && (importFileURL != nil))
						{
							NSError *removeError = nil;
							[[NSFileManager defaultManager] removeItemAtURL:importFileURL error:&removeError];
							OCFileOpLog(@"rm", removeError, @"Deleted temporary copy at %@", importFileURL.path);
						}

						OCSyncContext *completionContext = [OCSyncContext eventHandlingContextWith:syncRecord event:event];
						completionContext.updatedItems = @[ finalUploadedItem ];
						[completionContext transitionToState:OCSyncRecordStateCompleted withWaitConditions:nil];
						[completionContext completeWithError:nil core:core item:finalUploadedItem parameter:finalUploadedItem];
						[core performSyncContextActions:completionContext];

						[core removeSyncRecords:@[ syncRecord ] completionHandler:^(OCDatabase *db, NSError *removeError) {
							if (removeError != nil)
							{
								OCLogError(@"Error removing completed upload sync record %@: %@", syncRecord.recordID, removeError);
							}
							[core setNeedsToProcessSyncRecords];
						}];
					}];
				}];

				// Stay in Processing until async checksum finishes; event is consumed by the engine.
				return (OCCoreSyncInstructionStop);
			}

			// No checksum to verify — complete synchronously
			uploadedItem.locallyModified = YES;

			NSArray<OCItemPolicy *> *availableOfflineItemPoliciesCoveringItem;

			if (((availableOfflineItemPoliciesCoveringItem =  [self.core retrieveAvailableOfflinePoliciesCoveringItem:uploadedItem completionHandler:nil]) != nil) && (availableOfflineItemPoliciesCoveringItem.count > 0))
			{
				uploadedItem.downloadTriggerIdentifier = OCItemDownloadTriggerIDAvailableOffline;
			}

			[uploadedItem removeSyncRecordID:syncContext.syncRecord.recordID activity:OCItemSyncActivityUploading];

			syncContext.updatedItems = @[ uploadedItem ];

			self.localItem = uploadedItem;

			if (_importFileIsTemporaryAlongsideCopy)
			{
				NSError *error = nil;

				[[NSFileManager defaultManager] removeItemAtURL:_importFileURL error:&error];

				OCFileOpLog(@"rm", error, @"Deleted temporary copy at %@", _importFileURL.path);
			}
		}
		else
		{
			OCLogWarning(@"Upload completion failed retrieving localItem/placeholder");
		}

		// Action complete and can be removed
		[syncContext transitionToState:OCSyncRecordStateCompleted withWaitConditions:nil];
		resultInstruction = OCCoreSyncInstructionDeleteLast;

		// Call resultHandler (and give file provider a chance to attach an uploadingError)
		[syncContext completeWithError:event.error core:self.core item:(OCItem *)event.result parameter:self.localItem];
	}
	else
	{
		// Call resultHandler (and give file provider a chance to attach an uploadingError)
		[syncContext completeWithError:event.error core:self.core item:(OCItem *)event.result parameter:self.localItem];
	}

	if (event.error != nil)
	{
		if ([event.error isOCErrorWithCode:OCErrorCancelled] || [event.error isOCErrorWithCode:OCErrorRequestCancelled])
		{
			OCLogDebug(@"Upload has been cancelled - descheduling");
			[self.core _descheduleSyncRecord:syncContext.syncRecord completeWithError:syncContext.error parameter:nil];

			syncContext.error = nil;

			resultInstruction = OCCoreSyncInstructionProcessNext;
		}
		else
		{
			// Create issue with other options for all other errors
			OCSyncIssue *issue;
			BOOL alreadyExists = [event.error isOCErrorWithCode:OCErrorItemAlreadyExists];

			issue = [OCSyncIssue issueFromTemplate:(alreadyExists ? OCMessageTemplateIdentifierUploadKeepBoth : OCMessageTemplateIdentifierUploadRetry)
						 forSyncRecord:syncContext.syncRecord
							 level:OCIssueLevelError
							 title:[NSString stringWithFormat:OCLocalizedString(@"Couldn't upload %@",nil), self.localItem.name]
						   description:event.error.localizedDescription
						      metaData:nil];

			[issue setAutoChoiceError:event.error forChoiceWithIdentifier:OCSyncIssueChoiceIdentifierRetry];

			[syncContext addSyncIssue:issue];
			[syncContext transitionToState:OCSyncRecordStateProcessing withWaitConditions:nil]; // updates the sync record with the issue wait condition
		}
	}

	return (resultInstruction);
}

#pragma mark - Issue resolution
- (OCItem *)_preExistingItem
{
	__block OCItem *itemToReplace = nil;
	OCLocalID localItemLocalID;

	if ((localItemLocalID = self.localItem.localID) != nil)
	{
		[self.core.vault.database retrieveCacheItemsAtLocation:self.localItem.location itemOnly:NO completionHandler:^(OCDatabase *db, NSError *error, OCSyncAnchor syncAnchor, NSArray<OCItem *> *items) {
			for (OCItem *item in items)
			{
				if (![item.localID isEqual:localItemLocalID])
				{
					itemToReplace = item;
					break;
				}
			}
		}];
	}

	return (itemToReplace);
}

- (NSError *)resolveIssue:(OCSyncIssue *)issue withChoice:(OCSyncIssueChoice *)choice context:(OCSyncContext *)syncContext
{
	NSError *resolutionError = nil;

	if ((resolutionError = [super resolveIssue:issue withChoice:choice context:syncContext]) != nil)
	{
		if (![resolutionError isOCErrorWithCode:OCErrorFeatureNotImplemented])
		{
			return (resolutionError);
		}

		if ([choice.identifier isEqual:@"keepBoth"])
		{
			// Keep both
			if (self.filename != nil)
			{
				NSString *filename = [self.filename stringByDeletingPathExtension];
				NSString *extension = [self.filename pathExtension];
				NSString *dateString = [[NSDate new] compactLocalTimeZoneString];
				NSURL *previousLocalURL = [self.core localURLForItem:self.localItem];

				if (filename.length > 0)
				{
					filename = [filename stringByAppendingFormat:@" (%@)", dateString];
				}
				else
				{
					filename = @"";
					extension = [extension stringByAppendingFormat:@" (%@)", dateString];
				}

				// Create filename with timestamp
				self.filename = [NSString stringWithFormat:@"%@.%@", filename, extension];

				// Adapt paths
 				self.localItem.path = [self.localItem.path.parentPath stringByAppendingPathComponent:self.filename];
 				self.localItem.localRelativePath = [self.core.vault relativePathForItem:self.localItem];

				// Decouple from existing file ID and eTag to prevent collissions and duplicates
 				self.localItem.eTag = OCFileETagPlaceholder;
 				self.localItem.fileID = [OCItem generatePlaceholderFileID];

				// No longer replacing another item
 				self.replaceItem = nil;

 				// Move underlying file
 				NSURL *newLocalURL = [self.core localURLForItem:self.localItem];
 				NSError *error = nil;

 				if (![[NSFileManager defaultManager] moveItemAtURL:previousLocalURL toURL:newLocalURL error:&error])
 				{
 					OCLogError(@"Renaming local copy of file from %@ to %@ during `keepBoth` issue resolution returned an error=%@", previousLocalURL, newLocalURL, error);
				}

				OCFileOpLog(@"mv", error, @"Renamed local copy of file from %@ to %@ during `keepBoth` issue resolution", previousLocalURL.path, newLocalURL.path);

				// Update item
				syncContext.updatedItems = @[ self.localItem ];

				// Initiate scan to get the item that took this item's place
				OCLocation *parentLocation;
				if ((parentLocation = self.localItem.location.parentLocation) != nil)
				{
					syncContext.refreshLocations = @[ parentLocation ];
				}
				syncContext.updateStoredSyncRecordAfterItemUpdates = YES;
			}

			// Reschedule
			[syncContext transitionToState:OCSyncRecordStateReady withWaitConditions:nil];

			resolutionError = nil;
		}

		if ([choice.identifier isEqual:@"replaceExisting"])
		{
			// Replace existing (force replace)
			NSMutableDictionary<OCCoreOption,id> *options = (self.options != nil) ? [self.options mutableCopy] : [NSMutableDictionary new];
			options[OCConnectionOptionForceReplaceKey] = @(YES);
			self.options = options;

			OCItem *preExistingItem = [self _preExistingItem];
			if (preExistingItem != nil)
			{
				// Remove (possible) duplicate item from database
				syncContext.removedItems = @[ preExistingItem ];
			}

			syncContext.updateStoredSyncRecordAfterItemUpdates = YES;

			[syncContext transitionToState:OCSyncRecordStateReady withWaitConditions:nil];

			resolutionError = nil;
		}
	}

	return (resolutionError);
}

#pragma mark - Restore progress
- (OCItem *)itemToRestoreProgressRegistrationFor
{
	return (self.localItem);
}

#pragma mark - Lane tags
- (NSSet<OCSyncLaneTag> *)generateLaneTags
{
	return ([self generateLaneTagsFromItems:@[
		OCSyncActionWrapNullableItem(self.localItem),
		OCSyncActionWrapNullableItem(self.replaceItem)
	]]);
}

#pragma mark - NSCoding
- (void)decodeActionData:(NSCoder *)decoder
{
	_filename = [decoder decodeObjectOfClass:[NSString class] forKey:@"filename"];

	_importFileURL = [decoder decodeObjectOfClass:[NSURL class] forKey:@"importFileURL"];
	_importFileChecksum = [decoder decodeObjectOfClass:[OCChecksum class] forKey:@"importFileChecksum"];
	_importFileIsTemporaryAlongsideCopy = [decoder decodeBoolForKey:@"importFileIsTemporaryAlongsideCopy"];

	_parentItem = [decoder decodeObjectOfClass:[OCItem class] forKey:@"parentItem"];
	_replaceItem = [decoder decodeObjectOfClass:[OCItem class] forKey:@"replaceItem"];

	_uploadCopyFileURL = [decoder decodeObjectOfClass:[NSURL class] forKey:@"uploadCopyFileURL"];

	self.options = [decoder decodeObjectOfClasses:OCEvent.safeClasses forKey:@"options"];
}

- (void)encodeActionData:(NSCoder *)coder
{
	[coder encodeObject:_filename forKey:@"filename"];

	[coder encodeObject:_importFileURL forKey:@"importFileURL"];
	[coder encodeObject:_importFileChecksum forKey:@"importFileChecksum"];
	[coder encodeBool:_importFileIsTemporaryAlongsideCopy forKey:@"importFileIsTemporaryAlongsideCopy"];

	[coder encodeObject:_parentItem forKey:@"parentItem"];
	[coder encodeObject:_replaceItem forKey:@"replaceItem"];

	[coder encodeObject:_uploadCopyFileURL forKey:@"uploadCopyFileURL"];

	[coder encodeObject:self.options forKey:@"options"];
}

@end

OCSyncActionCategory OCSyncActionCategoryUpload = @"upload";
OCSyncActionCategory OCSyncActionCategoryUploadWifiOnly = @"upload-wifi-only";
OCSyncActionCategory OCSyncActionCategoryUploadWifiAndCellular = @"upload-cellular-and-wifi";
