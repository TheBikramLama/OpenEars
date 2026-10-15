#include "AudioCore.h"
#include "DSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define MAX_FRAMES 4096
#define RING_SIZE 16384          // ~0.34 s at 48 kHz. Power of two.
#define ANALYSIS_SIZE 131072     // ~2.7 s at 48 kHz. Power of two.
#define CLICK_LOOKAHEAD 64       // ~1.3 ms at 48 kHz: just enough to turn down a keystroke before it plays.

typedef struct {
    Biquad highpass, bass, treble, presence;
    float gain;  // linear
    float duck;  // linear
    int superHearing;
    int noiseGate;
} Settings;

struct OECore {
    double sampleRate;
    AudioUnit inputUnit;
    float input[MAX_FRAMES];

    // Processed audio, input thread -> output thread.
    float ring[RING_SIZE];
    _Atomic uint64_t ringWrite;
    _Atomic uint64_t ringRead;

    // Raw audio, input thread -> sound recognition.
    float analysis[ANALYSIS_SIZE];
    _Atomic uint64_t analysisWrite;
    _Atomic uint64_t analysisRead;

    _Atomic int outputEnabled;
    _Atomic int analysisEnabled;

    // Settings are handed to the audio thread through a seqlock: odd means mid-write.
    _Atomic uint32_t settingsSeq;
    Settings pending;
    Settings active;
    uint32_t activeSeq;

    // Audio-thread state.
    BiquadState highpassState, bassState, trebleState, presenceState;
    float gain, duck;               // smoothed towards active.gain/duck
    float gainSmoothing, duckSmoothing;
    float compEnv, compAttack, compRelease;
    float gateEnv, gateFloorDB, gateGain, gateAttack, gateRelease, gateFloorRise;
    Biquad clickDetect;
    BiquadState clickDetectState;
    float clickFast, clickSlow, clickFastAttack, clickFastRelease, clickSlowAttack, clickSlowRelease;
    float clickGain, clickRecover;
    uint32_t clickHold, clickHoldFrames;
    float lookahead[CLICK_LOOKAHEAD];
    uint32_t lookaheadPos;
    float levelDecayPerFrame;

    _Atomic float level;
    _Atomic uint64_t inputFrames;
};

// Super hearing: the same curve the SoX version used. Quiet sounds up to +20 dB, loud ones held at -6 dBFS.
static float compressorGainDB(float inDB) {
    static const float xs[] = {-70, -40, -20, 0};
    static const float ys[] = {-60, -20, -12, -6};
    if (inDB <= xs[0]) return ys[0] - xs[0];
    if (inDB >= xs[3]) return ys[3] - inDB;
    for (int i = 0; i < 3; i++) {
        if (inDB <= xs[i + 1]) {
            float t = (inDB - xs[i]) / (xs[i + 1] - xs[i]);
            return ys[i] + t * (ys[i + 1] - ys[i]) - inDB;
        }
    }
    return 0;
}

// Last line of ear protection: nothing leaves above full scale, and peaks are rounded off rather than clipped.
static inline float softLimit(float x) {
    float a = fabsf(x);
    if (a <= 0.8f) return x;
    float limited = 0.8f + 0.2f * tanhf((a - 0.8f) / 0.2f);
    return x < 0 ? -limited : limited;
}

// MARK: Lifecycle and settings

OECore *oe_core_create(double sampleRate) {
    OECore *core = calloc(1, sizeof(OECore));
    if (!core) return NULL;
    core->sampleRate = sampleRate;
    core->active = (Settings){identity(), identity(), identity(), identity(), 1, 1, 0, 0};
    core->gain = 1;
    core->duck = 1;
    core->gainSmoothing = 1 - coefficient(sampleRate, 0.02);
    core->duckSmoothing = 1 - coefficient(sampleRate, 0.05);
    core->compAttack = coefficient(sampleRate, 0.005);
    core->compRelease = coefficient(sampleRate, 0.25);
    core->gateAttack = coefficient(sampleRate, 0.002);
    core->gateRelease = coefficient(sampleRate, 0.1);
    core->gateFloorDB = -60;
    core->gateGain = 1;
    core->gateFloorRise = (float)(3.0 / sampleRate); // dB per frame: the noise floor estimate climbs 3 dB/s
    // Keystrokes are clicks: broadband, but it's the treble that jumps out of the background.
    core->clickDetect = highpass(sampleRate, 2500, 0.707);
    core->clickFastAttack = coefficient(sampleRate, 0.0001);
    core->clickFastRelease = coefficient(sampleRate, 0.005);
    core->clickSlowAttack = coefficient(sampleRate, 0.02);
    core->clickSlowRelease = coefficient(sampleRate, 0.1);
    core->clickGain = 1;
    core->clickRecover = 1 - coefficient(sampleRate, 0.015);
    core->clickHoldFrames = (uint32_t)(0.008 * sampleRate); // at least the click itself
    core->levelDecayPerFrame = (float)(30.0 / sampleRate);
    atomic_store(&core->level, -120.0f);
    return core;
}

