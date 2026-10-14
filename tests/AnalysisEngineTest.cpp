// Tests for the iPad app's JUCE-free analysis engine (iPad/KDM/Engine).
// Builds and runs anywhere with a C++17 compiler (ctest), no Apple SDK needed.

#include "AnalysisEngine.h"

#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace
{
    int failures = 0;
    void check (bool cond, const std::string& msg)
    {
        std::printf ("[%s] %s\n", cond ? "PASS" : "FAIL", msg.c_str());
        if (! cond) ++failures;
    }

    constexpr double kSR = 48000.0;
    constexpr double kPi = 3.14159265358979323846;

    double midiToHz (int midi) { return 440.0 * std::pow (2.0, (midi - 69) / 12.0); }

    // Harmonic tone (fundamental + a few decaying partials), like a simple synth.
    void addNote (std::vector<float>& buf, int midi, float amp)
    {
        const double f = midiToHz (midi);
        for (size_t n = 0; n < buf.size(); ++n)
            for (int h = 1; h <= 4; ++h)
                buf[n] += (float) (amp / h * std::sin (2.0 * kPi * f * h * (double) n / kSR));
    }

    // Feed a mono signal as stereo in host-sized blocks.
    void feed (AnalysisEngine& e, const std::vector<float>& sig, int block = 512)
    {
        for (int i = 0; i + block <= (int) sig.size(); i += block)
            e.process (sig.data() + i, sig.data() + i, block);
    }
}

int main()
{
    // --- Key, through the full audio path (FIFO -> Hann -> FFT -> chroma) -----
    // Same scale signals as ChromaKeyDetectorTest (scale + the tonic an octave up),
    // but rendered as audio.
    auto keyOf = [] (std::vector<int> notes, bool majorOnly)
    {
        AnalysisEngine e;
        e.setMajorOnly (majorOnly);
        e.prepare (kSR, 512);
        std::vector<float> sig ((size_t) (kSR * 6.0), 0.0f);
        for (int m : notes) addNote (sig, m, 0.05f);
        feed (e, sig);
        AnalysisEngine::Snapshot s; e.getSnapshot (s);
        return s;
    };
    {
        auto s = keyOf ({ 60, 62, 64, 65, 67, 69, 71, 72 }, true);
        std::printf ("C major scale -> pc %d (%s), corr %.2f\n", s.keyPitchClass, s.keyIsMinor ? "minor" : "major", s.keyCorrelation);
        check (s.keyPitchClass == 0 && ! s.keyIsMinor, "C major scale -> C major");
    }
    {
        auto s = keyOf ({ 67, 69, 71, 72, 74, 76, 78, 79 }, true);
        std::printf ("G major scale -> pc %d (%s)\n", s.keyPitchClass, s.keyIsMinor ? "minor" : "major");
        check (s.keyPitchClass == 7 && ! s.keyIsMinor, "G major scale -> G major");
    }
    {
        auto s = keyOf ({ 57, 59, 60, 62, 64, 65, 67, 69 }, false);
        std::printf ("A minor scale (minor enabled) -> pc %d (%s)\n", s.keyPitchClass, s.keyIsMinor ? "minor" : "major");
        check (s.keyPitchClass == 9 && s.keyIsMinor, "A minor scale -> A minor when minor keys are enabled");
    }
    {
        auto s = keyOf ({ 57, 59, 60, 62, 64, 65, 67, 69 }, true);
        check (s.keyPitchClass == 0 && ! s.keyIsMinor, "A minor scale -> relative C major in major-only mode");
    }

    // --- Tuner: A4 = 440 Hz ---------------------------------------------------
    {
        AnalysisEngine e;
        e.prepare (kSR, 512);
        std::vector<float> sig ((size_t) (kSR * 2.0), 0.0f);
        addNote (sig, 69, 0.3f);
        feed (e, sig);
        AnalysisEngine::Snapshot s; e.getSnapshot (s);
        std::printf ("A4 tone -> tuner %.2f Hz\n", s.tunerFrequency);
        check (std::abs (s.tunerFrequency - 440.0f) < 1.0f, "tuner reads 440 Hz");
    }

    // --- Meter: peak / RMS / clip, and reset after each snapshot --------------
    {
        AnalysisEngine e;
        e.prepare (kSR, 512);
        std::vector<float> left ((size_t) kSR), right ((size_t) kSR);
        for (size_t n = 0; n < left.size(); ++n)
        {
            left[n]  = (float) (0.5 * std::sin (2.0 * kPi * 1000.0 * (double) n / kSR));
            right[n] = (float) (0.25 * std::sin (2.0 * kPi * 1000.0 * (double) n / kSR));
        }
        for (int i = 0; i + 480 <= (int) left.size(); i += 480)
            e.process (left.data() + i, right.data() + i, 480);

        AnalysisEngine::Snapshot s; e.getSnapshot (s);
        std::printf ("meter L peak %.3f rms %.3f, R peak %.3f rms %.3f, ch %d\n",
                     s.levels[0].peak, s.levels[0].rms, s.levels[1].peak, s.levels[1].rms, s.numChannels);
        check (std::abs (s.levels[0].peak - 0.5f)    < 0.01f, "left peak 0.5");
        check (std::abs (s.levels[0].rms  - 0.3536f) < 0.01f, "left RMS 0.354 (sine)");
        check (std::abs (s.levels[1].peak - 0.25f)   < 0.01f, "right peak 0.25");
        check (s.numChannels == 2 && ! s.levels[0].clipped, "stereo, no clip");

        std::vector<float> hot (480, 1.0f);
        e.process (hot.data(), nullptr, 480);
        e.getSnapshot (s);
        check (s.levels[0].clipped && s.numChannels == 1, "full-scale mono input flags clip");

        e.getSnapshot (s);
        check (s.levels[0].peak == 0.0f && ! s.levels[0].clipped, "meter resets after snapshot");
    }

    // --- FFT matches a direct DFT on a few bins --------------------------------
    {
        AnalysisEngine e;
        e.prepare (kSR, 512);
        std::vector<float> sig ((size_t) AnalysisEngine::fftSize, 0.0f);
        uint32_t rng = 1;
        for (auto& v : sig) { rng = rng * 1664525u + 1013904223u; v = (float) ((double) rng / 4294967296.0 - 0.5); }
        e.process (sig.data(), nullptr, (int) sig.size());   // exactly one frame
        std::vector<float> mags; e.getSpectrum (mags);

        // Reference: Hann (normalised like JUCE) + DFT.
        const int N = AnalysisEngine::fftSize;
        std::vector<double> w ((size_t) N); double sum = 0;
        for (int i = 0; i < N; ++i) { w[(size_t) i] = 0.5 - 0.5 * std::cos (2.0 * kPi * i / (N - 1)); sum += w[(size_t) i]; }
        double maxRelErr = 0.0;
        for (int k : { 1, 17, 500, 2048, 4095 })
        {
            std::complex<double> X = 0;
            for (int n = 0; n < N; ++n)
                X += (double) sig[(size_t) n] * w[(size_t) n] * (N / sum) * std::polar (1.0, -2.0 * kPi * k * n / N);
            maxRelErr = std::max (maxRelErr, std::abs (std::abs (X) - mags[(size_t) k]) / std::max (1e-9, std::abs (X)));
        }
        std::printf ("FFT vs DFT max relative error %.2e\n", maxRelErr);
        check (maxRelErr < 1e-3, "FFT magnitudes match DFT");
    }

    std::printf (failures == 0 ? "\nAll AnalysisEngine tests passed.\n" : "\n%d failure(s).\n", failures);
    return failures == 0 ? 0 : 1;
}
