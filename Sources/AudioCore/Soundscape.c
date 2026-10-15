#include "Soundscape.h"
#include "DSP.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Every scene is built from two layers: a bed of filtered noise whose colour and loudness wander at random,
// and short events (crackles, drops, bird notes, waves) fired at random times with random sizes and positions.
// Nothing is a recording, so there's no loop to recognise.

#define MAX_VOICES 128
#define CRICKETS 5
#define CONTROL_INTERVAL 32 // frames between slow updates: filter sweeps, wandering levels

// MARK: Randomness

typedef struct { uint32_t state; } Rng;

static inline uint32_t nextRandom(Rng *r) {
    uint32_t x = r->state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return r->state = x;
}
static inline float uniform(Rng *r) { return (float)(nextRandom(r) >> 8) * (1.0f / 16777216.0f); } // [0, 1)
static inline float signedRandom(Rng *r) { return uniform(r) * 2 - 1; }
static inline float between(Rng *r, float lo, float hi) { return lo + (hi - lo) * uniform(r); }
/// Waiting time until the next event of something that happens `rate` times a second on average.
static inline float waitFor(Rng *r, float rate) { return -logf(1 - uniform(r)) / fmaxf(rate, 1e-4f); }
/// Mostly small values with the odd big one, like real crackles and drops.
static inline float skewed(Rng *r, float power) { return powf(uniform(r), power); }

/// A value that wanders: picks a new random target every so often and glides towards it.
typedef struct { float value, target, hold, glide, lo, hi, minHold, maxHold; } Wander;

static Wander wander(Rng *r, float lo, float hi, float minHold, float maxHold, float glideSeconds) {
    float start = between(r, lo, hi);
    float tick = (float)CONTROL_INTERVAL / 48000.0f;
    return (Wander){start, start, 0, 1 - expf(-tick / glideSeconds), lo, hi, minHold, maxHold};
}

static inline float wanderStep(Wander *w, Rng *r, float dt) {
    w->hold -= dt;
    if (w->hold <= 0) {
        w->target = between(r, w->lo, w->hi);
        w->hold = between(r, w->minHold, w->maxHold);
    }
    w->value += (w->target - w->value) * w->glide;
    return w->value;
}

// MARK: Noise

typedef struct { float b0, b1, b2; } Pink;
// Paul Kellet's economy pink filter.
static inline float pink(Pink *p, float white) {
    p->b0 = 0.99765f * p->b0 + white * 0.0990f;
    p->b1 = 0.96300f * p->b1 + white * 0.2965f;
    p->b2 = 0.57000f * p->b2 + white * 1.0526f;
    return (p->b0 + p->b1 + p->b2 + white * 0.1848f) * 0.25f;
}

typedef struct { float z; } Brown;
static inline float brown(Brown *b, float white) {
    b->z = (b->z + 0.02f * white) / 1.02f;
    return b->z * 3.5f;
}

/// Left and right gains for a position from -1 (left) to 1 (right), keeping loudness even.
static inline void panGains(float position, float *left, float *right) {
    float angle = (position + 1) * (float)M_PI_4;
    *left = cosf(angle);
    *right = sinf(angle);
}

// MARK: Events

typedef enum {
    VoiceBurst,   // filtered noise click: crackles, pops, raindrops
    VoiceTone,    // gliding sine: water plinks, bubbles, bird notes
    VoiceCroak,   // pulsing low tone: frogs
    VoiceThunder, // long low rumble
    VoiceWave,    // a wave rolling in and breaking
} VoiceKind;

typedef struct {
    int active;
    VoiceKind kind;
    OEScene scene;
    float delay;  // seconds before it starts
    float t, dur; // seconds
    float amp, decay;
    float gainL, gainR;
    float f0, f1, phase;
    float vibrato, vibratoRate, vibratoPhase;
    int bell; // envelope: 0 = instant attack and decay, 1 = smooth rise and fall
    float peak; // wave: where in its life it breaks, 0 to 1
    float cutoff;
    float rumble, rumbleTarget, rumbleHold;
    Biquad filter;
    BiquadState stateL, stateR;
    Brown brownL, brownR;
    Pink pinkL, pinkR;
} Voice;

