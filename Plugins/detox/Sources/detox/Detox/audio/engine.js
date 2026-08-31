import { debugLog } from '../core/debug.js';

// Global envelope ID counter for debugging
let envelopeIdCounter = 0;

export class AudioEngine {
    constructor() {
        this.context = null;
        this.isInitialized = false;
        this.nodes = new Map();
        this.chains = [];
        this.masterGain = null;
        this.analyser = null;
        this.loadingCallback = null; // Callback for loading state changes
        this.mixers = new Map(); // Store named mixers with channels: { mixerName: { channelNum: gainNode } }
    }

    async init() {
        if (this.isInitialized) return;

        this.context = new (window.AudioContext || window.webkitAudioContext)();

        // Load DattorroReverb AudioWorklet
        try {
            await this.context.audioWorklet.addModule('audio/dattorroReverb.js');
            debugLog('DattorroReverb worklet loaded successfully');
        } catch (error) {
            console.error('Failed to load DattorroReverb worklet:', error);
        }

        // Create master gain and analyser with stereo configuration
        this.masterGain = this.context.createGain();
        this.masterGain.gain.value = 0.7;
        this.masterGain.channelCount = 2;
        this.masterGain.channelCountMode = 'explicit';
        this.masterGain.channelInterpretation = 'speakers';

        this.analyser = this.context.createAnalyser();
        this.analyser.fftSize = 2048;
        this.analyser.channelCount = 2;
        this.analyser.channelCountMode = 'explicit';
        this.analyser.channelInterpretation = 'speakers';

        this.masterGain.connect(this.analyser);
        this.analyser.connect(this.context.destination);

        this.isInitialized = true;
    }

    createOscillator(freq = 440, type = 'sine') {
        const osc = this.context.createOscillator();
        osc.type = type;
        osc.frequency.value = freq;
        // Oscillators output mono, but will be upmixed to stereo by downstream nodes
        osc.channelCount = 1;
        osc.channelCountMode = 'explicit';
        osc.channelInterpretation = 'speakers';
        return osc;
    }

    // Convert mono source to stereo by duplicating to both channels
    monoToStereo(monoNode) {
        const splitter = this.context.createChannelSplitter(1);
        const merger = this.context.createChannelMerger(2);

        monoNode.connect(splitter);
        splitter.connect(merger, 0, 0); // Connect to left
        splitter.connect(merger, 0, 1); // Connect to right

        return merger;
    }

    createNoise(type = 'white') {
        // Create noise generator using buffer source
        const bufferSize = this.context.sampleRate * 2; // 2 seconds of noise
        const buffer = this.context.createBuffer(1, bufferSize, this.context.sampleRate);
        const data = buffer.getChannelData(0);

        switch (type) {
            case 'white':
                // White noise - equal energy across all frequencies
                for (let i = 0; i < bufferSize; i++) {
                    data[i] = Math.random() * 2 - 1;
                }
                break;

            case 'pink':
                // Pink noise - equal energy per octave (1/f spectrum)
                let b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
                for (let i = 0; i < bufferSize; i++) {
                    const white = Math.random() * 2 - 1;
                    b0 = 0.99886 * b0 + white * 0.0555179;
                    b1 = 0.99332 * b1 + white * 0.0750759;
                    b2 = 0.96900 * b2 + white * 0.1538520;
                    b3 = 0.86650 * b3 + white * 0.3104856;
                    b4 = 0.55000 * b4 + white * 0.5329522;
                    b5 = -0.7616 * b5 - white * 0.0168980;
                    data[i] = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11;
                    b6 = white * 0.115926;
                }
                break;

            case 'brown':
                // Brown noise - even more low-frequency emphasis
                let lastOut = 0;
                for (let i = 0; i < bufferSize; i++) {
                    const white = Math.random() * 2 - 1;
                    data[i] = (lastOut + (0.02 * white)) / 1.02;
                    lastOut = data[i];
                    data[i] *= 3.5; // Compensate for amplitude loss
                }
                break;

            default:
                // Default to white noise
                for (let i = 0; i < bufferSize; i++) {
                    data[i] = Math.random() * 2 - 1;
                }
        }

        const source = this.context.createBufferSource();
        source.buffer = buffer;
        source.loop = true;
        return source;
    }

    createConstant(value = 0.5) {
        // Constant DC signal
        const constantSource = this.context.createConstantSource();
        constantSource.offset.value = value;
        return constantSource;
    }

    createImpulse(rate = 4) {
        // Generate impulse train using buffer
        const bufferSize = Math.floor(this.context.sampleRate / rate);
        const buffer = this.context.createBuffer(1, bufferSize, this.context.sampleRate);
        const data = buffer.getChannelData(0);

        // First sample is impulse, rest is silence
        data[0] = 1.0;
        for (let i = 1; i < bufferSize; i++) {
            data[i] = 0;
        }

        const source = this.context.createBufferSource();
        source.buffer = buffer;
        source.loop = true;
        return source;
    }

    createClick(freq = 2) {
        // Metronome clicks
        const clickLength = 0.01; // 10ms click
        const period = 1 / freq;
        const bufferSize = Math.floor(this.context.sampleRate * period);
        const buffer = this.context.createBuffer(1, bufferSize, this.context.sampleRate);
        const data = buffer.getChannelData(0);

        const clickSamples = Math.floor(this.context.sampleRate * clickLength);
        for (let i = 0; i < clickSamples; i++) {
            // Short burst of noise
            data[i] = (Math.random() * 2 - 1) * Math.exp(-i / (clickSamples / 4));
        }

        const source = this.context.createBufferSource();
        source.buffer = buffer;
        source.loop = true;
        return source;
    }

    createPWM(freq = 220, width = 0.5) {
        // Pulse width modulation - variable duty cycle square wave
        // Use two sawtooth waves with different phases
        const osc1 = this.context.createOscillator();
        const osc2 = this.context.createOscillator();
        const inverter = this.context.createGain();
        const widthOffset = this.context.createConstantSource();
        const output = this.context.createGain();

        osc1.type = 'sawtooth';
        osc2.type = 'sawtooth';
        osc1.frequency.value = freq;
        osc2.frequency.value = freq;

        inverter.gain.value = -1;
        widthOffset.offset.value = width * 2 - 1; // Map 0-1 to -1 to 1

        // PWM = saw1 - (-saw2 + offset)
        osc1.connect(output);
        osc2.connect(inverter);
        inverter.connect(output);
        widthOffset.connect(output);

        widthOffset.start();

        return { osc1, osc2, output, widthOffset, freq, width };
    }

    createSub(freq = 110, octaves = -1) {
        // Sub-oscillator - adds octave below
        const output = this.context.createGain();

        // Main oscillator at original frequency
        const main = this.context.createOscillator();
        main.type = 'sawtooth';
        main.frequency.value = freq;

        // Sub oscillator at lower octave
        const subFreq = freq * Math.pow(2, octaves);
        const sub = this.context.createOscillator();
        sub.type = 'sine';
        sub.frequency.value = subFreq;

        // Mix both
        main.connect(output);
        sub.connect(output);
        output.gain.value = 0.6; // Normalize

        return { main, sub, output, freq };
    }

    createSupersaw(freq = 220, detune = 0.1, voices = 7) {
        // Supersaw - multiple detuned sawtooth oscillators
        const output = this.context.createGain();
        output.gain.value = 1 / voices; // Normalize volume

        const oscillators = [];
        const detuneAmount = detune * 100; // Convert to cents

        for (let i = 0; i < voices; i++) {
            const osc = this.context.createOscillator();
            osc.type = 'sawtooth';
            osc.frequency.value = freq;

            // Spread detune symmetrically around center
            const offset = (i - (voices - 1) / 2) / ((voices - 1) / 2);
            osc.detune.value = offset * detuneAmount;

            osc.connect(output);
            oscillators.push(osc);
        }

        return { oscillators, output, freq };
    }

    createFM(carrier = 440, modulator = 220, depth = 2) {
        // FM synthesis - frequency modulation
        const carrierOsc = this.context.createOscillator();
        const modulatorOsc = this.context.createOscillator();
        const modulatorGain = this.context.createGain();

        carrierOsc.type = 'sine';
        modulatorOsc.type = 'sine';
        carrierOsc.frequency.value = carrier;
        modulatorOsc.frequency.value = modulator;
        modulatorGain.gain.value = modulator * depth; // Modulation index

        modulatorOsc.connect(modulatorGain);
        modulatorGain.connect(carrierOsc.frequency);

        // Expose AudioParams for LFO modulation
        return {
            carrier: carrierOsc,
            modulator: modulatorOsc,
            output: carrierOsc,
            carrierFreq: carrierOsc.frequency,
            modulatorFreq: modulatorOsc.frequency,
            depth: modulatorGain.gain
        };
    }

    createAM(carrier = 440, modulator = 10, depth = 0.5) {
        // AM synthesis - amplitude modulation
        const carrierOsc = this.context.createOscillator();
        const modulatorOsc = this.context.createOscillator();
        const modulatorGain = this.context.createGain();
        const output = this.context.createGain();

        carrierOsc.type = 'sine';
        modulatorOsc.type = 'sine';
        carrierOsc.frequency.value = carrier;
        modulatorOsc.frequency.value = modulator;

        // Set up AM: output = carrier * (1 + depth * modulator)
        modulatorGain.gain.value = depth;
        output.gain.value = 1 - depth / 2; // DC offset

        carrierOsc.connect(output);
        modulatorOsc.connect(modulatorGain);
        modulatorGain.connect(output.gain);

        // Expose AudioParams for LFO modulation
        return {
            carrier: carrierOsc,
            modulator: modulatorOsc,
            output,
            carrierFreq: carrierOsc.frequency,
            modulatorFreq: modulatorOsc.frequency,
            depth: modulatorGain.gain
        };
    }

