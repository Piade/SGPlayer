//
//  SGFrameOutput.m
//  SGPlayer iOS
//
//  Created by Single on 2018/10/22.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGFrameOutput.h"
#import "SGAsset+Internal.h"
#import "SGDecodeLoop.h"
#import "SGAudioDecoder.h"
#import "SGVideoDecoder.h"
#import "SGPacketOutput.h"
#import "SGMacro.h"
#import "SGLock.h"

@interface SGFrameOutput () <SGPacketOutputDelegate, SGDecodeLoopDelegate>

{
    struct {
        NSError *error;
        SGFrameOutputState state;
    } _flags;
}

@property (nonatomic, strong, readonly) NSLock *lock;
@property (nonatomic, strong, readonly) SGPacketOutput *packetOutput;
@property (nonatomic, strong, readonly) SGDecodeLoop *audioDecoder;
@property (nonatomic, strong, readonly) SGDecodeLoop *videoDecoder;
@property (nonatomic, strong, readonly) NSArray<SGTrack *> *selectedTracks;
@property (nonatomic, strong, readonly) NSArray<SGTrack *> *finishedTracks;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSNumber *, SGCapacity *> *capacitys;

@end

@implementation SGFrameOutput

@synthesize selectedTracks = _selectedTracks;
@synthesize finishedTracks = _finishedTracks;

- (instancetype)initWithAsset:(SGAsset *)asset
{
    if (self = [super init]) {
        self->_lock = [[NSLock alloc] init];
        self->_capacitys = [NSMutableDictionary dictionary];
        self->_audioDecoder = [[SGDecodeLoop alloc] initWithDecodableClass:[SGAudioDecoder class]];
        self->_audioDecoder.delegate = self;
        self->_videoDecoder = [[SGDecodeLoop alloc] initWithDecodableClass:[SGVideoDecoder class]];
        self->_videoDecoder.delegate = self;
        self->_packetOutput = [[SGPacketOutput alloc] initWithDemuxable:[asset newDemuxable]];
        self->_packetOutput.delegate = self;
    }
    return self;
}

- (void)dealloc
{
    SGLockCondEXE10(self->_lock, ^BOOL {
        return self->_flags.state != SGFrameOutputStateClosed;
    }, ^SGBlock {
        [self setState:SGFrameOutputStateClosed];
        [self->_packetOutput close];
        [self->_audioDecoder close];
        [self->_videoDecoder close];
        return nil;
    });
}

#pragma mark - Mapping

SGGet0Map(CMTime, duration, self->_packetOutput)
SGGet0Map(NSDictionary *, metadata, self->_packetOutput)
SGGet0Map(NSArray<SGTrack *> *, tracks, self->_packetOutput)

#pragma mark - Setter & Getter

- (SGBlock)setState:(SGFrameOutputState)state
{
    if (self->_flags.state == state) {
        return ^{};
    }
    self->_flags.state = state;
    return ^{
        [self->_delegate frameOutput:self didChangeState:state];
    };
}

- (SGFrameOutputState)state
{
    __block SGFrameOutputState ret = SGFrameOutputStateNone;
    SGLockEXE00(self->_lock, ^{
        ret = self->_flags.state;
    });
    return ret;
}

- (NSError *)error
{
    __block NSError *ret = nil;
    SGLockEXE00(self->_lock, ^{
        ret = [self->_flags.error copy];
    });
    return ret;
}

- (BOOL)selectTracks:(NSArray<SGTrack *> *)tracks
{
    return SGLockCondEXE10(self->_lock, ^BOOL {
        return ![self->_selectedTracks isEqualToArray:tracks];
    }, ^SGBlock {
        self->_selectedTracks = [tracks copy];
        return nil;
    });
}

- (NSArray<SGTrack *> *)selectedTracks
{
    __block NSArray<SGTrack *> *ret = nil;
    SGLockEXE00(self->_lock, ^{
        ret = [self->_selectedTracks copy];
    });
    return ret;
}

- (NSArray<SGTrack *> *)finishedTracks
{
    __block NSArray<SGTrack *> *ret = nil;
    SGLockEXE00(self->_lock, ^{
        ret = [self->_finishedTracks copy];
    });
    return ret;
}

- (SGCapacity *)capacityWithType:(SGMediaType)type
{
    __block SGCapacity *ret = nil;
    SGLockEXE00(self->_lock, ^{
        SGCapacity *c = [self->_capacitys objectForKey:@(type)];
        ret = c ? [c copy] : [[SGCapacity alloc] init];
    });
    return ret;
}

#pragma mark - Control

- (BOOL)open
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_flags.state == SGFrameOutputStateNone;
    }, ^SGBlock {
        return [self setState:SGFrameOutputStateOpening];
    }, ^BOOL(SGBlock block) {
        block();
        return [self->_packetOutput open];
    });
}

- (BOOL)start
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_flags.state == SGFrameOutputStateOpened;
    }, ^SGBlock {
        return [self setState:SGFrameOutputStateReading];
    }, ^BOOL(SGBlock block) {
        block();
        return [self->_packetOutput resume];
    });
}

- (BOOL)close
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_flags.state != SGFrameOutputStateClosed;
    }, ^SGBlock {
        return [self setState:SGFrameOutputStateClosed];
    }, ^BOOL(SGBlock block) {
        block();
        [self->_packetOutput close];
        [self->_audioDecoder close];
        [self->_videoDecoder close];
        return YES;
    });
}

- (BOOL)pause:(SGMediaType)type
{
    return SGLockEXE00(self->_lock, ^{
        if (type == SGMediaTypeAudio) {
            [self->_audioDecoder pause];
        } else if (type == SGMediaTypeVideo) {
            [self->_videoDecoder pause];
        }
    });
}

