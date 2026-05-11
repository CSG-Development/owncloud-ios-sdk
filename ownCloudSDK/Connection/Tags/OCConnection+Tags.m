//
//  OCConnection+Tags.m
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

#import "OCConnection+Tags.h"
#import "OCSystemTag.h"
#import "OCConnection.h"
#import "OCEvent.h"
#import "OCXMLParser.h"
#import "OCHTTPRequest.h"
#import "OCHTTPDAVRequest.h"
#import "OCHTTPDAVMultistatusResponse.h"
#import "OCXMLNode.h"
#import "OCHTTPStatus.h"
#import "OCHTTPResponse+DAVError.h"
#import "NSError+OCError.h"
#import "OCItem.h"
#import "OCMacros.h"

@implementation OCConnection (Tags)

#pragma mark - PROPFIND helpers

- (NSArray<OCXMLNode *> *)_tagPropfindProperties
{
	return @[
		[OCXMLNode elementWithName:@"oc:display-name"],
		[OCXMLNode elementWithName:@"oc:user-visible"],
		[OCXMLNode elementWithName:@"oc:user-assignable"],
		[OCXMLNode elementWithName:@"oc:id"]
	];
}

- (NSArray<OCSystemTag *> *)_systemTagsFromDAVResponseData:(NSData *)responseData basePath:(NSString *)basePath
{
	if (responseData == nil) { return @[]; }

	OCXMLParser *parser = [[OCXMLParser alloc] initWithData:responseData];
	if (parser == nil) { return @[]; }

	if (basePath != nil) {
		parser.options = [NSMutableDictionary dictionaryWithObject:basePath forKey:@"basePath"];
	}
	[parser addObjectCreationClasses:@[ [OCHTTPDAVMultistatusResponse class] ]];

	if (![parser parse]) { return @[]; }

	NSMutableArray<OCSystemTag *> *tags = [NSMutableArray new];
	OCHTTPStatus *okStatus = [OCHTTPStatus HTTPStatusWithCode:OCHTTPStatusCodeOK];

	for (id parsed in parser.parsedObjects) {
		if (![parsed isKindOfClass:[OCHTTPDAVMultistatusResponse class]]) { continue; }

		OCHTTPDAVMultistatusResponse *msr = (OCHTTPDAVMultistatusResponse *)parsed;
		NSDictionary *props = msr.valueForPropByStatusCode[okStatus];
		if (props == nil) {
			for (OCHTTPStatus *status in msr.valueForPropByStatusCode) {
				if (status.code == OCHTTPStatusCodeOK) {
					props = msr.valueForPropByStatusCode[status];
					break;
				}
			}
		}
		if (props == nil) { continue; }

		OCSystemTag *tag = [OCSystemTag fromMultistatusResponse:msr];
		if (tag != nil) {
			[tags addObject:tag];
		}
	}
	return [tags copy];
}

#pragma mark - List Tags

- (nullable NSProgress *)retrieveSystemTagsWithCompletionHandler:(OCConnectionTagsListCompletionHandler)completionHandler
{
	NSURL *url = [self URLForEndpoint:OCConnectionEndpointIDWebDAVSystemTags options:nil];
	if (url == nil) {
		completionHandler(OCError(OCErrorInternal), nil);
		return nil;
	}

	// Sabre DAV Tags API does not support Depth: infinity; use depth 1 for collection + immediate children (tags)
	OCHTTPDAVRequest *request = [OCHTTPDAVRequest propfindRequestWithURL:url depth:OCPropfindDepthItemAndImmediateChildren];
	[request.xmlRequestPropAttribute addChildren:[self _tagPropfindProperties]];
	request.requiredSignals = self.propFindSignals;

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error, nil);
			return;
		}
		if (!response.status.isSuccess) {
			NSError *responseError = response.bodyParsedAsDAVError ?: response.status.error;
			completionHandler(responseError ?: OCError(OCErrorInternal), nil);
			return;
		}
		NSArray<OCSystemTag *> *tags = [self _systemTagsFromDAVResponseData:response.bodyData basePath:url.path];
		completionHandler(nil, tags);
	}];
}

