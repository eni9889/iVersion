//
//  iVersion.m
//
//  Version 1.9.1
//
//  Created by Nick Lockwood on 26/01/2011.
//  Copyright 2011 Charcoal Design
//
//  Distributed under the permissive zlib license
//  Get the latest version from either of these locations:
//
//  http://charcoaldesign.co.uk/source/cocoa#iversion
//  https://github.com/nicklockwood/iVersion
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//  claim that you wrote the original software. If you use this software
//  in a product, an acknowledgment in the product documentation would be
//  appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//  misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "iVersion.h"


static NSString *const iVersionLastVersionKey = @"iVersionLastVersionChecked";
static NSString *const iVersionIgnoreVersionKey = @"iVersionIgnoreVersion";
static NSString *const iVersionLastCheckedKey = @"iVersionLastChecked";
static NSString *const iVersionLastRemindedKey = @"iVersionLastReminded";

static NSString *const iVersionMacAppStoreBundleID = @"com.apple.appstore";
static NSString *const iVersionAppLookupURLFormat = @"http://itunes.apple.com/lookup?country=%@&lang=%@";

//note, these aren't ideal as they link to the app page, not the update page
//there may be some way to link directly to the app store updates tab, but I don't know what it is
static NSString *const iVersioniOSAppStoreURLFormat = @"itms-apps://itunes.apple.com/app/id%i";
static NSString *const iVersionMacAppStoreURLFormat = @"macappstore://itunes.apple.com/app/id%i";


#define SECONDS_IN_A_DAY 86400.0
#define MAC_APP_STORE_REFRESH_DELAY 5.0


@implementation NSString(iVersion)

- (NSComparisonResult)compareVersion:(NSString *)version
{
    return [self compare:version options:NSNumericSearch];
}

- (NSComparisonResult)compareVersionDescending:(NSString *)version
{
    switch ([self compareVersion:version])
    {
        case NSOrderedAscending:
        {
            return NSOrderedDescending;
        }
        case NSOrderedDescending:
        {
            return NSOrderedAscending;
        }
        default:
        {
            return NSOrderedSame;
        }
    }
}

@end


#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
@interface iVersion () <UIAlertViewDelegate>
#else
@interface iVersion ()
#endif

@property (nonatomic, copy) NSDictionary *remoteVersionsDict;
@property (nonatomic, strong) NSError *downloadError;
@property (nonatomic, copy) NSString *versionDetails;
@property (nonatomic, strong) id visibleLocalAlert;
@property (nonatomic, strong) id visibleRemoteAlert;

@end


@implementation iVersion

@synthesize remoteVersionsDict;
@synthesize downloadError;
@synthesize appStoreID;
@synthesize remoteVersionsPlistURL;
@synthesize localVersionsPlistPath;
@synthesize applicationName;
@synthesize applicationVersion;
@synthesize applicationBundleID;
@synthesize appStoreLanguage;
@synthesize appStoreCountry;
@synthesize showOnFirstLaunch;
@synthesize groupNotesByVersion;
@synthesize checkPeriod;
@synthesize remindPeriod;
@synthesize inThisVersionTitle;
@synthesize updateAvailableTitle;
@synthesize versionLabelFormat;
@synthesize okButtonLabel;
@synthesize ignoreButtonLabel;
@synthesize remindButtonLabel;
@synthesize downloadButtonLabel;
@synthesize checkAtLaunch;
@synthesize debug;
@synthesize updateURL;
@synthesize versionDetails;
@synthesize delegate;
@synthesize visibleLocalAlert;
@synthesize visibleRemoteAlert;


#pragma mark -
#pragma mark Lifecycle methods

+ (void)load
{
    @autoreleasepool
    {
        //initialise iVersion
        [iVersion sharedInstance];
    }
}

+ (iVersion *)sharedInstance
{
    static iVersion *sharedInstance = nil;
    if (sharedInstance == nil)
    {
        sharedInstance = [[iVersion alloc] init];
    }
    return sharedInstance;
}

