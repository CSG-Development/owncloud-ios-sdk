//
//  OCConnection+Trash.m
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

#import "OCConnection+Trash.h"
#import "OCConnection+GraphAPI.h"
#import "OCConnection+OData.h"
#import "OCHTTPRequest.h"
#import "NSProgress+OCEvent.h"
#import "OCLogger.h"
#import "OCDrive.h"
#import "OCEvent.h"
#import "OCEventTarget.h"
#import <CoreServices/CoreServices.h>
#import "OCHTTPDAVRequest.h"
#import "OCHTTPDAVMultistatusResponse.h"
#import "OCXMLParser.h"
#import "OCXMLNode.h"
#import "OCHTTPStatus.h"
#import "OCHTTPResponse+DAVError.h"
#import "NSError+OCError.h"
#import "OCMacros.h"

OCLocalAttribute OCLocalAttributeTrashItem = @"_trash-item";

NSNotificationName const OCTrashDebugLogNotification = @"OCTrashDebugLogNotification";
NSString * const OCTrashDebugLogMessageKey = @"message";

void OCTrashDebugLog(NSString *message)
{
	if (message.length == 0) { return; }

	[[NSNotificationCenter defaultCenter] postNotificationName:OCTrashDebugLogNotification object:nil userInfo:@{ OCTrashDebugLogMessageKey : message }];
}
OCLocalAttribute OCLocalAttributeTrashOriginalLocation = @"_trash-original-location";
OCLocalAttribute OCLocalAttributeTrashOriginalFilename = @"_trash-original-filename";
OCLocalAttribute OCLocalAttributeTrashDeletionTimestamp = @"_trash-deletion-timestamp";
OCLocalAttribute OCLocalAttributeTrashPendingSyncRecordID = @"_trash-pending-sync-record-id";

static NSString * const OCTrashPreviewRestoreFolderName = @".owncloud-ios-trash-preview";

@implementation OCConnection (Trash)

#pragma mark - URL helpers

- (BOOL)isTrashedItem:(OCItem *)item
{
	if (item == nil) { return NO; }

	if ([item valueForLocalAttribute:OCLocalAttributeTrashItem] != nil) {
		return YES;
	}

	id trashOriginalFilename = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalFilename];
	return ([trashOriginalFilename isKindOfClass:NSString.class] && ((NSString *)trashOriginalFilename).length > 0);
}

- (NSURL *)previewURLForTrashedItem:(OCItem *)item
{
	return ([self _trashItemURLForItem:item]);
}

- (NSString *)_effectiveMIMETypeForTrashedItem:(OCItem *)item
{
	if (![self _isUninformativeMIMEType:item.mimeType]) {
		return (item.mimeType);
	}

	NSString *filename = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalFilename];
	if (filename.length == 0) {
		filename = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalLocation];
	}
	if (filename.length > 0) {
		return ([self _mimeTypeForFilename:filename.lastPathComponent]);
	}

	return (item.mimeType);
}

- (BOOL)trashedItemSupportsRawImageDownload:(OCItem *)item
{
	NSString *mimeType = [self _effectiveMIMETypeForTrashedItem:item];

	return ([mimeType hasPrefix:@"image/"]);
}

- (BOOL)_isUninformativeMIMEType:(NSString *)mimeType
{
	if (mimeType.length == 0) { return YES; }

	static NSSet<NSString *> *uninformativeMIMETypes;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		uninformativeMIMETypes = [NSSet setWithObjects:
			@"application/octet-stream",
			@"binary/octet-stream",
		nil];
	});

	return ([uninformativeMIMETypes containsObject:mimeType]);
}

- (OCDriveID)_personalDriveID
{
	for (OCDrive *drive in self.drives) {
		if ([drive.specialType isEqual:OCDriveSpecialTypePersonal]) {
			return (drive.identifier);
		}
	}

	return (nil);
}

- (NSString *)_normalizedTrashItemPathComponent:(OCItem *)item
{
	NSString *pathComponent = item.fileID.length > 0 ? item.fileID : item.path;
	if (pathComponent.length == 0) { return nil; }

	while ([pathComponent hasPrefix:@"/"]) {
		pathComponent = [pathComponent substringFromIndex:1];
	}

	if ([pathComponent hasSuffix:@"/"]) {
		pathComponent = [pathComponent substringToIndex:pathComponent.length - 1];
	}

	return (pathComponent.length > 0 ? pathComponent : nil);
}

- (NSDate *)_dateFromTrashDeletionValue:(id)value
{
	if ([value isKindOfClass:NSDate.class]) {
		return ((NSDate *)value);
	}

	if ([value isKindOfClass:NSNumber.class]) {
		return ([NSDate dateWithTimeIntervalSince1970:((NSNumber *)value).doubleValue]);
	}

	if ([value isKindOfClass:NSString.class]) {
		NSString *stringValue = (NSString *)value;

		if (stringValue.length == 0) { return nil; }

		long long timestamp = stringValue.longLongValue;
		if (timestamp > 1000000000) {
			return ([NSDate dateWithTimeIntervalSince1970:timestamp]);
		}

		static NSDateFormatter *httpDateFormatter;
		static dispatch_once_t onceToken;

		dispatch_once(&onceToken, ^{
			httpDateFormatter = [NSDateFormatter new];
			httpDateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
			httpDateFormatter.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
			httpDateFormatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
		});

		NSDate *date = [httpDateFormatter dateFromString:stringValue];
		if (date != nil) { return (date); }

		NSISO8601DateFormatter *iso8601Formatter = [NSISO8601DateFormatter new];
		iso8601Formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
		date = [iso8601Formatter dateFromString:stringValue];
		if (date != nil) { return (date); }

		iso8601Formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
		return ([iso8601Formatter dateFromString:stringValue]);
	}

	return (nil);
}