void oe_core_destroy(OECore *core) { free(core); }

void oe_core_set_input_unit(OECore *core, AudioUnit unit) { core->inputUnit = unit; }
void oe_core_set_output_enabled(OECore *core, bool enabled) { atomic_store(&core->outputEnabled, enabled); }
void oe_core_set_analysis_enabled(OECore *core, bool enabled) { atomic_store(&core->analysisEnabled, enabled); }
float oe_core_input_level(OECore *core) { return atomic_load_explicit(&core->level, memory_order_relaxed); }
uint64_t oe_core_input_frames(OECore *core) { return atomic_load_explicit(&core->inputFrames, memory_order_relaxed); }

void oe_core_set_params(OECore *core, const OEParams *p) {
    double fs = core->sampleRate;
    double cutoff = fmin(fmax(p->highpassHz, 10), fs * 0.45);
    Settings s = {
        .highpass = highpass(fs, cutoff, 0.707),
        .bass = shelf(fs, 100, p->bassDB, 0),
        .treble = shelf(fs, 3000, p->trebleDB, 1),
        // Lift 2-4 kHz, where speech consonants and footsteps live.
        .presence = p->superHearing ? peaking(fs, 3000, 1.5, 6) : identity(),
        .gain = fromdB(p->gainDB),
        .duck = fromdB(p->duckCompensationDB),
        .superHearing = p->superHearing,
        .noiseGate = p->noiseGate,
    };
    uint32_t seq = atomic_load_explicit(&core->settingsSeq, memory_order_relaxed);
    atomic_store_explicit(&core->settingsSeq, seq + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    core->pending = s;
    atomic_store_explicit(&core->settingsSeq, seq + 2, memory_order_release);
}

static void pickUpSettings(OECore *core) {
    uint32_t before = atomic_load_explicit(&core->settingsSeq, memory_order_acquire);
    if (before == core->activeSeq || (before & 1)) return;
    Settings copy = core->pending;
    atomic_thread_fence(memory_order_acquire);
    if (atomic_load_explicit(&core->settingsSeq, memory_order_relaxed) != before) return;
    core->active = copy;
    core->activeSeq = before;
}

// MARK: Ring buffers

static void push(float *ring, uint64_t size, _Atomic uint64_t *write, _Atomic uint64_t *read,
                 const float *source, uint32_t frames) {
    uint64_t w = atomic_load_explicit(write, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(read, memory_order_acquire);
    if (size - (w - r) < frames) return; // Full: drop this block rather than block the audio thread.
    for (uint32_t i = 0; i < frames; i++) ring[(w + i) & (size - 1)] = source[i];
    atomic_store_explicit(write, w + frames, memory_order_release);
}

int oe_core_read_analysis(OECore *core, float *destination, int maxFrames) {
    uint64_t w = atomic_load_explicit(&core->analysisWrite, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&core->analysisRead, memory_order_relaxed);
    uint64_t available = w - r;
    int frames = available < (uint64_t)maxFrames ? (int)available : maxFrames;
    for (int i = 0; i < frames; i++) destination[i] = core->analysis[(r + i) & (ANALYSIS_SIZE - 1)];
    atomic_store_explicit(&core->analysisRead, r + frames, memory_order_release);
    return frames;
}

// MARK: Processing

// Turns keystrokes down by 20 dB. A click jumps 18 dB above the recent treble level within a millisecond;
// voices, music and footsteps rise far more slowly. The audio is delayed slightly so the dip lands on time.
static inline float suppressClicks(OECore *core, float x) {
    float d = fabsf(run(&core->clickDetect, &core->clickDetectState, x));
    core->clickFast = d > core->clickFast ? core->clickFastAttack * core->clickFast + (1 - core->clickFastAttack) * d
                                          : core->clickFastRelease * core->clickFast + (1 - core->clickFastRelease) * d;
    float f = core->clickFast;
    // The background estimate may at most double every ~20 ms, so one keystroke can't hide the next,
    // while a sound that stays loud is accepted within about 0.1 s.
    float rising = fminf(f, 2 * core->clickSlow + 1e-6f);
    core->clickSlow = f > core->clickSlow ? core->clickSlowAttack * core->clickSlow + (1 - core->clickSlowAttack) * rising
                                          : core->clickSlowRelease * core->clickSlow + (1 - core->clickSlowRelease) * f;
    if (f > 8 * core->clickSlow && f > 0.002f) core->clickHold = core->clickHoldFrames;
    // Stay down only while the click is still ringing, so voices underneath come straight back.
    else if (core->clickHold > 0 && f > 3 * core->clickSlow) core->clickHold = core->clickHold > 1 ? core->clickHold : 2;

    float target = core->clickHold > 0 ? 0.1f : 1;
    if (core->clickHold > 0) core->clickHold--;
    // Duck within a few samples, come back over ~15 ms so the dip itself doesn't click.
    core->clickGain += (target - core->clickGain) * (target < core->clickGain ? 0.3f : core->clickRecover);

    float delayed = core->lookahead[core->lookaheadPos];
    core->lookahead[core->lookaheadPos] = x;
    core->lookaheadPos = (core->lookaheadPos + 1) % CLICK_LOOKAHEAD;
    return delayed * core->clickGain;
}

static void process(OECore *core, float *samples, uint32_t frames) {
    pickUpSettings(core);
    const Settings *s = &core->active;
    double sumSquares = 0;

    for (uint32_t i = 0; i < frames; i++) {
        float x = samples[i];
        sumSquares += (double)x * x;

        if (s->noiseGate) {
            x = suppressClicks(core, x);
            float a = fabsf(x);
            core->gateEnv = a > core->gateEnv ? core->gateAttack * core->gateEnv + (1 - core->gateAttack) * a
                                              : core->gateRelease * core->gateEnv + (1 - core->gateRelease) * a;
            float envDB = todB(core->gateEnv);
            // Follow the quietest recent level: drops instantly, climbs slowly. That's the steady noise floor.
            core->gateFloorDB = envDB < core->gateFloorDB ? envDB : core->gateFloorDB + core->gateFloorRise;
            if (core->gateFloorDB < -90) core->gateFloorDB = -90;
            float threshold = core->gateFloorDB + 8;
            float targetDB = envDB < threshold ? fmaxf(-18, (envDB - threshold) * 1.5f) : 0;
            float target = fromdB(targetDB);
            float rate = target > core->gateGain ? 0.02f : 0.0005f; // open fast, close gently
            core->gateGain += (target - core->gateGain) * rate;
            x *= core->gateGain;
        }

        core->gain += (s->gain - core->gain) * core->gainSmoothing;
        float y = x * core->gain;
        y = run(&s->highpass, &core->highpassState, y);
        y = run(&s->bass, &core->bassState, y);
        y = run(&s->treble, &core->trebleState, y);

        if (s->superHearing) {
            y = run(&s->presence, &core->presenceState, y);
            float a = fabsf(y);
            core->compEnv = a > core->compEnv ? core->compAttack * core->compEnv + (1 - core->compAttack) * a
                                              : core->compRelease * core->compEnv + (1 - core->compRelease) * a;
            y *= fromdB(compressorGainDB(todB(core->compEnv)));
        }

        core->duck += (s->duck - core->duck) * core->duckSmoothing;
        samples[i] = softLimit(y * core->duck);
    }

    float blockDB = todB((float)sqrt(sumSquares / (frames ? frames : 1)));
    float previous = atomic_load_explicit(&core->level, memory_order_relaxed);
    float decayed = previous - core->levelDecayPerFrame * frames;
    atomic_store_explicit(&core->level, blockDB > decayed ? blockDB : decayed, memory_order_relaxed);
}

// MARK: Callbacks

OSStatus oe_input_callback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                           UInt32 bus, UInt32 frames, AudioBufferList *data) {
    OECore *core = refCon;
    if (frames > MAX_FRAMES || !core->inputUnit) return kAudio_ParamError;

    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 1;
    list.mBuffers[0].mDataByteSize = frames * sizeof(float);
    list.mBuffers[0].mData = core->input;
    OSStatus status = AudioUnitRender(core->inputUnit, flags, timeStamp, bus, frames, &list);
    if (status != noErr) return status;
    atomic_fetch_add_explicit(&core->inputFrames, frames, memory_order_relaxed);

    if (atomic_load_explicit(&core->analysisEnabled, memory_order_relaxed)) {
        push(core->analysis, ANALYSIS_SIZE, &core->analysisWrite, &core->analysisRead, core->input, frames);
    }
    process(core, core->input, frames);
    if (atomic_load_explicit(&core->outputEnabled, memory_order_relaxed)) {
        push(core->ring, RING_SIZE, &core->ringWrite, &core->ringRead, core->input, frames);
    }
    return noErr;
}

OSStatus oe_output_callback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    OECore *core = refCon;
    if (!data) return noErr;
    uint64_t r = atomic_load_explicit(&core->ringRead, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&core->ringWrite, memory_order_acquire);
    uint64_t available = w - r;

    // Mic and headphones run on separate clocks, so the queue slowly drifts.
    // If it grows past a small cushion, skip ahead to keep the delay low.
    uint64_t cushion = frames > 256 ? frames : 256;
    if (available > frames + 2 * cushion) {
        r = w - (frames + cushion);
        available = frames + cushion;
    }
    uint32_t count = available < frames ? (uint32_t)available : frames;

    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        float *out = data->mBuffers[b].mData;
        for (uint32_t i = 0; i < count; i++) out[i] = core->ring[(r + i) & (RING_SIZE - 1)];
        memset(out + count, 0, (frames - count) * sizeof(float));
    }
    atomic_store_explicit(&core->ringRead, r + count, memory_order_release);
    return noErr;
}
