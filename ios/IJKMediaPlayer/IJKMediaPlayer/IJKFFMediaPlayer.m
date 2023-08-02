/*
 * IJKFFMoviePlayerDef.m
 *
 * Copyright (c) 2019 Befovy <befovy@gmail.com>
 *
 * This file is part of fijkPlayer.
 *
 * ijkPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * ijkPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with ijkPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "IJKFFMoviePlayerController.h"
#import "IJKFFMediaPlayer.h"
#import "IJKFFMoviePlayerDef.h"
#import "IJKAudioKit.h"
#import "IJKFFOptions.h"
#import "IJKNotificationManager.h"
#import "ijkplayer/ijkplayer.h"

#import <libkern/OSAtomic.h>

typedef NS_ENUM(NSInteger, IJKSDLFFPlayrRenderType) {
    IJKSDLFFPlayrRenderTypeGlView = 0,
    IJKSDLFFPlayrRenderTypeFboView = 1,
};


@interface IJKFFWeakHolder : NSObject
@property (nonatomic, weak) id object;
@end

@implementation IJKFFWeakHolder
@end

@implementation IJKFFMediaPlayer {
    IjkMediaPlayer* _nativeMediaPlayer;
    IJKFFMoviePlayerMessagePool *_msgPool;

    IJKNotificationManager *_notificationManager;
    NSMutableSet<id<IJKMPEventHandler>> *_eventHandlers;
    
    CFDictionaryRef _optionsDictionary;
    CVPixelBufferRef _pixelBuffer;

#if IJK_IOS
    IJKSDLFboGLView* _fboView;
#endif
    id<IJKCVPBViewProtocol> _cvPBView;
    IJKSDLFFPlayrRenderType _renderType;
    BOOL _playingBeforeInterruption;
}


@synthesize fps = _fps;
@synthesize isThirdGLView = _isThirdGLView;
@synthesize scaleFactor = _scaleFactor;

- (IJKFFMoviePlayerMessage *) obtainMessage {
    return [_msgPool obtain];
}

inline static IJKFFMediaPlayer *ffplayerRetain(void *arg) {
    return (__bridge_transfer IJKFFMediaPlayer *) arg;
}

inline static void fillMetaInternal(NSMutableDictionary *meta, IjkMediaMeta *rawMeta, const char *name, NSString *defaultValue)
{
    if (!meta || !rawMeta || !name)
        return;

    NSString *key = [NSString stringWithUTF8String:name];
    const char *value = ijkmeta_get_string_l(rawMeta, name);
    if (value) {
        [meta setObject:[NSString stringWithUTF8String:value] forKey:key];
    } else if (defaultValue) {
        [meta setObject:defaultValue forKey:key];
    } else {
        [meta removeObjectForKey:key];
    }
}

int ff_media_player_msg_loop(void* arg)
{
    @autoreleasepool {
        IjkMediaPlayer *mp = (IjkMediaPlayer*)arg;
        __weak IJKFFMediaPlayer *ffPlayer = ffplayerRetain(ijkmp_set_weak_thiz(mp, NULL));
        while (ffPlayer) {
            @autoreleasepool {
                IJKFFMoviePlayerMessage *msg = [ffPlayer obtainMessage];
                if (!msg)
                    break;
                
                int retval = ijkmp_get_msg(mp, &msg->_msg, 1);
                if (retval < 0)
                    break;
                
                // block-get should never return 0
                assert(retval > 0);
                [ffPlayer performSelectorOnMainThread:@selector(postEvent:) withObject:msg waitUntilDone:NO];
            }
        }
        
        // retained in prepare_async, before SDL_CreateThreadEx
        ijkmp_dec_ref_p(&mp);
        return 0;
    }
}

- (IJKFFMediaPlayer *)init
{
    self = [super init];
    if (self) {
        _renderType = IJKSDLFFPlayrRenderTypeGlView;
         [self nativeSetup];
    }
    return self;
}

- (instancetype)initWithFbo
{
    self = [super init];
    if (self) {
        _renderType = IJKSDLFFPlayrRenderTypeFboView;
        [self nativeSetup];
    }
    return self;
}


- (void) nativeSetup
{
    ijkmp_global_init();
    _msgPool = [[IJKFFMoviePlayerMessagePool alloc] init];
    _eventHandlers = [[NSMutableSet alloc] init];
    
    _nativeMediaPlayer = ijkmp_ios_create(ff_media_player_msg_loop);
    ijkmp_set_option(_nativeMediaPlayer, IJKMP_OPT_CATEGORY_PLAYER, "overlay-format", "fcc-_es2");

    IJKFFWeakHolder *weakHolder = [[IJKFFWeakHolder alloc] init];
    weakHolder.object = self;
    
    ijkmp_set_weak_thiz(_nativeMediaPlayer, (__bridge_retained void *) self);
    ijkmp_set_inject_opaque(_nativeMediaPlayer, (__bridge_retained void *) weakHolder);
    ijkmp_set_ijkio_inject_opaque(_nativeMediaPlayer, (__bridge_retained void *) weakHolder);
    
    _notificationManager = [[IJKNotificationManager alloc] init];

    [[IJKAudioKit sharedInstance] setupAudioSessionWithoutInterruptHandler];
    _optionsDictionary = nil;
    _isThirdGLView = true;
    _scaleFactor = 1.0f;
    _fps = 1.0f;

    [self registerApplicationObservers];

}

- (void)postEvent: (IJKFFMoviePlayerMessage *)msg
{
    if (!msg)
        return;
    
    AVMessage *avmsg = &msg->_msg;
    for (id<IJKMPEventHandler> handler in _eventHandlers) {
        [handler onEvent4Player:self withType:avmsg->what andArg1:avmsg->arg1 andArg2:avmsg->arg2 andExtra:avmsg->obj];
    }
    [_msgPool recycle:msg];
}

- (int) prepareAsync
{
    return ijkmp_prepare_async(_nativeMediaPlayer);
}

- (int) setDataSource:(NSString *)url
{
    return ijkmp_set_data_source(_nativeMediaPlayer, [url UTF8String]);
}

- (int) start
{
    return ijkmp_start(_nativeMediaPlayer);
}

- (int) stop
{
    return ijkmp_stop(_nativeMediaPlayer);
}

- (int) pause
{
    return ijkmp_pause(_nativeMediaPlayer);
}

- (BOOL) isPlaying
{
    return ijkmp_is_playing(_nativeMediaPlayer);
}

- (long) getCurrentPosition
{
    return ijkmp_get_current_position(_nativeMediaPlayer);
}

- (long) getDuration
{
    return ijkmp_get_duration(_nativeMediaPlayer);
}

- (int) seekTo:(long) msec
{
    return ijkmp_seek_to(_nativeMediaPlayer, msec);
}


- (void) setLoop:(int) loop
{
    ijkmp_set_loop(_nativeMediaPlayer, loop);
}

- (int) getLoop
{
    return ijkmp_get_loop(_nativeMediaPlayer);
}

- (void) setSpeed:(float) speed
{
    ijkmp_set_property_float(_nativeMediaPlayer, FFP_PROP_FLOAT_PLAYBACK_RATE, speed);
}

- (NSDictionary *) getMediaMeta
{
    IjkMediaMeta *rawMeta = ijkmp_get_meta_l(_nativeMediaPlayer);
    if (!rawMeta)
        return nil;

    ijkmeta_lock(rawMeta);
    NSMutableDictionary *newMediaMeta = [[NSMutableDictionary alloc] init];

    fillMetaInternal(newMediaMeta, rawMeta, IJKM_KEY_FORMAT, nil);
    fillMetaInternal(newMediaMeta, rawMeta, IJKM_KEY_DURATION_US, nil);
    fillMetaInternal(newMediaMeta, rawMeta, IJKM_KEY_START_US, nil);
    fillMetaInternal(newMediaMeta, rawMeta, IJKM_KEY_BITRATE, nil);

    fillMetaInternal(newMediaMeta, rawMeta, IJKM_KEY_VIDEO_STREAM, nil);
    fillMetaInternal(newMediaMeta, rawMeta, IJKM_KEY_AUDIO_STREAM, nil);
    fillMetaInternal(newMediaMeta, rawMeta, IJKM_KEY_TIMEDTEXT_STREAM, nil);

    NSMutableArray *streams = [[NSMutableArray alloc] init];

    size_t count = ijkmeta_get_children_count_l(rawMeta);
    for(size_t i = 0; i < count; ++i) {
        IjkMediaMeta *streamRawMeta = ijkmeta_get_child_l(rawMeta, i);
        NSMutableDictionary *streamMeta = [[NSMutableDictionary alloc] init];

        if (streamRawMeta) {
            fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_TYPE, k_IJKM_VAL_TYPE__UNKNOWN);
            fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_LANGUAGE, nil);
            fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_TITLE, nil);

            const char *type = ijkmeta_get_string_l(streamRawMeta, IJKM_KEY_TYPE);
            if (type) {
                fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_CODEC_NAME, nil);
                fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_CODEC_PROFILE, nil);
                fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_CODEC_LONG_NAME, nil);
                fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_BITRATE, nil);

                if (0 == strcmp(type, IJKM_VAL_TYPE__VIDEO)) {
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_WIDTH, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_HEIGHT, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_FPS_NUM, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_FPS_DEN, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_TBR_NUM, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_TBR_DEN, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_SAR_NUM, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_SAR_DEN, nil);
                } else if (0 == strcmp(type, IJKM_VAL_TYPE__AUDIO)) {
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_SAMPLE_RATE, nil);
                    fillMetaInternal(streamMeta, streamRawMeta, IJKM_KEY_CHANNEL_LAYOUT, nil);
                }
            }
        }

        [streams addObject:streamMeta];
    }

    [newMediaMeta setObject:streams forKey:kk_IJKM_KEY_STREAMS];
    ijkmeta_unlock(rawMeta);

    return newMediaMeta;
}

- (NSArray *) getTrackInfo
{
    NSDictionary *mediaMeta = [self getMediaMeta];
    if (!mediaMeta)
        return nil;

    NSArray *streamMetas = [mediaMeta objectForKey:kk_IJKM_KEY_STREAMS];
    if (!streamMetas)
        return nil;
    
    NSMutableArray *tracks = [[NSMutableArray alloc] init];
    for (NSDictionary *streamMeta in streamMetas) {
        NSString *type = [streamMeta objectForKey:k_IJKM_KEY_TYPE];
        if (!type)
            continue;

        int trackType = 0;
        if ([type isEqualToString:k_IJKM_VAL_TYPE__VIDEO]) {
            trackType = 1;
        } else if ([type isEqualToString:k_IJKM_VAL_TYPE__AUDIO]) {
            trackType = 2;
        } else if ([type isEqualToString:k_IJKM_VAL_TYPE__TIMEDTEXT]) {
            trackType = 3;
        }

        // add to tracks
        NSMutableDictionary *track = [[NSMutableDictionary alloc] init];

        // type
        [track setObject:[NSNumber numberWithInt:trackType] forKey:k_IJKM_KEY_TYPE];

        // title
        NSString *title = [streamMeta objectForKey:k_IJKM_KEY_TITLE];
        [track setObject:[self getTitle:title] forKey:k_IJKM_KEY_TITLE];

        // language
        NSString *language = [streamMeta objectForKey:k_IJKM_KEY_LANGUAGE];
        [track setObject:[self getLanguage:language] forKey:k_IJKM_KEY_LANGUAGE];

        // info
        NSString *info = @"";
        NSString *codec_name = [streamMeta objectForKey:k_IJKM_KEY_CODEC_NAME]; // codec name
        NSString *bitrate = [streamMeta objectForKey:k_IJKM_KEY_BITRATE]; // bitrate

        // add prefix
        switch (trackType) {
            case 1:
                info = [info stringByAppendingString:@"VIDEO"];
                break;
            case 2:
                info = [info stringByAppendingString:@"AUDIO"];
                break;
            case 3:
                info = [info stringByAppendingString:@"TIMEDTEXT"];
                break;
            case 4:
                info = [info stringByAppendingString:@"SUBTITLE"];
                break;
            default:
                info = [info stringByAppendingString:@"UNKNOWN"];
                break;
        }

        // add codec info
        if (codec_name) {
            info = [info stringByAppendingString:@", "];
            info = [info stringByAppendingString:[self getCodecShortNameInline:codec_name]];
        }

        // add bitrate info
        if (bitrate) {
            info = [info stringByAppendingString:@", "];
            info = [info stringByAppendingString:[self getBitrateInline:[bitrate longLongValue]]];
        }

        // resolution only for video
        NSNumber *width = [streamMeta objectForKey:k_IJKM_KEY_WIDTH];
        NSNumber *height = [streamMeta objectForKey:k_IJKM_KEY_HEIGHT];
        if (width && height && trackType == 1) {
            info = [info stringByAppendingString:@", "];
            info = [info stringByAppendingString:[NSString stringWithFormat:@"%@ x %@", width, height]];
        }

        // sample rate only for audio
        NSString *sample_rate = [streamMeta objectForKey:k_IJKM_KEY_SAMPLE_RATE]; // sample_rate
        if (sample_rate && trackType == 2) {
            info = [info stringByAppendingString:@", "];
            info = [info stringByAppendingString:[self getSampleRateInline:[sample_rate intValue]]];
        }

        // timedtext language
        if (trackType == 3) {
            info = [info stringByAppendingString:@", "];
            info = [info stringByAppendingString:[self getLanguage:language]];
        }

        [track setObject:info forKey:@"info"];
        [tracks addObject:track];
    }

    return tracks;
}

- (NSString *) getTitle:(NSString *) mTitle {
    return mTitle.length > 0 ? mTitle : @"und";
}

- (NSString *) getLanguage:(NSString *) mLanguage {
    return mLanguage.length > 0 ? mLanguage : @"und";
}

- (NSString *) getCodecShortNameInline:(NSString *) mCodecName {
    return mCodecName.length > 0 ? mCodecName : @"N/A";
}

- (NSString *) getBitrateInline:(long) mBitrate {
    if (mBitrate <= 0) {
        return @"N/A";
    } else {
        if (mBitrate < 1000) {
            return [NSString stringWithFormat:@"%ld bit/s", mBitrate];
        } else {
            return [NSString stringWithFormat:@"%ld kb/s", mBitrate / 1000];
        }
    }
}

- (NSString *) getSampleRateInline:(int) mSampleRate {
    return mSampleRate <= 0 ? @"N/A" : [NSString stringWithFormat:@"%d Hz", mSampleRate];
}

- (int64_t) getTcpSpeed {
    return [self getLongProperty:FFP_PROP_INT64_TCP_SPEED default:0];
}

- (int64_t) getSelectedTrack:(int) trackType
{
    switch(trackType) {
        case 1:
            return [self getLongProperty:FFP_PROP_INT64_SELECTED_VIDEO_STREAM default:-1];
        case 2:
            return [self getLongProperty:FFP_PROP_INT64_SELECTED_AUDIO_STREAM default:-1];
        case 3:
            return [self getLongProperty:FFP_PROP_INT64_SELECTED_TIMEDTEXT_STREAM default:-1];
        default:
            return -1;
    }
}

- (void) selectTrack:(int) track
{
    [self setStreamSelected:track selected:YES];
}

- (void) setStreamSelected:(int) stream selected:(BOOL) selected
{
    ijkmp_set_stream_selected(_nativeMediaPlayer, stream, selected);
}

- (float) getFloatProperty:(int) property defalut:(float) value
{
    return ijkmp_get_property_float(_nativeMediaPlayer, property, value);
}

- (int64_t) getLongProperty:(int) property default:(int64_t) value
{
    return ijkmp_get_property_int64(_nativeMediaPlayer, property, value);
}

- (void) setPlaybackVolume:(float)volume
{
    if (!_nativeMediaPlayer)
        return;
    ijkmp_set_playback_volume(_nativeMediaPlayer, volume);
}

- (float) playbackVolume
{
    if (!_nativeMediaPlayer)
        return 0.0f;
    return ijkmp_get_property_float(_nativeMediaPlayer, FFP_PROP_FLOAT_PLAYBACK_VOLUME, 1.0f);
}

- (void) shutdown
{
    _ignoreAudioInterrupt = YES;
    [self unregisterApplicationObservers];
    ijkmp_shutdown(_nativeMediaPlayer);
    
    __unused id weakPlayer = (__bridge_transfer IJKFFMediaPlayer*)ijkmp_set_weak_thiz(_nativeMediaPlayer, NULL);
    __unused id weakHolder = (__bridge_transfer IJKFFWeakHolder*)ijkmp_set_inject_opaque(_nativeMediaPlayer, NULL);
    __unused id weakijkHolder = (__bridge_transfer IJKFFWeakHolder*)ijkmp_set_ijkio_inject_opaque(_nativeMediaPlayer, NULL);

    if (_optionsDictionary)
        CFRelease(_optionsDictionary);

    [_eventHandlers removeAllObjects];
    ijkmp_dec_ref_p(&_nativeMediaPlayer);

    CVPixelBufferRef buffer = _pixelBuffer;
    while (!OSAtomicCompareAndSwapPtrBarrier(buffer, nil,
                                              (void **)&_pixelBuffer)) {
         buffer = _pixelBuffer;
    }
    if (buffer != nil) {
        CVPixelBufferRelease(buffer);
        buffer = nil;
    }
    _cvPBView = nil;
#if IJK_IOS
    _fboView = nil;
#endif
}

- (int) reset
{
    ijkmp_stop(_nativeMediaPlayer);
    ijkmp_reset(_nativeMediaPlayer);
    return 0;
}


- (void) setOptionValue:(NSString *)value
                forKey:(NSString *)key
            ofCategory:(IJKFFOptionCategory)category
{
    ijkmp_set_option(_nativeMediaPlayer, category, [key UTF8String], [value UTF8String]);
}

- (void) setOptionIntValue:(int64_t)value
                   forKey:(NSString *)key
               ofCategory:(IJKFFOptionCategory)category
{
    ijkmp_set_option_int(_nativeMediaPlayer, category, [key UTF8String], value);
}


- (void) addIJKMPEventHandler:(id<IJKMPEventHandler>) handler
{
    [_eventHandlers addObject:handler];
}

- (void) removeIJKMPEventHandler:(id<IJKMPEventHandler>) handler
{
    [_eventHandlers removeObject:handler];
}

#if IJK_IOS
- (UIImage *)snapshot {
    return nil;
}
#else
- (NSImage *)snapshot {
    return nil;
}
#endif

- (void) setupCVPixelBufferView:(id<IJKCVPBViewProtocol>) cvPBView
{
    _cvPBView = cvPBView;
    
    if (_renderType == IJKSDLFFPlayrRenderTypeFboView) {
#if IJK_IOS
        _fboView = [[IJKSDLFboGLView alloc] initWithIJKCVPBViewProtocol:self];
        ijkmp_ios_set_glview(_nativeMediaPlayer, _fboView);
#endif
    } else if (_renderType == IJKSDLFFPlayrRenderTypeGlView) {
        const void *keys[] = {
#if IJK_IOS
            kCVPixelBufferOpenGLESCompatibilityKey,
#else
            kCVPixelBufferOpenGLCompatibilityKey,
#endif
            kCVPixelBufferIOSurfacePropertiesKey,
        };
        const void *values[] = {
            (__bridge const void *) (@YES),
            (__bridge const void *) ([NSDictionary dictionary]),
        };
        
        _optionsDictionary = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        ijkmp_ios_set_glview(_nativeMediaPlayer, self);
    }
}

- (void) onSnapshot:(CVPixelBufferRef) pixelbuffer
{
    if (_cacheSnapshot) {
        CVPixelBufferRef newBuffer = CVPixelBufferRetain(pixelbuffer);
        CVPixelBufferRef oldBuffer = _pixelBuffer;
        while (!OSAtomicCompareAndSwapPtrBarrier(oldBuffer, newBuffer,
                                                 (void **)&_pixelBuffer)) {
            oldBuffer = _pixelBuffer;
        }
        if (oldBuffer != nil) {
            CVPixelBufferRelease(oldBuffer);
        }
    }
}

// IJKSDL GLview call this when display frame
- (void) display_pixels:(IJKOverlay *)overlay
{
    if (overlay->pixel_buffer != nil && _cvPBView != nil) {
        [self onSnapshot: overlay->pixel_buffer];
        [_cvPBView display_pixelbuffer:overlay->pixel_buffer];
    } else if (_cvPBView != nil && overlay->format == SDL_FCC_BGRA){
        CVPixelBufferRef pixelBuffer;
        
        // CVPixelBufferCreateWithBytes lead to crash if reset player
        // and then setDataSource and play again.
        /*
         int retval = CVPixelBufferCreateWithBytes(
         kCFAllocatorDefault,
         (size_t) overlay->w,
         (size_t) overlay->h,
         kCVPixelFormatType_32BGRA,
         overlay->pixels[0],
         overlay->pitches[0],
         NULL, NULL, _optionsDictionary,
         &pixelBuffer);
         */
        int retval = CVPixelBufferCreate(kCFAllocatorDefault,
                                         (size_t) overlay->w,
                                         (size_t) overlay->h,
                                         kCVPixelFormatType_32BGRA,
                                         _optionsDictionary,
                                         &pixelBuffer);
        if (retval == kCVReturnSuccess) {
            CVPixelBufferLockBaseAddress(pixelBuffer, 0);
            uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
            memcpy(dst, overlay->pixels[0], overlay->pitches[0] * overlay->h);
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            [self onSnapshot: pixelBuffer];
            [_cvPBView display_pixelbuffer:pixelBuffer];
            CVPixelBufferRelease(pixelBuffer);
        }
    }
}


