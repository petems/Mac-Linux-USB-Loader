//
//  Document.m
//  Mac Linux USB Loader
//
//  Created by SevenBits on 11/26/12.
//  Copyright (c) 2012 SevenBits. All rights reserved.
//

#import "Document.h"
#import "USBDevice.h"

#import "RHPreferences/RHPreferences.h"
#import "RHPreferences/RHPreferencesWindowController.h"

#import "AppDelegate.h"
#import "SBAcknowledgementsViewController.h"
#import "SBUpdateControlViewController.h"
#import "SBNotificationViewController.h"

#pragma mark - SBCopyDelegateInfoRelay class

/*
 * A simple class used to store information that we'll pass to the progress bar.
 */
@interface SBCopyDelegateInfoRelay : NSObject

@property (assign) NSProgressIndicator *progress;
@property (assign) NSString *usbRoot;
@property (assign) NSWindow *window;
@property (assign) Document *document;

@end

@implementation SBCopyDelegateInfoRelay

@end

#pragma mark - Document class

@implementation Document

@synthesize window;

NSMutableDictionary *usbs;
NSString *isoFilePath;
NSString *isoFileName;
USBDevice *device;
FSFileOperationClientContext clientContext;
SBCopyDelegateInfoRelay *infoClientContext;

BOOL isCopying = NO;

- (id)init {
    self = [super init];
    if (self) {
        // No initilization needed here.
    }
    return self;
}

- (NSString *)windowNibName {
    return @"Document";
}

- (BOOL)windowShouldClose:(id)sender {
    if (isCopying) {
        return NO;
    } else {
        return YES;
    }
}

