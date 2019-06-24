//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "OWSContactsManager.h"
#import "Environment.h"
#import "NSAttributedString+OWS.h"
#import "OWSFormat.h"
#import "OWSProfileManager.h"
#import "OWSUserProfile.h"
#import "ViewControllerUtils.h"
#import <Contacts/Contacts.h>
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalCoreKit/iOSVersions.h>
#import <SignalMessaging/SignalMessaging-Swift.h>
#import <SignalMessaging/UIColor+OWS.h>
#import <SignalMessaging/UIFont+OWS.h>
#import <SignalServiceKit/ContactsUpdater.h>
#import <SignalServiceKit/NSNotificationCenter+OWS.h>
#import <SignalServiceKit/NSString+SSK.h>
#import <SignalServiceKit/OWSError.h>
#import <SignalServiceKit/OWSPrimaryStorage.h>
#import <SignalServiceKit/PhoneNumber.h>
#import <SignalServiceKit/SignalAccount.h>
#import <SignalServiceKit/SignalAccountFinder.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const OWSContactsManagerSignalAccountsDidChangeNotification
    = @"OWSContactsManagerSignalAccountsDidChangeNotification";

NSString *const OWSContactsManagerCollection = @"OWSContactsManagerCollection";
NSString *const OWSContactsManagerKeyLastKnownContactPhoneNumbers
    = @"OWSContactsManagerKeyLastKnownContactPhoneNumbers";
NSString *const OWSContactsManagerKeyNextFullIntersectionDate = @"OWSContactsManagerKeyNextFullIntersectionDate2";

@interface OWSContactsManager () <SystemContactsFetcherDelegate>

@property (nonatomic) BOOL isContactsUpdateInFlight;
// This reflects the contents of the device phone book and includes
// contacts that do not correspond to any signal account.
@property (atomic) NSArray<Contact *> *allContacts;
@property (atomic) NSDictionary<NSString *, Contact *> *allContactsMap;
@property (atomic) NSArray<SignalAccount *> *signalAccounts;
@property (atomic) NSDictionary<NSString *, SignalAccount *> *signalAccountMap;
@property (nonatomic, readonly) SystemContactsFetcher *systemContactsFetcher;
@property (nonatomic, readonly) YapDatabaseConnection *dbReadConnection;
@property (nonatomic, readonly) YapDatabaseConnection *dbWriteConnection;
@property (nonatomic, readonly) SignalAccountFinder *accountFinder;
@property (nonatomic, readonly) NSCache<NSString *, CNContact *> *cnContactCache;
@property (nonatomic, readonly) NSCache<NSString *, UIImage *> *cnContactAvatarCache;
@property (atomic) BOOL isSetup;

@end

#pragma mark -

@implementation OWSContactsManager

- (id)initWithPrimaryStorage:(OWSPrimaryStorage *)primaryStorage
{
    self = [super init];
    if (!self) {
        return self;
    }

    _keyValueStore = [[SDSKeyValueStore alloc] initWithCollection:OWSContactsManagerCollection];

    // TODO: We need to configure the limits of this cache.
    _avatarCache = [ImageCache new];

    _dbReadConnection = primaryStorage.newDatabaseConnection;
    _dbWriteConnection = primaryStorage.newDatabaseConnection;
    _accountFinder = [SignalAccountFinder new];

    _allContacts = @[];
    _allContactsMap = @{};
    _signalAccountMap = @{};
    _signalAccounts = @[];
    _systemContactsFetcher = [SystemContactsFetcher new];
    _systemContactsFetcher.delegate = self;
    _cnContactCache = [NSCache new];
    _cnContactCache.countLimit = 50;
    _cnContactAvatarCache = [NSCache new];
    _cnContactAvatarCache.countLimit = 25;

    OWSSingletonAssert();

    [AppReadiness runNowOrWhenAppWillBecomeReady:^{
        [self setup];

        [self startObserving];
    }];

    return self;
}

- (void)setup {
    __block NSMutableArray<SignalAccount *> *signalAccounts;
    [self.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        NSUInteger signalAccountCount = [SignalAccount numberOfKeysInCollectionWithTransaction:transaction];
        OWSLogInfo(@"loading %lu signal accounts from cache.", (unsigned long)signalAccountCount);

        signalAccounts = [[NSMutableArray alloc] initWithCapacity:signalAccountCount];

        [SignalAccount enumerateCollectionObjectsWithTransaction:transaction usingBlock:^(SignalAccount *signalAccount, BOOL * _Nonnull stop) {
            [signalAccounts addObject:signalAccount];
        }];
    }];
    [signalAccounts sortUsingComparator:self.signalAccountComparator];

    [self updateSignalAccounts:signalAccounts];
}

- (dispatch_queue_t)serialQueue
{
    static dispatch_queue_t _serialQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _serialQueue = dispatch_queue_create("org.whispersystems.contacts.buildSignalAccount", DISPATCH_QUEUE_SERIAL);
    });

    return _serialQueue;
}

#pragma mark - System Contact Fetching

// Request contacts access if you haven't asked recently.
- (void)requestSystemContactsOnce
{
    [self requestSystemContactsOnceWithCompletion:nil];
}

- (void)requestSystemContactsOnceWithCompletion:(void (^_Nullable)(NSError *_Nullable error))completion
{
    [self.systemContactsFetcher requestOnceWithCompletion:completion];
}

- (void)fetchSystemContactsOnceIfAlreadyAuthorized
{
    [self.systemContactsFetcher fetchOnceIfAlreadyAuthorized];
}

- (void)userRequestedSystemContactsRefreshWithCompletion:(void (^)(NSError *_Nullable error))completionHandler
{
    [self.systemContactsFetcher userRequestedRefreshWithCompletion:completionHandler];
}

- (BOOL)isSystemContactsAuthorized
{
    return self.systemContactsFetcher.isAuthorized;
}

