//
//  OCConnection+Recipients.m
//  ownCloudSDK
//
//  Created by Felix Schwarz on 09.12.24.
//  Copyright © 2024 ownCloud GmbH. All rights reserved.
//

/*
 * Copyright (C) 2024, ownCloud GmbH.
 *
 * This code is covered by the GNU Public License Version 3.
 *
 * For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 * You should have received a copy of this license along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 *
 */

#import "OCConnection.h"
#import "NSError+OCError.h"
#import "OCMacros.h"
#import "OCConnection+OData.h"
#import "OCConnection+GraphAPI.h"
#import "GAUser.h"
#import "GAGroup.h"
#import "NSProgress+OCExtensions.h"

#if OC_LEGACY_SUPPORT
#import "OCConnection+RecipientsLegacy.h"
#endif /* OC_LEGACY_SUPPORT */

// oCIS Graph rejects $search shorter than GRAPH_IDENTITY_SEARCH_MIN_LENGTH (default 3) for regular users.
static const NSUInteger OCGraphIdentitySearchMinLength = 3;

@interface OCConnection (RecipientsInternal)
- (NSString *)_graphSearchParameterForTerm:(NSString *)searchTerm;
- (nullable NSProgress *)_retrieveRecipientsUsingGraphSearchForItemType:(OCItemType)itemType ofShareType:(nullable NSArray<OCShareTypeID> *)shareTypes searchTerm:(NSString *)searchTerm maximumNumberOfRecipients:(NSUInteger)maximumNumberOfRecipients completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler;
- (nullable NSProgress *)_retrieveRecipientsUsingGraphSearchForItemType:(OCItemType)itemType ofShareType:(nullable NSArray<OCShareTypeID> *)shareTypes searchTerm:(NSString *)searchTerm maximumNumberOfRecipients:(NSUInteger)maximumNumberOfRecipients allowShareesFallback:(BOOL)allowShareesFallback completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler;
- (nullable NSProgress *)_retrieveUsersForSearchTerm:(NSString *)searchTerm maximumResultCount:(NSUInteger)maximumResultCount completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler;
- (nullable NSProgress *)_retrieveGroupsForSearchTerm:(nullable NSString *)searchTerm maximumResultCount:(NSUInteger)maximumResultCount completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler;
#if OC_LEGACY_SUPPORT
- (nullable NSProgress *)_retrieveRecipientsUsingShareesResolvingGraphIDsForItemType:(OCItemType)itemType ofShareType:(nullable NSArray<OCShareTypeID> *)shareTypes searchTerm:(NSString *)searchTerm maximumNumberOfRecipients:(NSUInteger)maximumNumberOfRecipients completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler;
- (nullable NSProgress *)_enrichIdentitiesWithGraphIDs:(NSArray<OCIdentity *> *)identities completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler;
#endif
@end

@implementation OCConnection (Recipients)

#pragma mark - Search
- (nullable NSProgress *)retrieveRecipientsForItemType:(OCItemType)itemType ofShareType:(nullable NSArray <OCShareTypeID> *)shareTypes searchTerm:(nullable NSString *)searchTerm maximumNumberOfRecipients:(NSUInteger)maximumNumberOfRecipients completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler
{
	// OC 10
	#if OC_LEGACY_SUPPORT
	if (!self.useDriveAPI) {
		return ([self legacyRetrieveRecipientsForItemType:itemType ofShareType:shareTypes searchTerm:searchTerm maximumNumberOfRecipients:maximumNumberOfRecipients completionHandler:completionHandler]);
	}
	#endif /* OC_LEGACY_SUPPORT */

	if ((searchTerm == nil) || (searchTerm.length == 0))
	{
		if (completionHandler != nil)
		{
			completionHandler(nil, @[], YES);
		}
		return (nil);
	}

	#if OC_LEGACY_SUPPORT
	// Graph $search is substring/contains matching on the backend, but regular users are
	// rejected below GRAPH_IDENTITY_SEARCH_MIN_LENGTH (default 3). The OCS sharees API has
	// no such floor, so 1- and 2-character queries can still return matching users/groups.
	if (searchTerm.length < OCGraphIdentitySearchMinLength)
	{
		return ([self _retrieveRecipientsUsingShareesResolvingGraphIDsForItemType:itemType ofShareType:shareTypes searchTerm:searchTerm maximumNumberOfRecipients:maximumNumberOfRecipients completionHandler:completionHandler]);
	}
	#endif /* OC_LEGACY_SUPPORT */

	return ([self _retrieveRecipientsUsingGraphSearchForItemType:itemType ofShareType:shareTypes searchTerm:searchTerm maximumNumberOfRecipients:maximumNumberOfRecipients allowShareesFallback:YES completionHandler:completionHandler]);
}