- (NSNumber *)_deletionTimestampSecondsForTrashedItem:(OCItem *)item
{
	NSString *name = item.name;

	if (name.length > 0) {
		NSRange dotDRange = [name rangeOfString:@".d" options:NSBackwardsSearch];

		if (dotDRange.location != NSNotFound) {
			NSString *suffix = [name substringFromIndex:dotDRange.location + 2];
			long long timestamp = suffix.longLongValue;

			if (timestamp > 0) {
				return (@(timestamp));
			}
		}
	}

	NSDate *deletionDate = [self _dateFromTrashDeletionValue:[item valueForLocalAttribute:OCLocalAttributeTrashDeletionTimestamp]];

	if (deletionDate != nil) {
		return (@((long long)[deletionDate timeIntervalSince1970]));
	}

	return (nil);
}

- (NSString *)classicTrashPreviewFileParameterForItem:(OCItem *)item
{
	NSString *name = item.name;

	if (name.length > 0) {
		NSRange dotDRange = [name rangeOfString:@".d" options:NSBackwardsSearch];

		if (dotDRange.location != NSNotFound) {
			NSString *suffix = [name substringFromIndex:dotDRange.location + 2];
			long long timestamp = suffix.longLongValue;

			if (timestamp > 0) {
				while ([name hasPrefix:@"/"]) {
					name = [name substringFromIndex:1];
				}

				return ([NSString stringWithFormat:@"/%@", name]);
			}
		}
	}

	NSString *basePath = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalLocation];

	if (basePath.length == 0) {
		basePath = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalFilename];
	}

	if (basePath.length == 0) { return nil; }

	while ([basePath hasPrefix:@"/"]) {
		basePath = [basePath substringFromIndex:1];
	}

	NSNumber *deletionTimestamp = [self _deletionTimestampSecondsForTrashedItem:item];

	if (deletionTimestamp == nil) { return nil; }

	return ([NSString stringWithFormat:@"/%@.d%lld", basePath, deletionTimestamp.longLongValue]);
}

- (NSString *)classicTrashPreviewCacheParameterForItem:(OCItem *)item
{
	NSNumber *deletionTimestamp = [self _deletionTimestampSecondsForTrashedItem:item];

	if (deletionTimestamp != nil) {
		return (@(deletionTimestamp.longLongValue * 1000).stringValue);
	}

	return (item.eTag);
}

- (NSURL *)previewURLForTrashedItemThumbnail:(OCItem *)item
{
	if (item == nil) { return nil; }

	NSString *classicFileParameter = [self classicTrashPreviewFileParameterForItem:item];

	if (classicFileParameter.length > 0) {
		NSURL *classicPreviewURL = [self URLForEndpoint:OCConnectionEndpointIDTrashPreview options:nil];

		if (classicPreviewURL != nil) {
			OCTrashDebugLog([NSString stringWithFormat:@"previewURL: classic trash preview endpoint=%@ file=%@ c=%@",
				classicPreviewURL.absoluteString, classicFileParameter, [self classicTrashPreviewCacheParameterForItem:item]]);
			return (classicPreviewURL);
		}
	}

	// oCIS-style fallback: trash-bin WebDAV with ?preview=1
	NSURL *trashBinURL = [self previewURLForTrashedItem:item];
	if (trashBinURL != nil) {
		OCLogDebug(@"[Trash] previewURLForTrashedItemThumbnail: using trash-bin url=%@", trashBinURL.absoluteString);
		return (trashBinURL);
	}

	NSString *originalLocation = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalLocation];
	NSString *previewPath = originalLocation.length > 0 ? originalLocation : [self _normalizedTrashItemPathComponent:item];
	OCDriveID driveID = item.driveID;

	if (driveID.length == 0) {
		driveID = [self _personalDriveID];
	}

	if (self.useDriveAPI && driveID.length > 0 && previewPath.length > 0) {
		NSURL *spacesRoot = [self URLForEndpoint:OCConnectionEndpointIDWebDAVSpaces options:nil];

		if (spacesRoot != nil) {
			NSString *normalizedPath = previewPath;

			while ([normalizedPath hasPrefix:@"/"]) {
				normalizedPath = [normalizedPath substringFromIndex:1];
			}

			NSURL *url = [[spacesRoot URLByAppendingPathComponent:driveID] URLByAppendingPathComponent:normalizedPath];
			OCLogDebug(@"[Trash] previewURLForTrashedItemThumbnail: using spaces fallback driveID=%@ path=%@ url=%@", driveID, normalizedPath, url.absoluteString);
			return (url);
		}
	}

	return (nil);
}

- (NSString *)_mimeTypeForFilename:(NSString *)filename
{
	NSString *extension = filename.pathExtension;
	if (extension.length == 0) { return nil; }

	CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)extension, NULL);
	if (uti == NULL) { return nil; }

	NSString *mimeType = nil;
	CFStringRef mimeTypeRef = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType);
	if (mimeTypeRef != NULL)
	{
		mimeType = (__bridge_transfer NSString *)mimeTypeRef;
	}
	CFRelease(uti);

	return mimeType;
}

- (NSURL *)_trashBinRootURL
{
	return ([self URLForEndpoint:OCConnectionEndpointIDWebDAVTrashBinRoot options:nil]);
}

- (NSURL *)_trashItemURLForItem:(OCItem *)item
{
	NSURL *trashRootURL = [self _trashBinRootURL];
	if (trashRootURL == nil || item.path.length == 0) { return nil; }

	NSString *trashPath = item.path;
	if ([trashPath hasPrefix:@"/"]) {
		trashPath = [trashPath substringFromIndex:1];
	}

	return ([trashRootURL URLByAppendingPathComponent:trashPath]);
}

#pragma mark - Trash content download

- (NSString *)_normalizedFilesRelativePath:(NSString *)path
{
	NSString *normalized = path ?: @"";

	while ([normalized hasPrefix:@"/"]) {
		normalized = [normalized substringFromIndex:1];
	}

	return (normalized);
}

- (NSURL *)_filesURLForRelativePath:(NSString *)relativePath driveID:(nullable OCDriveID)driveID
{
	NSURL *filesRootURL = [self URLForEndpoint:OCConnectionEndpointIDWebDAVRoot options:@{
		OCConnectionEndpointURLOptionDriveID : OCNullProtect(driveID)
	}];

	if (filesRootURL == nil) { return (nil); }

	return ([filesRootURL URLByAppendingPathComponent:[self _normalizedFilesRelativePath:relativePath]]);
}

