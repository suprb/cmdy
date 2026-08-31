/**
 * CodioCore - UI-independent API for the Codio audio engine
 *
 * This class provides a clean API for building custom UIs on top of Codio's
 * audio engine, sequencer, and parser. It's completely decoupled from any
 * specific UI implementation (editor, terminal, visualizer, etc.)
 *
 * @example Basic usage
 * ```javascript
 * const codio = new CodioCore({
 *     bpm: 120,
 *     onLog: (msg, type) => console.log(`[${type}] ${msg}`),
 *     onStateChange: (state) => updateUI(state)
 * });
 *
 * await codio.init();
 * await codio.compile('osc(440) -> lpf(1000) -> out');
 * codio.play();
 * ```
 */

import { AudioEngine } from '../audio/engine.js';
import { Sequencer } from '../audio/sequencer.js';
import { Parser } from '../parser/parser.js';
import { debugLog } from './debug.js';

export class CodioCore {
    /**
     * Create a new Codio instance
     *
     * @param {Object} options - Configuration options
     * @param {number} [options.bpm=120] - Initial tempo
     * @param {Function} [options.onLog] - Callback for log messages (message, type)
     * @param {Function} [options.onError] - Callback for errors (error)
     * @param {Function} [options.onStateChange] - Callback for state changes (state)
     * @param {Function} [options.onSequenceTick] - Callback for sequencer ticks (sequences)
     * @param {Function} [options.onVariation] - Callback for variation changes
     * @param {Function} [options.onModulesCreated] - Callback when modules are created (modules)
     * @param {Function} [options.onAnalyserData] - Callback for analyser data (dataArray, bufferLength)
     * @param {boolean} [options.autoInit=false] - Auto-initialize audio context
     */
    constructor(options = {}) {
        // Core audio components
        this.audioEngine = new AudioEngine();
        this.sequencer = new Sequencer(this.audioEngine);
        this.parser = new Parser(this.audioEngine, this.sequencer);

        // State
        this.isPlaying = false;
        this.bpm = options.bpm || 120;
        this.variationCount = 0;
        this.playStartTime = null;
        this.lastCompileResult = null;
        this.tickPollInterval = null;
        this.lastSequencerState = null;

        // Callbacks (all optional)
        this.onLog = options.onLog || null;
        this.onError = options.onError || null;
        this.onStateChange = options.onStateChange || null;
        this.onSequenceTick = options.onSequenceTick || null;
        this.onVariation = options.onVariation || null;
        this.onModulesCreated = options.onModulesCreated || null;
        this.onAnalyserData = options.onAnalyserData || null;

        // Set up audio engine loading callback
        this.audioEngine.loadingCallback = (isLoading, message) => {
            if (this.onLog) {
                this.onLog(message || (isLoading ? 'Loading...' : 'Loaded'), isLoading ? 'info' : 'success');
            }
        };

        // Set up sequencer variation callback
        this.sequencer.onVariation = () => {
            this.variationCount++;
            if (this.onVariation) {
                this.onVariation(this.variationCount);
            }
        };

        // Auto-initialize if requested
        if (options.autoInit) {
            this.init().catch(err => {
                if (this.onError) this.onError(err);
            });
        }
    }

    /**
     * Initialize the audio engine
     * Must be called before compiling/playing audio
     *
     * @returns {Promise<void>}
     */
    async init() {
        try {
            await this.audioEngine.init();
            if (this.onLog) {
                this.onLog('Audio engine initialized', 'success');
            }
        } catch (error) {
            if (this.onError) {
                this.onError(error);
            }
            throw error;
        }
    }

    /**
     * Compile Codio code without playing it
     *
     * @param {string} code - Codio DSL code to compile
     * @returns {Promise<Object>} Parse result with modules array
     */
    async compile(code) {
        try {
            // Initialize audio context if not already done
            if (!this.audioEngine.isInitialized) {
                await this.init();
            }

            if (this.onLog) {
                this.onLog('Parsing code...', 'info');
            }

            // Stop any existing audio
            this.audioEngine.stopAll();
            this.sequencer.stop();

            // Set BPM
            this.sequencer.setBPM(this.bpm);

            // Parse the code
            const result = this.parser.parse(code);

            // Store result
            this.lastCompileResult = result;

            // Update BPM from parser if it was set in code
            this.bpm = this.sequencer.bpm;

            if (this.onLog) {
                this.onLog(`Compiled ${result.modules.length} module(s)`, 'success');
            }

            if (this.onModulesCreated) {
                this.onModulesCreated(result.modules);
            }

            // Notify state change
            if (this.onStateChange) {
                this.onStateChange({
                    isPlaying: false,
                    bpm: this.bpm,
                    moduleCount: result.modules.length
                });
            }

            return result;

        } catch (error) {
            if (this.onLog) {
                this.onLog(`Error: ${error.message}`, 'error');
            }
            if (this.onError) {
                this.onError(error);
            }
            throw error;
        }
    }

