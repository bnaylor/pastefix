//
//  PerlInterpreter.m
//  Pastefix
//
//  Created by Brian Naylor on 11/10/19.
//  Copyright © 2019 Brian Naylor. All rights reserved.
//

#import "PerlInterpreter.h"

#define PERL      "/usr/bin/perl"
#define PERL_ARGS "-ln"

#define PERL_MAIN                          \
"                                        \n\
use strict;                              \n\
use warnings;                            \n\
                                         \n\
sub process_buffer($);                   \n\
                                         \n\
my $buffer = '';                         \n\
                                         \n\
while(<STDIN>) {                         \n\
    $buffer .= $_;                       \n\
}                                        \n\
                                         \n\
my $filtered = process_buffer($buffer);  \n\
print STDOUT $filtered;                  \n\
close(STDOUT);                           \n\
                                         \n\
exit 0;                                  \n\
"

#define PERL_USER                          \
"                                        \n\
sub process_buffer($) {                  \n\
    my($buffer) = @_;                    \n\
    $buffer =~ s/hello/world/gm;         \n\
    return $buffer;                      \n\
}                                        \n\
"


@implementation PerlInterpreter

- (id)init
{
    if(self = [super init]) {
        executablePath = [NSString stringWithCString:PERL encoding:NSUTF8StringEncoding];
        cmdlineArgs = [NSString stringWithCString:PERL_ARGS encoding:NSUTF8StringEncoding];
    }
    return self;
}

- (NSString *) execPath {
    return executablePath;
}

- (NSString *) execArgs {
    return cmdlineArgs;
}

- (NSString *)scriptCode:(int) scriptID {
    NSLog(@"perl scriptcode");
    return [NSString stringWithCString:PERL_MAIN PERL_USER encoding:NSUTF8StringEncoding];
}

@end