- (BOOL)requiresTemporaryRestoreForTrashContentDownload:(OCItem *)item
{
	if (![self isTrashedItem:item]) { return (NO); }

	// oCIS / spaces trash supports direct GET on the trash-bin endpoint
	if (self.useDriveAPI && item.driveID.length > 0) { return (NO); }

	// Classic ownCloud trash-bin only supports PROPFIND / MOVE / DELETE — not GET
	return (YES);
}

- (void)_ensureWebDAVCollectionExistsAtRelativePath:(NSString *)relativePath
						driveID:(nullable OCDriveID)driveID
			      completionHandler:(OCConnectionTrashModificationCompletionHandler)completionHandler
{
	NSArray<NSString *> *components = [[self _normalizedFilesRelativePath:relativePath] pathComponents];

	if (components.count == 0) {
		if (completionHandler != nil) {
			completionHandler(nil);
		}
		return;
	}

	__block void (^mkcolNext)(NSUInteger);

	mkcolNext = ^(NSUInteger index) {
		if (index >= components.count) {
			if (completionHandler != nil) {
				completionHandler(nil);
			}
			return;
		}

		NSString *subPath = [[components subarrayWithRange:NSMakeRange(0, index + 1)] componentsJoinedByString:@"/"];
		NSURL *collectionURL = [self _filesURLForRelativePath:subPath driveID:driveID];

		if (collectionURL == nil) {
			if (completionHandler != nil) {
				completionHandler(OCError(OCErrorInternal));
			}
			return;
		}

		OCHTTPRequest *request = [OCHTTPRequest requestWithURL:collectionURL];
		request.method = OCHTTPMethodMKCOL;
		request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

		[self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
			if (error != nil) {
				if (completionHandler != nil) {
					completionHandler(error);
				}
				return;
			}

			// 405 Method Not Allowed means the collection already exists
			if (response.status.isSuccess || response.status.code == OCHTTPStatusCodeMETHOD_NOT_ALLOWED) {
				mkcolNext(index + 1);
			} else if (completionHandler != nil) {
				completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
			}
		}];
	};

	mkcolNext(0);
}

- (void)_restoreTrashedItem:(OCItem *)item
      toRelativeFilesPath:(NSString *)relativeFilesPath
		completionHandler:(OCConnectionTrashModificationCompletionHandler)completionHandler
{
	NSURL *trashItemURL = [self _trashItemURLForItem:item];
	NSURL *destinationURL = [self _filesURLForRelativePath:relativeFilesPath driveID:item.driveID];

	if (trashItemURL == nil || destinationURL == nil) {
		if (completionHandler != nil) {
			completionHandler(OCError(OCErrorInsufficientParameters));
		}
		return;
	}

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:trashItemURL];
	request.method = OCHTTPMethodMOVE;
	request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];
	[request setValue:destinationURL.absoluteString forHeaderField:OCHTTPHeaderFieldNameDestination];
	[request setValue:@"T" forHeaderField:OCHTTPHeaderFieldNameOverwrite];

	OCLogDebug(@"[Trash] temp restore MOVE %@ -> %@", trashItemURL.absoluteString, destinationURL.absoluteString);

	[self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			if (completionHandler != nil) {
				completionHandler(error);
			}
			return;
		}

		if (response.status.isSuccess || response.status.code == OCHTTPStatusCodeNO_CONTENT) {
			if (completionHandler != nil) {
				completionHandler(nil);
			}
		} else if (completionHandler != nil) {
			completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
		}
	}];
}

- (void)_deleteFileAtRelativeFilesPath:(NSString *)relativeFilesPath
				 driveID:(nullable OCDriveID)driveID
	       completionHandler:(OCConnectionTrashModificationCompletionHandler)completionHandler
{
	NSURL *fileURL = [self _filesURLForRelativePath:relativeFilesPath driveID:driveID];

	if (fileURL == nil) {
		if (completionHandler != nil) {
			completionHandler(OCError(OCErrorInsufficientParameters));
		}
		return;
	}

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:fileURL];
	request.method = OCHTTPMethodDELETE;
	request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

	OCLogDebug(@"[Trash] temp restore cleanup DELETE %@", fileURL.absoluteString);

	[self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			if (completionHandler != nil) {
				completionHandler(error);
			}
			return;
		}

		if (response.status.isSuccess || response.status.code == OCHTTPStatusCodeNO_CONTENT || response.status.code == OCHTTPStatusCodeNOT_FOUND) {
			if (completionHandler != nil) {
				completionHandler(nil);
			}
		} else if (completionHandler != nil) {
			completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
		}
	}];
}