// MARK: Scene layers

typedef struct {
    Pink pinkL, pinkR;
    Biquad high, low;
    BiquadState highL, highR, lowL, lowR;
    Wander intensity;
    float bedLevel, dropRate, plinkRate;
    float nextDrop, nextPlink;
} Rain;

typedef struct {
    Pink pinkL, pinkR;
    BiquadState bandL, bandR, whistleL, whistleR;
    Biquad band, whistle;
    Wander gust, centre, whistlePitch;
    float lo, hi, level;
} Wind;

typedef struct {
    float freq, gainL, gainR, amp, phase;
    float interval, nextChirp, pulseGap, pulseTimer, pulseT;
    int pulsesLeft, pulsing;
} Cricket;

struct OESoundscape {
    double sampleRate;
    float dt;
    Rng rng;

    _Atomic float targets[OESceneCount];
    _Atomic float masterTarget;
    float levels[OESceneCount];
    float master;
    float levelGlide;
    uint32_t controlCountdown;

    Voice voices[MAX_VOICES];

    // Fire
    Brown fireBrownL, fireBrownR;
    Pink fireHissL, fireHissR;
    Biquad fireLow, fireHigh;
    BiquadState fireLowL, fireLowR, fireHighL, fireHighR;
    Wander flicker, crackleRate;
    float nextCrackle, nextPop, nextSnap;

    Rain rain, stormRain, forestRain;
    float nextThunder;

    // Night
    Cricket crickets[CRICKETS];
    Wind breeze;
    float nextCroak;

    // Rainforest
    float nextBird;
    Biquad insectBand;
    BiquadState insectL, insectR;
    Wander insectSwell;
    float insectPhase;

    // Ocean
    Brown surfL, surfR;
    Biquad surfLow;
    BiquadState surfLowL, surfLowR;
    float nextWave;

    Wind wind;

    // Stream
    Pink streamL, streamR;
    Biquad streamBand;
    BiquadState streamBandL, streamBandR;
    Wander churn, bubbleRate;
    float nextBubble;
};

// MARK: Voice lifecycle

static Voice *newVoice(OESoundscape *s, VoiceKind kind, OEScene scene) {
    for (int i = 0; i < MAX_VOICES; i++) {
        Voice *v = &s->voices[i];
        if (v->active) continue;
        memset(v, 0, sizeof *v);
        v->active = 1;
        v->kind = kind;
        v->scene = scene;
        return v;
    }
    return NULL; // Busy moment: skip this event rather than cut another short.
}

static void burst(OESoundscape *s, OEScene scene, Biquad filter, float amp, float decay, float pan) {
    Voice *v = newVoice(s, VoiceBurst, scene);
    if (!v) return;
    v->filter = filter;
    v->amp = amp;
    v->decay = decay;
    v->dur = decay * 7;
    panGains(pan, &v->gainL, &v->gainR);
}

static Voice *tone(OESoundscape *s, OEScene scene, float f0, float f1, float dur, float amp, float pan) {
    Voice *v = newVoice(s, VoiceTone, scene);
    if (!v) return NULL;
    v->f0 = f0;
    v->f1 = f1;
    v->dur = dur;
    v->amp = amp;
    v->decay = dur / 4;
    panGains(pan, &v->gainL, &v->gainR);
    return v;
}

// MARK: Event makers

static void crackle(OESoundscape *s) {
    Rng *r = &s->rng;
    burst(s, OESceneFire, highpass(s->sampleRate, between(r, 1500, 4000), 0.707),
          0.05f + 0.6f * skewed(r, 4), between(r, 0.0003f, 0.0015f), signedRandom(r) * 0.7f);
}

