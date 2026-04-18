//
//  OCSystemTag.m
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

#import "OCSystemTag.h"
#import "OCHTTPDAVMultistatusResponse.h"
#import "OCHTTPStatus.h"

@implementation OCSystemTag

+ (BOOL)supportsSecureCoding
{
	return (YES);
}

- (instancetype)init
{
	if ((self = [super init]) != nil)
	{
		_identifier = nil;
		_displayName = @"";
		_userVisible = YES;
		_userAssignable = YES;
	}
	return (self);
}

- (instancetype)initWithIdentifier:(OCSystemTagID)identifier displayName:(NSString *)displayName userVisible:(BOOL)userVisible userAssignable:(BOOL)userAssignable
{
	if ((self = [super init]) != nil)
	{
		_identifier = identifier;
		_displayName = displayName ?: @"";
		_userVisible = userVisible;
		_userAssignable = userAssignable;
	}
	return (self);
}

- (nullable instancetype)initWithMultistatusResponse:(OCHTTPDAVMultistatusResponse *)response
{
	NSDictionary<OCHTTPStatus *, NSDictionary<NSString *, id> *> *valueForPropByStatusCode = response.valueForPropByStatusCode;
	NSDictionary<NSString *, id> *props = nil;

	for (OCHTTPStatus *status in valueForPropByStatusCode)
	{
		if (status.code == OCHTTPStatusCodeOK)
		{
			props = valueForPropByStatusCode[status];
			break;
		}
	}

	if (props == nil)
	{
		return (nil);
	}

	NSString *identifier = nil;
	id idValue = props[@"oc:id"];
	if ([idValue isKindOfClass:[NSString class]])
	{
		identifier = (NSString *)idValue;
	}
	else if (idValue == nil || [idValue isKindOfClass:[NSNull class]])
	{
		// Extract ID from path if oc:id not present (e.g. /remote.php/dav/systemtags/10 -> 10)
		NSString *path = response.path;
		if (path != nil)
		{
			identifier = [path lastPathComponent];
		}
	}

	if (identifier == nil)
	{
		return (nil);
	}

	NSString *displayName = @"";
	id nameValue = props[@"oc:display-name"];
	if ([nameValue isKindOfClass:[NSString class]])
	{
		displayName = (NSString *)nameValue;
	}

	BOOL userVisible = YES;
	id visibleValue = props[@"oc:user-visible"];
	if ([visibleValue isKindOfClass:[NSString class]])
	{
		userVisible = [((NSString *)visibleValue) isEqualToString:@"true"] || [((NSString *)visibleValue) isEqualToString:@"1"];
	}

	BOOL userAssignable = YES;
	id assignableValue = props[@"oc:user-assignable"];
	if ([assignableValue isKindOfClass:[NSString class]])
	{
		userAssignable = [((NSString *)assignableValue) isEqualToString:@"true"] || [((NSString *)assignableValue) isEqualToString:@"1"];
	}

	return ([self initWithIdentifier:identifier displayName:displayName userVisible:userVisible userAssignable:userAssignable]);
}

+ (nullable instancetype)fromMultistatusResponse:(OCHTTPDAVMultistatusResponse *)response
{
	return ([[OCSystemTag alloc] initWithMultistatusResponse:response]);
}

#pragma mark - NSSecureCoding
- (instancetype)initWithCoder:(NSCoder *)coder
{
	if ((self = [super init]) != nil)
	{
		_identifier = [coder decodeObjectOfClass:[NSString class] forKey:@"identifier"];
		_displayName = [coder decodeObjectOfClass:[NSString class] forKey:@"displayName"] ?: @"";
		_userVisible = [coder decodeBoolForKey:@"userVisible"];
		_userAssignable = [coder decodeBoolForKey:@"userAssignable"];
	}
	return (self);
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_identifier forKey:@"identifier"];
	[coder encodeObject:_displayName forKey:@"displayName"];
	[coder encodeBool:_userVisible forKey:@"userVisible"];
	[coder encodeBool:_userAssignable forKey:@"userAssignable"];
}

#pragma mark - NSCopying
- (id)copyWithZone:(nullable NSZone *)zone
{
	OCSystemTag *copy = [[OCSystemTag alloc] initWithIdentifier:_identifier displayName:_displayName userVisible:_userVisible userAssignable:_userAssignable];
	return (copy);
}

#pragma mark - Equality
- (BOOL)isEqual:(id)object
{
	if ([object isKindOfClass:[OCSystemTag class]])
	{
		return ([_identifier isEqual:((OCSystemTag *)object).identifier]);
	}
	return (NO);
}

- (NSUInteger)hash
{
	return (_identifier.hash);
}

@end