- (NSString *)localizedStringForKey:(NSString *)key
{
    static NSBundle *bundle = nil;
    if (bundle == nil)
    {
        //get localisation bundle
        NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"iVersion" ofType:@"bundle"];
        bundle = [NSBundle bundleWithPath:bundlePath] ?: [NSBundle mainBundle];
        
        //get correct lproj folder as this doesn't always happen automatically
        for (NSString *language in [NSLocale preferredLanguages])
        {
            if ([[bundle localizations] containsObject:language])
            {
                bundlePath = [bundle pathForResource:language ofType:@"lproj"];
                bundle = [NSBundle bundleWithPath:bundlePath];
                break;
            }
        }
        
        //retain bundle
        bundle = AH_RETAIN(bundle);
    }
    
    //return localised string
    return [bundle localizedStringForKey:key value:nil table:nil];
}

- (iVersion *)init
{
    if ((self = [super init]))
    {
        
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
        
        //register for iphone application events
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationLaunched:)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
        
        if (&UIApplicationWillEnterForegroundNotification)
        {
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(applicationWillEnterForeground:)
                                                         name:UIApplicationWillEnterForegroundNotification
                                                       object:nil];
        }
#else
        //register for mac application events
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationLaunched:)
                                                     name:NSApplicationDidFinishLaunchingNotification
                                                   object:nil];
#endif
        
        //get language and country
        self.appStoreLanguage = [[NSLocale currentLocale] localeIdentifier];
        self.appStoreCountry = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
        
        //application version (use short version preferentially)
        self.applicationVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if ([applicationVersion length] == 0)
        {
            self.applicationVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey];
        }
        
        //localised application name
        self.applicationName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        if ([applicationName length] == 0)
        {
            self.applicationName = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleNameKey];
        }
        
        //bundle id
        self.applicationBundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        //default settings
        checkAtLaunch = YES;
        showOnFirstLaunch = NO;
        groupNotesByVersion = YES;
        checkPeriod = 0.0f;
        remindPeriod = 1.0f;
        
        //default message text, don't edit these here; if you want to provide your
        //own message text then configure them using the setters/getters
        self.inThisVersionTitle = [self localizedStringForKey:@"New in this version"];
        self.updateAvailableTitle = nil; //set lazily so that appname can be included
        self.versionLabelFormat = [self localizedStringForKey:@"Version %@"];
        self.okButtonLabel = [self localizedStringForKey:@"OK"];
        self.ignoreButtonLabel = [self localizedStringForKey:@"Ignore"];
        self.remindButtonLabel = [self localizedStringForKey:@"Remind Me Later"];
        self.downloadButtonLabel = [self localizedStringForKey:@"Download"];
    }
    return self;
}

- (id<iVersionDelegate>)delegate
{
    if (delegate == nil)
    {
        
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
        
        delegate = (id<iVersionDelegate>)[[UIApplication sharedApplication] delegate];
#else
        delegate = (id<iVersionDelegate>)[[NSApplication sharedApplication] delegate];
#endif
        
    }
    return delegate;
}

- (NSString *)updateAvailableTitle
{
    if (updateAvailableTitle)
    {
        return updateAvailableTitle;
    }
    return [NSString stringWithFormat:[self localizedStringForKey:@"A new version of %@ is available to download"], applicationName];
}

- (NSURL *)updateURL
{
    if (updateURL)
    {
        return updateURL;
    }
    
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
    return [NSURL URLWithString:[NSString stringWithFormat:iVersioniOSAppStoreURLFormat, appStoreID]];
#else
    return [NSURL URLWithString:[NSString stringWithFormat:iVersionMacAppStoreURLFormat, appStoreID]];
#endif
    
}

- (NSDate *)lastChecked
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:iVersionLastCheckedKey];
}

- (void)setLastChecked:(NSDate *)date
{
    [[NSUserDefaults standardUserDefaults] setObject:date forKey:iVersionLastCheckedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSDate *)lastReminded
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:iVersionLastRemindedKey];
}

- (void)setLastReminded:(NSDate *)date
{
    [[NSUserDefaults standardUserDefaults] setObject:date forKey:iVersionLastRemindedKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSString *)ignoredVersion
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:iVersionIgnoreVersionKey];
}