- (BOOL)resume:(SGMediaType)type
{
    return SGLockEXE00(self->_lock, ^{
        if (type == SGMediaTypeAudio) {
            [self->_audioDecoder resume];
        } else if (type == SGMediaTypeVideo) {
            [self->_videoDecoder resume];
        }
    });
}

- (BOOL)seekable
{
    return [self->_packetOutput seekable];
}

- (BOOL)seekToTime:(CMTime)time result:(SGSeekResult)result
{
    SGWeakify(self)
    return [self->_packetOutput seekToTime:time result:^(CMTime time, NSError *error) {
        SGStrongify(self)
        if (!error) {
            [self->_audioDecoder flush];
            [self->_videoDecoder flush];
        }
        if (result) {
            result(time, error);
        }
    }];
}

#pragma mark - SGPacketOutputDelegate

- (void)packetOutput:(SGPacketOutput *)packetOutput didChangeState:(SGPacketOutputState)state
{
    SGLockEXE10(self->_lock, ^SGBlock {
        SGBlock b1 = ^{}, b2 = ^{}, b3 = ^{};
        switch (state) {
            case SGPacketOutputStateOpened: {
                b1 = [self setState:SGFrameOutputStateOpened];
                int nb_a = 0, nb_v = 0;
                NSMutableArray *tracks = [NSMutableArray array];
                for (SGTrack *obj in packetOutput.tracks) {
                    if (obj.type == SGMediaTypeAudio && nb_a == 0) {
                        [tracks addObject:obj];
                        nb_a += 1;
                    } else if (obj.type == SGMediaTypeVideo && nb_v == 0) {
                        [tracks addObject:obj];
                        nb_v += 1;
                    }
                    if (nb_a && nb_v) {
                        break;
                    }
                }
                self->_selectedTracks = [tracks copy];
                if (nb_a) {
                    [self->_audioDecoder open];
                }
                if (nb_v) {
                    [self->_videoDecoder open];
                }
            }
                break;
            case SGPacketOutputStateReading:
                b1 = [self setState:SGFrameOutputStateReading];
                break;
            case SGPacketOutputStateSeeking:
                b1 = [self setState:SGFrameOutputStateSeeking];
                break;
            case SGPacketOutputStateFinished: {
                NSArray<SGTrack *> *tracks = self->_selectedTracks;
                b1 = ^{
                    [self->_audioDecoder finish:tracks];
                    [self->_videoDecoder finish:tracks];
                };
            }
                break;
            case SGPacketOutputStateFailed:
                self->_flags.error = [packetOutput.error copy];
                b1 = [self setState:SGFrameOutputStateFailed];
                break;
            default:
                break;
        }
        return ^{
            b1(); b2(); b3();
        };
    });
}

- (void)packetOutput:(SGPacketOutput *)packetOutput didOutputPacket:(SGPacket *)packet
{
    SGLockEXE10(self->_lock, ^SGBlock {
        SGBlock b1 = ^{};
        if ([self->_selectedTracks containsObject:packet.track]) {
            SGDecodeLoop *decoder = nil;
            if (packet.track.type == SGMediaTypeAudio) {
                decoder = self->_audioDecoder;
            } else if (packet.track.type == SGMediaTypeVideo) {
                decoder = self->_videoDecoder;
            }
            b1 = ^{
                [decoder putPacket:packet];
            };
        }
        return b1;
    });
}

#pragma mark - SGDecoderDelegate

- (void)decoder:(SGDecodeLoop *)decoder didChangeState:(SGDecodeLoopState)state
{
    
}

- (void)decoder:(SGDecodeLoop *)decoder didChangeCapacity:(SGCapacity *)capacity
{
    capacity = [capacity copy];
    __block SGBlock finished = ^{};
    __block SGMediaType type = SGMediaTypeUnknown;
    SGLockCondEXE11(self->_lock, ^BOOL {
        if (decoder == self->_audioDecoder) {
            type = SGMediaTypeAudio;
        } else if (decoder == self->_videoDecoder) {
            type = SGMediaTypeVideo;
        }
        return ![[self->_capacitys objectForKey:@(type)] isEqualToCapacity:capacity];
    }, ^SGBlock {
        [self->_capacitys setObject:capacity forKey:@(type)];
        SGCapacity *audioCapacity = [self->_capacitys objectForKey:@(SGMediaTypeAudio)];
        SGCapacity *videoCapacity = [self->_capacitys objectForKey:@(SGMediaTypeVideo)];
        int size = audioCapacity.size + videoCapacity.size;
        BOOL enough = NO;
        if ((audioCapacity ? audioCapacity.isEnough : YES) &&
            (videoCapacity ? videoCapacity.isEnough : YES)) {
            enough = YES;
        }
        if ((!audioCapacity || audioCapacity.isEmpty) &&
            (!videoCapacity || videoCapacity.isEmpty) &&
            self->_packetOutput.state == SGPacketOutputStateFinished) {
            finished = [self setState:SGFrameOutputStateFinished];
        }
        return ^{
            if (enough || (size > 15 * 1024 * 1024)) {
                [self->_packetOutput pause];
            } else {
                [self->_packetOutput resume];
            }
        };
    }, ^BOOL(SGBlock block) {
        block();
        [self->_delegate frameOutput:self didChangeCapacity:[capacity copy] type:type];
        finished();
        return YES;
    });
}

- (void)decoder:(SGDecodeLoop *)decoder didOutputFrame:(__kindof SGFrame *)frame
{
    [self->_delegate frameOutput:self didOutputFrame:frame];
}

@end
