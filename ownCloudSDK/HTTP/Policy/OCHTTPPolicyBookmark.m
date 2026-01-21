//
//  OCHTTPPolicyBookmark.m
//  ownCloudSDK
//
//  Created by Felix Schwarz on 20.07.20.
//  Copyright © 2020 ownCloud GmbH. All rights reserved.
//

/*
 * Copyright (C) 2020, ownCloud GmbH.
 *
 * This code is covered by the GNU Public License Version 3.
 *
 * For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 * You should have received a copy of this license along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 *
 */

#import "OCHTTPPolicyBookmark.h"
#import "OCBookmarkManager.h"
#import "OCConnection.h"
#import "OCCertificate.h"
#import "OCLogger.h"
#import "NSError+OCError.h"
#import "OCMacros.h"

@interface OCHTTPPolicyBookmark ()
{
	__weak OCBookmark *_bookmark;
	__weak OCConnection *_connection;
}
@end

@implementation OCHTTPPolicyBookmark

- (instancetype)initWithBookmarkUUID:(OCBookmarkUUID)bookmarkUUID
{
	if ((self = [super initWithIdentifier:OCHTTPPolicyIdentifierConnection]) != nil)
	{
		_bookmarkUUID = bookmarkUUID;
	}

	return (self);
}

- (instancetype)initWithBookmark:(OCBookmark *)bookmark;
{
	if ((self = [super initWithIdentifier:OCHTTPPolicyIdentifierConnection]) != nil)
	{
		_bookmark = bookmark;
		_bookmarkUUID = bookmark.uuid;
	}

	return (self);
}

- (instancetype)initWithConnection:(OCConnection *)connection
{
	if ((self = [super initWithIdentifier:OCHTTPPolicyIdentifierConnection]) != nil)
	{
		_connection = connection;
		_bookmarkUUID = connection.bookmark.uuid;
	}

	return (self);
}

- (void)validateCertificate:(nonnull OCCertificate *)certificate forRequest:(nonnull OCHTTPRequest *)request validationResult:(OCCertificateValidationResult)validationResult validationError:(nonnull NSError *)validationError proceedHandler:(nonnull OCConnectionCertificateProceedHandler)proceedHandler
{
	@synchronized (self)
	{
		if (_connection != nil)
		{
			_bookmark = _connection.bookmark;
		}

		if (_bookmark == nil)
		{
			_bookmark = [OCBookmarkManager.sharedBookmarkManager bookmarkForUUID:_bookmarkUUID];
		}
	}

	if (_bookmark != nil)
	{
		[OCHTTPPolicyBookmark validateBookmark:_bookmark certificate:certificate forRequest:request validationResult:validationResult validationError:validationError proceedHandler:proceedHandler];
	}
	else
	{
		OCLogWarning(@"No bookmark found for %@ - not performing certificate check, falling back to super implementation", _bookmarkUUID);
		[super validateCertificate:certificate forRequest:request validationResult:validationResult validationError:validationError proceedHandler:proceedHandler];
	}
}

+ (void)validateBookmark:(OCBookmark *)bookmark certificate:(nonnull OCCertificate *)certificateToValidate forRequest:(nonnull OCHTTPRequest *)request validationResult:(OCCertificateValidationResult)validationResult validationError:(nonnull NSError *)validationError proceedHandler:(nonnull OCConnectionCertificateProceedHandler)proceedHandler
{
	NSString *requestHostname = request.hostname;
	OCCertificate *storedCertificateForHostname = [bookmark.certificateStore certificateForHostname:requestHostname lastModified:NULL];

	if (proceedHandler != nil)
	{
		OCCertificateValidationHandler handler = [OCConnection certificateValidationHandler];

		if (handler != nil)
		{
			handler(nil, request, certificateToValidate, storedCertificateForHostname, proceedHandler);
			return;
		}

		// No app-level handler configured: reject by default.
		NSError *errorIssue = OCError(OCErrorRequestServerCertificateRejected);
		OCErrorAddDateFromResponse(errorIssue, request.httpResponse);
		OCIssue *issue = [OCIssue issueForCertificate:certificateToValidate validationResult:validationResult url:request.url level:OCIssueLevelWarning issueHandler:nil];
		errorIssue = [errorIssue errorByEmbeddingIssue:issue];
		proceedHandler(NO, errorIssue);
	}
}

#pragma mark - Secure coding
+ (BOOL)supportsSecureCoding
{
	return (YES);
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
	if ((self = [super initWithCoder:coder]) != nil)
	{
		_bookmarkUUID = [coder decodeObjectOfClass:NSUUID.class forKey:@"bookmarkUUID"];
	}

	return (self);
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[super encodeWithCoder:coder];

	[coder encodeObject:_bookmarkUUID forKey:@"bookmarkUUID"];
}

@end
