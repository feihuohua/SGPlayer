//
//  SGFFPlayer.m
//  SGPlayer
//
//  Created by Single on 03/01/2017.
//  Copyright © 2017 single. All rights reserved.
//

#import "SGFFPlayer.h"
#import "SGFFSession.h"
#import "SGFFPlayerView.h"
#import "SGFFAudioPlaybackOutput.h"
#import "SGFFVideoPlaybackOutput.h"
#import "SGFFPlayerView.h"

#import "SGPlayerMacro.h"
#import "SGPlayerUtil.h"
#import "SGPlayerActivity.h"
#import "SGPlayerDefinesPrivate.h"
#import "SGPlayerBackgroundHandler.h"
#import "SGPlayerAudioInterruptHandler.h"


@interface SGFFPlayer () <SGPlayerPrivate, SGFFSessionDelegate>

@property (nonatomic, assign) NSInteger tagInternal;
@property (nonatomic, strong) SGPlayerBackgroundHandler * backgroundHandler;
@property (nonatomic, strong) SGPlayerAudioInterruptHandler * audioInterruptHandler;

@property (nonatomic, copy) NSURL * contentURL;
@property (nonatomic, assign) SGPlayerPlaybackState playbackStateBeforSeeking;
@property (nonatomic, copy) NSError * error;

@property (nonatomic, strong) SGFFSession * session;
@property (nonatomic, strong) SGFFAudioPlaybackOutput * audioOutput;
@property (nonatomic, strong) SGFFVideoPlaybackOutput * videoOutput;
@property (nonatomic, strong) SGFFPlayerView * displayView;

@end

@implementation SGFFPlayer

@synthesize playbackState = _playbackState;
@synthesize playableState = _playableState;

- (instancetype)init
{
    if (self = [super init])
    {
        self.tagInternal = [SGPlayerUtil globalPlayerTag];
        self.backgroundHandler = [SGPlayerBackgroundHandler backgroundHandlerWithPlayer:self];
        self.audioInterruptHandler = [SGPlayerAudioInterruptHandler audioInterruptHandlerWithPlayer:self];
        self.backgroundMode = SGPlayerBackgroundModeContinue;
        
        self.displayView = [[SGFFPlayerView alloc] initWithFrame:CGRectZero];
    }
    return self;
}

- (void)dealloc
{
    [SGPlayerActivity resignActive:self];
    [self cleanDecoder];
}

- (void)replaceWithContentURL:(NSURL *)contentURL
{
    [self clean];
    if (contentURL == nil)
    {
        return;
    }
    self.contentURL = contentURL;
    
    SGFFSessionConfiguration * configuration = [[SGFFSessionConfiguration alloc] init];
    self.audioOutput = [[SGFFAudioPlaybackOutput alloc] init];
    self.videoOutput = [[SGFFVideoPlaybackOutput alloc] init];
    configuration.audioOutput = self.audioOutput;
    configuration.videoOutput = self.videoOutput;
    self.displayView.view = self.videoOutput.view;
    
    self.session = [[SGFFSession alloc] init];
    self.session.URL = self.contentURL;
    self.session.delegate = self;
    self.session.configuration = configuration;
    [self.session openStreams];
}

#pragma mark - Control

- (void)play
{
    [SGPlayerActivity becomeActive:self];
    switch (self.playbackState)
    {
        case SGPlayerPlaybackStateFinished:
            [self.session seekToTime:kCMTimeZero completionHandler:nil];
            break;
        case SGPlayerPlaybackStateFailed:
            [self replaceWithContentURL:self.contentURL];
            break;
        default:
            break;
    }
    self.playbackState = SGPlayerPlaybackStatePlaying;
}

- (void)playOrPause
{
    if (self.playbackState == SGPlayerPlaybackStatePlaying && self.playableState == SGPlayerPlayableStatePlayable) {
        [self.audioOutput play];
    } else {
        [self.audioOutput pause];
    }
}

- (void)pause
{
    [SGPlayerActivity resignActive:self];
//    [self.decoder pause];
    switch (self.playbackState) {
        case SGPlayerPlaybackStateStopped:
        case SGPlayerPlaybackStateFinished:
        case SGPlayerPlaybackStateFailed:
            return;
        default:
            break;
    }
    self.playbackState = SGPlayerPlaybackStatePaused;
}

