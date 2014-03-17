#import "ofQTKitMovieRenderer.h"
#import <Accelerate/Accelerate.h>

//secret selectors!
@interface QTMovie (QTFrom763)
- (QTTime)frameStartTime: (QTTime)atTime;
- (QTTime)frameEndTime: (QTTime)atTime;
- (QTTime)keyframeStartTime:(QTTime)atTime;
@end

//--------------------------------------------------------------
//This method is called whenever a new frame comes in from the visual context
//it's called on the back thread so locking is performed in Renderer class
static void frameAvailable(QTVisualContextRef _visualContext, const CVTimeStamp *frameTime, void *refCon)
{

	NSAutoreleasePool	*pool		= [[NSAutoreleasePool alloc] init];
	CVImageBufferRef	currentFrame;
	OSStatus			err;
	QTKitMovieRenderer		*renderer	= (QTKitMovieRenderer *)refCon;
	
	if ((err = QTVisualContextCopyImageForTime(_visualContext, NULL, frameTime, &currentFrame)) == kCVReturnSuccess) {
		[renderer frameAvailable:currentFrame];
	}
	else{
		[renderer frameFailed];
	}
	
	[pool release];
}


struct OpenGLTextureCoordinates
{
    GLfloat topLeft[2];
    GLfloat topRight[2];
    GLfloat bottomRight[2];
    GLfloat bottomLeft[2];
};

typedef struct OpenGLTextureCoordinates OpenGLTextureCoordinates;

@implementation QTKitMovieRenderer
@synthesize movieSize;
@synthesize useTexture;
@synthesize usePixels;
@synthesize useAlpha;
@synthesize frameCount;
@synthesize frameRate;
@synthesize justSetFrame;
@synthesize synchronousSeek;
@synthesize mAudioSampleRate;


- (NSDictionary*) pixelBufferAttributes
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
            //if we have a texture, make the pixel buffer OpenGL compatible
            [NSNumber numberWithBool:self.useTexture], (NSString*)kCVPixelBufferOpenGLCompatibilityKey, 
            [NSNumber numberWithInt:kCVPixelFormatType_32ARGB], (NSString*)kCVPixelBufferPixelFormatTypeKey,
            nil];
}

- (BOOL) loadMovie:(NSString*)moviePath pathIsURL:(BOOL)isURL allowTexture:(BOOL)doUseTexture allowPixels:(BOOL)doUsePixels allowAlpha:(BOOL)doUseAlpha
{
    // if the path is local, make sure the file exists before proceeding
    if (!isURL && ![[NSFileManager defaultManager] fileExistsAtPath:moviePath])
    {
		NSLog(@"No movie file found at %@", moviePath);
		return NO;
	}
	
	//create visual context
	useTexture = doUseTexture;
	usePixels = doUsePixels;
	useAlpha = doUseAlpha;
    

    // build the movie URL
    NSString *movieURL;
    if (isURL) {
        movieURL = [NSURL URLWithString:moviePath];
    }
    else {
        movieURL = [NSURL fileURLWithPath:[moviePath stringByStandardizingPath]];
    }

	NSError* error;
	NSMutableDictionary* movieAttributes = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                            movieURL, QTMovieURLAttribute,
                                            [NSNumber numberWithBool:NO], QTMovieOpenAsyncOKAttribute,
                                            nil];
    
	_movie = [[QTMovie alloc] initWithAttributes:movieAttributes 
										   error: &error];
	
	if(error || _movie == NULL){
		NSLog(@"Error Loading Movie: %@", error);
		return NO;
	}
    lastMovieTime = QTMakeTime(0,1);
	movieSize = [[_movie attributeForKey:QTMovieNaturalSizeAttribute] sizeValue];
    //	NSLog(@"movie size %f %f", movieSize.width, movieSize.height);
	
	movieDuration = [_movie duration];
    
	[_movie gotoBeginning];
    
    [_movie gotoEnd];
    QTTime endTime = [_movie currentTime];
    
    [_movie gotoBeginning];
    QTTime curTime = [_movie currentTime];
    
    long numFrames = 0;
	NSMutableArray* timeValues = [NSMutableArray array];
    while(true) {
        //        % get the end time of the current frame
		[timeValues addObject:[NSNumber numberWithLongLong:curTime.timeValue]];

        curTime = [_movie frameEndTime:curTime];
        numFrames++;
        int time = curTime.timeValue;
        //NSLog(@" num frames %ld, %lld/%ld , dif %lld, current time %f", numFrames,curTime.timeValue,curTime.timeScale, curTime.timeValue - time, 1.0*curTime.timeValue/curTime.timeScale);
        if (QTTimeCompare(curTime, endTime) == NSOrderedSame ||
            QTTimeCompare(curTime, [_movie frameEndTime:curTime])  == NSOrderedSame ){ //this will happen for audio files since they have no frames.
            break;
        }
    }
    
	if(frameTimeValues != NULL){
		[frameTimeValues release];
	}
	frameTimeValues = [[NSArray arrayWithArray:timeValues] retain];
	
	frameCount = numFrames;
	frameStep = round((double)(movieDuration.timeValue)/(double)numFrames);
    frameRate = round((double)numFrames)/((double)(movieDuration.timeValue/movieDuration.timeScale));

	NSLog(@" movie has %d frames and frame step %f and frame rate %f", frameCount, frameStep, frameRate);
	
	//if we are using pixels, make the visual context
	//a pixel buffer context with ARGB textures
	if(self.usePixels){
		
		NSMutableDictionary *ctxAttributes = [NSMutableDictionary dictionaryWithObject:[self pixelBufferAttributes]
																				forKey:(NSString*)kQTVisualContextPixelBufferAttributesKey];
		
		OSStatus err = QTPixelBufferContextCreate(kCFAllocatorDefault, (CFDictionaryRef)ctxAttributes, &_visualContext);
		if(err){
			NSLog(@"error %ld creating OpenPixelBufferContext", err);
			return NO;
		}
        
		// if we also have a texture, create a texture cache for it
		if(self.useTexture){
			//create a texture cache			
			err = CVOpenGLTextureCacheCreate(kCFAllocatorDefault, NULL, 
											 CGLGetCurrentContext(), CGLGetPixelFormat(CGLGetCurrentContext()), 
											 (CFDictionaryRef)ctxAttributes, &_textureCache);
			if(err){
				NSLog(@"error %ld creating CVOpenGLTextureCacheCreate", err);
				return NO;
			}
		}
	}
	//if we are using a texture, just create an OpenGL visual context 
	else if(self.useTexture){
		OSStatus err = QTOpenGLTextureContextCreate(kCFAllocatorDefault,
													CGLGetCurrentContext(), CGLGetPixelFormat(CGLGetCurrentContext()),
													(CFDictionaryRef)NULL, &_visualContext);	
		if(err){
			NSLog(@"error %ld creating QTOpenGLTextureContextCreate", err);
			return NO;
		}
	}
	else {
		NSLog(@"Error - QTKitMovieRenderer - Must specify either Pixels or Texture as rendering strategy");
		return NO;
	}
	
	[_movie setVisualContext:_visualContext];
	
	QTVisualContextSetImageAvailableCallback(_visualContext, frameAvailable, self);
	synchronousSeekLock = [[NSCondition alloc] init];
	
	//borrowed from WebCore:
	// http://opensource.apple.com/source/WebCore/WebCore-1298/platform/graphics/win/QTMovie.cpp
	hasVideo = (NULL != GetMovieIndTrackType([_movie quickTimeMovie], 1, VisualMediaCharacteristic, movieTrackCharacteristic | movieTrackEnabledOnly));
	hasAudio = (NULL != GetMovieIndTrackType([_movie quickTimeMovie], 1, AudioMediaCharacteristic,  movieTrackCharacteristic | movieTrackEnabledOnly));
	NSLog(@"has video? %@ has audio? %@", (hasVideo ? @"YES" : @"NO"), (hasAudio ? @"YES" : @"NO") );
	loadedFirstFrame = NO;
	self.volume = 1.0;
	self.loops = YES;
    self.palindrome = NO;

    if (hasAudio) {
        
        mAudioBufList = NULL;
        [self configureExtractionSessionWithMovie:[_movie quickTimeMovie]];
        
        NSLog(@"Setting up audio export...");
    }
    
    //synchronousSeek = false;
    
    
	return YES;
}