- (void)windowControllerDidLoadNib:(NSWindowController *)controller {
    /* I KNOW, progress bar names are totally mixed up. Someone want to fix this for me? */
    [super windowControllerDidLoadNib:controller];
    usbs = [[NSMutableDictionary alloc] initWithCapacity:10]; //A maximum capacity of 10 is fine, nobody has that many ports anyway.
    device = [USBDevice new];
    device.window = window;
    
    isoFilePath = [[self fileURL] absoluteString];
    isoFileName = [[self fileURL] lastPathComponent];
    if ([isoFileName rangeOfString:@"ubuntu"].location != NSNotFound ||
        [isoFileName rangeOfString:@"zorin"].location != NSNotFound ||
        [isoFileName rangeOfString:@"elementaryos"].location != NSNotFound ||
        [isoFileName rangeOfString:@"linuxmint"].location != NSNotFound) {
        [_distributionFamilySelector setStringValue:@"Ubuntu"];
    } else {
        [_distributionFamilySelector setStringValue:@"Debian"];
    }
    
    // Set the title of this window to contain the name of the ISO we're installing.
    [window setTitle:[@"Installing: " stringByAppendingString:[[isoFilePath lastPathComponent] stringByDeletingPathExtension]]];
    
    // Disable the install button if for some reason we opened this window without an open file.
    if (isoFilePath == nil) {
        [_makeUSBButton setEnabled:NO];
        [_eraseUSBButton setEnabled:NO];
    }
    
    // Read the settings regarding which firmware to install.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    bootLoaderName = [defaults stringForKey:@"selectedFirmwareType"];
    automaticallyBless = [defaults boolForKey:@"automaticallyBless"];
    
    // Update the list of USB devices.
    [self getUSBDeviceList];
    
    // Determine our system architecture.
    NSString *arch = [[self determineSystemArchitecture]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([arch isEqualToString:@"x86_64"]) {
        // Do something.
    } else {
        // Do something else.
    }
}

- (NSString *)determineSystemArchitecture {
    // Use uname to get the system processor architecture.
    NSTask *task = [[NSTask alloc] init];
    [task setArguments:@[@"-m"]];
    [task setLaunchPath:@"/usr/bin/uname"];
    
    NSPipe *pipe = [[NSPipe alloc] init];
    [task setStandardOutput:pipe];
    [task launch];
    
    // Read the data from the pipe to determine what uname printed.
    NSFileHandle *handle = [pipe fileHandleForReading];
    NSString *returnString = [[NSString alloc] initWithData:[handle readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    return returnString;
}

- (void)getUSBDeviceList {
    // Fetch the NSArray of strings of mounted media from the shared workspace.
    NSArray *volumes = [[NSWorkspace sharedWorkspace] mountedLocalVolumePaths];
    
    // Setup target variables for the data to be put into.
    BOOL isRemovable, isWritable, isUnmountable;
    NSString *description, *volumeType;
    
    [_usbDriveDropdown removeAllItems]; // Clear the dropdown list.
    [usbs removeAllObjects];           // Clear the dictionary of the list of USB drives.
    
    // Iterate through the array using fast enumeration.
    for (NSString *volumePath in volumes) {
        // Get filesystem info about each of the mounted volumes.
        if ([[NSWorkspace sharedWorkspace] getFileSystemInfoForPath:volumePath isRemovable:&isRemovable isWritable:&isWritable isUnmountable:&isUnmountable description:&description type:&volumeType]) {
            if ([volumeType isEqualToString:@"msdos"] && isWritable && [volumePath rangeOfString:@"/Volumes/"].location != NSNotFound) {
                // We have a valid mounted media - not necessarily a USB though.
                NSString *title = [NSString stringWithFormat:@"Install to: Drive at %@ of type %@", volumePath, volumeType];
                
#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_8)
                usbs[title] = volumePath; // Add the path of the usb to a dictionary so later we can tell what USB
                                          // they are refering to when they select one from a drop down.
#elif
                [usbs setObject:volumePath forKey:title];
#endif
                [_usbDriveDropdown addItemWithTitle:title]; // Add to the dropdown list.
            }
        }
    }
    
    /*
     Basically, this makes sure that you can't make the live USB if you don't have a file open (shouldn't happen, but a
     precaution), or if there are no mounted volumes we can use. If we have a mounted volume, though, and we have an ISO,
     then they can make the live USB.
     */
    if (isoFilePath != nil && [_usbDriveDropdown numberOfItems] != 1) {
        [_makeUSBButton setEnabled:YES];
        [_eraseUSBButton setEnabled:YES];
    } else if ([_usbDriveDropdown numberOfItems] == 0) { // There are no detected USB ports, at least those formatted as FAT.
        [_makeUSBButton setEnabled:NO];
        [_eraseUSBButton setEnabled:NO];
    }
    // Exit.
}

- (IBAction)updateDeviceList:(id)sender {
    [self getUSBDeviceList];
}

// This is too long... this needs to be split up, perhaps with some components in USBDevice like before.
- (IBAction)makeLiveUSB:(id)sender {
    [(AppDelegate *)[NSApp delegate] setCanQuit:NO];
    [_makeUSBButton setEnabled:NO];
    [_eraseUSBButton setEnabled:NO];
    [_distributionFamilySelector setEnabled:NO];
    [_usbDriveDropdown setEnabled:NO];
    isCopying = YES;
    
    __block BOOL failure = false;
    
    isoFilePath = [[self fileURL] path];
    
    // If no USBs available, or if no ISO open, display an error and return.
    if ([_usbDriveDropdown numberOfItems] == 0 || isoFilePath == nil) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:NSLocalizedString(@"OKAY", nil)];
        [alert setMessageText:NSLocalizedString(@"NO-USBS-PLUGGED-IN", nil)];
        [alert setInformativeText:NSLocalizedString(@"NO-USBS-PLUGGED-IN-LONG", nil)];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(regularAlertDidEnd:returnCode:contextInfo:) contextInfo:nil];
        
        [_makeUSBButton setEnabled:NO];
        [_eraseUSBButton setEnabled:NO];
        
        [(AppDelegate *)[NSApp delegate] setCanQuit:YES]; // We're done, the user can quit the program.
        isCopying = NO;
        
        return;
    }
    
    NSString* directoryKey = [_usbDriveDropdown titleOfSelectedItem];
    NSString* usbRoot = [usbs valueForKey:directoryKey];
    NSString* finalPath = [usbRoot stringByAppendingPathComponent:@"/efi/boot/"];
    
    directoryKey = nil; // Tell the garbage collector to release this object.
    
    [_spinner setUsesThreadedAnimation:YES];
    [_spinner setIndeterminate:YES];
    [_spinner setDoubleValue:0.0];
    [_spinner startAnimation:self];
    
    // Check if the Linux distro ISO already exists.
    NSString *temp = [usbRoot stringByAppendingPathComponent:@"/efi/boot/boot.iso"];
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:temp];
    
    if (fileExists == YES) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:NSLocalizedString(@"ABORT", nil)];
        [alert setMessageText:NSLocalizedString(@"FAILED-CREATE-BOOTABLE-USB", nil)];
        [alert setInformativeText:NSLocalizedString(@"FAILED-CREATE-BOOTABLE-USB-LONG", nil)];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(regularAlertDidEnd:returnCode:contextInfo:) contextInfo:nil];
        
        [_spinner stopAnimation:self];
        [_spinner setIndeterminate:NO];
        [_spinner setDoubleValue:0.0];
        [(AppDelegate *)[NSApp delegate] setCanQuit:YES];
        isCopying = NO;
        
        return;
    }

    // Now progress with the copy.
    [(AppDelegate *)[NSApp delegate] setCanQuit:NO]; // The user can't quit while we're copying.
    if ([device prepareUSB:usbRoot] == YES) {
        [_spinner setIndeterminate:NO];
        [_spinner setUsesThreadedAnimation:YES];
            
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // Use the NSFileManager to obtain the size of our source file in bytes.
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSDictionary *sourceAttributes = [fileManager fileAttributesAtPath:[[self fileURL] path] traverseLink:YES];
        NSNumber *sourceFileSize;
        
        if ((sourceFileSize = sourceAttributes[NSFileSize])) {
            // Set the max value to our source file size.
            [_spinner setMaxValue:(double)[sourceFileSize unsignedLongLongValue]];
        } else {
            // Couldn't get the file size so we need to bail.
            NSLog(@"Unable to obtain size of file being copied.");
            return;
        }
        [_spinner setDoubleValue:0.0];
            
        // Get the current run loop and schedule our callback
        CFRunLoopRef runLoop = CFRunLoopGetCurrent();
        FSFileOperationRef fileOp = FSFileOperationCreate(kCFAllocatorDefault);
        
        OSStatus status = FSFileOperationScheduleWithRunLoop(fileOp, runLoop, kCFRunLoopDefaultMode);
        if(status) {
            NSLog(@"Failed to schedule operation with run loop: %d", status);
            return;
        }
             
        // Create a filesystem ref structure for the source and destination and
        // populate them with their respective paths.
        FSRef source;
        FSRef destination;
            
        FSPathMakeRef((const UInt8 *)[[[self fileURL] path] fileSystemRepresentation], &source, NULL);
            
        Boolean isDir = true;
        FSPathMakeRef((const UInt8 *)[finalPath fileSystemRepresentation], &destination, &isDir);
        
        // Construct the storage class.
        NSLog(@"Constructing the info client context...");
        infoClientContext = [SBCopyDelegateInfoRelay new];
        infoClientContext.progress = _spinner;
        infoClientContext.usbRoot = usbRoot;
        infoClientContext.window = window;
        infoClientContext.document = self;
        
        // Start the async copy.
        if (_spinner != nil) {
            clientContext.info = (__bridge void *)infoClientContext;
        }
        
        NSLog(@"Performing the copy...");
        status = FSCopyObjectAsync(fileOp,
                                   &source,
                                   &destination, // Full path to destination dir.
                                   CFSTR("boot.iso"), // Copy with the name boot.iso.
                                   kFSFileOperationDefaultOptions,
                                   copyStatusCallback, // Our callback function.
                                   0.5, // How often to fire our callback.
                                   &clientContext); // The class with the objects that we want to use to update.
        
        CFRelease(fileOp);
        
        if(status) {
            NSLog(@"Failed to begin asynchronous object copy: %d", status);
            failure = YES;
        }
        
#pragma clang diagnostic warning "-Wdeprecated-declarations"
        
        if (!failure) {
            // Create the Enterprise configuration file.
            [device markUsbAsLive:usbRoot distributionFamily:[_distributionFamilySelector stringValue]];
        }
    } else {
        // Some form of setup failed. Alert the user.
        [(AppDelegate *)[NSApp delegate] setCanQuit:YES];
        isCopying = NO;
        
        failure = YES;
    }
    
    if (failure) {
        [_spinner setIndeterminate:NO];
        [_spinner setDoubleValue:0.0];
        [_spinner stopAnimation:self];
        
        [_spinner stopAnimation:self];
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:NSLocalizedString(@"NO", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"YES", nil)];
        [alert setMessageText:NSLocalizedString(@"FAILED-CREATE-BOOTABLE-USB", nil)];
        [alert setInformativeText:NSLocalizedString(@"FAILED-CREATE-BOOTABLE-USB-LONG2", nil)];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(eraseAlertDidEnd:returnCode:contextInfo:) contextInfo:nil]; // Offer to erase the EFI boot since we never completed.
    } else {
    }
}

