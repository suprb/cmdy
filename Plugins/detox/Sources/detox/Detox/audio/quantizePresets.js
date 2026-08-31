/**
 * Quantize Presets - Classic Drum Machine Groove Templates
 *
 * Each preset defines timing offsets for 16 steps (16th notes in a bar).
 * Offsets are in percentages: 0% = on grid, positive = delayed, negative = rushed
 *
 * Based on real hardware timing characteristics and famous grooves.
 */

export const QUANTIZE_PRESETS = {
  // Perfect grid - no swing
  straight: {
    name: 'Straight (0%)',
    description: 'Perfect quantization with no swing',
    offsets: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    swing: 0
  },

  // Akai MPC swing templates - the legendary MPC groove
  mpc50: {
    name: 'MPC Swing 50%',
    description: 'Akai MPC 50% swing - subtle groove',
    offsets: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    swing: 50
  },

  mpc54: {
    name: 'MPC Swing 54%',
    description: 'Akai MPC 54% swing - light bounce',
    offsets: [0, 2.1, 0, 2.1, 0, 2.1, 0, 2.1, 0, 2.1, 0, 2.1, 0, 2.1, 0, 2.1],
    swing: 54
  },

  mpc58: {
    name: 'MPC Swing 58%',
    description: 'Akai MPC 58% swing - classic hip-hop feel',
    offsets: [0, 4.2, 0, 4.2, 0, 4.2, 0, 4.2, 0, 4.2, 0, 4.2, 0, 4.2, 0, 4.2],
    swing: 58
  },

  mpc62: {
    name: 'MPC Swing 62%',
    description: 'Akai MPC 62% swing - pronounced groove',
    offsets: [0, 6.3, 0, 6.3, 0, 6.3, 0, 6.3, 0, 6.3, 0, 6.3, 0, 6.3, 0, 6.3],
    swing: 62
  },

  mpc66: {
    name: 'MPC Swing 66%',
    description: 'Akai MPC 66% swing - heavy shuffle',
    offsets: [0, 8.4, 0, 8.4, 0, 8.4, 0, 8.4, 0, 8.4, 0, 8.4, 0, 8.4, 0, 8.4],
    swing: 66
  },

  mpc75: {
    name: 'MPC Swing 75%',
    description: 'Akai MPC 75% swing - extreme triplet feel',
    offsets: [0, 12.5, 0, 12.5, 0, 12.5, 0, 12.5, 0, 12.5, 0, 12.5, 0, 12.5, 0, 12.5],
    swing: 75
  },

  // Roland TR-909 - slight mechanical imperfections give it character
  tr909: {
    name: 'Roland TR-909',
    description: 'Classic 909 drum machine timing with mechanical variations',
    offsets: [
      0, 0.3, -0.1, 0.2, 0, 0.4, -0.2, 0.1,
      0, 0.2, -0.1, 0.3, 0, 0.3, -0.1, 0.2
    ],
    swing: 0
  },

  // Roland TR-808 - similar to 909 but slightly different character
  tr808: {
    name: 'Roland TR-808',
    description: 'Classic 808 drum machine timing',
    offsets: [
      0, 0.4, -0.2, 0.3, 0, 0.5, -0.1, 0.2,
      0, 0.3, -0.2, 0.4, 0, 0.4, -0.1, 0.3
    ],
    swing: 0
  },

  // J Dilla / "Drunk" style - heavily behind the beat with variation
  dilla: {
    name: 'J Dilla',
    description: 'Dilla-style drunk timing - behind the beat with character',
    offsets: [
      0, 8.5, 1.2, 10.2, 0.5, 9.1, 1.8, 8.8,
      0.3, 9.5, 1.5, 10.5, 0.8, 8.3, 2.1, 9.8
    ],
    swing: 65
  },

  // Shuffle - triplet-based swing (66.67% = perfect triplets)
  shuffle: {
    name: 'Shuffle',
    description: 'Triplet-based shuffle groove',
    offsets: [0, 11.1, 0, 11.1, 0, 11.1, 0, 11.1, 0, 11.1, 0, 11.1, 0, 11.1, 0, 11.1],
    swing: 66.67
  },

  // Human feel - subtle random variations
  human: {
    name: 'Human Feel',
    description: 'Subtle random timing variations for organic feel',
    offsets: [
      0, 0.8, -0.3, 1.2, 0.2, 0.5, -0.6, 0.9,
      0.1, 0.7, -0.4, 1.1, -0.1, 0.6, -0.5, 0.8
    ],
    swing: 52
  },

  // Techno/Electronic - tight but with slight push
  techno: {
    name: 'Techno',
    description: 'Tight electronic timing with slight forward push',
    offsets: [
      0, -0.5, 0, -0.5, 0, -0.5, 0, -0.5,
      0, -0.5, 0, -0.5, 0, -0.5, 0, -0.5
    ],
    swing: 0
  },

  // Half-time shuffle - laid back groove
  halfswing: {
    name: 'Half-time Shuffle',
    description: 'Laid-back half-time shuffle feel',
    offsets: [0, 6.3, 0, 0, 0, 6.3, 0, 0, 0, 6.3, 0, 0, 0, 6.3, 0, 0],
    swing: 58
  },

  // Dotted - dotted 8th note feel
  dotted: {
    name: 'Dotted 8th',
    description: 'Dotted eighth note pattern',
    offsets: [0, 0, 0, 8.3, 0, 0, 8.3, 0, 0, 0, 0, 8.3, 0, 0, 8.3, 0],
    swing: 0
  },

  // Logic Pro style grooves
  logicSwing16: {
    name: 'Logic Swing 16',
    description: 'Logic Pro 16th note swing',
    offsets: [0, 3.1, 0, 3.1, 0, 3.1, 0, 3.1, 0, 3.1, 0, 3.1, 0, 3.1, 0, 3.1],
    swing: 55
  },

  logicSwing8: {
    name: 'Logic Swing 8',
    description: 'Logic Pro 8th note swing',
    offsets: [0, 6.3, 0, 0, 0, 6.3, 0, 0, 0, 6.3, 0, 0, 0, 6.3, 0, 0],
    swing: 62
  },

  // Funk - syncopated with emphasis on upbeats
  funk: {
    name: 'Funk',
    description: 'Funky syncopated groove with upbeat emphasis',
    offsets: [
      0, 1.5, 0.8, 2.2, 0.3, 1.8, 1.2, 2.5,
      0, 1.6, 0.9, 2.3, 0.4, 1.9, 1.1, 2.4
    ],
    swing: 56
  },

  // Push - everything slightly ahead for driving feel
  push: {
    name: 'Push',
    description: 'Notes pushed ahead for driving, urgent feel',
    offsets: [
      -0.8, -1.2, -0.9, -1.1, -0.8, -1.3, -0.9, -1.2,
      -0.8, -1.1, -0.9, -1.2, -0.8, -1.3, -0.9, -1.1
    ],
    swing: 0
  },

  // Drag - everything slightly behind for laid-back feel
  drag: {
    name: 'Drag',
    description: 'Notes dragged behind for laid-back feel',
    offsets: [
      0.8, 1.2, 0.9, 1.1, 0.8, 1.3, 0.9, 1.2,
      0.8, 1.1, 0.9, 1.2, 0.8, 1.3, 0.9, 1.1
    ],
    swing: 0
  }
};

// Helper function to get preset by name
export function getQuantizePreset(name) {
  return QUANTIZE_PRESETS[name] || QUANTIZE_PRESETS.straight;
}

// Helper function to list all presets
export function listQuantizePresets() {
  return Object.entries(QUANTIZE_PRESETS).map(([key, preset]) => ({
    key,
    name: preset.name,
    description: preset.description
  }));
}

// Apply quantize offsets to a timing value
export function applyQuantize(stepIndex, timeInMs, preset) {
  const presetData = typeof preset === 'string' ? getQuantizePreset(preset) : preset;
  const offset = presetData.offsets[stepIndex % 16];

  // Calculate offset in milliseconds
  // Offset percentage is based on 16th note duration
  const sixteenthNoteDuration = (60000 / (120 * 4)); // Default to 120 BPM, adjust in implementation
  const offsetMs = (offset / 100) * sixteenthNoteDuration;

  return timeInMs + offsetMs;
}