- (nullable NSProgress *)downloadTrashedItemContent:(OCItem *)item
				   toLocalDirectory:(NSURL *)localDirectoryURL
				completionHandler:(OCConnectionTrashDownloadCompletionHandler)completionHandler
{
	if (item == nil || localDirectoryURL == nil) {
		if (completionHandler != nil) {
			completionHandler(OCError(OCErrorInvalidParameter), nil);
		}
		return (nil);
	}

	if ([self requiresTemporaryRestoreForTrashContentDownload:item]) {
		NSString *originalFilename = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalFilename];

		if (originalFilename.length == 0) {
			originalFilename = item.name;
		}
		originalFilename = originalFilename.lastPathComponent;

		if (originalFilename.length == 0) {
			originalFilename = @"trash_preview";
		}

		NSString *fileID = item.fileID.length > 0 ? item.fileID : item.path.lastPathComponent;

		fileID = [self _normalizedFilesRelativePath:fileID];

		if (fileID.length == 0) {
			fileID = [[NSUUID UUID] UUIDString];
		}

		NSString *previewFolderPath = [OCTrashPreviewRestoreFolderName stringByAppendingPathComponent:fileID];
		NSString *previewFileRelativePath = [previewFolderPath stringByAppendingPathComponent:originalFilename];

		OCLogDebug(@"[Trash] downloadTrashedItemContent: temp restore path=%@", previewFileRelativePath);

		__weak OCConnection *weakSelf = self;

		[self _ensureWebDAVCollectionExistsAtRelativePath:previewFolderPath driveID:item.driveID completionHandler:^(NSError *error) {
			OCConnection *strongSelf = weakSelf;

			if (strongSelf == nil) {
				if (completionHandler != nil) {
					completionHandler(OCError(OCErrorInternal), nil);
				}
				return;
			}

			if (error != nil) {
				OCLogError(@"[Trash] downloadTrashedItemContent: MKCOL failed: %@", error);
				if (completionHandler != nil) {
					completionHandler(error, nil);
				}
				return;
			}

			[strongSelf _restoreTrashedItem:item toRelativeFilesPath:previewFileRelativePath completionHandler:^(NSError *restoreError) {
				OCConnection *strongSelf = weakSelf;

				if (strongSelf == nil) {
					if (completionHandler != nil) {
						completionHandler(OCError(OCErrorInternal), nil);
					}
					return;
				}

				if (restoreError != nil) {
					OCLogError(@"[Trash] downloadTrashedItemContent: restore failed: %@", restoreError);
					if (completionHandler != nil) {
						completionHandler(restoreError, nil);
					}
					return;
				}

				NSURL *downloadURL = [strongSelf _filesURLForRelativePath:previewFileRelativePath driveID:item.driveID];

				if (downloadURL == nil) {
					[strongSelf _deleteFileAtRelativeFilesPath:previewFileRelativePath driveID:item.driveID completionHandler:nil];
					if (completionHandler != nil) {
						completionHandler(OCError(OCErrorInternal), nil);
					}
					return;
				}

				OCHTTPRequest *getRequest = [OCHTTPRequest requestWithURL:downloadURL];
				getRequest.method = OCHTTPMethodGET;
				getRequest.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

				NSProgress *progress = [strongSelf sendRequest:getRequest ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *transportError) {
					OCConnection *strongSelf = weakSelf;
					NSError *downloadError = transportError;
					NSURL *localFileURL = nil;

					if (downloadError == nil && !response.status.isSuccess) {
						downloadError = response.status.error ?: OCError(OCErrorInternal);
					}

					if (downloadError == nil) {
						NSData *bodyData = response.bodyData;

						if (bodyData.length == 0 && response.bodyURL != nil) {
							bodyData = [NSData dataWithContentsOfURL:response.bodyURL];
						}

						if (bodyData.length == 0) {
							downloadError = OCError(OCErrorFeatureNotSupportedForItem);
						} else {
							localFileURL = [localDirectoryURL URLByAppendingPathComponent:originalFilename];
							NSError *writeError = nil;

							if (![bodyData writeToURL:localFileURL options:NSDataWritingAtomic error:&writeError]) {
								downloadError = writeError ?: OCError(OCErrorInternal);
								localFileURL = nil;
							} else {
								OCLogDebug(@"[Trash] downloadTrashedItemContent: downloaded %lu bytes to %@", (unsigned long)bodyData.length, localFileURL.path);
							}
						}
					}

					if (strongSelf == nil) {
						if (completionHandler != nil) {
							completionHandler(OCError(OCErrorInternal), nil);
						}
						return;
					}

					// Delete the temporarily restored copy; on classic ownCloud this moves it back to trash
					[strongSelf _deleteFileAtRelativeFilesPath:previewFileRelativePath driveID:item.driveID completionHandler:^(NSError *cleanupError) {
						if (cleanupError != nil) {
							OCLogError(@"[Trash] downloadTrashedItemContent: cleanup failed: %@", cleanupError);
						}

						if (completionHandler != nil) {
							completionHandler(downloadError, localFileURL);
						}
					}];
				}];

				if (progress == nil && completionHandler != nil) {
					[strongSelf _deleteFileAtRelativeFilesPath:previewFileRelativePath driveID:item.driveID completionHandler:nil];
					completionHandler(OCError(OCErrorInternal), nil);
				}
			}];
		}];

		return (nil);
	}

	OCHTTPRequest *request = [self trashItemContentDownloadRequestForItem:item];

	if (request == nil) {
		if (completionHandler != nil) {
			completionHandler(OCError(OCErrorInternal), nil);
		}
		return (nil);
	}

	NSString *originalFilename = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalFilename];

	if (originalFilename.length == 0) {
		originalFilename = item.name ?: @"trash_preview";
	}
	originalFilename = originalFilename.lastPathComponent;

	return ([self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			if (completionHandler != nil) {
				completionHandler(error, nil);
			}
			return;
		}

		if (!response.status.isSuccess) {
			if (completionHandler != nil) {
				completionHandler(response.status.error ?: OCError(OCErrorInternal), nil);
			}
			return;
		}

		NSData *bodyData = response.bodyData;

		if (bodyData.length == 0 && response.bodyURL != nil) {
			bodyData = [NSData dataWithContentsOfURL:response.bodyURL];
		}

		if (bodyData.length == 0) {
			if (completionHandler != nil) {
				completionHandler(OCError(OCErrorFeatureNotSupportedForItem), nil);
			}
			return;
		}

		NSURL *localFileURL = [localDirectoryURL URLByAppendingPathComponent:originalFilename];
		NSError *writeError = nil;

		if (![bodyData writeToURL:localFileURL options:NSDataWritingAtomic error:&writeError]) {
			if (completionHandler != nil) {
				completionHandler(writeError ?: OCError(OCErrorInternal), nil);
			}
			return;
		}

		if (completionHandler != nil) {
			completionHandler(nil, localFileURL);
		}
	}]);
}

- (nullable OCHTTPRequest *)trashItemContentDownloadRequestForItem:(OCItem *)item
{
	if (item == nil) { return (nil); }

	NSURL *trashURL = [self previewURLForTrashedItem:item];

	if (trashURL == nil) { return (nil); }

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:trashURL];
	request.method = OCHTTPMethodGET;
	request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

	OCLogDebug(@"[Trash] trashItemContentDownloadRequest: webdav url=%@", trashURL.absoluteString);

	return (request);
}