- (BOOL)isSystemContactsDenied
{
    return self.systemContactsFetcher.isDenied;
}

- (BOOL)systemContactsHaveBeenRequestedAtLeastOnce
{
    return self.systemContactsFetcher.systemContactsHaveBeenRequestedAtLeastOnce;
}

- (BOOL)supportsContactEditing
{
    return self.systemContactsFetcher.supportsContactEditing;
}

#pragma mark - CNContacts

- (nullable CNContact *)cnContactWithId:(nullable NSString *)contactId
{
    OWSAssertDebug(self.cnContactCache);

    if (!contactId) {
        return nil;
    }

    CNContact *_Nullable cnContact;
    @synchronized(self.cnContactCache) {
        cnContact = [self.cnContactCache objectForKey:contactId];
        if (!cnContact) {
            cnContact = [self.systemContactsFetcher fetchCNContactWithContactId:contactId];
            if (cnContact) {
                [self.cnContactCache setObject:cnContact forKey:contactId];
            }
        }
    }

    return cnContact;
}

- (nullable NSData *)avatarDataForCNContactId:(nullable NSString *)contactId
{
    // Don't bother to cache avatar data.
    CNContact *_Nullable cnContact = [self cnContactWithId:contactId];
    return [Contact avatarDataForCNContact:cnContact];
}

- (nullable UIImage *)avatarImageForCNContactId:(nullable NSString *)contactId
{
    OWSAssertDebug(self.cnContactAvatarCache);

    if (!contactId) {
        return nil;
    }

    UIImage *_Nullable avatarImage;
    @synchronized(self.cnContactAvatarCache) {
        avatarImage = [self.cnContactAvatarCache objectForKey:contactId];
        if (!avatarImage) {
            NSData *_Nullable avatarData = [self avatarDataForCNContactId:contactId];
            if (avatarData && [avatarData ows_isValidImage]) {
                avatarImage = [UIImage imageWithData:avatarData];
            }
            if (avatarImage) {
                [self.cnContactAvatarCache setObject:avatarImage forKey:contactId];
            }
        }
    }

    return avatarImage;
}

#pragma mark - SystemContactsFetcherDelegate

- (void)systemContactsFetcher:(SystemContactsFetcher *)systemsContactsFetcher
              updatedContacts:(NSArray<Contact *> *)contacts
                isUserRequested:(BOOL)isUserRequested
{
    BOOL shouldClearStaleCache;
    // On iOS 11.2, only clear the contacts cache if the fetch was initiated by the user.
    // iOS 11.2 rarely returns partial fetches and we use the cache to prevent contacts from
    // periodically disappearing from the UI.
    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(11, 2) && !SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(11, 3)) {
        shouldClearStaleCache = isUserRequested;
    } else {
        shouldClearStaleCache = YES;
    }
    [self updateWithContacts:contacts isUserRequested:isUserRequested shouldClearStaleCache:shouldClearStaleCache];
}

- (void)systemContactsFetcher:(SystemContactsFetcher *)systemContactsFetcher
       hasAuthorizationStatus:(enum ContactStoreAuthorizationStatus)authorizationStatus
{
    if (authorizationStatus == ContactStoreAuthorizationStatusRestricted
        || authorizationStatus == ContactStoreAuthorizationStatusDenied) {
        // Clear the contacts cache if access to the system contacts is revoked.
        [self updateWithContacts:@[] isUserRequested:NO shouldClearStaleCache:YES];
    }
}

#pragma mark - Intersection

- (NSSet<NSString *> *)phoneNumbersForIntersectionWithContacts:(NSArray<Contact *> *)contacts
{
    OWSAssertDebug(contacts);

    NSMutableSet<NSString *> *phoneNumbers = [NSMutableSet set];

    for (Contact *contact in contacts) {
        for (PhoneNumber *phoneNumber in contact.parsedPhoneNumbers) {
            [phoneNumbers addObject:phoneNumber.toE164];
        }
    }

    return phoneNumbers;
}