static void pop(OESoundscape *s, float size) {
    Rng *r = &s->rng;
    burst(s, OESceneFire, bandpass(s->sampleRate, between(r, 500, 2500) / size, between(r, 2, 6)),
          size * between(r, 0.5f, 1.2f), between(r, 0.003f, 0.012f) * size, signedRandom(r) * 0.6f);
}

static void raindrop(OESoundscape *s, OEScene scene, float loudness) {
    Rng *r = &s->rng;
    burst(s, scene, bandpass(s->sampleRate, between(r, 2000, 7500), 1.2),
          loudness * (0.02f + 0.25f * skewed(r, 3)), between(r, 0.0008f, 0.003f), signedRandom(r));
}

static void plink(OESoundscape *s, OEScene scene, float loudness) {
    Rng *r = &s->rng;
    float f = between(r, 1400, 3500);
    Voice *v = tone(s, scene, f, f * between(r, 0.6f, 0.85f), between(r, 0.03f, 0.06f), loudness * between(r, 0.02f, 0.08f),
                    signedRandom(r));
    if (v) v->decay = between(r, 0.008f, 0.02f);
}

static void bubble(OESoundscape *s) {
    Rng *r = &s->rng;
    // Small bubbles ring higher and quieter. A bubble's pitch rises as it reaches the surface.
    float size = skewed(r, 2);
    float f = 1700 - 1300 * size;
    Voice *v = tone(s, OESceneStream, f, f * between(r, 1.3f, 1.8f), between(r, 0.02f, 0.05f),
                    0.03f + 0.12f * size, signedRandom(r) * 0.8f);
    if (v) v->decay = between(r, 0.006f, 0.02f);
}

static void birdCall(OESoundscape *s) {
    Rng *r = &s->rng;
    int notes = 1 + (int)(uniform(r) * 6);
    float f = between(r, 1800, 5000);
    float noteLength = between(r, 0.05f, 0.22f), gap = between(r, 0.03f, 0.14f);
    float sweep = between(r, 0.7f, 1.4f);
    float step = uniform(r) < 0.5f ? 1 : between(r, 0.88f, 1.08f); // repeat the note, or walk up or down
    float vibrato = uniform(r) < 0.4f ? between(r, 0.01f, 0.06f) : 0, vibratoRate = between(r, 15, 60);
    float distance = skewed(r, 1.5f); // most birds are far off
    float amp = 0.02f + 0.1f * (1 - distance), pan = signedRandom(r);
    float delay = 0;
    for (int i = 0; i < notes; i++) {
        float length = noteLength * between(r, 0.85f, 1.15f);
        Voice *v = tone(s, OESceneForest, f, f * sweep, length, amp * between(r, 0.7f, 1), pan);
        if (!v) break;
        v->bell = 1;
        v->delay = delay;
        v->vibrato = vibrato;
        v->vibratoRate = vibratoRate;
        delay += length + gap * between(r, 0.7f, 1.3f);
        f *= step;
    }
}

static void croak(OESoundscape *s) {
    Rng *r = &s->rng;
    float f = between(r, 110, 320), pulse = between(r, 18, 40), length = between(r, 0.12f, 0.4f);
    float amp = between(r, 0.03f, 0.1f), pan = signedRandom(r);
    int times = 1 + (int)(uniform(r) * 4);
    float delay = 0;
    for (int i = 0; i < times; i++) {
        Voice *v = newVoice(s, VoiceCroak, OESceneNight);
        if (!v) return;
        v->f0 = f;
        v->vibratoRate = pulse;
        v->dur = length;
        v->amp = amp;
        v->delay = delay;
        panGains(pan, &v->gainL, &v->gainR);
        delay += length + between(r, 0.15f, 0.5f);
    }
}

