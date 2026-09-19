//
//  Interpreter.m
//  Pastefix
//
//  Created by Brian Naylor on 11/9/19.
//  Copyright © 2019 Brian Naylor. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "Interpreter.h"
#import "Error.h"
#import "Tempfile.h"


@implementation Interpreter

- (id)init
{
    if(self = [super init]) {
    }
    return self;
}

// Subclasses need to implement this
- (NSString *) execPath {
    return NULL;
}

// Subclasses need to implement this
- (NSString *) execArgs {
    return NULL;
}

// Subclasses need to implement this
- (NSString *)scriptCode:(int) scriptID {
    NSLog(@"toplevel scriptcode xXX");
    return NULL;
}

// later this will take some kind of identifier/etc (scriptID tbd) for routing
// XXX also revisit whether string or data makes more sense.  esp. since we convert to data.
- (BOOL) runScript:(int) scriptID buffer:(NSString *)buffer {
    NSPipe *interpreterStdin = [NSPipe pipe];
    NSPipe *interpreterStdout = [NSPipe pipe];
    NSFileHandle *istdin = interpreterStdin.fileHandleForWriting;
    NSFileHandle *istdout = interpreterStdout.fileHandleForReading;

    Tempfile *script = [[Tempfile alloc] init];
    if (! [script writeString:[self scriptCode:scriptID]]) {
        NSLog(@"Error writing temporary file");
        return FALSE;
    }
    NSLog(@"Wrote script to %@\n", [script filePath]);

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = [self execPath];
    task.arguments = @[[self execArgs], [script filePath]];
    task.standardInput = interpreterStdin;
    task.standardOutput = interpreterStdout;

    NSError *error = nil;
    if (! [task launchAndReturnError:&error]) {
        Error *e;
        [e errorWithError:error logMessage:@"Couldn't execute interpreter."];
    }
    
    NSLog(@"Writing text: %@\n", buffer);
    NSData *bufdata = [buffer dataUsingEncoding:NSUTF8StringEncoding];
    [istdin writeData:bufdata];
    [istdin closeFile];
    
    NSData *data = [istdout readDataToEndOfFile];
    [istdout closeFile];

    NSString *output = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
    NSLog (@"interpreter returned text:\n%@", output);
    return TRUE;
}

@end