- (void)setIgnoredVersion:(NSString *)version
{
    [[NSUserDefaults standardUserDefaults] setObject:version forKey:iVersionIgnoreVersionKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)viewedVersionDetails
{
    return [[[NSUserDefaults standardUserDefaults] objectForKey:iVersionLastVersionKey] isEqualToString:applicationVersion];
}

- (void)setViewedVersionDetails:(BOOL)viewed
{
    [[NSUserDefaults standardUserDefaults] setObject:(viewed? applicationVersion: nil) forKey:iVersionLastVersionKey];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    AH_RELEASE(appStoreLanguage);
    AH_RELEASE(appStoreCountry);
    AH_RELEASE(remoteVersionsDict);
    AH_RELEASE(downloadError);
    AH_RELEASE(remoteVersionsPlistURL);
    AH_RELEASE(localVersionsPlistPath);
    AH_RELEASE(applicationName);
    AH_RELEASE(applicationVersion);
    AH_RELEASE(applicationBundleID);
    AH_RELEASE(inThisVersionTitle);
    AH_RELEASE(updateAvailableTitle);
    AH_RELEASE(versionLabelFormat);
    AH_RELEASE(okButtonLabel);
    AH_RELEASE(ignoreButtonLabel);
    AH_RELEASE(remindButtonLabel);
    AH_RELEASE(downloadButtonLabel);
    AH_RELEASE(updateURL);
    AH_RELEASE(versionDetails);
    AH_RELEASE(visibleLocalAlert);
    AH_RELEASE(visibleRemoteAlert);
    AH_SUPER_DEALLOC;
}

#pragma mark -
#pragma mark Methods

- (NSString *)lastVersion
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:iVersionLastVersionKey];
}

- (void)setLastVersion:(NSString *)version
{
    [[NSUserDefaults standardUserDefaults] setObject:version forKey:iVersionLastVersionKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSDictionary *)localVersionsDict
{
    static NSDictionary *versionsDict = nil;
    if (versionsDict == nil)
    {
        if (localVersionsPlistPath == nil)
        {
            versionsDict = [[NSDictionary alloc] init]; //empty dictionary
        }
        else
        {
            NSString *versionsFile = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:localVersionsPlistPath];
            versionsDict = [[NSDictionary alloc] initWithContentsOfFile:versionsFile];
        }
    }
    return versionsDict;
}

- (NSString *)mostRecentVersionInDict:(NSDictionary *)dict
{
    return [[[dict allKeys] sortedArrayUsingSelector:@selector(compareVersion:)] lastObject];
}

- (NSString *)versionDetails:(NSString *)version inDict:(NSDictionary *)dict
{
    id versionData = [dict objectForKey:version];
    if ([versionData isKindOfClass:[NSString class]])
    {
        return versionData;
    }
    else if ([versionData isKindOfClass:[NSArray class]])
    {
        return [versionData componentsJoinedByString:@"\n\n"];
    }
    return nil;
}

- (NSString *)versionDetailsSince:(NSString *)lastVersion inDict:(NSDictionary *)dict
{
    if (debug)
    {
        lastVersion = @"0";
    }
    BOOL newVersionFound = NO;
    NSMutableString *details = [NSMutableString string];
    NSArray *versions = [[dict allKeys] sortedArrayUsingSelector:@selector(compareVersionDescending:)];
    for (NSString *version in versions)
    {
        if ([version compareVersion:lastVersion] == NSOrderedDescending)
        {
            newVersionFound = YES;
            if (groupNotesByVersion)
            {
                [details appendFormat:versionLabelFormat, version];
                [details appendString:@"\n\n"];
            }
            [details appendString:[self versionDetails:version inDict:dict]];
            [details appendString:@"\n\n"];
        }
    }
    return newVersionFound? [details stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]: nil;
}

- (NSString *)versionDetails
{
    if (!versionDetails)
    {
        if (self.viewedVersionDetails)
        {
            self.versionDetails = [self versionDetails:applicationVersion inDict:[self localVersionsDict]];
        }
        else 
        {
            self.versionDetails = [self versionDetailsSince:self.lastVersion inDict:[self localVersionsDict]];
        }
    }
    return versionDetails;
}

- (NSString *)URLEncodedString:(NSString *)string
{
    CFStringRef encoded = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                  (__bridge CFStringRef)string,
                                                                  NULL,
                                                                  CFSTR("!*'\"();:@&=+$,/?%#[]% "),
                                                                  kCFStringEncodingUTF8);
    return CFBridgingRelease(encoded);
}