#pragma mark - Create Tag

- (nullable NSProgress *)createSystemTagWithName:(NSString *)name userVisible:(BOOL)userVisible userAssignable:(BOOL)userAssignable completionHandler:(OCConnectionTagCompletionHandler)completionHandler
{
	if (name.length == 0) {
		completionHandler(OCError(OCErrorInvalidParameter), nil);
		return nil;
	}

	NSURL *url = [self URLForEndpoint:OCConnectionEndpointIDWebDAVSystemTags options:nil];
	if (url == nil) {
		completionHandler(OCError(OCErrorInternal), nil);
		return nil;
	}
	// Ensure the collection URL ends with a trailing slash to avoid server-side redirects
	// (WebDAV collections are canonically accessed with a trailing slash)
	if (![url.absoluteString hasSuffix:@"/"]) {
		url = [NSURL URLWithString:[url.absoluteString stringByAppendingString:@"/"]];
	}

	NSDictionary *body = @{
        @"canAssign" : @YES,
		@"name" : name,
		@"userVisible" : (userVisible ? @YES : @NO),
        @"userEditable" : @YES,
		@"userAssignable" : (userAssignable ? @YES : @NO)
	};
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
	if (jsonData == nil) {
		completionHandler(OCError(OCErrorInternal), nil);
		return nil;
	}

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:url];
	request.method = OCHTTPMethodPOST;
	request.bodyData = jsonData;
	[request setValue:@"application/json" forHeaderField:OCHTTPHeaderFieldNameContentType];
	request.requiredSignals = self.propFindSignals;

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error, nil);
			return;
		}
		switch (response.status.code) {
			case OCHTTPStatusCodeCREATED: {
				NSString *location = response.headerFields[@"Content-Location"];
				NSString *tagId = nil;
				if (location.length > 0) {
					tagId = [location lastPathComponent];
				}
				OCSystemTag *tag = [[OCSystemTag alloc] init];
				tag.identifier = tagId;
				tag.displayName = name;
				tag.userVisible = userVisible;
				tag.userAssignable = userAssignable;
				completionHandler(nil, tag);
			}
			break;
			case OCHTTPStatusCodeCONFLICT:
				completionHandler(OCError(OCErrorItemAlreadyExists), nil);
			break;
			default: {
				NSError *davError = response.bodyParsedAsDAVError;
				NSString *davMessage = davError.davExceptionMessage;
				if (davMessage != nil && [davMessage rangeOfString:@"already exists" options:NSCaseInsensitiveSearch].location != NSNotFound) {
					completionHandler(OCError(OCErrorItemAlreadyExists), nil);
				} else {
					completionHandler(davError ?: response.status.error ?: OCError(OCErrorInternal), nil);
				}
			}
			break;
		}
	}];
}

#pragma mark - Update Tag

- (nullable NSProgress *)updateSystemTag:(OCSystemTag *)tag withDisplayName:(NSString *)displayName completionHandler:(OCConnectionTagModificationCompletionHandler)completionHandler
{
	if (tag.identifier.length == 0) {
		completionHandler(OCError(OCErrorInvalidParameter));
		return nil;
	}
	if (displayName.length == 0) {
		completionHandler(OCError(OCErrorInvalidParameter));
		return nil;
	}

	NSURL *baseURL = [self URLForEndpoint:OCConnectionEndpointIDWebDAVSystemTags options:nil];
	if (baseURL == nil) {
		completionHandler(OCError(OCErrorInternal));
		return nil;
	}
	NSURL *url = [baseURL URLByAppendingPathComponent:tag.identifier];

	OCXMLNode *setNode = [OCXMLNode elementWithName:@"D:set" children:@[
		[OCXMLNode elementWithName:@"D:prop" children:@[
			[OCXMLNode elementWithName:@"oc:display-name" stringValue:displayName]
		]]
	]];
	OCHTTPDAVRequest *request = [OCHTTPDAVRequest proppatchRequestWithURL:url content:@[ setNode ]];
	request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error);
			return;
		}
		if (response.status.code == OCHTTPStatusCodeMULTI_STATUS || response.status.isSuccess) {
			completionHandler(nil);
			return;
		}
		if (response.status.code == OCHTTPStatusCodeCONFLICT) {
			completionHandler(OCError(OCErrorItemAlreadyExists));
			return;
		}
		NSError *davError = response.bodyParsedAsDAVError;
		NSString *davMessage = davError.davExceptionMessage;
		if (davMessage != nil && [davMessage rangeOfString:@"already exists" options:NSCaseInsensitiveSearch].location != NSNotFound) {
			completionHandler(OCError(OCErrorItemAlreadyExists));
			return;
		}
		completionHandler(davError ?: response.status.error ?: OCError(OCErrorInternal));
	}];
}