static void thunder(OESoundscape *s) {
    Rng *r = &s->rng;
    float closeness = skewed(r, 2);
    Voice *v = newVoice(s, VoiceThunder, OESceneStorm);
    if (!v) return;
    v->filter = lowpass(s->sampleRate, 120 + 400 * closeness, 0.6);
    v->dur = between(r, 4, 9);
    v->decay = v->dur / 4;
    v->f0 = between(r, 0.05f, 0.4f); // attack
    v->amp = 0.35f + 0.6f * closeness;
    v->rumble = 1;
    panGains(signedRandom(r) * 0.5f, &v->gainL, &v->gainR);
    // Close strikes start with a crack.
    if (closeness > 0.6f) burst(s, OESceneStorm, highpass(s->sampleRate, 400, 0.707), 0.5f * closeness, 0.06f, 0);
}

static void wave(OESoundscape *s) {
    Rng *r = &s->rng;
    Voice *v = newVoice(s, VoiceWave, OESceneOcean);
    if (!v) return;
    v->dur = between(r, 6, 11);
    v->peak = between(r, 0.4f, 0.6f);
    v->amp = between(r, 0.4f, 1.0f);
    v->filter = lowpass(s->sampleRate, 200, 0.707);
    panGains(signedRandom(r) * 0.35f, &v->gainL, &v->gainR);
}

// MARK: Rendering events

static inline float waveEnvelope(const Voice *v) {
    float u = v->t / v->dur;
    if (u < v->peak) {
        float x = u / v->peak;
        return x * x;
    }
    return expf(-(u - v->peak) * 4.6f / (1 - v->peak));
}

/// Slow per-voice updates: sweeping filters, rumbling.
static void controlVoice(OESoundscape *s, Voice *v, float tick) {
    if (v->delay > 0) return;
    if (v->kind == VoiceWave) {
        float e = waveEnvelope(v);
        v->filter = lowpass(s->sampleRate, 180 + 2800 * e, 0.6);
    } else if (v->kind == VoiceThunder) {
        v->rumbleHold -= tick;
        if (v->rumbleHold <= 0) {
            v->rumbleTarget = between(&s->rng, 0.3f, 1.2f);
            v->rumbleHold = between(&s->rng, 0.08f, 0.5f);
        }
        v->rumble += (v->rumbleTarget - v->rumble) * 0.08f;
    }
}

static inline void renderVoice(OESoundscape *s, Voice *v, float level, float *left, float *right) {
    float dt = s->dt;
    if (v->delay > 0) {
        v->delay -= dt;
        return;
    }
    Rng *r = &s->rng;
    float t = v->t;
    float l = 0, rr = 0;

    switch (v->kind) {
    case VoiceBurst: {
        float x = signedRandom(r) * v->amp * expf(-t / v->decay);
        float y = run(&v->filter, &v->stateL, x);
        l = y * v->gainL;
        rr = y * v->gainR;
        break;
    }
    case VoiceTone: {
        float progress = t / v->dur;
        float f = v->f0 + (v->f1 - v->f0) * progress;
        if (v->vibrato > 0) {
            v->vibratoPhase += 2 * (float)M_PI * v->vibratoRate * dt;
            f *= 1 + v->vibrato * sinf(v->vibratoPhase);
        }
        v->phase += 2 * (float)M_PI * f * dt;
        if (v->phase > 2 * (float)M_PI) v->phase -= 2 * (float)M_PI;
        float env;
        if (v->bell) {
            float b = sinf((float)M_PI * progress);
            env = b * b;
        } else {
            env = fminf(1, t / 0.001f) * expf(-t / v->decay);
        }
        float y = sinf(v->phase) * env * v->amp;
        l = y * v->gainL;
        rr = y * v->gainR;
        break;
    }
    case VoiceCroak: {
        v->phase += 2 * (float)M_PI * v->f0 * dt;
        if (v->phase > 2 * (float)M_PI) v->phase -= 2 * (float)M_PI;
        v->vibratoPhase += 2 * (float)M_PI * v->vibratoRate * dt;
        float pulse = 0.5f + 0.5f * sinf(v->vibratoPhase);
        pulse *= pulse * pulse;
        float b = sinf((float)M_PI * t / v->dur);
        float y = (sinf(v->phase) + 0.5f * sinf(2 * v->phase) + 0.25f * sinf(3 * v->phase)) * pulse * b * v->amp;
        l = y * v->gainL;
        rr = y * v->gainR;
        break;
    }
    case VoiceThunder: {
        float attack = v->f0;
        float env = t < attack ? t / attack : expf(-(t - attack) / v->decay);
        float g = env * v->amp * v->rumble;
        l = run(&v->filter, &v->stateL, brown(&v->brownL, signedRandom(r))) * g * v->gainL * 1.4f;
        rr = run(&v->filter, &v->stateR, brown(&v->brownR, signedRandom(r))) * g * v->gainR * 1.4f;
        break;
    }
    case VoiceWave: {
        float e = waveEnvelope(v);
        float g = e * v->amp;
        // Foam hiss after the wave breaks.
        float foam = t / v->dur > v->peak ? e * e * 0.08f : 0;
        l = (run(&v->filter, &v->stateL, pink(&v->pinkL, signedRandom(r))) * g + signedRandom(r) * foam * v->amp) * v->gainL;
        rr = (run(&v->filter, &v->stateR, pink(&v->pinkR, signedRandom(r))) * g + signedRandom(r) * foam * v->amp) * v->gainR;
        break;
    }
    }

    *left += l * level;
    *right += rr * level;
    v->t += dt;
    if (v->t >= v->dur) v->active = 0;
}