    createPluck(freq = 220, decay = 2) {
        // Karplus-Strong plucked string synthesis
        const sampleRate = this.context.sampleRate;
        const delayTime = 1 / freq;
        const bufferSize = Math.floor(sampleRate * delayTime);

        // Create initial noise burst
        const buffer = this.context.createBuffer(1, bufferSize, sampleRate);
        const data = buffer.getChannelData(0);
        for (let i = 0; i < bufferSize; i++) {
            data[i] = Math.random() * 2 - 1;
        }

        const source = this.context.createBufferSource();
        source.buffer = buffer;

        const delay = this.context.createDelay();
        delay.delayTime.value = delayTime;

        const feedback = this.context.createGain();
        feedback.gain.value = 0.99; // High feedback for sustain

        const dampening = this.context.createBiquadFilter();
        dampening.type = 'lowpass';
        dampening.frequency.value = 3000;

        const envelope = this.context.createGain();
        envelope.gain.setValueAtTime(1, this.context.currentTime);
        envelope.gain.exponentialRampToValueAtTime(0.001, this.context.currentTime + decay);

        // Karplus-Strong feedback loop
        source.connect(delay);
        delay.connect(dampening);
        dampening.connect(feedback);
        feedback.connect(delay);
        feedback.connect(envelope);

        return { source, output: envelope, freq };
    }

    async createSample(url, rate = 1) {
        // Load and play audio sample with pitch control
        try {
            const response = await fetch(url);
            const arrayBuffer = await response.arrayBuffer();
            const audioBuffer = await this.context.decodeAudioData(arrayBuffer);

            const source = this.context.createBufferSource();
            source.buffer = audioBuffer;
            source.playbackRate.value = rate;
            source.loop = false;

            return { source, output: source, url, rate };
        } catch (error) {
            console.error('Failed to load sample:', url, error);
            // Return silent fallback
            return { source: this.context.createGain(), output: this.context.createGain() };
        }
    }

    createLoop(buffer, start = 0, end = 1) {
        // Looping sample player
        if (!buffer || !buffer.duration) {
            console.error('Invalid buffer for loop');
            return this.context.createGain(); // Silent fallback
        }

        const source = this.context.createBufferSource();
        source.buffer = buffer;
        source.loop = true;
        source.loopStart = start * buffer.duration;
        source.loopEnd = end * buffer.duration;

        return source;
    }

    createGrain(buffer, position = 0.5, grainSize = 100) {
        // Granular sampler - plays small grains of audio
        if (!buffer || !buffer.duration) {
            console.error('Invalid buffer for grain');
            return this.context.createGain(); // Silent fallback
        }

        const output = this.context.createGain();
        const grainDuration = grainSize / 1000; // Convert ms to seconds
        const startTime = position * buffer.duration;

        // Create grain
        const source = this.context.createBufferSource();
        source.buffer = buffer;

        // Envelope for grain
        const envelope = this.context.createGain();
        const now = this.context.currentTime;

        envelope.gain.setValueAtTime(0, now);
        envelope.gain.linearRampToValueAtTime(1, now + grainDuration * 0.1);
        envelope.gain.linearRampToValueAtTime(1, now + grainDuration * 0.9);
        envelope.gain.linearRampToValueAtTime(0, now + grainDuration);

        source.connect(envelope);
        envelope.connect(output);

        // Play just this grain
        source.start(now, startTime, grainDuration);

        return output;
    }

    createWavetable(freq = 440, tableName = 'basic') {
        // Wavetable oscillator with predefined or custom tables
        const wavetables = {
            'basic': [0, 0.5, 1, 0.5, 0, -0.5, -1, -0.5], // Basic wave
            'bass': [0, 0.3, 0.7, 1, 0.7, 0.3, 0, -0.3, -0.7, -1, -0.7, -0.3], // Bass-rich
            'bright': [0, 0.8, 1, 0.5, 0, -0.5, -1, -0.8], // Bright harmonics
            'hollow': [0, 1, 0, -1, 0, 0.5, 0, -0.5], // Hollow sound
        };

        // Get wavetable data
        let tableData = wavetables[tableName] || wavetables['basic'];
        if (Array.isArray(tableName)) {
            tableData = tableName; // Custom table provided
        }

        // Create periodic wave from table
        const real = new Float32Array(tableData.length);
        const imag = new Float32Array(tableData.length);

        for (let i = 0; i < tableData.length; i++) {
            real[i] = tableData[i];
            imag[i] = 0;
        }

        const wave = this.context.createPeriodicWave(real, imag);
        const osc = this.context.createOscillator();
        osc.setPeriodicWave(wave);
        osc.frequency.value = freq;

        return osc;
    }

    createBlow(freq = 440, pressure = 0.8) {
        // Simple blown bottle/flute physical model using filtered noise
        const noise = this.createNoise('white');
        const filter = this.context.createBiquadFilter();
        const resonator = this.context.createBiquadFilter();
        const output = this.context.createGain();

        // High-pass to remove low frequencies
        filter.type = 'highpass';
        filter.frequency.value = freq * 0.5;
        filter.Q.value = 0.5;

        // Resonant filter at fundamental frequency
        resonator.type = 'bandpass';
        resonator.frequency.value = freq;
        resonator.Q.value = 20 * pressure; // Pressure affects resonance

        output.gain.value = pressure * 0.3;

        noise.connect(filter);
        filter.connect(resonator);
        resonator.connect(output);

        return { source: noise, output, freq };
    }

    createBow(freq = 440, pressure = 0.6) {
        // Bowed string model using sawtooth with vibrato and filtering
        const osc = this.context.createOscillator();
        const vibrato = this.context.createOscillator();
        const vibratoGain = this.context.createGain();
        const filter = this.context.createBiquadFilter();
        const output = this.context.createGain();

        osc.type = 'sawtooth';
        osc.frequency.value = freq;

        // Add vibrato for bowing effect
        vibrato.type = 'sine';
        vibrato.frequency.value = 5 + pressure * 3; // Faster vibrato with more pressure
        vibratoGain.gain.value = freq * 0.01 * pressure;

        vibrato.connect(vibratoGain);
        vibratoGain.connect(osc.frequency);

        // Lowpass filter for mellow tone
        filter.type = 'lowpass';
        filter.frequency.value = freq * 3;
        filter.Q.value = pressure * 2;

        output.gain.value = 0.3;

        osc.connect(filter);
        filter.connect(output);

        // Note: vibrato needs to be started by the caller along with osc

        return { osc, vibrato, output, freq };
    }

    createStrike(freq = 440, hardness = 0.8) {
        // Struck percussion model using filtered impulse with decay
        const noise = this.createNoise('white');
        const filter = this.context.createBiquadFilter();
        const resonator = this.context.createBiquadFilter();
        const envelope = this.context.createGain();
        const output = this.context.createGain();

        // Bandpass filter at strike frequency
        filter.type = 'bandpass';
        filter.frequency.value = freq;
        filter.Q.value = 10;

        // Resonant filter for metallic ring
        resonator.type = 'bandpass';
        resonator.frequency.value = freq * 1.5;
        resonator.Q.value = 20 * hardness;

        // Sharp attack, exponential decay
        const now = this.context.currentTime;
        const decayTime = 0.5 / hardness; // Harder strikes decay faster

        envelope.gain.setValueAtTime(1, now);
        envelope.gain.exponentialRampToValueAtTime(0.001, now + decayTime);

        output.gain.value = hardness * 0.5;

        noise.connect(filter);
        filter.connect(resonator);
        resonator.connect(envelope);
        envelope.connect(output);

        return { source: noise, output, freq };
    }

    createGain(value = 1.0) {
        const gain = this.context.createGain();
        gain.gain.value = value;
        // Ensure stereo processing
        gain.channelCount = 2;
        gain.channelCountMode = 'clamped-max';
        gain.channelInterpretation = 'speakers';
        return gain;
    }

    createPanner(position = 0) {
        const panner = this.context.createStereoPanner();
        panner.pan.value = Math.max(-1, Math.min(1, position));
        return panner;
    }

    createStereoWidth(width = 0.5, detune = 5) {
        // Create stereo width using all-pass filters for phase decorrelation
        // This creates a wide stereo effect without mono compatibility issues
        const input = this.context.createGain();
        const merger = this.context.createChannelMerger(2);

        // Create ConstantSourceNode for width parameter (for LFO modulation)
        const widthSource = this.context.createConstantSource();
        widthSource.offset.value = width;
        widthSource.start();

        // Create all-pass filters for phase shifts on each channel
        const allpassL1 = this.context.createBiquadFilter();
        const allpassL2 = this.context.createBiquadFilter();
        const allpassR1 = this.context.createBiquadFilter();
        const allpassR2 = this.context.createBiquadFilter();

        allpassL1.type = 'allpass';
        allpassL2.type = 'allpass';
        allpassR1.type = 'allpass';
        allpassR2.type = 'allpass';

        // Create gain nodes to scale width to frequency spread (0-1 * 1500Hz)
        const spreadGainL1 = this.context.createGain();
        const spreadGainL2 = this.context.createGain();
        const spreadGainR1 = this.context.createGain();
        const spreadGainR2 = this.context.createGain();

        spreadGainL1.gain.value = 1500 * 0.5;  // 0-750Hz
        spreadGainL2.gain.value = 1500;        // 0-1500Hz
        spreadGainR1.gain.value = 1500 * 0.8;  // 0-1200Hz
        spreadGainR2.gain.value = 1500 * 0.3;  // 0-450Hz

        // Connect width source through gain nodes to filter frequencies
        widthSource.connect(spreadGainL1);
        widthSource.connect(spreadGainL2);
        widthSource.connect(spreadGainR1);
        widthSource.connect(spreadGainR2);

        spreadGainL1.connect(allpassL1.frequency);
        spreadGainL2.connect(allpassL2.frequency);
        spreadGainR1.connect(allpassR1.frequency);
        spreadGainR2.connect(allpassR2.frequency);

        // Set base frequencies
        allpassL1.frequency.value = 500;
        allpassL2.frequency.value = 2000;
        allpassR1.frequency.value = 1000;
        allpassR2.frequency.value = 1500;

        allpassL1.Q.value = 0.5;
        allpassL2.Q.value = 0.5;
        allpassR1.Q.value = 0.5;
        allpassR2.Q.value = 0.5;

        // Add small delays for Haas effect
        const delayL = this.context.createDelay();
        const delayR = this.context.createDelay();
        const delayTimeGain = this.context.createGain();
        delayTimeGain.gain.value = 0.015; // Scale to max 15ms

        delayL.delayTime.value = 0;
        widthSource.connect(delayTimeGain);
        delayTimeGain.connect(delayR.delayTime);

        // Left channel: through allpass filters
        input.connect(allpassL1);
        allpassL1.connect(allpassL2);
        allpassL2.connect(delayL);
        delayL.connect(merger, 0, 0);

        // Right channel: through different allpass filters + delay
        input.connect(allpassR1);
        allpassR1.connect(allpassR2);
        allpassR2.connect(delayR);
        delayR.connect(merger, 0, 1);

        // Expose width parameter for external LFO modulation
        return { input: input, output: merger, width: widthSource.offset };
    }