    /**
     * Compile and play Codio code
     *
     * @param {string} code - Codio DSL code to compile and play
     * @returns {Promise<Object>} Parse result
     */
    async run(code) {
        const result = await this.compile(code);
        this.play();
        return result;
    }

    /**
     * Start playback of compiled code
     */
    play() {
        // Start sequencer if there are sequences
        if (this.sequencer.sequences.length > 0) {
            this.sequencer.start();
        }

        this.isPlaying = true;
        this.playStartTime = Date.now();
        this.variationCount = 0;

        // Start polling sequencer state for tick callbacks
        if (this.onSequenceTick) {
            this.startSequencerPolling();
        }

        if (this.onStateChange) {
            this.onStateChange({
                isPlaying: true,
                bpm: this.bpm,
                playTime: 0,
                variationCount: 0
            });
        }
    }

    /**
     * Stop playback
     *
     * @param {boolean} [clearContinuousOscillators=true] - Whether to stop continuous oscillators
     */
    stop(clearContinuousOscillators = true) {
        this.audioEngine.stopAll();
        this.sequencer.stop(clearContinuousOscillators);
        this.isPlaying = false;
        this.playStartTime = null;

        // Stop polling sequencer state
        this.stopSequencerPolling();

        if (this.onStateChange) {
            this.onStateChange({
                isPlaying: false,
                bpm: this.bpm,
                playTime: 0
            });
        }
    }

    /**
     * Start polling sequencer for tick updates
     * @private
     */
    startSequencerPolling() {
        // Poll at ~60fps for smooth step indicator updates
        this.tickPollInterval = setInterval(() => {
            if (!this.isPlaying) return;

            const sequences = this.sequencer.sequences.map(seq => ({
                currentStep: seq.currentStep,
                length: seq.length,
                isPlaying: seq.isPlaying
            }));

            if (this.onSequenceTick) {
                this.onSequenceTick(sequences);
            }
        }, 16); // ~60fps
    }

    /**
     * Stop polling sequencer
     * @private
     */
    stopSequencerPolling() {
        if (this.tickPollInterval) {
            clearInterval(this.tickPollInterval);
            this.tickPollInterval = null;
        }
    }

    /**
     * Toggle play/stop
     */
    toggle() {
        if (this.isPlaying) {
            this.stop();
        } else {
            this.play();
        }
    }

    /**
     * Set the BPM (tempo)
     *
     * @param {number} bpm - Beats per minute
     */
    setBPM(bpm) {
        this.bpm = bpm;
        this.sequencer.setBPM(bpm);

        if (this.onStateChange) {
            this.onStateChange({ bpm });
        }
    }

    /**
     * Get the current BPM
     *
     * @returns {number} Current BPM
     */
    getBPM() {
        return this.bpm;
    }

    /**
     * Get playback time in milliseconds
     *
     * @returns {number} Milliseconds since playback started, or 0 if not playing
     */
    getPlayTime() {
        if (!this.playStartTime) return 0;
        return Date.now() - this.playStartTime;
    }

    /**
     * Get analyser data for visualization
     *
     * @param {string} [type='frequency'] - 'frequency' or 'waveform'
     * @returns {Object} { dataArray, bufferLength }
     */
    getAnalyserData(type = 'frequency') {
        if (!this.audioEngine.analyser) {
            return { dataArray: new Uint8Array(0), bufferLength: 0 };
        }

        const analyser = this.audioEngine.analyser;
        const bufferLength = type === 'frequency' ? analyser.frequencyBinCount : analyser.fftSize;
        const dataArray = new Uint8Array(bufferLength);

        if (type === 'frequency') {
            analyser.getByteFrequencyData(dataArray);
        } else {
            analyser.getByteTimeDomainData(dataArray);
        }

        return { dataArray, bufferLength };
    }

    /**
     * Get all active sequences (for step indicators)
     *
     * @returns {Array} Array of sequence objects
     */
    getSequences() {
        return this.sequencer.sequences;
    }