// MARK: Layers

static void rainSetup(Rain *rain, Rng *r, double fs, float bed, float drops, float plinks, float lowCut) {
    rain->high = highpass(fs, lowCut, 0.707);
    rain->low = lowpass(fs, 9000, 0.707);
    rain->intensity = wander(r, 0.55f, 1.0f, 4, 15, 3);
    rain->bedLevel = bed;
    rain->dropRate = drops;
    rain->plinkRate = plinks;
}

static inline void rainSample(OESoundscape *s, Rain *rain, OEScene scene, float level, float *left, float *right) {
    Rng *r = &s->rng;
    float i = rain->intensity.value;
    float g = rain->bedLevel * i * level;
    *left += run(&rain->low, &rain->lowL, run(&rain->high, &rain->highL, pink(&rain->pinkL, signedRandom(r)))) * g;
    *right += run(&rain->low, &rain->lowR, run(&rain->high, &rain->highR, pink(&rain->pinkR, signedRandom(r)))) * g;
    if ((rain->nextDrop -= s->dt) <= 0) {
        raindrop(s, scene, 0.6f + 0.4f * i);
        rain->nextDrop = waitFor(r, rain->dropRate * i);
    }
    if ((rain->nextPlink -= s->dt) <= 0) {
        plink(s, scene, i);
        rain->nextPlink = waitFor(r, rain->plinkRate * i);
    }
}

static void windSetup(Wind *w, Rng *r, float lo, float hi, float level) {
    w->gust = wander(r, 0.15f, 1.0f, 0.8f, 4, 1.2f);
    w->centre = wander(r, lo, hi, 1, 5, 2);
    w->whistlePitch = wander(r, 500, 1300, 2, 8, 3);
    w->lo = lo;
    w->hi = hi;
    w->level = level;
}

static void windControl(OESoundscape *s, Wind *w, float tick) {
    float gust = wanderStep(&w->gust, &s->rng, tick);
    float centre = wanderStep(&w->centre, &s->rng, tick) * (0.8f + 0.4f * gust); // stronger gusts blow higher
    w->band = bandpass(s->sampleRate, centre, 0.8);
    w->whistle = bandpass(s->sampleRate, wanderStep(&w->whistlePitch, &s->rng, tick), 14);
}

static inline void windSample(OESoundscape *s, Wind *w, float level, float *left, float *right) {
    Rng *r = &s->rng;
    float gust = w->gust.value;
    float g = gust * w->level * level, whistle = gust * gust * gust * w->level * level * 0.6f;
    float pl = pink(&w->pinkL, signedRandom(r)), pr = pink(&w->pinkR, signedRandom(r));
    *left += run(&w->band, &w->bandL, pl) * g * 2.2f + run(&w->whistle, &w->whistleL, pl) * whistle * 4;
    *right += run(&w->band, &w->bandR, pr) * g * 2.2f + run(&w->whistle, &w->whistleR, pr) * whistle * 4;
}