    createPingPongDelay(time = 0.25, feedback = 0.4) {
        // Ping-pong delay that bounces between L and R
        // Clamp time to valid range (max 1 second by default)
        time = Math.max(0, Math.min(1, time));

        const delayL = this.context.createDelay();
        const delayR = this.context.createDelay();
        const feedbackL = this.context.createGain();
        const feedbackR = this.context.createGain();
        const merger = this.context.createChannelMerger(2);
        const inputGain = this.context.createGain();

        delayL.delayTime.value = time;
        delayR.delayTime.value = time;
        feedbackL.gain.value = feedback;
        feedbackR.gain.value = feedback;

        // Create ping-pong routing
        inputGain.connect(delayL);
        inputGain.connect(delayR);

        delayL.connect(feedbackL);
        delayR.connect(feedbackR);

        // Cross-feedback for ping-pong effect
        feedbackL.connect(delayR);
        feedbackR.connect(delayL);

        // Output to stereo
        delayL.connect(merger, 0, 0); // Left channel
        delayR.connect(merger, 0, 1); // Right channel

        // Return with exposed AudioParams for LFO modulation
        return {
            input: inputGain,
            output: merger,
            delayTimeL: delayL.delayTime,
            delayTimeR: delayR.delayTime,
            feedbackL: feedbackL.gain,
            feedbackR: feedbackR.gain
        };
    }

    createFilter(type = 'lowpass', freq = 1000, q = 1) {
        const filter = this.context.createBiquadFilter();
        filter.type = type;
        filter.frequency.value = freq;
        filter.Q.value = q;
        // Ensure stereo processing
        filter.channelCount = 2;
        filter.channelCountMode = 'clamped-max';
        filter.channelInterpretation = 'speakers';
        return filter;
    }

    createDelay(time = 0.5, feedback = 0.3) {
        const delay = this.context.createDelay();
        const feedbackGain = this.context.createGain();
        const wetGain = this.context.createGain();

        delay.delayTime.value = time;
        feedbackGain.gain.value = feedback;
        wetGain.gain.value = 0.5;

        delay.connect(feedbackGain);
        feedbackGain.connect(delay);
        delay.connect(wetGain);

        return { input: delay, output: wetGain, delay, feedbackGain, wetGain };
    }

    createConvolver(impulseLength = 2, type = 'hall') {
        const convolver = this.context.createConvolver();

        // Create reverb impulse response
        const sampleRate = this.context.sampleRate;
        const length = sampleRate * impulseLength;
        const impulse = this.context.createBuffer(2, length, sampleRate);

        for (let channel = 0; channel < 2; channel++) {
            const channelData = impulse.getChannelData(channel);

            if (type === 'plate') {
                // Plate reverb - brighter, more reflective
                for (let i = 0; i < length; i++) {
                    const decay = Math.pow(1 - i / length, 1.5);
                    // Add early reflections
                    let value = (Math.random() * 2 - 1) * decay;
                    if (i < length * 0.02) {
                        value *= Math.sin((i / (length * 0.02)) * Math.PI) * 2;
                    }
                    channelData[i] = value;
                }
            } else if (type === 'room') {
                // Room reverb - shorter, less dense
                for (let i = 0; i < length; i++) {
                    const decay = Math.pow(1 - i / length, 3);
                    channelData[i] = (Math.random() * 2 - 1) * decay;
                }
            } else {
                // Hall reverb - smooth, natural
                for (let i = 0; i < length; i++) {
                    const decay = Math.pow(1 - i / length, 2);
                    channelData[i] = (Math.random() * 2 - 1) * decay;
                }
            }
        }

        convolver.buffer = impulse;
        // Ensure stereo output
        convolver.channelCount = 2;
        convolver.channelCountMode = 'clamped-max';
        convolver.channelInterpretation = 'speakers';
        return convolver;
    }

    createDattorroReverb(params = {}) {
        // Full Dattorro reverb using AudioWorklet implementation
        // Parameters:
        // - preDelay: 0 to sampleRate-1 samples (default: 0)
        // - bandwidth: 0 to 1 (default: 0.9999)
        // - inputDiffusion1: 0 to 1 (default: 0.75)
        // - inputDiffusion2: 0 to 1 (default: 0.625)
        // - decay: 0 to 1 (default: 0.5)
        // - decayDiffusion1: 0 to 0.999999 (default: 0.7)
        // - decayDiffusion2: 0 to 0.999999 (default: 0.5)
        // - damping: 0 to 1 (default: 0.005)
        // - excursionRate: 0 to 2 Hz (default: 0.5)
        // - excursionDepth: 0 to 2 ms (default: 0.7)
        // - wet: 0 to 1 (default: 0.3)
        // - dry: 0 to 1 (default: 0.6)

        try {
            const reverbNode = new AudioWorkletNode(this.context, 'DattorroReverb', {
                numberOfInputs: 1,
                numberOfOutputs: 1,
                outputChannelCount: [2],
                channelCount: 2,
                channelCountMode: 'explicit',
                channelInterpretation: 'speakers'
            });

            // Set parameters if provided
            if (params.preDelay !== undefined) {
                reverbNode.parameters.get('preDelay').value = params.preDelay;
            }
            if (params.bandwidth !== undefined) {
                reverbNode.parameters.get('bandwidth').value = params.bandwidth;
            }
            if (params.inputDiffusion1 !== undefined) {
                reverbNode.parameters.get('inputDiffusion1').value = params.inputDiffusion1;
            }
            if (params.inputDiffusion2 !== undefined) {
                reverbNode.parameters.get('inputDiffusion2').value = params.inputDiffusion2;
            }
            if (params.decay !== undefined) {
                reverbNode.parameters.get('decay').value = params.decay;
            }
            if (params.decayDiffusion1 !== undefined) {
                reverbNode.parameters.get('decayDiffusion1').value = params.decayDiffusion1;
            }
            if (params.decayDiffusion2 !== undefined) {
                reverbNode.parameters.get('decayDiffusion2').value = params.decayDiffusion2;
            }
            if (params.damping !== undefined) {
                reverbNode.parameters.get('damping').value = params.damping;
            }
            if (params.excursionRate !== undefined) {
                reverbNode.parameters.get('excursionRate').value = params.excursionRate;
            }
            if (params.excursionDepth !== undefined) {
                reverbNode.parameters.get('excursionDepth').value = params.excursionDepth;
            }
            if (params.wet !== undefined) {
                reverbNode.parameters.get('wet').value = params.wet;
            }
            if (params.dry !== undefined) {
                reverbNode.parameters.get('dry').value = params.dry;
            }

            // AudioWorkletNode acts as both input and output
            // Expose key AudioParams for LFO modulation
            return {
                input: reverbNode,
                output: reverbNode,
                workletNode: reverbNode,
                decay: reverbNode.parameters.get('decay'),
                damping: reverbNode.parameters.get('damping'),
                wet: reverbNode.parameters.get('wet'),
                dry: reverbNode.parameters.get('dry'),
                excursionRate: reverbNode.parameters.get('excursionRate'),
                excursionDepth: reverbNode.parameters.get('excursionDepth')
            };
        } catch (error) {
            console.error('Failed to create DattorroReverb:', error);
            // Fallback to simple convolution reverb
            const convolver = this.createConvolver(2, 'hall');
            const wetGain = this.createGain(0.3);
            const dryGain = this.createGain(0.7);

            convolver.connect(wetGain);

            return {
                input: convolver,
                output: wetGain,
                convolver,
                wetGain,
                dryGain
            };
        }
    }

    createAllPass(delayTime, feedback) {
        const input = this.context.createGain();
        const output = this.context.createGain();
        const delay = this.context.createDelay();
        const feedbackGain = this.context.createGain();
        const feedforwardGain = this.context.createGain();

        delay.delayTime.value = delayTime;
        feedbackGain.gain.value = feedback;
        feedforwardGain.gain.value = -feedback;

        // All-pass filter structure
        input.connect(feedforwardGain);
        input.connect(delay);
        delay.connect(feedbackGain);
        feedbackGain.connect(delay);
        delay.connect(output);
        feedforwardGain.connect(output);

        return { input, output };
    }

