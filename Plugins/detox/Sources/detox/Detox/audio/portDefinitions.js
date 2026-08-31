/**
 * Port Definitions for Modular Routing System
 *
 * Defines inputs and outputs for each module type.
 * Each port has a type (audio, cv, midi, trigger, param) and description.
 */

export const SIGNAL_TYPES = {
  AUDIO: 'audio',
  CV: 'cv',
  MIDI: 'midi',
  TRIGGER: 'trigger',
  PARAM: 'param'
};

export const MODULE_PORTS = {
  // === SOURCES ===
  osc: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Frequency in Hz' },
      waveform: { type: SIGNAL_TYPES.PARAM, description: 'Waveform type (sine, square, saw, triangle)' },
      phase: { type: SIGNAL_TYPES.CV, description: 'Current phase (0-1)' }
    }
  },

  noise: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Noise output' },
      type: { type: SIGNAL_TYPES.PARAM, description: 'Noise type (white, pink, brown)' }
    }
  },

  sample: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Sample playback output' },
      speed: { type: SIGNAL_TYPES.PARAM, description: 'Playback speed' },
      position: { type: SIGNAL_TYPES.CV, description: 'Current playback position (0-1)' }
    }
  },

  loop: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Looped sample output' },
      speed: { type: SIGNAL_TYPES.PARAM, description: 'Playback speed' },
      position: { type: SIGNAL_TYPES.CV, description: 'Current loop position (0-1)' }
    }
  },

  grain: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Granular synthesis output' },
      grainSize: { type: SIGNAL_TYPES.PARAM, description: 'Grain size in ms' },
      density: { type: SIGNAL_TYPES.PARAM, description: 'Grain density' }
    }
  },

  fm: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'FM synthesis output' },
      carrier: { type: SIGNAL_TYPES.PARAM, description: 'Carrier frequency' },
      modulator: { type: SIGNAL_TYPES.PARAM, description: 'Modulator frequency' },
      index: { type: SIGNAL_TYPES.PARAM, description: 'Modulation index' }
    }
  },

  am: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'AM synthesis output' },
      carrier: { type: SIGNAL_TYPES.PARAM, description: 'Carrier frequency' },
      modulator: { type: SIGNAL_TYPES.PARAM, description: 'Modulator frequency' }
    }
  },

  pwm: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'PWM output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Frequency in Hz' },
      pulseWidth: { type: SIGNAL_TYPES.CV, description: 'Pulse width (0-1)' }
    }
  },

  supersaw: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Supersaw output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Base frequency' },
      detune: { type: SIGNAL_TYPES.PARAM, description: 'Detune amount' },
      voices: { type: SIGNAL_TYPES.PARAM, description: 'Number of voices' }
    }
  },

  wavetable: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Wavetable output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Frequency in Hz' },
      position: { type: SIGNAL_TYPES.CV, description: 'Wavetable position (0-1)' }
    }
  },

  pluck: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Plucked string output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Fundamental frequency' },
      decay: { type: SIGNAL_TYPES.PARAM, description: 'Decay time' }
    }
  },

  bow: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Bowed string output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Fundamental frequency' },
      pressure: { type: SIGNAL_TYPES.PARAM, description: 'Bow pressure' }
    }
  },

  blow: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Blown pipe output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Fundamental frequency' },
      pressure: { type: SIGNAL_TYPES.PARAM, description: 'Blow pressure' }
    }
  },

  strike: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Struck membrane output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Fundamental frequency' },
      decay: { type: SIGNAL_TYPES.PARAM, description: 'Decay time' }
    }
  },

  click: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Click output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Click frequency' }
    }
  },

  impulse: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Impulse output' },
      trigger: { type: SIGNAL_TYPES.TRIGGER, description: 'Trigger signal' }
    }
  },

  const: {
    outputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Constant value output' },
      value: { type: SIGNAL_TYPES.PARAM, description: 'Constant value' }
    }
  },

  sub: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Sub-oscillator output' },
      freq: { type: SIGNAL_TYPES.PARAM, description: 'Frequency (1 or 2 octaves down)' }
    }
  },

  // === FILTERS ===
  lpf: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Filtered audio output' },
      frequency: { type: SIGNAL_TYPES.PARAM, description: 'Cutoff frequency in Hz' },
      Q: { type: SIGNAL_TYPES.PARAM, description: 'Filter resonance' }
    }
  },

  hpf: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Filtered audio output' },
      frequency: { type: SIGNAL_TYPES.PARAM, description: 'Cutoff frequency in Hz' },
      Q: { type: SIGNAL_TYPES.PARAM, description: 'Filter resonance' }
    }
  },

  bpf: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Filtered audio output' },
      frequency: { type: SIGNAL_TYPES.PARAM, description: 'Center frequency in Hz' },
      Q: { type: SIGNAL_TYPES.PARAM, description: 'Filter bandwidth' }
    }
  },

  // === MODULATORS ===
  lfo: {
    outputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'LFO output signal' },
      rate: { type: SIGNAL_TYPES.PARAM, description: 'LFO rate in Hz' },
      waveform: { type: SIGNAL_TYPES.PARAM, description: 'Waveform type' },
      min: { type: SIGNAL_TYPES.PARAM, description: 'Minimum value' },
      max: { type: SIGNAL_TYPES.PARAM, description: 'Maximum value' },
      phase: { type: SIGNAL_TYPES.CV, description: 'Current phase (0-1)' }
    }
  },

  env: {
    inputs: {
      gate: { type: SIGNAL_TYPES.TRIGGER, description: 'Gate trigger input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Envelope output (0-1)' },
      attack: { type: SIGNAL_TYPES.PARAM, description: 'Attack time in seconds' },
      release: { type: SIGNAL_TYPES.PARAM, description: 'Release time in seconds' },
      gate: { type: SIGNAL_TYPES.TRIGGER, description: 'Current gate state' }
    }
  },

  random: {
    outputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Random output' },
      min: { type: SIGNAL_TYPES.PARAM, description: 'Minimum value' },
      max: { type: SIGNAL_TYPES.PARAM, description: 'Maximum value' },
      rate: { type: SIGNAL_TYPES.PARAM, description: 'Update rate in Hz' }
    }
  },

  sh: {
    inputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Input signal to sample' },
      trigger: { type: SIGNAL_TYPES.TRIGGER, description: 'Sample trigger' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Sampled output' }
    }
  },

  slew: {
    inputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Input signal' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Slewed output' },
      rise: { type: SIGNAL_TYPES.PARAM, description: 'Rise time in seconds' },
      fall: { type: SIGNAL_TYPES.PARAM, description: 'Fall time in seconds' }
    }
  },

  // === SEQUENCERS ===
  seq: {
    outputs: {
      note: { type: SIGNAL_TYPES.MIDI, description: 'Current note value' },
      velocity: { type: SIGNAL_TYPES.MIDI, description: 'Note velocity (0-127)' },
      gate: { type: SIGNAL_TYPES.TRIGGER, description: 'Gate on/off signal' },
      step: { type: SIGNAL_TYPES.PARAM, description: 'Current step number' },
      bpm: { type: SIGNAL_TYPES.PARAM, description: 'Tempo in BPM' }
    }
  },

  euclidean: {
    outputs: {
      trigger: { type: SIGNAL_TYPES.TRIGGER, description: 'Euclidean trigger output' },
      step: { type: SIGNAL_TYPES.PARAM, description: 'Current step' },
      pulses: { type: SIGNAL_TYPES.PARAM, description: 'Number of pulses' },
      steps: { type: SIGNAL_TYPES.PARAM, description: 'Total steps' }
    }
  },

  tracker: {
    outputs: {
      note: { type: SIGNAL_TYPES.MIDI, description: 'Current note' },
      gate: { type: SIGNAL_TYPES.TRIGGER, description: 'Gate signal' },
      pattern: { type: SIGNAL_TYPES.PARAM, description: 'Current pattern row' }
    }
  },

  quantize: {
    inputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Input signal to quantize' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Quantized output' },
      scale: { type: SIGNAL_TYPES.PARAM, description: 'Scale name' }
    }
  },

  // === EFFECTS ===
  reverb: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Reverb output' },
      mix: { type: SIGNAL_TYPES.PARAM, description: 'Dry/wet mix (0-1)' },
      decay: { type: SIGNAL_TYPES.PARAM, description: 'Decay time' }
    }
  },

  dattorro: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Dattorro reverb output' },
      preDelay: { type: SIGNAL_TYPES.PARAM, description: 'Pre-delay in ms' },
      decay: { type: SIGNAL_TYPES.PARAM, description: 'Decay factor' }
    }
  },

  delay: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Delayed audio output' },
      time: { type: SIGNAL_TYPES.PARAM, description: 'Delay time in seconds' },
      feedback: { type: SIGNAL_TYPES.PARAM, description: 'Feedback amount (0-1)' },
      mix: { type: SIGNAL_TYPES.PARAM, description: 'Dry/wet mix (0-1)' }
    }
  },

  pingpong: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Ping-pong delay output' },
      time: { type: SIGNAL_TYPES.PARAM, description: 'Delay time' },
      feedback: { type: SIGNAL_TYPES.PARAM, description: 'Feedback amount' }
    }
  },

  chorus: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Chorus output' },
      rate: { type: SIGNAL_TYPES.PARAM, description: 'LFO rate' },
      depth: { type: SIGNAL_TYPES.PARAM, description: 'Modulation depth' }
    }
  },

  flanger: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Flanger output' },
      rate: { type: SIGNAL_TYPES.PARAM, description: 'LFO rate' },
      depth: { type: SIGNAL_TYPES.PARAM, description: 'Modulation depth' },
      feedback: { type: SIGNAL_TYPES.PARAM, description: 'Feedback amount' }
    }
  },

  phaser: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Phaser output' },
      rate: { type: SIGNAL_TYPES.PARAM, description: 'LFO rate' },
      depth: { type: SIGNAL_TYPES.PARAM, description: 'Modulation depth' },
      stages: { type: SIGNAL_TYPES.PARAM, description: 'Number of stages' }
    }
  },

  tremolo: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Tremolo output' },
      rate: { type: SIGNAL_TYPES.PARAM, description: 'LFO rate' },
      depth: { type: SIGNAL_TYPES.PARAM, description: 'Modulation depth (0-1)' }
    }
  },

  vibrato: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Vibrato output' },
      rate: { type: SIGNAL_TYPES.PARAM, description: 'LFO rate' },
      depth: { type: SIGNAL_TYPES.PARAM, description: 'Pitch modulation depth' }
    }
  },

  autopan: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Auto-panned output' },
      rate: { type: SIGNAL_TYPES.PARAM, description: 'Pan rate' },
      depth: { type: SIGNAL_TYPES.PARAM, description: 'Pan depth' }
    }
  },

  autowah: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Auto-wah output' },
      sensitivity: { type: SIGNAL_TYPES.PARAM, description: 'Envelope sensitivity' },
      Q: { type: SIGNAL_TYPES.PARAM, description: 'Filter resonance' }
    }
  },

  ringmod: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Carrier signal' },
      modulator: { type: SIGNAL_TYPES.AUDIO, description: 'Modulator signal' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Ring modulated output' }
    }
  },

  // === DISTORTION ===
  distortion: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Distorted output' },
      amount: { type: SIGNAL_TYPES.PARAM, description: 'Distortion amount' }
    }
  },

  bitcrush: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Bitcrushed output' },
      bits: { type: SIGNAL_TYPES.PARAM, description: 'Bit depth' },
      sampleRate: { type: SIGNAL_TYPES.PARAM, description: 'Sample rate reduction' }
    }
  },

  fold: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Wavefolded output' },
      amount: { type: SIGNAL_TYPES.PARAM, description: 'Fold amount' }
    }
  },

  compressor: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Compressed output' },
      threshold: { type: SIGNAL_TYPES.PARAM, description: 'Threshold in dB' },
      ratio: { type: SIGNAL_TYPES.PARAM, description: 'Compression ratio' },
      reduction: { type: SIGNAL_TYPES.CV, description: 'Current gain reduction' }
    }
  },

  limiter: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Limited output' },
      threshold: { type: SIGNAL_TYPES.PARAM, description: 'Limiter threshold' }
    }
  },

  sidechain: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio to be ducked' },
      trigger: { type: SIGNAL_TYPES.AUDIO, description: 'Sidechain trigger' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Ducked output' },
      amount: { type: SIGNAL_TYPES.PARAM, description: 'Duck amount' }
    }
  },

  sync: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Slave oscillator' },
      master: { type: SIGNAL_TYPES.AUDIO, description: 'Master oscillator' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Hard-synced output' }
    }
  },

  // === MIX & ROUTING ===
  gain: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Amplified output' },
      amount: { type: SIGNAL_TYPES.PARAM, description: 'Gain amount (0-1)' }
    }
  },

  pan: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Panned stereo output' },
      position: { type: SIGNAL_TYPES.PARAM, description: 'Pan position (-1 to 1)' }
    }
  },

  width: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Stereo input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Width-adjusted output' },
      amount: { type: SIGNAL_TYPES.PARAM, description: 'Stereo width (0-1)' }
    }
  },

  crossfade: {
    inputs: {
      signalA: { type: SIGNAL_TYPES.AUDIO, description: 'First audio signal' },
      signalB: { type: SIGNAL_TYPES.AUDIO, description: 'Second audio signal' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Crossfaded output' },
      mix: { type: SIGNAL_TYPES.PARAM, description: 'Crossfade position (0-1)' }
    }
  },

  vca: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' },
      control: { type: SIGNAL_TYPES.CV, description: 'Control voltage input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'VCA output' }
    }
  },

  in: {
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Mixed input from channels' },
      mixer: { type: SIGNAL_TYPES.PARAM, description: 'Mixer name' },
      channels: { type: SIGNAL_TYPES.PARAM, description: 'Channel numbers' }
    }
  },

  out: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio to output' }
    },
    outputs: {
      mixer: { type: SIGNAL_TYPES.PARAM, description: 'Mixer name (if specified)' },
      channel: { type: SIGNAL_TYPES.PARAM, description: 'Channel number (if specified)' }
    }
  },

  // === TRANSFORM ===
  pitchshift: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Pitch-shifted output' },
      shift: { type: SIGNAL_TYPES.PARAM, description: 'Pitch shift in semitones' }
    }
  },

  scale: {
    inputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Input value' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.CV, description: 'Scaled output' },
      inMin: { type: SIGNAL_TYPES.PARAM, description: 'Input minimum' },
      inMax: { type: SIGNAL_TYPES.PARAM, description: 'Input maximum' },
      outMin: { type: SIGNAL_TYPES.PARAM, description: 'Output minimum' },
      outMax: { type: SIGNAL_TYPES.PARAM, description: 'Output maximum' }
    }
  },

  voices: {
    inputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Audio input' }
    },
    outputs: {
      signal: { type: SIGNAL_TYPES.AUDIO, description: 'Polyphonic output' },
      count: { type: SIGNAL_TYPES.PARAM, description: 'Number of voices' }
    }
  }
};

