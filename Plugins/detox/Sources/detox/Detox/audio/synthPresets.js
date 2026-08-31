/**
 * Synth Presets - Classic Synthesizer Sound Configurations
 * Organized by synth -> preset hierarchy
 * Syntax: preset(synth, preset-name)
 */

export const SYNTH_PRESETS = {
  // ===================
  // FM SYNTHS
  // ===================

  'dx7': {
    'epiano-1': {
      name: 'E.Piano 1',
      description: 'Classic DX7 electric piano - most famous preset ever',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 0.5 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'epiano-2': {
      name: 'E.Piano 2',
      description: 'Brighter, harder electric piano',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 200, q: 0.5 } },
        { type: 'lpf', params: { freq: 3000, q: 0.7 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'lately-bass': {
      name: 'Lately Bass',
      description: 'Deep, warm FM bass',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 500, q: 1.5 } },
        { type: 'distortion', params: { amount: 15, mix: 0.3 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'tub-bells': {
      name: 'Tub Bells',
      description: 'Tubular bell sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 400, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'marimba': {
      name: 'Marimba',
      description: 'Wooden mallet percussion',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 0.8 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'solid-bass': {
      name: 'Solid Bass',
      description: 'Punchy FM bass',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 400, q: 2.0 } },
        { type: 'distortion', params: { amount: 20, mix: 0.4 } },
        { type: 'gain', params: { value: 0.95 } }
      ]
    },
    'brass-1': {
      name: 'Brass 1',
      description: 'Classic DX7 brass',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.0 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'flute-1': {
      name: 'Flute 1',
      description: 'Breathy FM flute',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 0.5 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    }
  },

  'tx81z': {
    'lately-bass': {
      name: 'Lately Bass (TX81Z)',
      description: 'The famous TX81Z bass',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 450, q: 1.8 } },
        { type: 'distortion', params: { amount: 18, mix: 0.35 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'calliope': {
      name: 'Calliope',
      description: 'Circus organ sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'rubber-bass': {
      name: 'Rubber Bass',
      description: 'Bouncy FM bass',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 600, q: 3.0 } },
        { type: 'distortion', params: { amount: 15, mix: 0.3 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'glass-pad': {
      name: 'Glass Pad',
      description: 'Shimmering pad texture',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 600, q: 0.5 } },
        { type: 'gain', params: { value: 0.65 } }
      ]
    },
    'syn-brass': {
      name: 'Syn Brass',
      description: 'Synthetic brass ensemble',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 1.2 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'fm-piano': {
      name: 'FM Piano',
      description: 'Percussive FM piano',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 3000, q: 0.6 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    }
  },

  'digitone': {
    'arctic': {
      name: 'Arctic',
      description: 'Cold, crystalline FM pad',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 800, q: 0.5 } },
        { type: 'gain', params: { value: 0.6 } }
      ]
    },
    'fm-bass': {
      name: 'FM Bass',
      description: 'Modern FM bassline',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 500, q: 2.5 } },
        { type: 'distortion', params: { amount: 20, mix: 0.4 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'glass-keys': {
      name: 'Glass Keys',
      description: 'Glassy keyboard sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 400, q: 0.5 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'bellish': {
      name: 'Bellish',
      description: 'Bell-like tones',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 600, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'drone-pad': {
      name: 'Drone Pad',
      description: 'Deep evolving pad',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 1000, q: 0.5 } },
        { type: 'gain', params: { value: 0.6 } }
      ]
    },
    'elastic-pluck': {
      name: 'Elastic Pluck',
      description: 'Bouncy plucked sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.5 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    }
  },

  // ===================
  // ANALOG/AM SYNTHS
  // ===================

  'minimoog': {
    'bass-1': {
      name: 'Bass 1',
      description: 'THE classic Moog bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 800, q: 2.5 } },
        { type: 'distortion', params: { amount: 10, mix: 0.2 } },
        { type: 'gain', params: { value: 0.95 } }
      ]
    },
    'lead-2': {
      name: 'Lead 2',
      description: 'Soaring mono lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 2.0 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'moog-brass': {
      name: 'Moog Brass',
      description: 'Fat analog brass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1600, q: 1.8 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'sync-lead': {
      name: 'Sync Lead',
      description: 'Oscillator sync lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2200, q: 1.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'fat-bass': {
      name: 'Fat Bass',
      description: 'Deep powerful bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 400, q: 2.0 } },
        { type: 'distortion', params: { amount: 15, mix: 0.3 } },
        { type: 'gain', params: { value: 0.95 } }
      ]
    },
    'space-drone': {
      name: 'Space Drone',
      description: 'Cosmic atmospheric drone',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1200, q: 0.5 } },
        { type: 'gain', params: { value: 0.65 } }
      ]
    },
    'sub-bass': {
      name: 'Sub Bass',
      description: 'Ultra-deep sub bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 300, q: 1.5 } },
        { type: 'gain', params: { value: 1.0 } }
      ]
    },
    'filter-sweep': {
      name: 'Filter Sweep',
      description: 'Classic resonant sweep',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 600, q: 4.0 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    }
  },

  'arp-2600': {
    'ring-lead': {
      name: 'Ring Lead',
      description: 'Ring modulated lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'ringmod', params: { freq: 200 } },
        { type: 'lpf', params: { freq: 2000, q: 2.0 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'noise-drone': {
      name: 'Noise Drone',
      description: 'Filtered noise pad',
      sourceTypes: ['noise', 'seq+noise'],
      chain: [
        { type: 'bpf', params: { freq: 1000, q: 4.0 } },
        { type: 'gain', params: { value: 0.6 } }
      ]
    },
    'laser-zaps': {
      name: 'Laser Zaps',
      description: 'Classic sci-fi sounds',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 3000, q: 5.0 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'brass-pad': {
      name: 'Brass Pad',
      description: 'Thick brass ensemble',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1400, q: 1.0 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'fx-sweep': {
      name: 'FX Sweep',
      description: 'Evolving FX sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 3.0 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'resonant-bass': {
      name: 'Resonant Bass',
      description: 'High-Q bass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 500, q: 6.0 } },
        { type: 'distortion', params: { amount: 15, mix: 0.3 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    }
  },

  'ms-20': {
    'ring-mod-bass': {
      name: 'Ring Mod Bass',
      description: 'Metallic ring mod bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'ringmod', params: { freq: 55 } },
        { type: 'lpf', params: { freq: 600, q: 4.0 } },
        { type: 'distortion', params: { amount: 25, mix: 0.4 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'noise-lead': {
      name: 'Noise Lead',
      description: 'Aggressive noise-based lead',
      sourceTypes: ['noise', 'seq+noise'],
      chain: [
        { type: 'bpf', params: { freq: 2000, q: 8.0 } },
        { type: 'distortion', params: { amount: 30, mix: 0.5 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'self-osc-drone': {
      name: 'Self-OSC Drone',
      description: 'Self-oscillating filter drone',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 800, q: 10.0 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'acid-bass': {
      name: 'Acid Bass',
      description: 'Squelchy 303-style bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 800, q: 8.0 } },
        { type: 'distortion', params: { amount: 20, mix: 0.4 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'scream-lead': {
      name: 'Scream Lead',
      description: 'Screaming resonant lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 6.0 } },
        { type: 'distortion', params: { amount: 25, mix: 0.4 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'mod-bell': {
      name: 'Mod Bell',
      description: 'Modulated bell sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'hpf', params: { freq: 600, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    }
  },

  // ===================
  // OSC POLY SYNTHS
  // ===================

  'prophet5': {
    'prophet-strings': {
      name: 'Prophet Strings',
      description: 'Lush analog string ensemble',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1200, q: 0.3 } },
        { type: 'gain', params: { value: 0.65 } }
      ]
    },
    'classic-brass': {
      name: 'Classic Brass',
      description: 'Sequential brass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.0 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'sync-lead': {
      name: 'Sync Lead',
      description: 'Oscillator sync lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 1.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'poly-keys': {
      name: 'Poly Keys',
      description: 'Bright polyphonic keys',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 0.8 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'bright-pad': {
      name: 'Bright Pad',
      description: 'Shimmering pad sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'warm-bass': {
      name: 'Warm Bass',
      description: 'Smooth analog bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 600, q: 1.5 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'seq-bass': {
      name: 'Seq Bass',
      description: 'Sequencer bass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 500, q: 2.5 } },
        { type: 'distortion', params: { amount: 10, mix: 0.2 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'fat-lead': {
      name: 'Fat Lead',
      description: 'Thick mono lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 2.0 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    }
  },

  'jupiter8': {
    'juno-pad': {
      name: 'Juno Pad',
      description: 'Warm Jupiter pad',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1200, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'sync-brass': {
      name: 'Sync Brass',
      description: 'Synced brass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 1.5 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'pwm-lead': {
      name: 'PWM Lead',
      description: 'Pulse width modulation lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2200, q: 1.8 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'soft-keys': {
      name: 'Soft Keys',
      description: 'Mellow keyboard sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1500, q: 0.5 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'lfo-sweep': {
      name: 'LFO Sweep',
      description: 'LFO modulated sweep',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1000, q: 3.0 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'poly-sweep': {
      name: 'Poly Sweep',
      description: 'Polyphonic filter sweep',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1500, q: 2.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    }
  },

  'juno106': {
    'chorus-pad': {
      name: 'Chorus Pad',
      description: 'Classic Juno chorus pad',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1200, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'warm-lead': {
      name: 'Warm Lead',
      description: 'Smooth Juno lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'poly-bass': {
      name: 'Poly Bass',
      description: 'Polyphonic bass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 500, q: 2.0 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'soft-strings': {
      name: 'Soft Strings',
      description: 'Gentle string sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1000, q: 0.3 } },
        { type: 'gain', params: { value: 0.65 } }
      ]
    },
    'analog-keys': {
      name: 'Analog Keys',
      description: 'Classic analog keyboard',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 0.8 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'vintage-brass': {
      name: 'Vintage Brass',
      description: '80s brass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1600, q: 1.0 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    }
  },

  'obxa': {
    'van-halen-brass': {
      name: 'Van Halen Brass',
      description: 'The Jump brass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.5 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'warm-pad': {
      name: 'Warm Pad',
      description: 'Lush OB pad',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 800, q: 0.5 } },
        { type: 'gain', params: { value: 0.6 } }
      ]
    },
    'chorus-strings': {
      name: 'Chorus Strings',
      description: 'Thick string ensemble',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1400, q: 0.3 } },
        { type: 'gain', params: { value: 0.65 } }
      ]
    },
    'bright-lead': {
      name: 'Bright Lead',
      description: 'Cutting OB lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 3000, q: 1.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'epic-poly': {
      name: 'Epic Poly',
      description: 'Big polyphonic sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.0 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'soft-lead': {
      name: 'Soft Lead',
      description: 'Mellow lead sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 1.2 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    }
  },

  // ===================
  // CLASSIC MONO SYNTHS
  // ===================

  'tb303': {
    'acid-bass': {
      name: 'Acid Bass',
      description: 'The legendary 303 acid sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 600, q: 8.0 } },
        { type: 'distortion', params: { amount: 15, mix: 0.3 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'squelch': {
      name: 'Squelch',
      description: 'High resonance squelchy bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 400, q: 10.0 } },
        { type: 'distortion', params: { amount: 20, mix: 0.4 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'deep-303': {
      name: 'Deep 303',
      description: 'Sub-heavy acid bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 300, q: 6.0 } },
        { type: 'distortion', params: { amount: 10, mix: 0.2 } },
        { type: 'gain', params: { value: 1.0 } }
      ]
    },
    'screamer': {
      name: 'Screamer',
      description: 'Aggressive high-Q lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1200, q: 12.0 } },
        { type: 'distortion', params: { amount: 25, mix: 0.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    }
  },

  'sh101': {
    'bass-line': {
      name: 'Bass Line',
      description: 'Classic SH-101 bassline',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 500, q: 2.5 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'sync-lead': {
      name: 'Sync Lead',
      description: 'Sync oscillator lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 2.0 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'reso-bass': {
      name: 'Reso Bass',
      description: 'Resonant bass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 400, q: 4.0 } },
        { type: 'distortion', params: { amount: 15, mix: 0.3 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'poly-mod': {
      name: 'Poly Mod',
      description: 'Poly mod lead sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 1.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    }
  },

  'odyssey': {
    'fat-bass': {
      name: 'Fat Bass',
      description: 'Thick Odyssey bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 600, q: 2.0 } },
        { type: 'distortion', params: { amount: 12, mix: 0.25 } },
        { type: 'gain', params: { value: 0.95 } }
      ]
    },
    'ring-lead': {
      name: 'Ring Lead',
      description: 'Ring modulated lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'ringmod', params: { freq: 100 } },
        { type: 'lpf', params: { freq: 1800, q: 2.0 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'sync-sweep': {
      name: 'Sync Sweep',
      description: 'Oscillator sync sweep',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 1.8 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'noise-bass': {
      name: 'Noise Bass',
      description: 'Bass with noise character',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 500, q: 3.0 } },
        { type: 'distortion', params: { amount: 20, mix: 0.4 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    }
  },

  // ===================
  // DIGITAL/PCM SYNTHS
  // ===================

  'm1': {
    'piano': {
      name: 'M1 Piano',
      description: 'Classic M1 piano sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 3000, q: 0.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'organ': {
      name: 'M1 Organ',
      description: 'M1 organ sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 0.8 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'universe': {
      name: 'Universe',
      description: 'Famous M1 pad',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1200, q: 0.3 } },
        { type: 'gain', params: { value: 0.6 } }
      ]
    },
    'lore': {
      name: 'Lore',
      description: 'Iconic M1 atmosphere',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'hpf', params: { freq: 400, q: 0.5 } },
        { type: 'gain', params: { value: 0.65 } }
      ]
    },
    'bass': {
      name: 'M1 Bass',
      description: 'M1 bass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 600, q: 1.5 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    }
  },

  'd50': {
    'fantasia': {
      name: 'Fantasia',
      description: 'Signature D-50 pad',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1500, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'digital-native': {
      name: 'Digital Native Dance',
      description: 'Classic D-50 dance pad',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 0.6 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'glass-voices': {
      name: 'Glass Voices',
      description: 'Ethereal vocal pad',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'hpf', params: { freq: 600, q: 0.5 } },
        { type: 'lpf', params: { freq: 2500, q: 0.5 } },
        { type: 'gain', params: { value: 0.65 } }
      ]
    },
    'staccato-heaven': {
      name: 'Staccato Heaven',
      description: 'Bright staccato sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'hpf', params: { freq: 500, q: 0.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    }
  },

  'jd800': {
    'vintage-lead': {
      name: 'Vintage Lead',
      description: 'Classic JD-800 lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2200, q: 1.5 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'super-saw': {
      name: 'Super Saw',
      description: 'JD-800 supersaw pad',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 0.8 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'hoover': {
      name: 'Hoover',
      description: 'Classic hoover sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1500, q: 2.0 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'rave-stab': {
      name: 'Rave Stab',
      description: '90s rave stab',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 1.5 } },
        { type: 'distortion', params: { amount: 10, mix: 0.2 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    }
  },

  // ===================
  // AM SYNTHESIS
  // ===================

  'am-classic': {
    'bell-tone': {
      name: 'Bell Tone',
      description: 'Metallic bell using AM',
      sourceTypes: ['am', 'seq+am'],
      chain: [
        { type: 'hpf', params: { freq: 600, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'gong': {
      name: 'Gong',
      description: 'Deep AM gong',
      sourceTypes: ['am', 'seq+am'],
      chain: [
        { type: 'lpf', params: { freq: 1500, q: 0.8 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'tremolo-pad': {
      name: 'Tremolo Pad',
      description: 'AM-based tremolo pad',
      sourceTypes: ['am', 'seq+am'],
      chain: [
        { type: 'lpf', params: { freq: 1200, q: 0.5 } },
        { type: 'gain', params: { value: 0.65 } }
      ]
    },
    'metallic-lead': {
      name: 'Metallic Lead',
      description: 'Bright metallic lead',
      sourceTypes: ['am', 'seq+am'],
      chain: [
        { type: 'hpf', params: { freq: 400, q: 0.5 } },
        { type: 'lpf', params: { freq: 2500, q: 1.0 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'shimmer': {
      name: 'Shimmer',
      description: 'Shimmering AM texture',
      sourceTypes: ['am', 'seq+am'],
      chain: [
        { type: 'hpf', params: { freq: 800, q: 0.5 } },
        { type: 'gain', params: { value: 0.6 } }
      ]
    },
    'radio': {
      name: 'Radio',
      description: 'AM radio-like sound',
      sourceTypes: ['am', 'seq+am'],
      chain: [
        { type: 'bpf', params: { freq: 1500, q: 2.0 } },
        { type: 'distortion', params: { amount: 20, mix: 0.3 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    }
  },

  // ===================
  // MORE FM SYNTHS
  // ===================

  'volca-fm': {
    'arp-bell': {
      name: 'Arp Bell',
      description: 'Arpeggiated bell tone',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 500, q: 0.5 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'dx-bass': {
      name: 'DX Bass',
      description: 'FM bass sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 600, q: 2.0 } },
        { type: 'distortion', params: { amount: 15, mix: 0.3 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'chord-organ': {
      name: 'Chord Organ',
      description: 'Organ-like chords',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 0.7 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'vibes': {
      name: 'Vibes',
      description: 'Vibraphone sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 300, q: 0.5 } },
        { type: 'lpf', params: { freq: 2500, q: 0.8 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    }
  },

  'op1': {
    'digi-keys': {
      name: 'Digi Keys',
      description: 'Digital keyboard sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 0.6 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'phase-lead': {
      name: 'Phase Lead',
      description: 'Phasing lead sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.5 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'cluster': {
      name: 'Cluster',
      description: 'Cluster FM texture',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 600, q: 0.5 } },
        { type: 'gain', params: { value: 0.65 } }
      ]
    },
    'fm-pluck': {
      name: 'FM Pluck',
      description: 'Plucky FM sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.0 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    }
  },

  'reface-dx': {
    'warm-ep': {
      name: 'Warm EP',
      description: 'Warm electric piano',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2200, q: 0.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'clav': {
      name: 'Clav',
      description: 'Clavinet-like sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 300, q: 0.5 } },
        { type: 'lpf', params: { freq: 3000, q: 1.5 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'chorus-ep': {
      name: 'Chorus EP',
      description: 'EP with chorus character',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 0.6 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'harm-bell': {
      name: 'Harmonic Bell',
      description: 'Harmonic bell sound',
      sourceTypes: ['fm', 'seq+fm'],
      chain: [
        { type: 'hpf', params: { freq: 600, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    }
  },

  // ===================
  // MORE ANALOG CLASSICS
  // ===================

  'sub37': {
    'sub-bass': {
      name: 'Sub Bass',
      description: 'Deep Moog sub bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 300, q: 1.5 } },
        { type: 'gain', params: { value: 1.0 } }
      ]
    },
    'multi-drive': {
      name: 'Multi Drive',
      description: 'Multi-filtered drive',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1500, q: 2.5 } },
        { type: 'distortion', params: { amount: 20, mix: 0.4 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'arp-lead': {
      name: 'Arp Lead',
      description: 'Arpeggiated lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2200, q: 1.8 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'unison-bass': {
      name: 'Unison Bass',
      description: 'Thick unison bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 500, q: 2.0 } },
        { type: 'distortion', params: { amount: 15, mix: 0.3 } },
        { type: 'gain', params: { value: 0.95 } }
      ]
    }
  },

  'prophet6': {
    'poly-brass': {
      name: 'Poly Brass',
      description: 'Polyphonic brass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 1.2 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'vintage-pad': {
      name: 'Vintage Pad',
      description: 'Classic analog pad',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1200, q: 0.5 } },
        { type: 'gain', params: { value: 0.7 } }
      ]
    },
    'saw-lead': {
      name: 'Saw Lead',
      description: 'Classic saw lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2500, q: 1.8 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'sync-keys': {
      name: 'Sync Keys',
      description: 'Synced keyboard sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    }
  },

  'matriarch': {
    'paraphonic-bass': {
      name: 'Paraphonic Bass',
      description: 'Paraphonic bass sound',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 500, q: 2.5 } },
        { type: 'distortion', params: { amount: 18, mix: 0.35 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'stereo-lead': {
      name: 'Stereo Lead',
      description: 'Wide stereo lead',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 2200, q: 2.0 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'drone-bass': {
      name: 'Drone Bass',
      description: 'Deep droning bass',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 400, q: 1.8 } },
        { type: 'gain', params: { value: 0.95 } }
      ]
    },
    'delay-lead': {
      name: 'Delay Lead',
      description: 'Lead with delay character',
      sourceTypes: ['osc', 'seq+osc'],
      chain: [
        { type: 'lpf', params: { freq: 1800, q: 1.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    }
  },

  // ===================
  // PLUCK SYNTHESIS
  // ===================

  'pluck-classic': {
    'acoustic-guitar': {
      name: 'Acoustic Guitar',
      description: 'Natural guitar pluck',
      sourceTypes: ['pluck', 'seq+pluck'],
      chain: [
        { type: 'lpf', params: { freq: 3000, q: 0.5 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    },
    'bass-guitar': {
      name: 'Bass Guitar',
      description: 'Plucked bass sound',
      sourceTypes: ['pluck', 'seq+pluck'],
      chain: [
        { type: 'lpf', params: { freq: 800, q: 0.8 } },
        { type: 'gain', params: { value: 0.9 } }
      ]
    },
    'sitar': {
      name: 'Sitar',
      description: 'Sitar-like pluck',
      sourceTypes: ['pluck', 'seq+pluck'],
      chain: [
        { type: 'hpf', params: { freq: 300, q: 0.5 } },
        { type: 'lpf', params: { freq: 2500, q: 1.5 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'harp': {
      name: 'Harp',
      description: 'Harp pluck',
      sourceTypes: ['pluck', 'seq+pluck'],
      chain: [
        { type: 'hpf', params: { freq: 200, q: 0.5 } },
        { type: 'gain', params: { value: 0.75 } }
      ]
    },
    'koto': {
      name: 'Koto',
      description: 'Japanese koto',
      sourceTypes: ['pluck', 'seq+pluck'],
      chain: [
        { type: 'lpf', params: { freq: 2000, q: 1.0 } },
        { type: 'gain', params: { value: 0.8 } }
      ]
    },
    'banjo': {
      name: 'Banjo',
      description: 'Bright banjo pluck',
      sourceTypes: ['pluck', 'seq+pluck'],
      chain: [
        { type: 'hpf', params: { freq: 400, q: 0.5 } },
        { type: 'lpf', params: { freq: 3500, q: 0.8 } },
        { type: 'gain', params: { value: 0.85 } }
      ]
    }
  }
};

// Helper function to get preset by synth and preset name
export function getSynthPreset(synth, presetName) {
  // Handle null/undefined values
  if (!synth || !presetName) {
    console.warn('[synthPresets] Invalid synth or preset name:', { synth, presetName });
    return null;
  }

  const synthKey = synth.toLowerCase().replace(/['"]/g, '');
  const presetKey = presetName.toLowerCase().replace(/['"]/g, '');

  if (SYNTH_PRESETS[synthKey] && SYNTH_PRESETS[synthKey][presetKey]) {
    return SYNTH_PRESETS[synthKey][presetKey];
  }

  return null;
}

// Helper function to list all synths
export function listSynths() {
  return Object.keys(SYNTH_PRESETS);
}

// Helper function to list presets for a synth
export function listPresetsForSynth(synth) {
  const synthKey = synth.toLowerCase().replace(/['"]/g, '');
  if (SYNTH_PRESETS[synthKey]) {
    return Object.keys(SYNTH_PRESETS[synthKey]);
  }
  return [];
}

// Helper function to get all presets with metadata
export function getAllPresets() {
  const presets = [];
  for (const [synth, presetList] of Object.entries(SYNTH_PRESETS)) {
    for (const [presetName, presetData] of Object.entries(presetList)) {
      presets.push({
        synth,
        preset: presetName,
        name: presetData.name,
        description: presetData.description,
        sourceTypes: presetData.sourceTypes
      });
    }
  }
  return presets;
}