// IJKSDL Fbo view call this delegate when display frame
- (void)display_pixelbuffer:(CVPixelBufferRef)pixelbuffer {
    if (_cvPBView) {
        [_cvPBView display_pixelbuffer:pixelbuffer];
    }
    [self onSnapshot: pixelbuffer];
}

- (void) takeSnapshot:(OnSnapshotBlock) block
{
    CVPixelBufferRef snapshot = _pixelBuffer;
    while (!OSAtomicCompareAndSwapPtrBarrier(snapshot, nil,
                                              (void **)&_pixelBuffer)) {
         snapshot = _pixelBuffer;
    }
    if (snapshot != nil) {
        CVPixelBufferRetain(snapshot);
    }
    if (!OSAtomicCompareAndSwapPtrBarrier(nil, snapshot, (void **)&_pixelBuffer)) {
        CVPixelBufferRelease(snapshot);
    }
    
    if (block != nil) {
        if (snapshot != nil) {
            CIImage *ciImage = [CIImage imageWithCVPixelBuffer:snapshot];

               CIContext *context = [CIContext contextWithOptions:nil];
               CGImageRef imageRef = [context createCGImage:ciImage
                        fromRect:CGRectMake(0, 0,
                                            CVPixelBufferGetWidth(snapshot),
                                            CVPixelBufferGetHeight(snapshot))];

               UIImage *uiImage = [UIImage imageWithCGImage:imageRef];
               CGImageRelease(imageRef);

               block(uiImage, nil);
        } else {
            block(nil, [[NSError alloc] initWithDomain:@"no snapshot" code:IJKMPEC_SNAPSHOT userInfo:nil]);
        }
    }
    if (snapshot != nil) {
        CVPixelBufferRelease(snapshot);
    }
}

