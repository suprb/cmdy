import { getSynthPreset, SYNTH_PRESETS } from '../audio/synthPresets.js';
import { TagRegistry } from '../audio/tagRegistry.js';
import { debugLog } from '../core/debug.js';

export class Parser {
    constructor(audioEngine, sequencer) {
        this.engine = audioEngine;
        this.sequencer = sequencer;
        this.modules = [];
        this.terminal = null; // Will be set by main.js
        this.lfoCache = new Map(); // Cache for LFO nodes to avoid recreating them
        this.tagRegistry = new TagRegistry(); // Tag registry for @tag support
    }

    setTerminal(terminal) {
        this.terminal = terminal;
    }

    removeComments(line) {
        // Remove // comments but respect strings
        let result = '';
        let inString = false;
        let stringChar = null;
        let escapeNext = false;

        for (let i = 0; i < line.length; i++) {
            const char = line[i];
            const next = line[i + 1];

            if (escapeNext) {
                result += char;
                escapeNext = false;
                continue;
            }

            if (char === '\\') {
                result += char;
                escapeNext = true;
                continue;
            }

            if (char === '"' || char === "'") {
                if (!inString) {
                    inString = true;
                    stringChar = char;
                } else if (char === stringChar) {
                    inString = false;
                    stringChar = null;
                }
                result += char;
            } else if (!inString && char === '/' && next === '/') {
                // Found comment outside of string, stop here
                break;
            } else {
                result += char;
            }
        }

        return result;
    }

