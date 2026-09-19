
#ifndef Interpreter_h
#define Interpreter_h

#import <Foundation/Foundation.h>

@interface Interpreter : NSObject {
}

- (id)         init;
- (NSString *) execPath;
- (NSString *) execArgs;
- (BOOL)       runScript:(int) scriptID buffer:(NSString *)buffer;
- (NSString *) scriptCode:(int) scriptID;

@end

#endif /* Interpreter_h */
