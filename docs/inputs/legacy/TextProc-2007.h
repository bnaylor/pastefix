//
//  TextProc.h
//  Pastefix
//
//  Created by Brian L. Naylor on 4/21/07.
//  Copyright 2007 scromp. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#include <iconv.h>


@interface TextProc : NSObject {
  iconv_t       iconv_handle;
}

- (id)init;

- (NSString *)convertUTF8ToASCII:(NSString *)input;
- (BOOL)shouldSplitLines:(NSString *)buffer maxLength:(int)count;
- (NSString *)splitLines:(NSString *)buffer maxLength:(int)count;
- (NSArray *)doSplit:(NSString *)buffer onString:(NSString *)delim maxLength:(int)count;
- (void)dealloc;

@end