    parse(code) {
        this.modules = [];
        this.lfoCache.clear(); // Clear LFO cache for fresh parse
        this.tagRegistry.clear(); // Clear tag registry for fresh parse
        this.lineMapping = []; // Track which line each module came from
        this.originalCode = code; // Store original code for position tracking
        this.allLines = code.split('\n'); // Store all lines

        // Split into lines and track line numbers
        const linesToParse = [];

        // First pass: collect lines and handle multi-line tracker patterns
        let i = 0;
        while (i < this.allLines.length) {
            const line = this.allLines[i];
            const cleaned = this.removeComments(line).trim();

            if (cleaned.length > 0) {
                // Check if this is a tracker pattern start
                if (cleaned.match(/^tracker\s*\(/)) {
                    // Collect the tracker line and all pattern lines
                    let trackerCode = cleaned;
                    let startLine = i;
                    i++;

                    // First, collect any continuation lines for tracker arguments (multi-line array)
                    // Check if the line doesn't have a closing paren or has an unclosed bracket
                    let parenDepth = (cleaned.match(/\(/g) || []).length - (cleaned.match(/\)/g) || []).length;
                    let bracketDepth = (cleaned.match(/\[/g) || []).length - (cleaned.match(/\]/g) || []).length;

                    while (i < this.allLines.length && (parenDepth > 0 || bracketDepth > 0)) {
                        const nextLine = this.allLines[i];
                        const nextCleaned = this.removeComments(nextLine).trim();

                        trackerCode += ' ' + nextCleaned;
                        parenDepth += (nextCleaned.match(/\(/g) || []).length - (nextCleaned.match(/\)/g) || []).length;
                        bracketDepth += (nextCleaned.match(/\[/g) || []).length - (nextCleaned.match(/\]/g) || []).length;
                        i++;
                    }

                    // Now collect pattern lines
                    while (i < this.allLines.length) {
                        const nextLine = this.allLines[i];
                        const nextCleaned = this.removeComments(nextLine).trim();

                        // Check if line starts with -> (end of pattern)
                        if (nextCleaned.startsWith('->')) {
                            trackerCode += ' ' + nextCleaned;
                            i++;
                            break;
                        }
                        // Check if it's a pattern line (note format or empty)
                        // Pattern: C-4 01 ... or --- -- ... (single or multi-channel)
                        // Multi-channel: C-4 01 ...    E-4 01 ...    G-4 01 ...
                        else if (nextCleaned.match(/^([A-G][#b]?-\d|---)\s+(\d{2}|--)\s+(\.{3}|\w{3})(\s+([A-G][#b]?-\d|---)\s+(\d{2}|--)\s+(\.{3}|\w{3}))*$/)) {
                            trackerCode += '\n' + nextCleaned;
                            i++;
                        }
                        // Otherwise, stop collecting
                        else {
                            break;
                        }
                    }

                    linesToParse.push({
                        code: trackerCode,
                        lineNumber: startLine,
                        originalLine: this.allLines[startLine]
                    });
                } else {
                    // Skip lines that start with -> (they'll be collected as continuations)
                    if (cleaned.startsWith('->')) {
                        i++;
                        continue;
                    }

                    // Check if this line is part of a chain
                    let chainCode = cleaned;
                    let startLine = i;
                    i++;

                    // Helper function to check if there are unclosed parens/braces
                    const hasUnclosedDelimiters = (code) => {
                        let parenDepth = 0;
                        let braceDepth = 0;
                        let inString = false;
                        let stringChar = null;

                        for (let j = 0; j < code.length; j++) {
                            const char = code[j];
                            if ((char === '"' || char === "'") && (j === 0 || code[j-1] !== '\\')) {
                                if (!inString) {
                                    inString = true;
                                    stringChar = char;
                                } else if (char === stringChar) {
                                    inString = false;
                                    stringChar = null;
                                }
                            }
                            if (!inString) {
                                if (char === '(') parenDepth++;
                                else if (char === ')') parenDepth--;
                                else if (char === '{') braceDepth++;
                                else if (char === '}') braceDepth--;
                            }
                        }
                        return parenDepth > 0 || braceDepth > 0;
                    };

                    // Always check if next lines are continuations
                    while (i < this.allLines.length) {
                        const nextLine = this.allLines[i];
                        const nextCleaned = this.removeComments(nextLine).trim();

                        if (nextCleaned.length === 0) {
                            i++;
                            continue;
                        }

                        // Check if current line has unclosed delimiters (parens/braces)
                        if (hasUnclosedDelimiters(chainCode)) {
                            // Continue collecting until delimiters are closed
                            chainCode += ' ' + nextCleaned;
                            i++;
                            continue;
                        }

                        // Check if next line is a continuation (starts with -> or is a module after ->)
                        const startsWithArrow = nextCleaned.startsWith('->');

                        if (startsWithArrow) {
                            // Add the arrow and what follows
                            chainCode += ' ' + nextCleaned;
                            i++;
                            continue;
                        }

                        // If chain ends with '-> out', it's complete - don't collect more
                        if (chainCode.match(/->?\s*out\s*$/)) {
                            break;
                        }

                        // If current chain already has ->, check if next line is an effect module
                        // Only EFFECT modules can be continuations, never SOURCE modules
                        if (chainCode.includes('->')) {
                            // Source modules that start chains: seq, tracker, osc, noise, in (mixer input), and all new sources
                            const isSourceModule = nextCleaned.match(/^(seq|tracker|osc|noise|const|impulse|click|pwm|sub|supersaw|fm|am|pluck|sample|grain|loop|wavetable|blow|bow|strike|in)\s*\(/);
                            // Everything else is an effect/modifier that can be a continuation
                            const isEffectModule = nextCleaned.match(/^(lpf|hpf|bpf|delay|reverb|pingpong|gain|pan|out|distortion|dist|chorus|flanger|phaser|tremolo|vibrato|ringmod|bitcrush|crush|autowah|autopan|lfo|env|envelope|scale|width|dattorro|limiter|random)\s*\(/);

                            if (isEffectModule && !isSourceModule) {
                                // Effect module continuation (format 2)
                                chainCode += ' -> ' + nextCleaned;
                                i++;
                                continue;
                            }
                        }

                        // Not a continuation, stop
                        break;
                    }

                    linesToParse.push({
                        code: chainCode,
                        lineNumber: startLine,
                        originalLine: line
                    });
                }
            } else {
                i++;
            }
        }

        // Parse each chain
        for (const lineInfo of linesToParse) {
            try {
                const moduleCountBefore = this.modules.length;
                this.currentLineInfo = lineInfo;  // Store for use in parseChain
                this.parseChain(lineInfo.code);
                const moduleCountAfter = this.modules.length;

                // Tag all new modules with this line number
                for (let i = moduleCountBefore; i < moduleCountAfter; i++) {
                    this.modules[i].lineNumber = lineInfo.lineNumber;
                }
            } catch (error) {
                throw new Error(`Parse error in line "${lineInfo.code}": ${error.message}`);
            }
        }

        return {
            modules: this.modules,
            chains: this.engine.chains,
            lineMapping: this.modules.map(m => m.lineNumber),
            sequences: this.sequencer.sequences  // Include sequences for step tracking
        };
    }

    smartSplitChain(chainStr) {
        // Split by -> but respect parentheses depth and strings
        const parts = [];
        let current = '';
        let depth = 0;
        let inString = false;
        let stringChar = null;

        for (let i = 0; i < chainStr.length; i++) {
            const char = chainStr[i];
            const next = chainStr[i + 1];

            // Track string state
            if (char === '"' || char === "'") {
                if (!inString) {
                    inString = true;
                    stringChar = char;
                } else if (char === stringChar) {
                    inString = false;
                    stringChar = null;
                }
                current += char;
            } else if (!inString) {
                // Only track parens and -> outside of strings
                if (char === '(') {
                    depth++;
                    current += char;
                } else if (char === ')') {
                    depth--;
                    current += char;
                } else if (char === '-' && next === '>' && depth === 0) {
                    // Found -> at depth 0
                    parts.push(current.trim());
                    current = '';
                    i++; // Skip the '>'
                } else {
                    current += char;
                }
            } else {
                // Inside string, just add character
                current += char;
            }
        }

        if (current.trim()) {
            parts.push(current.trim());
        }

        return parts;
    }

    parseChain(chainStr) {
        // FIRST: Check if there's a preset with bracket chain and expand it inline
        // This must happen BEFORE splitting by -> to preserve the bracket chain
        const presetBracketRegex = /preset\(([^)]+)\)\s*\[\s*(.+?)\s*<\]/g;
        let expandedChainStr = chainStr;
        let match;

        while ((match = presetBracketRegex.exec(chainStr)) !== null) {
            const fullMatch = match[0];
            const chainText = match[2]; // The content inside the brackets
            debugLog(`[parser] Found preset bracket chain, using custom chain: ${chainText}`);

            // Replace preset(...)[...] with just the chain content
            expandedChainStr = expandedChainStr.replace(fullMatch, chainText);
        }

        // Split by -> to get the chain (but respect parentheses)
        const parts = this.smartSplitChain(expandedChainStr);

        // Check if this is a BPM command
        const firstModule = this.parseModule(parts[0]);
        if (firstModule && firstModule.type === 'bpm') {
            this.sequencer.setBPM(firstModule.params.value);
            this.modules.push(firstModule);
            return;
        }

        // Check if this is a Quantize command
        if (firstModule && firstModule.type === 'quantize') {
            this.sequencer.setQuantize(firstModule.params.preset);
            this.modules.push(firstModule);
            return;
        }

        // Check if this is a sequencer chain (starts with seq or tracker)
        if (firstModule && (firstModule.type === 'seq' || firstModule.type === 'tracker')) {
            this.parseSequencerChain(parts, firstModule);
            return;
        }

        // Check if chain contains an explicit envelope to avoid adding default envelope
        const hasExplicitEnvelope = parts.some(part => {
            const trimmed = part.trim();
            return trimmed.startsWith('env(') || trimmed.startsWith('envelope(');
        });

        // Check if chain contains an explicit limiter to avoid adding default limiter
        const hasExplicitLimiter = parts.some(part => {
            const trimmed = part.trim();
            return trimmed.startsWith('limiter(');
        });

        let currentNode = null;
        const chainNodes = [];
        let charOffset = 0;
        let pendingLFO = null; // Track LFO to connect to next module's param

        for (let i = 0; i < parts.length; i++) {
            const part = parts[i];

            // Check if this part is a standalone @tag reference
            const tagMatch = part.trim().match(/^@([a-zA-Z_]\w*)(?:\.(\w+))?$/);
            if (tagMatch) {
                const tagName = tagMatch[1];
                const propertyName = tagMatch[2];

                // Resolve the tag reference
                const result = this.tagRegistry.resolveProperty(tagName, propertyName || 'signal');

                if (result.error) {
                    if (this.terminal) {
                        this.terminal.log(`Tag error: ${result.error}`, 'error');
                    }
                    console.warn('Tag resolution error:', result.error);
                    continue;
                }

                const audioNode = result.value;
                if (audioNode) {
                    // Add this node to the chain
                    if (currentNode) {
                        // Connect previous node to this one
                        if (currentNode.output) {
                            currentNode.output.connect(audioNode.input || audioNode);
                        } else {
                            currentNode.connect(audioNode.input || audioNode);
                        }
                    }

                    chainNodes.push(audioNode);
                    if (audioNode.isMixerOut) {
                        debugLog('[PARSER] Pushed @tag out node to chainNodes, isMixerOut:', audioNode.isMixerOut, 'mixerName:', audioNode.mixerName);
                    }
                    currentNode = audioNode.output || audioNode;
                }
                continue;
            }

            const module = this.parseModule(part);

            if (!module) continue;

            // Track module position in the line
            if (this.currentLineInfo) {
                module.lineNumber = this.currentLineInfo.lineNumber;

                const moduleStart = this.currentLineInfo.originalLine.indexOf(part, charOffset);
                if (moduleStart !== -1) {
                    module.charPosition = {
                        start: moduleStart,
                        end: moduleStart + part.length
                    };
                    charOffset = moduleStart + part.length;
                }
            }

            // Check if this is a preset - expand it into multiple effect nodes
            if (module.type === 'preset') {
                const synthName = module.params.synth;
                const presetName = module.params.preset;

                // Note: Bracket chains are now handled earlier in parseChain()
                // before the split, so this code only runs for unexpanded presets
                const preset = getSynthPreset(synthName, presetName);

                if (preset) {
                    debugLog(`Expanding preset in direct chain: ${synthName}/${presetName} - ${preset.name}`);

                    // Validate source compatibility
                    // Look back in the chain to find the source module
                    let sourceModule = null;
                    for (let j = i - 1; j >= 0; j--) {
                        const prevPart = parts[j];
                        const prevModule = this.parseModule(prevPart);
                        if (prevModule && ['osc', 'fm', 'noise', 'pluck'].includes(prevModule.type)) {
                            sourceModule = prevModule;
                            break;
                        }
                    }

                    if (sourceModule) {
                        const sourceType = sourceModule.type;
                        const expectedTypes = preset.sourceTypes || [];
                        const isCompatible = expectedTypes.some(type => type === sourceType || type === `seq+${sourceType}`);

                        if (!isCompatible) {
                            const message = `Preset "${synthName}/${presetName}" expects ${expectedTypes.join(' or ')} but got ${sourceType}`;
                            if (this.terminal) {
                                this.terminal.log(message, 'warning');
                            }
                            console.warn(`⚠️  ${message}`);
                        }

                        // Auto-fix: switch sine waves to sawtooth for filter-heavy presets
                        if (sourceModule.type === 'osc' && sourceModule.params.type === 'sine') {
                            const hasFilters = preset.chain.some(e => ['lpf', 'hpf', 'bpf'].includes(e.type));
                            if (hasFilters) {
                                // Automatically switch to sawtooth for better results
                                sourceModule.params.type = 'sawtooth';

                                // Update the editor text to reflect the change
                                if (this.onAutoFix) {
                                    this.onAutoFix(sourceModule.lineNumber, 'sine', 'sawtooth');
                                }

                                const message = `Auto-switched from sine to sawtooth for preset "${synthName}/${presetName}" (filters work better with harmonics)`;
                                if (this.terminal) {
                                    this.terminal.log(message, 'info');
                                }
                                debugLog(`✨ ${message}`);
                            }
                        }
                    }

                    // Create and add each effect from the preset chain
                    for (const effectDef of preset.chain) {
                        const effectModule = {
                            type: effectDef.type,
                            params: effectDef.params
                        };

                        const audioNode = this.createAudioNode(effectModule);

                        if (audioNode) {
                            // Connect pending LFO if exists
                            if (pendingLFO) {
                                this.connectLFOToModule(pendingLFO.lfo, audioNode, effectModule.type);
                                pendingLFO = null;
                            }

                            // Connect to previous node
                            if (currentNode) {
                                if (currentNode.output) {
                                    currentNode.output.connect(audioNode.input || audioNode);
                                } else {
                                    currentNode.connect(audioNode.input || audioNode);
                                }
                            }

                            chainNodes.push(audioNode);
                            if (module.type === 'out') {
                                debugLog('[PARSER] Pushed out node to chainNodes, isMixerOut:', audioNode.isMixerOut, 'mixerName:', audioNode.mixerName);
                            }
                            currentNode = audioNode.output || audioNode;

                            // Start if needed (skip if already started)
                            if (audioNode.start && !audioNode._started) {
                                try {
                                    audioNode.start();
                                    audioNode._started = true;
                                } catch(e) {
                                    // Already started, ignore
                                }
                            }
                        }
                    }

                    this.modules.push(module);
                } else {
                    const message = `Preset not found: ${synthName}/${presetName}`;
                    if (this.terminal) {
                        this.terminal.log(message, 'error');
                    }
                    console.warn(message);
                }
                continue; // Move to next part
            }

            // Create the actual audio node
            let audioNode = this.createAudioNode(module);

            if (module.type === 'out') {
                debugLog('[PARSER] After createAudioNode for out, audioNode:', audioNode, 'truthy:', !!audioNode);
            }

            if (audioNode) {
                // Store audioNode reference on module for real-time tracking
                module.audioNode = audioNode;

                // Register tag if present
                if (module.tagName) {
                    const lineNumber = module.lineNumber || 0;
                    this.tagRegistry.register(
                        module.tagName,
                        module.type,
                        audioNode,
                        lineNumber,
                        module.params
                    );
                }

                // Check if this is an LFO
                if (audioNode.isLFO) {
                    pendingLFO = { lfo: audioNode, module: module };
                    this.modules.push(module);
                    continue; // Don't add to chain, wait for next module
                }

                // If we have a pending LFO, connect it to this module's parameter
                if (pendingLFO) {
                    this.connectLFOToModule(pendingLFO.lfo, audioNode, module.type);
                    pendingLFO = null;
                }

                // Apply default anti-click envelope to sources if no explicit envelope exists
                if (this.isSourceModule(module.type) && !hasExplicitEnvelope && !currentNode) {
                    // This is a source at the start of the chain without explicit envelope
                    // Use envelope with params: attack=0.001, decay=0.0, sustain=0.0, release=0.01
                    const antiClickGain = this.engine.context.createGain();
                    antiClickGain.gain.value = 0;

                    const now = this.engine.context.currentTime;
                    const attack = 0.001;
                    const decay = 0.0;
                    const sustain = 1.0; // Full sustain for continuous sources
                    const release = 0.01;

                    // Apply ADSR envelope
                    antiClickGain.gain.cancelScheduledValues(now);
                    antiClickGain.gain.setValueAtTime(0, now);
                    antiClickGain.gain.linearRampToValueAtTime(1, now + attack);
                    antiClickGain.gain.linearRampToValueAtTime(sustain, now + attack + decay);

                    // Connect source -> antiClickGain
                    if (audioNode.output) {
                        audioNode.output.connect(antiClickGain);
                    } else {
                        audioNode.connect(antiClickGain);
                    }

                    // Wrap the audioNode reference to use antiClickGain as output
                    const wrappedNode = {
                        input: audioNode.input || audioNode,
                        output: antiClickGain,
                        source: audioNode,
                        antiClickGain: antiClickGain,
                        start: audioNode.start ? audioNode.start.bind(audioNode) : null
                    };

                    audioNode = wrappedNode;
                    module.audioNode = wrappedNode;
                }

                // Check if this is an out() node - don't connect it in the chain
                const isOutNode = module.type === 'out';

                // Connect to previous node (but not if this is an out() node)
                if (currentNode && !isOutNode) {
                    if (currentNode.output) {
                        currentNode.output.connect(audioNode.input || audioNode);
                    } else {
                        currentNode.connect(audioNode.input || audioNode);
                    }
                }

                chainNodes.push(audioNode);
                if (isOutNode) {
                    debugLog('[PARSER] Pushed out node to chainNodes (main loop), isMixerOut:', audioNode.isMixerOut, 'mixerName:', audioNode.mixerName, 'audioNode:', audioNode);
                }

                // Only update currentNode if this is not an out() node
                if (!isOutNode) {
                    currentNode = audioNode.output || audioNode;
                }

                // Start oscillators (skip if already started)
                if (audioNode.start && !audioNode._started) {
                    try {
                        audioNode.start();
                        audioNode._started = true;
                    } catch(e) {
                        // Already started, ignore
                    }
                }

                this.modules.push(module);
            }
        }

        // Check if chain ends with 'out' module
        const hasOut = parts.some(part => {
            const trimmed = part.trim();
            return trimmed === 'out' || trimmed.startsWith('out(');
        });

        // Check if the last node is a mixer out
        const lastNode = chainNodes[chainNodes.length - 1];
        const isMixerOut = lastNode && lastNode.isMixerOut;
        debugLog('[PARSER] lastNode:', lastNode, 'isMixerOut:', isMixerOut);

        // Determine the actual output node to connect
        // If last node is an out() marker, connect the node before it
        // Otherwise, connect the last node
        let outputNode;
        if (lastNode && lastNode.isMixerOut) {
            // Mixer out marker - connect node before it
            outputNode = chainNodes.length > 1 ? chainNodes[chainNodes.length - 2] : null;
            debugLog('[PARSER] Mixer out detected, outputNode is node before it:', outputNode);
        } else if (lastNode && lastNode.gain && lastNode.gain.value !== undefined && !lastNode.isMixerInput) {
            // Regular gain/effect node - this is the output
            outputNode = lastNode;
        } else {
            // Last node might be a source - connect it
            outputNode = lastNode;
        }

        // Add automatic limiter before output if no explicit limiter exists
        let finalOutputNode = outputNode;
        if (hasOut && outputNode && !hasExplicitLimiter) {
            // Create default limiter: limiter(-3, 0.003, 0.1)
            const defaultLimiter = this.engine.createLimiter(-3, 0.003, 0.1);

            // Connect outputNode -> limiter
            if (outputNode.output) {
                outputNode.output.connect(defaultLimiter.input);
            } else {
                outputNode.connect(defaultLimiter.input);
            }

            finalOutputNode = defaultLimiter;
            // Note: don't add to chainNodes so it's invisible to the user
        }

        // Connect to destination (master or mixer channel)
        debugLog('[PARSER] parseChain checks - hasOut:', hasOut, 'finalOutputNode:', !!finalOutputNode, 'isMixerOut:', isMixerOut);
        if (hasOut && finalOutputNode) {
            if (isMixerOut) {
                // Route to mixer channel(s)
                const mixerName = lastNode.mixerName;
                const channels = lastNode.mixerChannels;

                debugLog('[PARSER] Routing to mixer:', mixerName, 'channels:', channels);

                channels.forEach(channelNum => {
                    const mixerChannel = this.engine.getMixerChannel(mixerName, channelNum);
                    if (finalOutputNode.output) {
                        finalOutputNode.output.connect(mixerChannel);
                    } else {
                        finalOutputNode.connect(mixerChannel);
                    }
                    debugLog('[PARSER] Connected audio to mixer', mixerName, 'channel', channelNum);
                });
            } else {
                // Regular master out
                if (finalOutputNode.output) {
                    finalOutputNode.output.connect(this.engine.masterGain);
                } else {
                    finalOutputNode.connect(this.engine.masterGain);
                }
            }
        } else if (!hasOut && chainNodes.length > 0) {
            const message = 'Chain missing "-> out" at the end. Chain will not produce sound.';
            if (this.terminal) {
                this.terminal.log(message, 'error');
            }
            console.warn(message);
        }

        this.engine.chains.push({
            nodes: chainNodes,
            lineNumber: this.currentLineInfo ? this.currentLineInfo.lineNumber : -1
        });
    }

    parseSequencerChain(parts, seqModule = null) {
        // Parse: seq([C4, E4, G4], 8) -> osc(saw) -> lpf(800) -> out
        // Or: tracker(4) ... -> out
        // If seqModule is not provided, parse it from parts[0]
        if (!seqModule) {
            seqModule = this.parseModule(parts[0]);
            if (!seqModule) return;
        }

        // Set line number from current parsing context
        if (this.currentLineInfo) {
            seqModule.lineNumber = this.currentLineInfo.lineNumber;
        }

        this.modules.push(seqModule);

        // Parse the rest of the chain (osc/noise, filters, effects)
        const chainNodes = [];
        let oscType = 'sine';
        let useNoise = false;
        let noiseType = 'white';
        let pendingLFO = null;
        let scaleTransform = null;
        let quantizePreset = null;

        // Track position in the original line
        let charOffset = 0;
        if (this.currentLineInfo) {
            // Find where the first part starts
            charOffset = this.currentLineInfo.originalLine.indexOf(parts[0]);
        }

        // Source modules that should replace the default oscillator
        const sourceModules = ['pluck', 'blow', 'bow', 'strike', 'fm', 'am', 'pwm', 'sub', 'supersaw', 'wavetable', 'sample', 'grain', 'loop', 'const', 'impulse', 'click', 'grains', 'sampler'];
        let sourceModuleType = null;
        let sourceModuleParams = null;
        let maxVoices = null; // Track voice limit if specified

        for (let i = 1; i < parts.length; i++) {
            const module = this.parseModule(parts[i]);
            if (!module) continue;

            // Track module position in the line
            if (this.currentLineInfo) {
                module.lineNumber = this.currentLineInfo.lineNumber;

                const moduleStart = this.currentLineInfo.originalLine.indexOf(parts[i], charOffset);
                if (moduleStart !== -1) {
                    module.charPosition = {
                        start: moduleStart,
                        end: moduleStart + parts[i].length
                    };
                    charOffset = moduleStart + parts[i].length;
                }
            }

            if (module.type === 'voices') {
                // Store voice limit
                maxVoices = module.params.maxVoices;
                this.modules.push(module);
            } else if (module.type === 'scale') {
                // Store scale transform to apply to sequence
                scaleTransform = module.params;
                this.modules.push(module);
            } else if (module.type === 'quantize') {
                // Store quantize preset to apply to sequence
                quantizePreset = module.params.preset;
                this.modules.push(module);
            } else if (module.type === 'osc') {
                oscType = module.params.type || 'sine';
                useNoise = false;
                this.modules.push(module);
            } else if (module.type === 'noise') {
                useNoise = true;
                noiseType = module.params.type || 'white';
                this.modules.push(module);
            } else if (sourceModules.includes(module.type)) {
                // This is a source module - store it to pass to sequencer
                sourceModuleType = module.type;
                sourceModuleParams = module.params;

                // Special handling for sampler - need to create and store the promise
                if (module.type === 'sampler') {
                    sourceModuleParams.samplerPromise = this.engine.createMultiSampler(module.params.sampleMap);
                }

                this.modules.push(module);
            } else if (module.type === 'lfo') {
                // Store LFO to connect to next module
                const audioNode = this.createAudioNode(module);
                if (audioNode) {
                    pendingLFO = { lfo: audioNode, module: module };
                    this.modules.push(module);
                }
            } else if (module.type === 'out') {
                // Handle out module - store it for mixer routing
                const audioNode = this.createAudioNode(module);
                if (audioNode) {
                    chainNodes.push(audioNode);
                    this.modules.push(module);
                }
            } else if (module.type === 'preset') {
                // Expand preset into multiple effect nodes
                const synthName = module.params.synth;
                const presetName = module.params.preset;
                const preset = getSynthPreset(synthName, presetName);

                if (preset) {
                    debugLog(`Expanding preset: ${synthName}/${presetName} - ${preset.name}`);

                    // Validate source compatibility
                    let sourceType = sourceModuleType || (useNoise ? 'noise' : 'osc');
                    const expectedTypes = preset.sourceTypes || [];
                    const isCompatible = expectedTypes.some(type => type === sourceType || type === `seq+${sourceType}`);

                    if (!isCompatible) {
                        const message = `Preset "${synthName}/${presetName}" expects ${expectedTypes.join(' or ')} but got seq+${sourceType}`;
                        if (this.terminal) {
                            this.terminal.log(message, 'warning');
                        }
                        console.warn(`⚠️  ${message}`);
                    }

                    // Auto-fix: switch sine waves to sawtooth for filter-heavy presets
                    if (!useNoise && !sourceModuleType && oscType === 'sine') {
                        const hasFilters = preset.chain.some(e => ['lpf', 'hpf', 'bpf'].includes(e.type));
                        if (hasFilters) {
                            // Auto-switch to sawtooth for better filter response
                            oscType = 'sawtooth';

                            // Update the editor text
                            if (this.onAutoFix && this.currentLineInfo) {
                                this.onAutoFix(this.currentLineInfo.lineNumber, 'sine', 'sawtooth');
                            }

                            const message = `Auto-switched from sine to sawtooth for preset "${synthName}/${presetName}" (filters work better with harmonics)`;
                            if (this.terminal) {
                                this.terminal.log(message, 'info');
                            }
                            debugLog(`✨ ${message}`);
                        }
                    }

                    // Override oscillator type if preset specifies one
                    if (preset.waveform && !useNoise) {
                        oscType = preset.waveform;
                    }

                    // Create and add each effect from the preset chain
                    for (const effectDef of preset.chain) {
                        const effectModule = {
                            type: effectDef.type,
                            params: effectDef.params
                        };

                        const audioNode = this.createAudioNode(effectModule);
                        if (audioNode) {
                            // Connect pending LFO if exists
                            if (pendingLFO) {
                                this.connectLFOToModule(pendingLFO.lfo, audioNode, effectModule.type);
                                pendingLFO = null;
                            }
                            chainNodes.push(audioNode);
                        }
                    }

                    this.modules.push(module);
                } else {
                    const message = `Preset not found: ${synthName}/${presetName}`;
                    if (this.terminal) {
                        this.terminal.log(message, 'error');
                    }
                    console.warn(message);
                }
            } else {
                // Create effect nodes for the chain
                const audioNode = this.createAudioNode(module);
                if (audioNode) {
                    // Connect pending LFO if exists
                    if (pendingLFO) {
                        this.connectLFOToModule(pendingLFO.lfo, audioNode, module.type);
                        pendingLFO = null;
                    }
                    chainNodes.push(audioNode);
                    this.modules.push(module);
                }
            }
        }

        // Add scale transform to seqModule params if present
        if (scaleTransform) {
            seqModule.params.scaleTransform = scaleTransform;
        }

        // Check if chain ends with 'out' module and get mixer info
        const hasOut = parts.some(part => {
            const trimmed = part.trim();
            return trimmed === 'out' || trimmed.startsWith('out(');
        });

        // Check if chain contains an explicit limiter
        const hasExplicitLimiter = parts.some(part => {
            const trimmed = part.trim();
            return trimmed.startsWith('limiter(');
        });

        // Check if the last node is a mixer out BEFORE adding limiter
        const lastNode = chainNodes[chainNodes.length - 1];
        const mixerInfo = lastNode && lastNode.isMixerOut ? {
            mixerName: lastNode.mixerName,
            channels: lastNode.mixerChannels
        } : null;

        debugLog('[PARSER] Sequencer chain - lastNode:', lastNode, 'mixerInfo:', mixerInfo);

        // Add automatic limiter before output if no explicit limiter exists
        if (hasOut && !hasExplicitLimiter && chainNodes.length > 0) {
            // Create default limiter: limiter(-3, 0.003, 0.1)
            const defaultLimiter = this.engine.createLimiter(-3, 0.003, 0.1);
            chainNodes.push(defaultLimiter);
            // Note: The sequencer will connect this in the per-note chain
        }

        if (!hasOut) {
            const message = 'Sequencer chain missing "-> out" at the end. Chain will not produce sound.';
            if (this.terminal) {
                this.terminal.log(message, 'error');
            }
            console.warn(message);
        }

        // Add sequence to sequencer
        // Pass the entire params object if it has a generator
        // Handle different sequence types
        let notesOrParams;
        if (seqModule.params.pattern) {
            // Tracker pattern
            notesOrParams = seqModule.params;
        } else if (seqModule.params.generator) {
            // Generator function
            notesOrParams = seqModule.params;
        } else {
            // Static notes
            notesOrParams = seqModule.params.notes;
        }

        // Prepare oscillator/source type for sequencer
        let sourceType;
        if (sourceModuleType) {
            // Use custom source module
            sourceType = { sourceModule: sourceModuleType, params: sourceModuleParams };
        } else if (useNoise) {
            // Use noise
            sourceType = { noise: noiseType };
        } else {
            // Use standard oscillator
            sourceType = oscType;
        }

        const seq = this.sequencer.addSequence(
            notesOrParams,
            seqModule.params.subdivision || 16,
            sourceType,
            chainNodes,
            hasOut,
            mixerInfo
        );

        // Store position info on sequence
        if (seqModule.lineNumber !== undefined) {
            seq.lineNumber = seqModule.lineNumber;
        }
        if (seqModule.params.generatorArrayPositions) {
            seq.generatorArrayPositions = seqModule.params.generatorArrayPositions;
        }
        if (seqModule.params.notePositions) {
            seq.notePositions = seqModule.params.notePositions;
        }
        if (seqModule.params.patternPositions) {
            seq.patternPositions = seqModule.params.patternPositions;
        }

        // Store voice limit if specified
        if (maxVoices !== null) {
            seq.maxVoices = maxVoices;
        }

        // Store quantize preset if specified
        if (quantizePreset !== null) {
            seq.quantizePreset = quantizePreset;
        }
    }

    parseModule(moduleStr) {
        // Match function-like syntax: name(arg1, arg2, ...)
        // Need to handle nested parentheses for complex expressions
        const nameMatch = moduleStr.match(/^(\w+)\s*\(/);
        if (!nameMatch) {
            return null;
        }

        const type = nameMatch[1];

        // Track module name position if we have line info
        const moduleNamePosition = {
            start: 0,
            end: type.length
        };

        // Find matching closing paren (respecting strings and braces)
        let parenDepth = 0;
        let braceDepth = 0;
        let argsStart = moduleStr.indexOf('(') + 1;
        let argsEnd = -1;
        let inString = false;
        let stringChar = null;
        let escapeNext = false;

        for (let i = argsStart - 1; i < moduleStr.length; i++) {
            const char = moduleStr[i];

            // Handle escape sequences
            if (escapeNext) {
                escapeNext = false;
                continue;
            }

            if (char === '\\') {
                escapeNext = true;
                continue;
            }

            // Track string state
            if (char === '"' || char === "'") {
                if (!inString) {
                    inString = true;
                    stringChar = char;
                } else if (char === stringChar) {
                    inString = false;
                    stringChar = null;
                }
            }

            // Only count parens and braces outside of strings
            if (!inString) {
                if (char === '(') parenDepth++;
                else if (char === '{') braceDepth++;
                else if (char === '}') braceDepth--;
                else if (char === ')') {
                    parenDepth--;
                    if (parenDepth === 0) {
                        argsEnd = i;
                        break;
                    }
                }
            }
        }

        if (argsEnd === -1) {
            const message = `Syntax error: Could not find matching paren for: ${moduleStr}`;
            if (this.terminal) {
                this.terminal.log(message, 'error');
            }
            console.warn('Could not find matching paren for:', moduleStr, 'inString:', inString, 'parenDepth:', parenDepth, 'braceDepth:', braceDepth);
            return null;
        }

        const argsStr = moduleStr.substring(argsStart, argsEnd);

        if (type === 'grains') {
            debugLog('[DEBUG parseModule] moduleStr:', moduleStr);
            debugLog('[DEBUG parseModule] argsStr:', argsStr);
        }

        // Smart split that respects arrays and strings
        const args = this.splitArgs(argsStr);

        if (type === 'grains') {
            debugLog('[DEBUG parseModule] args after splitArgs:', args);
        }

        // Check for @tag after closing paren
        const afterParen = moduleStr.substring(argsEnd + 1).trim();
        const tagMatch = afterParen.match(/^@([a-zA-Z_]\w*)/);
        const tagName = tagMatch ? tagMatch[1] : null;

        return {
            type,
            args,
            params: this.extractParams(type, args, moduleStr),
            tagName
        };
    }

    resolveTagReference(expr) {
        // Resolve @tag.property references in an expression
        // Example: "@mod.signal * 1000 + 500" -> resolves @mod.signal to its value

        if (typeof expr !== 'string') {
            return expr;
        }

        // Check if this is a pure @tag reference (no math expressions)
        const pureTagMatch = expr.trim().match(/^@([a-zA-Z_]\w*)(?:\.([a-zA-Z_]\w*))?$/);
        if (pureTagMatch) {
            const tagName = pureTagMatch[1];
            const propertyName = pureTagMatch[2] || 'signal';

            const result = this.tagRegistry.resolveProperty(tagName, propertyName);

            if (result.error) {
                if (this.terminal) {
                    this.terminal.log(`Tag error: ${result.error}`, 'error');
                }
                console.warn(`Tag resolution error:`, result.error);
                return expr;
            }

            // For audio/CV signals used as modulation sources, return in module format
            if ((result.type === 'audio' || result.type === 'cv') && propertyName === 'signal') {
                // Return a special marker that indicates this is a tag-based modulation source
                return {
                    type: 'tagModulation',
                    tagName: tagName,
                    audioNode: result.value,
                    tag: result.tag
                };
            }

            // For parameters, return the numeric value
            if (result.type === 'param' && typeof result.value === 'number') {
                return result.value;
            }

            // Return the value as-is
            return result.value;
        }

        // Find all @tag.property references in expressions
        const tagRefRegex = /@([a-zA-Z_]\w*)(?:\.([a-zA-Z_]\w*))?/g;
        let resolved = expr;

        while ((match = tagRefRegex.exec(expr)) !== null) {
            const [fullMatch, tagName, propertyName] = match;

            // Resolve the tag property
            const result = this.tagRegistry.resolveProperty(tagName, propertyName || 'signal');

            if (result.error) {
                if (this.terminal) {
                    this.terminal.log(`Tag error: ${result.error}`, 'error');
                }
                console.warn(`Tag resolution error:`, result.error);
                continue;
            }

            // Only numeric parameters can be used in expressions
            if (result.type === 'param' && typeof result.value === 'number') {
                // Replace @tag.property with the numeric value
                resolved = resolved.replace(fullMatch, result.value);
            } else {
                // Can't use audio/CV in math expressions
                if (this.terminal) {
                    this.terminal.log(`Cannot use @${tagName}.${propertyName || 'signal'} in math expression - audio signals must be used alone`, 'error');
                }
                return expr; // Return original expression
            }
        }

        return resolved;
    }

    splitArgs(argsStr) {
        const args = [];
        let current = '';
        let bracketDepth = 0;
        let parenDepth = 0;
        let braceDepth = 0;
        let inString = false;
        let stringChar = null;

        for (let i = 0; i < argsStr.length; i++) {
            const char = argsStr[i];

            if (char === '"' || char === "'") {
                if (!inString) {
                    inString = true;
                    stringChar = char;
                } else if (char === stringChar) {
                    inString = false;
                    stringChar = null;
                }
                current += char;
            } else if (!inString) {
                if (char === '[') {
                    bracketDepth++;
                    current += char;
                } else if (char === ']') {
                    bracketDepth--;
                    current += char;
                } else if (char === '(') {
                    parenDepth++;
                    current += char;
                } else if (char === ')') {
                    parenDepth--;
                    current += char;
                } else if (char === '{') {
                    braceDepth++;
                    current += char;
                } else if (char === '}') {
                    braceDepth--;
                    current += char;
                } else if (char === ',' && bracketDepth === 0 && parenDepth === 0 && braceDepth === 0) {
                    if (current.trim()) {
                        args.push(current.trim());
                    }
                    current = '';
                } else {
                    current += char;
                }
            } else {
                current += char;
            }
        }

        if (current.trim()) {
            args.push(current.trim());
        }

        return args;
    }

    extractParams(type, args, moduleStr) {
        const params = {};

        switch (type) {
            case 'osc': {
                // Smart parameter parsing: if first arg is a waveform type, treat it as type not freq
                const waveforms = ['sine', 'square', 'triangle', 'sawtooth'];
                const firstArgClean = args[0] ? args[0].trim().toLowerCase() : '';

                if (waveforms.includes(firstArgClean)) {
                    // First arg is waveform type, check if second arg is LFO
                    const freqArg = this.parseValue(args[1]);
                    if (freqArg && typeof freqArg === 'object' && freqArg.type === 'module') {
                        params.freqModulation = freqArg.module;
                        params.freq = 440; // Default base freq
                    } else {
                        params.freq = freqArg || 440;
                    }
                    params.type = firstArgClean;
                } else {
                    // Normal case: freq, type - check if freq is LFO
                    const freqArg = this.parseValue(args[0]);
                    if (freqArg && typeof freqArg === 'object' && freqArg.type === 'module') {
                        params.freqModulation = freqArg.module;
                        params.freq = 440; // Default base freq
                    } else {
                        params.freq = freqArg || 440;
                    }
                    params.type = args[1] ? args[1].trim().toLowerCase() : 'sine';
                }
                break;
            }

            case 'noise':
                params.type = args[0] || 'white';
                break;

            case 'const':
                params.value = this.parseValue(args[0]) || 0.5;
                break;

            case 'impulse':
                params.rate = this.parseValue(args[0]) || 4;
                break;

            case 'click':
                params.freq = this.parseValue(args[0]) || 2;
                break;

            case 'pwm': {
                params.freq = this.parseValue(args[0]) || 220;

                // Check if width parameter is an LFO module
                const widthArg = this.parseValue(args[1]);
                if (widthArg && typeof widthArg === 'object' && widthArg.type === 'module') {
                    params.widthModulation = widthArg.module;
                    params.width = 0.5; // Default base width
                } else {
                    params.width = widthArg || 0.5;
                }
                break;
            }

            case 'sub':
                params.freq = this.parseValue(args[0]) || 110;
                params.octaves = this.parseValue(args[1]) || -1;
                break;

            case 'supersaw':
                params.freq = this.parseValue(args[0]) || 220;
                params.detune = this.parseValue(args[1]) || 0.1;
                params.voices = this.parseValue(args[2]) || 7;
                break;

            case 'fm': {
                // Check for LFO modulation on carrier frequency
                const carrierArg = this.parseValue(args[0]);
                if (carrierArg && typeof carrierArg === 'object' && carrierArg.type === 'module') {
                    params.carrierModulation = carrierArg.module;
                    params.carrier = 440;
                } else {
                    params.carrier = carrierArg || 440;
                }

                // Check for LFO modulation on modulator frequency
                const modulatorArg = this.parseValue(args[1]);
                if (modulatorArg && typeof modulatorArg === 'object' && modulatorArg.type === 'module') {
                    params.modulatorModulation = modulatorArg.module;
                    params.modulator = 220;
                } else {
                    params.modulator = modulatorArg || 220;
                }

                // Check for LFO modulation on modulation depth
                const depthArg = this.parseValue(args[2]);
                if (depthArg && typeof depthArg === 'object' && depthArg.type === 'module') {
                    params.depthModulation = depthArg.module;
                    params.depth = 2;
                } else {
                    params.depth = depthArg || 2;
                }
                break;
            }

            case 'am': {
                // Check for LFO modulation on carrier frequency
                const carrierArg = this.parseValue(args[0]);
                if (carrierArg && typeof carrierArg === 'object' && carrierArg.type === 'module') {
                    params.carrierModulation = carrierArg.module;
                    params.carrier = 440;
                } else {
                    params.carrier = carrierArg || 440;
                }

                // Check for LFO modulation on modulator frequency
                const modulatorArg = this.parseValue(args[1]);
                if (modulatorArg && typeof modulatorArg === 'object' && modulatorArg.type === 'module') {
                    params.modulatorModulation = modulatorArg.module;
                    params.modulator = 10;
                } else {
                    params.modulator = modulatorArg || 10;
                }

                // Check for LFO modulation on modulation depth
                const depthArg = this.parseValue(args[2]);
                if (depthArg && typeof depthArg === 'object' && depthArg.type === 'module') {
                    params.depthModulation = depthArg.module;
                    params.depth = 0.5;
                } else {
                    params.depth = depthArg || 0.5;
                }
                break;
            }

            case 'pluck':
                params.freq = this.parseValue(args[0]) || 220;
                params.decay = this.parseValue(args[1]) || 2;
                break;

            case 'sample':
                params.url = args[0] ? args[0].replace(/['"]/g, '') : '';
                params.rate = this.parseValue(args[1]) || 1;
                break;

            case 'grains':
                // First parameter can be URL string or source expression
                debugLog('[DEBUG grains] args:', args);
                debugLog('[DEBUG grains] args[0]:', args[0]);
                const sourceArg = args[0];
                debugLog('[DEBUG grains] sourceArg:', sourceArg);
                debugLog('[DEBUG grains] condition check:', sourceArg && (sourceArg.startsWith('@') || sourceArg.includes('(')));
                if (sourceArg && (sourceArg.startsWith('@') || sourceArg.includes('('))) {
                    // It's a tag reference or expression, store it as-is
                    debugLog('[DEBUG grains] Using sourceExpression mode');
                    params.sourceExpression = sourceArg;
                    params.url = ''; // Clear URL
                } else {
                    // It's a URL string
                    debugLog('[DEBUG grains] Using URL mode');
                    params.url = sourceArg ? sourceArg.replace(/['"]/g, '') : '';
                    params.sourceExpression = null;
                }
                params.grainSize = this.parseValue(args[1]) || 100; // ms
                params.density = this.parseValue(args[2]) || 10;
                params.position = this.parseValue(args[3]) || 0.5; // 0-1
                params.spread = this.parseValue(args[4]) || 0.1;
                params.pitch = this.parseValue(args[5]) || 1.0;
                params.bufferRefreshRate = this.parseValue(args[6]) || 1.0; // seconds
                debugLog('[DEBUG grains] Final params:', params);
                break;

            case 'wavetable':
                params.freq = this.parseValue(args[0]) || 440;
                params.table = args[1] ? args[1].replace(/['"]/g, '') : 'basic';
                break;

            case 'loop':
                params.buffer = args[0]; // Buffer reference
                params.start = this.parseValue(args[1]) || 0;
                params.end = this.parseValue(args[2]) || 1;
                break;

            case 'grain':
                params.buffer = args[0]; // Buffer reference
                params.position = this.parseValue(args[1]) || 0.5;
                params.size = this.parseValue(args[2]) || 100;
                break;

            case 'blow':
                params.freq = this.parseValue(args[0]) || 440;
                params.pressure = this.parseValue(args[1]) || 0.8;
                break;

            case 'bow':
                params.freq = this.parseValue(args[0]) || 440;
                params.pressure = this.parseValue(args[1]) || 0.6;
                break;

            case 'strike':
                params.freq = this.parseValue(args[0]) || 440;
                params.hardness = this.parseValue(args[1]) || 0.8;
                break;

            case 'filter':
            case 'lpf':
            case 'hpf':
            case 'bpf':
                if (type === 'filter') {
                    params.type = args[0];
                } else if (type === 'lpf') {
                    params.type = 'lowpass';
                } else if (type === 'hpf') {
                    params.type = 'highpass';
                } else if (type === 'bpf') {
                    params.type = 'bandpass';
                }

                const freqArg = this.parseValue(args[type === 'filter' ? 1 : 0]);
                const qArg = this.parseValue(args[type === 'filter' ? 2 : 1]);
                const modulationArg = this.parseValue(args[type === 'filter' ? 3 : 2]);

                // Handle frequency parameter (could be a number, LFO module, or tag modulation)
                if (freqArg && typeof freqArg === 'object' && freqArg.type === 'module') {
                    params.freqModulation = freqArg.module;
                    params.freq = 0; // Base frequency is 0 when using LFO
                } else if (freqArg && typeof freqArg === 'object' && freqArg.type === 'tagModulation') {
                    params.tagModulation = freqArg; // Store tag modulation info
                    params.freq = 0; // Base frequency is 0 when using tag modulation
                } else {
                    params.freq = freqArg || 1000;
                }

                // Handle Q parameter
                if (qArg && typeof qArg === 'object' && qArg.type === 'module') {
                    params.qModulation = qArg.module;
                    params.q = 1; // Default Q
                } else if (qArg && typeof qArg === 'object' && qArg.type === 'tagModulation') {
                    params.qTagModulation = qArg; // Store tag modulation info for Q
                    params.q = 1; // Default Q
                } else {
                    params.q = qArg || 1;
                }

                // Handle third argument as modulation (for syntax: lpf(baseFreq, q, lfo(...)))
                if (modulationArg && typeof modulationArg === 'object' && modulationArg.type === 'module') {
                    params.freqModulation = modulationArg.module;
                    params.freq = 0; // Base frequency is 0 when using inline LFO
                } else if (modulationArg && typeof modulationArg === 'object' && modulationArg.type === 'tagModulation') {
                    params.tagModulation = modulationArg;
                    params.freq = 0; // Base frequency is 0 when using tag modulation
                }
                break;

            case 'delay': {
                // Check if time parameter is an LFO module
                const timeArg = this.parseValue(args[0]);
                if (timeArg && typeof timeArg === 'object' && timeArg.type === 'module') {
                    params.timeModulation = timeArg.module;
                    params.time = 0.5; // Default base time
                } else {
                    params.time = timeArg || 0.5;
                }

                // Check if feedback parameter is an LFO module
                const feedbackArg = this.parseValue(args[1]);
                if (feedbackArg && typeof feedbackArg === 'object' && feedbackArg.type === 'module') {
                    params.feedbackModulation = feedbackArg.module;
                    params.feedback = 0.3; // Default base feedback
                } else {
                    params.feedback = feedbackArg || 0.3;
                }
                break;
            }

            case 'reverb': {
                // Check for LFO modulation on amount (wet mix)
                const amountArg = this.parseValue(args[0]);
                if (amountArg && typeof amountArg === 'object' && amountArg.type === 'module') {
                    params.amountModulation = amountArg.module;
                    params.amount = 0.3;
                } else {
                    params.amount = amountArg || 0.3;
                }

                params.length = this.parseValue(args[1]) || 2;
                params.type = args[2] || 'dattorro'; // hall, plate, room, dattorro (default)

                // Extended Dattorro parameters (if more args provided)
                // Check for LFO modulation on decay
                if (args[3] !== undefined) {
                    const decayArg = this.parseValue(args[3]);
                    if (decayArg && typeof decayArg === 'object' && decayArg.type === 'module') {
                        params.decayModulation = decayArg.module;
                        params.decay = 0.5;
                    } else {
                        params.decay = decayArg;
                    }
                }

                // Check for LFO modulation on damping
                if (args[4] !== undefined) {
                    const dampingArg = this.parseValue(args[4]);
                    if (dampingArg && typeof dampingArg === 'object' && dampingArg.type === 'module') {
                        params.dampingModulation = dampingArg.module;
                        params.damping = 0.005;
                    } else {
                        params.damping = dampingArg;
                    }
                }

                if (args[5] !== undefined) params.inputDiffusion1 = this.parseValue(args[5]);
                if (args[6] !== undefined) params.inputDiffusion2 = this.parseValue(args[6]);
                if (args[7] !== undefined) params.decayDiffusion1 = this.parseValue(args[7]);
                if (args[8] !== undefined) params.decayDiffusion2 = this.parseValue(args[8]);
                if (args[9] !== undefined) params.bandwidth = this.parseValue(args[9]);
                if (args[10] !== undefined) params.preDelay = this.parseValue(args[10]);
                if (args[11] !== undefined) params.excursionRate = this.parseValue(args[11]);
                if (args[12] !== undefined) params.excursionDepth = this.parseValue(args[12]);
                break;
            }

            case 'env':
            case 'envelope': {
                // Parse each envelope parameter, checking if it's an LFO module
                const attackArg = this.parseValue(args[0]);
                const decayArg = this.parseValue(args[1]);
                const sustainArg = this.parseValue(args[2]);
                const releaseArg = this.parseValue(args[3]);

                // Attack parameter
                if (attackArg && typeof attackArg === 'object' && attackArg.type === 'module') {
                    params.attackModulation = attackArg.module;
                    params.attack = 0; // Base is 0 when using LFO (LFO value becomes the actual value)
                } else {
                    params.attack = attackArg || 0.01;
                }

                // Decay parameter
                if (decayArg && typeof decayArg === 'object' && decayArg.type === 'module') {
                    params.decayModulation = decayArg.module;
                    params.decay = 0; // Base is 0 when using LFO
                } else {
                    params.decay = decayArg || 0.1;
                }

                // Sustain parameter
                if (sustainArg && typeof sustainArg === 'object' && sustainArg.type === 'module') {
                    params.sustainModulation = sustainArg.module;
                    params.sustain = 0; // Base is 0 when using LFO
                } else {
                    params.sustain = sustainArg || 0.7;
                }

                // Release parameter
                if (releaseArg && typeof releaseArg === 'object' && releaseArg.type === 'module') {
                    params.releaseModulation = releaseArg.module;
                    params.release = 0; // Base is 0 when using LFO
                } else {
                    params.release = releaseArg || 0.3;
                }
                break;
            }

            case 'gain': {
                // Check if value parameter is an LFO module or tag modulation
                const valueArg = this.parseValue(args[0]);
                if (valueArg && typeof valueArg === 'object' && valueArg.type === 'module') {
                    params.valueModulation = valueArg.module;
                    params.value = 1.0; // Default base value
                } else if (valueArg && typeof valueArg === 'object' && valueArg.type === 'tagModulation') {
                    params.tagModulation = valueArg; // Store tag modulation info
                    params.value = 1.0; // Default base value
                } else {
                    params.value = valueArg ?? 1.0;
                }
                break;
            }

            case 'pan': {
                // Check if position parameter is an LFO module
                const positionArg = this.parseValue(args[0]);
                if (positionArg && typeof positionArg === 'object' && positionArg.type === 'module') {
                    params.positionModulation = positionArg.module;
                    params.position = 0; // Default center
                } else {
                    params.position = positionArg || 0;
                }
                break;
            }

            case 'width':
            case 'stereo': {
                // Check for LFO modulation on width
                const widthArg = this.parseValue(args[0]);
                if (widthArg && typeof widthArg === 'object' && widthArg.type === 'module') {
                    params.widthModulation = widthArg.module;
                    params.width = 0.5;
                } else {
                    params.width = widthArg || 0.5;
                }

                params.detune = this.parseValue(args[1]) || 5;
                break;
            }

            case 'pingpong': {
                // Check for LFO modulation on time
                const timeArg = this.parseValue(args[0]);
                if (timeArg && typeof timeArg === 'object' && timeArg.type === 'module') {
                    params.timeModulation = timeArg.module;
                    params.time = 0.25;
                } else {
                    params.time = timeArg || 0.25;
                }

                // Check for LFO modulation on feedback
                const feedbackArg = this.parseValue(args[1]);
                if (feedbackArg && typeof feedbackArg === 'object' && feedbackArg.type === 'module') {
                    params.feedbackModulation = feedbackArg.module;
                    params.feedback = 0.4;
                } else {
                    params.feedback = feedbackArg || 0.4;
                }
                break;
            }

            case 'chorus': {
                // Check for LFO modulation on rate
                const rateArg = this.parseValue(args[0]);
                if (rateArg && typeof rateArg === 'object' && rateArg.type === 'module') {
                    params.rateModulation = rateArg.module;
                    params.rate = 1.5;
                } else {
                    params.rate = rateArg || 1.5;
                }

                // Check for LFO modulation on depth
                const depthArg = this.parseValue(args[1]);
                if (depthArg && typeof depthArg === 'object' && depthArg.type === 'module') {
                    params.depthModulation = depthArg.module;
                    params.depth = 0.002;
                } else {
                    params.depth = depthArg || 0.002;
                }

                // Check for LFO modulation on mix
                const mixArg = this.parseValue(args[2]);
                if (mixArg && typeof mixArg === 'object' && mixArg.type === 'module') {
                    params.mixModulation = mixArg.module;
                    params.mix = 0.5;
                } else {
                    params.mix = mixArg || 0.5;
                }
                break;
            }

            case 'phaser': {
                // Check for LFO modulation on rate
                const rateArg = this.parseValue(args[0]);
                if (rateArg && typeof rateArg === 'object' && rateArg.type === 'module') {
                    params.rateModulation = rateArg.module;
                    params.rate = 0.5;
                } else {
                    params.rate = rateArg || 0.5;
                }

                // Check for LFO modulation on depth
                const depthArg = this.parseValue(args[1]);
                if (depthArg && typeof depthArg === 'object' && depthArg.type === 'module') {
                    params.depthModulation = depthArg.module;
                    params.depth = 1;
                } else {
                    params.depth = depthArg || 1;
                }

                params.stages = this.parseValue(args[2]) || 4;
                break;
            }

            case 'distortion':
            case 'dist': {
                params.amount = this.parseValue(args[0]) || 50;

                // Check if mix parameter is an LFO module
                const mixArg = this.parseValue(args[1]);
                if (mixArg && typeof mixArg === 'object' && mixArg.type === 'module') {
                    params.mixModulation = mixArg.module;
                    params.mix = 1.0; // Default base mix
                } else {
                    params.mix = mixArg || 1.0;
                }
                break;
            }

            case 'bitcrush':
            case 'crush':
                params.bits = this.parseValue(args[0]) || 4;
                params.sampleRate = this.parseValue(args[1]) || 4000;
                break;

            case 'granular':
                params.grainSize = this.parseValue(args[0]) || 50; // ms
                params.density = this.parseValue(args[1]) || 10;
                params.spread = this.parseValue(args[2]) || 0.1;
                params.pitch = this.parseValue(args[3]) || 1.0;
                break;

            case 'stutter':
                params.rate = this.parseValue(args[0]) || 8;
                params.length = this.parseValue(args[1]) || 0.125;
                break;

            case 'freeze':
                params.fadeTime = this.parseValue(args[0]) || 0.01;
                break;

            case 'gate':
                params.rate = this.parseValue(args[0]) || 16;
                // Parse pattern array: gate(16, [1,0,1,0])
                if (args[1]) {
                    const patternStr = args[1].trim();
                    if (patternStr.startsWith('[') && patternStr.endsWith(']')) {
                        const inner = patternStr.slice(1, -1);
                        params.pattern = inner.split(',').map(v => parseInt(v.trim()));
                    } else {
                        params.pattern = [1, 0, 1, 0];
                    }
                } else {
                    params.pattern = [1, 0, 1, 0];
                }
                break;

            case 'downsample':
                params.factor = this.parseValue(args[0]) || 4;
                break;

            case 'glitch':
                params.intensity = this.parseValue(args[0]) || 0.5;
                params.rate = this.parseValue(args[1]) || 10;
                break;

            case 'out':
                // Output node - can be out() or out(@mixer, channel) or out(@mixer, ch1, ch2, ...)
                debugLog('[EXTRACT] out() args:', args);
                if (args.length >= 2) {
                    // out(@mixer, channel) or out(@mixer, ch1, ch2, ...)
                    // Strip @ prefix if present
                    let mixerName = args[0];
                    debugLog('[EXTRACT] out() mixerName before strip:', mixerName, 'type:', typeof mixerName);
                    if (typeof mixerName === 'string' && mixerName.startsWith('@')) {
                        mixerName = mixerName.substring(1);
                        debugLog('[EXTRACT] out() stripped @ to get:', mixerName);
                    }
                    params.mixer = mixerName; // Mixer name (without @)
                    params.channels = args.slice(1).map(arg => this.parseValue(arg)); // Channel numbers
                    debugLog('[EXTRACT] out() final params.mixer:', params.mixer, 'channels:', params.channels);
                } else if (args.length === 1) {
                    // Could be out(@mixer) for default channel 1
                    let mixerName = args[0];
                    if (typeof mixerName === 'string' && mixerName.startsWith('@')) {
                        mixerName = mixerName.substring(1);
                    }
                    params.mixer = mixerName;
                    params.channels = [1];
                    debugLog('[EXTRACT] out() single arg - mixer:', params.mixer);
                }
                // If no args, it's master out (default behavior)
                break;

            case 'in':
                // Input from mixer - in(@mixer, channel) or in(@mixer, ch1, ch2, ...)
                if (args.length >= 2) {
                    // Strip @ prefix if present
                    let mixerName = args[0];
                    if (typeof mixerName === 'string' && mixerName.startsWith('@')) {
                        mixerName = mixerName.substring(1);
                    }
                    params.mixer = mixerName; // Mixer name (without @)
                    params.channels = args.slice(1).map(arg => this.parseValue(arg)); // Channel numbers
                } else if (args.length === 1) {
                    // in(@mixer) - default to channel 1
                    let mixerName = args[0];
                    if (typeof mixerName === 'string' && mixerName.startsWith('@')) {
                        mixerName = mixerName.substring(1);
                    }
                    params.mixer = mixerName;
                    params.channels = [1];
                }
                break;

            case 'voices':
                params.maxVoices = this.parseValue(args[0]) || 8;
                break;

            case 'tracker':
                // Parse tracker pattern: tracker(channels, length, [sources])
                params.channels = this.parseValue(args[0]) || 1;
                params.maxLength = this.parseValue(args[1]) || 64; // Default to 64 rows
                params.subdivision = 16; // Default to 16th notes

                // Parse sources array if provided (third argument): tracker(4, 64, [osc(sine), ...])
                if (args[2]) {
                    const sourcesStr = args[2].trim();
                    if (sourcesStr.startsWith('[') && sourcesStr.endsWith(']')) {
                        // Remove brackets
                        const sourcesContent = sourcesStr.slice(1, -1);
                        // Split by comma but respect nested parentheses
                        const sources = this.splitArgs(sourcesContent);
                        params.sources = sources.map(src => {
                            const trimmed = src.trim();
                            // Check if source is a chain (contains ->)
                            if (trimmed.includes('->')) {
                                // Parse as a mini-chain
                                const chainModules = trimmed.split('->').map(s => s.trim());
                                const parsedChain = chainModules.map(m => this.parseModule(m)).filter(m => m);
                                return { isChain: true, modules: parsedChain };
                            } else {
                                // Parse as single module
                                return this.parseModule(trimmed);
                            }
                        }).filter(m => m);
                    }
                }

                // The pattern is the rest of the moduleStr after tracker(...arguments...)
                // Extract it from the full moduleStr
                // Find the closing paren by tracking depth to handle nested parentheses
                const startIdx = moduleStr.indexOf('tracker');
                if (startIdx !== -1) {
                    const openParen = moduleStr.indexOf('(', startIdx);
                    if (openParen !== -1) {
                        let depth = 0;
                        let closeParen = -1;

                        for (let i = openParen; i < moduleStr.length; i++) {
                            if (moduleStr[i] === '(') depth++;
                            else if (moduleStr[i] === ')') {
                                depth--;
                                if (depth === 0) {
                                    closeParen = i;
                                    break;
                                }
                            }
                        }

                        if (closeParen !== -1) {
                            // Everything after the closing paren until -> or end of string
                            const afterArgs = moduleStr.substring(closeParen + 1);
                            const arrowIdx = afterArgs.indexOf('->');
                            const patternText = arrowIdx !== -1
                                ? afterArgs.substring(0, arrowIdx).trim()
                                : afterArgs.trim();

                            if (patternText) {
                                const result = this.parseTrackerPattern(patternText, params.channels, params.maxLength);
                                params.pattern = result.pattern;
                                params.patternPositions = result.positions;
                            }
                        }
                    }
                }
                break;

            case 'seq':
                // Support: array, string pattern, or generator function
                const firstArg = args[0];

                // Check if third arg has generator (seq(length, subdivision, i => expr))
                if (args[2] && /=>/.test(args[2])) {
                    params.length = this.parseValue(firstArg) || 16;
                    params.subdivision = this.parseValue(args[1]) || 16;
                    params.generator = args[2];
                    debugLog('Detected generator in args[2]:', args[2]);

                    // Try to extract array literals from the generator for position tracking
                    params.generatorArrayPositions = this.extractArrayFromGenerator(args[2]);
                }
                // Check if first arg has generator (seq(i => expr, subdivision))
                else if (firstArg && /=>/.test(firstArg)) {
                    params.length = 16; // default length
                    params.subdivision = this.parseValue(args[1]) || 16;
                    params.generator = firstArg;
                    debugLog('Detected generator in args[0]:', firstArg);
                }
                else if (firstArg && firstArg.startsWith('[')) {
                    // Array notation - parse with position tracking
                    const arrayResult = this.parseArrayWithPositions(firstArg);
                    params.notes = arrayResult.notes;
                    params.notePositions = arrayResult.positions;  // Store character positions
                    params.subdivision = this.parseValue(args[1]) || 16;
                } else if (firstArg && firstArg.startsWith('"')) {
                    // String pattern: "C4 .. E4 G4"
                    const pattern = firstArg.replace(/^"|"$/g, '');
                    params.notes = this.sequencer.parsePattern(pattern);
                    params.subdivision = this.parseValue(args[1]) || 16;

                    // Track positions for string patterns
                    params.notePositions = this.extractPositionsFromStringPattern(firstArg, pattern);
                } else {
                    // Might be: seq(length, subdivision, "expression")
                    const maybeLength = this.parseValue(firstArg);
                    if (typeof maybeLength === 'number' && args[2]) {
                        params.length = maybeLength;
                        params.subdivision = this.parseValue(args[1]) || 16;
                        params.generator = args[2].replace(/^"|"$/g, '');
                    } else {
                        params.notes = [];
                        params.subdivision = this.parseValue(args[1]) || 16;
                    }
                }
                break;

            case 'scale':
                params.root = this.parseValue(args[0]) || 440;
                params.scaleName = args[1] || 'major';
                break;

            case 'lfo':
                params.rate = this.parseValue(args[0]) || 1;

                // Check if second arg is a waveform type (string) or a number (min frequency)
                const arg1 = args[1];
                const isWaveformType = arg1 && (arg1 === 'sine' || arg1 === 'square' || arg1 === 'triangle' || arg1 === 'sawtooth');

                if (isWaveformType) {
                    // LFO with waveform: lfo(rate, type, min, max)
                    params.type = arg1;
                    const arg2 = this.parseValue(args[2]);
                    const arg3 = this.parseValue(args[3]);

                    // Treat args[2] and args[3] as min/max and convert to depth/offset
                    if (arg2 !== null && arg3 !== null) {
                        // Store original min/max for real-time updates
                        params.min = arg2;
                        params.max = arg3;
                        // offset = (min + max) / 2
                        // depth = (max - min) / 2
                        params.offset = (arg2 + arg3) / 2;
                        params.depth = (arg3 - arg2) / 2;
                    } else {
                        params.depth = 1;
                        params.offset = 0;
                    }
                } else {
                    // Inline LFO syntax: lfo(rate, minValue, maxValue)
                    params.type = 'sine'; // Default to sine
                    const minValue = this.parseValue(args[1]);
                    const maxValue = this.parseValue(args[2]);

                    if (minValue !== null && maxValue !== null) {
                        // Store original min/max for real-time updates
                        params.min = minValue;
                        params.max = maxValue;
                        // Calculate depth and offset from min/max
                        // offset = (min + max) / 2
                        // depth = (max - min) / 2
                        params.offset = (minValue + maxValue) / 2;
                        params.depth = (maxValue - minValue) / 2;
                    } else {
                        params.depth = 1;
                        params.offset = 0;
                    }
                }
                break;

            case 'tremolo':
                params.rate = this.parseValue(args[0]) || 5;
                params.depth = this.parseValue(args[1]) || 0.5;
                break;

            case 'vibrato':
                params.rate = this.parseValue(args[0]) || 5;
                params.depth = this.parseValue(args[1]) || 10;
                break;

            case 'autowah':
            case 'wah':
                params.rate = this.parseValue(args[0]) || 0.5;
                params.depth = this.parseValue(args[1]) || 800;
                params.center = this.parseValue(args[2]) || 1000;
                break;

            case 'autopan':
                params.rate = this.parseValue(args[0]) || 0.5;
                params.depth = this.parseValue(args[1]) || 1;
                break;

            case 'ringmod': {
                // Check for LFO modulation on frequency
                const freqArg = this.parseValue(args[0]);
                if (freqArg && typeof freqArg === 'object' && freqArg.type === 'module') {
                    params.freqModulation = freqArg.module;
                    params.freq = 440;
                } else {
                    params.freq = freqArg || 440;
                }
                break;
            }

            case 'flanger': {
                // Check for LFO modulation on rate
                const rateArg = this.parseValue(args[0]);
                if (rateArg && typeof rateArg === 'object' && rateArg.type === 'module') {
                    params.rateModulation = rateArg.module;
                    params.rate = 0.5;
                } else {
                    params.rate = rateArg || 0.5;
                }

                // Check for LFO modulation on depth
                const depthArg = this.parseValue(args[1]);
                if (depthArg && typeof depthArg === 'object' && depthArg.type === 'module') {
                    params.depthModulation = depthArg.module;
                    params.depth = 0.002;
                } else {
                    params.depth = depthArg || 0.002;
                }

                // Check for LFO modulation on feedback
                const feedbackArg = this.parseValue(args[2]);
                if (feedbackArg && typeof feedbackArg === 'object' && feedbackArg.type === 'module') {
                    params.feedbackModulation = feedbackArg.module;
                    params.feedback = 0.5;
                } else {
                    params.feedback = feedbackArg || 0.5;
                }
                break;
            }

            // NEW EURORACK-STYLE MODULES PARAMETERS
            case 'vca':
                params.cv = args[0] || null; // CV input (will be connected, or null for passthrough)
                break;

            case 'compressor':
            case 'comp': {
                // Check for LFO modulation on each parameter
                const thresholdArg = this.parseValue(args[0]);
                if (thresholdArg && typeof thresholdArg === 'object' && thresholdArg.type === 'module') {
                    params.thresholdModulation = thresholdArg.module;
                    params.threshold = -24;
                } else {
                    params.threshold = thresholdArg || -24;
                }

                const ratioArg = this.parseValue(args[1]);
                if (ratioArg && typeof ratioArg === 'object' && ratioArg.type === 'module') {
                    params.ratioModulation = ratioArg.module;
                    params.ratio = 4;
                } else {
                    params.ratio = ratioArg || 4;
                }

                const attackArg = this.parseValue(args[2]);
                if (attackArg && typeof attackArg === 'object' && attackArg.type === 'module') {
                    params.attackModulation = attackArg.module;
                    params.attack = 0.003;
                } else {
                    params.attack = attackArg || 0.003;
                }

                const releaseArg = this.parseValue(args[3]);
                if (releaseArg && typeof releaseArg === 'object' && releaseArg.type === 'module') {
                    params.releaseModulation = releaseArg.module;
                    params.release = 0.25;
                } else {
                    params.release = releaseArg || 0.25;
                }
                break;
            }

            case 'sidechain':
            case 'sc': {
                params.sidechain = args[0]; // Sidechain input (will be connected)

                // Check for LFO modulation on threshold
                const thresholdArg = this.parseValue(args[1]);
                if (thresholdArg && typeof thresholdArg === 'object' && thresholdArg.type === 'module') {
                    params.thresholdModulation = thresholdArg.module;
                    params.threshold = -24;
                } else {
                    params.threshold = thresholdArg || -24;
                }

                // Check for LFO modulation on ratio
                const ratioArg = this.parseValue(args[2]);
                if (ratioArg && typeof ratioArg === 'object' && ratioArg.type === 'module') {
                    params.ratioModulation = ratioArg.module;
                    params.ratio = 8;
                } else {
                    params.ratio = ratioArg || 8;
                }

                // Check for LFO modulation on attack
                const attackArg = this.parseValue(args[3]);
                if (attackArg && typeof attackArg === 'object' && attackArg.type === 'module') {
                    params.attackModulation = attackArg.module;
                    params.attack = 0.001;
                } else {
                    params.attack = attackArg || 0.001;
                }

                // Check for LFO modulation on release
                const releaseArg = this.parseValue(args[4]);
                if (releaseArg && typeof releaseArg === 'object' && releaseArg.type === 'module') {
                    params.releaseModulation = releaseArg.module;
                    params.release = 0.1;
                } else {
                    params.release = releaseArg || 0.1;
                }
                break;
            }

            case 'crossfade':
            case 'xfade': {
                // If only one arg, treat it as position (simplified mode)
                if (args.length === 1) {
                    const positionArg = this.parseValue(args[0]);
                    if (positionArg && typeof positionArg === 'object' && positionArg.type === 'module') {
                        params.positionModulation = positionArg.module;
                        params.position = 0.5;
                    } else {
                        params.position = positionArg || 0.5;
                    }
                    params.b = null;
                } else {
                    params.b = args[0]; // Signal B (passed as parameter)
                    const positionArg = this.parseValue(args[1]);
                    if (positionArg && typeof positionArg === 'object' && positionArg.type === 'module') {
                        params.positionModulation = positionArg.module;
                        params.position = 0.5;
                    } else {
                        params.position = positionArg || 0.5;
                    }
                }
                break;
            }

            case 'sh':
            case 'samplehold':
                params.rate = this.parseValue(args[0]) || 10;
                break;

            case 'sync':
                params.modulator = this.parseValue(args[0]) || 220;
                break;

            case 'fold':
            case 'wavefold':
                params.threshold = this.parseValue(args[0]) || 0.7;
                break;

            case 'euclidean':
                params.length = this.parseValue(args[0]) || 16;
                params.pulses = this.parseValue(args[1]) || 4;
                params.rotation = this.parseValue(args[2]) || 0;
                break;

            case 'pitchshift':
            case 'pitch':
                params.semitones = this.parseValue(args[0]) || 0;
                break;

            case 'porta':
            case 'portamento':
            case 'glide': {
                // Check if time parameter is an LFO module
                const timeArg = this.parseValue(args[0]);
                if (timeArg && typeof timeArg === 'object' && timeArg.type === 'module') {
                    params.timeModulation = timeArg.module;
                    params.time = 0; // Base is 0 when using LFO (LFO value becomes the actual value)
                } else {
                    params.time = timeArg || 0.1;
                }
                break;
            }

            case 'limiter': {
                // Check for LFO modulation on threshold
                const thresholdArg = this.parseValue(args[0]);
                if (thresholdArg && typeof thresholdArg === 'object' && thresholdArg.type === 'module') {
                    params.thresholdModulation = thresholdArg.module;
                    params.threshold = -3;
                } else {
                    params.threshold = thresholdArg || -3;
                }

                // Check for LFO modulation on attack
                const attackArg = this.parseValue(args[1]);
                if (attackArg && typeof attackArg === 'object' && attackArg.type === 'module') {
                    params.attackModulation = attackArg.module;
                    params.attack = 0.003;
                } else {
                    params.attack = attackArg || 0.003;
                }

                // Check for LFO modulation on release
                const releaseArg = this.parseValue(args[2]);
                if (releaseArg && typeof releaseArg === 'object' && releaseArg.type === 'module') {
                    params.releaseModulation = releaseArg.module;
                    params.release = 0.1;
                } else {
                    params.release = releaseArg || 0.1;
                }
                break;
            }

            case 'random':
                // random(type, min, max, rate)
                // type: 'value', 'freq', 'note'
                params.type = args[0] ? args[0].replace(/['"]/g, '') : 'value';
                params.min = this.parseValue(args[1]) || 0;
                params.max = this.parseValue(args[2]) || 1;
                params.rate = this.parseValue(args[3]) || 1000; // ms
                break;

            case 'bpm':
                params.value = this.parseValue(args[0]) || 120;
                break;

            case 'quantize':
                // Parse quantize preset name
                params.preset = args[0] ? args[0].replace(/['"]/g, '') : 'straight';
                break;

            case 'preset':
                // Parse synth preset: preset(synth-preset-name) OR preset(synth, preset-name)
                // Support both single argument (hyphenated) and two argument formats
                if (args.length >= 2) {
                    // Two argument format: preset(synth, preset-name)
                    params.synth = args[0] ? args[0].replace(/['"]/g, '') : null;
                    params.preset = args[1] ? args[1].replace(/['"]/g, '') : null;
                } else {
                    // Single argument format: preset(synth-preset-name)
                    const presetArg = args[0] ? args[0].replace(/['"]/g, '') : null;
                    if (presetArg) {
                        // Since synth names can contain hyphens (e.g., "arp-2600"),
                        // we need to match against known categories
                        let foundSynth = null;
                        let foundPreset = null;

                        const categories = Object.keys(SYNTH_PRESETS);
                        for (const category of categories) {
                            if (presetArg.startsWith(category + '-')) {
                                foundSynth = category;
                                foundPreset = presetArg.substring(category.length + 1);
                                break;
                            }
                        }

                        if (foundSynth && foundPreset) {
                            params.synth = foundSynth;
                            params.preset = foundPreset;
                        } else {
                            // Fallback to simple split if no match
                            const hyphenIndex = presetArg.indexOf('-');
                            if (hyphenIndex !== -1) {
                                params.synth = presetArg.substring(0, hyphenIndex);
                                params.preset = presetArg.substring(hyphenIndex + 1);
                            } else {
                                params.synth = null;
                                params.preset = presetArg;
                            }
                        }
                    } else {
                        params.synth = null;
                        params.preset = null;
                    }
                }
                break;

            case 'sampler':
                // Parse sampler with multiple samples: sampler({ 'A0': 'url1', 'A2': 'url2', ... })
                // Or single URL: sampler("url") which maps to C4
                // The first argument should be an object literal with note-to-URL mappings
                debugLog('Sampler args:', args);
                if (args[0]) {
                    const objStr = args[0].trim();
                    debugLog('Sampler objStr:', objStr);
                    // Check if it's a single URL string (not an object)
                    if ((objStr.startsWith('"') && objStr.endsWith('"')) ||
                        (objStr.startsWith("'") && objStr.endsWith("'")) ||
                        objStr.startsWith('http')) {
                        // Single URL - map to C4 as the base note
                        const url = objStr.replace(/^['"]|['"]$/g, '');
                        params.sampleMap = { 'C4': url };
                        debugLog('Parsed sampler single URL, mapped to C4:', url);
                    } else if (objStr.startsWith('{') && objStr.endsWith('}')) {
                        const content = objStr.slice(1, -1).trim();
                        const sampleMap = {};

                        // Manual parsing: split by commas that aren't inside quotes
                        let current = '';
                        let inQuote = false;
                        let quoteChar = null;

                        for (let i = 0; i < content.length; i++) {
                            const char = content[i];
                            if ((char === '"' || char === "'") && (i === 0 || content[i-1] !== '\\')) {
                                if (!inQuote) {
                                    inQuote = true;
                                    quoteChar = char;
                                } else if (char === quoteChar) {
                                    inQuote = false;
                                    quoteChar = null;
                                }
                                current += char;
                            } else if (char === ',' && !inQuote) {
                                // Process entry
                                const entry = current.trim();
                                const match = entry.match(/['"](.+?)['"][\s]*:[\s]*['"](.+?)['"]/);
                                if (match) {
                                    sampleMap[match[1]] = match[2];
                                }
                                current = '';
                            } else {
                                current += char;
                            }
                        }

                        // Process last entry
                        if (current.trim()) {
                            const entry = current.trim();
                            const match = entry.match(/['"](.+?)['"][\s]*:[\s]*['"](.+?)['"]/);
                            if (match) {
                                sampleMap[match[1]] = match[2];
                            }
                        }

                        params.sampleMap = sampleMap;
                        debugLog('Parsed sampler sampleMap:', sampleMap);
                    }
                }
                break;
        }

        return params;
    }

    parseValue(str) {
        if (!str) return null;

        // Check if it's a @tag reference
        if (str.includes('@')) {
            const resolved = this.resolveTagReference(str);
            if (resolved !== str) {
                // If resolved to something different, parse the result
                if (typeof resolved === 'string') {
                    return this.parseValue(resolved);
                }
                // Otherwise return the resolved value (could be an audio node)
                return resolved;
            }
        }

        // Check if it's a nested function call (e.g., lfo(0.08, 800, 2500))
        if (/^[a-z]+\(/.test(str)) {
            // Parse as a module and return the module descriptor
            const module = this.parseModule(str);
            if (module) {
                return { type: 'module', module };
            }
        }

        // Check if it's a note (e.g., C4, A#3)
        if (/^[A-G][#b]?\d+$/.test(str)) {
            const freq = this.engine.noteToFreq(str);
            return isFinite(freq) ? freq : null;
        }

        // Parse as number
        const num = parseFloat(str);
        if (isNaN(num) || !isFinite(num)) return str;
        return num;
    }

    parseArray(str) {
        if (!str) return [];

        // Match [item1, item2, ...]
        const match = str.match(/^\[([^\]]+)\]$/);
        if (!match) return [str];

        return match[1]
            .split(',')
            .map(s => this.parseValue(s.trim()))
            .filter(v => v !== null);
    }

    parseArrayWithPositions(arrayStr) {
        // Parse array and track character position of each element
        // arrayStr is like "[C4, E4, G4, C5]"

        const notes = [];
        const positions = [];

        const match = arrayStr.match(/^\[([^\]]+)\]$/);
        if (!match) return { notes: [arrayStr], positions: [] };

        const content = match[1]; // "C4, E4, G4, C5"
        const items = content.split(',');

        // Find where the array starts in the original line
        let lineOffset = 0;
        if (this.currentLineInfo) {
            const originalLine = this.currentLineInfo.originalLine;
            const arrayStartInLine = originalLine.indexOf('[');
            if (arrayStartInLine !== -1) {
                lineOffset = arrayStartInLine + 1;  // +1 to account for '[' itself
            }
        }

        let searchPos = 0;

        items.forEach(item => {
            const trimmed = item.trim();
            const value = this.parseValue(trimmed);

            if (value !== null) {
                // Find position of this token in the content string
                const pos = content.indexOf(trimmed, searchPos);

                if (pos !== -1) {
                    // Calculate absolute position in the line
                    positions.push({
                        lineNumber: this.currentLineInfo ? this.currentLineInfo.lineNumber : 0,
                        start: lineOffset + pos,
                        end: lineOffset + pos + trimmed.length,
                        token: trimmed
                    });
                    searchPos = pos + trimmed.length;
                }

                notes.push(value);
            }
        });

        return { notes, positions };
    }

    extractPositionsFromStringPattern(quotedPattern, cleanPattern) {
        // Extract positions for string patterns like "C4 .. E4 G4"
        // quotedPattern is like '"C4 .. E4 G4"'
        // cleanPattern is like 'C4 .. E4 G4'

        if (!this.currentLineInfo) return [];

        const originalLine = this.currentLineInfo.originalLine;
        const patternStartInLine = originalLine.indexOf(quotedPattern);
        if (patternStartInLine === -1) return [];

        // Split pattern into tokens
        const tokens = cleanPattern.split(/\s+/);
        const positions = [];
        let searchPos = 0;

        tokens.forEach(token => {
            // Find this token's position in the clean pattern
            const pos = cleanPattern.indexOf(token, searchPos);
            if (pos !== -1) {
                positions.push({
                    lineNumber: this.currentLineInfo.lineNumber,
                    start: patternStartInLine + 1 + pos, // +1 for opening quote
                    end: patternStartInLine + 1 + pos + token.length,
                    token: token
                });
                searchPos = pos + token.length;
            }
        });

        return positions;
    }

    extractArrayFromGenerator(generatorStr) {
        // Extract array literals from generator expressions like "i => [C4, D4, E4][i % 3]"
        // Find arrays in the generator string
        const arrayMatch = generatorStr.match(/\[([^\]]+)\]/);
        if (!arrayMatch) return null;

        const arrayStr = arrayMatch[0]; // "[C4, D4, E4]"
        const content = arrayMatch[1]; // "C4, D4, E4"
        const items = content.split(',').map(s => s.trim());

        // Find where this array is in the original line
        if (!this.currentLineInfo) return null;

        const originalLine = this.currentLineInfo.originalLine;
        const arrayStartInLine = originalLine.indexOf(arrayStr);
        if (arrayStartInLine === -1) return null;

        const positions = [];
        let searchPos = 0;

        items.forEach((item, index) => {
            const pos = content.indexOf(item, searchPos);
            if (pos !== -1) {
                positions.push({
                    lineNumber: this.currentLineInfo.lineNumber,
                    start: arrayStartInLine + 1 + pos, // +1 for '['
                    end: arrayStartInLine + 1 + pos + item.length,
                    token: item,
                    index: index  // Array index
                });
                searchPos = pos + item.length;
            }
        });

        return positions;
    }

    isSourceModule(type) {
        // Returns true if the module type is an audio source that can benefit from anti-click envelope
        const sourceTypes = [
            'osc', 'noise', 'const', 'impulse', 'click', 'pwm', 'sub',
            'supersaw', 'fm', 'am', 'pluck', 'sample', 'wavetable',
            'loop', 'grain', 'blow', 'bow', 'strike'
        ];
        return sourceTypes.includes(type);
    }

    createAudioNode(module) {
        const { type, params } = module;

        switch (type) {
            case 'osc': {
                const oscNode = this.engine.createOscillator(params.freq, params.type);

                // Connect freq modulation (LFO) for vibrato effect
                if (params.freqModulation && oscNode.frequency) {
                    const lfoNode = this.createAudioNode(params.freqModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(oscNode.frequency);
                        }
                    }
                }

                return oscNode;
            }

            case 'noise':
                return this.engine.createNoise(params.type);

            case 'const':
                return this.engine.createConstant(params.value);

            case 'impulse':
                return this.engine.createImpulse(params.rate);

            case 'click':
                return this.engine.createClick(params.freq);

            case 'pwm': {
                const pwm = this.engine.createPWM(params.freq, params.width);
                pwm.osc1.start();
                pwm.osc2.start();

                // Connect width modulation (LFO)
                if (params.widthModulation && pwm.widthOffset) {
                    const lfoNode = this.createAudioNode(params.widthModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(pwm.widthOffset.offset);
                        }
                    }
                }

                // Mark as started to prevent double-start in parseChain
                pwm.output._started = true;
                return pwm.output;
            }

            case 'sub': {
                const sub = this.engine.createSub(params.freq, params.octaves);
                sub.main.start();
                sub.sub.start();
                // Mark as started to prevent double-start in parseChain
                sub.output._started = true;
                return sub.output;
            }

            case 'supersaw': {
                const supersaw = this.engine.createSupersaw(params.freq, params.detune, params.voices);
                supersaw.oscillators.forEach(osc => osc.start());
                // Mark as started to prevent double-start in parseChain
                supersaw.output._started = true;
                return supersaw.output;
            }

            case 'fm': {
                const fm = this.engine.createFM(params.carrier, params.modulator, params.depth);

                // Connect LFO modulation to carrier frequency
                if (params.carrierModulation && fm.carrierFreq) {
                    const lfoNode = this.createAudioNode(params.carrierModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(fm.carrierFreq);
                        }
                    }
                }

                // Connect LFO modulation to modulator frequency
                if (params.modulatorModulation && fm.modulatorFreq) {
                    const lfoNode = this.createAudioNode(params.modulatorModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(fm.modulatorFreq);
                        }
                    }
                }

                // Connect LFO modulation to modulation depth
                if (params.depthModulation && fm.depth) {
                    const lfoNode = this.createAudioNode(params.depthModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(fm.depth);
                        }
                    }
                }

                // Start oscillators (with try-catch for already-started oscillators)
                try { fm.carrier.start(); } catch(e) {}
                try { fm.modulator.start(); } catch(e) {}
                // Mark as started to prevent double-start in parseChain
                fm.output._started = true;
                return fm.output;
            }

            case 'am': {
                const am = this.engine.createAM(params.carrier, params.modulator, params.depth);

                // Connect LFO modulation to carrier frequency
                if (params.carrierModulation && am.carrierFreq) {
                    const lfoNode = this.createAudioNode(params.carrierModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(am.carrierFreq);
                        }
                    }
                }

                // Connect LFO modulation to modulator frequency
                if (params.modulatorModulation && am.modulatorFreq) {
                    const lfoNode = this.createAudioNode(params.modulatorModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(am.modulatorFreq);
                        }
                    }
                }

                // Connect LFO modulation to modulation depth
                if (params.depthModulation && am.depth) {
                    const lfoNode = this.createAudioNode(params.depthModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(am.depth);
                        }
                    }
                }

                // Start oscillators (with try-catch for already-started oscillators)
                try { am.carrier.start(); } catch(e) {}
                try { am.modulator.start(); } catch(e) {}
                // Mark as started to prevent double-start in parseChain
                am.output._started = true;
                return am.output;
            }

            case 'pluck': {
                const pluck = this.engine.createPluck(params.freq, params.decay);
                pluck.source.start();
                // Mark as started to prevent double-start in parseChain
                pluck.output._started = true;
                return pluck.output;
            }

            case 'sample': {
                // Sample loading is async, so we need to handle this specially
                const output = this.engine.createGain();
                this.engine.createSample(params.url, params.rate).then(sample => {
                    sample.source.connect(output);
                    sample.source.start();
                });
                return output;
            }

            case 'wavetable': {
                const wavetable = this.engine.createWavetable(params.freq, params.table);
                wavetable.start();
                // Mark as started to prevent double-start in parseChain
                wavetable._started = true;
                return wavetable;
            }

            case 'loop':
                // Note: buffer needs to be pre-loaded
                return this.engine.createLoop(params.buffer, params.start, params.end);

            case 'grain':
                // Note: buffer needs to be pre-loaded
                return this.engine.createGrain(params.buffer, params.position, params.size);

            case 'blow': {
                const blow = this.engine.createBlow(params.freq, params.pressure);
                blow.source.start();
                // Mark as started to prevent double-start in parseChain
                blow.output._started = true;
                return blow.output;
            }

            case 'bow': {
                const bow = this.engine.createBow(params.freq, params.pressure);
                bow.osc.start();
                bow.vibrato.start();
                // Mark as started to prevent double-start in parseChain
                bow.output._started = true;
                return bow.output;
            }

            case 'strike': {
                const strike = this.engine.createStrike(params.freq, params.hardness);
                strike.source.start();
                // Mark as started to prevent double-start in parseChain
                strike.output._started = true;
                return strike.output;
            }

            case 'env':
            case 'envelope': {
                const envelope = this.engine.createEnvelopeGain(params.attack, params.decay, params.sustain, params.release);

                // Store LFO modulation info for sequencer to use when creating per-note envelopes
                envelope._lfoModulations = {};

                // Connect LFO modulation to envelope parameters
                if (params.attackModulation) {
                    const lfoNode = this.createAudioNode(params.attackModulation);
                    if (lfoNode && envelope.attackParam) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(envelope.attackParam.offset);
                            envelope._lfoModulations.attack = lfoNode;
                        }
                    }
                }
                if (params.decayModulation) {
                    const lfoNode = this.createAudioNode(params.decayModulation);
                    if (lfoNode && envelope.decayParam) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(envelope.decayParam.offset);
                            envelope._lfoModulations.decay = lfoNode;
                        }
                    }
                }
                if (params.sustainModulation) {
                    const lfoNode = this.createAudioNode(params.sustainModulation);
                    if (lfoNode && envelope.sustainParam) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(envelope.sustainParam.offset);
                            envelope._lfoModulations.sustain = lfoNode;
                        }
                    }
                }
                if (params.releaseModulation) {
                    const lfoNode = this.createAudioNode(params.releaseModulation);
                    if (lfoNode && envelope.releaseParam) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(envelope.releaseParam.offset);
                            envelope._lfoModulations.release = lfoNode;
                        }
                    }
                }

                // For direct chains (not in sequencer), auto-trigger the envelope with infinite sustain
                // The envelope will attack, decay to sustain level, and hold there
                if (envelope.trigger) {
                    envelope.trigger(999999); // Very long duration for continuous play
                }
                return envelope;
            }

            case 'filter':
            case 'lpf':
            case 'hpf':
            case 'bpf': {
                const filter = this.engine.createFilter(params.type, params.freq, params.q);

                // If there's frequency modulation (LFO or random), create and connect it
                if (params.freqModulation) {
                    const lfoNode = this.createAudioNode(params.freqModulation);
                    if (lfoNode) {
                        this.connectLFOToModule(lfoNode, filter, type);

                        // Store modulation info for real-time tracking
                        if (!filter.modulationInfo) {
                            filter.modulationInfo = [];
                        }
                        filter.modulationInfo.push({
                            parameter: 'frequency',
                            paramName: 'freq',
                            lfo: lfoNode,
                            baseValue: params.freq,
                            range: lfoNode.isRandom ? {
                                min: lfoNode.min,
                                max: lfoNode.max
                            } : {
                                min: lfoNode.offset - lfoNode.depth,
                                max: lfoNode.offset + lfoNode.depth
                            }
                        });
                    }
                }

                // If there's tag-based frequency modulation, connect it
                if (params.tagModulation && params.tagModulation.audioNode) {
                    const tagNode = params.tagModulation.audioNode;
                    if (tagNode && filter.frequency) {
                        const output = tagNode.output ? tagNode.output : (tagNode.connect ? tagNode : null);
                        if (output && output.connect) {
                            output.connect(filter.frequency);
                            debugLog(`[TAG MOD] Connected @${params.tagModulation.tagName} to filter frequency`);
                        }
                    }
                }

                // If there's Q modulation (LFO), create and connect it
                if (params.qModulation) {
                    const lfoNode = this.createAudioNode(params.qModulation);
                    if (lfoNode && filter.Q) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(filter.Q);

                            // Store modulation info for Q parameter
                            if (!filter.modulationInfo) {
                                filter.modulationInfo = [];
                            }
                            filter.modulationInfo.push({
                                parameter: 'Q',
                                paramName: 'q',
                                lfo: lfoNode,
                                baseValue: params.q,
                                range: {
                                    min: lfoNode.offset - lfoNode.depth,
                                    max: lfoNode.offset + lfoNode.depth
                                }
                            });
                        }
                    }
                }

                return filter;
            }

            case 'delay': {
                const delayNode = this.engine.createDelay(params.time, params.feedback);

                // Connect time modulation (LFO)
                if (params.timeModulation && delayNode.delay) {
                    const lfoNode = this.createAudioNode(params.timeModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(delayNode.delay.delayTime);
                        }
                    }
                }

                // Connect feedback modulation (LFO)
                if (params.feedbackModulation && delayNode.feedbackGain) {
                    const lfoNode = this.createAudioNode(params.feedbackModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(delayNode.feedbackGain.gain);
                        }
                    }
                }

                return delayNode;
            }

            case 'reverb': {
                if (params.type === 'dattorro') {
                    // Use full Dattorro reverb with AudioWorklet
                    const dattorroParams = {
                        wet: params.amount,
                        dry: 1 - params.amount
                    };

                    // Map length parameter to decay (0-1 range)
                    if (params.length !== undefined) {
                        dattorroParams.decay = Math.min(params.length / 10, 1);
                    }

                    // Add extended parameters if provided
                    if (params.decay !== undefined) dattorroParams.decay = params.decay;
                    if (params.damping !== undefined) dattorroParams.damping = params.damping;
                    if (params.inputDiffusion1 !== undefined) dattorroParams.inputDiffusion1 = params.inputDiffusion1;
                    if (params.inputDiffusion2 !== undefined) dattorroParams.inputDiffusion2 = params.inputDiffusion2;
                    if (params.decayDiffusion1 !== undefined) dattorroParams.decayDiffusion1 = params.decayDiffusion1;
                    if (params.decayDiffusion2 !== undefined) dattorroParams.decayDiffusion2 = params.decayDiffusion2;
                    if (params.bandwidth !== undefined) dattorroParams.bandwidth = params.bandwidth;
                    if (params.preDelay !== undefined) dattorroParams.preDelay = params.preDelay;
                    if (params.excursionRate !== undefined) dattorroParams.excursionRate = params.excursionRate;
                    if (params.excursionDepth !== undefined) dattorroParams.excursionDepth = params.excursionDepth;

                    const reverb = this.engine.createDattorroReverb(dattorroParams);

                    // Connect wet/dry mix modulation (LFO)
                    if (params.amountModulation && reverb.wet) {
                        const lfoNode = this.createAudioNode(params.amountModulation);
                        if (lfoNode) {
                            const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                            if (output && output.connect) {
                                output.connect(reverb.wet);
                            }
                        }
                    }

                    // Connect decay modulation (LFO)
                    if (params.decayModulation && reverb.decay) {
                        const lfoNode = this.createAudioNode(params.decayModulation);
                        if (lfoNode) {
                            const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                            if (output && output.connect) {
                                output.connect(reverb.decay);
                            }
                        }
                    }

                    // Connect damping modulation (LFO)
                    if (params.dampingModulation && reverb.damping) {
                        const lfoNode = this.createAudioNode(params.dampingModulation);
                        if (lfoNode) {
                            const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                            if (output && output.connect) {
                                output.connect(reverb.damping);
                            }
                        }
                    }

                    return reverb;
                } else {
                    // Use convolution reverb
                    const convolver = this.engine.createConvolver(params.length, params.type);
                    const wetGain = this.engine.createGain(params.amount);
                    const dryGain = this.engine.createGain(1 - params.amount);

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

            case 'gain': {
                const gainNode = this.engine.createGain(params.value);

                // Connect value modulation (LFO) for tremolo effect
                if (params.valueModulation && gainNode.gain) {
                    const lfoNode = this.createAudioNode(params.valueModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(gainNode.gain);
                        }
                    }
                }

                // Connect tag-based modulation
                if (params.tagModulation && params.tagModulation.audioNode && gainNode.gain) {
                    const tagNode = params.tagModulation.audioNode;
                    const output = tagNode.output ? tagNode.output : (tagNode.connect ? tagNode : null);
                    if (output && output.connect) {
                        output.connect(gainNode.gain);
                        debugLog(`[TAG MOD] Connected @${params.tagModulation.tagName} to gain`);
                    }
                }

                return gainNode;
            }

            case 'pan': {
                const panNode = this.engine.createPanner(params.position);

                // Connect position modulation (LFO)
                if (params.positionModulation && panNode.pan) {
                    const lfoNode = this.createAudioNode(params.positionModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(panNode.pan);
                        }
                    }
                }

                return panNode;
            }

            case 'width':
            case 'stereo': {
                const stereo = this.engine.createStereoWidth(params.width, params.detune);

                // Connect width modulation (LFO)
                if (params.widthModulation && stereo.width) {
                    const lfoNode = this.createAudioNode(params.widthModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(stereo.width);
                        }
                    }
                }

                return stereo;
            }

            case 'pingpong': {
                const pingpong = this.engine.createPingPongDelay(params.time, params.feedback);

                // Connect time modulation (LFO) to both L and R delay times
                if (params.timeModulation && pingpong.delayTimeL && pingpong.delayTimeR) {
                    const lfoNode = this.createAudioNode(params.timeModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(pingpong.delayTimeL);
                            output.connect(pingpong.delayTimeR);
                        }
                    }
                }

                // Connect feedback modulation (LFO) to both L and R feedback gains
                if (params.feedbackModulation && pingpong.feedbackL && pingpong.feedbackR) {
                    const lfoNode = this.createAudioNode(params.feedbackModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(pingpong.feedbackL);
                            output.connect(pingpong.feedbackR);
                        }
                    }
                }

                return pingpong;
            }

            case 'chorus': {
                const chorus = this.engine.createChorus(params.rate, params.depth, params.mix);

                // Connect rate modulation (LFO) to all internal LFO frequencies
                if (params.rateModulation && chorus.lfos && chorus.lfos.length > 0) {
                    const lfoNode = this.createAudioNode(params.rateModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            chorus.lfos.forEach(lfo => output.connect(lfo.frequency));
                        }
                    }
                }

                // Connect depth modulation (LFO) to all LFO gain nodes
                if (params.depthModulation && chorus.lfoGains && chorus.lfoGains.length > 0) {
                    const lfoNode = this.createAudioNode(params.depthModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            chorus.lfoGains.forEach(gain => output.connect(gain.gain));
                        }
                    }
                }

                // Connect mix modulation (LFO)
                if (params.mixModulation && chorus.mix) {
                    const lfoNode = this.createAudioNode(params.mixModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(chorus.mix);
                        }
                    }
                }

                return chorus;
            }

            case 'phaser': {
                const phaser = this.engine.createPhaser(params.rate, params.depth, params.stages);

                // Connect rate modulation (LFO) to internal LFO frequency
                if (params.rateModulation && phaser.lfo) {
                    const lfoNode = this.createAudioNode(params.rateModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(phaser.lfo.frequency);
                        }
                    }
                }

                // Connect depth modulation (LFO) to all LFO gain nodes
                if (params.depthModulation && phaser.lfoGains && phaser.lfoGains.length > 0) {
                    const lfoNode = this.createAudioNode(params.depthModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            phaser.lfoGains.forEach(gain => output.connect(gain.gain));
                        }
                    }
                }

                return phaser;
            }

            case 'distortion':
            case 'dist': {
                const distortion = this.engine.createDistortion(params.amount, params.mix);

                // Connect mix modulation (LFO) to wetGain
                if (params.mixModulation && distortion.wetGain) {
                    const lfoNode = this.createAudioNode(params.mixModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(distortion.wetGain.gain);
                        }
                    }
                }

                return distortion.input;
            }

