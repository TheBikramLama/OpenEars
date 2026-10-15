#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

/// Focus sounds: nature scenes synthesised live from random events, so nothing ever loops.
typedef struct OESoundscape OESoundscape;

/// Order matches FocusScene in Swift.
typedef enum {
    OESceneFire,
    OESceneRain,
    OESceneStorm,
    OESceneNight,
    OESceneForest,
    OESceneOcean,
    OESceneWind,
    OESceneStream,
    OESceneCount
} OEScene;

CF_ASSUME_NONNULL_BEGIN

OESoundscape *_Nullable oe_soundscape_create(double sampleRate, uint32_t seed);
void oe_soundscape_destroy(OESoundscape *soundscape);

// Main thread. Levels fade smoothly, so they can change while playing.
/// 0 to 1 per scene.
void oe_soundscape_set_level(OESoundscape *soundscape, OEScene scene, float level);
/// 0 to 1 for everything, used to turn the scenes down while the room is let in.
void oe_soundscape_set_master(OESoundscape *soundscape, float level);

/// Renders stereo audio. Audio thread, or a test.
void oe_soundscape_render(OESoundscape *soundscape, float *left, float *right, uint32_t frames);

/// Audio unit render callback, matching AURenderCallback, for a 2-channel non-interleaved float stream.
/// Pass the OESoundscape as the refCon.
OSStatus oe_soundscape_callback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                                UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data);

CF_ASSUME_NONNULL_END
