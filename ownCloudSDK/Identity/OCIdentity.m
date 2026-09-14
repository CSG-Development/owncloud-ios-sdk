//
//  OCIdentity.m
//  ownCloudSDK
//
//  Created by Felix Schwarz on 01.03.19.
//  Copyright © 2019 ownCloud GmbH. All rights reserved.
//

/*
 * Copyright (C) 2019, ownCloud GmbH.
 *
 * This code is covered by the GNU Public License Version 3.
 *
 * For distribution utilizing Apple mechanisms please see https://owncloud.org/contribute/iOS-license-exception/
 * You should have received a copy of this license along with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.en.html>.
 *
 */

#import "OCIdentity.h"
#import "OCMacros.h"

@implementation OCIdentity

@dynamic identifier;
@dynamic displayName;

+ (instancetype)identityWithUser:(OCUser *)user
{
	OCIdentity *recipient = [self new];

	recipient.type = OCIdentityTypeUser;
	recipient.user = user;

	return (recipient);
}

+ (instancetype)identityWithGroup:(OCGroup *)group
{
	OCIdentity *recipient = [self new];

	recipient.type = OCIdentityTypeGroup;
	recipient.group = group;

	return (recipient);
}

- (instancetype)withSearchResultName:(NSString *)searchResultName
{
	self.searchResultName = searchResultName;

	return (self);
}

#pragma mark - Search ranking

typedef struct {
	NSInteger kind;		// 0 exact, 1 prefix, 2 word-exact, 3 word-prefix, 4 contains, 100 none
	NSInteger field;	// 0 username, 1 display name, 2 email / additional info
	NSInteger position;
	NSInteger length;
} OCIdentitySearchMatch;

static const NSInteger OCIdentitySearchMatchKindNone = 100;
static const NSStringCompareOptions OCIdentitySearchCompareOptions = (NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch);

static OCIdentitySearchMatch OCIdentitySearchMatchMake(NSInteger kind, NSInteger field, NSInteger position, NSInteger length)
{
	OCIdentitySearchMatch match = { .kind = kind, .field = field, .position = position, .length = length };
	return (match);
}

static BOOL OCIdentitySearchMatchBetter(OCIdentitySearchMatch candidate, OCIdentitySearchMatch best)
{
	if (candidate.kind != best.kind) { return (candidate.kind < best.kind); }
	if (candidate.field != best.field) { return (candidate.field < best.field); }
	if (candidate.position != best.position) { return (candidate.position < best.position); }
	if (candidate.length != best.length) { return (candidate.length < best.length); }
	return (NO);
}

static void OCIdentitySearchConsiderString(NSString *value, NSString *term, NSInteger field, BOOL allowWordMatch, OCIdentitySearchMatch *best)
{
	if (value.length == 0)
	{
		return;
	}

	NSInteger valueLength = (NSInteger)value.length;

	if ([value compare:term options:OCIdentitySearchCompareOptions] == NSOrderedSame)
	{
		OCIdentitySearchMatch candidate = OCIdentitySearchMatchMake(0, field, 0, valueLength);
		if (OCIdentitySearchMatchBetter(candidate, *best)) { *best = candidate; }
		return;
	}

	NSRange prefixRange = [value rangeOfString:term options:(OCIdentitySearchCompareOptions | NSAnchoredSearch)];
	if (prefixRange.location != NSNotFound)
	{
		OCIdentitySearchMatch candidate = OCIdentitySearchMatchMake(1, field, 0, valueLength);
		if (OCIdentitySearchMatchBetter(candidate, *best)) { *best = candidate; }
		return;
	}

	if (allowWordMatch)
	{
		[value enumerateSubstringsInRange:NSMakeRange(0, value.length) options:NSStringEnumerationByWords usingBlock:^(NSString * _Nullable substring, NSRange substringRange, NSRange enclosingRange, BOOL * _Nonnull stop) {
			if (substring.length == 0) { return; }

			if ([substring compare:term options:OCIdentitySearchCompareOptions] == NSOrderedSame)
			{
				OCIdentitySearchMatch candidate = OCIdentitySearchMatchMake(2, field, (NSInteger)substringRange.location, (NSInteger)substring.length);
				if (OCIdentitySearchMatchBetter(candidate, *best)) { *best = candidate; }
				*stop = YES;
				return;
			}

			NSRange wordPrefixRange = [substring rangeOfString:term options:(OCIdentitySearchCompareOptions | NSAnchoredSearch)];
			if (wordPrefixRange.location != NSNotFound)
			{
				OCIdentitySearchMatch candidate = OCIdentitySearchMatchMake(3, field, (NSInteger)substringRange.location, (NSInteger)substring.length);
				if (OCIdentitySearchMatchBetter(candidate, *best)) { *best = candidate; }
			}
		}];

		if (best->kind <= 3)
		{
			return;
		}
	}

	NSRange containsRange = [value rangeOfString:term options:OCIdentitySearchCompareOptions];
	if (containsRange.location != NSNotFound)
	{
		OCIdentitySearchMatch candidate = OCIdentitySearchMatchMake(4, field, (NSInteger)containsRange.location, valueLength);
		if (OCIdentitySearchMatchBetter(candidate, *best)) { *best = candidate; }
	}
}