#pragma mark - Delete Tag

- (nullable NSProgress *)deleteSystemTag:(OCSystemTag *)tag completionHandler:(OCConnectionTagModificationCompletionHandler)completionHandler
{
	if (tag.identifier.length == 0) {
		completionHandler(OCError(OCErrorInvalidParameter));
		return nil;
	}

	NSURL *baseURL = [self URLForEndpoint:OCConnectionEndpointIDWebDAVSystemTags options:nil];
	if (baseURL == nil) {
		completionHandler(OCError(OCErrorInternal));
		return nil;
	}
	NSURL *url = [baseURL URLByAppendingPathComponent:tag.identifier];

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:url];
	request.method = OCHTTPMethodDELETE;
	request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error);
			return;
		}
		if (response.status.code == OCHTTPStatusCodeNO_CONTENT || response.status.code == OCHTTPStatusCodeOK) {
			completionHandler(nil);
		} else if (response.status.code == OCHTTPStatusCodeNOT_FOUND) {
			completionHandler(OCError(OCErrorResourceDoesNotExist));
		} else {
			completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
		}
	}];
}

#pragma mark - Retrieve tags for file

- (nullable NSProgress *)retrieveTagsForFileWithID:(OCFileID)fileID completionHandler:(OCConnectionFileTagsCompletionHandler)completionHandler
{
	if (fileID.length == 0) {
		completionHandler(OCError(OCErrorInvalidParameter), nil);
		return nil;
	}

	NSURL *baseURL = [self URLForEndpoint:OCConnectionEndpointIDWebDAVSystemTagsRelations options:nil];
	if (baseURL == nil) {
		completionHandler(OCError(OCErrorInternal), nil);
		return nil;
	}
	NSURL *url = [[baseURL URLByAppendingPathComponent:@"files" isDirectory:YES] URLByAppendingPathComponent:fileID];

	OCHTTPDAVRequest *request = [OCHTTPDAVRequest propfindRequestWithURL:url depth:OCPropfindDepthItemAndImmediateChildren];
	[request.xmlRequestPropAttribute addChildren:[self _tagPropfindProperties]];
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
		NSArray<OCSystemTag *> *tags = [self _systemTagsFromDAVResponseData:response.bodyData basePath:url.path];
		completionHandler(nil, tags);
	}];
}

#pragma mark - Assign tag to file

- (nullable NSProgress *)assignTag:(OCSystemTag *)tag toFileWithID:(OCFileID)fileID completionHandler:(OCConnectionTagModificationCompletionHandler)completionHandler
{
	if (tag.identifier.length == 0 || fileID.length == 0) {
		completionHandler(OCError(OCErrorInvalidParameter));
		return nil;
	}

	NSURL *baseURL = [self URLForEndpoint:OCConnectionEndpointIDWebDAVSystemTagsRelations options:nil];
	if (baseURL == nil) {
		completionHandler(OCError(OCErrorInternal));
		return nil;
	}
	NSURL *url = [[[baseURL URLByAppendingPathComponent:@"files" isDirectory:YES] URLByAppendingPathComponent:fileID] URLByAppendingPathComponent:tag.identifier];

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:url];
	request.method = OCHTTPMethodPUT;
	[request setValue:@"application/xml" forHeaderField:OCHTTPHeaderFieldNameContentType];
	request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error);
			return;
		}
		switch (response.status.code) {
			case OCHTTPStatusCodeCREATED:
			case OCHTTPStatusCodeOK:
			case OCHTTPStatusCodeNO_CONTENT:
				completionHandler(nil);
			break;
			case OCHTTPStatusCodeNOT_FOUND:
				completionHandler(OCError(OCErrorResourceDoesNotExist));
			break;
			case OCHTTPStatusCodeCONFLICT:
				completionHandler(OCError(OCErrorItemAlreadyExists));
			break;
			default:
				completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
			break;
		}
	}];
}