static void cricketReset(Cricket *c, Rng *r) {
    c->freq = between(r, 3900, 5200);
    panGains(signedRandom(r), &c->gainL, &c->gainR);
    c->amp = between(r, 0.006f, 0.03f);
    c->interval = between(r, 0.35f, 1.1f);
    c->pulseGap = 1 / between(r, 25, 45);
    c->nextChirp = between(r, 0, 1);
}

static inline void cricketSample(OESoundscape *s, Cricket *c, float level, float *left, float *right) {
    Rng *r = &s->rng;
    float dt = s->dt;
    if ((c->nextChirp -= dt) <= 0) {
        c->pulsesLeft = 2 + (int)(uniform(r) * 3);
        c->pulseTimer = 0;
        c->nextChirp = c->interval * between(r, 0.9f, 1.1f);
        // Now and then a cricket goes quiet, and may come back from somewhere else.
        if (uniform(r) < 0.02f) {
            c->nextChirp += between(r, 2, 12);
            if (uniform(r) < 0.5f) cricketReset(c, r);
        }
    }
    if (c->pulsesLeft > 0 && (c->pulseTimer -= dt) <= 0) {
        c->pulsesLeft--;
        c->pulseTimer = c->pulseGap;
        c->pulsing = 1;
        c->pulseT = 0;
    }
    if (!c->pulsing) return;
    const float pulseLength = 0.014f;
    float b = sinf((float)M_PI * c->pulseT / pulseLength);
    c->phase += 2 * (float)M_PI * c->freq * dt;
    if (c->phase > 2 * (float)M_PI) c->phase -= 2 * (float)M_PI;
    float y = sinf(c->phase) * b * b * c->amp * level;
    *left += y * c->gainL;
    *right += y * c->gainR;
    c->pulseT += dt;
    if (c->pulseT >= pulseLength) c->pulsing = 0;
}

// MARK: Lifecycle

OESoundscape *oe_soundscape_create(double sampleRate, uint32_t seed) {
    OESoundscape *s = calloc(1, sizeof(OESoundscape));
    if (!s) return NULL;
    double fs = sampleRate;
    s->sampleRate = fs;
    s->dt = (float)(1.0 / fs);
    s->rng.state = seed ? seed : 0x9E3779B9u;
    Rng *r = &s->rng;
    s->levelGlide = 1 - expf(-(float)CONTROL_INTERVAL / (float)fs / 0.4f);
    atomic_store(&s->masterTarget, 1.0f);
    s->master = 1;

    s->fireLow = lowpass(fs, 380, 0.707);
    s->fireHigh = highpass(fs, 2500, 0.707);
    s->flicker = wander(r, 0.35f, 1.0f, 0.08f, 0.5f, 0.06f);
    s->crackleRate = wander(r, 4, 30, 0.5f, 3, 0.4f);

    rainSetup(&s->rain, r, fs, 0.55f, 120, 2.5f, 450);
    rainSetup(&s->stormRain, r, fs, 0.9f, 260, 4, 300);
    rainSetup(&s->forestRain, r, fs, 0.25f, 50, 3, 600);
    s->nextThunder = between(r, 3, 10);

    for (int i = 0; i < CRICKETS; i++) cricketReset(&s->crickets[i], r);
    windSetup(&s->breeze, r, 150, 450, 0.18f);
    s->nextCroak = between(r, 1, 5);

    s->insectBand = bandpass(fs, 6200, 3);
    s->insectSwell = wander(r, 0, 1, 3, 10, 2);
    s->nextBird = between(r, 0.5f, 3);

    s->surfLow = lowpass(fs, 220, 0.707);
    s->nextWave = between(r, 0.5f, 2);

    windSetup(&s->wind, r, 220, 900, 0.6f);

    s->streamBand = bandpass(fs, 900, 0.7);
    s->churn = wander(r, 0.45f, 1.0f, 0.03f, 0.15f, 0.02f);
    s->bubbleRate = wander(r, 20, 70, 1, 4, 0.5f);
    return s;
}