- (void) dealloc
{
	@synchronized(self){
		
		if(_visualContext != NULL){
			QTVisualContextSetImageAvailableCallback(_visualContext, NULL, NULL);
		}

		if(_latestTextureFrame != NULL){
			CVOpenGLTextureRelease(_latestTextureFrame);
			_latestTextureFrame = NULL;
		}
		
		if(_latestPixelFrame != NULL){
			CVPixelBufferRelease(_latestPixelFrame);
			_latestPixelFrame = NULL;
		}
		
		if(_movie != NULL){
			[_movie release];
			_movie = NULL;
		}
		
		if(_visualContext != NULL){
			QTVisualContextRelease(_visualContext);
			_visualContext = NULL;
		}
		
		if(_textureCache != NULL){
			CVOpenGLTextureCacheRelease(_textureCache);
			_textureCache = NULL;
		}
		
		if(frameTimeValues != NULL){
			[frameTimeValues release];
			frameTimeValues = NULL;
		}
        
        if (mAudioExtractionSession){
            MovieAudioExtractionEnd(mAudioExtractionSession);
        }
        
        if (mExtractionLayoutPtr) {
            free(mExtractionLayoutPtr);
        }
        
		
		if(synchronousSeekLock != nil){
			[synchronousSeekLock release];
			synchronousSeekLock = nil;
		}
	}
	[super dealloc];
}

//JG Note, in the OF wrapper this does not get used since we have a modified ofTexture that we use to draw
//this is here in case you want to use this renderer outside of openFrameworks
- (void) draw:(NSRect)drawRect
{   
	
	if(!self.useTexture || _latestTextureFrame == NULL){
		return;
	}
	
	OpenGLTextureCoordinates texCoords;	
	
	CVOpenGLTextureGetCleanTexCoords(_latestTextureFrame, 
									 texCoords.bottomLeft, 
									 texCoords.bottomRight, 
									 texCoords.topRight, 
									 texCoords.topLeft);        
	
	[self bindTexture];
	
	glBegin(GL_QUADS);
	
	glTexCoord2fv(texCoords.topLeft);
	glVertex2f(NSMinX(drawRect), NSMinY(drawRect));
	
	glTexCoord2fv(texCoords.topRight);
	glVertex2f(NSMaxX(drawRect), NSMinY(drawRect));
	
	glTexCoord2fv(texCoords.bottomRight);
	glVertex2f(NSMaxX(drawRect), NSMaxY(drawRect));
	
	glTexCoord2fv(texCoords.bottomLeft);
	glVertex2f(NSMinX(drawRect), NSMaxY(drawRect));
	
	glEnd();
	
	[self unbindTexture];
	
}