- (void)intersectContacts:(NSArray<Contact *> *)contacts
          isUserRequested:(BOOL)isUserRequested
               completion:(void (^)(NSError *_Nullable error))completion
{
    OWSAssertDebug(contacts);
    OWSAssertDebug(completion);
    OWSAssertIsOnMainThread();


    dispatch_async(self.serialQueue, ^{
        __block BOOL isFullIntersection = YES;
        __block BOOL isRegularlyScheduledRun = NO;
        __block NSSet<NSString *> *allContactPhoneNumbers;
        __block NSSet<NSString *> *phoneNumbersForIntersection;
        __block NSMutableSet<SignalRecipient *> *existingRegisteredRecipients = [NSMutableSet new];
        [self.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            // Contact updates initiated by the user should always do a full intersection.
            if (!isUserRequested) {
                NSDate *_Nullable nextFullIntersectionDate =
                    [self.keyValueStore getDate:OWSContactsManagerKeyNextFullIntersectionDate
                                    transaction:transaction.asAnyRead];
                if (nextFullIntersectionDate && [nextFullIntersectionDate isAfterNow]) {
                    isFullIntersection = NO;
                } else {
                    isRegularlyScheduledRun = YES;
                }
            }

            [SignalRecipient
                enumerateCollectionObjectsWithTransaction:transaction
                                               usingBlock:^(id _Nonnull object, BOOL *_Nonnull stop) {
                                                   if (![object isKindOfClass:[SignalRecipient class]]) {
                                                       OWSFailDebug(@"unexpected object: %@", object);
                                                       return;
                                                   }
                                                   SignalRecipient *signalRecipient = (SignalRecipient *)object;
                                                   if (signalRecipient.devices.count > 0) {
                                                       [existingRegisteredRecipients addObject:(SignalRecipient *)object];
                                                   }
                                               }];

            allContactPhoneNumbers = [self phoneNumbersForIntersectionWithContacts:contacts];
            phoneNumbersForIntersection = allContactPhoneNumbers;

            if (!isFullIntersection) {
                // Do a "delta" intersection instead of a "full" intersection:
                // only intersect new contacts which were not in the last successful
                // "full" intersection.
                NSSet<NSString *> *_Nullable lastKnownContactPhoneNumbers =
                    [self.keyValueStore getObject:OWSContactsManagerKeyLastKnownContactPhoneNumbers
                                      transaction:transaction.asAnyRead];
                if (lastKnownContactPhoneNumbers) {
                    // Do a "delta" sync which only intersects phone numbers not included
                    // in the last full intersection.
                    NSMutableSet<NSString *> *newPhoneNumbers = [allContactPhoneNumbers mutableCopy];
                    [newPhoneNumbers minusSet:lastKnownContactPhoneNumbers];
                    phoneNumbersForIntersection = newPhoneNumbers;
                } else {
                    // Without a list of "last known" contact phone numbers, we'll have to do a full intersection.
                    isFullIntersection = YES;
                }
            }
        }];
        OWSAssertDebug(phoneNumbersForIntersection);

        if (phoneNumbersForIntersection.count < 1) {
            OWSLogInfo(@"Skipping intersection; no contacts to intersect.");
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                completion(nil);
            });
            return;
        } else if (isFullIntersection) {
            OWSLogInfo(@"Doing full intersection with %zu contacts.", phoneNumbersForIntersection.count);
        } else {
            OWSLogInfo(@"Doing delta intersection with %zu contacts.", phoneNumbersForIntersection.count);
        }

        [self intersectContacts:phoneNumbersForIntersection
            retryDelaySeconds:1.0
            success:^(NSSet<SignalRecipient *> *registeredRecipients) {
                if (isRegularlyScheduledRun) {
                    NSMutableSet<SignalRecipient *> *newSignalRecipients = [registeredRecipients mutableCopy];
                    [newSignalRecipients minusSet:existingRegisteredRecipients];

                    if (newSignalRecipients.count == 0) {
                        OWSLogInfo(@"No new recipients.");
                    } else {
                        __block NSSet<NSString *> *_Nullable lastKnownContactPhoneNumbers;
                        [self.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
                            lastKnownContactPhoneNumbers =
                                [self.keyValueStore getObject:OWSContactsManagerKeyLastKnownContactPhoneNumbers
                                                  transaction:transaction.asAnyRead];
                        }];

                        if (lastKnownContactPhoneNumbers != nil && lastKnownContactPhoneNumbers.count > 0) {
                            [OWSNewAccountDiscovery.shared discoveredNewRecipients:newSignalRecipients];
                        } else {
                            OWSLogInfo(@"skipping new recipient notification for first successful contact sync.");
                        }
                    }
                }

                [self markIntersectionAsComplete:allContactPhoneNumbers isFullIntersection:isFullIntersection];

                completion(nil);
            }
            failure:^(NSError *error) {
                completion(error);
            }];
    });
}

- (void)markIntersectionAsComplete:(NSSet<NSString *> *)phoneNumbersForIntersection
                isFullIntersection:(BOOL)isFullIntersection
{
    OWSAssertDebug(phoneNumbersForIntersection.count > 0);

    dispatch_async(self.serialQueue, ^{
        [self.dbWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            [self.keyValueStore setObject:phoneNumbersForIntersection
                                      key:OWSContactsManagerKeyLastKnownContactPhoneNumbers
                              transaction:transaction.asAnyWrite];

            if (isFullIntersection) {
                // Don't do a full intersection more often than once every 6 hours.
                const NSTimeInterval kMinFullIntersectionInterval = 6 * kHourInterval;
                NSDate *nextFullIntersectionDate = [NSDate
                    dateWithTimeIntervalSince1970:[NSDate new].timeIntervalSince1970 + kMinFullIntersectionInterval];
                [self.keyValueStore setDate:nextFullIntersectionDate
                                        key:OWSContactsManagerKeyNextFullIntersectionDate
                                transaction:transaction.asAnyWrite];
            }
        }];
    });
}

- (void)intersectContacts:(NSSet<NSString *> *)phoneNumbers
        retryDelaySeconds:(double)retryDelaySeconds
                  success:(void (^)(NSSet<SignalRecipient *> *))successParameter
                  failure:(void (^)(NSError *))failureParameter
{
    OWSAssertDebug(phoneNumbers.count > 0);
    OWSAssertDebug(retryDelaySeconds > 0);
    OWSAssertDebug(successParameter);
    OWSAssertDebug(failureParameter);

    void (^success)(NSArray<SignalRecipient *> *) = ^(NSArray<SignalRecipient *> *registeredRecipients) {
        OWSLogInfo(@"Successfully intersected contacts.");
        successParameter([NSSet setWithArray:registeredRecipients]);
    };
    void (^failure)(NSError *) = ^(NSError *error) {
        if ([error.domain isEqualToString:OWSSignalServiceKitErrorDomain]
            && error.code == OWSErrorCodeContactsUpdaterRateLimit) {
            OWSLogError(@"Contact intersection hit rate limit with error: %@", error);
            failureParameter(error);
            return;
        }

        OWSLogWarn(@"Failed to intersect contacts with error: %@. Rescheduling", error);

        // Retry with exponential backoff.
        //
        // TODO: Abort if another contact intersection succeeds in the meantime.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retryDelaySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self intersectContacts:phoneNumbers
                      retryDelaySeconds:retryDelaySeconds * 2.0
                                success:successParameter
                                failure:failureParameter];
            });
    };
    [[ContactsUpdater sharedUpdater] lookupIdentifiers:phoneNumbers.allObjects success:success failure:failure];
}

- (void)startObserving
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(otherUsersProfileWillChange:)
                                                 name:kNSNotificationName_OtherUsersProfileWillChange
                                               object:nil];
}