- (void)registerApplicationObservers
{
    [_notificationManager addObserver:self
                             selector:@selector(audioSessionInterrupt:)
                                 name:AVAudioSessionInterruptionNotification
                               object:nil];
}

- (void)unregisterApplicationObservers
{
    [_notificationManager removeAllObservers:self];
}


- (void)audioSessionInterrupt:(NSNotification *)notification
{
    if (_ignoreAudioInterrupt) {
        return;
    }
    int reason = [[[notification userInfo] valueForKey:AVAudioSessionInterruptionTypeKey] intValue];
    switch (reason) {
        case AVAudioSessionInterruptionTypeBegan: {
            if (_nativeMediaPlayer && ijkmp_get_state(_nativeMediaPlayer) == MP_STATE_STARTED) {
                _playingBeforeInterruption = YES;
            } else{
                _playingBeforeInterruption = NO;
            }
            NSLog(@"IJKFFMediaPlayer:audioSessionInterrupt: begin, %d\n", _playingBeforeInterruption);
            [self pause];
            [[IJKAudioKit sharedInstance] setActive:NO];
            break;
        }
        case AVAudioSessionInterruptionTypeEnded: {
            NSLog(@"IJKFFMediaPlayer:audioSessionInterrupt: end\n");
            [[IJKAudioKit sharedInstance] setActive:YES];
            if (_playingBeforeInterruption) {
                [self start];
            }
            break;
        }
    }
}
@end