- (void)frameAvailable:(CVImageBufferRef)image
{

	@synchronized(self){
		
		if(_visualContext == NULL){
			return;
		}

		if(self.usePixels){
			if(_latestPixelFrame != NULL){
				CVPixelBufferRelease(_latestPixelFrame);
				_latestPixelFrame = NULL;
			}
			_latestPixelFrame = image;
			
			//if we are using a texture, create one from the texture cache
			if(self.useTexture){
				if(_latestTextureFrame != NULL){
					CVOpenGLTextureRelease(_latestTextureFrame);
					_latestTextureFrame = NULL;
					CVOpenGLTextureCacheFlush(_textureCache, 0);
				}
				
				OSErr err = CVOpenGLTextureCacheCreateTextureFromImage(NULL, _textureCache, _latestPixelFrame, NULL, &_latestTextureFrame);
				
				if(err != noErr){
					NSLog(@"Error creating OpenGL texture %d", err);
				}
			}
		}
		//just get the texture
		else if(self.useTexture){
			if(_latestTextureFrame != NULL){
				CVOpenGLTextureRelease(_latestTextureFrame);
				_latestTextureFrame = NULL;
			}
			_latestTextureFrame = image;
		}
		frameIsNew = YES;	
	}

//	NSLog(@"incoming frame time: %lld/%ld and movie time is %lld", correctedFrameTime.timeValue, correctedFrameTime.timeScale, self.timeValue);

//	lastMovieTime = (1.0*frameTime.timeValue)/frameTime.timeScale;
//	lastMovieTime = frameTime;
	if(self.justSetFrame){
		CVAttachmentMode mode = kCVAttachmentMode_ShouldPropagate;
		NSDictionary* timeDictionary = (NSDictionary*)CVBufferGetAttachment (image, kCVBufferMovieTimeKey, &mode);
		QTTime frameTime = QTMakeTime([[timeDictionary valueForKey:@"TimeValue"] longLongValue],
									  [[timeDictionary valueForKey:@"TimeScale"] longValue]);
		//
		QTTime correctedFrameTime = [_movie frameEndTime:frameTime];
		//Incoming frames will often be earlier times than requested. So we have to signal
		//the waiting thread to try the MovieTask() again to get another frame.
		//sometimes timestamps don't contain data, we have no choice but to assume it's the right frame
		if(correctedFrameTime.timeValue >= self.timeValue || frameTime.timeValue == 0){
//			NSLog(@"Time is good ");
			justSetFrame = NO;
		}
		//signal to the waiting thread that the pixels are updated
		[synchronousSeekLock lock];
		[synchronousSeekLock signal];
		[synchronousSeekLock unlock];
	}

	QTVisualContextTask(_visualContext);
}

- (void)frameFailed
{
	NSLog(@"QTRenderer -- Error failed to get frame on callback");
}

- (BOOL) update
{
   	BOOL newFrame = frameIsNew;
	frameIsNew = false;
	return newFrame;

}

- (void) stepForward
{
    if(_movie){
		self.justSetFrame = YES;
        [_movie stepForward];
		[self synchronizeSeek];
    }
}

- (void) stepBackward
{
    if(_movie){
		self.justSetFrame = YES;
        [_movie stepBackward];
		[self synchronizeSeek];
    }
}

- (void) gotoBeginning
{
	if(_movie){
		self.justSetFrame = YES;
    	[_movie gotoBeginning];
		[self synchronizeSeek];
    }
}

//writes out the pixels in RGB or RGBA format to outbuf
- (void) pixels:(unsigned char*) outbuf
{
	@synchronized(self){
		if(!self.usePixels || _latestPixelFrame == NULL){
			return;
		}
		
	//    NSLog(@"pixel buffer width is %ld height %ld and bpr %ld, movie size is %d x %d ",
	//          CVPixelBufferGetWidth(_latestPixelFrame),
	//          CVPixelBufferGetHeight(_latestPixelFrame), 
	//          CVPixelBufferGetBytesPerRow(_latestPixelFrame),
	//          (NSInteger)movieSize.width, (NSInteger)movieSize.height);
		if((NSInteger)movieSize.width != CVPixelBufferGetWidth(_latestPixelFrame) ||
		   (NSInteger)movieSize.height != CVPixelBufferGetHeight(_latestPixelFrame)){
			NSLog(@"CoreVideo pixel buffer is %ld x %ld while QTKit Movie reports size of %d x %d. This is most likely caused by a non-square pixel video format such as HDV. Open this video in texture only mode to view it at the appropriate size",
				  CVPixelBufferGetWidth(_latestPixelFrame), CVPixelBufferGetHeight(_latestPixelFrame), (NSInteger)movieSize.width, (NSInteger)movieSize.height);
			return;
		}
		
		if(CVPixelBufferGetPixelFormatType(_latestPixelFrame) != kCVPixelFormatType_32ARGB){
			NSLog(@"QTKitMovieRenderer - Frame pixelformat not kCVPixelFormatType_32ARGB: %d, instead %ld",kCVPixelFormatType_32ARGB,CVPixelBufferGetPixelFormatType(_latestPixelFrame));
			return;
		}
		
		CVPixelBufferLockBaseAddress(_latestPixelFrame, kCVPixelBufferLock_ReadOnly);
		//If we are using alpha, the ofQTKitPlayer class will have allocated a buffer of size
		//movieSize.width * movieSize.height * 4
		//CoreVideo creates alpha video in the format ARGB, and openFrameworks expects RGBA,
		//so we need to swap the alpha around using a vImage permutation
		vImage_Buffer src = {
			CVPixelBufferGetBaseAddress(_latestPixelFrame),
			CVPixelBufferGetHeight(_latestPixelFrame),
			CVPixelBufferGetWidth(_latestPixelFrame),
			CVPixelBufferGetBytesPerRow(_latestPixelFrame)
		};
		vImage_Error err;
		if(self.useAlpha){
			vImage_Buffer dest = { outbuf, movieSize.height, movieSize.width, movieSize.width*4 };
			uint8_t permuteMap[4] = { 1, 2, 3, 0 }; //swizzle the alpha around to the end to make ARGB -> RGBA
			err = vImagePermuteChannels_ARGB8888(&src, &dest, permuteMap, 0);
		}
		//If we are are doing RGB then ofQTKitPlayer will have created a buffer of size movieSize.width * movieSize.height * 3
		//so we use vImage to copy them int the out buffer
		else {
			vImage_Buffer dest = { outbuf, movieSize.height, movieSize.width, movieSize.width*3 };
			err = vImageConvert_ARGB8888toRGB888(&src, &dest, 0);
// NO LONGER USED: keep for reference
// was needed when requesting RGB buffers straight from QTKit, but this resulted in strange behavior in many cases
//			else{
//				//This branch is not intended to be used anymore as we will use vImage all the time, getting only ARGB frames
//				if (CVPixelBufferGetPixelFormatType(_latestPixelFrame) != kCVPixelFormatType_24RGB){
//					NSLog(@"QTKitMovieRenderer - Frame pixelformat not kCVPixelFormatType_24RGB: %d, instead %ld",kCVPixelFormatType_24RGB,CVPixelBufferGetPixelFormatType(_latestPixelFrame));
//				}
//				size_t dstBytesPerRow = movieSize.width * 3;
//				if (CVPixelBufferGetBytesPerRow(_latestPixelFrame) == dstBytesPerRow) {
//					memcpy(outbuf, CVPixelBufferGetBaseAddress(_latestPixelFrame), dstBytesPerRow*CVPixelBufferGetHeight(_latestPixelFrame));
//				}
//				else {
//					unsigned char *dst = outbuf;
//					unsigned char *src = (unsigned char*)CVPixelBufferGetBaseAddress(_latestPixelFrame);
//					size_t srcBytesPerRow = CVPixelBufferGetBytesPerRow(_latestPixelFrame);
//					size_t copyBytesPerRow = MIN(dstBytesPerRow, srcBytesPerRow); // should always be dstBytesPerRow but be safe
//					int y;
//					for(y = 0; y < movieSize.height; y++){
//						memcpy(dst, src, copyBytesPerRow);
//						dst += dstBytesPerRow;
//						src += srcBytesPerRow;
//					}
//				}
//			}
		}
		
		CVPixelBufferUnlockBaseAddress(_latestPixelFrame, kCVPixelBufferLock_ReadOnly);
		
		if(err != kvImageNoError){
			NSLog(@"Error in Pixel Copy vImage_error %ld", err);
		}
		
	}
}

