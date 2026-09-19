//
//  PerlInterpreter.h
//  Pastefix
//
//  Created by Brian Naylor on 11/10/19.
//  Copyright © 2019 Brian Naylor. All rights reserved.
//

#import "Interpreter.h"

NS_ASSUME_NONNULL_BEGIN

@interface PerlInterpreter : Interpreter {
    NSString *executablePath;
    NSString *cmdlineArgs;
}

- (id)         init;
- (NSString *) scriptCode:(int) scriptID;

@end

NS_ASSUME_NONNULL_END