- (NSArray<OCXMLNode *> *)_trashPropfindProperties
{
	NSMutableArray<OCXMLNode *> *properties = [[self _davItemAttributes] mutableCopy];
	[properties addObjectsFromArray:@[
		[OCXMLNode elementWithName:@"oc:spaceid"],
		[OCXMLNode elementWithName:@"oc:trashbin-original-filename"],
		[OCXMLNode elementWithName:@"oc:trashbin-original-location"],
		[OCXMLNode elementWithName:@"oc:trashbin-delete-datetime"]
	]];
	return [properties copy];
}

- (void)_logTrashedItem:(OCItem *)item context:(NSString *)context
{
	OCLogDebug(@"[Trash] %@: path=%@ name=%@ type=%ld mimeType=%@ fileID=%@ driveID=%@ originalFilename=%@ originalLocation=%@ trashItem=%@",
		context,
		item.path,
		item.name,
		(long)item.type,
		item.mimeType,
		item.fileID,
		item.driveID,
		[item valueForLocalAttribute:OCLocalAttributeTrashOriginalFilename],
		[item valueForLocalAttribute:OCLocalAttributeTrashOriginalLocation],
		[item valueForLocalAttribute:OCLocalAttributeTrashItem] != nil ? @"YES" : @"NO");
}

- (NSString *)_stringTrashProperty:(id)value
{
	if ([value isKindOfClass:NSString.class]) {
		return ((NSString *)value).length > 0 ? value : nil;
	}
	return nil;
}

- (void)_applyTrashPropertiesFromMultistatusResponse:(OCHTTPDAVMultistatusResponse *)response toItem:(OCItem *)item
{
	if (response == nil || item == nil) { return; }

	OCHTTPStatus *okStatus = [OCHTTPStatus HTTPStatusWithCode:OCHTTPStatusCodeOK];
	NSDictionary *props = response.valueForPropByStatusCode[okStatus];
	if (props == nil) {
		for (OCHTTPStatus *status in response.valueForPropByStatusCode) {
			if (status.code == OCHTTPStatusCodeOK) {
				props = response.valueForPropByStatusCode[status];
				break;
			}
		}
	}
	if (props == nil) { return; }

	OCLogDebug(@"[Trash] applyTrashProperties path=%@ propKeys=%@", item.path, props.allKeys);

	NSString *originalFilename = [self _stringTrashProperty:props[@"oc:trashbin-original-filename"]];
	NSString *originalLocation = [self _stringTrashProperty:props[@"oc:trashbin-original-location"]];
	id deletionTimestamp = props[@"oc:trashbin-delete-datetime"];
	if (deletionTimestamp == (id)NSNull.null) {
		deletionTimestamp = props[@"oc:trashbin-delete-timestamp"];
	}

	NSString *spaceID = [self _stringTrashProperty:props[@"oc:spaceid"]];
	if (spaceID.length > 0) {
		item.driveID = spaceID;
	}

	if (originalFilename.length > 0) {
		[item setValue:originalFilename forLocalAttribute:OCLocalAttributeTrashOriginalFilename];
	}
	if (originalLocation.length > 0) {
		[item setValue:originalLocation forLocalAttribute:OCLocalAttributeTrashOriginalLocation];
	}
	if (deletionTimestamp != nil) {
		[item setValue:deletionTimestamp forLocalAttribute:OCLocalAttributeTrashDeletionTimestamp];
	}

	[self _enrichTrashedItem:item];
}

- (void)_enrichTrashedItem:(OCItem *)item
{
	if (item == nil) { return; }

	NSString *originalFilename = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalFilename];
	NSString *originalLocation = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalLocation];

	if (originalFilename.length == 0) {
		NSString *name = item.name;

		if (name.length > 0) {
			NSRange dotDRange = [name rangeOfString:@".d" options:NSBackwardsSearch];

			if (dotDRange.location != NSNotFound) {
				originalFilename = [name substringToIndex:dotDRange.location];
			} else {
				originalFilename = name;
			}

			if (originalFilename.length > 0) {
				[item setValue:originalFilename forLocalAttribute:OCLocalAttributeTrashOriginalFilename];
			}
		}
	}

	if (originalFilename.length == 0 && originalLocation.length > 0) {
		originalFilename = originalLocation.lastPathComponent;
		if (originalFilename.length > 0) {
			[item setValue:originalFilename forLocalAttribute:OCLocalAttributeTrashOriginalFilename];
		}
	}

	if ([self _isUninformativeMIMEType:item.mimeType] && originalFilename.length > 0) {
		NSString *mimeType = [self _mimeTypeForFilename:originalFilename];
		if (mimeType.length > 0) {
			item.mimeType = mimeType;
		}
	}

	if (item.driveID.length == 0) {
		OCDriveID personalDriveID = [self _personalDriveID];
		if (personalDriveID.length > 0) {
			item.driveID = personalDriveID;
		}
	}

	if (item.fileID.length == 0 && item.path.length > 0) {
		item.fileID = item.path.lastPathComponent;
	}

	[self _logTrashedItem:item context:@"enrichTrashedItem"];
}

#pragma mark - List

- (NSString *)_normalizedTrashPath:(NSString *)path
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

- (BOOL)_isImmediateChildPath:(NSString *)childPath ofFolderPath:(nullable NSString *)folderPath
{
	NSString *child = [self _normalizedTrashPath:childPath];

	if (child.length == 0) { return NO; }

	NSString *folder = [self _normalizedTrashPath:folderPath];

	if (folder.length == 0) {
		return ([child rangeOfString:@"/"].location == NSNotFound);
	}

	if (![child isEqualToString:folder] && ![child hasPrefix:[folder stringByAppendingString:@"/"]]) {
		return NO;
	}

	if ([child isEqualToString:folder]) {
		return NO;
	}

	NSString *remainder = [child substringFromIndex:folder.length];

	if ([remainder hasPrefix:@"/"]) {
		remainder = [remainder substringFromIndex:1];
	}

	return (remainder.length > 0 && [remainder rangeOfString:@"/"].location == NSNotFound);
}

- (BOOL)_shouldIncludeTrashedItem:(OCItem *)item inFolder:(nullable OCItem *)folderItem
{
	if (folderItem == nil) {
		if (item.type == OCItemTypeCollection && (item.path.length == 0 || [item.path isEqualToString:@"/"])) {
			return NO;
		}

		return ([self _isImmediateChildPath:item.path ofFolderPath:nil]);
	}

	NSString *relativePath = [self _normalizedTrashPath:item.path];

	if (relativePath.length == 0) {
		return NO;
	}

	return ([relativePath rangeOfString:@"/"].location == NSNotFound);
}