    createChorus(rate = 1.5, depth = 0.002, mix = 0.5) {
        // Chorus effect using delay and LFO
        const input = this.context.createGain();
        const output = this.context.createGain();
        const dryGain = this.context.createGain();
        const wetGain = this.context.createGain();

        dryGain.gain.value = 1 - mix;
        wetGain.gain.value = mix;

        // Arrays to store LFOs and gains for external modulation
        const lfos = [];
        const lfoGains = [];

        // Create multiple delayed voices with LFO modulation
        const voices = 3;
        for (let i = 0; i < voices; i++) {
            const delay = this.context.createDelay();
            const lfo = this.context.createOscillator();
            const lfoGain = this.context.createGain();

            delay.delayTime.value = 0.02 + (i * 0.01);
            lfoGain.gain.value = depth;
            lfo.frequency.value = rate + (i * 0.3);

            lfo.connect(lfoGain);
            lfoGain.connect(delay.delayTime);

            input.connect(delay);
            delay.connect(wetGain);

            lfo.start();

            lfos.push(lfo);
            lfoGains.push(lfoGain);
        }

        input.connect(dryGain);
        dryGain.connect(output);
        wetGain.connect(output);

        // Expose AudioParams for external LFO modulation
        return {
            input,
            output,
            lfos,         // Array of internal LFO oscillators (for rate modulation)
            lfoGains,     // Array of LFO gain nodes (for depth modulation)
            mix: wetGain.gain  // Mix parameter
        };
    }

    createPhaser(rate = 0.5, depth = 1, stages = 4) {
        // Phaser using all-pass filters with LFO
        const input = this.context.createGain();
        const output = this.context.createGain();

        const lfo = this.context.createOscillator();
        lfo.frequency.value = rate;

        let current = input;
        const filters = [];
        const lfoGains = [];

        // Create cascade of all-pass filters
        for (let i = 0; i < stages; i++) {
            const filter = this.context.createBiquadFilter();
            filter.type = 'allpass';
            filter.frequency.value = 1000;
            filter.Q.value = 1;

            const lfoGain = this.context.createGain();
            lfoGain.gain.value = depth * 1000;

            lfo.connect(lfoGain);
            lfoGain.connect(filter.frequency);

            current.connect(filter);
            current = filter;
            filters.push(filter);
            lfoGains.push(lfoGain);
        }

        current.connect(output);
        input.connect(output); // Mix dry signal

        lfo.start();

        // Expose AudioParams for external LFO modulation
        return {
            input,
            output,
            lfo,         // Internal LFO (for rate modulation)
            lfoGains,    // Array of LFO gain nodes (for depth modulation)
            filters
        };
    }

    createDistortion(amount = 50, mix = 1.0) {
        // Waveshaper distortion
        const input = this.context.createGain();
        const output = this.context.createGain();
        const waveshaper = this.context.createWaveShaper();
        const dryGain = this.context.createGain();
        const wetGain = this.context.createGain();

        dryGain.gain.value = 1 - mix;
        wetGain.gain.value = mix;

        // Create distortion curve
        const samples = 44100;
        const curve = new Float32Array(samples);
        const deg = Math.PI / 180;

        for (let i = 0; i < samples; i++) {
            const x = (i * 2) / samples - 1;
            curve[i] = ((3 + amount) * x * 20 * deg) / (Math.PI + amount * Math.abs(x));
        }

        waveshaper.curve = curve;
        waveshaper.oversample = '4x';

        input.connect(dryGain);
        input.connect(waveshaper);
        waveshaper.connect(wetGain);

        dryGain.connect(output);
        wetGain.connect(output);

        return { input, output, waveshaper, dryGain, wetGain };
    }

    createBitcrusher(bits = 4, sampleRate = 4000) {
        // Bitcrusher using waveshaper
        const input = this.context.createGain();
        const output = this.context.createGain();
        const waveshaper = this.context.createWaveShaper();

        // Create bit reduction curve
        const samples = 44100;
        const curve = new Float32Array(samples);
        const step = Math.pow(0.5, bits);

        for (let i = 0; i < samples; i++) {
            const x = (i * 2) / samples - 1;
            curve[i] = Math.floor(x / step) * step;
        }

        waveshaper.curve = curve;

        input.connect(waveshaper);
        waveshaper.connect(output);

        return { input, output, waveshaper };
    }

    createEnvelopeGain(attack = 0.001, decay = 0.0, sustain = 1.0, release = 0.01) {
        // Create a gain node with envelope capabilities
        const gainNode = this.context.createGain();
        gainNode.gain.value = 0;

        // Use ConstantSourceNodes for all envelope parameters (enables LFO modulation)
        const attackParam = this.context.createConstantSource();
        attackParam.offset.value = attack;
        attackParam.start();

        const decayParam = this.context.createConstantSource();
        decayParam.offset.value = decay;
        decayParam.start();

        const sustainParam = this.context.createConstantSource();
        sustainParam.offset.value = sustain;
        sustainParam.start();

        const releaseParam = this.context.createConstantSource();
        releaseParam.offset.value = release;
        releaseParam.start();

        // Assign unique ID for debugging
        const envelopeId = ++envelopeIdCounter;

        const envelope = {
            input: gainNode,
            output: gainNode,
            gainNode: gainNode,
            attackParam: attackParam,
            decayParam: decayParam,
            sustainParam: sustainParam,
            releaseParam: releaseParam,
            _envelopeId: envelopeId,

            // Method to trigger the envelope
            trigger: function(duration = 1.0, startTime) {
                const now = startTime !== undefined ? startTime : this.gainNode.context.currentTime;
                const param = this.gainNode.gain;

                // Read envelope times from AudioParams (enables LFO modulation)
                const attack = this.attackParam.offset.value;
                const decay = this.decayParam.offset.value;
                const sustain = this.sustainParam.offset.value;
                const release = this.releaseParam.offset.value;

                // Get current value to start from (for smooth retriggering)
                const currentValue = param.value;

                param.cancelScheduledValues(now);
                param.setValueAtTime(currentValue, now);
                param.linearRampToValueAtTime(1, now + attack);
                param.linearRampToValueAtTime(sustain, now + attack + decay);

                // Hold sustain level until it's time to release
                const releaseStartTime = Math.max(now + duration - release, now + attack + decay);
                param.setValueAtTime(sustain, releaseStartTime);
                param.linearRampToValueAtTime(0, releaseStartTime + release);
            },

            // Method to trigger just the release phase (for portamento mode)
            releaseNow: function() {
                const now = this.gainNode.context.currentTime;
                const param = this.gainNode.gain;

                // Read release time from AudioParam
                const release = this.releaseParam.offset.value;

                // Cancel any scheduled values and start release from current position
                param.cancelScheduledValues(now);
                param.setValueAtTime(param.value, now);
                param.linearRampToValueAtTime(0, now + release);
            }
        };

        return envelope;
    }

    createEnvelope(attack = 0.001, decay = 0.0, sustain = 1.0, release = 0.01) {
        return { attack, decay, sustain, release };
    }

    applyEnvelope(param, envelope, duration = 1.0) {
        const now = this.context.currentTime;
        const { attack, decay, sustain, release } = envelope;

        param.cancelScheduledValues(now);
        param.setValueAtTime(0, now);
        param.linearRampToValueAtTime(1, now + attack);
        param.linearRampToValueAtTime(sustain, now + attack + decay);
        param.setValueAtTime(sustain, now + duration - release);
        param.linearRampToValueAtTime(0, now + duration);
    }

    createLFO(rate = 1, type = 'sine', depth = 1, offset = 0) {
        // Create an LFO (Low Frequency Oscillator) for parameter modulation
        // depth: modulation depth (amplitude of LFO)
        // offset: center value of modulation (DC offset)
        // The LFO output will oscillate between (offset - depth) and (offset + depth)

        const lfo = this.context.createOscillator();
        lfo.type = type;
        lfo.frequency.value = rate;

        const lfoGain = this.context.createGain();
        lfoGain.gain.value = depth;

        const lfoOffset = this.context.createConstantSource();
        lfoOffset.offset.value = offset;

        const merger = this.context.createGain();
        merger.gain.value = 1;

        // Connect: LFO -> Gain (for depth) -> Merger
        //          ConstantSource (for offset) -> Merger
        lfo.connect(lfoGain);
        lfoGain.connect(merger);

        if (offset !== 0) {
            lfoOffset.connect(merger);
            try {
                lfoOffset.start();
                lfoOffset._started = true;
            } catch(e) {
                // Already started, ignore
                debugLog('[LFO] lfoOffset already started, skipping');
            }
        }

        // Start the LFO (use try-catch to handle already-started oscillators)
        const startTime = this.context.currentTime;
        try {
            lfo.start(startTime);
            lfo._started = true;
            debugLog('[LFO START] Successfully started LFO');
        } catch(e) {
            // Oscillator already started (e.g., from cache reuse)
            debugLog('[LFO START] Oscillator already started, skipping');
        }

        return {
            isLFO: true,
            oscillator: lfo,
            gainNode: lfoGain,
            offsetSource: lfoOffset,
            rate: rate,
            type: type,
            depth: depth,
            offset: offset,
            output: merger, // The modulation output (LFO + offset)
            startTime: startTime,
            // Method to get current LFO value for control-rate parameters (like envelope)
            getCurrentValue: function() {
                const elapsed = this.oscillator.context.currentTime - this.startTime;
                const phase = (elapsed * this.rate) % 1.0;
                let sample = 0;

                // Calculate waveform value at current phase
                switch (this.type) {
                    case 'sine':
                        sample = Math.sin(phase * 2 * Math.PI);
                        break;
                    case 'square':
                        sample = phase < 0.5 ? 1 : -1;
                        break;
                    case 'sawtooth':
                        sample = 2 * phase - 1;
                        break;
                    case 'triangle':
                        sample = phase < 0.5 ? (4 * phase - 1) : (3 - 4 * phase);
                        break;
                    default:
                        sample = Math.sin(phase * 2 * Math.PI);
                }

                // Apply depth and offset: output = sample * depth + offset
                return sample * this.depth + this.offset;
            }
        };
    }

