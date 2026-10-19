// Objective-C face of the C++ AnalysisEngine, so Swift can use it.
// (Plain Objective-C header: no C++ here, it is imported through the bridging header.)

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KDMTunerMode) {
    KDMTunerModeAuto  = 0,
    KDMTunerModePitch = 1,
    KDMTunerModePeak  = 2,
};

/// One read of the analysis results. Meter values cover the period since the
/// previous snapshot (peaks are reset by each read).
@interface KDMAnalysisSnapshot : NSObject

// Key: pitch class 0 = C … 11 = B, or -1 when there's no reading yet.
@property (nonatomic, readonly) NSInteger keyPitchClass;
@property (nonatomic, readonly) BOOL      keyIsMinor;
@property (nonatomic, readonly) float     keyCorrelation;   // -1..1, low = atonal
@property (nonatomic, readonly) float     keyConfidence;    // 0..1
@property (nonatomic, readonly) NSArray<NSNumber *> *chroma; // 12 values, C..B

// Tempo from the audio.
@property (nonatomic, readonly) float bpm;
@property (nonatomic, readonly) float bpmConfidence;

// Tuner (frequency 0 = nothing to show).
@property (nonatomic, readonly) float tunerFrequency;
@property (nonatomic, readonly) float tunerClarity;
@property (nonatomic, readonly) BOOL  tunerIsPitch;

// Input meter: linear levels (1.0 = 0 dBFS). Right is 0 for mono input.
@property (nonatomic, readonly) NSInteger numChannels;
@property (nonatomic, readonly) float peakLeft;
@property (nonatomic, readonly) float peakRight;
@property (nonatomic, readonly) float rmsLeft;
@property (nonatomic, readonly) float rmsRight;
@property (nonatomic, readonly) BOOL  clippedLeft;
@property (nonatomic, readonly) BOOL  clippedRight;

@end

@interface KDMAnalysisEngine : NSObject

/// Call while audio is stopped, before processing and whenever the sample rate changes.
- (void)prepareWithSampleRate:(double)sampleRate maxBlockSize:(NSInteger)maxBlockSize;

/// Audio thread. Pass right = NULL for a single (mono) channel.
- (void)processLeft:(const float *)left
              right:(const float * _Nullable)right
         frameCount:(NSInteger)frameCount;

/// UI thread.
- (KDMAnalysisSnapshot *)snapshot;

/// Clears the key/chroma history (e.g. when the next track starts).
- (void)reset;

@property (nonatomic) float smoothing;      // 0..0.99, default 0.85
@property (nonatomic) BOOL frozen;          // hold the current key
@property (nonatomic) BOOL majorOnly;       // default YES (matches the desktop plug-in)
@property (nonatomic) KDMTunerMode tunerMode;
@property (nonatomic) BOOL tunerEnabled;    // default YES; off saves CPU (key + BPM only)

/// Key stability: how long the note profile is averaged (seconds) and how long a
/// different key must keep winning before it's shown (seconds).
- (void)setKeySmoothingSeconds:(double)seconds holdSeconds:(double)hold;
/// Below this level (dBFS) key analysis pauses and keeps its last key (fader down).
@property (nonatomic) float silenceGateDb;

@end

NS_ASSUME_NONNULL_END