- (void)otherUsersProfileWillChange:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();

    [AppReadiness runNowOrWhenAppDidBecomeReady:^{
        NSString *recipientId = notification.userInfo[kNSNotificationKey_ProfileRecipientId];
        OWSAssertDebug(recipientId.length > 0);

        [self.avatarCache removeAllImagesForKey:recipientId];
    }];
}

- (void)updateWithContacts:(NSArray<Contact *> *)contacts
           isUserRequested:(BOOL)isUserRequested
     shouldClearStaleCache:(BOOL)shouldClearStaleCache
{
    dispatch_async(self.serialQueue, ^{
        NSMutableDictionary<NSString *, Contact *> *allContactsMap = [NSMutableDictionary new];
        for (Contact *contact in contacts) {
            for (PhoneNumber *phoneNumber in contact.parsedPhoneNumbers) {
                NSString *phoneNumberE164 = phoneNumber.toE164;
                if (phoneNumberE164.length > 0) {
                    allContactsMap[phoneNumberE164] = contact;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.allContacts = contacts;
            self.allContactsMap = [allContactsMap copy];
            [self.cnContactCache removeAllObjects];
            [self.cnContactAvatarCache removeAllObjects];

            [self.avatarCache removeAllImages];

            [self intersectContacts:contacts
                    isUserRequested:isUserRequested
                         completion:^(NSError *_Nullable error) {
                             // TODO: Should we do this on error?
                             [self buildSignalAccountsAndClearStaleCache:shouldClearStaleCache];
                         }];
        });
    });
}

- (void)buildSignalAccountsAndClearStaleCache:(BOOL)shouldClearStaleCache
{
    dispatch_async(self.serialQueue, ^{
        NSMutableArray<SignalAccount *> *signalAccounts = [NSMutableArray new];
        NSArray<Contact *> *contacts = self.allContacts;

        // We use a transaction only to load the SignalRecipients for each contact,
        // in order to avoid database deadlock.
        NSMutableDictionary<NSString *, NSArray<SignalRecipient *> *> *contactIdToSignalRecipientsMap =
            [NSMutableDictionary new];
        [self.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            for (Contact *contact in contacts) {
                NSArray<SignalRecipient *> *signalRecipients = [contact signalRecipientsWithTransaction:transaction];
                contactIdToSignalRecipientsMap[contact.uniqueId] = signalRecipients;
            }
        }];

        NSMutableSet<NSString *> *seenPhoneNumbers = [NSMutableSet new];
        for (Contact *contact in contacts) {
            NSArray<SignalRecipient *> *signalRecipients = contactIdToSignalRecipientsMap[contact.uniqueId];
            for (SignalRecipient *signalRecipient in [signalRecipients sortedArrayUsingSelector:@selector((compare:))]) {
                if ([seenPhoneNumbers containsObject:signalRecipient.recipientId]) {
                    OWSLogDebug(@"Ignoring duplicate contact: %@, %@", signalRecipient.recipientId, contact.fullName);
                    continue;
                }
                [seenPhoneNumbers addObject:signalRecipient.recipientId];

                SignalAccount *signalAccount = [[SignalAccount alloc] initWithSignalRecipient:signalRecipient];
                signalAccount.contact = contact;
                if (signalRecipients.count > 1) {
                    signalAccount.hasMultipleAccountContact = YES;
                    signalAccount.multipleAccountLabelText =
                        [[self class] accountLabelForContact:contact phoneNumber:signalRecipient.recipientId];
                }
                [signalAccounts addObject:signalAccount];
            }
        }

        NSMutableDictionary<NSString *, SignalAccount *> *oldSignalAccounts = [NSMutableDictionary new];
        [self.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            [SignalAccount
                enumerateCollectionObjectsWithTransaction:transaction
                                               usingBlock:^(id _Nonnull object, BOOL *_Nonnull stop) {
                                                   OWSAssertDebug([object isKindOfClass:[SignalAccount class]]);
                                                   SignalAccount *oldSignalAccount = (SignalAccount *)object;

                                                   oldSignalAccounts[oldSignalAccount.uniqueId] = oldSignalAccount;
                                               }];
        }];

        NSMutableArray *accountsToSave = [NSMutableArray new];
        for (SignalAccount *signalAccount in signalAccounts) {
            SignalAccount *_Nullable oldSignalAccount = oldSignalAccounts[signalAccount.uniqueId];

            // keep track of which accounts are still relevant, so we can clean up orphans
            [oldSignalAccounts removeObjectForKey:signalAccount.uniqueId];

            if (oldSignalAccount == nil) {
                // new Signal Account
                [accountsToSave addObject:signalAccount];
                continue;
            }

            if ([oldSignalAccount isEqual:signalAccount]) {
                // Same value, no need to save.
                continue;
            }

            // value changed, save account
            [accountsToSave addObject:signalAccount];
        }

        // Update cached SignalAccounts on disk
        [self.dbWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            OWSLogInfo(@"Saving %lu SignalAccounts", (unsigned long)accountsToSave.count);
            for (SignalAccount *signalAccount in accountsToSave) {
                OWSLogVerbose(@"Saving SignalAccount: %@", signalAccount);
                [signalAccount saveWithTransaction:transaction];
            }

            if (shouldClearStaleCache) {
                OWSLogInfo(@"Removing %lu old SignalAccounts.", (unsigned long)oldSignalAccounts.count);
                for (SignalAccount *signalAccount in oldSignalAccounts.allValues) {
                    OWSLogVerbose(@"Removing old SignalAccount: %@", signalAccount);
                    [signalAccount removeWithTransaction:transaction];
                }
            } else {
                // In theory we want to remove SignalAccounts if the user deletes the corresponding system contact.
                // However, as of iOS11.2 CNContactStore occasionally gives us only a subset of the system contacts.
                // Because of that, it's not safe to clear orphaned accounts.
                // Because we still want to give users a way to clear their stale accounts, if they pull-to-refresh
                // their contacts we'll clear the cached ones.
                // RADAR: https://bugreport.apple.com/web/?problemID=36082946
                if (oldSignalAccounts.allValues.count > 0) {
                    OWSLogWarn(@"NOT Removing %lu old SignalAccounts.", (unsigned long)oldSignalAccounts.count);
                    for (SignalAccount *signalAccount in oldSignalAccounts.allValues) {
                        OWSLogVerbose(@"Ensuring old SignalAccount is not inadvertently lost: %@", signalAccount);
                        [signalAccounts addObject:signalAccount];
                    }

                    // re-sort signal accounts since we've appended some orphans
                    [signalAccounts sortUsingComparator:self.signalAccountComparator];
                }
            }
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateSignalAccounts:signalAccounts];
        });
    });
}

