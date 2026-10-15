#pragma once
// Filters and helpers shared by the mic effects and the soundscape generator.
// Biquads from Robert Bristow-Johnson's cookbook.

#include <math.h>

typedef struct { float b0, b1, b2, a1, a2; } Biquad;
typedef struct { float z1, z2; } BiquadState;

static inline Biquad identity(void) { return (Biquad){1, 0, 0, 0, 0}; }

static inline Biquad normalize(double b0, double b1, double b2, double a0, double a1, double a2) {
    return (Biquad){(float)(b0 / a0), (float)(b1 / a0), (float)(b2 / a0), (float)(a1 / a0), (float)(a2 / a0)};
}

static inline Biquad highpass(double fs, double f, double q) {
    double w = 2 * M_PI * f / fs, c = cos(w), alpha = sin(w) / (2 * q);
    return normalize((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
}

// Slope 0.5 and these corner frequencies match SoX's bass/treble, so earlier settings sound the same.
static inline Biquad shelf(double fs, double f, double gainDB, int high) {
    if (fabs(gainDB) < 0.01) return identity();
    double A = pow(10, gainDB / 40), w = 2 * M_PI * f / fs, c = cos(w), s = sin(w);
    double slope = 0.5;
    double alpha = s / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2);
    double sa = 2 * sqrt(A) * alpha;
    if (high) {
        return normalize(A * ((A + 1) + (A - 1) * c + sa), -2 * A * ((A - 1) + (A + 1) * c),
                         A * ((A + 1) + (A - 1) * c - sa), (A + 1) - (A - 1) * c + sa,
                         2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sa);
    }
    return normalize(A * ((A + 1) - (A - 1) * c + sa), 2 * A * ((A - 1) - (A + 1) * c),
                     A * ((A + 1) - (A - 1) * c - sa), (A + 1) + (A - 1) * c + sa,
                     -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - sa);
}

static inline Biquad lowpass(double fs, double f, double q) {
    double w = 2 * M_PI * f / fs, c = cos(w), alpha = sin(w) / (2 * q);
    return normalize((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha);
}

// Peak gain of 1 at the centre frequency.
static inline Biquad bandpass(double fs, double f, double q) {
    double w = 2 * M_PI * f / fs, c = cos(w), alpha = sin(w) / (2 * q);
    return normalize(alpha, 0, -alpha, 1 + alpha, -2 * c, 1 - alpha);
}

static inline Biquad peaking(double fs, double f, double q, double gainDB) {
    double A = pow(10, gainDB / 40), w = 2 * M_PI * f / fs, c = cos(w), alpha = sin(w) / (2 * q);
    return normalize(1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c, 1 - alpha / A);
}

static inline float run(const Biquad *k, BiquadState *s, float x) {
    float y = k->b0 * x + s->z1;
    s->z1 = k->b1 * x - k->a1 * y + s->z2;
    s->z2 = k->b2 * x - k->a2 * y;
    return y;
}

static inline float todB(float x) { return 20.0f * log10f(x + 1e-9f); }
static inline float fromdB(float db) { return powf(10.0f, db / 20.0f); }
static inline float coefficient(double fs, double seconds) { return (float)exp(-1.0 / (seconds * fs)); }