- (void)interrupt
{
    [SGPlayerActivity resignActive:self];
//    [self.decoder pause];
    switch (self.playbackState) {
        case SGPlayerPlaybackStateStopped:
        case SGPlayerPlaybackStateFinished:
        case SGPlayerPlaybackStateFailed:
            return;
        default:
            break;
    }
    self.playbackState = SGPlayerPlaybackStateInterrupted;
}

- (void)stop
{
    [SGPlayerActivity resignActive:self];
    [self cleanDecoder];
    [self cleanProperty];
    [self cleanTimes];
    self.playbackState = SGPlayerPlaybackStateStopped;
}

- (BOOL)seekable
{
    return self.session.seekable;
}

- (void)seekToTime:(CMTime)time
{
    [self seekToTime:time completionHandler:nil];
}

- (void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL))completionHandler
{
    if (!self.seekable)
    {
        if (completionHandler)
        {
            completionHandler(NO);
        }
        return;
    }
    self.playbackStateBeforSeeking = self.playbackState;
    self.playbackState = SGPlayerPlaybackStateSeeking;
    SGWeakSelf
    [self.session seekToTime:time completionHandler:^(BOOL success) {
        SGStrongSelf
        strongSelf.playbackState = strongSelf.playbackStateBeforSeeking;
        strongSelf.playbackStateBeforSeeking = SGPlayerPlaybackStateIdle;
        if (completionHandler)
        {
            completionHandler(success);
        }
        SGPlayerLog(@"SGPlayer seek finished, %d", success);
    }];
}


#pragma mark - Setter & Getter

- (void)setPlaybackState:(SGPlayerPlaybackState)playbackState
{
    if (_playbackState != playbackState)
    {
        _playbackState = playbackState;
        [self playOrPause];
        if ([self.delegate respondsToSelector:@selector(playerDidChangePlaybackState:)])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate playerDidChangePlaybackState:self];
            });
        }
    }
}

- (void)setPlayableState:(SGPlayerPlayableState)playableState
{
    if (_playableState != playableState)
    {
        _playableState = playableState;
        [self playOrPause];
        if ([self.delegate respondsToSelector:@selector(playerDidChangePlayableState:)])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate playerDidChangePlayableState:self];
            });
        }
    }
}

- (NSInteger)tag
{
    return self.tagInternal;
}

- (SGPLFView *)view
{
    return self.displayView;
}

- (CMTime)duration
{
    if (self.session)
    {
        return self.session.duration;
    }
    return kCMTimeZero;
}

#pragma mark - clean

- (void)clean
{
    [SGPlayerActivity resignActive:self];
    [self cleanDecoder];
    [self cleanProperty];
    [self cleanTimes];
    self.playbackState = SGPlayerPlaybackStateIdle;
}

- (void)cleanDecoder
{
    if (self.session)
    {
        [self.session closeStreams];
        self.session = nil;
    }
}

- (void)cleanProperty
{
    
}

- (void)cleanTimes
{
    [self callbackForTimes];
}

#pragma mark - Callback

- (void)callbackForTimes
{
    
}

#pragma mark - SGFFSessionDelegate

- (void)sessionDidChangeState:(SGFFSession *)session
{
    if (session.state == SGFFSourceStateOpened)
    {
        [self.session startReading];
    }
}

- (void)sessionDidChangeCapacity:(SGFFSession *)session
{
    CMTime loadedDuration = self.session.loadedDuration;
    if (self.session.state == SGFFSessionStateFinished)
    {
        if (CMTimeCompare(loadedDuration, kCMTimeZero) > 0) {
            self.playableState = SGPlayerPlayableStatePlayable;
        } else {
            self.playableState = SGPlayerPlayableStateIdle;
            self.playbackState = SGPlayerPlaybackStateFinished;
        }
    }
    else
    {
        if (CMTimeCompare(loadedDuration, kCMTimeZero) > 0) {
            self.playableState = SGPlayerPlayableStatePlayable;
        } else {
            self.playableState = SGPlayerPlayableStateLoading;
        }
    }
}

@end