    /**
     * Update a sequence's pattern in real-time without recompiling
     *
     * @param {number} sequenceIndex - Index of the sequence to update
     * @param {Array} notes - New notes array for the sequence
     */
    updateSequenceNotes(sequenceIndex, notes) {
        if (sequenceIndex < 0 || sequenceIndex >= this.sequencer.sequences.length) {
            console.warn(`[updateSequenceNotes] Invalid sequence index: ${sequenceIndex}`);
            return;
        }

        const sequence = this.sequencer.sequences[sequenceIndex];
        if (!sequence) {
            console.warn(`[updateSequenceNotes] No sequence at index: ${sequenceIndex}`);
            return;
        }

        debugLog(`[updateSequenceNotes] Updating sequence ${sequenceIndex} with:`, notes);
        sequence.notes = notes;
    }

    /**
     * Get the last compile result
     *
     * @returns {Object|null} Parse result with modules array
     */
    getLastCompileResult() {
        return this.lastCompileResult;
    }

    /**
     * Update a module parameter in real-time
     *
     * @param {number} lineNumber - Line number of the module
     * @param {string} paramName - Parameter name (e.g., 'frequency', 'gain')
     * @param {*} newValue - New parameter value
     */
    updateParameter(lineNumber, paramName, newValue) {
        debugLog(`[updateParameter] Line: ${lineNumber}, Param: ${paramName}, Value: ${newValue}`);

        // Find the module on this line
        if (!this.lastCompileResult || !this.lastCompileResult.modules) {
            debugLog(`[updateParameter] No compile result or modules`);
            return;
        }

        const module = this.lastCompileResult.modules.find(m => m.lineNumber === lineNumber);
        if (!module) {
            debugLog(`[updateParameter] No module found on line ${lineNumber}`);
            debugLog(`[updateParameter] Available lines:`, this.lastCompileResult.modules.map(m => m.lineNumber));
            return;
        }

        if (!module.audioNode) {
            debugLog(`[updateParameter] Module found but no audioNode:`, module);
            return;
        }

        debugLog(`[updateParameter] Found module:`, module.type, module);
        const audioNode = module.audioNode;
        const currentTime = this.audioEngine.context.currentTime;

        // Special handling for different module types
        // (This is extracted from main.js updateParameterRealtime method)

        // Handle grains parameters
        if (module.type === 'grains') {
            if (paramName === 'source' && audioNode._sourceOscillator) {
                const freq = parseFloat(newValue);
                if (!isNaN(freq)) {
                    const osc = audioNode._sourceOscillator;
                    osc.frequency.cancelScheduledValues(currentTime);
                    osc.frequency.setValueAtTime(osc.frequency.value, currentTime);
                    osc.frequency.exponentialRampToValueAtTime(Math.max(0.01, freq), currentTime + 0.2);
                }
                return;
            }

            if (audioNode._grainsObject && audioNode._grainsObject.params) {
                const grainParams = audioNode._grainsObject.params;
                const numValue = parseFloat(newValue);

                if (!isNaN(numValue)) {
                    switch (paramName) {
                        case 'grainSize':
                            grainParams.grainSize = numValue;
                            break;
                        case 'density':
                            grainParams.density = Math.max(1, numValue);
                            break;
                        case 'position':
                            grainParams.position = Math.max(0, Math.min(1, numValue));
                            break;
                        case 'spread':
                            grainParams.spread = Math.max(0, Math.min(1, numValue));
                            break;
                        case 'pitch':
                            grainParams.pitch = Math.max(0.1, Math.min(4, numValue));
                            break;
                    }
                }
            }
            return;
        }

        // Handle AudioParam updates (filters, gain, etc.)
        if (audioNode[paramName] && audioNode[paramName].setValueAtTime) {
            const value = parseFloat(newValue);
            if (!isNaN(value)) {
                audioNode[paramName].setValueAtTime(value, currentTime);
            }
        }

        // Handle nested params (e.g., filter.frequency)
        if (audioNode.input && audioNode.input[paramName] && audioNode.input[paramName].setValueAtTime) {
            const value = parseFloat(newValue);
            if (!isNaN(value)) {
                audioNode.input[paramName].setValueAtTime(value, currentTime);
            }
        }
    }

    /**
     * Clean up resources
     */
    dispose() {
        this.stop(true);

        if (this.audioEngine.context) {
            this.audioEngine.context.close();
        }

        this.isPlaying = false;
        this.lastCompileResult = null;
    }
}
