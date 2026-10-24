//
//  ImpDefragmentingHFSToHFSPlusConverter.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-10.
//

#import "ImpDefragmentingHFSToHFSPlusConverter.h"

#import "ImpTextEncodingConverter.h"
#import "ImpSizeUtilities.h"
#import "NSData+ImpMultiplication.h"
#import "ImpSourceVolume.h"
#import "ImpHFSSourceVolume.h"
#import "ImpDestinationVolume.h"
#import "ImpHFSPlusDestinationVolume.h"
#import "ImpVirtualFileHandle.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeIndexNode.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpMutableBTreeFile.h"

#import <hfs/hfs_format.h>

@implementation ImpDefragmentingHFSToHFSPlusConverter
{
	NSMutableArray <NSData *> *_Nullable _catalogRecords;
	bool _hasBootBlocks, _hasVolumeHeader, _hasAllocationsBitmap, _hasCatalogFile, _hasExtentsOverflowFile, _hasUpdatedExtents;
}

#pragma mark Conversion utilities

- (void) convertHFSVolumeHeader:(struct HFSMasterDirectoryBlock const *_Nonnull const)mdbPtr toHFSPlusVolumeHeader:(struct HFSPlusVolumeHeader *_Nonnull const)vhPtr
{
	[super convertHFSVolumeHeader:mdbPtr toHFSPlusVolumeHeader:vhPtr];

	//Reset some things that don't make sense in a defragmenting conversion, and let them be repopulated elsewhere.
	u_int32_t const blockSize = kISOStandardBlockSize;
	S(vhPtr->blockSize, blockSize);
	u_int32_t const clumpSize = blockSize * 2 * 2;
	S(vhPtr->rsrcClumpSize, clumpSize);
	S(vhPtr->dataClumpSize, clumpSize);

	//To be repopulated by initializing the allocations file.
	S(vhPtr->totalBlocks, 0);
	S(vhPtr->freeBlocks, 0);
	S(vhPtr->nextAllocation, 0);
}

- (void) copyFromHFSExtentsOverflowFile:(ImpBTreeFile *_Nonnull const)sourceTree toHFSPlusExtentsOverflowFile:(ImpMutableBTreeFile *_Nonnull const)destTree {
	//We're going to copy files anew, without regard to where they might have been on the source volume, so any extents in the old extents overflow file have no relevance in the new one. The new one will very likely be empty; if it isn't, any files that do end up in it will be added when those files are copied.

	//At one point I thought we have to create an extents overflow file with an empty leaf node (so that there's a root node). Evidently not: fsck_hfs explicitly flags this as invalid.
#if 0
	ImpBTreeNode *_Nonnull const leafNode = [destTree allocateNewNodeOfKind:kBTLeafNode populate:^(void *_Nonnull bytes, NSUInteger length) {
		struct BTNodeDescriptor *_Nonnull const nodeDesc = bytes;
		S(nodeDesc->height, 1);
	}];
#endif

	u_int32_t const numNodesTotal = (u_int32_t)(destTree.lengthInBytes / destTree.bytesPerNode);
	u_int32_t const numNodesUsed = 1; //The header node.
	[destTree.headerNode reviseHeaderRecord:^(struct BTHeaderRec *_Nonnull const headerRecPtr) {
		S(headerRecPtr->rootNode, 0);
		S(headerRecPtr->treeDepth, 0);
		S(headerRecPtr->firstLeafNode, 0);
		S(headerRecPtr->lastLeafNode, 0);
		S(headerRecPtr->leafRecords, 0);
		S(headerRecPtr->totalNodes, numNodesTotal);
		S(headerRecPtr->freeNodes, (numNodesTotal - numNodesUsed));
		S(headerRecPtr->maxKeyLength, (u_int16_t)kHFSPlusExtentKeyMaximumLength);
	}];
}

#pragma mark Steps

- (bool) step1_convertPreamble_error:(NSError *_Nullable *_Nullable const)outError {
	bool const succeeded = [super step1_convertPreamble_error:outError];
	_hasBootBlocks = _hasVolumeHeader = succeeded;
	return succeeded;
}