#pragma mark - Unassign tag from file

- (nullable NSProgress *)unassignTag:(OCSystemTag *)tag fromFileWithID:(OCFileID)fileID completionHandler:(OCConnectionTagModificationCompletionHandler)completionHandler
{
	if (tag.identifier.length == 0 || fileID.length == 0) {
		completionHandler(OCError(OCErrorInvalidParameter));
		return nil;
	}

	NSURL *baseURL = [self URLForEndpoint:OCConnectionEndpointIDWebDAVSystemTagsRelations options:nil];
	if (baseURL == nil) {
		completionHandler(OCError(OCErrorInternal));
		return nil;
	}
	NSURL *url = [[[baseURL URLByAppendingPathComponent:@"files" isDirectory:YES] URLByAppendingPathComponent:fileID] URLByAppendingPathComponent:tag.identifier];

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:url];
	request.method = OCHTTPMethodDELETE;
	[request setValue:@"application/xml" forHeaderField:OCHTTPHeaderFieldNameContentType];
	request.requiredSignals = [NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable];

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error);
			return;
		}
		if (response.status.code == OCHTTPStatusCodeNO_CONTENT || response.status.code == OCHTTPStatusCodeOK) {
			completionHandler(nil);
		} else if (response.status.code == OCHTTPStatusCodeNOT_FOUND) {
			completionHandler(OCError(OCErrorResourceDoesNotExist));
		} else {
			completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal));
		}
	}];
}

#pragma mark - Create and assign tag in one request

- (nullable NSProgress *)createAndAssignTagWithName:(NSString *)name userVisible:(BOOL)userVisible userAssignable:(BOOL)userAssignable toFileWithID:(OCFileID)fileID completionHandler:(OCConnectionTagCompletionHandler)completionHandler
{
	if (name.length == 0 || fileID.length == 0) {
		completionHandler(OCError(OCErrorInvalidParameter), nil);
		return nil;
	}

	NSURL *baseURL = [self URLForEndpoint:OCConnectionEndpointIDWebDAVSystemTagsRelations options:nil];
	if (baseURL == nil) {
		completionHandler(OCError(OCErrorInternal), nil);
		return nil;
	}
	NSURL *url = [[baseURL URLByAppendingPathComponent:@"files" isDirectory:YES] URLByAppendingPathComponent:fileID];

	NSDictionary *body = @{
		@"name" : name,
		@"userVisible" : (userVisible ? @YES : @NO),
		@"userAssignable" : (userAssignable ? @YES : @NO)
	};
	NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
	if (jsonData == nil) {
		completionHandler(OCError(OCErrorInternal), nil);
		return nil;
	}

	OCHTTPRequest *request = [OCHTTPRequest requestWithURL:url];
	request.method = OCHTTPMethodPOST;
	request.bodyData = jsonData;
	[request setValue:@"application/json" forHeaderField:OCHTTPHeaderFieldNameContentType];
	request.requiredSignals = self.propFindSignals;

	return [self sendRequest:request ephermalCompletionHandler:^(OCHTTPRequest *req, OCHTTPResponse *response, NSError *error) {
		if (error != nil) {
			completionHandler(error, nil);
			return;
		}
		if (response.status.code == OCHTTPStatusCodeCREATED) {
			NSString *location = response.headerFields[@"Content-Location"];
			NSString *tagId = nil;
			if (location.length > 0) {
				tagId = [location lastPathComponent];
			}
			OCSystemTag *tag = [[OCSystemTag alloc] init];
			tag.identifier = tagId;
			tag.displayName = name;
			tag.userVisible = userVisible;
			tag.userAssignable = userAssignable;
			completionHandler(nil, tag);
		} else if (response.status.code == OCHTTPStatusCodeCONFLICT) {
			completionHandler(OCError(OCErrorItemAlreadyExists), nil);
		} else {
			completionHandler(response.bodyParsedAsDAVError ?: response.status.error ?: OCError(OCErrorInternal), nil);
		}
	}];
}