/**
 * Get port definitions for a module type
 * @param {string} moduleName - Name of the module (e.g., 'osc', 'lpf')
 * @returns {object|null} Port definitions or null if not found
 */
export function getModulePorts(moduleName) {
  return MODULE_PORTS[moduleName] || null;
}

/**
 * Get all output port names for a module
 * @param {string} moduleName - Name of the module
 * @returns {string[]} Array of output port names
 */
export function getModuleOutputs(moduleName) {
  const ports = MODULE_PORTS[moduleName];
  return ports?.outputs ? Object.keys(ports.outputs) : [];
}

/**
 * Get all input port names for a module
 * @param {string} moduleName - Name of the module
 * @returns {string[]} Array of input port names
 */
export function getModuleInputs(moduleName) {
  const ports = MODULE_PORTS[moduleName];
  return ports?.inputs ? Object.keys(ports.inputs) : [];
}

/**
 * Get a specific port definition
 * @param {string} moduleName - Name of the module
 * @param {string} portName - Name of the port
 * @param {string} direction - 'input' or 'output'
 * @returns {object|null} Port definition or null
 */
export function getPortDefinition(moduleName, portName, direction = 'output') {
  const ports = MODULE_PORTS[moduleName];
  if (!ports) return null;

  const portMap = direction === 'input' ? ports.inputs : ports.outputs;
  return portMap?.[portName] || null;
}

/**
 * Check if a module has a specific output port
 * @param {string} moduleName - Name of the module
 * @param {string} portName - Name of the port
 * @returns {boolean}
 */
export function hasOutputPort(moduleName, portName) {
  return getPortDefinition(moduleName, portName, 'output') !== null;
}

/**
 * Check if a module has a specific input port
 * @param {string} moduleName - Name of the module
 * @param {string} portName - Name of the port
 * @returns {boolean}
 */
export function hasInputPort(moduleName, portName) {
  return getPortDefinition(moduleName, portName, 'input') !== null;
}