    createTremolo(rate = 5, depth = 0.5) {
        // Tremolo: amplitude modulation effect
        const input = this.context.createGain();
        const output = this.context.createGain();
        const lfo = this.context.createOscillator();
        const lfoGain = this.context.createGain();

        lfo.type = 'sine';
        lfo.frequency.value = rate;

        // LFO modulates between (1 - depth) and 1
        // So depth = 0.5 means modulation between 0.5 and 1
        lfoGain.gain.value = depth * 0.5;

        output.gain.value = 1 - (depth * 0.5);

        lfo.connect(lfoGain);
        lfoGain.connect(output.gain);

        input.connect(output);

        lfo.start();

        return { input, output, lfo, rate, depth };
    }

    createVibrato(rate = 5, depth = 10) {
        // Vibrato: pitch modulation using delay
        const input = this.context.createGain();
        const output = this.context.createGain();
        const delay = this.context.createDelay();
        const lfo = this.context.createOscillator();
        const lfoGain = this.context.createGain();

        lfo.type = 'sine';
        lfo.frequency.value = rate;

        // Convert depth from cents to delay time variation
        // depth in Hz, delay variation in seconds
        const delayVariation = depth / 1000;
        lfoGain.gain.value = delayVariation;

        delay.delayTime.value = 0.005; // 5ms base delay

        lfo.connect(lfoGain);
        lfoGain.connect(delay.delayTime);

        input.connect(delay);
        delay.connect(output);

        lfo.start();

        return { input, output, lfo, delay, rate, depth };
    }

    createAutoWah(rate = 0.5, depth = 800, center = 1000) {
        // Auto-wah: automatic filter sweep
        const input = this.context.createGain();
        const output = this.context.createGain();
        const filter = this.context.createBiquadFilter();
        const lfo = this.context.createOscillator();
        const lfoGain = this.context.createGain();

        filter.type = 'bandpass';
        filter.Q.value = 10; // High resonance for wah effect
        filter.frequency.value = center;

        lfo.type = 'sine';
        lfo.frequency.value = rate;
        lfoGain.gain.value = depth;

        lfo.connect(lfoGain);
        lfoGain.connect(filter.frequency);

        input.connect(filter);
        filter.connect(output);

        lfo.start();

        return { input, output, filter, lfo, rate, depth, center };
    }

    createAutoPan(rate = 0.5, depth = 1) {
        // Auto-pan: automatic stereo panning
        const input = this.context.createGain();
        const panner = this.context.createStereoPanner();
        const output = this.context.createGain();
        const lfo = this.context.createOscillator();
        const lfoGain = this.context.createGain();

        lfo.type = 'sine';
        lfo.frequency.value = rate;
        lfoGain.gain.value = depth; // -1 to 1

        panner.pan.value = 0;

        lfo.connect(lfoGain);
        lfoGain.connect(panner.pan);

        input.connect(panner);
        panner.connect(output);

        lfo.start();

        return { input, output, panner, lfo, rate, depth };
    }

    createRingMod(freq = 440) {
        // Ring modulation: multiply input signal with carrier oscillator
        const input = this.context.createGain();
        const output = this.context.createGain();
        const carrier = this.context.createOscillator();
        const modulator = this.context.createGain();

        carrier.type = 'sine';
        carrier.frequency.value = freq;

        // Ring modulation uses gain node as multiplier
        modulator.gain.value = 0;

        input.connect(modulator.gain);
        carrier.connect(modulator);
        modulator.connect(output);

        carrier.start();

        // Expose carrier frequency AudioParam for LFO modulation
        return { input, output, carrier, frequency: carrier.frequency };
    }

    createFlanger(rate = 0.5, depth = 0.002, feedback = 0.5) {
        // Flanger: short delay with LFO modulation
        const input = this.context.createGain();
        const output = this.context.createGain();
        const delay = this.context.createDelay();
        const feedbackGain = this.context.createGain();
        const lfo = this.context.createOscillator();
        const lfoGain = this.context.createGain();
        const dryGain = this.context.createGain();
        const wetGain = this.context.createGain();

        delay.delayTime.value = 0.003; // 3ms base delay
        feedbackGain.gain.value = feedback;
        dryGain.gain.value = 0.7;
        wetGain.gain.value = 0.7;

        lfo.type = 'sine';
        lfo.frequency.value = rate;
        lfoGain.gain.value = depth;

        lfo.connect(lfoGain);
        lfoGain.connect(delay.delayTime);

        input.connect(dryGain);
        input.connect(delay);
        delay.connect(feedbackGain);
        feedbackGain.connect(delay);
        delay.connect(wetGain);

        dryGain.connect(output);
        wetGain.connect(output);

        lfo.start();

        // Expose AudioParams for external LFO modulation
        return {
            input,
            output,
            delay,
            lfo,              // Internal LFO (for rate modulation via lfo.frequency)
            lfoGain,          // LFO gain (for depth modulation via lfoGain.gain)
            feedback: feedbackGain.gain  // Feedback parameter
        };
    }