- (void)downloadedVersionsData
{
    
#ifndef __IPHONE_OS_VERSION_MAX_ALLOWED
    
    //only show when main window is available
    if (![[NSApplication sharedApplication] mainWindow])
    {
        [self performSelector:@selector(downloadedVersionsData) withObject:nil afterDelay:0.5];
        return;
    }
    
#endif
    
    //check if data downloaded
    if (!remoteVersionsDict)
    {
        if ([self.delegate respondsToSelector:@selector(iVersionVersionCheckDidFailWithError:)])
        {
            [delegate iVersionVersionCheckDidFailWithError:downloadError];
        }
        
        //deprecated code path
        else if ([delegate respondsToSelector:@selector(iVersionVersionCheckFailed:)])
        {
            NSLog(@"iVersionVersionCheckFailed: delegate method is deprecated, use iVersionVersionCheckDidFailWithError: instead");
            [delegate performSelector:@selector(iVersionVersionCheckFailed:) withObject:downloadError];
        }
        return;
    }
    
    //get version details
    NSString *details = [self versionDetailsSince:applicationVersion inDict:remoteVersionsDict];
    NSString *mostRecentVersion = [self mostRecentVersionInDict:remoteVersionsDict];
    if (details)
    {
        //inform delegate of new version
        if ([self.delegate respondsToSelector:@selector(iVersionDidDetectNewVersion:details:)])
        {
            [delegate iVersionDidDetectNewVersion:mostRecentVersion details:details];
        }
        
        //deprecated code path
        else if ([delegate respondsToSelector:@selector(iVersionDetectedNewVersion:details:)])
        {
            NSLog(@"iVersionDetectedNewVersion:details: delegate method is deprecated, use iVersionDidDetectNewVersion:details: instead");
            [delegate performSelector:@selector(iVersionDetectedNewVersion:details:) withObject:mostRecentVersion withObject:details];
        }
        
        //check if ignored
        BOOL showDetails = ![self.ignoredVersion isEqualToString:mostRecentVersion] || debug;
        if (showDetails && [self.delegate respondsToSelector:@selector(iVersionShouldDisplayNewVersion:details:)])
        {
            showDetails = [delegate iVersionShouldDisplayNewVersion:mostRecentVersion details:details];
        }
        
        //show details
        if (showDetails && !visibleRemoteAlert)
        {
            
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
            
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:self.updateAvailableTitle
                                                            message:details
                                                           delegate:self
                                                  cancelButtonTitle:ignoreButtonLabel
                                                  otherButtonTitles:downloadButtonLabel, nil];
            if (remindButtonLabel)
            {
                [alert addButtonWithTitle:remindButtonLabel];
            }
            
            self.visibleRemoteAlert = alert;
            [visibleRemoteAlert show];
            AH_RELEASE(alert);
#else
            self.visibleRemoteAlert = [NSAlert alertWithMessageText:self.updateAvailableTitle
                                                      defaultButton:downloadButtonLabel
                                                    alternateButton:ignoreButtonLabel
                                                        otherButton:nil
                                          informativeTextWithFormat:details];    
            
            if (remindButtonLabel)
            {
                [visibleRemoteAlert addButtonWithTitle:remindButtonLabel];
            }
            
            [visibleRemoteAlert beginSheetModalForWindow:[[NSApplication sharedApplication] mainWindow]
                                           modalDelegate:self
                                          didEndSelector:@selector(remoteAlertDidEnd:returnCode:contextInfo:)
                                             contextInfo:nil];
#endif
            
        }
    }
    else if ([self.delegate respondsToSelector:@selector(iVersionDidNotDetectNewVersion)])
    {
        [delegate iVersionDidNotDetectNewVersion];
    }
}

- (BOOL)shouldCheckForNewVersion
{
    //debug mode?
    if (!debug)
    {
        //check if within the reminder period
        if (self.lastReminded != nil)
        {
            //reminder takes priority over check period
            if ([[NSDate date] timeIntervalSinceDate:self.lastReminded] < remindPeriod * SECONDS_IN_A_DAY)
            {
                return NO;
            }
        }
        
        //check if within the check period
        else if (self.lastChecked != nil && [[NSDate date] timeIntervalSinceDate:self.lastChecked] < checkPeriod * SECONDS_IN_A_DAY)
        {
            return NO;
        }
    }
    
    //confirm with delegate
    if ([self.delegate respondsToSelector:@selector(iVersionShouldCheckForNewVersion)])
    {
        return [delegate iVersionShouldCheckForNewVersion];
    }
    
    //perform the check
    return YES;
}