- (NSString *)_graphSearchParameterForTerm:(NSString *)searchTerm
{
	// Quote only when OData would otherwise tokenize the term (emails, spaces, etc.).
	// Always-on quotes inflate Graph's min-length check by 2 ("N" is measured as 3, required 5).
	static NSCharacterSet *nonSimpleCharacters;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSMutableCharacterSet *simpleCharacters = [NSMutableCharacterSet alphanumericCharacterSet];
		[simpleCharacters addCharactersInString:@"._"];
		nonSimpleCharacters = simpleCharacters.invertedSet;
	});

	if ([searchTerm rangeOfCharacterFromSet:nonSimpleCharacters].location != NSNotFound)
	{
		NSString *escapedTerm = [[searchTerm stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
		return ([NSString stringWithFormat:@"\"%@\"", escapedTerm]);
	}

	return (searchTerm);
}

- (nullable NSProgress *)_retrieveRecipientsUsingGraphSearchForItemType:(OCItemType)itemType ofShareType:(nullable NSArray<OCShareTypeID> *)shareTypes searchTerm:(NSString *)searchTerm maximumNumberOfRecipients:(NSUInteger)maximumNumberOfRecipients completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler
{
	return ([self _retrieveRecipientsUsingGraphSearchForItemType:itemType ofShareType:shareTypes searchTerm:searchTerm maximumNumberOfRecipients:maximumNumberOfRecipients allowShareesFallback:YES completionHandler:completionHandler]);
}

- (nullable NSProgress *)_retrieveRecipientsUsingGraphSearchForItemType:(OCItemType)itemType ofShareType:(nullable NSArray<OCShareTypeID> *)shareTypes searchTerm:(NSString *)searchTerm maximumNumberOfRecipients:(NSUInteger)maximumNumberOfRecipients allowShareesFallback:(BOOL)allowShareesFallback completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler
{
	// ocis
	// Reference: https://owncloud.dev/apis/http/graph/users/#get-users
	NSProgress *progress = nil;
	NSProgress *combinedProgress = [NSProgress indeterminateProgress];
	NSMutableArray<OCIdentity *> *resultIdentities = [NSMutableArray new];
	__block NSError *combinedError = nil;
	dispatch_group_t completionGroup = dispatch_group_create();

	dispatch_group_enter(completionGroup);
	progress = [self _retrieveUsersForSearchTerm:searchTerm maximumResultCount:maximumNumberOfRecipients completionHandler:^(NSError * _Nullable error, NSArray<OCIdentity *> * _Nullable recipients, BOOL finished) {
		@synchronized(resultIdentities) {
			if (error != nil) {
				combinedError = error;
			}
			else
			{
				[resultIdentities addObjectsFromArray:recipients];
			}
		}
		dispatch_group_leave(completionGroup);
	}];
	if (progress != nil)
	{
		[combinedProgress addChild:progress withPendingUnitCount:50];
	}

	dispatch_group_enter(completionGroup);
	progress = [self _retrieveGroupsForSearchTerm:searchTerm maximumResultCount:maximumNumberOfRecipients completionHandler:^(NSError * _Nullable error, NSArray<OCIdentity *> * _Nullable recipients, BOOL finished) {
		@synchronized(resultIdentities) {
			if (error != nil) {
				combinedError = error;
			}
			else
			{
				[resultIdentities addObjectsFromArray:recipients];
			}
		}
		dispatch_group_leave(completionGroup);
	}];
	if (progress != nil)
	{
		[combinedProgress addChild:progress withPendingUnitCount:50];
	}

	dispatch_group_notify(completionGroup, dispatch_get_main_queue(), ^{
		#if OC_LEGACY_SUPPORT
		if ((combinedError != nil) && allowShareesFallback)
		{
			[self _retrieveRecipientsUsingShareesResolvingGraphIDsForItemType:itemType ofShareType:shareTypes searchTerm:searchTerm maximumNumberOfRecipients:maximumNumberOfRecipients completionHandler:completionHandler];
			return;
		}
		#endif /* OC_LEGACY_SUPPORT */

		completionHandler(combinedError, (combinedError == nil) ? resultIdentities : nil, YES);
	});

	return (combinedProgress);
}

#if OC_LEGACY_SUPPORT
- (nullable NSProgress *)_retrieveRecipientsUsingShareesResolvingGraphIDsForItemType:(OCItemType)itemType ofShareType:(nullable NSArray<OCShareTypeID> *)shareTypes searchTerm:(NSString *)searchTerm maximumNumberOfRecipients:(NSUInteger)maximumNumberOfRecipients completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler
{
	return ([self legacyRetrieveRecipientsForItemType:itemType ofShareType:shareTypes searchTerm:searchTerm maximumNumberOfRecipients:maximumNumberOfRecipients completionHandler:^(NSError * _Nullable error, NSArray<OCIdentity *> * _Nullable recipients, BOOL finished) {
		if (error != nil)
		{
			[self _retrieveRecipientsUsingGraphSearchForItemType:itemType ofShareType:shareTypes searchTerm:searchTerm maximumNumberOfRecipients:maximumNumberOfRecipients allowShareesFallback:NO completionHandler:completionHandler];
			return;
		}

		if (recipients.count == 0)
		{
			completionHandler(nil, @[], YES);
			return;
		}

		[self _enrichIdentitiesWithGraphIDs:recipients completionHandler:completionHandler];
	}]);
}

- (nullable NSProgress *)_enrichIdentitiesWithGraphIDs:(NSArray<OCIdentity *> *)identities completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler
{
	NSProgress *combinedProgress = NSProgress.indeterminateProgress;
	dispatch_group_t retrievalGroup = dispatch_group_create();
	NSMutableArray<OCIdentity *> *resolvedIdentities = [NSMutableArray new];

	for (OCIdentity *identity in identities)
	{
		OCUser *user = identity.user;
		OCGroup *group = identity.group;
		NSProgress *retrieveProgress = nil;

		if (user != nil)
		{
			OCUserID userID = (user.identifier.length > 0) ? user.identifier : user.userName;

			if (userID.length == 0)
			{
				@synchronized(resolvedIdentities) {
					[resolvedIdentities addObject:identity];
				}
				continue;
			}

			dispatch_group_enter(retrievalGroup);
			retrieveProgress = [self retrieveUserForID:userID completionHandler:^(NSError * _Nullable error, OCUser * _Nullable graphUser) {
				OCIdentity *resolvedIdentity = identity;

				if ((error == nil) && (graphUser != nil))
				{
					resolvedIdentity = [[OCIdentity identityWithUser:graphUser] withSearchResultName:identity.searchResultName];
					resolvedIdentity.matchType = identity.matchType;
				}

				@synchronized(resolvedIdentities) {
					[resolvedIdentities addObject:resolvedIdentity];
				}
				dispatch_group_leave(retrievalGroup);
			}];
		}
		else if ((group != nil) && (group.identifier.length > 0))
		{
			dispatch_group_enter(retrievalGroup);
			retrieveProgress = [self retrieveGroupForID:group.identifier completionHandler:^(NSError * _Nullable error, OCGroup * _Nullable graphGroup) {
				OCIdentity *resolvedIdentity = identity;

				if ((error == nil) && (graphGroup != nil))
				{
					resolvedIdentity = [[OCIdentity identityWithGroup:graphGroup] withSearchResultName:identity.searchResultName];
					resolvedIdentity.matchType = identity.matchType;
				}

				@synchronized(resolvedIdentities) {
					[resolvedIdentities addObject:resolvedIdentity];
				}
				dispatch_group_leave(retrievalGroup);
			}];
		}
		else
		{
			@synchronized(resolvedIdentities) {
				[resolvedIdentities addObject:identity];
			}
		}

		if (retrieveProgress != nil)
		{
			[combinedProgress addChild:retrieveProgress withPendingUnitCount:1];
		}
	}

	dispatch_group_notify(retrievalGroup, dispatch_get_main_queue(), ^{
		completionHandler(nil, resolvedIdentities, YES);
	});

	return (combinedProgress);
}
#endif /* OC_LEGACY_SUPPORT */

- (nullable NSProgress *)_retrieveUsersForSearchTerm:(NSString *)searchTerm maximumResultCount:(NSUInteger)maximumResultCount completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler
{
	return ([self requestODataAtURL:[self URLForEndpoint:OCConnectionEndpointIDGraphUsers options:nil] requireSignals:[NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable] selectEntityID:nil selectProperties:nil filterString:nil parameters:@{
		@"$search" : [self _graphSearchParameterForTerm:searchTerm],
		@"$orderby" : @"displayName"
	} entityClass:GAUser.class options:nil completionHandler:^(NSError * _Nullable error, id  _Nullable response) {
		NSMutableArray<OCIdentity *> *ocIdentities = nil;

		if (error == nil)
		{
			// Convert GAUser to OCIdentities
			NSArray<GAUser *> *gaUsers;

			if ((gaUsers = OCTypedCast(response, NSArray)) != nil)
			{
				ocIdentities = [NSMutableArray new];

				for (GAUser *gaUser in gaUsers)
				{
					OCUser *ocUser;

					if ((ocUser = [OCUser userWithGraphUser:gaUser]) != nil)
					{
						OCIdentity *ocIdentity;

						if ((ocIdentity = [OCIdentity identityWithUser:ocUser]) != nil)
						{
							[ocIdentities addObject:ocIdentity];
						}
					}
				}
			}
		}

		OCLogDebug(@"User response: identities=%@, error=%@", ocIdentities, error);

		completionHandler(error, (ocIdentities.count > 0) ? ocIdentities : nil, YES);
	}]);
}

- (nullable NSProgress *)_retrieveGroupsForSearchTerm:(nullable NSString *)searchTerm maximumResultCount:(NSUInteger)maximumResultCount completionHandler:(OCConnectionRecipientsRetrievalCompletionHandler)completionHandler
{
	return ([self requestODataAtURL:[self URLForEndpoint:OCConnectionEndpointIDGraphGroups options:nil] requireSignals:[NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable] selectEntityID:nil selectProperties:nil filterString:nil parameters:@{
		@"$search" : [self _graphSearchParameterForTerm:searchTerm],
		@"$orderby" : @"displayName"
	} entityClass:GAGroup.class options:nil completionHandler:^(NSError * _Nullable error, id  _Nullable response) {
		NSMutableArray<OCIdentity *> *ocIdentities = nil;

		if (error == nil)
		{
			// Convert GAGroup to OCIdentities
			NSArray<GAGroup *> *gaGroups;

			if ((gaGroups = OCTypedCast(response, NSArray)) != nil)
			{
				ocIdentities = [NSMutableArray new];

				for (GAGroup *gaGroup in gaGroups)
				{
					OCGroup *ocGroup;

					if ((ocGroup = [OCGroup groupWithGraphGroup:gaGroup]) != nil)
					{
						OCIdentity *ocIdentity;

						if ((ocIdentity = [OCIdentity identityWithGroup:ocGroup]) != nil)
						{
							[ocIdentities addObject:ocIdentity];
						}
					}
				}
			}
		}

		OCLogDebug(@"Group response: identities=%@, error=%@", ocIdentities, error);

		completionHandler(error, (ocIdentities.count > 0) ? ocIdentities : nil, YES);
	}]);
}

#pragma mark - Lookup
- (nullable NSProgress *)retrieveUserForID:(OCUserID)userID completionHandler:(OCConnectionUserRetrievalCompletionHandler)completionHandler
{
	// ocis-only
	if (!self.useDriveAPI) {
		completionHandler(OCError(OCErrorFeatureNotSupportedByServer), nil);
		return(nil);
	}

	// Reference: https://owncloud.dev/apis/http/graph/users/#get-usersuserid-or-accountname
	return ([self requestODataAtURL:[[self URLForEndpoint:OCConnectionEndpointIDGraphUsers options:nil] URLByAppendingPathComponent:userID] requireSignals:[NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable] selectEntityID:nil selectProperties:nil filterString:nil parameters:nil entityClass:GAUser.class options:nil completionHandler:^(NSError * _Nullable error, id  _Nullable response) {
		OCUser *user = nil;

		if (error == nil)
		{
			GAUser *gaUser;

			if ((gaUser = OCTypedCast(response, GAUser)) != nil)
			{
				// Convert GAUser to OCUser
				user = [OCUser userWithGraphUser:gaUser];
			}
			else
			{
				error = OCError(OCErrorResponseUnknownFormat);
			}
		}

		completionHandler(error, user);
	}]);
}

- (nullable NSProgress *)retrieveGroupForID:(OCGroupID)groupID completionHandler:(OCConnectionGroupRetrievalCompletionHandler)completionHandler
{
	// ocis-only
	if (!self.useDriveAPI) {
		completionHandler(OCError(OCErrorFeatureNotSupportedByServer), nil);
		return(nil);
	}

	// Reference: https://owncloud.dev/apis/http/graph/groups/#get-groupsgroupid
	return ([self requestODataAtURL:[[self URLForEndpoint:OCConnectionEndpointIDGraphGroups options:nil] URLByAppendingPathComponent:groupID] requireSignals:[NSSet setWithObject:OCConnectionSignalIDAuthenticationAvailable] selectEntityID:nil selectProperties:nil filterString:nil parameters:nil entityClass:GAGroup.class options:nil completionHandler:^(NSError * _Nullable error, id  _Nullable response) {
		OCGroup *group = nil;

		if (error == nil)
		{
			GAGroup *gaGroup;

			if ((gaGroup = OCTypedCast(response, GAGroup)) != nil)
			{
				// Convert GAGroup to OCGroup
				group = [OCGroup groupWithGraphGroup:gaGroup];
			}
			else
			{
				error = OCError(OCErrorResponseUnknownFormat);
			}
		}

		completionHandler(error, group);
	}]);
}

- (nullable NSProgress *)retrieveDetailsForIdentity:(OCIdentity *)identity completionHandler:(OCConnectionIdentityDetailsRetrievalCompletionHandler)completionHandler
{
	// ocis-only
	if (!self.useDriveAPI) {
		completionHandler(OCError(OCErrorFeatureNotSupportedByServer), nil);
		return(nil);
	}

	if (identity.user != nil) {
		return ([self retrieveUserForID:identity.user.identifier completionHandler:^(NSError * _Nullable error, OCUser * _Nullable user) {
			completionHandler(error, (user != nil) ? [OCIdentity identityWithUser:user] : nil);
		}]);
	} else if (identity.group != nil) {
		return ([self retrieveGroupForID:identity.group.identifier completionHandler:^(NSError * _Nullable error, OCGroup * _Nullable group) {
			completionHandler(error, (group != nil) ? [OCIdentity identityWithGroup:group] : nil);
		}]);
	} else {
		completionHandler(OCError(OCErrorInvalidParameter), nil);
	}

	return (nil);
}

- (nullable NSProgress *)retrieveDetailsForObjects:(NSArray *)identityObjects asIdentities:(BOOL)asIdentities resolveIdentities:(BOOL)resolveIdentities completionHandler:(OCConnectionIdentityObjectsDetailsRetrievalCompletionHandler)completionHandler
{
	// ocis-only
	if (!self.useDriveAPI) {
		completionHandler(OCError(OCErrorFeatureNotSupportedByServer), nil);
		return(nil);
	}
	NSProgress *combinedProgress = NSProgress.indeterminateProgress;
	dispatch_group_t retrievalGroup = dispatch_group_create();
	NSMutableArray *resultObjects = [NSMutableArray new];
	__block NSError *retrievalError = nil;

	for (id identityObj in identityObjects) {
		OCUser *user = OCTypedCast(identityObj, OCUser);
		OCGroup *group = OCTypedCast(identityObj, OCGroup);
		OCIdentity *identity = OCTypedCast(identityObj, OCIdentity);
		NSProgress *retrieveProgress = nil;

		if ((identity != nil) && resolveIdentities) {
			if (identity.user != nil) {
				user = identity.user;
				identity = nil;
			} else if (identity.group != nil) {
				group = identity.group;
				identity = nil;
			}
		}

		if (user != nil) {
			OCUserID userID = (user.identifier.length > 0) ? user.identifier : user.userName;
			if (userID.length == 0) {
				continue;
			}
			dispatch_group_enter(retrievalGroup);
			retrieveProgress = [self retrieveUserForID:userID completionHandler:^(NSError * _Nullable error, OCUser * _Nullable user) {
				@synchronized(resultObjects) {
					if ((error != nil) && (retrievalError == nil)) {
						retrievalError = error;
					}
					if (user != nil) {
						[resultObjects addObject:(asIdentities ? [OCIdentity identityWithUser:user] : user)];
					}
				}
				dispatch_group_leave(retrievalGroup);
			}];
		}

		if (group != nil) {
			dispatch_group_enter(retrievalGroup);
			retrieveProgress = [self retrieveGroupForID:group.identifier completionHandler:^(NSError * _Nullable error, OCGroup * _Nullable group) {
				@synchronized(resultObjects) {
					if ((error != nil) && (retrievalError == nil)) {
						retrievalError = error;
					}
					if (group != nil) {
						[resultObjects addObject:(asIdentities ? [OCIdentity identityWithGroup:group] : group)];
					}
				}
				dispatch_group_leave(retrievalGroup);
			}];
		}

		if (identity != nil) {
			dispatch_group_enter(retrievalGroup);
			retrieveProgress = [self retrieveDetailsForIdentity:identity completionHandler:^(NSError * _Nullable error, OCIdentity * _Nullable identity) {
				@synchronized(resultObjects) {
					if ((error != nil) && (retrievalError == nil)) {
						retrievalError = error;
					}
					if (identity != nil) {
						[resultObjects addObject:identity];
					}
				}
				dispatch_group_leave(retrievalGroup);
			}];
		}

		if (retrieveProgress != nil) {
			[combinedProgress addChild:retrieveProgress withPendingUnitCount:1];
		}
	}

	dispatch_group_notify(retrievalGroup, dispatch_get_main_queue(), ^{
		completionHandler(retrievalError, (retrievalError == nil) ? resultObjects : nil);
	});

	return (combinedProgress);
}

@end
