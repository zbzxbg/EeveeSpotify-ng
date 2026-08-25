#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <os/log.h>

static void writeDebugLog(NSString *message) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"enableLogRecording"]) {
        return;
    }

    // Console：真正的 debug 级别。
    os_log_debug(OS_LOG_DEFAULT, "[EeveeSpotify] %{public}@", message);

    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"];
    NSString *timestamp = [[NSDate date] description];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logMessage writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor)) static void init() {
    @try {
        // Initialize Orion - do not remove this line.
        orion_init();
        // Custom initialization code goes here.
    }
    @catch (NSException *exception) {
        NSString *errorMsg = [NSString stringWithFormat:@"ERROR: Failed to initialize tweak: %@, Reason: %@", exception, [exception reason]];
        writeDebugLog(errorMsg);
    }
}