    noteToFreq(note) {
        const notes = {
            'C': 0, 'C#': 1, 'Db': 1, 'D': 2, 'D#': 3, 'Eb': 3,
            'E': 4, 'F': 5, 'F#': 6, 'Gb': 6, 'G': 7, 'G#': 8,
            'Ab': 8, 'A': 9, 'A#': 10, 'Bb': 10, 'B': 11
        };

        const match = note.match(/^([A-G][#b]?)(\d+)$/);
        if (!match) return 440;

        const [, noteName, octave] = match;
        const noteNum = notes[noteName];
        const midiNote = (parseInt(octave) + 1) * 12 + noteNum;

        return 440 * Math.pow(2, (midiNote - 69) / 12);
    }

    stopAll() {
        this.chains.forEach(chain => {
            chain.nodes.forEach(node => {
                // Stop audio sources
                if (node.stop) {
                    try {
                        node.stop();
                    } catch (e) {
                        // Already stopped
                    }
                }

                // Disconnect all nodes to prevent audio buildup
                if (node.disconnect) {
                    try {
                        node.disconnect();
                    } catch (e) {
                        // Already disconnected
                    }
                }

                // Handle wrapped nodes with output property
                if (node.output && node.output.disconnect) {
                    try {
                        node.output.disconnect();
                    } catch (e) {
                        // Already disconnected
                    }
                }

                // Handle wrapped nodes with source property
                if (node.source) {
                    if (node.source.stop) {
                        try {
                            node.source.stop();
                        } catch (e) {
                            // Already stopped
                        }
                    }
                    if (node.source.disconnect) {
                        try {
                            node.source.disconnect();
                        } catch (e) {
                            // Already disconnected
                        }
                    }
                }
            });
        });
        this.chains = [];
        this.nodes.clear();
        this.clearMixers();
    }

    getAnalyserData() {
        if (!this.analyser) return null;

        const bufferLength = this.analyser.frequencyBinCount;
        const dataArray = new Uint8Array(bufferLength);
        this.analyser.getByteTimeDomainData(dataArray);

        return dataArray;
    }

    // Granular synthesis - creates texture by repeating and overlapping small chunks
    createGranular(grainSize = 50, density = 10, spread = 0.1, pitch = 1.0) {
        // For now, create a simple texture using multiple delays
        const input = this.context.createGain();
        const output = this.context.createGain();

        // Create multiple delay taps for grain-like texture
        const grainDelay = grainSize / 1000; // Convert ms to seconds
        const numGrains = Math.min(8, Math.ceil(density / 2));

        for (let i = 0; i < numGrains; i++) {
            const delay = this.context.createDelay();
            const delayGain = this.context.createGain();

            // Stagger delays to create overlapping grains
            delay.delayTime.value = (i * grainDelay) + (Math.random() * spread * grainDelay);
            delayGain.gain.value = 0.3 / numGrains; // Normalize

            input.connect(delay);
            delay.connect(delayGain);
            delayGain.connect(output);
        }

        // Also connect dry signal
        const dryGain = this.context.createGain();
        dryGain.gain.value = 0.3;
        input.connect(dryGain);
        dryGain.connect(output);

        return {
            input,
            output,
            isGranular: true
        };
    }

    // Granular sampler - loads audio file and plays back grains
    async createGranularSampler(source, grainSize = 100, density = 10, position = 0.5, spread = 0.1, pitch = 1.0, bufferRefreshRate = 1.0) {
        debugLog('createGranularSampler called with:', { source, grainSize, density, position, spread, pitch, bufferRefreshRate });
        debugLog('Source type:', typeof source, 'Has connect:', source && source.connect, 'Source:', source);

        const output = this.context.createGain();
        output.gain.value = 1.0;

        // Detect if source is a string (URL) or AudioNode (signal)
        const isSignalBased = source && typeof source === 'object' && source.connect;
        debugLog('isSignalBased:', isSignalBased);

        let audioBuffer = null;
        let circularBuffer = null;
        let writeHead = 0;
        let scriptNode = null;

        if (isSignalBased) {
            // Signal-based granular synthesis with circular buffer
            debugLog('Using signal-based granular synthesis');

            // Create circular buffer (bufferRefreshRate seconds at sample rate)
            const bufferSize = Math.floor(this.context.sampleRate * bufferRefreshRate);
            circularBuffer = new Float32Array(bufferSize);

            // Create a temporary audio buffer for grain extraction
            audioBuffer = this.context.createBuffer(1, bufferSize, this.context.sampleRate);

            // Create ScriptProcessorNode to record incoming audio
            const processorBufferSize = 4096;
            scriptNode = this.context.createScriptProcessor(processorBufferSize, 1, 1);

            scriptNode.onaudioprocess = (e) => {
                const input = e.inputBuffer.getChannelData(0);
                const output = e.outputBuffer.getChannelData(0);

                // Write to circular buffer
                for (let i = 0; i < input.length; i++) {
                    circularBuffer[writeHead] = input[i];
                    writeHead = (writeHead + 1) % circularBuffer.length;
                    output[i] = input[i]; // Pass through
                }

                // Update audioBuffer with current circular buffer contents
                const bufferData = audioBuffer.getChannelData(0);
                bufferData.set(circularBuffer);
            };

            // Connect input signal to script processor
            source.connect(scriptNode);

            // ScriptProcessorNode must be connected to destination to keep processing,
            // but we don't want to hear the raw signal. Connect through a muted gain node.
            const muteGain = this.context.createGain();
            muteGain.gain.value = 0;
            scriptNode.connect(muteGain);
            muteGain.connect(this.context.destination);

            debugLog('Circular buffer created. Size:', bufferSize, 'samples (', bufferRefreshRate, 'seconds)');
        } else {
            // File-based granular synthesis (existing behavior)
            debugLog('Using file-based granular synthesis');

            // Notify loading started
            if (this.loadingCallback) {
                this.loadingCallback(true, 'Loading audio...');
            }

            // Load audio file
            try {
                debugLog('Fetching audio file:', source);
                const response = await fetch(source);
                debugLog('Fetch response:', response.status);
                const arrayBuffer = await response.arrayBuffer();
                debugLog('ArrayBuffer size:', arrayBuffer.byteLength);
                audioBuffer = await this.context.decodeAudioData(arrayBuffer);
                debugLog('Audio decoded successfully. Duration:', audioBuffer.duration, 'seconds');

                // Notify loading complete
                if (this.loadingCallback) {
                    this.loadingCallback(false);
                }
            } catch (error) {
                console.error('Failed to load audio file:', error);

                // Notify loading complete (even on error)
                if (this.loadingCallback) {
                    this.loadingCallback(false);
                }

                return null;
            }
        }

        // Grain scheduler
        let grainSchedulerId = null;
        const activeGrains = [];

        // Store parameters as an object so they can be updated in real-time
        const grainParams = {
            grainSize: grainSize,
            density: density,
            position: position,
            spread: spread,
            pitch: pitch
        };

        let grainCount = 0;
        const scheduleGrain = () => {
            if (!audioBuffer) return;

            const now = this.context.currentTime;
            grainCount++;
            if (grainCount <= 3) {
                debugLog(`Scheduling grain #${grainCount} at time ${now}`);
            }

            // Create grain
            const grainSource = this.context.createBufferSource();
            grainSource.buffer = audioBuffer;

            // Randomize position with spread (read from grainParams for real-time updates)
            const centerPos = grainParams.position * audioBuffer.duration;
            const randomOffset = (Math.random() - 0.5) * grainParams.spread * audioBuffer.duration;
            const startPos = Math.max(0, Math.min(audioBuffer.duration - (grainParams.grainSize / 1000), centerPos + randomOffset));

            // Pitch shift (read from grainParams for real-time updates)
            grainSource.playbackRate.value = grainParams.pitch;

            // Envelope for grain
            const grainEnv = this.context.createGain();
            grainEnv.gain.value = 0;

            // Attack/Release for grain (smoother envelope)
            const attackTime = 0.02;
            const releaseTime = 0.02;
            const grainDuration = grainParams.grainSize / 1000;

            grainEnv.gain.setValueAtTime(0, now);
            grainEnv.gain.linearRampToValueAtTime(1.0, now + attackTime);
            grainEnv.gain.setValueAtTime(1.0, now + grainDuration - releaseTime);
            grainEnv.gain.linearRampToValueAtTime(0, now + grainDuration);

            // Connect grain
            grainSource.connect(grainEnv);
            grainEnv.connect(output);

            if (grainCount <= 3) {
                debugLog('Grain connected. Output node:', output, 'Output gain:', output.gain.value);
            }

            // Play grain
            grainSource.start(now, startPos, grainDuration);
            grainSource.stop(now + grainDuration);

            // Track active grain
            activeGrains.push({ source: grainSource, stopTime: now + grainDuration });

            // Clean up old grains
            const cleanupTime = now - 1;
            for (let i = activeGrains.length - 1; i >= 0; i--) {
                if (activeGrains[i].stopTime < cleanupTime) {
                    activeGrains.splice(i, 1);
                }
            }

            // Schedule next grain (read density from grainParams for real-time updates)
            const interval = 1000 / grainParams.density; // ms between grains
            grainSchedulerId = setTimeout(scheduleGrain, interval);
        };

        // Start grain scheduler
        scheduleGrain();

        return {
            output,
            buffer: audioBuffer,
            stop: () => {
                if (grainSchedulerId) {
                    clearTimeout(grainSchedulerId);
                }
                activeGrains.forEach(grain => {
                    try {
                        grain.source.stop();
                    } catch (e) {
                        // Already stopped
                    }
                });
                // Disconnect script node if using signal-based granular
                if (scriptNode) {
                    scriptNode.disconnect();
                    if (source && source.disconnect) {
                        try {
                            source.disconnect(scriptNode);
                        } catch (e) {
                            // Already disconnected
                        }
                    }
                }
            },
            isGranularSampler: true,
            isSignalBased: isSignalBased,
            params: grainParams  // Expose parameters for real-time updates
        };
    }

    // Multi-sample instrument sampler
    // Loads multiple samples and maps them across the keyboard
    async createMultiSampler(sampleMap) {
        debugLog('createMultiSampler called with:', sampleMap);

        // sampleMap should be an object like:
        // { 'A0': 'url', 'A2': 'url', 'A4': 'url', 'A6': 'url' }

        const loadedSamples = {};

        // Load all samples
        for (const [noteName, url] of Object.entries(sampleMap)) {
            try {
                debugLog(`Loading sample ${noteName} from ${url}`);
                const response = await fetch(url);
                const arrayBuffer = await response.arrayBuffer();
                const audioBuffer = await this.context.decodeAudioData(arrayBuffer);

                const noteFreq = this.noteToFreq(noteName);
                loadedSamples[noteName] = {
                    buffer: audioBuffer,
                    frequency: noteFreq
                };
                debugLog(`Loaded ${noteName} (${noteFreq}Hz), duration: ${audioBuffer.duration}s`);
            } catch (error) {
                console.error(`Failed to load sample ${noteName}:`, error);
            }
        }

        // Find nearest sample for a given frequency
        const findNearestSample = (targetFreq) => {
            let nearest = null;
            let nearestDiff = Infinity;

            for (const [noteName, data] of Object.entries(loadedSamples)) {
                const diff = Math.abs(Math.log2(data.frequency / targetFreq));
                if (diff < nearestDiff) {
                    nearestDiff = diff;
                    nearest = data;
                }
            }

            return nearest;
        };

        return {
            loadedSamples,
            playNote: (frequency, time = 0) => {
                const nearest = findNearestSample(frequency);
                if (!nearest) {
                    console.warn('No samples loaded for frequency:', frequency);
                    return null;
                }

                // Calculate playback rate to pitch shift to target frequency
                const playbackRate = frequency / nearest.frequency;

                // Create source
                const source = this.context.createBufferSource();
                source.buffer = nearest.buffer;
                source.playbackRate.value = playbackRate;

                const output = this.context.createGain();
                output.gain.value = 1.0;

                source.connect(output);

                return {
                    source,
                    output,
                    start: (when = this.context.currentTime) => {
                        source.start(when);
                    },
                    stop: (when = this.context.currentTime) => {
                        source.stop(when);
                    }
                };
            },
            isMultiSampler: true
        };
    }

    // Stutter - repeats small buffer chunks (Alva Noto style)
    createStutter(rate = 8, length = 0.125) {
        const input = this.context.createGain();
        const output = this.context.createGain();

        // Create delay line for stutter effect
        const delay = this.context.createDelay(1.0);
        const feedback = this.context.createGain();

        // Set delay time based on rate
        delay.delayTime.value = length;
        feedback.gain.value = 0.7; // Feedback for repetition

        // Create rhythmic gate for stutter
        const gateGain = this.context.createGain();
        let currentStep = 0;

        const scheduleStutter = () => {
            const now = this.context.currentTime;
            const stepDuration = 1 / rate;

            // Create stutter pattern: quick on/off
            gateGain.gain.cancelScheduledValues(now);
            gateGain.gain.setValueAtTime(1, now);
            gateGain.gain.setValueAtTime(1, now + length);
            gateGain.gain.linearRampToValueAtTime(0, now + length + 0.01);

            setTimeout(scheduleStutter, stepDuration * 1000);
        };

        scheduleStutter();

        // Connect: input -> delay -> feedback -> delay (loop)
        input.connect(delay);
        delay.connect(gateGain);
        gateGain.connect(feedback);
        feedback.connect(delay);
        gateGain.connect(output);

        // Also pass through some dry signal
        input.connect(output);

        return {
            input,
            output,
            delay,
            feedback,
            isStutter: true
        };
    }

    // Freeze - holds and loops a moment in time (simplified: long delay)
    createFreeze(fadeTime = 0.01) {
        const input = this.context.createGain();
        const output = this.context.createGain();

        // Use a long delay with high feedback for freeze effect
        const delay = this.context.createDelay(2.0);
        const feedback = this.context.createGain();
        const wetGain = this.context.createGain();
        const dryGain = this.context.createGain();

        delay.delayTime.value = 0.5; // Half second delay
        feedback.gain.value = 0.6; // High feedback for sustain (reduced to prevent buildup)
        wetGain.gain.value = 0.3; // Wet signal (reduced)
        dryGain.gain.value = 0.3; // Dry signal (reduced)

        // Add a compressor to prevent clipping from buildup
        const compressor = this.context.createDynamicsCompressor();
        compressor.threshold.value = -24;
        compressor.knee.value = 10;
        compressor.ratio.value = 12;
        compressor.attack.value = 0.003;
        compressor.release.value = 0.25;

        input.connect(delay);
        delay.connect(feedback);
        feedback.connect(delay);
        delay.connect(wetGain);
        wetGain.connect(compressor);
        compressor.connect(output);

        // Pass through dry signal
        input.connect(dryGain);
        dryGain.connect(output);

        return {
            input,
            output,
            delay,
            feedback,
            isFreeze: true
        };
    }

    // Gate - rhythmic on/off (Alva Noto's signature sound)
    createGate(rate = 16, pattern = [1, 0, 1, 0]) {
        const input = this.context.createGain();
        const output = this.context.createGain();

        // Pattern defines which steps are on (1) or off (0)
        const patternLength = pattern.length;
        let currentStep = 0;
        let gateScheduler = null;

        // Schedule gate pattern
        const scheduleGate = () => {
            const now = this.context.currentTime;
            const stepDuration = 1 / rate;

            // Set gain based on pattern
            const isOn = pattern[currentStep % patternLength];
            output.gain.cancelScheduledValues(now);
            output.gain.setValueAtTime(output.gain.value, now);
            output.gain.linearRampToValueAtTime(isOn ? 0.8 : 0, now + stepDuration * 0.1); // Reduced from 1 to 0.8

            currentStep++;
            gateScheduler = setTimeout(scheduleGate, stepDuration * 1000);
        };

        scheduleGate();

        input.connect(output);

        return {
            input,
            output,
            rate,
            pattern,
            stop: () => {
                if (gateScheduler) {
                    clearTimeout(gateScheduler);
                }
            },
            isGate: true
        };
    }

    // Downsample - reduces sample rate for lo-fi digital glitch sound
    createDownsample(factor = 4) {
        const input = this.context.createGain();
        const output = this.context.createGain();

        // Create a script processor for downsampling
        // Note: This is a simplified version - a proper implementation would use AudioWorklet
        const bufferSize = 256;
        const processor = this.context.createScriptProcessor(bufferSize, 1, 1);

        let holdSample = 0;
        let holdCounter = 0;

        processor.onaudioprocess = (e) => {
            const inputBuffer = e.inputBuffer.getChannelData(0);
            const outputBuffer = e.outputBuffer.getChannelData(0);

            for (let i = 0; i < bufferSize; i++) {
                if (holdCounter <= 0) {
                    holdSample = inputBuffer[i];
                    holdCounter = Math.floor(factor);
                }
                outputBuffer[i] = holdSample;
                holdCounter--;
            }
        };

        input.connect(processor);
        processor.connect(output);

        return {
            input,
            output,
            processor,
            factor,
            isDownsample: true
        };
    }

    // Glitch - random buffer manipulation and artifacts
    createGlitch(intensity = 0.5, rate = 10) {
        const input = this.context.createGain();
        const output = this.context.createGain();

        // Start at unity gain
        output.gain.value = 1;

        // Random gain modulation for glitchy artifacts
        let glitchScheduler = null;

        const scheduleGlitch = () => {
            const now = this.context.currentTime;
            const interval = 1 / rate;

            if (Math.random() < intensity) {
                // Random glitch event
                const glitchType = Math.random();

                if (glitchType < 0.33) {
                    // Quick mute
                    output.gain.setValueAtTime(0, now);
                    output.gain.setValueAtTime(0.8, now + 0.01);
                } else if (glitchType < 0.66) {
                    // Volume spike (reduced from 1.5 to 1.1)
                    output.gain.setValueAtTime(1.1, now);
                    output.gain.exponentialRampToValueAtTime(0.8, now + 0.05);
                } else {
                    // Micro-stutter (very fast gain modulation)
                    for (let i = 0; i < 3; i++) {
                        output.gain.setValueAtTime(0, now + i * 0.005);
                        output.gain.setValueAtTime(0.8, now + i * 0.005 + 0.0025);
                    }
                }
            }

            glitchScheduler = setTimeout(scheduleGlitch, interval * 1000);
        };

        scheduleGlitch();
        input.connect(output);

        return {
            input,
            output,
            intensity,
            rate,
            stop: () => {
                if (glitchScheduler) {
                    clearTimeout(glitchScheduler);
                }
            },
            isGlitch: true
        };
    }

    createLimiter(threshold = -3, attack = 0.003, release = 0.1) {
        // Brick-wall limiter using dynamics compressor with extreme settings
        // Plus output gain control to compensate for compressor makeup gain

        const limiter = this.context.createDynamicsCompressor();
        const outputGain = this.context.createGain();

        // Limiter settings - maximum ratio for brick-wall limiting
        limiter.threshold.value = threshold; // dB
        limiter.knee.value = 0; // Hard knee for brick-wall limiting
        limiter.ratio.value = 20; // Maximum ratio (20:1 is max for DynamicsCompressor)
        limiter.attack.value = attack; // Very fast attack to catch peaks (0.003 = 3ms)
        limiter.release.value = release; // Fast release

        // Reduce output to compensate for compressor's makeup gain
        // The compressor adds ~6-12dB of makeup gain automatically
        outputGain.gain.value = 0.5; // -6dB reduction

        // Connect: input -> limiter -> output gain -> output
        limiter.connect(outputGain);

        // Ensure stereo processing
        limiter.channelCount = 2;
        limiter.channelCountMode = 'clamped-max';
        limiter.channelInterpretation = 'speakers';
        outputGain.channelCount = 2;
        outputGain.channelCountMode = 'clamped-max';
        outputGain.channelInterpretation = 'speakers';

        // Return a compound node with input/output
        return {
            input: limiter,
            output: outputGain,
            limiter,
            outputGain
        };
    }

    createRandom(type = 'value', min = 0, max = 1, rate = 1000) {
        // Random value generator that updates periodically
        // type: 'value' (numbers), 'freq' (frequencies), 'note' (note frequencies)
        // min, max: range boundaries
        // rate: update rate in milliseconds

        const output = this.context.createConstantSource();
        let randomScheduler = null;

        // Store the parameters for potential updates
        const randomizer = {
            type,
            min,
            max,
            rate,
            output,
            offsetNode: output,
            isRandom: true,

            updateValue: function() {
                let newValue;

                if (this.type === 'note') {
                    // Generate random MIDI note number in range, then convert to frequency
                    const midiNote = Math.floor(Math.random() * (this.max - this.min + 1)) + this.min;
                    newValue = 440 * Math.pow(2, (midiNote - 69) / 12);
                } else if (this.type === 'freq') {
                    // Generate random frequency in range
                    newValue = Math.random() * (this.max - this.min) + this.min;
                } else {
                    // Generate random value in range
                    newValue = Math.random() * (this.max - this.min) + this.min;
                }

                // Use direct value assignment for immediate, glitch-free updates
                this.output.offset.value = newValue;
            },

            start: function() {
                // Start the constant source FIRST
                this.output.start();

                // Set initial value
                let initialValue;
                if (this.type === 'note') {
                    const midiNote = Math.floor(Math.random() * (this.max - this.min + 1)) + this.min;
                    initialValue = 440 * Math.pow(2, (midiNote - 69) / 12);
                } else if (this.type === 'freq') {
                    initialValue = Math.random() * (this.max - this.min) + this.min;
                } else {
                    initialValue = Math.random() * (this.max - this.min) + this.min;
                }

                // Set initial value at audio context time 0 (or current time if already started)
                const now = this.output.context.currentTime;
                this.output.offset.setValueAtTime(initialValue, now);

                // Schedule periodic updates
                const scheduleUpdate = () => {
                    this.updateValue();
                    randomScheduler = setTimeout(scheduleUpdate, this.rate);
                };

                scheduleUpdate();
            },

            stop: function() {
                if (randomScheduler) {
                    clearTimeout(randomScheduler);
                    randomScheduler = null;
                }
            }
        };

        return randomizer;
    }

    // === MIXER SYSTEM ===
    // Get or create a mixer channel
    getMixerChannel(mixerName, channelNum) {
        if (!this.mixers.has(mixerName)) {
            this.mixers.set(mixerName, new Map());
            debugLog('[MIXER] Created new mixer:', mixerName);
        }

        const mixer = this.mixers.get(mixerName);

        if (!mixer.has(channelNum)) {
            // Create a new channel (gain node)
            const channelGain = this.context.createGain();
            channelGain.gain.value = 1.0;
            mixer.set(channelNum, channelGain);
            debugLog('[MIXER] Created channel', channelNum, 'for mixer', mixerName);
        }

        return mixer.get(channelNum);
    }

    // Get mixer input(s) - returns a summing node if multiple channels
    getMixerInput(mixerName, channels) {
        // channels can be a single number or array of numbers
        const channelArray = Array.isArray(channels) ? channels : [channels];

        debugLog('[MIXER] Getting input from mixer:', mixerName, 'channels:', channelArray);

        if (channelArray.length === 1) {
            // Single channel - disconnect it first to clear old connections
            const ch = this.getMixerChannel(mixerName, channelArray[0]);
            ch.disconnect(); // Clear any previous connections
            debugLog('[MIXER] Returning single channel', channelArray[0], 'from mixer', mixerName);
            return ch;
        } else {
            // Multiple channels - create a summing gain node
            const sum = this.context.createGain();
            sum.gain.value = 1.0;

            // Disconnect and reconnect all requested channels to the NEW sum
            channelArray.forEach(channelNum => {
                const channel = this.getMixerChannel(mixerName, channelNum);
                channel.disconnect(); // Clear any previous connections
                channel.connect(sum);
                debugLog('[MIXER] Connected channel', channelNum, 'to sum');
            });

            debugLog('[MIXER] Returning sum of', channelArray.length, 'channels from mixer', mixerName);
            return sum;
        }
    }

    // Clear all mixers (called on stop)
    clearMixers() {
        this.mixers.forEach((mixer, mixerName) => {
            mixer.forEach((channelGain, channelNum) => {
                channelGain.disconnect();
            });
            mixer.clear();
        });
        this.mixers.clear();
    }

    // ========================================
    // NEW EURORACK-STYLE MODULES
    // ========================================

    // VCA - Voltage Controlled Amplifier
    createVCA(cvInput) {
        const vca = this.context.createGain();

        // If no CV input, act as unity gain passthrough
        if (!cvInput || !cvInput.connect) {
            vca.gain.value = 1.0; // Unity gain
        } else {
            vca.gain.value = 0; // Start at 0, controlled by CV
            cvInput.connect(vca.gain);
        }

        return vca;
    }


    // Compressor - Dynamics control
    createCompressor(threshold = -24, ratio = 4, attack = 0.003, release = 0.25) {
        const compressor = this.context.createDynamicsCompressor();
        compressor.threshold.value = threshold;
        compressor.ratio.value = ratio;
        compressor.attack.value = attack;
        compressor.release.value = release;
        compressor.knee.value = 30; // Soft knee

        return compressor;
    }

    // Sidechain Compression
    createSidechain(sidechainInput, threshold = -24, ratio = 8, attack = 0.001, release = 0.1) {
        const compressor = this.context.createDynamicsCompressor();
        compressor.threshold.value = threshold;
        compressor.ratio.value = ratio;
        compressor.attack.value = attack;
        compressor.release.value = release;
        compressor.knee.value = 10;

        // Connect sidechain input if provided
        if (sidechainInput && sidechainInput.connect) {
            sidechainInput.connect(compressor);
        }

        return compressor;
    }

    // Crossfade - Mix between two signals
    createCrossfade(signalB, position = 0.5) {
        // signalA will be connected as input, signalB passed as parameter
        const gainA = this.context.createGain();
        const gainB = this.context.createGain();
        const output = this.context.createGain();
        output.gain.value = 1.0;

        // Create ConstantSourceNode for position control (for LFO modulation)
        const positionSource = this.context.createConstantSource();
        positionSource.offset.value = position;
        positionSource.start();

        // Create WaveShaperNodes for equal-power curve
        // For gainA: cos(position * PI/2) - decreases from 1 to 0
        const cosShaper = this.context.createWaveShaper();
        const cosCurve = new Float32Array(256);
        for (let i = 0; i < 256; i++) {
            const x = i / 255; // [0, 1]
            const angle = x * Math.PI / 2;
            cosCurve[i] = Math.cos(angle);
        }
        cosShaper.curve = cosCurve;
        cosShaper.oversample = '4x';

        // For gainB: sin(position * PI/2) - increases from 0 to 1
        const sinShaper = this.context.createWaveShaper();
        const sinCurve = new Float32Array(256);
        for (let i = 0; i < 256; i++) {
            const x = i / 255; // [0, 1]
            const angle = x * Math.PI / 2;
            sinCurve[i] = Math.sin(angle);
        }
        sinShaper.curve = sinCurve;
        sinShaper.oversample = '4x';

        // Connect position source through shapers to gains
        positionSource.connect(cosShaper);
        positionSource.connect(sinShaper);
        cosShaper.connect(gainA.gain);
        sinShaper.connect(gainB.gain);

        // Initialize gain values (will be overridden by WaveShaper)
        gainA.gain.value = 0;
        gainB.gain.value = 0;

        // Connect signal B
        if (signalB && signalB.connect) {
            signalB.connect(gainB);
        }

        gainA.connect(output);
        gainB.connect(output);

        // Return object with input for A, position control, and the output
        return { inputA: gainA, inputB: gainB, output, position: positionSource.offset };
    }

    // Sample & Hold
    createSampleHold(clockRate = 10) {
        // Create a constant source that will be updated
        const constantSource = this.context.createConstantSource();
        constantSource.offset.value = 0;
        constantSource.start();

        // Create clock using oscillator
        const clock = this.context.createOscillator();
        clock.frequency.value = clockRate;
        clock.type = 'square';
        clock.start();

        // We'll need a scriptProcessor to implement S&H logic
        // For now, return a simple lowpass gate effect as placeholder
        const gate = this.context.createGain();
        gate.gain.value = 1.0;

        // Store for later implementation with AudioWorklet
        gate._sampleHold = {
            clock,
            constantSource,
            rate: clockRate
        };

        return gate;
    }

    // Oscillator Sync - Hard sync
    createSync(modulatorFreq = 220) {
        // Create carrier oscillator (will be passed as input)
        // Create modulator oscillator for sync
        const modulator = this.context.createOscillator();
        modulator.frequency.value = modulatorFreq;
        modulator.type = 'sawtooth';

        // For true hard sync, we'd need an AudioWorklet
        // As a simplified version, use waveshaper for harmonic richness
        const shaper = this.context.createWaveShaper();
        const curve = new Float32Array(256);
        for (let i = 0; i < 256; i++) {
            const x = (i / 128) - 1;
            // Fold the waveform to simulate sync-like behavior
            curve[i] = Math.sin(x * Math.PI * 2) + Math.sin(x * Math.PI * 4) * 0.3;
        }
        shaper.curve = curve;

        shaper._sync = { modulator, modulatorFreq };
        modulator.start();

        return shaper;
    }

    // Wavefolder - Buchla-style
    createWavefolder(threshold = 0.7) {
        const folder = this.context.createWaveShaper();

        // Create folding transfer curve
        const samples = 1024;
        const curve = new Float32Array(samples);

        for (let i = 0; i < samples; i++) {
            let x = (i / samples) * 2 - 1;  // -1 to 1

            // Apply gain based on threshold (lower threshold = more folding)
            x = x / threshold;

            // Fold the wave when it exceeds ±1
            while (Math.abs(x) > 1) {
                if (x > 1) {
                    x = 2 - x;
                } else if (x < -1) {
                    x = -2 - x;
                }
            }

            curve[i] = x * 0.5; // Scale output
        }

        folder.curve = curve;
        folder.oversample = '4x'; // Better quality

        return folder;
    }

    // Euclidean Rhythm Generator
    createEuclidean(length = 16, pulses = 4, rotation = 0) {
        // Generate Euclidean rhythm pattern using Bjorklund algorithm
        const pattern = this.euclideanRhythm(length, pulses, rotation);

        // Create a buffer with the pattern
        const sampleRate = this.context.sampleRate;
        const stepDuration = 0.125; // 16th note at 120 BPM
        const bufferLength = Math.ceil(length * stepDuration * sampleRate);
        const buffer = this.context.createBuffer(1, bufferLength, sampleRate);
        const data = buffer.getChannelData(0);

        // Fill buffer with gates
        for (let step = 0; step < length; step++) {
            if (pattern[step]) {
                const startSample = Math.floor(step * stepDuration * sampleRate);
                const gateDuration = Math.floor(0.05 * sampleRate); // 50ms gate

                for (let i = 0; i < gateDuration && (startSample + i) < bufferLength; i++) {
                    data[startSample + i] = 1.0;
                }
            }
        }

        const source = this.context.createBufferSource();
        source.buffer = buffer;
        source.loop = true;

        // Don't start here - the parser will call start() automatically
        return source;
    }

    // Euclidean rhythm algorithm (Bjorklund algorithm)
    euclideanRhythm(steps, pulses, rotation = 0) {
        if (pulses > steps || pulses === 0 || steps === 0) {
            return new Array(steps).fill(0);
        }

        const pattern = [];
        const counts = [];
        const remainders = [];

        let divisor = steps - pulses;
        remainders.push(pulses);

        let level = 0;
        while (true) {
            counts[level] = Math.floor(divisor / remainders[level]);
            remainders[level + 1] = divisor % remainders[level];
            divisor = remainders[level];
            level++;
            if (remainders[level] <= 1) break;
        }
        counts[level] = divisor;

        const build = (level) => {
            if (level === -1) {
                pattern.push(0);
            } else if (level === -2) {
                pattern.push(1);
            } else {
                for (let i = 0; i < counts[level]; i++) {
                    build(level - 1);
                }
                if (remainders[level] !== 0) {
                    build(level - 2);
                }
            }
        };

        build(level);

        // Apply rotation
        if (rotation !== 0) {
            const rot = ((rotation % steps) + steps) % steps;
            return [...pattern.slice(rot), ...pattern.slice(0, rot)];
        }

        return pattern;
    }

    // Pitch Shifter - Simple delay-based approximation
    createPitchShift(semitones = 0) {
        // For now, just return a gain node as pitch shifting is complex
        // A proper implementation would require AudioWorklet or complex granular synthesis

        // Convert semitones to gain approximation (simplified)
        const gain = this.context.createGain();
        gain.gain.value = 1.0; // Unity gain, pitch shifting disabled for now

        // Store semitones info for potential future implementation
        gain._pitchShift = {
            semitones,
            rate: Math.pow(2, semitones / 12)
        };

        return gain;
    }

    // Portamento / Glide - marker for continuous oscillator mode
    createPortamento(time = 0.1) {
        // Create a passthrough gain node that acts as a marker for portamento
        const gain = this.context.createGain();
        gain.gain.value = 1.0;

        // Mark this node as a portamento controller
        gain._isPortamento = true;

        // Use ConstantSourceNode for glide time (enables LFO modulation)
        const glideTimeParam = this.context.createConstantSource();
        glideTimeParam.offset.value = time;
        glideTimeParam.start();

        gain._glideTimeParam = glideTimeParam;

        return gain;
    }

}
