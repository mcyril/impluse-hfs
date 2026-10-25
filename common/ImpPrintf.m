//
//  ImpPrintf.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-01.
//

#import "ImpPrintf.h"

static bool curMuffled = false;

bool ImpSetPrintfMuffle(bool newMuffled) {
	bool const oldMuffled = curMuffled;
	curMuffled = newMuffled;
	return oldMuffled;
}

int ImpPrintf(NSString *_Nonnull const fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *_Nonnull const msg = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	//Write the full UTF-8 bytes rather than printf("%s"), which stops at the first NUL. HFS names can contain NUL characters, and those must not truncate the line.
	NSData *_Nonnull const msgData = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
	return (int)fwrite(msgData.bytes, 1, msgData.length, stdout);
}