- (void)updateSignalAccounts:(NSArray<SignalAccount *> *)signalAccounts
{
    OWSAssertIsOnMainThread();

    if ([signalAccounts isEqual:self.signalAccounts]) {
        OWSLogDebug(@"SignalAccounts unchanged.");
        return;
    }

    NSMutableDictionary<NSString *, SignalAccount *> *signalAccountMap = [NSMutableDictionary new];
    NSMutableArray<NSString *> *transitional_phoneNumbers = [NSMutableArray array];
    for (SignalAccount *signalAccount in signalAccounts) {
        if (signalAccount.recipientPhoneNumber) {
            signalAccountMap[signalAccount.recipientPhoneNumber] = signalAccount;
            [transitional_phoneNumbers addObject:signalAccount.recipientPhoneNumber];
        }
        if (signalAccount.recipientUUID) {
            signalAccountMap[signalAccount.recipientUUID] = signalAccount;
        }
    }

    self.signalAccountMap = [signalAccountMap copy];
    self.signalAccounts = [signalAccounts copy];
    [self.profileManager setContactRecipientIds:transitional_phoneNumbers];

    self.isSetup = YES;

    [[NSNotificationCenter defaultCenter]
        postNotificationNameAsync:OWSContactsManagerSignalAccountsDidChangeNotification
                           object:nil];
}

// TODO dependency inject, avoid circular dependencies.
- (OWSProfileManager *)profileManager
{
    return [OWSProfileManager sharedManager];
}

- (nullable NSString *)cachedContactNameForSignalServiceAddress:(SignalServiceAddress *)address
{
    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForSignalServiceAddress:address];
    return [self cachedContactNameForSignalServiceAddress:address signalAccount:signalAccount];
}

- (nullable NSString *)cachedContactNameForSignalServiceAddress:(SignalServiceAddress *)address
                                                    transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(address);
    OWSAssertDebug(transaction);

    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForSignalServiceAddress:address
                                                                                 transaction:transaction];
    return [self cachedContactNameForSignalServiceAddress:address signalAccount:signalAccount];
}

- (nullable NSString *)cachedContactNameForSignalServiceAddress:(SignalServiceAddress *)address
                                                  signalAccount:(nullable SignalAccount *)signalAccount
{
    OWSAssertDebug(address);

    if (!signalAccount) {
        // search system contacts for no-longer-registered signal users, for which there will be no SignalAccount
        NSString *_Nullable phoneNumber = [self phoneNumberForSignalServiceAddress:address];
        Contact *_Nullable nonSignalContact = self.allContactsMap[phoneNumber];
        if (!nonSignalContact) {
            return nil;
        }
        return nonSignalContact.fullName;
    }

    NSString *fullName = signalAccount.contactFullName;
    if (fullName.length == 0) {
        return nil;
    }

    NSString *multipleAccountLabelText = signalAccount.multipleAccountLabelText;
    if (multipleAccountLabelText.length == 0) {
        return fullName;
    }

    return [NSString stringWithFormat:@"%@ (%@)", fullName, multipleAccountLabelText];
}

- (nullable NSString *)cachedFirstNameForSignalServiceAddress:(SignalServiceAddress *)address
{
    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForSignalServiceAddress:address];
    return signalAccount.contact.firstName.filterStringForDisplay;
}

- (nullable NSString *)cachedLastNameForSignalServiceAddress:(SignalServiceAddress *)address
{
    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForSignalServiceAddress:address];
    return signalAccount.contact.lastName.filterStringForDisplay;
}

- (nullable NSString *)phoneNumberForSignalServiceAddress:(SignalServiceAddress *)address
{
    if (address.isPhoneNumber) {
        return address.stringIdentifier;
    }

    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForSignalServiceAddress:address];
    return signalAccount.recipientPhoneNumber;
}

#pragma mark - View Helpers

// TODO move into Contact class.
+ (NSString *)accountLabelForContact:(Contact *)contact phoneNumber:(NSString *)phoneNumber
{
    OWSAssertDebug(contact);
    OWSAssertDebug(phoneNumber.length > 0);
    OWSAssertDebug([contact.textSecureIdentifiers containsObject:phoneNumber]);

    if (contact.textSecureIdentifiers.count <= 1) {
        return nil;
    }

    // 1. Find the phone number type of this account.
    NSString *phoneNumberLabel = [contact nameForPhoneNumber:phoneNumber];

    // 2. Find all phone numbers for this contact of the same type.
    NSMutableArray *phoneNumbersWithTheSameName = [NSMutableArray new];
    for (NSString *textSecureIdentifier in contact.textSecureIdentifiers) {
        if ([phoneNumberLabel isEqualToString:[contact nameForPhoneNumber:textSecureIdentifier]]) {
            [phoneNumbersWithTheSameName addObject:textSecureIdentifier];
        }
    }

    OWSAssertDebug([phoneNumbersWithTheSameName containsObject:phoneNumber]);
    if (phoneNumbersWithTheSameName.count > 1) {
        NSUInteger index =
            [[phoneNumbersWithTheSameName sortedArrayUsingSelector:@selector((compare:))] indexOfObject:phoneNumber];
        NSString *indexText = [OWSFormat formatInt:(int)index + 1];
        phoneNumberLabel =
            [NSString stringWithFormat:NSLocalizedString(@"PHONE_NUMBER_TYPE_AND_INDEX_NAME_FORMAT",
                                           @"Format for phone number label with an index. Embeds {{Phone number label "
                                           @"(e.g. 'home')}} and {{index, e.g. 2}}."),
                      phoneNumberLabel,
                      indexText];
    }

    return phoneNumberLabel.filterStringForDisplay;
}

