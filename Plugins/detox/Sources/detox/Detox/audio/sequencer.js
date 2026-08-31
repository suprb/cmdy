import { ScaleHelper } from './scales.js';
import { QUANTIZE_PRESETS, getQuantizePreset } from './quantizePresets.js';
import { debugLog } from '../core/debug.js';

export class Sequencer {
    constructor(audioEngine) {
        this.engine = audioEngine;
        this.scaleHelper = new ScaleHelper(audioEngine);
        this.sequences = [];
        this.isPlaying = false;
        this.bpm = 120;
        this.currentStep = 0;
        this.schedulerId = null;
        this.activeGranularSamplers = []; // Track active granular samplers
        this.currentQuantizePreset = QUANTIZE_PRESETS.straight; // Default to straight timing
    }

    setBPM(bpm) {
        this.bpm = bpm;
    }

    setQuantize(presetName) {
        const preset = getQuantizePreset(presetName);
        if (preset) {
            this.currentQuantizePreset = preset;
            debugLog(`Quantize preset set to: ${preset.name}`);
        } else {
            console.warn(`Quantize preset not found: ${presetName}`);
        }
    }

    getQuantizeOffset(stepIndex, sequence = null) {
        // Calculate timing offset in seconds for the given step
        // Check for sequence-specific quantize preset first, then fall back to global
        let preset = null;

        if (sequence && sequence.quantizePreset) {
            // Use sequence-specific quantize preset
            preset = getQuantizePreset(sequence.quantizePreset);
        } else if (this.currentQuantizePreset) {
            // Use global quantize preset
            preset = this.currentQuantizePreset;
        }

        if (!preset || !preset.offsets) {
            return 0;
        }

        const offset = preset.offsets[stepIndex % 16];

        // Calculate 16th note duration in seconds
        const beatDuration = 60 / this.bpm;
        const sixteenthNoteDuration = (beatDuration * 4) / 16;

        // Convert offset percentage to seconds
        // Positive offset = delay, negative = rush
        const offsetSeconds = (offset / 100) * sixteenthNoteDuration;

        return offsetSeconds;
    }

    addSequence(notesOrParams, subdivision, oscType, chain, hasOut = true, mixerInfo = null) {
        const sequence = {
            subdivision,
            oscType,
            chain,
            hasOut,
            mixerInfo, // Store mixer routing info { mixerName, channels }
            currentStep: 0,
            activeVoices: [], // Track currently playing voices for this sequence
            maxVoices: null,   // Voice limit (null = unlimited)
            chainOverrides: {} // Store runtime parameter overrides (e.g., { osc: { waveform: 'square' } })
        };

        // Check if it's a tracker pattern
        if (notesOrParams && notesOrParams.pattern && notesOrParams.channels) {
            // Tracker mode
            debugLog('Adding tracker sequence:', notesOrParams);
            sequence.pattern = notesOrParams.pattern;
            sequence.channels = notesOrParams.channels;
            sequence.sources = notesOrParams.sources; // Source modules per channel
            sequence.isTracker = true;
            sequence.length = notesOrParams.pattern.length;

            // Check if multi-channel (pattern rows are arrays)
            sequence.isMultiChannel = Array.isArray(notesOrParams.pattern[0]);
            debugLog('Tracker sequence added:', sequence);
        }
        // Check if it's a generator function or static notes
        else if (notesOrParams && notesOrParams.generator) {
            // Generator mode
            sequence.generator = this.compileGenerator(notesOrParams.generator);
            sequence.length = notesOrParams.length || 16;
            sequence.isGenerator = true;
        } else if (notesOrParams && notesOrParams.notes) {
            // Old API with params object
            sequence.notes = notesOrParams.notes;
            sequence.isGenerator = false;
        } else {
            // Simple array of notes
            sequence.notes = notesOrParams;
            sequence.isGenerator = false;
        }

        // Store scale transform if present
        if (notesOrParams && notesOrParams.scaleTransform) {
            sequence.scaleTransform = notesOrParams.scaleTransform;
        }

        // Restore preserved continuous oscillator if this is a recompile
        if (this.preservedOscillators && this.preservedOscillators.length > 0) {
            const preserved = this.preservedOscillators.shift(); // Get first preserved oscillator
            if (preserved) {
                sequence.continuousOscillator = preserved.continuousOscillator;
                sequence.currentFrequency = preserved.currentFrequency;
                sequence.currentWaveform = preserved.currentWaveform;
                // Don't restore currentChain - we want it to detect the new chain as changed
            }
        }

        this.sequences.push(sequence);
        return sequence;
    }