void oe_soundscape_destroy(OESoundscape *s) { free(s); }

void oe_soundscape_set_level(OESoundscape *s, OEScene scene, float level) {
    if (scene >= OESceneCount) return;
    atomic_store_explicit(&s->targets[scene], fminf(fmaxf(level, 0), 1), memory_order_relaxed);
}

void oe_soundscape_set_master(OESoundscape *s, float level) {
    atomic_store_explicit(&s->masterTarget, fminf(fmaxf(level, 0), 1), memory_order_relaxed);
}

// MARK: Rendering

// Brings every scene to roughly the same loudness (about -24 dBFS at full level), measured offline.
static const float sceneTrim[OESceneCount] = {
    [OESceneFire] = 1.45f, [OESceneRain] = 1.0f, [OESceneStorm] = 0.62f, [OESceneNight] = 2.1f,
    [OESceneForest] = 1.75f, [OESceneOcean] = 1.0f, [OESceneWind] = 0.63f, [OESceneStream] = 1.0f,
};

static void control(OESoundscape *s) {
    float tick = s->dt * CONTROL_INTERVAL;
    Rng *r = &s->rng;
    for (int i = 0; i < OESceneCount; i++) {
        float target = atomic_load_explicit(&s->targets[i], memory_order_relaxed) * sceneTrim[i];
        s->levels[i] += (target - s->levels[i]) * s->levelGlide;
        if (target == 0 && s->levels[i] < 1e-4f) s->levels[i] = 0;
    }
    s->master += (atomic_load_explicit(&s->masterTarget, memory_order_relaxed) - s->master) * s->levelGlide;

    wanderStep(&s->flicker, r, tick);
    wanderStep(&s->crackleRate, r, tick);
    wanderStep(&s->rain.intensity, r, tick);
    wanderStep(&s->stormRain.intensity, r, tick);
    wanderStep(&s->forestRain.intensity, r, tick);
    wanderStep(&s->insectSwell, r, tick);
    wanderStep(&s->churn, r, tick);
    wanderStep(&s->bubbleRate, r, tick);
    if (s->levels[OESceneNight] > 0) windControl(s, &s->breeze, tick);
    if (s->levels[OESceneWind] > 0) windControl(s, &s->wind, tick);
    for (int i = 0; i < MAX_VOICES; i++) {
        if (s->voices[i].active) controlVoice(s, &s->voices[i], tick);
    }
}

