//
//  TextProc.m
//  Pastefix
//
//  Created by Brian L. Naylor on 4/21/07.
//  Copyright 2007 scromp. All rights reserved.
//

#import "TextProc.h"
#import "Preferences.h"

@implementation TextProc

- (id)init
{
  if(self = [super init])
  {
  	iconv_handle = iconv_open("ASCII//TRANSLIT", "UTF-8");
	  if(iconv_handle == (iconv_t)-1)
	  {
	    NSLog(@"Unable to convert from UTF-8 to ASCII.\n");
	    return nil;
	  }
  }
  return self;
}


// -convert
//
// Actually does the conversion of the string.  Checks to see if it actually needs conversion first, then, if so,
// attempts to use iconv() to convert since it does nice transilteration.  If iconv doesn't like the string,
// then we punt and let NSString/NSData convert "lossily" - basically stripping weird punctuation and downsizing
// things like é to its base Roman character, 'e', and so on.
//
// Could add an intermediate step in the event of an iconv failure, doing some transliteration ourselves for 
// the most common web dingbats with an NSMutableString -replaceOccurrencesOfString:withString:etc:etc
//
- (NSString *)convertUTF8ToASCII:(NSString *)input
{
  NSString      *ret;
  NSData        *inBytes;
  size_t         inbytes_left, outbytes_left, rc;
  char         *inbuf, *outbuf, *isave, *osave;
  BOOL          use_iconv = [[NSUserDefaults standardUserDefaults] boolForKey:PFUseIconvKey];
  NSLog(@"use_iconv: %d", use_iconv);
    
  // quick check to see if we need to convert anything at all
  if([input canBeConvertedToEncoding:NSASCIIStringEncoding])
  {
    return input;
  }
  
  // debug
  //  for(int i=0; i<[input length]; i++)
  //  {
  //    NSLog(@"%c=%d\n", [input characterAtIndex:i], [input characterAtIndex:i]);
  //  }

  if(use_iconv)
  {
    inBytes = [input dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    inbuf = (char*)[inBytes bytes];
    outbytes_left = sizeof(char) * [inBytes length];
    inbytes_left  = [inBytes length];
    
    // allocate more space than needed as iconv can add characters in transilteration
    if( (outbuf = (char *)malloc((outbytes_left*2)+1)) == NULL)
    {
      NSLog(@"Couldn't allocate %d bytes!\n", outbytes_left);
      return nil;
    }
    memset(outbuf, 0, (outbytes_left*2)+1);
   
    isave = inbuf;
    osave = outbuf;
    
    rc = iconv(iconv_handle, (const char **)&inbuf, &inbytes_left, &outbuf, &outbytes_left);
    if(rc == -1)
    {
      NSLog(@"iconv returned an error: ");
      switch(errno) {
        case E2BIG:
          NSLog(@"There is not sufficient room at *outbuf.\n");
          break;
        case EILSEQ:
          NSLog(@"An invalid multibyte sequence has been encountered in the input.\n");
          break;
        case EINVAL:
          NSLog(@"An incomplete multibyte sequence has been encountered in the input.\n");
          break;
        default:
          NSLog(@"Unknown error: %d\n", errno);
          break;
    };
      // iconv failed - destructively convert
      ret = [[NSString alloc] initWithBytes:[[input dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES] bytes] 
                                      length:[input length] encoding:NSASCIIStringEncoding];
    }
    else
    {
      // iconv worked
      ret = [[NSString alloc] initWithBytes:osave length:strlen(osave) encoding:NSASCIIStringEncoding];
    }
    
    free(osave);    
  }
  else  // use_iconv=NO
  {
    ret = [[NSString alloc] initWithBytes:[[input dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES] bytes] 
                                   length:[input length] encoding:NSASCIIStringEncoding];    
  }
  
  [ret autorelease];
  return(ret);  
}

- (BOOL)shouldSplitLines:(NSString *)buffer maxLength:(int)count
{
  NSString *tmp;
  NSScanner *scanner = [NSScanner scannerWithString:buffer];
  
  while([scanner isAtEnd] == NO)
  {
    if([scanner scanUpToString:@"\n" intoString:&tmp])
    {
      if([tmp length] > count)
      {
        return YES;
      }
    }
  }
  
  return NO;
}

- (NSString *)splitLines:(NSString *)buffer maxLength:(int)count
{
  NSString *tmp;
  NSMutableString *ret = [[NSMutableString alloc] init];
  NSScanner *scanner = [NSScanner scannerWithString:buffer];
  
  if(![self shouldSplitLines:buffer maxLength:count])
  {
    [ret release];
    return buffer;
  }
  
  while([scanner isAtEnd] == NO)
  {
    if([scanner scanUpToString:@"\n" intoString:&tmp])
    {
      if([tmp length] > count)
      {
        NSArray *newlines = [self doSplit:tmp onString:@" " maxLength:count];
        if(!newlines)
        {
          NSLog(@"Internal error: splitLines");
          return @"Internal error splitting lines";
        }
        for(int i=0; i<[newlines count]; i++)
        {
          [ret appendFormat:@"%@\n", [newlines objectAtIndex:i]];
        }
      }
      else
      {
        [ret appendFormat:@"%@\n", tmp];
      }
    }
  }

  [ret autorelease];
  return ret;
}

// doSplit
// does the actual line-splitting
//
// I'm open to better suggestions in terms of how to do this.  It seems kinda
// goofy and i know there are some pretty unlikely boundary bugs but I don't
// care for the time being.
// 
- (NSArray *)doSplit:(NSString *)buffer onString:(NSString *)delim maxLength:(int)count
{
  NSMutableArray *ret = [[NSMutableArray alloc] init];
  NSArray *words;
  
  words = [buffer componentsSeparatedByString:@" "];
  
  NSMutableString *chunk = [NSMutableString stringWithString:@""];
  NSString *thisword;
  for(int i=0; i<[words count]; i++)
  {
    thisword = [words objectAtIndex:i];
    if([thisword length] > count)
    {
      // destructive, fuck'em :)
      thisword = @"You gotta be kidding me.";
    }
    else
    {
      // stopping condition
      if(([chunk length] + [thisword length] + 1) >= count)
      {
        [ret addObject:chunk];
        chunk = [NSMutableString stringWithString:thisword];
        [chunk appendString:@" "];
      }
      else
      {
        [chunk appendString:thisword];
        [chunk appendString:@" "];
      }
    }
  }
  [ret addObject:chunk];  
    
  [ret autorelease];
  return ret;
}

- (void)dealloc
{
  iconv_close(iconv_handle);
  [super dealloc];
}

@end
