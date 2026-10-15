#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include <stdint.h>

/// Mic in, effects, headphones out. Owns the buffers shared between the input and output audio threads.
typedef struct OECore OECore;

CF_ASSUME_NONNULL_BEGIN

typedef struct {
    float gainDB;
    float bassDB;
    float trebleDB;
    float highpassHz;
    bool superHearing;
    /// Software noise reduction: turns down steady background noise between sounds, and keyboard clicks.
    bool noiseGate;
    /// Extra gain while other audio is ducked, so the room stays as loud as before.
    float duckCompensationDB;
} OEParams;

OECore *_Nullable oe_core_create(double sampleRate);
void oe_core_destroy(OECore *core);

// Main thread. Safe to call while audio is running.
void oe_core_set_params(OECore *core, const OEParams *params);
void oe_core_set_input_unit(OECore *core, AudioUnit unit);
void oe_core_set_output_enabled(OECore *core, bool enabled);
void oe_core_set_analysis_enabled(OECore *core, bool enabled);

/// Smoothed mic level in dBFS, before any effects.
float oe_core_input_level(OECore *core);
/// Total frames captured. Stops increasing if macOS stops delivering mic audio.
uint64_t oe_core_input_frames(OECore *core);
/// Copies raw mic audio for sound recognition. Call from one background thread.
int oe_core_read_analysis(OECore *core, float *destination, int maxFrames);

// Audio unit callbacks, matching AURenderCallback. Pass the OECore as the refCon.
OSStatus oe_input_callback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                           UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data);
OSStatus oe_output_callback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                            UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data);
CF_ASSUME_NONNULL_END