- (BOOL) textureAllocated
{
	return self.useTexture && _latestTextureFrame != NULL;
}

- (GLuint) textureID
{
	@synchronized(self){
		return CVOpenGLTextureGetName(_latestTextureFrame);
	}
}

- (GLenum) textureTarget
{
	return CVOpenGLTextureGetTarget(_latestTextureFrame);
}

- (void) bindTexture
{
	if(!self.textureAllocated) return;
    
	GLuint texID = 0;
	texID = CVOpenGLTextureGetName(_latestTextureFrame);
	
	GLenum target = GL_TEXTURE_RECTANGLE_ARB;
	target = CVOpenGLTextureGetTarget(_latestTextureFrame);
	
	glEnable(target);
	glBindTexture(target, texID);
	
}

- (void) unbindTexture
{
	if(!self.textureAllocated) return;
	
	GLenum target = GL_TEXTURE_RECTANGLE_ARB;
	target = CVOpenGLTextureGetTarget(_latestTextureFrame);
	glDisable(target);	
}

- (void) setRate:(float) rate
{
	if(self.synchronousSeek && self.justSetFrame){
		//in case we are in the middle of waiting for an update signal that thread to end
		[synchronousSeekLock lock];
		self.justSetFrame = NO;
		[synchronousSeekLock signal];
		[synchronousSeekLock unlock];
	}
	[_movie setRate:rate];
}

- (float) rate
{
	return _movie.rate;
}

- (void) setVolume:(float) volume
{
	[_movie setVolume:volume];
}

- (float) volume
{
	return [_movie volume];
}

- (void) setBalance:(float) balance
{
    SetMovieAudioBalance([_movie quickTimeMovie], balance, 0);
}

- (void) setPosition:(CGFloat) position
{
	float oldRate = self.rate;
	if(self.rate != 0){
		_movie.rate = 0;
	}

    QTTime t = QTMakeTime(position*movieDuration.timeValue, movieDuration.timeScale);
	QTTime startTime =[_movie frameStartTime:t];
//	QTTime endTime =[_movie frameEndTime:t];
	if(QTTimeCompare(startTime, _movie.currentTime) != NSOrderedSame){
		_movie.currentTime = startTime;
		[self synchronizeSeek];
	}
	
	if(oldRate != 0){
		self.rate = oldRate;
	}
	
}

- (void) setFrame:(NSInteger) frame
{
	float oldRate = self.rate;
	if(self.rate != 0){
		_movie.rate = 0;
	}
	//QTTime t = QTMakeTime(frame*frameStep, movieDuration.timeScale);
	QTTime t = QTMakeTime([[frameTimeValues objectAtIndex:frame%frameTimeValues.count] longLongValue], movieDuration.timeScale);
	QTTime startTime =[_movie frameStartTime:t];
	QTTime endTime =[_movie frameEndTime:t];
	//NSLog(@"calculated frame time %lld, frame start end [%lld, %lld]", t.timeValue, startTime.timeValue, endTime.timeValue);
	if(QTTimeCompare(startTime, _movie.currentTime) != NSOrderedSame){
		self.justSetFrame = YES;
		_movie.currentTime = startTime;
		//NSLog(@"set time to %f", 1.0*_movie.currentTime.timeValue / _movie.currentTime.timeScale);
        //NSLog(@"nsorderedsame calculated frame time %lld, frame start end [%lld, %lld]", t.timeValue, startTime.timeValue, endTime.timeValue);
		[self synchronizeSeek];
	}

	if(oldRate != 0){
		self.rate = oldRate;
	}
}

- (CGFloat) position
{
//	return 1.0*lastMovieTime.timeValue / movieDuration.timeValue;
	return 1.0*_movie.currentTime.timeValue / movieDuration.timeValue;
}