            case 'bitcrush':
            case 'crush':
                return this.engine.createBitcrusher(params.bits, params.sampleRate);

            case 'granular':
                return this.engine.createGranular(params.grainSize, params.density, params.spread, params.pitch);

            case 'stutter':
                return this.engine.createStutter(params.rate, params.length);

            case 'freeze':
                return this.engine.createFreeze(params.fadeTime);

            case 'gate':
                return this.engine.createGate(params.rate, params.pattern);

            case 'downsample':
                return this.engine.createDownsample(params.factor);

            case 'glitch':
                return this.engine.createGlitch(params.intensity, params.rate);

            case 'lfo': {
                // Create a cache key based on LFO parameters
                const cacheKey = `lfo-${params.rate}-${params.type}-${params.depth}-${params.offset}`;

                // Check if we've already created this LFO
                if (this.lfoCache.has(cacheKey)) {
                    debugLog('[LFO CACHE] HIT:', cacheKey);
                    return this.lfoCache.get(cacheKey);
                }

                debugLog('[LFO CACHE] MISS, creating new LFO:', cacheKey, 'params:', params);
                // Create new LFO and cache it
                const lfo = this.engine.createLFO(params.rate, params.type, params.depth, params.offset);

                // Store min/max on the LFO node for real-time updates
                if (params.min !== undefined) lfo.min = params.min;
                if (params.max !== undefined) lfo.max = params.max;

                this.lfoCache.set(cacheKey, lfo);
                return lfo;
            }

