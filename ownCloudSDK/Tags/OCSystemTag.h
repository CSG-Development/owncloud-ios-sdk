//
//  OCSystemTag.h
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

#import <Foundation/Foundation.h>

@class OCHTTPDAVMultistatusResponse;

NS_ASSUME_NONNULL_BEGIN

typedef NSString* OCSystemTagID;

/**
 * Represents a system tag from the ownCloud Tags API.
 * See https://doc.owncloud.com/server/next/developer_manual/webdav_api/tags.html
 */
@interface OCSystemTag : NSObject <NSSecureCoding, NSCopying>

@property (strong, nonatomic) OCSystemTagID identifier;	//!< Tag ID (oc:id)
@property (strong, nonatomic) NSString *displayName;		//!< Visible tag name (oc:display-name)
@property (assign, nonatomic) BOOL userVisible;		//!< Whether tag is visible to users (oc:user-visible)
@property (assign, nonatomic) BOOL userAssignable;		//!< Whether users can assign this tag (oc:user-assignable)

- (instancetype)initWithIdentifier:(OCSystemTagID)identifier displayName:(NSString *)displayName userVisible:(BOOL)userVisible userAssignable:(BOOL)userAssignable;

+ (nullable instancetype)fromMultistatusResponse:(OCHTTPDAVMultistatusResponse *)response; //!< Creates an OCSystemTag from a DAV multistatus response

@end

NS_ASSUME_NONNULL_END