- (CGFloat) time
{
	//return lastMovieTime;
	//return 1.0*lastMovieTime.timeValue / lastMovieTime.timeScale;
	return _movie.currentTime.timeValue / movieDuration.timeScale;
}

//internal
- (long long) timeValue
{
	return _movie.currentTime.timeValue;
}

//This thread will guarantee that the current frame is in memory
//before proceeding. If something goes weird, it has 1.0 second timeout
//that it will print a warning and proceed.
//It works by blocking with a condition, which is signaled
//in the frameAvailable callback when the time matches the requested time
- (void) synchronizeSeek
{
	if(!self.synchronousSeek || !hasVideo){
		self.justSetFrame = NO;
		return;
	}
	
//	NSLog(@" current time %lld vs duration %lld", _movie.currentTime.timeValue, movieDuration.timeValue);
	//if requesting the last frame, don't synchronize update
	if(_movie.currentTime.timeValue == movieDuration.timeValue){
		self.justSetFrame = NO;
		return;
	}

	//no synchronous seeking for images or audio files!
	//except on the first frame.
	if(self.frameCount < 2 && loadedFirstFrame){
		self.justSetFrame = NO;
		return;		
	}

	int numTries = 0;
	while(self.justSetFrame && numTries++ < 10){
		[synchronousSeekLock lock];
		
		QTVisualContextTask(_visualContext);
		MoviesTask([_movie quickTimeMovie], 0);
		
		if(![synchronousSeekLock waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]]){
			NSLog(@"synchronizeUpdate timed out in QTMovieRenderer");
			self.justSetFrame = NO;
		}
		
		[synchronousSeekLock unlock];
	}
	loadedFirstFrame = true;
}

//complicated!!! =( Do a search through the frame time values
//to find the index of the current time, then return that index
// http://stackoverflow.com/questions/3995949/how-to-write-objective-c-blocks-inline
- (NSInteger) frame
{
	return [frameTimeValues indexOfObject:[NSNumber numberWithLongLong:_movie.currentTime.timeValue]
							inSortedRange:NSMakeRange(0, frameTimeValues.count)
								  options:NSBinarySearchingInsertionIndex
						  usingComparator:^(id lhs, id rhs) {
							  if ([lhs longLongValue] < [rhs longLongValue])
								  return (NSComparisonResult)NSOrderedAscending;
							  else if([lhs longLongValue] > [rhs longLongValue])
								  return (NSComparisonResult)NSOrderedDescending;
							  return (NSComparisonResult)NSOrderedSame;
						  }];
}

- (NSTimeInterval) duration
{
	return 1.0*movieDuration.timeValue / movieDuration.timeScale;
}

- (void) setLoops:(BOOL)loops
{
	[_movie setAttribute:[NSNumber numberWithBool:loops] 
				  forKey:QTMovieLoopsAttribute];
}

- (BOOL) loops
{
	return [[_movie attributeForKey:QTMovieLoopsAttribute] boolValue];
}

- (void) setPalindrome:(BOOL)palindrome
{
	[_movie setAttribute:[NSNumber numberWithBool:palindrome]
				  forKey:QTMovieLoopsBackAndForthAttribute];
}

- (BOOL) palindrome
{
	return [[_movie attributeForKey:QTMovieLoopsBackAndForthAttribute] boolValue];
}

- (BOOL) isFinished
{
	return !self.loops && !self.palindrome && _movie.currentTime.timeValue == movieDuration.timeValue;
}


/*!
 @method
 @abstract   Calcurate exporting movie duration (in Sec.)
 @discussion
 calculate the duration of the longest audio track in the movie
 if the audio tracks end at time N and the movie is much
 longer we don't want to keep extracting - the API will happily
 return zeroes until it reaches the movie duration
 */
-(void)setMovieExtractionDuration
{
    TimeValue maxDuration = 0;
    UInt8 i;
    
    SInt32 trackCount = GetMovieTrackCount([_movie quickTimeMovie]);
    
    if (trackCount) {
        for (i = 1; i < trackCount + 1; i++) {
            Track aTrack = GetMovieIndTrackType([_movie quickTimeMovie],
                                                i,
                                                SoundMediaType,
                                                movieTrackMediaType);
            if (aTrack) {
                TimeValue aDuration = GetTrackDuration(aTrack);
                mAudioTimeScale = GetMediaTimeScale(GetTrackMedia(aTrack));
                
                if (aDuration > maxDuration) maxDuration = aDuration;
            }
        }
        
        mMovieDuration = (Float64)maxDuration / (Float64)GetMovieTimeScale([_movie quickTimeMovie]);
    }
}



/*!
 @method
 @abstract   Get default extraction layout
 @discussion
 get the default extraction layout for this movie, expanded into individual channel descriptions
 
 @discussion
 The channel layout returned by this routine must be deallocated by the client
 If 'asbd' is non-NULL, fill it with the default extraction asbd, which contains the
 highest sample rate among the sound tracks that will be contributing.
 'outLayoutSize' and 'asbd' may be nil.
 */
- (OSStatus)getDefaultExtractionInfo
{
    OSStatus err;
    
    // get the size of the extraction output layout
    err = MovieAudioExtractionGetPropertyInfo(mAudioExtractionSession,
                                              kQTPropertyClass_MovieAudioExtraction_Audio,
                                              kQTMovieAudioExtractionAudioPropertyID_AudioChannelLayout,
                                              NULL,
                                              &mExtractionLayoutSize,
                                              NULL);
    if (err) goto bail;
    
    // allocate memory for the layout
    mExtractionLayoutPtr = (AudioChannelLayout *)calloc(1, mExtractionLayoutSize);
    if (NULL == mExtractionLayoutPtr)  { err = memFullErr; goto bail; }
    
    // get the layout for the current extraction configuration
    err = MovieAudioExtractionGetProperty(mAudioExtractionSession,
                                          kQTPropertyClass_MovieAudioExtraction_Audio,
                                          kQTMovieAudioExtractionAudioPropertyID_AudioChannelLayout,
                                          mExtractionLayoutSize,
                                          mExtractionLayoutPtr,
                                          NULL);
    if (err) {
        goto bail;
    }
    // get the audio stream basic description
    err = MovieAudioExtractionGetProperty(mAudioExtractionSession,
                                          kQTPropertyClass_MovieAudioExtraction_Audio,
                                          kQTMovieAudioExtractionAudioPropertyID_AudioStreamBasicDescription,
                                          sizeof(AudioStreamBasicDescription),
                                          &mSourceASBD,
                                          NULL);
    
bail:
    return err;
}