static OCIdentitySearchMatch OCIdentitySearchMatchForIdentity(OCIdentity *identity, NSString *term)
{
	OCIdentitySearchMatch best = OCIdentitySearchMatchMake(OCIdentitySearchMatchKindNone, 99, NSIntegerMax, NSIntegerMax);

	OCIdentitySearchConsiderString(identity.user.userName, term, 0, NO, &best);
	OCIdentitySearchConsiderString(identity.group.identifier, term, 0, NO, &best);
	OCIdentitySearchConsiderString(identity.user.displayName, term, 1, YES, &best);
	OCIdentitySearchConsiderString(identity.group.name, term, 1, YES, &best);
	OCIdentitySearchConsiderString(identity.user.emailAddress, term, 2, NO, &best);
	OCIdentitySearchConsiderString(identity.searchResultName, term, 2, NO, &best);

	return (best);
}

static NSInteger OCIdentitySearchMatchTypeRank(OCIdentityMatchType matchType)
{
	switch (matchType)
	{
		case OCIdentityMatchTypeExact:		return (0);
		case OCIdentityMatchTypeAdditional:	return (1);
		case OCIdentityMatchTypeUnknown:
		default:				return (2);
	}
}

+ (NSArray<OCIdentity *> *)identities:(NSArray<OCIdentity *> *)identities rankedBySearchTerm:(NSString *)searchTerm
{
	NSString *term = [searchTerm stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

	if ((identities.count < 2) || (term.length == 0))
	{
		return (identities);
	}

	return ([identities sortedArrayUsingComparator:^NSComparisonResult(OCIdentity *identity1, OCIdentity *identity2) {
		OCIdentitySearchMatch match1 = OCIdentitySearchMatchForIdentity(identity1, term);
		OCIdentitySearchMatch match2 = OCIdentitySearchMatchForIdentity(identity2, term);

		if (match1.kind != match2.kind) { return ((match1.kind < match2.kind) ? NSOrderedAscending : NSOrderedDescending); }
		if (match1.field != match2.field) { return ((match1.field < match2.field) ? NSOrderedAscending : NSOrderedDescending); }

		NSInteger type1 = OCIdentitySearchMatchTypeRank(identity1.matchType);
		NSInteger type2 = OCIdentitySearchMatchTypeRank(identity2.matchType);
		if (type1 != type2) { return ((type1 < type2) ? NSOrderedAscending : NSOrderedDescending); }

		if (match1.position != match2.position) { return ((match1.position < match2.position) ? NSOrderedAscending : NSOrderedDescending); }
		if (match1.length != match2.length) { return ((match1.length < match2.length) ? NSOrderedAscending : NSOrderedDescending); }

		NSString *name1 = identity1.displayName ?: identity1.user.userName ?: @"";
		NSString *name2 = identity2.displayName ?: identity2.user.userName ?: @"";
		return ([name1 localizedStandardCompare:name2]);
	}]);
}

- (NSString *)identifier
{
	switch (_type)
	{
		case OCIdentityTypeUser:
			if (_user.identifier != nil) {
				return (_user.identifier);
			}

			return (_user.userName);
		break;

		case OCIdentityTypeGroup:
			return (_group.identifier);
		break;
	}

	return (nil);
}

- (NSString *)displayName
{
	switch (_type)
	{
		case OCIdentityTypeUser:
			return ((_searchResultName.length == 0) ? _user.displayName : [_user.displayName stringByAppendingFormat:@" (%@)", _searchResultName]);
		break;

		case OCIdentityTypeGroup:
			return ((_searchResultName.length == 0) ? _group.name : [_group.name stringByAppendingFormat:@" (%@)", _searchResultName]);
		break;
	}

	return (nil);
}

#pragma mark - Comparison
- (NSUInteger)hash
{
	return (_type ^ (_user.hash << 3) ^ (_group.hash >> 3) ^ (_searchResultName.hash << 1));
}

- (BOOL)isEqual:(id)object
{
	OCIdentity *otherRecipient = OCTypedCast(object, OCIdentity);

	if (otherRecipient != nil)
	{
		#define compareVar(var) ((otherRecipient->var == var) || [otherRecipient->var isEqual:var])

		return ((otherRecipient.type == _type) && compareVar(_user) && compareVar(_group) && compareVar(_searchResultName));
	}

	return (NO);
}

#pragma mark - Copying
- (id)copyWithZone:(NSZone *)zone
{
	OCIdentity *recipient = [OCIdentity new];

	recipient->_type = _type;
	recipient->_user = _user;
	recipient->_group = _group;
	recipient->_searchResultName = _searchResultName;
	recipient->_matchType = _matchType;

	return (recipient);
}

#pragma mark - Secure coding
+ (BOOL)supportsSecureCoding
{
	return (YES);
}

- (instancetype)initWithCoder:(NSCoder *)decoder
{
	if ((self = [self init]) != nil)
	{
		_type = [decoder decodeIntegerForKey:@"type"];

		_group = [decoder decodeObjectOfClass:[OCGroup class] forKey:@"group"];
		_user = [decoder decodeObjectOfClass:[OCUser class] forKey:@"user"];

		_searchResultName = [decoder decodeObjectOfClass:[NSString class] forKey:@"searchResultName"];

		_matchType = [decoder decodeIntegerForKey:@"matchType"];
	}

	return (self);
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeInteger:_type forKey:@"type"];

	[coder encodeObject:_group forKey:@"group"];
	[coder encodeObject:_user forKey:@"user"];

	[coder encodeObject:_searchResultName forKey:@"searchResultName"];

	[coder encodeInteger:_matchType forKey:@"matchType"];
}

#pragma mark - Description
- (NSString *)description
{
	NSString *typeAsString = @"unknown";

	switch (_type)
	{
		case OCIdentityTypeUser:
			typeAsString = @"user";
		break;

		case OCIdentityTypeGroup:
			typeAsString = @"group";
		break;
	}

	return ([NSString stringWithFormat:@"<%@: %p, type: %@, identifier: %@, name: %@%@%@%@%@>", NSStringFromClass(self.class), self, typeAsString, self.identifier, self.displayName, ((_user!=nil)?[NSString stringWithFormat:@", user: %@", _user]:@""), ((_group!=nil)?[NSString stringWithFormat:@", group: %@", _group]:@""), ((_searchResultName!=nil)?[NSString stringWithFormat:@", searchResultName: %@", _searchResultName]:@""), ((_matchType!=OCIdentityMatchTypeUnknown) ? ((_matchType==OCIdentityMatchTypeExact) ? @", matchType: exact" : @", matchType: additional") : @"")]);
}

@end

// NSCoding compatibility shim following OCRecipient -> OCIdentity refactoring
@implementation OCRecipient
@end