+ (BOOL)autosavesInPlace
{
    return NO;
}

+ (BOOL)isEntireFileLoaded {
    return YES;
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError
{
    // Insert code here to read your document from the given data of the specified type. If outError != NULL, ensure that you create and set an appropriate error when returning NO.
    // You can also choose to override -readFromFileWrapper:ofType:error: or -readFromURL:ofType:error: instead.
    // If you override either of these, you should also override -isEntireFileLoaded to return NO if the contents are lazily loaded.
    return YES;
}

- (IBAction)eraseLiveBoot:(id)sender {
    if ([_usbDriveDropdown numberOfItems] != 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:NSLocalizedString(@"YES", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"NO", nil)];
        [alert setMessageText:NSLocalizedString(@"CONFIRM-ERASE-USB", nil)];
        [alert setInformativeText:NSLocalizedString(@"CONFIRM-ERASE-USB-LONG", nil)];
        [alert setAlertStyle:NSWarningAlertStyle];
        [alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(eraseAlertDidEnd:returnCode:contextInfo:) contextInfo:nil];
    } else {
        [sender setEnabled:NO];
    }
}

- (void)regularAlertDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo {
    // Do nothing.
}

- (void)eraseAlertDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo {
    if (returnCode == NSAlertFirstButtonReturn) {
        [(AppDelegate *)[NSApp delegate] setCanQuit:NO];

        if ([_usbDriveDropdown numberOfItems] != 0) {
            // Construct the path of the efi folder that we're going to nuke.
            NSString *directoryName = [_usbDriveDropdown titleOfSelectedItem];
            NSString *usbRoot = [usbs valueForKey:directoryName];
            NSString *tempPath = [usbRoot stringByAppendingPathComponent:@"/efi"];
            
            // Need these to recursively delete the folder, because UNIX can't erase a folder without erasing its
            // contents first, apparently.
            NSFileManager* fm = [[NSFileManager alloc] init];
            NSDirectoryEnumerator* en = [fm enumeratorAtPath:tempPath];
            NSError *err = nil;
            BOOL eraseDidSucceed;
            
            // Recursively erase the EFI folder.
            NSString *file;
            while (file = [en nextObject]) { // While there are files to remove...
                eraseDidSucceed = [fm removeItemAtPath:[tempPath stringByAppendingPathComponent:file] error:&err]; // Delete.
                if (!eraseDidSucceed && err) { // If there was an error...
                    NSString *text = [NSString stringWithFormat:@"Error: %@", err];
                    NSAlert *alert = [[NSAlert alloc] init];
                    [alert addButtonWithTitle:NSLocalizedString(@"OKAY", nil)];
                    [alert setMessageText:NSLocalizedString(@"FAILED-ERASE-BOOTABLE-USB", nil)];
                    [alert setInformativeText:text];
                    [alert setAlertStyle:NSWarningAlertStyle];
                    [alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(regularAlertDidEnd:returnCode:contextInfo:) contextInfo:nil];
                    NSLog(@"Could not delete: %@", err);
                }
            }
        }
        
        [(AppDelegate *)[NSApp delegate] setCanQuit:YES];
        isCopying = NO;
    }
}
@end