/*!
 @method
 @abstract   Sets up extraction settings
 @discussion
 This method prepare the specified movie for extraction by opening an extraction session, configuring
 and setting the output ASBD and the output layout if one exists - it also sets the start time to 0
 and calculates the total number of samples to export
 */
- (OSStatus) configureExtractionSessionWithMovie:(Movie)inMovie
{
    OSStatus err;
    
    // open a movie audio extraction session
    err = MovieAudioExtractionBegin(inMovie, 0, &mAudioExtractionSession);
    if (err) goto bail;
    
    err = [self getDefaultExtractionInfo];
    if (err) goto bail;
    
    /*
     Setting up extraction format.
     
     set the output ASBD to 16-bit interleaved PCM big-endian integers
     we start with the default ASBD which has set the sample rate to the
     highest rate among all audio tracks
     */
    // lazy hack: set the movie time scale to same as the sample rate, to allow for easy seeking
    SetMovieTimeScale([_movie quickTimeMovie], (TimeScale)mSourceASBD.mSampleRate);
    mAudioSampleRate = mSourceASBD.mSampleRate;
    
    [self setMovieExtractionDuration];
    
    mOutputASBD = mSourceASBD;
    
    mOutputASBD.mFormatID                   = kAudioFormatLinearPCM;
    mOutputASBD.mFormatFlags                = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked;
    //mOutputASBD.mFormatFlags                = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    mOutputASBD.mFramesPerPacket            = 1;
    mOutputASBD.mBitsPerChannel             = sizeof(int16_t) * 8;
    mOutputASBD.mBytesPerFrame              = mSourceASBD.mChannelsPerFrame * sizeof(int16_t);
    mOutputASBD.mBytesPerPacket             = mOutputASBD.mBytesPerFrame;
    mOutputASBD.mChannelsPerFrame           = mSourceASBD.mChannelsPerFrame;
    
    NSLog(@"   format flags   = %d",(unsigned int)mSourceASBD.mFormatFlags);
    NSLog(@"   sample rate    = %f",mSourceASBD.mSampleRate);
    NSLog(@"   b/packet       = %d",(unsigned int)mSourceASBD.mBytesPerPacket);
    NSLog(@"   f/packet       = %d",(unsigned int)mSourceASBD.mFramesPerPacket);
    NSLog(@"   b/frame        = %d",(unsigned int)mSourceASBD.mBytesPerFrame);
    NSLog(@"   channels/frame = %d",(unsigned int)mSourceASBD.mChannelsPerFrame);
    NSLog(@"   b/channel      = %d",(unsigned int)mSourceASBD.mBitsPerChannel);
    
    NSLog(@"   format flags   = %d",(unsigned int)mOutputASBD.mFormatFlags);
    NSLog(@"   sample rate    = %f",mOutputASBD.mSampleRate);
    NSLog(@"   b/packet       = %d",(unsigned int)mOutputASBD.mBytesPerPacket);
    NSLog(@"   f/packet       = %d",(unsigned int)mOutputASBD.mFramesPerPacket);
    NSLog(@"   b/frame        = %d",(unsigned int)mOutputASBD.mBytesPerFrame);
    NSLog(@"   channels/frame = %d",(unsigned int)mOutputASBD.mChannelsPerFrame);
    NSLog(@"   b/channel      = %d",(unsigned int)mOutputASBD.mBitsPerChannel);
    
    // set the extraction ASBD
    err = MovieAudioExtractionSetProperty(mAudioExtractionSession,
                                          kQTPropertyClass_MovieAudioExtraction_Audio,
                                          kQTMovieAudioExtractionAudioPropertyID_AudioStreamBasicDescription,
                                          sizeof(mOutputASBD),
                                          &mOutputASBD);
    if (err) {
        goto bail;
    }
    
    
    //mExtractionLayoutPtr->mChannelLayoutTag             = kAudioChannelLayoutTag_Mono;
    //mExtractionLayoutPtr->mChannelBitmap                = 0;
    //mExtractionLayoutPtr->mNumberChannelDescriptions    = 0;
    
    // set the output layout
    if (mExtractionLayoutPtr) {
        err = MovieAudioExtractionSetProperty(mAudioExtractionSession,
                                              kQTPropertyClass_MovieAudioExtraction_Audio,
                                              kQTMovieAudioExtractionAudioPropertyID_AudioChannelLayout,
                                              mExtractionLayoutSize,
                                              mExtractionLayoutPtr);
        if (err) {
            goto bail;
        }
    }
    
    
    // set the extraction start time - we always start at zero, but you don't have to
    TimeRecord startTime = { 0, 0, GetMovieTimeScale(inMovie), GetMovieTimeBase(inMovie) };
    
    err = MovieAudioExtractionSetProperty(mAudioExtractionSession,
                                          kQTPropertyClass_MovieAudioExtraction_Movie,
                                          kQTMovieAudioExtractionMoviePropertyID_CurrentTime,
                                          sizeof(TimeRecord), &startTime);
    if (err) {
        goto bail;
    }
    
    
    // set the number of total samples to export
    mSamplesRemaining = mMovieDuration ? (mMovieDuration * mOutputASBD.mSampleRate) : -1;
    mTotalNumberOfSamples = mSamplesRemaining;
bail:
    return err;
}