- (BOOL)phoneNumber:(PhoneNumber *)phoneNumber1 matchesNumber:(PhoneNumber *)phoneNumber2
{
    return [phoneNumber1.toE164 isEqualToString:phoneNumber2.toE164];
}

#pragma mark - Whisper User Management

- (BOOL)isSystemContact:(NSString *)phoneNumber
{
    OWSAssertDebug(phoneNumber.length > 0);

    return self.allContactsMap[phoneNumber] != nil;
}

- (BOOL)isSystemContactWithSignalAccount:(NSString *)phoneNumber
{
    OWSAssertDebug(phoneNumber.length > 0);

    return
        [self hasSignalAccountForSignalServiceAddress:[[SignalServiceAddress alloc] initWithPhoneNumber:phoneNumber]];
}

- (BOOL)hasNameInSystemContactsForSignalServiceAddress:(SignalServiceAddress *)address
{
    return [self cachedContactNameForSignalServiceAddress:address].length > 0;
}

- (NSString *)unknownContactName
{
    return NSLocalizedString(
        @"UNKNOWN_CONTACT_NAME", @"Displayed if for some reason we can't determine a contacts phone number *or* name");
}

- (nullable NSString *)formattedProfileNameForSignalServiceAddress:(SignalServiceAddress *)address
{
    NSString *_Nullable profileName = [self.profileManager profileNameForRecipientId:address.transitional_phoneNumber];
    if (profileName.length == 0) {
        return nil;
    }

    NSString *profileNameFormatString = NSLocalizedString(@"PROFILE_NAME_LABEL_FORMAT",
        @"Prepend a simple marker to differentiate the profile name, embeds the contact's {{profile name}}.");

    return [NSString stringWithFormat:profileNameFormatString, profileName];
}

- (nullable NSString *)profileNameForSignalServiceAddress:(SignalServiceAddress *)address
{
    return [self.profileManager profileNameForRecipientId:address.transitional_phoneNumber];
}

- (nullable NSString *)nameFromSystemContactsForSignalServiceAddress:(SignalServiceAddress *)address
{
    return [self cachedContactNameForSignalServiceAddress:address];
}

- (nullable NSString *)nameFromSystemContactsForSignalServiceAddress:(SignalServiceAddress *)address
                                                         transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(transaction);

    return [self cachedContactNameForSignalServiceAddress:address transaction:transaction];
}

- (NSString *)displayNameForSignalServiceAddress:(nullable SignalServiceAddress *)address
{
    OWSAssertDebug(address);

    if (address == nil) {
        return self.unknownContactName;
    }

    NSString *_Nullable displayName = [self nameFromSystemContactsForSignalServiceAddress:address];

    if (displayName.length < 1) {
        NSString *_Nullable phoneNumber = [self phoneNumberForSignalServiceAddress:address];
        displayName = phoneNumber ?: address.stringIdentifier;
    }

    return displayName;
}

- (NSString *)displayNameForSignalServiceAddress:(nullable SignalServiceAddress *)address
                                     transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(transaction);

    if (address == nil) {
        return self.unknownContactName;
    }

    NSString *_Nullable displayName = [self nameFromSystemContactsForSignalServiceAddress:address
                                                                              transaction:transaction];

    if (displayName.length < 1) {
        NSString *_Nullable phoneNumber = [self phoneNumberForSignalServiceAddress:address];
        displayName = phoneNumber ?: address.stringIdentifier;
    }

    return displayName;
}

- (NSString *_Nonnull)displayNameForSignalAccount:(SignalAccount *)signalAccount
{
    OWSAssertDebug(signalAccount);

    return [self displayNameForSignalServiceAddress:signalAccount.recipientAddress];
}

- (NSAttributedString *_Nonnull)formattedDisplayNameForSignalAccount:(SignalAccount *)signalAccount font:(UIFont *)font
{
    OWSAssertDebug(signalAccount);
    OWSAssertDebug(font);

    return [self formattedFullNameForSignalServiceAddress:signalAccount.recipientAddress font:font];
}