// Static function for our callback.
static void copyStatusCallback (FSFileOperationRef fileOp, const FSRef *currentItem, FSFileOperationStage stage, OSStatus error,
                            CFDictionaryRef statusDictionary, void *info) {
    /* Grab our instance of the class that we passed in as the void pointer and retrieve all of the needed fields from
     * it.
     */
    SBCopyDelegateInfoRelay *context = (__bridge SBCopyDelegateInfoRelay *)(info);
    NSProgressIndicator *progressIndicator;
    NSWindow *window;
    NSString *usbRoot;
    Document *document;
    
    if (context.progress != nil && context.window != nil && context.usbRoot != nil && context.document != nil) {
        progressIndicator = context.progress; // The progress bar to update.
        window = context.window; // The document window.
        usbRoot = context.usbRoot; // The path to the USB drive.
        document = context.document; // The document class.
    } else {
        NSLog(@"Some components are nil!");
    }
    
    if (progressIndicator == nil) {
        NSLog(@"Progress bar is nil!");
    }
    
    if (statusDictionary) {
        CFNumberRef bytesCompleted;
        
        bytesCompleted = (CFNumberRef) CFDictionaryGetValue(statusDictionary, kFSOperationBytesCompleteKey);
        
        CGFloat floatBytesCompleted;
        CFNumberGetValue (bytesCompleted, kCFNumberMaxType, &floatBytesCompleted);
        
#ifdef DEBUG
        //NSLog(@"Copied %lld bytes so far.", (unsigned long long)floatBytesCompleted);
#endif
        
        [progressIndicator setDoubleValue:(double)floatBytesCompleted];
        
        if (stage == kFSOperationStageComplete) {
            NSLog(@"Copy operation has completed.");
            
            [progressIndicator setDoubleValue:0];
            
#if (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_8)
            // Show a notification for Mountain Lion users.
            Class test = NSClassFromString(@"NSUserNotificationCenter");
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            
            // Ensure that we are running 10.8 before we display the notification as we still support Lion, which does not have
            // them.
            if (test != nil && [defaults boolForKey:@"ShowNotifications"] == YES) {
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                
                if ([defaults valueForKey:@"ShowNotifications"]) {
                    NSUserNotification *notification = [[NSUserNotification alloc] init];
                    notification.title = NSLocalizedString(@"FINISHED-MAKING-LIVE-USB", nil);
                    notification.informativeText = NSLocalizedString(@"FINISHED-MAKING-LIVE-USB-LONG", nil);
                    notification.soundName = NSUserNotificationDefaultSoundName;
                    
                    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
                }
                
                NSAlert *alert = [[NSAlert alloc] init];
                [alert addButtonWithTitle:NSLocalizedString(@"OKAY", nil)];
                [alert setMessageText:NSLocalizedString(@"FINISHED-MAKING-LIVE-USB", nil)];
                [alert setInformativeText:NSLocalizedString(@"FINISHED-MAKING-LIVE-USB-LONG", nil)];
                [alert setAlertStyle:NSWarningAlertStyle];
                
                if (document != nil || window != nil) {
                    [alert beginSheetModalForWindow:window modalDelegate:document didEndSelector:@selector(regularAlertDidEnd:returnCode:contextInfo:) contextInfo:nil];
                } else {
                    [alert runModal];
                }
            } else {
                [NSApp requestUserAttention:NSCriticalRequest];
            }
#else
            [NSApp requestUserAttention:NSCriticalRequest];
#endif
            [(AppDelegate *)[NSApp delegate] setCanQuit:YES]; // We're done, the user can quit the program.
            [document.makeUSBButton setEnabled:YES]; // Enable the buttons.
            [document.eraseUSBButton setEnabled:YES];
            isCopying = NO;
            
            if ([[NSUserDefaults standardUserDefaults] boolForKey:@"automaticallyBless"] == YES) {
                [(AppDelegate *)[NSApp delegate] blessDrive:usbRoot sender:nil]; // Automatically bless the user's drive.
            }
        }
    }
}