- (NSString *)_absoluteTrashPathForItemPath:(NSString *)itemPath inFolder:(OCItem *)folderItem
{
	NSString *relativePath = [self _normalizedTrashPath:itemPath];
	NSString *folderPath = [self _normalizedTrashPath:folderItem.path];

	if (relativePath.length == 0) {
		return (folderItem.path ?: @"/");
	}

	if (folderPath.length == 0) {
		return ([NSString stringWithFormat:@"/%@", relativePath]);
	}

	return ([NSString stringWithFormat:@"/%@/%@", folderPath, relativePath]);
}

- (nullable NSProgress *)retrieveTrashedItemsWithCompletionHandler:(OCConnectionTrashListCompletionHandler)completionHandler
{
	return ([self retrieveTrashedItemsInFolder:nil completionHandler:completionHandler]);
}

- (nullable NSProgress *)retrieveTrashedItemsInFolder:(nullable OCItem *)folderItem completionHandler:(OCConnectionTrashListCompletionHandler)completionHandler
{
	NSURL *url = nil;

	if (folderItem != nil) {
		url = [self _trashItemURLForItem:folderItem];

		if (url != nil && folderItem.type == OCItemTypeCollection) {
			NSString *absoluteURL = url.absoluteString;

			if (![absoluteURL hasSuffix:@"/"]) {
				url = [NSURL URLWithString:[absoluteURL stringByAppendingString:@"/"]];
			}
		}
	} else {
		url = [self _trashBinRootURL];
	}

	if (url == nil) {
		completionHandler(OCError(OCErrorInternal), nil);
		return nil;
	}

	OCHTTPDAVRequest *request = [OCHTTPDAVRequest propfindRequestWithURL:url depth:OCPropfindDepthItemAndImmediateChildren];
	[request.xmlRequestPropAttribute addChildren:[self _trashPropfindProperties]];
	request.requiredSignals = self.propFindSignals;

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error, nil);
			return;
		}
		if (!response.status.isSuccess) {
			completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal), nil);
			return;
		}

		NSArray<NSError *> *parseErrors = nil;
		NSArray<OCItem *> *items = [((OCHTTPDAVRequest *)req) responseItemsForBasePath:url.path drives:self.drives reuseUsersByID:self->_usersByUserID driveID:nil withErrors:&parseErrors];

		// Enrich items with trash-specific properties from the multistatus response
		if (response.bodyData != nil) {
			OCXMLParser *parser = [[OCXMLParser alloc] initWithData:response.bodyData];
			parser.options = [NSMutableDictionary dictionaryWithObject:url.path forKey:@"basePath"];
			[parser addObjectCreationClasses:@[ [OCHTTPDAVMultistatusResponse class] ]];

			if ([parser parse]) {
				NSMutableDictionary<NSString *, OCHTTPDAVMultistatusResponse *> *responsesByHref = [NSMutableDictionary new];
				for (id parsed in parser.parsedObjects) {
					if ([parsed isKindOfClass:[OCHTTPDAVMultistatusResponse class]]) {
						OCHTTPDAVMultistatusResponse *msr = (OCHTTPDAVMultistatusResponse *)parsed;
						if (msr.path != nil) {
							responsesByHref[msr.path] = msr;
						}
					}
				}

				for (OCItem *item in items) {
					NSString *normalizedPath = item.path;
					if ([normalizedPath hasPrefix:@"/"]) {
						normalizedPath = [normalizedPath substringFromIndex:1];
					}

					NSString *itemHref = [url.path stringByAppendingPathComponent:normalizedPath];
					OCHTTPDAVMultistatusResponse *msr = responsesByHref[itemHref];
					if (msr == nil) {
						itemHref = [url.path stringByAppendingFormat:@"/%@", normalizedPath];
						msr = responsesByHref[itemHref];
					}
					if (msr == nil) {
						// Try matching by last path component (file id)
						for (NSString *href in responsesByHref) {
							if ([href isEqualToString:normalizedPath]
							    || [href hasSuffix:normalizedPath]
							    || [href hasSuffix:[@"/" stringByAppendingString:normalizedPath]]) {
								msr = responsesByHref[href];
								break;
							}
						}
					}
					if (msr == nil) {
						OCLogDebug(@"[Trash] list: no multistatus match for item path=%@", item.path);
					}
					[self _applyTrashPropertiesFromMultistatusResponse:msr toItem:item];
				}
			}
		}

		NSMutableArray<OCItem *> *filteredItems = [NSMutableArray new];
		for (OCItem *item in items) {
			if (![self _shouldIncludeTrashedItem:item inFolder:folderItem]) {
				continue;
			}

			if (folderItem != nil) {
				item.path = [self _absoluteTrashPathForItemPath:item.path inFolder:folderItem];
			}

			[item setValue:@YES forLocalAttribute:OCLocalAttributeTrashItem];
			[self _enrichTrashedItem:item];
			[filteredItems addObject:item];
		}

		completionHandler(nil, filteredItems);
		OCLogDebug(@"[Trash] list: returning %lu item(s) in folder=%@", (unsigned long)filteredItems.count, folderItem.path ?: @"/");
	}];
}

#pragma mark - Restore

- (nullable OCProgress *)_enqueueTrashSyncRequest:(OCHTTPRequest *)request
				       eventType:(OCEventType)eventType
			    localizedDescription:(NSString *)localizedDescription
{
	if (request == nil) { return (nil); }

	request.forceCertificateDecisionDelegation = YES;
	[self attachToPipelines];
	[self.commandPipeline enqueueRequest:request forPartitionID:self.partitionID];

	OCProgress *requestProgress = request.progress;

	if ((requestProgress.progress != nil) && (localizedDescription.length > 0))
	{
		requestProgress.progress.eventType = eventType;
		requestProgress.progress.localizedDescription = localizedDescription;
	}

	return (requestProgress);
}