void oe_soundscape_render(OESoundscape *s, float *left, float *right, uint32_t frames) {
    Rng *r = &s->rng;
    float dt = s->dt;
    const float *lv = s->levels;

    for (uint32_t n = 0; n < frames; n++) {
        if (s->controlCountdown == 0) {
            control(s);
            s->controlCountdown = CONTROL_INTERVAL;
        }
        s->controlCountdown--;
        float l = 0, rr = 0;

        if (lv[OESceneFire] > 0) {
            float g = lv[OESceneFire];
            float flicker = s->flicker.value;
            l += run(&s->fireLow, &s->fireLowL, brown(&s->fireBrownL, signedRandom(r))) * flicker * 0.5f * g;
            rr += run(&s->fireLow, &s->fireLowR, brown(&s->fireBrownR, signedRandom(r))) * flicker * 0.5f * g;
            l += run(&s->fireHigh, &s->fireHighL, pink(&s->fireHissL, signedRandom(r))) * 0.05f * g;
            rr += run(&s->fireHigh, &s->fireHighR, pink(&s->fireHissR, signedRandom(r))) * 0.05f * g;
            if ((s->nextCrackle -= dt) <= 0) {
                crackle(s);
                s->nextCrackle = waitFor(r, s->crackleRate.value * flicker);
            }
            if ((s->nextPop -= dt) <= 0) {
                pop(s, 0.5f);
                s->nextPop = waitFor(r, 0.8f);
            }
            if ((s->nextSnap -= dt) <= 0) {
                pop(s, 1);
                s->nextSnap = waitFor(r, 0.07f);
            }
        }

        if (lv[OESceneRain] > 0) rainSample(s, &s->rain, OESceneRain, lv[OESceneRain], &l, &rr);

        if (lv[OESceneStorm] > 0) {
            rainSample(s, &s->stormRain, OESceneStorm, lv[OESceneStorm], &l, &rr);
            if ((s->nextThunder -= dt) <= 0) {
                thunder(s);
                s->nextThunder = between(r, 12, 45);
            }
        }

        if (lv[OESceneNight] > 0) {
            float g = lv[OESceneNight];
            for (int i = 0; i < CRICKETS; i++) cricketSample(s, &s->crickets[i], g, &l, &rr);
            windSample(s, &s->breeze, g, &l, &rr);
            if ((s->nextCroak -= dt) <= 0) {
                croak(s);
                s->nextCroak = waitFor(r, 0.15f);
            }
        }

        if (lv[OESceneForest] > 0) {
            float g = lv[OESceneForest];
            rainSample(s, &s->forestRain, OESceneForest, g, &l, &rr);
            // Cicada-like drone: a high buzz that swells and fades.
            s->insectPhase += 2 * (float)M_PI * 170 * dt;
            if (s->insectPhase > 2 * (float)M_PI) s->insectPhase -= 2 * (float)M_PI;
            float buzz = (0.6f + 0.4f * sinf(s->insectPhase)) * s->insectSwell.value * 0.05f * g;
            l += run(&s->insectBand, &s->insectL, signedRandom(r)) * buzz;
            rr += run(&s->insectBand, &s->insectR, signedRandom(r)) * buzz;
            if ((s->nextBird -= dt) <= 0) {
                birdCall(s);
                s->nextBird = waitFor(r, 0.45f);
            }
        }

        if (lv[OESceneOcean] > 0) {
            float g = lv[OESceneOcean];
            // A low surf underneath so the gaps between waves aren't silent.
            l += run(&s->surfLow, &s->surfLowL, brown(&s->surfL, signedRandom(r))) * 0.2f * g;
            rr += run(&s->surfLow, &s->surfLowR, brown(&s->surfR, signedRandom(r))) * 0.2f * g;
            if ((s->nextWave -= dt) <= 0) {
                wave(s);
                s->nextWave = between(r, 4, 9);
            }
        }

        if (lv[OESceneWind] > 0) windSample(s, &s->wind, lv[OESceneWind], &l, &rr);

        if (lv[OESceneStream] > 0) {
            float g = lv[OESceneStream] * s->churn.value * 0.6f;
            l += run(&s->streamBand, &s->streamBandL, pink(&s->streamL, signedRandom(r))) * g;
            rr += run(&s->streamBand, &s->streamBandR, pink(&s->streamR, signedRandom(r))) * g;
            if ((s->nextBubble -= dt) <= 0) {
                bubble(s);
                s->nextBubble = waitFor(r, s->bubbleRate.value);
            }
        }

        for (int i = 0; i < MAX_VOICES; i++) {
            Voice *v = &s->voices[i];
            if (v->active) renderVoice(s, v, lv[v->scene], &l, &rr);
        }

        // Rounded off rather than clipped, and well below full scale.
        left[n] = 0.7f * tanhf(l * s->master / 0.7f);
        right[n] = 0.7f * tanhf(rr * s->master / 0.7f);
    }
}

OSStatus oe_soundscape_callback(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp,
                                UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if (!data) return noErr;
    if (data->mNumberBuffers < 2) {
        for (UInt32 b = 0; b < data->mNumberBuffers; b++) memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
        return noErr;
    }
    oe_soundscape_render(refCon, data->mBuffers[0].mData, data->mBuffers[1].mData, frames);
    return noErr;
}