- (NSAttributedString *)formattedFullNameForSignalServiceAddress:(SignalServiceAddress *)address font:(UIFont *)font
{
    OWSAssertDebug(address);
    OWSAssertDebug(font);

    UIFont *boldFont = [UIFont ows_mediumFontWithSize:font.pointSize];

    NSDictionary<NSString *, id> *boldFontAttributes =
        @{ NSFontAttributeName : boldFont, NSForegroundColorAttributeName : [Theme boldColor] };
    NSDictionary<NSString *, id> *normalFontAttributes =
        @{ NSFontAttributeName : font, NSForegroundColorAttributeName : [Theme primaryColor] };
    NSDictionary<NSString *, id> *firstNameAttributes
        = (self.shouldSortByGivenName ? boldFontAttributes : normalFontAttributes);
    NSDictionary<NSString *, id> *lastNameAttributes
        = (self.shouldSortByGivenName ? normalFontAttributes : boldFontAttributes);

    NSString *cachedFirstName = [self cachedFirstNameForSignalServiceAddress:address];
    NSString *cachedLastName = [self cachedLastNameForSignalServiceAddress:address];
    NSString *_Nullable phoneNumber = [self phoneNumberForSignalServiceAddress:address];

    NSMutableAttributedString *formattedName = [NSMutableAttributedString new];

    if (cachedFirstName.length > 0 && cachedLastName.length > 0) {
        NSAttributedString *firstName =
            [[NSAttributedString alloc] initWithString:cachedFirstName attributes:firstNameAttributes];
        NSAttributedString *lastName =
            [[NSAttributedString alloc] initWithString:cachedLastName attributes:lastNameAttributes];

        NSString *_Nullable cnContactId = self.allContactsMap[phoneNumber].cnContactId;
        CNContact *_Nullable cnContact = [self cnContactWithId:cnContactId];
        if (!cnContact) {
            // If we don't have a CNContact for this recipient id, make one.
            // Presumably [CNContactFormatter nameOrderForContact:] tries
            // to localizes its result based on the languages/scripts used
            // in the contact's fields.
            CNMutableContact *formatContact = [CNMutableContact new];
            formatContact.givenName = firstName.string;
            formatContact.familyName = lastName.string;
            cnContact = formatContact;
        }
        CNContactDisplayNameOrder nameOrder = [CNContactFormatter nameOrderForContact:cnContact];
        NSAttributedString *_Nullable leftName, *_Nullable rightName;
        if (nameOrder == CNContactDisplayNameOrderGivenNameFirst) {
            leftName = firstName;
            rightName = lastName;
        } else {
            leftName = lastName;
            rightName = firstName;
        }

        [formattedName appendAttributedString:leftName];
        [formattedName
            appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:normalFontAttributes]];
        [formattedName appendAttributedString:rightName];
    } else if (cachedFirstName.length > 0) {
        [formattedName appendAttributedString:[[NSAttributedString alloc] initWithString:cachedFirstName
                                                                              attributes:firstNameAttributes]];
    } else if (cachedLastName.length > 0) {
        [formattedName appendAttributedString:[[NSAttributedString alloc] initWithString:cachedLastName
                                                                              attributes:lastNameAttributes]];
    } else if (phoneNumber) {
        // Fallback to just their phone number, if we know it
        NSString *phoneString =
            [PhoneNumber bestEffortFormatPartialUserSpecifiedTextToLookLikeAPhoneNumber:phoneNumber];
        return [[NSAttributedString alloc] initWithString:phoneString attributes:normalFontAttributes];

    } else {
        // Otherwise, fallback to their uuid
        return [[NSAttributedString alloc] initWithString:address.stringIdentifier attributes:normalFontAttributes];
    }

    // Append unique label for contacts with multiple Signal accounts
    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForSignalServiceAddress:address];
    if (signalAccount && signalAccount.multipleAccountLabelText) {
        OWSAssertDebug(signalAccount.multipleAccountLabelText.length > 0);

        [formattedName
            appendAttributedString:[[NSAttributedString alloc] initWithString:@" (" attributes:normalFontAttributes]];
        [formattedName
            appendAttributedString:[[NSAttributedString alloc] initWithString:signalAccount.multipleAccountLabelText
                                                                   attributes:normalFontAttributes]];
        [formattedName
            appendAttributedString:[[NSAttributedString alloc] initWithString:@")" attributes:normalFontAttributes]];
    }

    return formattedName;
}

- (NSString *)contactOrProfileNameForSignalServiceAddress:(SignalServiceAddress *)address
{
    // Prefer a saved name from system contacts, if available
    NSString *_Nullable savedContactName = [self cachedContactNameForSignalServiceAddress:address];
    if (savedContactName.length > 0) {
        return savedContactName;
    }

    NSString *_Nullable phoneNumber = [self phoneNumberForSignalServiceAddress:address];
    if (phoneNumber) {
        phoneNumber = [PhoneNumber bestEffortFormatPartialUserSpecifiedTextToLookLikeAPhoneNumber:phoneNumber];
    }

    NSString *_Nullable profileName = [self.profileManager profileNameForRecipientId:address.transitional_phoneNumber];

    if (profileName.length > 0) {
        NSString *numberAndProfileNameFormat = NSLocalizedString(@"PROFILE_NAME_AND_PHONE_NUMBER_LABEL_FORMAT",
            @"Label text combining the phone number and profile name separated by a simple demarcation character. "
            @"Phone number should be most prominent. '%1$@' is replaced with {{phone number}} and '%2$@' is replaced "
            @"with {{profile name}}");

        NSString *numberAndProfileName = [NSString
            stringWithFormat:numberAndProfileNameFormat, phoneNumber ?: address.stringIdentifier, profileName];
        return numberAndProfileName;
    }

    // else fall back to phone number or UUID
    return phoneNumber ?: address.stringIdentifier;
}

- (NSAttributedString *)attributedContactOrProfileNameForSignalServiceAddress:(SignalServiceAddress *)address
{
    return [[NSAttributedString alloc] initWithString:[self contactOrProfileNameForSignalServiceAddress:address]];
}

- (NSAttributedString *)attributedContactOrProfileNameForSignalServiceAddress:(SignalServiceAddress *)address
                                                                  primaryFont:(UIFont *)primaryFont
                                                                secondaryFont:(UIFont *)secondaryFont
{
    OWSAssertDebug(primaryFont);
    OWSAssertDebug(secondaryFont);

    return [self attributedContactOrProfileNameForSignalServiceAddress:(SignalServiceAddress *)address
                                                     primaryAttributes:@{
                                                         NSFontAttributeName : primaryFont,
                                                     }
                                                   secondaryAttributes:@{
                                                       NSFontAttributeName : secondaryFont,
                                                   }];
}