- (NSString *)valueForKey:(NSString *)key inJSON:(NSString *)json
{
    NSRange keyRange = [json rangeOfString:[NSString stringWithFormat:@"\"%@\"", key]];
    if (keyRange.location != NSNotFound)
    {
        NSInteger start = keyRange.location + keyRange.length;
        NSRange valueStart = [json rangeOfString:@":" options:0 range:NSMakeRange(start, [json length] - start)];
        if (valueStart.location != NSNotFound)
        {
            start = valueStart.location + 1;
            NSRange valueEnd = [json rangeOfString:@"," options:0 range:NSMakeRange(start, [json length] - start)];
            if (valueEnd.location != NSNotFound)
            {
                NSString *value = [json substringWithRange:NSMakeRange(start, valueEnd.location - start)];
                value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                while ([value hasPrefix:@"\""] && ![value hasSuffix:@"\""])
                {
                    if (valueEnd.location == NSNotFound)
                    {
                        break;
                    }
                    NSInteger newStart = valueEnd.location + 1;
                    valueEnd = [json rangeOfString:@"," options:0 range:NSMakeRange(newStart, [json length] - newStart)];
                    value = [json substringWithRange:NSMakeRange(start, valueEnd.location - start)];
                    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
                
                value = [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
                value = [value stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
                value = [value stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                value = [value stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
                value = [value stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
                value = [value stringByReplacingOccurrencesOfString:@"\\r" withString:@"\r"];
                value = [value stringByReplacingOccurrencesOfString:@"\\t" withString:@"\t"];
                value = [value stringByReplacingOccurrencesOfString:@"\\f" withString:@"\f"];
                value = [value stringByReplacingOccurrencesOfString:@"\\b" withString:@"\f"];
                
                while (YES)
                {
                    NSRange unicode = [value rangeOfString:@"\\u"];
                    if (unicode.location == NSNotFound)
                    {
                        break;
                    }
                    
                    uint32_t c = 0;
                    NSString *hex = [value substringWithRange:NSMakeRange(unicode.location + 2, 4)];
                    NSScanner *scanner = [NSScanner scannerWithString:hex];
                    [scanner scanHexInt:&c];
                    
                    if (c <= 0xffff)
                    {
                        value = [value stringByReplacingCharactersInRange:NSMakeRange(unicode.location, 6) withString:[NSString stringWithFormat:@"%C", c]];
                    }
                    else
                    {
                        //convert character to surrogate pair
                        uint16_t x = (uint16_t)c;
                        uint16_t u = (c >> 16) & ((1 << 5) - 1);
                        uint16_t w = (uint16_t)u - 1;
                        unichar high = 0xd800 | (w << 6) | x >> 10;
                        unichar low = (uint16_t)(0xdc00 | (x & ((1 << 10) - 1)));
                        
                        value = [value stringByReplacingCharactersInRange:NSMakeRange(unicode.location, 6) withString:[NSString stringWithFormat:@"%C%C", high, low]];
                    }
                }
                return value;
            }
        }
    }
    return nil;
}

- (void)setAppStoreIDOnMainThread:(NSString *)appStoreIDString
{
    self.appStoreID = [appStoreIDString longLongValue];
}

- (void)checkForNewVersionInBackground
{
    @synchronized (self)
    {
        @autoreleasepool
        {
            NSError *error = nil;
            BOOL newerVersionAvailable = NO;
            NSDictionary *versions = nil;
            
            //first check iTunes
            NSString *iTunesServiceURL = [NSString stringWithFormat:iVersionAppLookupURLFormat, appStoreCountry, appStoreLanguage];
            if (appStoreID)
            {
                iTunesServiceURL = [iTunesServiceURL stringByAppendingFormat:@"&id=%i", appStoreID];
            }
            else 
            {
                iTunesServiceURL = [iTunesServiceURL stringByAppendingFormat:@"&bundleId=%@", applicationBundleID];
            }
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iTunesServiceURL] options:NSDataReadingUncached error:&error];
            if (data)
            {
                //convert to string
                NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                
                //check bundle ID matches
                NSString *bundleID = [self valueForKey:@"bundleId" inJSON:json];
                if (bundleID && [bundleID isEqualToString:applicationBundleID])
                {
                    //get version details
                    NSString *releaseNotes = [self valueForKey:@"releaseNotes" inJSON:json];
                    NSString *latestVersion = [self valueForKey:@"version" inJSON:json];
                    if (releaseNotes && latestVersion)
                    {
                        versions = [NSDictionary dictionaryWithObject:releaseNotes forKey:latestVersion];
                    }
                    
                    //check for new version
                    newerVersionAvailable = ([latestVersion compareVersion:applicationVersion] == NSOrderedDescending);
                    
                    //get app id
                    if (!appStoreID)
                    {
                        NSString *appStoreIDString = [self valueForKey:@"trackId" inJSON:json];
                        [self performSelectorOnMainThread:@selector(setAppStoreIDOnMainThread:) withObject:appStoreIDString waitUntilDone:YES];
                    }
                }
                
                //release json
                AH_RELEASE(json);
                
                //now check plist for alternative release notes
                if (appStoreID && newerVersionAvailable && remoteVersionsPlistURL)
                {
                    NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:remoteVersionsPlistURL] options:NSDataReadingUncached error:&error];
                    if (data)
                    {
                        NSPropertyListFormat format;
                        if ([NSPropertyListSerialization respondsToSelector:@selector(propertyListWithData:options:format:error:)])
                        {
                            versions = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:&format error:&error];
                        }
                        else
                        {
                            versions = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:0 format:&format errorDescription:NULL];
                        }
                    }
                }
            }
            [self performSelectorOnMainThread:@selector(setDownloadError:) withObject:error waitUntilDone:YES];
            [self performSelectorOnMainThread:@selector(setRemoteVersionsDict:) withObject:versions waitUntilDone:YES];
            [self performSelectorOnMainThread:@selector(setLastChecked:) withObject:[NSDate date] waitUntilDone:YES];
            [self performSelectorOnMainThread:@selector(downloadedVersionsData) withObject:nil waitUntilDone:YES];        
        }
    }
}