#pragma mark - Retrieve files by tag

- (nullable OCProgress *)retrieveFilesWithTag:(OCSystemTag *)tag resultTarget:(OCEventTarget *)eventTarget
{
	if (tag.identifier.length == 0) {
		[eventTarget handleError:OCError(OCErrorInvalidParameter) type:OCEventTypeFilterFiles uuid:nil sender:self];
		return nil;
	}
	return (OCProgress *)[self _retrieveFilesWithSystemTagID:tag.identifier eventTarget:eventTarget];
}

- (nullable OCProgress *)_retrieveFilesWithSystemTagID:(NSString *)tagID eventTarget:(OCEventTarget *)eventTarget
{
	if (tagID.length == 0) {
		[eventTarget handleError:OCError(OCErrorInvalidParameter) type:OCEventTypeFilterFiles uuid:nil sender:self];
		return nil;
	}

	NSURL *url = [self URLForEndpoint:OCConnectionEndpointIDWebDAVRoot options:nil];
	if (url == nil) {
		[eventTarget handleError:OCError(OCErrorInternal) type:OCEventTypeFilterFiles uuid:nil sender:self];
		return nil;
	}

	NSMutableArray<OCXMLNode *> *propNodes = [self _davItemAttributes];
	OCXMLNode *filterRules = [OCXMLNode elementWithName:@"oc:filter-rules" children:@[
		[OCXMLNode elementWithName:@"oc:systemtag" stringValue:tagID]
	]];
	NSArray *content = @[
		[OCXMLNode elementWithName:@"D:prop" children:propNodes],
		filterRules
	];

	OCHTTPDAVRequest *request = [OCHTTPDAVRequest reportRequestWithURL:url rootElementName:@"oc:filter-files" content:content];
	request.eventTarget = eventTarget;
	request.resultHandlerAction = @selector(_handleRetrieveFilesWithTagResult:error:);
	request.requiredSignals = self.propFindSignals;
	request.userInfo = @{ @"endpointURL" : url };

	[self attachToPipelines];
	[self.ephermalPipeline enqueueRequest:request forPartitionID:self.partitionID];

	return (OCProgress *)request.progress;
}

- (void)_handleRetrieveFilesWithTagResult:(OCHTTPRequest *)request error:(NSError *)error
{
	OCEvent *event;

	if ((event = [OCEvent eventForEventTarget:request.eventTarget type:OCEventTypeFilterFiles uuid:request.identifier attributes:nil]) != nil)
	{
		if (error != nil)
		{
			event.error = error;
		}
		else if (request.error != nil)
		{
			event.error = request.error;
		}
		else
		{
			if (request.httpResponse.status.isSuccess)
			{
				NSArray<OCItem *> *items = nil;
				NSArray<NSError *> *errors = nil;
				NSURL *endpointURL = request.userInfo[@"endpointURL"];

				if (endpointURL != nil)
				{
					if ((items = [((OCHTTPDAVRequest *)request) responseItemsForBasePath:endpointURL.path drives:_drives reuseUsersByID:self->_usersByUserID driveID:nil withErrors:&errors]) != nil)
					{
						event.result = items;
					}
					else
					{
						event.error = errors.firstObject;
					}
				}
				else
				{
					event.error = OCError(OCErrorInternal);
				}
			}
			else if (request.httpResponse.status.code == OCHTTPStatusCodePRECONDITION_FAILED)
			{
				event.error = OCError(OCErrorResourceDoesNotExist);
			}
			else
			{
				event.error = request.httpResponse.status.error;
			}
		}
	}

	if (event != nil)
	{
		OCErrorAddDateFromResponse(event.error, request.httpResponse);
		[request.eventTarget handleEvent:event sender:self];
	}
}

@end