- (NSAttributedString *)attributedContactOrProfileNameForSignalServiceAddress:(SignalServiceAddress *)address
                                                            primaryAttributes:(NSDictionary *)primaryAttributes
                                                          secondaryAttributes:(NSDictionary *)secondaryAttributes
{
    OWSAssertDebug(primaryAttributes.count > 0);
    OWSAssertDebug(secondaryAttributes.count > 0);

    // Prefer a saved name from system contacts, if available
    NSString *_Nullable savedContactName = [self cachedContactNameForSignalServiceAddress:address];
    if (savedContactName.length > 0) {
        return [[NSAttributedString alloc] initWithString:savedContactName attributes:primaryAttributes];
    }

    NSString *_Nullable phoneNumber = [self phoneNumberForSignalServiceAddress:address];
    NSString *_Nullable profileName = [self.profileManager profileNameForRecipientId:address.transitional_phoneNumber];
    if (profileName.length > 0) {
        NSAttributedString *result = [[NSAttributedString alloc] initWithString:phoneNumber ?: address.stringIdentifier
                                                                     attributes:primaryAttributes];
        result = [result rtlSafeAppend:[[NSAttributedString alloc] initWithString:@" "]];
        result = [result rtlSafeAppend:[[NSAttributedString alloc] initWithString:@"~" attributes:secondaryAttributes]];
        result = [result
            rtlSafeAppend:[[NSAttributedString alloc] initWithString:profileName attributes:secondaryAttributes]];
        return [result copy];
    }

    // else fall back to phone number or UUID
    return [[NSAttributedString alloc] initWithString:phoneNumber ?: address.stringIdentifier
                                           attributes:primaryAttributes];
}

- (nullable SignalAccount *)fetchSignalAccountForSignalServiceAddress:(SignalServiceAddress *)address
{
    OWSAssertDebug(address);

    __block SignalAccount *signalAccount = self.signalAccountMap[address.stringIdentifier];

    // If contact intersection hasn't completed, it might exist on disk
    // even if it doesn't exist in memory yet.
    if (!signalAccount) {
        [self.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
            signalAccount = [self.accountFinder signalAccountForAddress:address withTransaction:transaction];
        }];
    }

    return signalAccount;
}

- (nullable SignalAccount *)fetchSignalAccountForSignalServiceAddress:(SignalServiceAddress *)address
                                                          transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(address);
    OWSAssertDebug(transaction);

    __block SignalAccount *signalAccount = self.signalAccountMap[address.stringIdentifier];

    // If contact intersection hasn't completed, it might exist on disk
    // even if it doesn't exist in memory yet.
    if (!signalAccount) {
        signalAccount = [self.accountFinder signalAccountForAddress:address withTransaction:transaction];
    }

    return signalAccount;
}

- (SignalAccount *)fetchOrBuildSignalAccountForSignalServiceAddress:(SignalServiceAddress *)address
{
    OWSAssertDebug(address);

    SignalAccount *_Nullable signalAccount = [self fetchSignalAccountForSignalServiceAddress:address];
    return (signalAccount ?: [[SignalAccount alloc] initWithSignalServiceAddress:address]);
}

- (BOOL)hasSignalAccountForSignalServiceAddress:(SignalServiceAddress *)address
{
    return [self fetchSignalAccountForSignalServiceAddress:address] != nil;
}

- (nullable UIImage *)systemContactImageForSignalServiceAddress:(nullable SignalServiceAddress *)address
{
    if (address == nil) {
        return nil;
    }

    NSString *_Nullable phoneNumber = [self phoneNumberForSignalServiceAddress:address];
    Contact *_Nullable contact = self.allContactsMap[phoneNumber];

    if (!contact) {
        // If we haven't loaded system contacts yet, we may have a cached
        // copy in the db
        SignalAccount *_Nullable account = [self fetchSignalAccountForSignalServiceAddress:address];
        contact = account.contact;
    }

    return [self avatarImageForCNContactId:contact.cnContactId];
}

- (nullable UIImage *)profileImageForSignalServiceAddress:(nullable SignalServiceAddress *)address
{
    if (address == nil) {
        return nil;
    }

    return [self.profileManager profileAvatarForRecipientId:address.transitional_phoneNumber];
}

- (nullable NSData *)profileImageDataForSignalServiceAddress:(nullable SignalServiceAddress *)address
{
    if (address == nil) {
        return nil;
    }

    return [self.profileManager profileAvatarDataForRecipientId:address.transitional_phoneNumber];
}

- (nullable UIImage *)imageForSignalServiceAddress:(nullable SignalServiceAddress *)address
{
    if (address == nil) {
        return nil;
    }

    // Prefer the contact image from the local address book if available
    UIImage *_Nullable image = [self systemContactImageForSignalServiceAddress:address];

    // Else try to use the image from their profile
    if (image == nil) {
        image = [self profileImageForSignalServiceAddress:address];
    }

    return image;
}

- (NSComparisonResult)compareSignalAccount:(SignalAccount *)left withSignalAccount:(SignalAccount *)right
{
    return self.signalAccountComparator(left, right);
}

- (NSComparisonResult (^)(SignalAccount *left, SignalAccount *right))signalAccountComparator
{
    return ^NSComparisonResult(SignalAccount *left, SignalAccount *right) {
        NSString *leftName = [self comparableNameForSignalAccount:left];
        NSString *rightName = [self comparableNameForSignalAccount:right];

        NSComparisonResult nameComparison = [leftName caseInsensitiveCompare:rightName];
        if (nameComparison == NSOrderedSame) {
            return [left.recipientAddress.stringIdentifier compare:right.recipientAddress.stringIdentifier];
        }

        return nameComparison;
    };
}

- (BOOL)shouldSortByGivenName
{
    return [[CNContactsUserDefaults sharedDefaults] sortOrder] == CNContactSortOrderGivenName;
}

- (NSString *)comparableNameForSignalAccount:(SignalAccount *)signalAccount
{
    NSString *_Nullable name;
    if (signalAccount.contact) {
        if (self.shouldSortByGivenName) {
            name = signalAccount.contact.comparableNameFirstLast;
        } else {
            name = signalAccount.contact.comparableNameLastFirst;
        }
    }

    if (name.length < 1) {
        name = signalAccount.recipientAddress.stringIdentifier;
    }

    return name;
}

NS_ASSUME_NONNULL_END

@end
