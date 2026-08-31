// Scale definitions in semitone intervals
export const SCALES = {
    major: [0, 2, 4, 5, 7, 9, 11],
    minor: [0, 2, 3, 5, 7, 8, 10],
    harmonicMinor: [0, 2, 3, 5, 7, 8, 11],
    melodicMinor: [0, 2, 3, 5, 7, 9, 11],
    dorian: [0, 2, 3, 5, 7, 9, 10],
    phrygian: [0, 1, 3, 5, 7, 8, 10],
    lydian: [0, 2, 4, 6, 7, 9, 11],
    mixolydian: [0, 2, 4, 5, 7, 9, 10],
    locrian: [0, 1, 3, 5, 6, 8, 10],
    pentatonicMajor: [0, 2, 4, 7, 9],
    pentatonicMinor: [0, 3, 5, 7, 10],
    blues: [0, 3, 5, 6, 7, 10],
    wholeTone: [0, 2, 4, 6, 8, 10],
    chromatic: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    japanese: [0, 1, 5, 7, 8],
    arabic: [0, 1, 4, 5, 7, 8, 11],
    gypsy: [0, 2, 3, 6, 7, 8, 11],
    spanish: [0, 1, 4, 5, 7, 8, 10]
};

export class ScaleHelper {
    constructor(engine) {
        this.engine = engine;
    }

    // Get scale note by index
    // scale(C4, 'major', 0) => C4
    // scale(C4, 'major', 1) => D4
    // scale(C4, 'major', 7) => C5 (wraps to next octave)
    getScaleNote(rootFreq, scaleName, index) {
        const scale = SCALES[scaleName] || SCALES.major;

        // Calculate octave and scale position
        const octave = Math.floor(index / scale.length);
        const position = index % scale.length;

        // Get semitone offset
        const semitones = scale[position] + (octave * 12);

        // Apply to root frequency
        return rootFreq * Math.pow(2, semitones / 12);
    }

    // Get chord from scale (triads, 7ths, etc.)
    // chord(C4, 'major', 0, 'triad') => [C4, E4, G4]
    // chord(C4, 'major', 0, '7th') => [C4, E4, G4, B4]
    getChord(rootFreq, scaleName, degree, type = 'triad') {
        const scale = SCALES[scaleName] || SCALES.major;

        const chord = [];
        let intervals;

        if (type === 'triad') {
            intervals = [0, 2, 4]; // Root, 3rd, 5th
        } else if (type === '7th') {
            intervals = [0, 2, 4, 6]; // Root, 3rd, 5th, 7th
        } else if (type === '9th') {
            intervals = [0, 2, 4, 6, 8]; // Root, 3rd, 5th, 7th, 9th
        } else if (type === 'sus2') {
            intervals = [0, 1, 4]; // Root, 2nd, 5th
        } else if (type === 'sus4') {
            intervals = [0, 3, 4]; // Root, 4th, 5th
        } else {
            intervals = [0, 2, 4]; // Default triad
        }

        for (const interval of intervals) {
            const index = degree + interval;
            chord.push(this.getScaleNote(rootFreq, scaleName, index));
        }

        return chord;
    }

    // Arpeggio pattern from chord
    // arp(C4, 'major', 0, 'triad', 'up') => [C4, E4, G4]
    // arp(C4, 'major', 0, 'triad', 'updown') => [C4, E4, G4, E4]
    getArpeggio(rootFreq, scaleName, degree, type = 'triad', pattern = 'up') {
        const chord = this.getChord(rootFreq, scaleName, degree, type);

        if (pattern === 'up') {
            return chord;
        } else if (pattern === 'down') {
            return [...chord].reverse();
        } else if (pattern === 'updown') {
            return [...chord, ...chord.slice(1, -1).reverse()];
        } else if (pattern === 'downup') {
            const reversed = [...chord].reverse();
            return [...reversed, ...reversed.slice(1, -1).reverse()];
        } else if (pattern === 'random') {
            return chord.sort(() => Math.random() - 0.5);
        }

        return chord;
    }

    // Create scale helper functions for generator scope
    createScaleFunctions(rootFreq) {
        return {
            scale: (scaleName, index) => this.getScaleNote(rootFreq, scaleName, index),
            chord: (scaleName, degree, type = 'triad') => this.getChord(rootFreq, scaleName, degree, type),
            arp: (scaleName, degree, type = 'triad', pattern = 'up') => this.getArpeggio(rootFreq, scaleName, degree, type, pattern)
        };
    }
}