    compileGenerator(generatorStr) {
        debugLog('compileGenerator input:', generatorStr);
        try {
            // Remove arrow function wrapper if present
            let expression = generatorStr.trim();

            // Handle: i => expression (non-greedy)
            const arrowMatch = expression.match(/^i\s*=>\s*(.+)$/s);
            if (arrowMatch) {
                expression = arrowMatch[1].trim();
            }

            // Handle: (i) => expression
            const parenMatch = expression.match(/^\(i\)\s*=>\s*(.+)$/s);
            if (parenMatch) {
                expression = parenMatch[1].trim();
            }

            // Remove quotes if wrapped in string
            expression = expression.replace(/^["'](.+)["']$/s, '$1');

            // Only preprocess if the expression contains ->
            // This avoids breaking simple expressions that return values
            if (expression.includes('->')) {
                // Detect and wrap -> chains in quotes
                // Look for patterns like: something -> something
                // This converts: osc(C4, sine) -> lpf(100) -> gain(0.8)
                // Into: "osc(C4, sine) -> lpf(100) -> gain(0.8)"
                debugLog('Before preprocessing:', expression);
                expression = this.preprocessChains(expression);
                debugLog('After preprocessing:', expression);
            }

            // Make note names and helpers available as variables
            const noteVars = this.createNoteVariables();

            // Filter out invalid parameter names (those starting with digits)
            const validParamNames = Object.keys(noteVars).filter(name => !/^\d/.test(name));
            const validParamValues = validParamNames.map(name => noteVars[name]);

            // Create function with note variables in scope
            const func = new Function(
                ...validParamNames,
                'i',
                `return ${expression}`
            );

            // Return wrapped function with note values
            return (i) => func(...validParamValues, i);
        } catch (error) {
            console.error('Generator compile error:', error);
            throw new Error(`Invalid generator expression: ${generatorStr}`);
        }
    }

    preprocessChains(expression) {
        // Find chains containing -> and wrap them in quotes
        // Handle: condition ? chain1 : chain2

        // Simple approach: split by ternary operators and process each part
        let result = '';
        let current = '';
        let depth = 0;
        let inString = false;
        let stringChar = null;

        for (let i = 0; i < expression.length; i++) {
            const char = expression[i];

            if (!inString) {
                if (char === '"' || char === "'") {
                    inString = true;
                    stringChar = char;
                    current += char;
                } else if (char === '(') {
                    depth++;
                    current += char;
                } else if (char === ')') {
                    depth--;
                    current += char;
                } else if ((char === '?' || char === ':') && depth === 0) {
                    // Found ternary operator at top level
                    // Wrap current if it contains ->
                    if (current.includes('->')) {
                        result += `"${current.trim()}"`;
                    } else {
                        result += current;
                    }
                    result += ' ' + char + ' ';
                    current = '';
                } else {
                    current += char;
                }
            } else {
                current += char;
                if (char === stringChar && expression[i-1] !== '\\') {
                    inString = false;
                }
            }
        }

        // Handle remaining
        if (current.trim()) {
            if (current.includes('->')) {
                result += `"${current.trim()}"`;
            } else {
                result += current;
            }
        }

        return result;
    }

    createNoteVariables() {
        // Create C0-C8 note variables
        const notes = {};
        const noteNames = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B'];

        for (let octave = 0; octave <= 8; octave++) {
            for (let note of noteNames) {
                const noteName = note + octave;
                notes[noteName] = this.engine.noteToFreq(noteName);
            }
        }

        // Add rest notation
        notes['rest'] = '..';

        // Add waveform types as string variables
        notes['sine'] = 'sine';
        notes['square'] = 'square';
        notes['sawtooth'] = 'sawtooth';
        notes['triangle'] = 'triangle';

        // Add scale names as string variables
        notes['major'] = 'major';
        notes['minor'] = 'minor';
        notes['harmonicMinor'] = 'harmonicMinor';
        notes['melodicMinor'] = 'melodicMinor';
        notes['dorian'] = 'dorian';
        notes['phrygian'] = 'phrygian';
        notes['lydian'] = 'lydian';
        notes['mixolydian'] = 'mixolydian';
        notes['locrian'] = 'locrian';
        notes['pentatonicMajor'] = 'pentatonicMajor';
        notes['pentatonicMinor'] = 'pentatonicMinor';
        notes['blues'] = 'blues';
        notes['wholeTone'] = 'wholeTone';
        notes['chromatic'] = 'chromatic';
        notes['japanese'] = 'japanese';
        notes['arabic'] = 'arabic';
        notes['gypsy'] = 'gypsy';
        notes['spanish'] = 'spanish';

        // Add chord/arp type names as string variables
        // Note: 7th and 9th must be used as strings '7th', '9th' since they can't be JS variable names
        notes['triad'] = 'triad';
        notes['sus2'] = 'sus2';
        notes['sus4'] = 'sus4';

        // Add arp pattern names as string variables
        notes['up'] = 'up';
        notes['down'] = 'down';
        notes['updown'] = 'updown';
        notes['downup'] = 'downup';
        notes['random'] = 'random';

        // Add note() helper function - just returns the frequency
        notes['note'] = (freq) => freq;

        // Add scale helper functions
        notes['scale'] = (root, scaleName, index) => {
            return this.scaleHelper.getScaleNote(root, scaleName, index);
        };

        notes['chord'] = (root, scaleName, degree, type = 'triad') => {
            return this.scaleHelper.getChord(root, scaleName, degree, type);
        };

        notes['arp'] = (root, scaleName, degree, type = 'triad', pattern = 'up') => {
            return this.scaleHelper.getArpeggio(root, scaleName, degree, type, pattern);
        };

        return notes;
    }

    start() {
        if (this.isPlaying) return;
        this.isPlaying = true;
        this.schedule();
    }

    stop(clearContinuousOscillators = false) {
        this.isPlaying = false;
        if (this.schedulerId) {
            clearTimeout(this.schedulerId);
            this.schedulerId = null;
        }

        // Stop all active granular samplers
        this.activeGranularSamplers.forEach(grains => {
            if (grains && grains.stop) {
                grains.stop();
            }
        });
        this.activeGranularSamplers = [];

        // Only stop continuous oscillators if explicitly requested (full stop, not recompile)
        if (clearContinuousOscillators) {
            this.sequences.forEach(seq => {
                if (seq.continuousOscillator) {
                    // First, trigger release on any envelopes in the chain
                    if (seq.chain && seq.chain.length > 0) {
                        seq.chain.forEach(node => {
                            if (node.releaseNow && typeof node.releaseNow === 'function') {
                                node.releaseNow();
                            }
                        });
                    }

                    // Schedule oscillator stop after envelope release time
                    // Find the longest release time in the chain
                    let maxRelease = 0;
                    if (seq.chain) {
                        seq.chain.forEach(node => {
                            // Read from AudioParam if available (envelope uses AudioParams now)
                            const release = node.releaseParam ? node.releaseParam.offset.value : node.release;
                            if (release !== undefined && release > maxRelease) {
                                maxRelease = release;
                            }
                        });
                    }

                    // Stop oscillator after release completes
                    const stopTime = this.engine.context.currentTime + maxRelease;
                    try {
                        seq.continuousOscillator.stop(stopTime);
                    } catch (e) {
                        // Oscillator may already be stopped, ignore error
                    }
                    seq.continuousOscillator = null;
                }
            });
        } else {
            // Preserve continuous oscillator state for recompile
            // Store them temporarily so they can be reattached to new sequences
            this.preservedOscillators = this.sequences
                .filter(seq => seq.continuousOscillator)
                .map(seq => ({
                    continuousOscillator: seq.continuousOscillator,
                    currentFrequency: seq.currentFrequency,
                    currentWaveform: seq.currentWaveform,
                    currentChain: seq.currentChain,
                    currentGlideTime: seq.currentGlideTime
                }));
        }

        this.sequences = [];
        this.globalTick = 0;
    }

    schedule() {
        if (!this.isPlaying) return;

        const now = this.engine.context.currentTime;

        // Initialize global tick counter
        if (this.globalTick === undefined) {
            this.globalTick = 0;
        }

        // Process each sequence
        this.sequences.forEach(seq => {
            // Initialize last trigger time
            if (seq.lastTick === undefined) {
                seq.lastTick = -1;
            }

            // Calculate how many global ticks per step for this subdivision
            // Base clock is 16th notes, so:
            // subdivision 16 = advance every 1 tick
            // subdivision 8 = advance every 2 ticks
            // subdivision 4 = advance every 4 ticks
            const ticksPerStep = 16 / seq.subdivision;

            // Check if enough ticks have passed for this sequence
            if (this.globalTick - seq.lastTick >= ticksPerStep) {
                let note;

                // Handle tracker patterns
                if (seq.isTracker) {
                    const row = seq.pattern[seq.currentStep];

                    if (seq.isMultiChannel && Array.isArray(row)) {
                        // Multi-channel tracker - play all channels
                        const notes = [];
                        for (let ch = 0; ch < row.length; ch++) {
                            const channelData = row[ch];
                            if (channelData && channelData.note !== '..') {
                                const freq = this.engine.noteToFreq(channelData.note);
                                notes.push({
                                    freq,
                                    channel: ch,
                                    instrument: channelData.instrument
                                });
                            }
                        }
                        // Store notes for multi-channel playback
                        note = notes.length > 0 ? notes : null;
                    } else if (row && row.note !== '..') {
                        // Single channel tracker
                        note = this.engine.noteToFreq(row.note);
                        debugLog('Playing tracker note:', row.note, '=', note, 'Hz');
                    }
                }
                // Get note from generator or static array
                else if (seq.isGenerator) {
                    try {
                        note = seq.generator(seq.currentStep);

                        // Validate note is finite
                        if (typeof note === 'number' && (!isFinite(note) || note <= 0)) {
                            console.warn('Generator returned invalid frequency:', note, 'at step', seq.currentStep);
                            note = null;
                        }
                    } catch (error) {
                        console.error('Generator error at step', seq.currentStep, ':', error.message);
                        note = null;
                    }
                } else {
                    note = seq.notes[seq.currentStep];
                }

                // Apply scale transform if present
                if (note && note !== '..' && seq.scaleTransform && typeof note === 'number') {
                    const { root, scaleName } = seq.scaleTransform;
                    note = this.scaleHelper.getScaleNote(root, scaleName, note);
                }

                // Track trigger time for visualization
                seq.lastTriggerTime = now;

                // Apply quantize offset based on the global tick (16th note position)
                // Check for sequence-specific quantize preset first
                const quantizeOffset = this.getQuantizeOffset(this.globalTick % 16, seq);
                const quantizedTime = now + quantizeOffset;

                // Check if note is a chain string (per-step synthesis)
                if (note && typeof note === 'string' && note.includes('->')) {
                    this.triggerChain(note, quantizedTime, seq);
                } else if (Array.isArray(note)) {
                    // Multi-channel tracker notes
                    for (const noteData of note) {
                        let oscType = seq.oscType;
                        let channelChain = null;

                        // Get source for this channel
                        if (seq.sources && seq.sources[noteData.channel]) {
                            const sourceModule = seq.sources[noteData.channel];

                            // Check if source is a chain
                            if (sourceModule.isChain) {
                                // Get the first module as the source type
                                const firstModule = sourceModule.modules[0];
                                if (firstModule.type === 'osc') {
                                    oscType = firstModule.params.type || 'sine';
                                } else if (firstModule.type === 'noise') {
                                    oscType = { noise: firstModule.params.type || 'white' };
                                }

                                // Create audio nodes for the rest of the chain
                                if (sourceModule.modules.length > 1) {
                                    channelChain = [];
                                    for (let i = 1; i < sourceModule.modules.length; i++) {
                                        const module = sourceModule.modules[i];
                                        const audioNode = this.createAudioNodeForChannel(module);
                                        if (audioNode) {
                                            channelChain.push(audioNode);
                                        }
                                    }
                                }
                            } else {
                                // Single module source
                                if (sourceModule.type === 'osc') {
                                    oscType = sourceModule.params.type || 'sine';
                                } else if (sourceModule.type === 'noise') {
                                    oscType = { noise: sourceModule.params.type || 'white' };
                                }
                            }
                        }

                        this.triggerNote(noteData.freq, oscType, seq.chain, quantizedTime, channelChain, seq.hasOut, seq);
                    }
                } else if (note && note !== '..') {
                    this.triggerNote(note, seq.oscType, seq.chain, quantizedTime, null, seq.hasOut, seq);
                }

                // Store the current step for visualization (before advancing)
                seq.displayStep = seq.currentStep;

                // Advance step
                const length = seq.isTracker ? seq.length : (seq.isGenerator ? seq.length : seq.notes.length);
                seq.currentStep = (seq.currentStep + 1) % length;
                seq.lastTick = this.globalTick;
            }
        });

        this.globalTick++;

        // Use 16th note as base clock (finest resolution)
        const beatDuration = 60 / this.bpm;
        const stepDuration = (beatDuration * 4) / 16;

        // Schedule next step
        this.schedulerId = setTimeout(() => {
            this.schedule();
        }, stepDuration * 1000);
    }

    triggerChain(chainStr, startTime, sequence = null) {
        // Parse and execute a full chain for this step
        // Import parser temporarily - we need to parse the mini-chain
        // For now, we'll use a simplified inline parser

        debugLog('triggerChain called with:', chainStr);

        try {
            const parts = chainStr.split('->').map(p => p.trim());
            let currentNode = null;

            for (const part of parts) {
                // Parse module (simplified) - handle both func() and func
                let type, args = [];
                const matchWithParens = part.match(/^(\w+)\s*\(([^)]*)\)$/);
                const matchNoParens = part.match(/^(\w+)$/);

                if (matchWithParens) {
                    type = matchWithParens[1];
                    const argsStr = matchWithParens[2];
                    args = argsStr ? argsStr.split(',').map(a => a.trim()) : [];
                } else if (matchNoParens) {
                    type = matchNoParens[1];
                    args = [];
                } else {
                    continue;
                }

                // Create audio node based on type
                if (type === 'osc') {
                    const freq = this.parseChainValue(args[0]);
                    let oscType = args[1] || 'sine';

                    debugLog('[triggerChain] Original oscType from args:', oscType);
                    debugLog('[triggerChain] Sequence:', sequence);
                    debugLog('[triggerChain] Sequence chainOverrides:', sequence?.chainOverrides);

                    // Check for chain overrides
                    if (sequence && sequence.chainOverrides && sequence.chainOverrides.osc && sequence.chainOverrides.osc.waveform) {
                        oscType = sequence.chainOverrides.osc.waveform;
                        debugLog('[triggerChain] Using override waveform:', oscType);
                    }

                    const osc = this.engine.createOscillator(freq, oscType);
                    const env = this.engine.createGain(0);
                    osc.connect(env);

                    currentNode = { osc, env, output: env };
                } else if (type === 'noise') {
                    const noiseType = args[0] || 'white';
                    const source = this.engine.createNoise(noiseType);
                    const env = this.engine.createGain(0);
                    source.connect(env);

                    currentNode = { source, env, output: env };
                } else if (type === 'lpf' || type === 'hpf' || type === 'bpf') {
                    const filterType = type.replace('pf', 'pass');

                    // Check if freq arg is a modulation source (lfo, random, etc)
                    let filter;
                    let modulationSource = null;

                    if (args[0] && /^(lfo|random)\(/.test(args[0])) {
                        // Parse the modulation source
                        modulationSource = this.parseModulationSource(args[0]);
                        // Create filter with base frequency 0 (modulation will control it)
                        filter = this.engine.createFilter(filterType, 0, this.parseChainValue(args[1]) || 1);

                        // Connect modulation source to filter frequency
                        if (modulationSource && modulationSource.output) {
                            modulationSource.output.connect(filter.frequency);
                        }
                    } else {
                        // Standard static filter
                        const freq = this.parseChainValue(args[0]) || 1000;
                        const q = this.parseChainValue(args[1]) || 1;
                        filter = this.engine.createFilter(filterType, freq, q);
                    }

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(filter);
                    }
                    currentNode = { ...currentNode, filter, output: filter, modulation: modulationSource };
                } else if (type === 'gain') {
                    const value = this.parseChainValue(args[0]) || 1.0;
                    const gain = this.engine.createGain(value);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(gain);
                    }
                    currentNode = { ...currentNode, gain, output: gain };
                } else if (type === 'pan') {
                    const position = this.parseChainValue(args[0]) || 0;
                    const panner = this.engine.createPanner(position);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(panner);
                    }
                    currentNode = { ...currentNode, panner, output: panner };
                } else if (type === 'reverb') {
                    const amount = this.parseChainValue(args[0]) || 0.3;
                    const length = this.parseChainValue(args[1]) || 2;
                    const convolver = this.engine.createConvolver(length);
                    const wetGain = this.engine.createGain(amount);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(convolver);
                    }
                    convolver.connect(wetGain);
                    currentNode = { ...currentNode, reverb: { convolver, wetGain }, output: wetGain };
                } else if (type === 'delay') {
                    const time = this.parseChainValue(args[0]) || 0.5;
                    const feedback = this.parseChainValue(args[1]) || 0.3;
                    const delayNode = this.engine.createDelay(time, feedback);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(delayNode.input);
                    }
                    currentNode = { ...currentNode, delay: delayNode, output: delayNode.output };
                } else if (type === 'pingpong') {
                    const time = this.parseChainValue(args[0]) || 0.25;
                    const feedback = this.parseChainValue(args[1]) || 0.4;
                    const pingpong = this.engine.createPingPongDelay(time, feedback);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(pingpong.input);
                    }
                    currentNode = { ...currentNode, pingpong, output: pingpong.output };
                } else if (type === 'chorus') {
                    const rate = this.parseChainValue(args[0]) || 1.5;
                    const depth = this.parseChainValue(args[1]) || 0.002;
                    const mix = this.parseChainValue(args[2]) || 0.5;
                    const chorus = this.engine.createChorus(rate, depth, mix);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(chorus.input);
                    }
                    currentNode = { ...currentNode, chorus, output: chorus.output };
                } else if (type === 'phaser') {
                    const rate = this.parseChainValue(args[0]) || 0.5;
                    const depth = this.parseChainValue(args[1]) || 1;
                    const stages = this.parseChainValue(args[2]) || 4;
                    const phaser = this.engine.createPhaser(rate, depth, stages);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(phaser.input);
                    }
                    currentNode = { ...currentNode, phaser, output: phaser.output };
                } else if (type === 'distortion' || type === 'dist') {
                    const amount = this.parseChainValue(args[0]) || 50;
                    const mix = this.parseChainValue(args[1]) || 1.0;
                    const distortion = this.engine.createDistortion(amount, mix);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(distortion.input);
                    }
                    currentNode = { ...currentNode, distortion, output: distortion.output };
                } else if (type === 'bitcrush' || type === 'crush') {
                    const bits = this.parseChainValue(args[0]) || 4;
                    const sampleRate = this.parseChainValue(args[1]) || 4000;
                    const bitcrusher = this.engine.createBitcrusher(bits, sampleRate);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(bitcrusher.input);
                    }
                    currentNode = { ...currentNode, bitcrusher, output: bitcrusher.output };
                } else if (type === 'limiter') {
                    const threshold = this.parseChainValue(args[0]) || -3;
                    const attack = this.parseChainValue(args[1]) || 0.003;
                    const release = this.parseChainValue(args[2]) || 0.1;
                    const limiter = this.engine.createLimiter(threshold, attack, release);

                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(limiter.input);
                    }
                    currentNode = { ...currentNode, limiter, output: limiter.output };
                } else if (type === 'random') {
                    const randomType = args[0] || 'value';
                    const min = this.parseChainValue(args[1]) || 0;
                    const max = this.parseChainValue(args[2]) || 1;
                    const rate = this.parseChainValue(args[3]) || 1000;
                    const randomizer = this.engine.createRandom(randomType, min, max, rate);

                    // Start the randomizer
                    randomizer.start();

                    // Note: random() is a control signal generator, not an audio processor
                    // It can be connected to AudioParams of other nodes for modulation
                    currentNode = { ...currentNode, random: randomizer, output: randomizer.output };
                } else if (type === 'out') {
                    // Connect to master
                    if (currentNode && currentNode.output) {
                        currentNode.output.connect(this.engine.masterGain);
                    }
                } else if (type === 'note') {
                    // note() helper - just pass through the frequency
                    // This is handled by the value already being a frequency
                }
            }

            // Start source (oscillator or noise) and apply envelope
            if (currentNode && (currentNode.osc || currentNode.source) && currentNode.env) {
                const source = currentNode.osc || currentNode.source;
                const env = currentNode.env;

                source.start(startTime);

                // ADSR envelope - env(0.001, 0.0, 0.0, 0.01)
                const attack = 0.001;
                const decay = 0.0;
                const sustain = 1.0;
                const release = 0.01;
                const noteDuration = 0.15;

                env.gain.cancelScheduledValues(startTime);
                env.gain.setValueAtTime(0, startTime);
                env.gain.linearRampToValueAtTime(1.0, startTime + attack);
                env.gain.linearRampToValueAtTime(sustain, startTime + attack + decay);
                env.gain.setValueAtTime(sustain, startTime + noteDuration - release);
                env.gain.linearRampToValueAtTime(0, startTime + noteDuration);

                source.stop(startTime + noteDuration + 0.1);
            }
        } catch (error) {
            console.error('Chain trigger error:', error);
        }
    }

    parseChainValue(str) {
        if (!str) return null;

        // Check if it's a note
        if (/^[A-G][#b]?\d+$/.test(str)) {
            return this.engine.noteToFreq(str);
        }

        // Parse as number
        const num = parseFloat(str);
        return isNaN(num) ? str : num;
    }

    parseModulationSource(str) {
        // Parse modulation sources like lfo(...) or random(...)
        const match = str.match(/^(\w+)\s*\(([^)]*)\)$/);
        if (!match) return null;

        const [, type, argsStr] = match;
        const args = argsStr ? argsStr.split(',').map(a => a.trim()) : [];

        if (type === 'random') {
            // random(type, min, max, rate)
            const randomType = args[0] ? args[0].replace(/['"]/g, '') : 'value';
            const min = parseFloat(args[1]) || 0;
            const max = parseFloat(args[2]) || 1;
            const rate = parseFloat(args[3]) || 1000;

            const randomizer = this.engine.createRandom(randomType, min, max, rate);
            randomizer.start();
            return randomizer;
        } else if (type === 'lfo') {
            // lfo(rate, min, max) - inline modulation syntax
            const rate = parseFloat(args[0]) || 1;
            const min = parseFloat(args[1]) || 0;
            const max = parseFloat(args[2]) || 1;

            // Calculate depth and offset from min/max
            const offset = (min + max) / 2;
            const depth = (max - min) / 2;

            return this.engine.createLFO(rate, 'sine', depth, offset);
        }

        return null;
    }

    createSourceModule(type, freq, params) {
        // Create the appropriate source module with the given frequency
        // Returns { sources, output, startNow, stopNow } where:
        // - sources is an array of AudioScheduledSourceNodes (for stopping)
        // - output is the AudioNode to connect to the chain
        // - startNow is a function to start all sources
        // - stopNow is a function to stop all sources

        switch (type) {
            case 'pluck': {
                const decay = params.decay || 2;
                const pluck = this.engine.createPluck(freq, decay);
                return {
                    sources: [pluck.source],
                    output: pluck.output,
                    startNow: (time) => pluck.source.start(time),
                    stopNow: (time) => pluck.source.stop(time)
                };
            }
            case 'blow': {
                const pressure = params.pressure || 0.8;
                const blow = this.engine.createBlow(freq, pressure);
                return {
                    sources: [blow.source],
                    output: blow.output,
                    startNow: (time) => blow.source.start(time),
                    stopNow: (time) => blow.source.stop(time)
                };
            }
            case 'bow': {
                const pressure = params.pressure || 0.6;
                const bow = this.engine.createBow(freq, pressure);
                // Bow has osc and vibrato - both need to be started/stopped
                return {
                    sources: [bow.osc, bow.vibrato],
                    output: bow.output,
                    startNow: (time) => {
                        bow.osc.start(time);
                        bow.vibrato.start(time);
                    },
                    stopNow: (time) => {
                        bow.osc.stop(time);
                        bow.vibrato.stop(time);
                    }
                };
            }
            case 'strike': {
                const hardness = params.hardness || 0.8;
                const strike = this.engine.createStrike(freq, hardness);
                return {
                    sources: [strike.source],
                    output: strike.output,
                    startNow: (time) => strike.source.start(time),
                    stopNow: (time) => strike.source.stop(time)
                };
            }
            case 'fm': {
                const modulator = params.modulator || freq / 2;
                const depth = params.depth || 2;
                const fm = this.engine.createFM(freq, modulator, depth);
                return {
                    sources: [fm.carrier, fm.modulator],
                    output: fm.output,
                    startNow: (time) => {
                        fm.carrier.start(time);
                        fm.modulator.start(time);
                    },
                    stopNow: (time) => {
                        fm.carrier.stop(time);
                        fm.modulator.stop(time);
                    }
                };
            }
            case 'am': {
                const modulator = params.modulator || 10;
                const depth = params.depth || 0.5;
                const am = this.engine.createAM(freq, modulator, depth);
                return {
                    sources: [am.carrier, am.modulator],
                    output: am.output,
                    startNow: (time) => {
                        am.carrier.start(time);
                        am.modulator.start(time);
                    },
                    stopNow: (time) => {
                        am.carrier.stop(time);
                        am.modulator.stop(time);
                    }
                };
            }
            case 'pwm': {
                const width = params.width || 0.5;
                const pwm = this.engine.createPWM(freq, width);
                return {
                    sources: [pwm.osc1, pwm.osc2],
                    output: pwm.output,
                    startNow: (time) => {
                        pwm.osc1.start(time);
                        pwm.osc2.start(time);
                    },
                    stopNow: (time) => {
                        pwm.osc1.stop(time);
                        pwm.osc2.stop(time);
                    }
                };
            }
            case 'sub': {
                const octaves = params.octaves || -1;
                const sub = this.engine.createSub(freq, octaves);
                return {
                    sources: [sub.main, sub.sub],
                    output: sub.output,
                    startNow: (time) => {
                        sub.main.start(time);
                        sub.sub.start(time);
                    },
                    stopNow: (time) => {
                        sub.main.stop(time);
                        sub.sub.stop(time);
                    }
                };
            }
            case 'supersaw': {
                const detune = params.detune || 0.1;
                const voices = params.voices || 7;
                const supersaw = this.engine.createSupersaw(freq, detune, voices);
                return {
                    sources: supersaw.oscillators,
                    output: supersaw.output,
                    startNow: (time) => {
                        supersaw.oscillators.forEach(osc => osc.start(time));
                    },
                    stopNow: (time) => {
                        supersaw.oscillators.forEach(osc => osc.stop(time));
                    }
                };
            }
            case 'wavetable': {
                const table = params.table || 'sine';
                const wavetable = this.engine.createWavetable(freq, table);
                return {
                    sources: [wavetable],
                    output: wavetable,
                    startNow: (time) => wavetable.start(time),
                    stopNow: (time) => wavetable.stop(time)
                };
            }
            case 'grains': {
                // Granular sampler - async loading or signal-based, starts immediately
                debugLog('[DEBUG sequencer grains] Received params:', params);
                let source = params.url; // Default to URL
                const grainSize = params.grainSize || 100;
                const density = params.density || 10;
                const position = params.position || 0.5;
                const spread = params.spread || 0.1;
                const pitch = params.pitch || 1.0;
                const bufferRefreshRate = params.bufferRefreshRate || 1.0;
                debugLog('[DEBUG sequencer grains] Initial source (from params.url):', source);

                // Check if we have a source expression (like osc(440) or @tag)
                debugLog('[DEBUG sequencer grains] Checking params.sourceExpression:', params.sourceExpression);
                if (params.sourceExpression) {
                    // Parse and evaluate the source expression to get an audio node
                    const sourceExpr = params.sourceExpression;

                    if (sourceExpr.startsWith('@')) {
                        // Tag reference - get the output node from the tag
                        const tagName = sourceExpr.substring(1).split('.')[0];
                        const taggedModule = this.taggedModules.get(tagName);
                        if (taggedModule && taggedModule.output) {
                            source = taggedModule.output;
                        } else {
                            console.error(`Tag '${tagName}' not found for grains source`);
                            source = null;
                        }
                    } else if (sourceExpr.includes('(')) {
                        // It's a module expression - parse and create it
                        try {
                            // Extract module name and parameters from expression like "osc(440)"
                            const match = sourceExpr.match(/(\w+)\((.*)\)/);
                            if (match) {
                                const [, moduleName, paramsStr] = match;
                                // Parse parameters
                                const argValues = paramsStr.split(',').map(s => {
                                    const trimmed = s.trim();
                                    return isNaN(trimmed) ? trimmed.replace(/['"]/g, '') : parseFloat(trimmed);
                                });

                                // Create a simple source module
                                if (moduleName === 'osc') {
                                    const freq = argValues[0] || 440;
                                    const type = argValues[1] || 'sine';
                                    const osc = this.engine.createOscillator(freq, type);
                                    osc.start(); // Start oscillator immediately
                                    source = osc;
                                    debugLog('Created oscillator for grains:', freq, type, 'Node:', source);
                                } else if (moduleName === 'noise') {
                                    const type = argValues[0] || 'white';
                                    source = this.engine.createNoise(type);
                                    debugLog('Created noise for grains:', type, 'Node:', source);
                                } else if (moduleName === 'fm') {
                                    const carrier = argValues[0] || 440;
                                    const modulator = argValues[1] || 220;
                                    const depth = argValues[2] || 1.0;
                                    const fm = this.engine.createFM(carrier, modulator, depth);
                                    fm.start(); // Start FM oscillators
                                    source = fm;
                                    debugLog('Created FM for grains:', carrier, modulator, depth, 'Node:', source);
                                } else {
                                    console.error(`Unsupported source module for grains: ${moduleName}`);
                                    source = null;
                                }
                            }
                        } catch (error) {
                            console.error('Error parsing source expression for grains:', error);
                            source = null;
                        }
                    }
                }

                // Create granular sampler (async)
                const grainsPromise = this.engine.createGranularSampler(source, grainSize, density, position, spread, pitch, bufferRefreshRate);

                // Return immediately with placeholder output
                const output = this.engine.createGain();
                output.gain.value = 1;

                // Connect when loaded and track it
                grainsPromise.then(grains => {
                    if (grains) {
                        grains.output.connect(output);
                        // Track this granular sampler
                        this.activeGranularSamplers.push(grains);
                    }
                });

                return {
                    sources: [],
                    output: output,
                    startNow: (time) => {}, // Grains auto-start
                    stopNow: (time) => {
                        grainsPromise.then(grains => {
                            if (grains && grains.stop) {
                                grains.stop();
                                // Remove from tracking
                                const idx = this.activeGranularSamplers.indexOf(grains);
                                if (idx > -1) {
                                    this.activeGranularSamplers.splice(idx, 1);
                                }
                            }
                        });
                    }
                };
            }
            case 'sampler': {
                // Multi-sample instrument - async loading
                // Load the sampler once and cache it
                if (!params.samplerPromise) {
                    console.error('Sampler params missing samplerPromise');
                    return null;
                }

                // Create output gain node
                const output = this.engine.createGain();
                output.gain.value = 1;

                // Store the promise reference
                const samplerPromise = params.samplerPromise;

                return {
                    sources: [],
                    output: output,
                    startNow: async (time) => {
                        // Wait for sampler to load before playing
                        const samplerInstrument = await samplerPromise;

                        if (samplerInstrument) {
                            const noteObj = samplerInstrument.playNote(freq, time);
                            if (noteObj) {
                                noteObj.output.connect(output);
                                noteObj.start(time);
                                // Store reference to stop later
                                return noteObj;
                            }
                        } else {
                            console.warn('Sampler failed to load');
                        }
                    },
                    stopNow: (time, noteObj) => {
                        // Stop the specific note
                        if (noteObj && noteObj.stop) {
                            noteObj.stop(time);
                        }
                    }
                };
            }
            default:
                console.warn('Unknown source module type:', type);
                // Fallback to oscillator
                const osc = this.engine.createOscillator(freq, 'sine');
                return {
                    sources: [osc],
                    output: osc,
                    startNow: (time) => osc.start(time),
                    stopNow: (time) => osc.stop(time)
                };
        }
    }

    triggerNote(note, oscType, chain, startTime, channelChain = null, hasOut = true, sequence = null) {
        // Parse note (could be "C4", "440", or object with velocity)
        let freq = note;
        let velocity = 1.0;

        // Check if chain has portamento node
        let portamentoNode = null;
        let glideTime = 0;
        if (chain) {
            for (const node of chain) {
                if (node._isPortamento) {
                    portamentoNode = node;
                    // Read from AudioParam (enables LFO modulation)
                    glideTime = node._glideTimeParam ? node._glideTimeParam.offset.value : 0;
                    break;
                }
            }
        }

        // Store current glide time for comparison
        if (sequence && portamentoNode) {
            sequence.currentGlideTime = glideTime;
        }

        // Check if using source module, noise, or oscillator
        const useSourceModule = oscType && typeof oscType === 'object' && oscType.sourceModule;
        const useNoise = oscType && typeof oscType === 'object' && oscType.noise;

        if (!useNoise && !useSourceModule) {
            if (typeof note === 'string') {
                // Check for velocity notation: "C4!0.5"
                const parts = note.split('!');
                freq = parts[0];
                velocity = parts[1] ? parseFloat(parts[1]) : 1.0;

                // Convert note name to frequency if needed
                if (/^[A-G][#b]?\d+$/.test(freq)) {
                    freq = this.engine.noteToFreq(freq);
                } else {
                    freq = parseFloat(freq);
                }
            }

            // Validate frequency
            if (!isFinite(freq) || freq <= 0) {
                console.warn('Invalid frequency:', freq, 'for note:', note);
                return;
            }
        } else if (useSourceModule) {
            // For source modules, we need frequency for most types
            if (typeof note === 'string') {
                const parts = note.split('!');
                freq = parts[0];
                velocity = parts[1] ? parseFloat(parts[1]) : 1.0;

                if (/^[A-G][#b]?\d+$/.test(freq)) {
                    freq = this.engine.noteToFreq(freq);
                } else {
                    freq = parseFloat(freq);
                }
            }

            // Validate frequency
            if (!isFinite(freq) || freq <= 0) {
                console.warn('Invalid frequency:', freq, 'for note:', note);
                return;
            }
        } else {
            // For noise, we don't need frequency validation
            velocity = typeof note === 'string' && note.includes('!') ? parseFloat(note.split('!')[1]) : 1.0;
        }

        // PORTAMENTO MODE: Use continuous oscillator with frequency gliding
        if (portamentoNode && !useSourceModule && !useNoise) {
            // Determine desired waveform
            let waveform = oscType || 'sine';
            if (sequence && sequence.chainOverrides && sequence.chainOverrides.osc && sequence.chainOverrides.osc.waveform) {
                waveform = sequence.chainOverrides.osc.waveform;
            }

            // Check if chain has changed (new chain object = recompile happened)
            const chainChanged = sequence.currentChain !== chain;

            // Check if we need to recreate/reconnect the oscillator
            const needsRecreate = !sequence.continuousOscillator || sequence.currentWaveform !== waveform;
            const needsReconnect = chainChanged && sequence.continuousOscillator;

            if (chainChanged) {
                debugLog('Chain changed detected! needsReconnect:', needsReconnect);
            }

            if (needsRecreate) {
                // Stop old oscillator if it exists
                if (sequence.continuousOscillator) {
                    try {
                        sequence.continuousOscillator.stop();
                    } catch (e) {
                        // Already stopped
                    }
                }

                // Create the new continuous oscillator and chain
                const osc = this.engine.createOscillator(freq, waveform);
                let outputNode = osc;

                // Connect through the chain
                if (chain && chain.length > 0) {
                    chain.forEach(node => {
                        // Skip portamento node itself (it's just a marker)
                        if (node._isPortamento) return;

                        if (outputNode.output) {
                            outputNode.output.connect(node.input || node);
                        } else {
                            outputNode.connect(node.input || node);
                        }
                        outputNode = node;
                    });
                }

                // Connect to destination
                if (hasOut) {
                    if (sequence.mixerInfo) {
                        const { mixerName, channels } = sequence.mixerInfo;
                        channels.forEach(channelNum => {
                            const mixerChannel = this.engine.getMixerChannel(mixerName, channelNum);
                            if (outputNode.output) {
                                outputNode.output.connect(mixerChannel);
                            } else {
                                outputNode.connect(mixerChannel);
                            }
                        });
                    } else {
                        if (outputNode.output) {
                            outputNode.output.connect(this.engine.masterGain);
                        } else {
                            outputNode.connect(this.engine.masterGain);
                        }
                    }
                }

                osc.start(); // Start the continuous oscillator
                sequence.continuousOscillator = osc;
                sequence.currentFrequency = freq;
                sequence.currentWaveform = waveform;
                sequence.currentChain = chain; // Store chain reference
            } else if (needsReconnect) {
                // Chain changed - reconnect the existing oscillator through new chain
                debugLog('RECONNECTING oscillator through new chain!');
                const osc = sequence.continuousOscillator;

                // Disconnect from old chain - disconnect from all nodes
                try {
                    osc.disconnect();
                    debugLog('Disconnected oscillator from old chain');
                } catch (e) {
                    debugLog('Error disconnecting:', e);
                }

                // Reconnect through the new chain
                let outputNode = osc;
                if (chain && chain.length > 0) {
                    chain.forEach(node => {
                        // Skip portamento node itself (it's just a marker)
                        if (node._isPortamento) return;

                        if (outputNode.output) {
                            outputNode.output.connect(node.input || node);
                        } else {
                            outputNode.connect(node.input || node);
                        }
                        outputNode = node;
                    });
                }

                // Connect to destination
                if (hasOut) {
                    if (sequence.mixerInfo) {
                        const { mixerName, channels } = sequence.mixerInfo;
                        channels.forEach(channelNum => {
                            const mixerChannel = this.engine.getMixerChannel(mixerName, channelNum);
                            if (outputNode.output) {
                                outputNode.output.connect(mixerChannel);
                            } else {
                                outputNode.connect(mixerChannel);
                            }
                        });
                    } else {
                        if (outputNode.output) {
                            outputNode.output.connect(this.engine.masterGain);
                        } else {
                            outputNode.connect(this.engine.masterGain);
                        }
                    }
                }

                sequence.currentChain = chain; // Update chain reference

                // Glide to new frequency
                const now = this.engine.context.currentTime;
                osc.frequency.cancelScheduledValues(now);
                osc.frequency.setValueAtTime(sequence.currentFrequency, now);
                osc.frequency.exponentialRampToValueAtTime(freq, startTime + glideTime);
                sequence.currentFrequency = freq;
            } else {
                // Just glide to new frequency (no chain or waveform change)
                const osc = sequence.continuousOscillator;
                const now = this.engine.context.currentTime;

                // Cancel any pending frequency changes
                osc.frequency.cancelScheduledValues(now);
                osc.frequency.setValueAtTime(sequence.currentFrequency, now);

                // Glide to new frequency
                osc.frequency.exponentialRampToValueAtTime(freq, startTime + glideTime);
                sequence.currentFrequency = freq;
            }

            // Trigger envelope on every note for rhythmic gating
            if (chain && chain.length > 0) {
                const allChainNodes = [...(channelChain || []), ...(chain || [])];

                for (const node of allChainNodes) {
                    if (node.trigger && typeof node.trigger === 'function') {
                        // Calculate note duration based on subdivision
                        const beatDuration = 60 / this.bpm;
                        const subdivision = sequence && sequence.subdivision ? sequence.subdivision : 8;
                        const noteDuration = (beatDuration * 4) / subdivision;

                        // Trigger the envelope at the note start time
                        node.trigger(noteDuration, startTime);
                    }
                }
            }

            // Return early - portamento mode doesn't create new oscillators
            return;
        }

        // Create source (oscillator, noise, or source module)
        let source;
        let sourceOutput;
        let sourceStartCallback = null;
        let sourceStopCallback = null;
        if (useSourceModule) {
            // Create the appropriate source module with the note's frequency
            const result = this.createSourceModule(oscType.sourceModule, freq, oscType.params);
            if (!result || !result.output) {
                console.error('Source module creation failed:', oscType.sourceModule, 'freq:', freq);
                return; // Skip this note
            }
            source = result.sources[0]; // Keep first source for compatibility
            sourceOutput = result.output;
            sourceStartCallback = result.startNow;
            sourceStopCallback = result.stopNow;
        } else if (useNoise) {
            source = this.engine.createNoise(oscType.noise);
            sourceOutput = source;
        } else {
            // Check for chain overrides for waveform
            let waveform = oscType || 'sine';
            if (sequence && sequence.chainOverrides && sequence.chainOverrides.osc && sequence.chainOverrides.osc.waveform) {
                waveform = sequence.chainOverrides.osc.waveform;
                debugLog('[triggerNote] Using override waveform:', waveform);
            }
            source = this.engine.createOscillator(freq, waveform);
            sourceOutput = source;
        }

        // Check if chain contains an envelope module
        let hasEnvelope = false;
        let envelopeParams = null;

        // Always re-read envelope params from chain for real-time updates to work
        const allChainNodes = [...(channelChain || []), ...(chain || [])];

        let chainEnvelope = null;
        for (const node of allChainNodes) {
            if (node.trigger && typeof node.trigger === 'function') {
                hasEnvelope = true;
                chainEnvelope = node;
                // Read from AudioParams every time (enables real-time updates)
                envelopeParams = {
                    attack: node.attackParam ? node.attackParam.offset.value : node.attack,
                    decay: node.decayParam ? node.decayParam.offset.value : node.decay,
                    sustain: node.sustainParam ? node.sustainParam.offset.value : node.sustain,
                    release: node.releaseParam ? node.releaseParam.offset.value : node.release
                };
                break;
            }
        }

        // Create envelope per note (never share envelope nodes between notes)
        let env = null;
        let envelopeNode = null;
        if (hasEnvelope && envelopeParams) {
            // Create a new envelope instance for this note with the sequence's parameters
            envelopeNode = this.engine.createEnvelopeGain(
                envelopeParams.attack,
                envelopeParams.decay,
                envelopeParams.sustain,
                envelopeParams.release
            );

            // If chain envelope has LFO modulations, sample their values and set envelope params
            if (chainEnvelope && chainEnvelope._lfoModulations) {
                const lfos = chainEnvelope._lfoModulations;

                if (lfos.attack && envelopeNode.attackParam && lfos.attack.getCurrentValue) {
                    envelopeNode.attackParam.offset.value = lfos.attack.getCurrentValue();
                }
                if (lfos.decay && envelopeNode.decayParam && lfos.decay.getCurrentValue) {
                    envelopeNode.decayParam.offset.value = lfos.decay.getCurrentValue();
                }
                if (lfos.sustain && envelopeNode.sustainParam && lfos.sustain.getCurrentValue) {
                    envelopeNode.sustainParam.offset.value = lfos.sustain.getCurrentValue();
                }
                if (lfos.release && envelopeNode.releaseParam && lfos.release.getCurrentValue) {
                    envelopeNode.releaseParam.offset.value = lfos.release.getCurrentValue();
                }
            }

            sourceOutput.connect(envelopeNode.input);
            env = envelopeNode.output;
        } else {
            // No envelope in chain - create default gain envelope
            env = this.engine.createGain(0);
            sourceOutput.connect(env);
        }

        // Apply per-channel chain effects first (if provided)
        let outputNode = env;
        if (channelChain && channelChain.length > 0) {
            channelChain.forEach(node => {
                // Skip envelope nodes (we created our own per-note envelope)
                if (node.trigger && typeof node.trigger === 'function') {
                    return;
                }
                if (outputNode.output) {
                    outputNode.output.connect(node.input || node);
                } else {
                    outputNode.connect(node.input || node);
                }
                outputNode = node;
            });
        }

        // Apply global chain effects (if provided)
        if (chain && chain.length > 0) {
            chain.forEach(node => {
                // Skip envelope nodes (we created our own per-note envelope)
                if (node.trigger && typeof node.trigger === 'function') {
                    return;
                }
                // Skip out() nodes (they're just markers for routing info)
                if (node.isMixerOut) {
                    return;
                }
                if (outputNode.output) {
                    outputNode.output.connect(node.input || node);
                } else {
                    outputNode.connect(node.input || node);
                }
                outputNode = node;
            });
        }

        // Connect to destination (mixer or master) only if chain has explicit 'out'
        if (hasOut) {
            if (sequence.mixerInfo) {
                // Route to mixer channel(s)
                const { mixerName, channels } = sequence.mixerInfo;
                channels.forEach(channelNum => {
                    const mixerChannel = this.engine.getMixerChannel(mixerName, channelNum);
                    if (outputNode.output) {
                        outputNode.output.connect(mixerChannel);
                    } else {
                        outputNode.connect(mixerChannel);
                    }
                });
            } else {
                // Connect to master
                if (outputNode.output) {
                    outputNode.output.connect(this.engine.masterGain);
                } else {
                    outputNode.connect(this.engine.masterGain);
                }
            }
        }

        // Voice management: check if we need to steal a voice
        if (sequence && sequence.maxVoices !== null && sequence.maxVoices > 0) {
            // Clean up finished voices first
            const currentTime = this.engine.context.currentTime;
            sequence.activeVoices = sequence.activeVoices.filter(v => v.stopTime > currentTime);

            // If at voice limit, steal the oldest voice
            if (sequence.activeVoices.length >= sequence.maxVoices) {
                const oldestVoice = sequence.activeVoices.shift(); // Remove oldest (first in array)

                // Stop the oldest voice immediately
                if (oldestVoice.sourceStopCallback) {
                    oldestVoice.sourceStopCallback(currentTime);
                } else if (oldestVoice.source && oldestVoice.source.stop) {
                    oldestVoice.source.stop(currentTime);
                }
            }
        }

        // Start source
        let noteObj = null; // For samplers that return note objects
        if (sourceStartCallback) {
            // Use custom start callback for source modules
            noteObj = sourceStartCallback(startTime);
        } else if (source && source.start) {
            // Standard AudioScheduledSourceNode
            source.start(startTime);
        }

        // Apply envelope
        let noteDuration = 0.15;

        if (hasEnvelope && envelopeNode) {
            // Calculate proper duration including envelope's release time
            // Duration = attack + decay + release (with some sustain time)
            // Read from AudioParams (envelopes now use ConstantSourceNodes)
            const attack = envelopeNode.attackParam ? envelopeNode.attackParam.offset.value : 0.001;
            const decay = envelopeNode.decayParam ? envelopeNode.decayParam.offset.value : 0;
            const release = envelopeNode.releaseParam ? envelopeNode.releaseParam.offset.value : 0.01;
            const envDuration = attack + decay + release + 0.1;
            noteDuration = Math.max(noteDuration, envDuration);

            // Trigger the envelope from the chain
            envelopeNode.trigger(noteDuration);
        } else {
            // Use default ADSR envelope - env(0.001, 0.0, 0.0, 0.01)
            const attack = 0.001;
            const decay = 0.0;
            const sustain = 1.0 * velocity;
            const release = 0.01;

            env.gain.cancelScheduledValues(startTime);
            env.gain.setValueAtTime(0, startTime);
            env.gain.linearRampToValueAtTime(velocity, startTime + attack);
            env.gain.linearRampToValueAtTime(sustain, startTime + attack + decay);
            env.gain.setValueAtTime(sustain, startTime + noteDuration - release);
            env.gain.linearRampToValueAtTime(0, startTime + noteDuration);
        }

        // Stop source after note (add extra buffer for envelope release)
        const stopTime = startTime + noteDuration + 0.5; // Extra time for release tail
        if (sourceStopCallback) {
            // Use custom stop callback for source modules (pass noteObj for samplers)
            sourceStopCallback(stopTime, noteObj);
        } else if (source && source.stop) {
            // Standard AudioScheduledSourceNode
            source.stop(stopTime);
        }

        // Track this voice if voice limiting is enabled
        if (sequence && sequence.maxVoices !== null && sequence.maxVoices > 0) {
            sequence.activeVoices.push({
                source,
                sourceStopCallback,
                stopTime,
                startTime
            });
        }
    }

    createAudioNodeForChannel(module) {
        // Create audio nodes for per-channel effects chains
        const { type, params } = module;

        switch (type) {
            case 'lpf':
            case 'hpf':
            case 'bpf':
                return this.engine.createFilter(params.type, params.freq, params.q);
            case 'distortion':
                return this.engine.createDistortion(params.amount, params.mix);
            case 'tremolo':
                return this.engine.createTremolo(params.rate, params.depth);
            case 'chorus':
                return this.engine.createChorus(params.rate, params.depth, params.mix);
            case 'flanger':
                return this.engine.createFlanger(params.rate, params.depth, params.feedback, params.mix);
            case 'phaser':
                return this.engine.createPhaser(params.rate, params.depth, params.freq, params.q, params.mix);
            case 'ringmod':
                return this.engine.createRingMod(params.freq);
            case 'bitcrush':
                return this.engine.createBitcrusher(params.bits, params.sampleRate);
            case 'delay':
                return this.engine.createDelay(params.time, params.feedback);
            case 'vibrato':
                return this.engine.createVibrato(params.rate, params.depth);
            case 'autowah':
                return this.engine.createAutoWah(params.rate, params.min, params.max);
            case 'autopan':
                return this.engine.createAutoPan(params.rate, params.depth);
            case 'limiter': {
                // Limiter returns compound node with input/output
                return this.engine.createLimiter(params.threshold, params.attack, params.release);
            }
            case 'random': {
                const randomizer = this.engine.createRandom(params.type, params.min, params.max, params.rate);
                randomizer.start();
                return randomizer;
            }
            default:
                console.warn(`Unsupported channel effect: ${type}`);
                return null;
        }
    }

    parsePattern(pattern) {
        // Parse tracker-style pattern: "C4 .. E4 G4!0.5"
        return pattern.split(/\s+/).map(step => {
            if (step === '..' || step === '.' || step === '-') {
                return '..';
            }
            return step;
        });
    }
}