- (void) GetAudioBuf:(void *)buf start:(int64_t) start count:(int64_t) count
{
    
    OSStatus err;
    
    TimeRecord trec;
    trec.scale              = GetMovieTimeScale([_movie quickTimeMovie]);
    trec.base               = NULL;
    trec.value.hi   = (int32_t)(start >> 32);
    trec.value.lo   = (int32_t)((start & 0xFFFFFFFF00000000ULL) >> 32);

    err = MovieAudioExtractionSetProperty(mAudioExtractionSession, kQTPropertyClass_MovieAudioExtraction_Movie, kQTMovieAudioExtractionMoviePropertyID_CurrentTime, sizeof(TimeRecord), &trec);
    if (err) {
        NSLog(@"  Error #: %d",(int)err);
        printf("  QuickTime audio provider: Failed to seek in file \n");
    }

    // FIXME: hack something up to actually handle very big counts correctly,
    // maybe with multiple buffers?
    AudioBufferList dst_buflist;
    dst_buflist.mNumberBuffers = 1;
    dst_buflist.mBuffers[0].mNumberChannels = mOutputASBD.mChannelsPerFrame;
    dst_buflist.mBuffers[0].mDataByteSize   = count * mOutputASBD.mBytesPerFrame;
    dst_buflist.mBuffers[0].mData           = buf;

    UInt32 flags;
    UInt32 decode_count = (UInt32)count;
    err = MovieAudioExtractionFillBuffer(mAudioExtractionSession, &decode_count, &dst_buflist, &flags);
    //QTCheckError(qt_status, wxString(_T("QuickTime audio provider: Failed to decode audio")));
    printf("QuickTime audio provider: Failed to decode audio \n");

    if (count != decode_count)
        printf("QuickTime audio provider: GetAudio: Warning: decoded samplecount %d not same as requested count %d \n", (uint32_t)decode_count, (uint32_t)count);
}

- (UInt32) GetAudioBufNumSamples
{
    QTTime t = QTMakeTime([[frameTimeValues objectAtIndex:1%frameTimeValues.count] longLongValue], movieDuration.timeScale);
    TimeRecord trec;
    QTGetTimeRecord(t, &trec);
    
    //NSLog(@"%lu",(UInt32)([_movie frameEndTime:t].timeValue - [_movie frameStartTime:t].timeValue) * mOutputASBD.mBytesPerFrame);
    
    return (UInt32)([_movie frameEndTime:t].timeValue - [_movie frameStartTime:t].timeValue) * mOutputASBD.mBytesPerFrame;
}

- (CMSampleBufferRef) GetAudioCMSampleBuf:(int64_t) start
{
    
    AudioBufferList* bufList = [self GetAudioBufList:start];
    
    
    CMSampleBufferRef buff = NULL;
    CMFormatDescriptionRef format = NULL;
    OSStatus error = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &mOutputASBD, 0, NULL, 0, NULL, NULL, &format);
    
    NSLog(@"Sample Rate: %f", mOutputASBD.mSampleRate);
    
    CMSampleTimingInfo timing = { CMTimeMake(1, mOutputASBD.mSampleRate), kCMTimeZero, kCMTimeInvalid };
    error = CMSampleBufferCreate(kCFAllocatorDefault, NULL, false, NULL, NULL, format, bufList->mBuffers[0].mDataByteSize, 1, &timing, 0, NULL, &buff);
    if ( error ) { NSLog(@"CMSampleBufferCreate returned error: %ld", error); }
    
    error = CMSampleBufferSetDataBufferFromAudioBufferList(buff, kCFAllocatorDefault, kCFAllocatorDefault, 0, bufList);
    if ( error ) { NSLog(@"CMSampleBufferSetDataBufferFromAudioBufferList returned error: %ld", error); }

    return buff;
}


- (AudioBufferList*) GetAudioBufList:(int64_t) start count:(int64_t)count
{
    QTTime t = QTMakeTime([[frameTimeValues objectAtIndex:start%frameTimeValues.count] longLongValue], movieDuration.timeScale);
    TimeRecord trec;
    QTGetTimeRecord(t, &trec);
    
    long long numFramesCalc = [_movie frameEndTime:t].timeValue - [_movie frameStartTime:t].timeValue;
    
    OSStatus err;
    
    NSLog(@"Start::: %lld  HI: %ld  LOW: %ld", start, trec.value.hi, trec.value.lo );
    NSLog(@"Movie Duration.. %d  Audio TimeScale: %d", (unsigned int)GetMovieDuration([_movie quickTimeMovie]), (unsigned int) mAudioTimeScale);
    
    err = MovieAudioExtractionSetProperty(mAudioExtractionSession, kQTPropertyClass_MovieAudioExtraction_Movie, kQTMovieAudioExtractionMoviePropertyID_CurrentTime, sizeof(TimeRecord), &trec);
    if (err) {
        NSLog(@"  Error #: %d",(int)err);
        printf("  QuickTime audio provider: Failed to seek in file \n");
    }
    
    //float   numFramesF = mOutputASBD.mSampleRate * ((float) GetMovieDuration([_movie quickTimeMovie]) / (float) GetMovieTimeScale([_movie quickTimeMovie]));
    float numFramesF = numFramesCalc; //mOutputASBD.mSampleRate/29.97; //mOutputASBD.mSampleRate * 1; //mOutputASBD.mSampleRate * ((float) 1.0 / (float) GetMovieTimeScale([_movie quickTimeMovie]));

    UInt32  numFrames  = (UInt32) count;
    NSLog(@"numFrames is %d and timeScale is %f",(unsigned int) numFrames, (float) GetMovieTimeScale([_movie quickTimeMovie]));
    
    // FIXME: hack something up to actually handle very big counts correctly,
    // maybe with multiple buffers?

    
    AudioBufferList* dst_buflist = calloc(sizeof(AudioBufferList), 1);
    
    dst_buflist->mNumberBuffers = 1;
    dst_buflist->mBuffers[0].mNumberChannels = mOutputASBD.mChannelsPerFrame;
    dst_buflist->mBuffers[0].mDataByteSize   = mOutputASBD.mBytesPerFrame * numFrames;

    dst_buflist->mBuffers[0].mData = calloc(mOutputASBD.mBytesPerFrame * numFrames, 1);
    
    //float* samples;
    UInt32 sampleCount;


    //samples = calloc(mAudioBufList->mBuffers[0].mDataByteSize, 1);
    //mAudioBufList->mBuffers[0].mData = samples;
    
    sampleCount = numFrames * dst_buflist->mBuffers[0].mNumberChannels;
    
    //NSLog(@"Loaded %d samples",(unsigned int)sampleCount);
    
    UInt32 flags;
    UInt32 decode_count = numFrames;
    err = MovieAudioExtractionFillBuffer(mAudioExtractionSession, &decode_count, dst_buflist, &flags);
    if (err) {
        NSLog(@"   Error #: %d",(int)err);
        NSLog(@"   Extraction flags = %d (contains %d?)",(unsigned int)flags,kQTMovieAudioExtractionComplete);
    }
    
    //    if (numFrames != decode_count)
    //        NSLog(@"QuickTime audio provider: GetAudio: Warning: decoded samplecount %d not same as requested count %d \n", (uint32_t)decode_count, (uint32_t)numFrames);
    
    //free(mAudioBufList->mBuffers[0].mData);
    //free(mAudioBufList);
    
    return dst_buflist;
}