- (bool) step2_convertVolume_error:(NSError *_Nullable *_Nullable const)outError {
	NSAssert(_hasVolumeHeader, @"Conversion steps happening out of order! Cannot convert the volume without the volume header.");

	ImpSourceVolume *_Nonnull const srcVol = self.sourceVolume;
	ImpDestinationVolume *_Nonnull const dstVol = self.destinationVolume;

	NSAssert([srcVol isKindOfClass:[ImpHFSSourceVolume class]], @"ERROR: Source volume is not an HFS volume! Can't convert anything but an HFS volume yet.");
	ImpHFSSourceVolume *_Nonnull const hfsVol = (ImpHFSSourceVolume *)srcVol;
	NSAssert([dstVol isKindOfClass:[ImpHFSPlusDestinationVolume class]], @"ERROR: Destination volume is not an HFS+ volume! Can't convert to anything but an HFS+ volume yet.");
	ImpHFSPlusDestinationVolume *_Nonnull const hfsPlusVol = (ImpHFSPlusDestinationVolume *)dstVol;

	__block struct HFSExtentDescriptor const *_Nonnull catalogFileSourceExtents;
	__block struct HFSExtentDescriptor const *_Nonnull extentsOverflowFileSourceExtents;
	[hfsVol peekAtHFSVolumeHeader:^(NS_NOESCAPE const struct HFSMasterDirectoryBlock *const mdbPtr) {
		catalogFileSourceExtents = mdbPtr->drCTExtRec;
		extentsOverflowFileSourceExtents = mdbPtr->drXTExtRec;
	}];

	struct HFSPlusVolumeHeader *_Nonnull const vh = hfsPlusVol.mutableVolumeHeaderPointer;
	__block bool hasAnyFiles = false;
	__block NSUInteger numFilesCopied = 0, numFoldersCopied = 0;

	u_int64_t const volumeLengthInBytes = dstVol.lengthInBytes ?: srcVol.lengthInBytes;

	u_int32_t const bytesPerSourceABlock = (u_int32_t)srcVol.numberOfBytesPerBlock;

	u_int32_t const bytesPerABlock = L(vh->blockSize);
	u_int32_t const numBlocksInVolume = (u_int32_t)ImpCeilingDivide(volumeLengthInBytes, bytesPerABlock);
	[hfsPlusVol initializeAllocationBitmapWithBlockSize:bytesPerABlock count:numBlocksInVolume];

	//We do need to create/have an extents overflow file, even if it's empty.
	ImpBTreeFile *_Nonnull const srcExtentsOverflow = srcVol.extentsOverflowBTree;
	ImpMutableBTreeFile *_Nonnull const destExtentsOverflow = [[ImpMutableBTreeFile alloc] initWithVersion:ImpBTreeVersionHFSPlusExtentsOverflow
		bytesPerNode:[ImpBTreeFile nodeSizeForVersion:ImpBTreeVersionHFSPlusExtentsOverflow]
		nodeCount:2
		convertTree:srcExtentsOverflow];
	[self copyFromHFSExtentsOverflowFile:srcExtentsOverflow toHFSPlusExtentsOverflowFile:destExtentsOverflow];
	//Since we're not copying over anything from the original extents overflow file, deduct it from the amount of data to be copied.
	[self reportSourceExtentRecordWillNotBeCopied:extentsOverflowFileSourceExtents];

	ImpBTreeFile *_Nonnull const srcCatalog = srcVol.catalogBTree;
	ImpMutableBTreeFile *_Nonnull const destCatalog = [self convertHFSCatalogFile:srcCatalog];
	[self reportSourceExtentRecordCopied:catalogFileSourceExtents];

	//Allocate the special files before anything else, so they get placed first on the disk.
	u_int64_t const catFileLength = destCatalog.lengthInBytes;
	[hfsPlusVol allocateBytes:catFileLength forFork:ImpForkTypeSpecialFileContents populateExtentRecord:vh->catalogFile.extents];
	S(vh->catalogFile.logicalSize, catFileLength);
	S(vh->catalogFile.totalBlocks, L(vh->catalogFile.extents[0].blockCount));
	u_int64_t const extFileLength = destExtentsOverflow.lengthInBytes;
	[hfsPlusVol allocateBytes:extFileLength forFork:ImpForkTypeSpecialFileContents populateExtentRecord:vh->extentsFile.extents];
	S(vh->extentsFile.logicalSize, extFileLength);
	S(vh->extentsFile.totalBlocks, L(vh->extentsFile.extents[0].blockCount));
//	ImpPrintf(@"Catalog file will be %llu bytes in %u blocks", L(vh->catalogFile.logicalSize), L(vh->catalogFile.totalBlocks));
//	ImpPrintf(@"Extents overflow file will be %llu bytes in %u blocks", L(vh->extentsFile.logicalSize), L(vh->extentsFile.totalBlocks));

	__block bool copiedEverything = true;
	__block NSError *_Nullable conversionError = nil;
	bool const copyForkData = self.copyForkData;
	NSData *_Nullable const placeholderForkData = copyForkData ? nil : self.placeholderForkData;

	//Copy all the files over.
	[srcCatalog walkLeafNodes:^bool(ImpBTreeNode *const _Nonnull srcLeafNode) {
		__block bool keepGoing = true;
		[srcLeafNode forEachHFSCatalogRecord_file:^(const struct HFSCatalogKey *const  _Nonnull keyPtr, const struct HFSCatalogFile *const _Nonnull fileRec) {
			//Zero-initialize: if convertHFSCatalogKey:toHFSPlus: fails partway through, we must not search the catalog with a half-filled-in (garbage) key.
			struct HFSPlusCatalogKey convertedKey = { 0 };
			NSString *_Nonnull const srcFilename = [srcVol.textEncodingConverter stringForPascalString:keyPtr->nodeName fromHFSCatalogKey:keyPtr];
			if ([self convertHFSCatalogKey:keyPtr toHFSPlus:&convertedKey] == 0) {
				//We couldn't convert this file's name to Unicode (most likely the volume uses a text encoding other than the one we're decoding with), so we can't look it up in the converted catalog. Bail out rather than search with, and later dereference, an unpopulated key.
				conversionError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not convert the name of file “%@” (in parent ID %u) to Unicode. The volume may use a text encoding other than the one selected.", @"Conversion failure message"), [srcVol.textEncodingConverter stringByEscapingString:srcFilename], L(keyPtr->parentID)] }];
				copiedEverything = false;
				keepGoing = false;
				return;
			}

			struct HFSUniStr255 *_Nonnull const unicodeNamePtr = &convertedKey.nodeName;
			NSString *_Nonnull const dstFilename = [dstVol.textEncodingConverter stringFromHFSUniStr255:unicodeNamePtr];

			ImpBTreeCursor *_Nullable const cursor = [destCatalog searchCatalogTreeForItemWithParentID:convertedKey.parentID unicodeName:unicodeNamePtr];
			if (cursor == nil) {
				//The file exists in the source catalog, but we couldn't find its record in the converted catalog. Without that record we have nowhere to write the file's extents, so bail out instead of dereferencing a NULL record pointer (which previously crashed in -allocateBytes:forFork:populateExtentRecord:).
				conversionError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Could not find file “%@” in parent ID %u in the converted catalog, and thus could not copy the file's contents.", @"Conversion failure message"), [dstVol.textEncodingConverter stringByEscapingString:dstFilename], L(convertedKey.parentID)] }];
				copiedEverything = false;
				keepGoing = false;
				return;
			}
			NSMutableData *_Nonnull const convertedFileRecData = [[cursor payloadData] mutableCopy];
			struct HFSPlusCatalogFile *_Nonnull const convertedFilePtr = convertedFileRecData.mutableBytes;

			hasAnyFiles = true;
			[self deliverProgressUpdateWithOperationDescription:[NSString stringWithFormat:NSLocalizedString(@"Copying file “%@” to “%@”…", @"Conversion progress message"), [srcVol.textEncodingConverter stringByEscapingString:srcFilename], [dstVol.textEncodingConverter stringByEscapingString:dstFilename]]];

			//Copy the data fork.
			u_int64_t const dataLogicalLength = L(fileRec->dataLogicalSize);
			u_int64_t const rsrcLogicalLength = L(fileRec->rsrcLogicalSize);

			struct HFSExtentDescriptor const *_Nonnull const firstDataExtents = fileRec->dataExtents;
			struct HFSExtentDescriptor const *_Nonnull const firstRsrcExtents = fileRec->rsrcExtents;
//			ImpPrintf(@"Before copy: This file's lengths in the input volume are DF %llu bytes, RF %llu bytes. Physical sizes %u blocks + %u blocks = %u blocks", dataLogicalLength, rsrcLogicalLength, ImpNumberOfBlocksInHFSExtentRecord(firstDataExtents), ImpNumberOfBlocksInHFSExtentRecord(firstRsrcExtents), ImpNumberOfBlocksInHFSExtentRecord(firstDataExtents) + ImpNumberOfBlocksInHFSExtentRecord(firstRsrcExtents));

			//Allocate by *logical* length (rounded up to whole destination allocation blocks), not the source's physical length. The source's physical size includes slack to fill its (often much larger) allocation blocks; carrying that slack into HFS+ wastes space and can overflow the volume. HFS+ stores exactly ceil(logicalSize / blockSize) blocks per fork.
			u_int64_t bytesNotYetAllocatedForData = [hfsPlusVol allocateBytes:dataLogicalLength forFork:ImpForkTypeData populateExtentRecord:convertedFilePtr->dataFork.extents];
			//TODO: Handle bytesNotYetAllocated > 0 (by inserting the fork into the extents overflow file)
			if (bytesNotYetAllocatedForData != 0) {
				//Out of space on the destination volume. NSAssert is compiled out in Release, so without this real check the conversion would silently write a truncated/corrupt fork and still report success. Fail loudly instead.
				conversionError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Ran out of space converting the data fork of “%@”: needed %llu more bytes. The destination HFS+ volume (sized to match the source) is too small to hold the source's contents plus HFS+ metadata. This commonly happens with full or nearly-full source volumes.", @"Conversion failure message"), [dstVol.textEncodingConverter stringByEscapingString:dstFilename], bytesNotYetAllocatedForData] }];
				copiedEverything = false;
				keepGoing = false;
				return;
			}
//			ImpPrintf(@"Allocated for data fork: #%u to #%u", L(convertedFilePtr->dataFork.extents[0].startBlock), L(convertedFilePtr->dataFork.extents[0].startBlock) + L(convertedFilePtr->dataFork.extents[0].blockCount));

			NSError *_Nullable dataReadError = nil;
			__block NSError *_Nullable dataWriteError = nil;
			ImpVirtualFileHandle *_Nonnull const dataFH = [dstVol fileHandleForWritingToExtents:convertedFilePtr->dataFork.extents];
			__block u_int64_t totalDataBytesWritten = 0;
			__block u_int32_t totalDataBlocksRead = 0;
			__block u_int64_t dataLogicalRemaining = dataLogicalLength;

			[hfsVol forEachExtentInFileWithID:L(fileRec->fileID)
				fork:ImpForkTypeData
				forkLogicalLength:dataLogicalLength
				startingWithExtentsRecord:firstDataExtents
				readDataOrReturnError:&dataReadError
				block:^bool(NSData *const  _Nonnull fileData, const u_int64_t logicalLength)
			{
//				ImpPrintf(@"Read file data: %lu physical bytes (%llu length remaining)", fileData.length, logicalLength);
				NSUInteger const numBlocksThisRead = ImpCeilingDivide(fileData.length, bytesPerSourceABlock);
				totalDataBlocksRead += numBlocksThisRead;
				//Write only the logical bytes, dropping the source's allocation-block slack. The destination fork was sized to the logical length, so writing the full physical chunk would overrun it.
				NSData *_Nonnull const sourceChunk = copyForkData ? fileData : [placeholderForkData times_Imp:numBlocksThisRead];
				NSData *_Nonnull const dataToWrite = ((u_int64_t)sourceChunk.length > dataLogicalRemaining)
					? [sourceChunk subdataWithRange:(NSRange){ 0, (NSUInteger)dataLogicalRemaining }]
					: sourceChunk;
				NSInteger const bytesWrittenThisTime = [dataFH writeData:dataToWrite error:&dataWriteError];
//				ImpPrintf(@"Wrote file data: %ld bytes", (long)bytesWrittenThisTime);
				if (bytesWrittenThisTime >= 0) {
					totalDataBytesWritten += bytesWrittenThisTime;
					dataLogicalRemaining -= MIN(dataLogicalRemaining, (u_int64_t)bytesWrittenThisTime);
//					ImpPrintf(@"Total written so far: %llu bytes", totalDataBytesWritten);
					//Always report success: the read loop already stops on its own once forkLogicalLength bytes have been consumed. (Returning false here would make -forEachExtentInFileWithID: log "Consumer block consumed no bytes" and treat it as an early stop.)
					return true;
				} else {
					copiedEverything = false;
					return false;
				}
			}];
			[dataFH closeFile];

//			ImpPrintf(@"Final tally: Wrote %llu out of %llu bytes", totalDataBytesWritten, dataLogicalLength);
			NSAssert(totalDataBytesWritten == dataLogicalLength, @"Failed to %@ all data fork bytes due to %@: should have written %llu, but actually wrote %llu", dataReadError != nil ? @"read" : dataWriteError != nil ? @"write" : @"copy", dataReadError ?: dataWriteError, dataLogicalLength, totalDataBytesWritten);
			[self reportSourceBlocksCopied:totalDataBlocksRead];

			S(convertedFilePtr->dataFork.logicalSize, dataLogicalLength);
			u_int64_t const totalDataBlocks = ImpNumberOfBlocksInHFSPlusExtentRecord(convertedFilePtr->dataFork.extents);
			//TN1150 does not specify what to do if totalBlocks is greater than UINT32_MAX (which it theoretically can be, because the blockCount of each extent is also a u_int32_t and there are eight of them per extent record).
			S(convertedFilePtr->dataFork.totalBlocks, totalDataBlocks > UINT32_MAX ? UINT32_MAX : (u_int32_t)totalDataBlocks);
			//Note: clumpSize should be left 0 per TN1150.

			//Copy the resource fork.

			//Allocate by logical length (see the data-fork note above).
			u_int64_t bytesNotYetAllocatedForRsrc = [hfsPlusVol allocateBytes:rsrcLogicalLength forFork:ImpForkTypeResource populateExtentRecord:convertedFilePtr->resourceFork.extents];
			//TODO: Handle bytesNotYetAllocated > 0 (by inserting the fork into the extents overflow file)
			if (bytesNotYetAllocatedForRsrc != 0) {
				//Out of space (see the data-fork case above).
				conversionError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Ran out of space converting the resource fork of “%@”: needed %llu more bytes. The destination HFS+ volume (sized to match the source) is too small to hold the source's contents plus HFS+ metadata. This commonly happens with full or nearly-full source volumes.", @"Conversion failure message"), [dstVol.textEncodingConverter stringByEscapingString:dstFilename], bytesNotYetAllocatedForRsrc] }];
				copiedEverything = false;
				keepGoing = false;
				return;
			}
//			ImpPrintf(@"Allocated for resource fork: #%u to #%u", L(convertedFilePtr->resourceFork.extents[0].startBlock), L(convertedFilePtr->resourceFork.extents[0].startBlock) + L(convertedFilePtr->resourceFork.extents[0].blockCount));

			NSError *_Nullable rsrcReadError = nil;
			__block NSError *_Nullable rsrcWriteError = nil;
			ImpVirtualFileHandle *_Nonnull const rsrcFH = [dstVol fileHandleForWritingToExtents:convertedFilePtr->resourceFork.extents];
			__block u_int64_t totalRsrcBytesWritten = 0;
			__block u_int32_t totalRsrcBlocksRead = 0;
			__block u_int64_t rsrcLogicalRemaining = rsrcLogicalLength;

			[hfsVol forEachExtentInFileWithID:L(fileRec->fileID)
				fork:ImpForkTypeResource
				forkLogicalLength:rsrcLogicalLength
				startingWithExtentsRecord:firstRsrcExtents
				readDataOrReturnError:&rsrcReadError
				block:^bool(NSData *const  _Nonnull fileData, const u_int64_t logicalLength)
			{
				NSUInteger const numBlocksThisRead = ImpCeilingDivide(fileData.length, bytesPerSourceABlock);
				totalRsrcBlocksRead += numBlocksThisRead;
				//Write only the logical bytes (see the data-fork note above).
				NSData *_Nonnull const sourceChunk = copyForkData ? fileData : [placeholderForkData times_Imp:numBlocksThisRead];
				NSData *_Nonnull const dataToWrite = ((u_int64_t)sourceChunk.length > rsrcLogicalRemaining)
					? [sourceChunk subdataWithRange:(NSRange){ 0, (NSUInteger)rsrcLogicalRemaining }]
					: sourceChunk;
				NSInteger const bytesWrittenThisTime = [rsrcFH writeData:dataToWrite error:&rsrcWriteError];
				if (bytesWrittenThisTime >= 0) {
					totalRsrcBytesWritten += bytesWrittenThisTime;
					rsrcLogicalRemaining -= MIN(rsrcLogicalRemaining, (u_int64_t)bytesWrittenThisTime);
					//Always report success (see the data-fork note above).
					return true;
				} else {
					copiedEverything = false;
					return false;
				}
			}];
			[rsrcFH closeFile];

			NSAssert(totalRsrcBytesWritten == rsrcLogicalLength, @"Failed to %@ all resource fork bytes due to %@: should have written %llu, but actually wrote %llu", rsrcReadError != nil ? @"read" : rsrcWriteError != nil ? @"write" : @"copy", rsrcReadError ?: rsrcWriteError, rsrcLogicalLength, totalRsrcBytesWritten);

//			ImpPrintf(@"After copy: Copied %u blocks + %u blocks = %u blocks from the input volume.", totalDataBlocksRead, totalRsrcBlocksRead, totalDataBlocksRead + totalRsrcBlocksRead);
//			ImpPrintf(@"After copy: This file's lengths in the output volume are DF %llu bytes, RF %llu bytes. Physical sizes %llu blocks + %llu blocks = %llu blocks.", dataLogicalLength, rsrcLogicalLength, ImpNumberOfBlocksInHFSPlusExtentRecord(convertedFilePtr->dataFork.extents), ImpNumberOfBlocksInHFSPlusExtentRecord(convertedFilePtr->resourceFork.extents), ImpNumberOfBlocksInHFSPlusExtentRecord(convertedFilePtr->dataFork.extents) + ImpNumberOfBlocksInHFSPlusExtentRecord(convertedFilePtr->resourceFork.extents));
			[self reportSourceBlocksCopied:totalRsrcBlocksRead];

			S(convertedFilePtr->resourceFork.logicalSize, rsrcLogicalLength);
			u_int64_t const totalRsrcBlocks = ImpNumberOfBlocksInHFSPlusExtentRecord(convertedFilePtr->resourceFork.extents);
			//TN1150 does not specify what to do if totalBlocks is greater than UINT32_MAX (which it theoretically can be, because the blockCount of each extent is also a u_int32_t and there are eight of them per extent record).
			S(convertedFilePtr->resourceFork.totalBlocks, totalRsrcBlocks > UINT32_MAX ? UINT32_MAX : (u_int32_t)totalRsrcBlocks);
			//Note: clumpSize should be left 0 per TN1150.

			cursor.payloadData = convertedFileRecData;

			++numFilesCopied;
			keepGoing = true;
		}
			folder:^(const struct HFSCatalogKey *const  _Nonnull keyPtr, const struct  HFSCatalogFolder *const _Nonnull fileRec) {
			//The folder gets “copied” as part of copying the catalog, so we don't have anything to do here but bump the counter.
			++numFoldersCopied;
		}
			thread:nil
		];
		return keepGoing;
	}];

	if (conversionError != nil) {
		if (outError != NULL) {
			*outError = conversionError;
		}
		return false;
	}

	//One of the folders in the catalog is the root of the volume, which isn't counted in numberOfFolders, so decrement that back out.
	--numFoldersCopied;

	[self deliverProgressUpdateWithOperationDescription:[NSString stringWithFormat:NSLocalizedString(@"Copied %lu of %lu files and %lu of %lu folders", @"Conversion progress message"), numFilesCopied, srcVol.numberOfFiles, numFoldersCopied, srcVol.numberOfFolders]];

	bool const shouldTryToRecoverOrphanedData = true;
	NSUInteger const numOrphanedSrcBlocks = [srcVol numberOfBlocksThatAreAllocatedButHaveNotBeenAccessed];
	if (shouldTryToRecoverOrphanedData && numOrphanedSrcBlocks > 0) {
		if (numOrphanedSrcBlocks > UINT32_MAX) {
			ImpPrintf(@"Source volume somehow contains %lu orphaned blocks. That seems unlikely, and probably indicative of other problems. At any rate, will try to rescue as many blocks as possible…", numOrphanedSrcBlocks);
		} else {
			ImpPrintf(@"Source volume contains %lu orphaned blocks. Attempting to rescue them…", numOrphanedSrcBlocks);
		}
		u_int32_t const numOrphanedSrcBlocks32 = numOrphanedSrcBlocks > UINT32_MAX ? UINT32_MAX : (u_int32_t)numOrphanedSrcBlocks;
		u_int64_t const physicalLength = numOrphanedSrcBlocks32 * srcVol.numberOfBytesPerBlock;
		u_int32_t const numDstBlocks32 = (u_int32_t)physicalLength / dstVol.numberOfBytesPerBlock;

		HFSPlusExtentRecord rescuedBlocksExtents;
		struct HFSPlusExtentDescriptor const *_Nonnull const rescuedBlocksExtentsPtr = rescuedBlocksExtents;
		bool const allocatedRescuedBlocksDataFork = [hfsPlusVol allocateBlocks:numDstBlocks32 forFork:ImpForkTypeData getExtent:rescuedBlocksExtents];
		if (! allocatedRescuedBlocksDataFork) {
			ImpPrintf(@"Failed to allocate %u blocks for the rescued blocks file.", numDstBlocks32);
		} else {
			ImpVirtualFileHandle *_Nonnull const orphanedBlocksFH = [dstVol fileHandleForWritingToExtents:rescuedBlocksExtents];
			[srcVol findExtentsThatAreAllocatedButHaveNotBeenAccessed:^(NSRange const extent) {
				struct HFSExtentDescriptor orphanedExtent;
				S(orphanedExtent.startBlock, (u_int16_t)extent.location);
				S(orphanedExtent.blockCount, (u_int16_t)extent.length);
				NSData *_Nonnull const recoveredBlocks = [hfsVol readDataFromFileDescriptor:srcVol.fileDescriptor
					logicalLength:physicalLength
					extents:&orphanedExtent
					numExtents:1
					error:outError];
				[orphanedBlocksFH writeData:recoveredBlocks error:outError];
			}];
			[orphanedBlocksFH closeFile];
			//We set this extent as the data for *both* the data and resource forks, because if the recovered data is in fact a resource map (as has happened with at least one real volume!) then having it in the resource fork makes it much easier to recover it on a (real or emulated) vintage system.
			[destCatalog setExtentRecord:rescuedBlocksExtentsPtr
				forFork:ImpForkTypeData
				ofCatalogItemInParentID:kHFSRootFolderID
				withName:ImpRescuedDataFileName
				setLogicalLength:physicalLength];
			[destCatalog setExtentRecord:rescuedBlocksExtentsPtr
				forFork:ImpForkTypeResource
				ofCatalogItemInParentID:kHFSRootFolderID
				withName:ImpRescuedDataFileName
				setLogicalLength:physicalLength];
		}
	}

	[self deliverProgressUpdateWithOperationDescription:NSLocalizedString(@"Updating catalog…", @"Conversion progress message")];

	//Lastly (now that the catalog file has been populated with files' real extents), write the catalog and extents overflow files.
	//TODO: Should this be a separate step in the superclass? Maybe make the ImpMutableBTreeFiles properties?
	__block bool wroteCatalog = false;
	__block NSError *_Nullable catWriteError = nil;
	[destCatalog serializeToData:^(NSData *const  _Nonnull data) {
		ImpVirtualFileHandle *_Nonnull const catFH = [dstVol fileHandleForWritingToExtents:vh->catalogFile.extents];
		wroteCatalog = [catFH writeData:data error:&catWriteError];
		[catFH closeFile];
	}];

	__block bool wroteExtentsOverflow = false;
	__block NSError *_Nullable extWriteError = nil;
	[destExtentsOverflow serializeToData:^(NSData *const  _Nonnull data) {
		ImpVirtualFileHandle *_Nonnull const extFH = [dstVol fileHandleForWritingToExtents:vh->extentsFile.extents];
		wroteExtentsOverflow = [extFH writeData:data error:&extWriteError];
		[extFH closeFile];
	}];

	S(vh->totalBlocks, numBlocksInVolume);
	S(vh->freeBlocks, [hfsPlusVol numberOfBlocksFreeAccordingToWorkingBitmap]);
	if (! hasAnyFiles) {
		//The encodings bitmap must have 1 bit set for each encoding used by files in the volume.
		//The superclass sets this to 1 << self.hfsTextEncoding, which is correct IFF we have at least one file (we set all files to the same encoding).
		//If there are no files, then no encodings are represented, so the bitmap should be 0.
		S(vh->encodingsBitmap, 0);
	}

	copiedEverything = copiedEverything && wroteCatalog && wroteExtentsOverflow;

	[srcVol reportBlocksThatAreAllocatedButHaveNotBeenAccessed];

	return copiedEverything;
}

@end
