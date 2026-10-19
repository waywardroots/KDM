#import "KDMAnalysisEngine.h"

#include "AnalysisEngine.h"

#include <memory>

@interface KDMAnalysisSnapshot ()
- (instancetype)initWithSnapshot:(const AnalysisEngine::Snapshot &)s;
@end

@implementation KDMAnalysisSnapshot

- (instancetype)initWithSnapshot:(const AnalysisEngine::Snapshot &)s
{
    if ((self = [super init]))
    {
        _keyPitchClass  = s.keyPitchClass;
        _keyIsMinor     = s.keyIsMinor;
        _keyCorrelation = s.keyCorrelation;
        _keyConfidence  = s.keyConfidence;

        NSMutableArray<NSNumber *> *c = [NSMutableArray arrayWithCapacity:12];
        for (float v : s.chroma)
            [c addObject:@(v)];
        _chroma = [c copy];

        _bpm           = s.bpm;
        _bpmConfidence = s.bpmConfidence;

        _tunerFrequency = s.tunerFrequency;
        _tunerClarity   = s.tunerClarity;
        _tunerIsPitch   = s.tunerIsPitch;

        _numChannels  = s.numChannels;
        _peakLeft     = s.levels[0].peak;
        _peakRight    = s.levels[1].peak;
        _rmsLeft      = s.levels[0].rms;
        _rmsRight     = s.levels[1].rms;
        _clippedLeft  = s.levels[0].clipped;
        _clippedRight = s.levels[1].clipped;
    }
    return self;
}

@end

@implementation KDMAnalysisEngine
{
    std::unique_ptr<AnalysisEngine> _engine;
    float _smoothing;
    BOOL _frozen;
    BOOL _majorOnly;
    KDMTunerMode _tunerMode;
    BOOL _tunerEnabled;
    float _silenceGateDb;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _engine = std::make_unique<AnalysisEngine>();
        _smoothing = 0.85f;
        _majorOnly = YES;
        _tunerMode = KDMTunerModeAuto;
        _tunerEnabled = YES;
        _silenceGateDb = -50.0f;
    }
    return self;
}

- (void)prepareWithSampleRate:(double)sampleRate maxBlockSize:(NSInteger)maxBlockSize
{
    _engine->prepare (sampleRate, (int) maxBlockSize);
}

- (void)processLeft:(const float *)left right:(const float *)right frameCount:(NSInteger)frameCount
{
    _engine->process (left, right, (int) frameCount);
}

- (KDMAnalysisSnapshot *)snapshot
{
    AnalysisEngine::Snapshot s;
    _engine->getSnapshot (s);
    return [[KDMAnalysisSnapshot alloc] initWithSnapshot:s];
}

- (void)reset { _engine->requestReset(); }

- (float)smoothing { return _smoothing; }
- (void)setSmoothing:(float)smoothing
{
    _smoothing = smoothing;
    _engine->setSmoothing (smoothing);
}

- (BOOL)frozen { return _frozen; }
- (void)setFrozen:(BOOL)frozen
{
    _frozen = frozen;
    _engine->setFrozen (frozen);
}

- (BOOL)majorOnly { return _majorOnly; }
- (void)setMajorOnly:(BOOL)majorOnly
{
    _majorOnly = majorOnly;
    _engine->setMajorOnly (majorOnly);
}

- (void)setKeySmoothingSeconds:(double)seconds holdSeconds:(double)hold
{
    _engine->setSmoothingSeconds (seconds);
    _engine->setKeyHoldSeconds (hold);
}

- (float)silenceGateDb { return _silenceGateDb; }
- (void)setSilenceGateDb:(float)db
{
    _silenceGateDb = db;
    _engine->setSilenceGateDb (db);
}

- (BOOL)tunerEnabled { return _tunerEnabled; }
- (void)setTunerEnabled:(BOOL)tunerEnabled
{
    _tunerEnabled = tunerEnabled;
    _engine->setTunerEnabled (tunerEnabled);
}

- (KDMTunerMode)tunerMode { return _tunerMode; }
- (void)setTunerMode:(KDMTunerMode)tunerMode
{
    _tunerMode = tunerMode;
    _engine->setTunerMode ((AnalysisEngine::TunerMode) tunerMode);
}

@end