- (CMSampleBufferRef) GetAudioCMSampleBuf2:(int64_t) start
{
    OSStatus err;

	QTTime t = QTMakeTime([[frameTimeValues objectAtIndex:start%frameTimeValues.count] longLongValue], movieDuration.timeScale);
	QTTime startTime =[_movie frameStartTime:t];
	QTTime endTime =[_movie frameEndTime:t];
    
    //TimeRecord tr;
    //GetMovieTime([_movie quickTimeMovie], &tr);
    //NSLog(@"Movie Duration.. %d  Audio TimeScale: %d", (unsigned int)GetMovieDuration([_movie quickTimeMovie]), (unsigned int) mAudioTimeScale);
    //NSLog(@"Movie Time: %d %d  ::  Audio Time: %lld", (int)tr.value.hi, (unsigned int)tr.value.lo, startTime.timeValue);
    
    err = MovieAudioExtractionSetProperty(mAudioExtractionSession, kQTPropertyClass_MovieAudioExtraction_Movie, kQTMovieAudioExtractionMoviePropertyID_CurrentTime, sizeof(TimeRecord), &startTime);
    if (err) {
        NSLog(@"  Error #: %d",(int)err);
        printf("  QuickTime audio provider: Failed to seek in file \n");
    }
    
    UInt32  numFrames  = (UInt32) mOutputASBD.mSampleRate/frameRate;
    //NSLog(@"numFrames is %d and timeScale is %f",(unsigned int) numFrames, (float) GetMovieTimeScale([_movie quickTimeMovie]));
    
    AudioBufferList* dst_buflist = calloc(sizeof(AudioBufferList), 1);
    if (dst_buflist == NULL) {
        NSLog(@"   Error #: I'm NULL");
    }
    
    dst_buflist->mNumberBuffers = 1;
    dst_buflist->mBuffers[0].mNumberChannels = mOutputASBD.mChannelsPerFrame;
    dst_buflist->mBuffers[0].mDataByteSize   = mOutputASBD.mBytesPerFrame * numFrames;
    
    float* samples; UInt32 sampleCount;
    samples = calloc(dst_buflist->mBuffers[0].mDataByteSize, 1);
    
    dst_buflist->mBuffers[0].mData = samples;
    
    sampleCount = numFrames * dst_buflist->mBuffers[0].mNumberChannels;
    
    //NSLog(@"Loaded %d samples",(unsigned int)sampleCount);
    
    UInt32 flags;
    UInt32 decode_count = (UInt32)numFrames;
    err = MovieAudioExtractionFillBuffer(mAudioExtractionSession, &decode_count, dst_buflist, &flags);
    if (err) {
        NSLog(@"   Error #: %d",(int)err);
        NSLog(@"   Extraction flags = %d (contains %d?)",(unsigned int)flags,kQTMovieAudioExtractionComplete);
    }
    
    //    if (numFrames != decode_count)
    //        NSLog(@"QuickTime audio provider: GetAudio: Warning: decoded samplecount %d not same as requested count %d \n", (uint32_t)decode_count, (uint32_t)numFrames);
    
    CMSampleBufferRef buff = NULL;
    CMFormatDescriptionRef format = NULL;
    OSStatus error = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &mOutputASBD, 0, NULL, 0, NULL, NULL, &format);
    
    CMSampleTimingInfo timing = { CMTimeMake(1, mOutputASBD.mSampleRate), CMTimeMake(_movie.currentTime.timeValue, _movie.currentTime.timeScale), kCMTimeInvalid };

    error = CMSampleBufferCreate(kCFAllocatorDefault, NULL, false, NULL, NULL, format, decode_count, 1, &timing, 0, NULL, &buff);
    if ( error ) { NSLog(@"CMSampleBufferCreate returned error: %ld", error); }
    
    error = CMSampleBufferSetDataBufferFromAudioBufferList(buff, kCFAllocatorDefault, kCFAllocatorDefault, 0, dst_buflist);
    if ( error ) { NSLog(@"CMSampleBufferSetDataBufferFromAudioBufferList returned error: %ld", error); }
    
    free(dst_buflist->mBuffers[0].mData);
    free(dst_buflist);
    
    return buff;
}




@end