- (nullable NSError *)_trashRestoreConflictErrorForResponse:(OCHTTPResponse *)response
{
	if (response == nil)
	{
		return (nil);
	}

	switch (response.status.code)
	{
		case OCHTTPStatusCodePRECONDITION_FAILED:
		case OCHTTPStatusCodeCONFLICT:
		case OCHTTPStatusCodeLOCKED:
			return (OCError(OCErrorItemAlreadyExists));
		default:
			break;
	}

	NSError *davError = [response bodyParsedAsDAVError];

	if (davError != nil)
	{
		NSString *davExceptionName = davError.davExceptionName;

		if ((davExceptionName != nil) &&
		    ([davExceptionName containsString:@"FileLocked"] ||
		     [davExceptionName containsString:@"PreconditionFailed"] ||
		     [davExceptionName containsString:@"Conflict"]))
		{
			return (OCError(OCErrorItemAlreadyExists));
		}
	}

	return (nil);
}

- (void)_handleTrashRestoreResult:(OCHTTPRequest *)request error:(NSError *)error
{
	OCEvent *event;

	if ((event = [OCEvent eventForEventTarget:request.eventTarget type:OCEventTypeMove uuid:request.identifier attributes:nil]) != nil)
	{
		if (error != nil)
		{
			event.error = error;
		}
		else if (request.error != nil)
		{
			event.error = request.error;
		}
		else if (request.httpResponse.status.isSuccess || request.httpResponse.status.code == OCHTTPStatusCodeNO_CONTENT)
		{
			event.result = request.httpResponse.status;
		}
		else if ((event.error = [self _trashRestoreConflictErrorForResponse:request.httpResponse]) != nil)
		{
		}
		else
		{
			event.error = request.httpResponse.bodyParsedAsDAVError ?: request.httpResponse.status.error ?: OCError(OCErrorInternal);
		}

		[request.eventTarget handleEvent:event sender:self];
	}
}

- (nullable OCProgress *)restoreTrashedItem:(OCItem *)item resultTarget:(OCEventTarget *)eventTarget
{
	if (item == nil)
	{
		[eventTarget handleError:OCError(OCErrorInvalidParameter) type:OCEventTypeMove uuid:nil sender:self];
		return (nil);
	}

	if (self.useDriveAPI && item.driveID.length > 0 && item.fileID.length > 0)
	{
		NSURL *itemURL = [[[[self URLForEndpoint:OCConnectionEndpointIDGraphDrivePermissions options:nil]
			URLByAppendingPathComponent:item.driveID]
			URLByAppendingPathComponent:@"items"]
			URLByAppendingPathComponent:item.fileID];

		OCHTTPRequest *request = [OCHTTPRequest requestWithURL:itemURL];
		request.method = OCHTTPMethodPATCH;
		[request setValue:@"T" forHeaderField:@"Restore"];
		request.bodyData = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
		[request setValue:@"application/json" forHeaderField:OCHTTPHeaderFieldNameContentType];
		request.requiredSignals = self.actionSignals;
		request.eventTarget = eventTarget;
		request.resultHandlerAction = @selector(_handleTrashRestoreResult:error:);

		return ([self _enqueueTrashSyncRequest:request eventType:OCEventTypeMove localizedDescription:[NSString stringWithFormat:OCLocalizedString(@"Restoring %@…", nil), item.name]]);
	}

	NSString *originalLocation = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalLocation];
	NSURL *trashItemURL = [self _trashItemURLForItem:item];
	NSURL *filesRootURL = [self URLForEndpoint:OCConnectionEndpointIDWebDAVRoot options:@{
		OCConnectionEndpointURLOptionDriveID : OCNullProtect(item.driveID)
	}];

	if (trashItemURL == nil || filesRootURL == nil || originalLocation.length == 0)
	{
		[eventTarget handleError:OCError(OCErrorInsufficientParameters) type:OCEventTypeMove uuid:nil sender:self];
		return (nil);
	}

	NSURL *destinationURL = [filesRootURL URLByAppendingPathComponent:originalLocation];
	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:trashItemURL];
	request.method = OCHTTPMethodMOVE;
	request.requiredSignals = self.actionSignals;
	request.eventTarget = eventTarget;
	request.resultHandlerAction = @selector(_handleTrashRestoreResult:error:);
	[request setValue:[destinationURL absoluteString] forHeaderField:OCHTTPHeaderFieldNameDestination];
	[request setValue:@"T" forHeaderField:OCHTTPHeaderFieldNameOverwrite];

	return ([self _enqueueTrashSyncRequest:request eventType:OCEventTypeMove localizedDescription:[NSString stringWithFormat:OCLocalizedString(@"Restoring %@…", nil), item.name]]);
}

- (nullable NSProgress *)restoreTrashedItem:(OCItem *)item completionHandler:(OCConnectionTrashModificationCompletionHandler)completionHandler
{
	if (item == nil) {
		completionHandler(OCError(OCErrorInvalidParameter));
		return nil;
	}

	if (self.useDriveAPI && item.driveID.length > 0 && item.fileID.length > 0) {
		NSURL *itemURL = [[[[self URLForEndpoint:OCConnectionEndpointIDGraphDrivePermissions options:nil]
			URLByAppendingPathComponent:item.driveID]
			URLByAppendingPathComponent:@"items"]
			URLByAppendingPathComponent:item.fileID];

		OCHTTPRequest *request = [OCHTTPRequest requestWithURL:itemURL];
		request.method = OCHTTPMethodPATCH;
		[request setValue:@"T" forHeaderField:@"Restore"];
		request.bodyData = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
		[request setValue:@"application/json" forHeaderField:OCHTTPHeaderFieldNameContentType];
		request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

		return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
			if (error != nil) {
				completionHandler(error);
				return;
			}
			if (response.status.isSuccess) {
				completionHandler(nil);
			} else if ((error = [self _trashRestoreConflictErrorForResponse:response]) != nil) {
				completionHandler(error);
			} else {
				completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
			}
		}];
	}

	NSString *originalLocation = [item valueForLocalAttribute:OCLocalAttributeTrashOriginalLocation];
	NSURL *trashItemURL = [self _trashItemURLForItem:item];
	NSURL *filesRootURL = [self URLForEndpoint:OCConnectionEndpointIDWebDAVRoot options:@{
		OCConnectionEndpointURLOptionDriveID : OCNullProtect(item.driveID)
	}];

	if (trashItemURL == nil || filesRootURL == nil || originalLocation.length == 0) {
		completionHandler(OCError(OCErrorInsufficientParameters));
		return nil;
	}

	NSURL *destinationURL = [filesRootURL URLByAppendingPathComponent:originalLocation];
	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:trashItemURL];
	request.method = OCHTTPMethodMOVE;
	request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];
	[request setValue:[destinationURL absoluteString] forHeaderField:OCHTTPHeaderFieldNameDestination];
	[request setValue:@"T" forHeaderField:OCHTTPHeaderFieldNameOverwrite];

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error);
			return;
		}
		if (response.status.code == OCHTTPStatusCodeNO_CONTENT || response.status.isSuccess) {
			completionHandler(nil);
		} else if ((error = [self _trashRestoreConflictErrorForResponse:response]) != nil) {
			completionHandler(error);
		} else {
			completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
		}
	}];
}