            case 'tremolo':
                return this.engine.createTremolo(params.rate, params.depth);

            case 'vibrato':
                return this.engine.createVibrato(params.rate, params.depth);

            case 'autowah':
            case 'wah':
                return this.engine.createAutoWah(params.rate, params.depth, params.center);

            case 'autopan':
                return this.engine.createAutoPan(params.rate, params.depth);

            case 'ringmod': {
                const ringmod = this.engine.createRingMod(params.freq);

                // Connect frequency modulation (LFO)
                if (params.freqModulation && ringmod.frequency) {
                    const lfoNode = this.createAudioNode(params.freqModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(ringmod.frequency);
                        }
                    }
                }

                return ringmod;
            }

            case 'flanger': {
                const flanger = this.engine.createFlanger(params.rate, params.depth, params.feedback);

                // Connect rate modulation (LFO) to internal LFO frequency
                if (params.rateModulation && flanger.lfo) {
                    const lfoNode = this.createAudioNode(params.rateModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(flanger.lfo.frequency);
                        }
                    }
                }

                // Connect depth modulation (LFO) to LFO gain
                if (params.depthModulation && flanger.lfoGain) {
                    const lfoNode = this.createAudioNode(params.depthModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(flanger.lfoGain.gain);
                        }
                    }
                }

                // Connect feedback modulation (LFO)
                if (params.feedbackModulation && flanger.feedback) {
                    const lfoNode = this.createAudioNode(params.feedbackModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(flanger.feedback);
                        }
                    }
                }

                return flanger;
            }

            // NEW EURORACK-STYLE MODULES
            case 'vca':
                return this.engine.createVCA(params.cv);

            case 'compressor':
            case 'comp': {
                const compressor = this.engine.createCompressor(params.threshold, params.ratio, params.attack, params.release);

                // Connect threshold modulation (LFO)
                if (params.thresholdModulation && compressor.threshold) {
                    const lfoNode = this.createAudioNode(params.thresholdModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(compressor.threshold);
                        }
                    }
                }

                // Connect ratio modulation (LFO)
                if (params.ratioModulation && compressor.ratio) {
                    const lfoNode = this.createAudioNode(params.ratioModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(compressor.ratio);
                        }
                    }
                }

                // Connect attack modulation (LFO)
                if (params.attackModulation && compressor.attack) {
                    const lfoNode = this.createAudioNode(params.attackModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(compressor.attack);
                        }
                    }
                }

                // Connect release modulation (LFO)
                if (params.releaseModulation && compressor.release) {
                    const lfoNode = this.createAudioNode(params.releaseModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(compressor.release);
                        }
                    }
                }

                return compressor;
            }

            case 'sidechain':
            case 'sc': {
                const sidechain = this.engine.createSidechain(params.sidechain, params.threshold, params.ratio, params.attack, params.release);

                // Connect threshold modulation (LFO)
                if (params.thresholdModulation && sidechain.threshold) {
                    const lfoNode = this.createAudioNode(params.thresholdModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(sidechain.threshold);
                        }
                    }
                }

                // Connect ratio modulation (LFO)
                if (params.ratioModulation && sidechain.ratio) {
                    const lfoNode = this.createAudioNode(params.ratioModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(sidechain.ratio);
                        }
                    }
                }

                // Connect attack modulation (LFO)
                if (params.attackModulation && sidechain.attack) {
                    const lfoNode = this.createAudioNode(params.attackModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(sidechain.attack);
                        }
                    }
                }

                // Connect release modulation (LFO)
                if (params.releaseModulation && sidechain.release) {
                    const lfoNode = this.createAudioNode(params.releaseModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(sidechain.release);
                        }
                    }
                }

                return sidechain;
            }

            case 'crossfade':
            case 'xfade': {
                // If no signal B, just create a simple gain node (passthrough)
                if (!params.b) {
                    const gain = this.engine.context.createGain();
                    gain.gain.value = 1.0;
                    return gain;
                }
                const xfade = this.engine.createCrossfade(params.b, params.position);

                // Connect position modulation (LFO)
                if (params.positionModulation && xfade.position) {
                    const lfoNode = this.createAudioNode(params.positionModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(xfade.position);
                        }
                    }
                }

                // Return inputA as the main input (signal will flow through inputA -> output)
                return xfade.inputA;
            }

            case 'sh':
            case 'samplehold':
                return this.engine.createSampleHold(params.rate);

            case 'sync':
                return this.engine.createSync(params.modulator);

            case 'fold':
            case 'wavefold':
                return this.engine.createWavefolder(params.threshold);

            case 'euclidean': {
                const eucl = this.engine.createEuclidean(params.length, params.pulses, params.rotation);
                // Don't call start() here - it's already started in createEuclidean or will be started when needed
                return eucl;
            }

            case 'pitchshift':
            case 'pitch':
                return this.engine.createPitchShift(params.semitones);

            case 'porta':
            case 'portamento':
            case 'glide': {
                const portamento = this.engine.createPortamento(params.time);

                // Connect LFO modulation to glide time parameter
                if (params.timeModulation && portamento._glideTimeParam) {
                    const lfoNode = this.createAudioNode(params.timeModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(portamento._glideTimeParam.offset);
                        }
                    }
                }

                return portamento;
            }

            case 'limiter': {
                // Limiter returns compound node with input/output and exposed AudioParams
                const limiter = this.engine.createLimiter(params.threshold, params.attack, params.release);

                // Connect threshold modulation (LFO)
                if (params.thresholdModulation && limiter.limiter && limiter.limiter.threshold) {
                    const lfoNode = this.createAudioNode(params.thresholdModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(limiter.limiter.threshold);
                        }
                    }
                }

                // Connect attack modulation (LFO)
                if (params.attackModulation && limiter.limiter && limiter.limiter.attack) {
                    const lfoNode = this.createAudioNode(params.attackModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(limiter.limiter.attack);
                        }
                    }
                }

                // Connect release modulation (LFO)
                if (params.releaseModulation && limiter.limiter && limiter.limiter.release) {
                    const lfoNode = this.createAudioNode(params.releaseModulation);
                    if (lfoNode) {
                        const output = lfoNode.output ? lfoNode.output : (lfoNode.connect ? lfoNode : null);
                        if (output && output.connect) {
                            output.connect(limiter.limiter.release);
                        }
                    }
                }

                return limiter;
            }

            case 'random': {
                const randomizer = this.engine.createRandom(params.type, params.min, params.max, params.rate);
                randomizer.start();
                return randomizer;
            }

            case 'out':
                // out() = master out, out(mixer, ch) = mixer channel out
                debugLog('[PARSER] Creating out node, params:', params);
                if (params.mixer) {
                    // Route to mixer channel(s)
                    debugLog('[PARSER] Detected mixer out - mixer:', params.mixer, 'channels:', params.channels);
                    const output = this.engine.createGain(1.0);
                    output.isMixerOut = true;
                    output.mixerName = params.mixer;
                    output.mixerChannels = params.channels;
                    return output;
                } else {
                    // Regular master out - return a pass-through gain node
                    debugLog('[PARSER] Creating regular master out');
                    return this.engine.createGain(1.0);
                }

            case 'in':
                // Get input from mixer channel(s)
                if (params.mixer && params.channels) {
                    const mixerInput = this.engine.getMixerInput(params.mixer, params.channels);
                    // Tag it so we know it's a mixer input (source)
                    mixerInput.isMixerInput = true;
                    return mixerInput;
                }
                return null;

            case 'grains': {
                // Granular sampler - async, starts immediately
                debugLog('[DEBUG parser createAudioNode grains] Received params:', params);

                // Check if we have an existing grains node with the same source expression that we can update
                let output = null;
                let source = params.url; // Default to URL
                let shouldUpdateExisting = false;

                // Get line number for tracking (if available)
                const lineNumber = module.lineNumber;

                // Initialize grains tracking map if not exists
                if (!this.grainsOutputsByLine) {
                    this.grainsOutputsByLine = new Map();
                }

                // Look for existing grains output node from previous parse for this line
                const existingGrains = lineNumber !== undefined ? this.grainsOutputsByLine.get(lineNumber) : null;
                if (existingGrains && params.sourceExpression) {
                    const lastParams = existingGrains._grainsParams;

                    // Match by source expression to ensure we're updating the same configuration
                    if (lastParams && lastParams.sourceExpression === params.sourceExpression) {
                        // Same source expression - check if we can just update parameters
                        const sourceExpr = params.sourceExpression;
                        const match = sourceExpr.match(/(\w+)\((.*)\)/);
                        if (match) {
                            const [, moduleName, paramsStr] = match;
                            const argValues = paramsStr.split(',').map(s => {
                                const trimmed = s.trim();
                                return isNaN(trimmed) ? trimmed.replace(/['"]/g, '') : parseFloat(trimmed);
                            });

                            if (moduleName === 'osc' && existingGrains._sourceOscillator) {
                                // Can update the existing oscillator's frequency!
                                const newFreq = argValues[0] || 440;
                                const newType = argValues[1] || 'sine';

                                if (existingGrains._sourceOscillator.type === newType) {
                                    // Same waveform, just update frequency
                                    const osc = existingGrains._sourceOscillator;
                                    const now = this.engine.context.currentTime;
                                    osc.frequency.cancelScheduledValues(now);
                                    osc.frequency.setValueAtTime(osc.frequency.value, now);
                                    // Use longer ramp time to avoid clicks
                                    osc.frequency.exponentialRampToValueAtTime(Math.max(0.01, newFreq), now + 0.2);
                                    debugLog('[DEBUG parser grains] Updated existing oscillator frequency to', newFreq);

                                    // Reuse the output node
                                    output = existingGrains;
                                    source = osc;
                                    shouldUpdateExisting = true;

                                    // Update stored params
                                    output._grainsParams = { ...params };
                                }
                            }
                        }
                    }
                }

                if (!output) {
                    output = this.engine.createGain();
                    output.gain.value = 1;
                }

                // Check if we have a source expression (like osc(440) or @tag)
                if (!shouldUpdateExisting && params.sourceExpression) {
                    debugLog('[DEBUG parser grains] Has sourceExpression:', params.sourceExpression);
                    const sourceExpr = params.sourceExpression;

                    if (sourceExpr.startsWith('@')) {
                        // Tag reference - get the output node from the tag
                        const tagName = sourceExpr.substring(1).split('.')[0];
                        const taggedModule = this.taggedModules.get(tagName);
                        if (taggedModule && taggedModule.output) {
                            source = taggedModule.output;
                            debugLog('[DEBUG parser grains] Using tagged module as source:', tagName);
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
                                    debugLog('[DEBUG parser grains] Created oscillator for grains:', freq, type);
                                } else if (moduleName === 'noise') {
                                    const type = argValues[0] || 'white';
                                    source = this.engine.createNoise(type);
                                    debugLog('[DEBUG parser grains] Created noise for grains:', type);
                                } else if (moduleName === 'fm') {
                                    const carrier = argValues[0] || 440;
                                    const modulator = argValues[1] || 220;
                                    const depth = argValues[2] || 1.0;
                                    const fm = this.engine.createFM(carrier, modulator, depth);
                                    fm.start(); // Start FM oscillators
                                    source = fm;
                                    debugLog('[DEBUG parser grains] Created FM for grains:', carrier, modulator, depth);
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

                debugLog('[DEBUG parser grains] Final source before createGranularSampler:', source);

                // Store source oscillator, params, and line number for future updates
                if (source && source.frequency) {
                    // It's an oscillator
                    output._sourceOscillator = source;
                }
                output._grainsParams = { ...params };
                output._lineNumber = lineNumber;

                // Create granular sampler (async) - only if not updating existing
                if (!shouldUpdateExisting) {
                    this.engine.createGranularSampler(
                        source,
                        params.grainSize,
                        params.density,
                        params.position,
                        params.spread,
                        params.pitch,
                        params.bufferRefreshRate
                    ).then(grains => {
                        if (grains) {
                            debugLog('Parser: Granular sampler loaded, connecting grains.output to parser output node');
                            grains.output.connect(output);
                            // Store grains object for real-time parameter access
                            output._grainsObject = grains;
                            // Track this granular sampler so it can be stopped
                            this.sequencer.activeGranularSamplers.push(grains);
                        }
                    });
                }

                // Store this grains output for future updates (by line number)
                if (lineNumber !== undefined) {
                    this.grainsOutputsByLine.set(lineNumber, output);
                }

                return output;
            }

            case 'sampler': {
                // Multi-sample instrument - async, returns sampler interface
                // This is NOT an audio node, but a controller object with playNote()
                // It should be handled by the sequencer
                debugLog('Parser: Creating multi-sampler with sampleMap:', params.sampleMap);

                // Return a placeholder that will be resolved by sequencer
                return {
                    isMultiSampler: true,
                    samplerPromise: this.engine.createMultiSampler(params.sampleMap)
                };
            }

            case 'seq':
            case 'tracker':
                // Sequencers are not audio nodes, they should not be processed here
                return null;

            default:
                console.warn(`Unknown module type: ${type}`);
                return null;
        }
    }

    connectLFOToModule(lfo, targetNode, moduleType) {
        // Connect LFO output to the appropriate AudioParam of the target module
        let targetParam = null;

        switch (moduleType) {
            case 'lpf':
            case 'hpf':
            case 'bpf':
            case 'filter':
                // Modulate filter frequency
                targetParam = targetNode.frequency;
                break;

            case 'gain':
                // Modulate gain (tremolo effect)
                targetParam = targetNode.gain;
                break;

            case 'pan':
                // Modulate pan (auto-pan effect)
                targetParam = targetNode.pan;
                break;

            case 'delay':
                // Modulate delay time
                if (targetNode.delay) {
                    targetParam = targetNode.delay.delayTime;
                }
                break;

            case 'osc':
                // Modulate oscillator frequency (vibrato effect)
                targetParam = targetNode.frequency;
                break;

            default:
                console.warn(`LFO modulation not implemented for module type: ${moduleType}`);
                return;
        }

        if (targetParam) {
            // Handle LFO output (could be lfo.output or just lfo if it's a direct AudioNode)
            const output = lfo.output ? lfo.output : (lfo.connect ? lfo : null);
            if (output && output.connect) {
                output.connect(targetParam);
            }
        }
    }

    parseTrackerPattern(patternText, channels, maxLength = 64) {
        // Parse tracker pattern like:
        // Single channel:
        //   C-4 01 ...
        //   E-4 01 ...
        // Multi-channel (tab-separated):
        //   C-4 01 ...    E-4 01 ...    G-4 01 ...    C-5 01 ...
        //   --- -- ...    --- -- ...    --- -- ...    --- -- ...
        //
        // maxLength: maximum pattern length (defaults to 64 rows)
        // Pattern will repeat if shorter, truncate if longer
        //
        // Returns: { pattern: [...], positions: [...] }

        const lines = patternText.split('\n').map(l => l.trim()).filter(l => l);
        const pattern = [];
        const positions = [];

        // Get the starting line number from currentLineInfo
        const baseLineNumber = this.currentLineInfo ? this.currentLineInfo.lineNumber : 0;

        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            // Split by whitespace
            const parts = line.split(/\s+/);

            // For multi-channel, group parts into channels (3 tokens per channel)
            const channelData = [];
            const channelPositions = [];
            let charPos = 0;

            for (let ch = 0; ch < channels; ch++) {
                const offset = ch * 3;
                if (offset < parts.length) {
                    const noteToken = parts[offset] || '---';
                    const instToken = parts[offset + 1] || '--';
                    const effectToken = parts[offset + 2] || '...';

                    // Parse note (C-4 → C4, --- → rest)
                    let note = noteToken;
                    if (note !== '---' && note !== '..') {
                        note = note.replace('-', '');  // C-4 → C4
                    } else {
                        note = '..';  // rest
                    }

                    // Parse instrument number
                    let instrument = null;
                    if (instToken !== '--') {
                        instrument = parseInt(instToken, 10);
                    }

                    channelData.push({
                        note,
                        instrument,
                        effect: effectToken
                    });

                    // Track position of this channel's note within the line
                    const channelText = `${noteToken} ${instToken} ${effectToken}`;
                    const startPos = line.indexOf(channelText, charPos);
                    if (startPos !== -1) {
                        channelPositions.push({
                            start: startPos,
                            end: startPos + channelText.length
                        });
                        charPos = startPos + channelText.length;
                    } else {
                        channelPositions.push({ start: 0, end: 0 });
                    }
                } else {
                    // No data for this channel on this row
                    channelData.push({
                        note: '..',
                        instrument: null,
                        effect: '...'
                    });
                    channelPositions.push({ start: 0, end: 0 });
                }
            }

            pattern.push(channelData);

            // Store position info for this pattern row
            positions.push({
                lineNumber: baseLineNumber + 1 + i,
                channels: channelPositions,
                lineStart: 0,
                lineEnd: line.length
            });
        }

        // Adjust pattern length to match maxLength
        if (pattern.length < maxLength) {
            // Pattern is shorter than maxLength - pad with empty rows
            const emptyRow = [];
            for (let ch = 0; ch < channels; ch++) {
                emptyRow.push({
                    note: '..',
                    instrument: null,
                    effect: '...'
                });
            }

            while (pattern.length < maxLength) {
                pattern.push([...emptyRow]);

                // Add empty position info
                positions.push({
                    lineNumber: baseLineNumber + 1 + pattern.length - 1,
                    channels: emptyRow.map(() => ({ start: 0, end: 0 })),
                    lineStart: 0,
                    lineEnd: 0
                });
            }
        } else if (pattern.length > maxLength) {
            // Pattern is longer than maxLength - truncate it
            pattern.length = maxLength;
            positions.length = maxLength;
        }

        return { pattern, positions };
    }
}
