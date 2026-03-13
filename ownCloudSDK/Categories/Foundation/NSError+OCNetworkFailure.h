//
//  NSError+OCNetworkFailure.h
//  ownCloudSDK
//
//  Created by Felix Schwarz on 24.02.20.
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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on main when a request fails with @c isNetworkFailureError (ex.: status.php polling).
/// @c userInfo[@"error"] is the @c NSError. Does not replace @c OCCoreDelegate handleError (still not called for these).
FOUNDATION_EXPORT NSNotificationName const OCNetworkingFailureReachabilityNotification;

@interface NSError (OCNetworkFailure)

@property(readonly,nonatomic) BOOL isNetworkFailureError;
@property(readonly,nonatomic) BOOL isNetworkTimeoutError;

@end

NS_ASSUME_NONNULL_END