#pragma mark - Permanent delete

- (void)_handleTrashPurgeResult:(OCHTTPRequest *)request error:(NSError *)error
{
	OCEvent *event;

	if ((event = [OCEvent eventForEventTarget:request.eventTarget type:OCEventTypeDelete uuid:request.identifier attributes:nil]) != nil)
	{
		if (error != nil)
		{
			event.error = error;
		}
		else if (request.error != nil)
		{
			event.error = request.error;
		}
		else if (request.httpResponse.status.isSuccess || request.httpResponse.status.code == OCHTTPStatusCodeNO_CONTENT)
		{
			event.result = request.httpResponse.status;
		}
		else if (request.httpResponse.status.code == OCHTTPStatusCodeNOT_FOUND)
		{
			event.error = OCError(OCErrorResourceDoesNotExist);
		}
		else
		{
			event.error = request.httpResponse.bodyParsedAsDAVError ?: request.httpResponse.status.error ?: OCError(OCErrorInternal);
		}

		[request.eventTarget handleEvent:event sender:self];
	}
}

- (nullable OCProgress *)permanentlyDeleteTrashedItem:(OCItem *)item resultTarget:(OCEventTarget *)eventTarget
{
	if (item == nil)
	{
		[eventTarget handleError:OCError(OCErrorInvalidParameter) type:OCEventTypeDelete uuid:nil sender:self];
		return (nil);
	}

	if (self.useDriveAPI && item.driveID.length > 0 && item.fileID.length > 0)
	{
		NSURL *itemURL = [[[[self URLForEndpoint:OCConnectionEndpointIDGraphDrivePermissions options:nil]
			URLByAppendingPathComponent:item.driveID]
			URLByAppendingPathComponent:@"items"]
			URLByAppendingPathComponent:item.fileID];

		OCHTTPRequest *request = [OCHTTPRequest requestWithURL:itemURL];
		request.method = OCHTTPMethodDELETE;
		[request setValue:@"T" forHeaderField:@"Purge"];
		request.requiredSignals = self.actionSignals;
		request.eventTarget = eventTarget;
		request.resultHandlerAction = @selector(_handleTrashPurgeResult:error:);

		return ([self _enqueueTrashSyncRequest:request eventType:OCEventTypeDelete localizedDescription:[NSString stringWithFormat:OCLocalizedString(@"Deleting %@…", nil), item.name]]);
	}

	NSURL *trashItemURL = [self _trashItemURLForItem:item];
	if (trashItemURL == nil)
	{
		[eventTarget handleError:OCError(OCErrorInsufficientParameters) type:OCEventTypeDelete uuid:nil sender:self];
		return (nil);
	}

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:trashItemURL];
	request.method = OCHTTPMethodDELETE;
	request.requiredSignals = self.actionSignals;
	request.eventTarget = eventTarget;
	request.resultHandlerAction = @selector(_handleTrashPurgeResult:error:);

	return ([self _enqueueTrashSyncRequest:request eventType:OCEventTypeDelete localizedDescription:[NSString stringWithFormat:OCLocalizedString(@"Deleting %@…", nil), item.name]]);
}

- (nullable NSProgress *)permanentlyDeleteTrashedItem:(OCItem *)item completionHandler:(OCConnectionTrashModificationCompletionHandler)completionHandler
{
	if (item == nil) {
		completionHandler(OCError(OCErrorInvalidParameter));
		return nil;
	}

	if (self.useDriveAPI && item.driveID.length > 0 && item.fileID.length > 0) {
		NSURL *itemURL = [[[[self URLForEndpoint:OCConnectionEndpointIDGraphDrivePermissions options:nil]
			URLByAppendingPathComponent:item.driveID]
			URLByAppendingPathComponent:@"items"]
			URLByAppendingPathComponent:item.fileID];

		OCHTTPRequest *request = [OCHTTPRequest requestWithURL:itemURL];
		request.method = OCHTTPMethodDELETE;
		[request setValue:@"T" forHeaderField:@"Purge"];
		request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

		return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
			if (error != nil) {
				completionHandler(error);
				return;
			}
			if (response.status.code == OCHTTPStatusCodeNO_CONTENT || response.status.isSuccess) {
				completionHandler(nil);
			} else if (response.status.code == OCHTTPStatusCodeNOT_FOUND) {
				completionHandler(OCError(OCErrorResourceDoesNotExist));
			} else {
				completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
			}
		}];
	}

	NSURL *trashItemURL = [self _trashItemURLForItem:item];
	if (trashItemURL == nil) {
		completionHandler(OCError(OCErrorInsufficientParameters));
		return nil;
	}

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:trashItemURL];
	request.method = OCHTTPMethodDELETE;
	request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error);
			return;
		}
		if (response.status.code == OCHTTPStatusCodeNO_CONTENT || response.status.isSuccess) {
			completionHandler(nil);
		} else if (response.status.code == OCHTTPStatusCodeNOT_FOUND) {
			completionHandler(OCError(OCErrorResourceDoesNotExist));
		} else {
			completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
		}
	}];
}

@end