- (void)checkForNewVersion
{
    [self performSelectorInBackground:@selector(checkForNewVersionInBackground) withObject:nil];
}

- (void)checkIfNewVersion
{
    
#ifndef __IPHONE_OS_VERSION_MAX_ALLOWED
    
    //only show when main window is available
    if (![[NSApplication sharedApplication] mainWindow])
    {
        [self performSelector:@selector(checkIfNewVersion) withObject:nil afterDelay:0.5];
        return;
    }
    
#endif
    
    if (self.lastVersion != nil || showOnFirstLaunch || debug)
    {
        if ([applicationVersion compareVersion:self.lastVersion] == NSOrderedDescending || debug)
        {
            //clear reminder
            self.lastReminded = nil;
            
            //get version details
            BOOL showDetails = !!self.versionDetails;
            if (showDetails && [self.delegate respondsToSelector:@selector(iVersionShouldDisplayCurrentVersionDetails:)])
            {
                showDetails = [delegate iVersionShouldDisplayCurrentVersionDetails:self.versionDetails];
            }
            
            //show details
            if (showDetails && !visibleLocalAlert)
            {
                
#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED
                
                self.visibleLocalAlert = AH_AUTORELEASE([[UIAlertView alloc] initWithTitle:inThisVersionTitle
                                                                                   message:versionDetails
                                                                                  delegate:self
                                                                         cancelButtonTitle:okButtonLabel
                                                                         otherButtonTitles:nil]);
                [visibleLocalAlert show];
#else
                self.visibleLocalAlert = [NSAlert alertWithMessageText:inThisVersionTitle
                                                         defaultButton:okButtonLabel
                                                       alternateButton:nil
                                                           otherButton:nil
                                             informativeTextWithFormat:versionDetails];    
                
                [visibleLocalAlert beginSheetModalForWindow:[[NSApplication sharedApplication] mainWindow]
                                              modalDelegate:self
                                             didEndSelector:@selector(localAlertDidEnd:returnCode:contextInfo:)
                                                contextInfo:nil];
#endif
            }
        }
    }
    else 
    {
        //record this as last viewed release
        self.viewedVersionDetails = YES;
    }
}

#pragma mark -
#pragma mark UIAlertViewDelegate methods

#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED

- (void)openAppPageInAppStore
{
    [[UIApplication sharedApplication] openURL:self.updateURL];
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    //latest version
    NSString *latestVersion = [self mostRecentVersionInDict:remoteVersionsDict];
    
    if (alertView == visibleLocalAlert)
    {
        //record that details have been viewed
        self.viewedVersionDetails = YES;
    }
    else if (buttonIndex == alertView.cancelButtonIndex)
    {
        //log event
        if ([self.delegate respondsToSelector:@selector(iVersionUserDidIgnoreUpdate:)])
        {
            [delegate iVersionUserDidIgnoreUpdate:latestVersion];
        }
        
        //ignore this version
        self.ignoredVersion = latestVersion;
        self.lastReminded = nil;
    }
    else if (buttonIndex == 2)
    {
        //log event
        if ([self.delegate respondsToSelector:@selector(iVersionUserDidRequestReminderForUpdate:)])
        {
            [delegate iVersionUserDidRequestReminderForUpdate:latestVersion];
        }
        
        //remind later
        self.lastReminded = [NSDate date];
    }
    else
    {
        //log event
        if ([self.delegate respondsToSelector:@selector(iVersionUserDidAttemptToDownloadUpdate:)])
        {
            [delegate iVersionUserDidAttemptToDownloadUpdate:latestVersion];
        }
        
        //clear reminder
        self.lastReminded = nil;
        
        //go to download page
        [self openAppPageInAppStore];
    }
    
    //release alert
    if (alertView == visibleLocalAlert)
    {
        self.visibleLocalAlert = nil;
    }
    else
    {
        self.visibleRemoteAlert = nil;
    }
}

#else

- (void)localAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
    //record that details have been viewed
    self.viewedVersionDetails = YES;
}

- (void)openAppPageWhenAppStoreLaunched
{
    //check if app store is running
    ProcessSerialNumber psn = { kNoProcess, kNoProcess };
    while (GetNextProcess(&psn) == noErr)
    {
        CFDictionaryRef cfDict = ProcessInformationCopyDictionary(&psn,  kProcessDictionaryIncludeAllInformationMask);
        NSString *bundleID = [(NSDictionary *)cfDict objectForKey:(NSString *)kCFBundleIdentifierKey];
        if ([iVersionMacAppStoreBundleID isEqualToString:bundleID])
        {
            //open app page
            [[NSWorkspace sharedWorkspace] performSelector:@selector(openURL:) withObject:self.updateURL afterDelay:MAC_APP_STORE_REFRESH_DELAY];
            CFRelease(cfDict);
            return;
        }
        CFRelease(cfDict);
    }
    
    //try again
    [self performSelector:@selector(openAppPageWhenAppStoreLaunched) withObject:nil afterDelay:0.0];
}

- (void)openAppPageInAppStore
{
    [[NSWorkspace sharedWorkspace] openURL:self.updateURL];
    [self openAppPageWhenAppStoreLaunched];
}

- (void)remoteAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
    //latest version
    NSString *latestVersion = [self mostRecentVersionInDict:remoteVersionsDict];
    
    switch (returnCode)
    {
        case NSAlertAlternateReturn:
        {
            //log event
            if ([self.delegate respondsToSelector:@selector(iVersionUserDidIgnoreUpdate:)])
            {
                [delegate iVersionUserDidIgnoreUpdate:latestVersion];
            }
            
            //ignore this version
            self.ignoredVersion = latestVersion;
            self.lastReminded = nil;
            break;
        }
        case NSAlertDefaultReturn:
        {
            //log event
            if ([self.delegate respondsToSelector:@selector(iVersionUserDidAttemptToDownloadUpdate:)])
            {
                [delegate iVersionUserDidAttemptToDownloadUpdate:latestVersion];
            }
            
            //clear reminder
            self.lastReminded = nil;
            
            //launch mac app store
            [self openAppPageInAppStore];
            break;
        }
        default:
        {
            //log event
            if ([self.delegate respondsToSelector:@selector(iVersionUserDidRequestReminderForUpdate:)])
            {
                [delegate iVersionUserDidRequestReminderForUpdate:latestVersion];
            }
            
            //remind later
            self.lastReminded = [NSDate date];
        }
    }
    
    //release alert
    if (alert == visibleLocalAlert)
    {
        self.visibleLocalAlert = nil;
    }
    else
    {
        self.visibleRemoteAlert = nil;
    }
}

#endif

- (void)applicationLaunched:(NSNotification *)notification
{
    if (checkAtLaunch)
    {
        [self checkIfNewVersion];
        if ([self shouldCheckForNewVersion])
        {
            [self checkForNewVersion];
        }
    }
}

#ifdef __IPHONE_OS_VERSION_MAX_ALLOWED

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground)
    {
        if (checkAtLaunch && [self shouldCheckForNewVersion])
        {
            [self checkForNewVersion];
        }
    }
}

#endif

@end