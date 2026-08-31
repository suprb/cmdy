/**
 * Tag Registry System
 *
 * Manages @tag → module mappings and resolves @tag.property references.
 * This is the core of the modular routing system.
 */

import { getModulePorts, getPortDefinition, hasOutputPort } from './portDefinitions.js';

export class TagRegistry {
  constructor() {
    // Map of tag name → module info
    this.tags = new Map();

    // Map of tag name → audio node/value
    this.tagNodes = new Map();

    // Errors encountered during tag resolution
    this.errors = [];
  }

  /**
   * Register a new tag
   * @param {string} tagName - The @tag name (without @)
   * @param {string} moduleName - Module type (e.g., 'osc', 'lfo')
   * @param {object} moduleNode - The audio node or module instance
   * @param {number} lineNumber - Line number in code where tag is defined
   * @param {object} params - Module parameters
   */
  register(tagName, moduleName, moduleNode, lineNumber, params = {}) {
    if (this.tags.has(tagName)) {
      this.errors.push({
        type: 'duplicate_tag',
        tagName,
        message: `Tag '@${tagName}' is already defined on line ${this.tags.get(tagName).lineNumber}`,
        lineNumber
      });
      return false;
    }

    this.tags.set(tagName, {
      moduleName,
      moduleNode,
      lineNumber,
      params,
      ports: getModulePorts(moduleName)
    });

    this.tagNodes.set(tagName, moduleNode);

    return true;
  }

  /**
   * Unregister a tag (for cleanup)
   * @param {string} tagName - The tag name to remove
   */
  unregister(tagName) {
    this.tags.delete(tagName);
    this.tagNodes.delete(tagName);
  }

  /**
   * Clear all tags (for re-parsing)
   */
  clear() {
    this.tags.clear();
    this.tagNodes.clear();
    this.errors = [];
  }

  /**
   * Check if a tag exists
   * @param {string} tagName - Tag name to check
   * @returns {boolean}
   */
  has(tagName) {
    return this.tags.has(tagName);
  }

  /**
   * Get tag information
   * @param {string} tagName - Tag name
   * @returns {object|null} Tag info or null
   */
  getTag(tagName) {
    return this.tags.get(tagName) || null;
  }

  /**
   * Get the module node for a tag
   * @param {string} tagName - Tag name
   * @returns {object|null} Module node or null
   */
  getNode(tagName) {
    return this.tagNodes.get(tagName) || null;
  }

  /**
   * Resolve a tag property reference like @lfo1.rate
   * @param {string} tagName - Tag name (without @)
   * @param {string} propertyName - Property name (e.g., 'rate', 'signal')
   * @returns {object} { value, type, error }
   */
  resolveProperty(tagName, propertyName) {
    // Check if tag exists
    if (!this.has(tagName)) {
      return {
        value: null,
        type: null,
        error: `Tag '@${tagName}' is not defined`
      };
    }

    const tag = this.getTag(tagName);
    const { moduleName, moduleNode, params } = tag;

    // If no property specified, return the default 'signal' output
    if (!propertyName || propertyName === 'signal') {
      return {
        value: moduleNode.output || moduleNode,
        type: 'audio', // or 'cv' depending on module type
        error: null,
        tag
      };
    }

    // Check if the module has this port
    const portDef = getPortDefinition(moduleName, propertyName, 'output');

    if (!portDef) {
      return {
        value: null,
        type: null,
        error: `Module '${moduleName}' does not have an output port '${propertyName}'`,
        availablePorts: Object.keys(tag.ports?.outputs || {})
      };
    }

    // Resolve the property value
    let value = null;

    // Special handling for different property types
    switch (propertyName) {
      // Audio/CV signals - return the audio node
      case 'signal':
        value = moduleNode.output || moduleNode;
        break;

      // Parameters - return the stored parameter value or AudioParam
      case 'rate':
      case 'freq':
      case 'frequency':
      case 'speed':
        // Try to get AudioParam first
        if (moduleNode[propertyName]) {
          value = moduleNode[propertyName];
        } else if (moduleNode.frequency) {
          // Many nodes use .frequency
          value = moduleNode.frequency;
        } else {
          // Fallback to stored parameter value
          value = params[0]; // First param is often frequency/rate
        }
        break;

      case 'Q':
      case 'resonance':
        value = moduleNode.Q || moduleNode[propertyName];
        break;

      case 'gain':
      case 'amount':
      case 'mix':
      case 'depth':
        value = moduleNode.gain || moduleNode[propertyName];
        break;

      // Phase - might be internal state
      case 'phase':
        value = moduleNode.phase || 0;
        break;

      // Waveform, type - return string value
      case 'waveform':
      case 'type':
        value = params.find(p => typeof p === 'string') || 'sine';
        break;

      // Min/max - from LFO params
      case 'min':
        value = params[2]; // LFO: lfo(rate, waveform, min, max)
        break;

      case 'max':
        value = params[3];
        break;

      // Generic parameter access by index
      default:
        // Try to access as a property on the module node
        if (moduleNode[propertyName] !== undefined) {
          value = moduleNode[propertyName];
        } else {
          // Return null - port exists but value not accessible
          value = null;
        }
    }

    return {
      value,
      type: portDef.type,
      error: null,
      portDef,
      tag
    };
  }

  /**
   * Get all available properties for a tag (for autocomplete)
   * @param {string} tagName - Tag name
   * @returns {Array} Array of { name, type, description }
   */
  getAvailableProperties(tagName) {
    if (!this.has(tagName)) {
      return [];
    }

    const tag = this.getTag(tagName);
    const ports = tag.ports?.outputs || {};

    return Object.entries(ports).map(([name, port]) => ({
      name,
      type: port.type,
      description: port.description
    }));
  }

  /**
   * Get all registered tags (for autocomplete)
   * @returns {Array} Array of { tagName, moduleName, lineNumber }
   */
  getAllTags() {
    return Array.from(this.tags.entries()).map(([tagName, info]) => ({
      tagName,
      moduleName: info.moduleName,
      lineNumber: info.lineNumber
    }));
  }

  /**
   * Get all errors
   * @returns {Array}
   */
  getErrors() {
    return this.errors;
  }

  /**
   * Validate all tag references in code
   * @param {string} code - The code to validate
   * @returns {Array} Array of errors
   */
  validateReferences(code) {
    const errors = [];

    // Find all @tag.property references
    const tagRefRegex = /@([a-zA-Z_]\w*)(?:\.([a-zA-Z_]\w*))?/g;
    let match;

    while ((match = tagRefRegex.exec(code)) !== null) {
      const [fullMatch, tagName, propertyName] = match;

      // Check if tag exists
      if (!this.has(tagName)) {
        errors.push({
          type: 'undefined_tag',
          tagName,
          message: `Tag '@${tagName}' is used but not defined`,
          position: match.index
        });
        continue;
      }

      // Check if property exists (if specified)
      if (propertyName) {
        const result = this.resolveProperty(tagName, propertyName);
        if (result.error) {
          errors.push({
            type: 'invalid_property',
            tagName,
            propertyName,
            message: result.error,
            position: match.index,
            availablePorts: result.availablePorts
          });
        }
      }
    }

    return errors;
  }

  /**
   * Get usage count for a tag (how many times it's referenced)
   * @param {string} tagName - Tag name
   * @param {string} code - The code to search
   * @returns {number}
   */
  getUsageCount(tagName, code) {
    const regex = new RegExp(`@${tagName}\\b`, 'g');
    const matches = code.match(regex);
    return matches ? matches.length - 1 : 0; // -1 to exclude definition
  }

  /**
   * Get all references to a tag in code
   * @param {string} tagName - Tag name
   * @param {string} code - The code to search
   * @returns {Array} Array of { line, column, context }
   */
  getReferences(tagName, code) {
    const references = [];
    const lines = code.split('\n');
    const regex = new RegExp(`@${tagName}\\b`, 'g');

    lines.forEach((line, lineIndex) => {
      let match;
      while ((match = regex.exec(line)) !== null) {
        references.push({
          line: lineIndex + 1,
          column: match.index,
          context: line.trim()
        });
      }
    });

    return references;
  }

  /**
   * Debug: Print all registered tags
   */
  debug() {
    console.log('=== Tag Registry Debug ===');
    console.log(`Total tags: ${this.tags.size}`);

    this.tags.forEach((info, tagName) => {
      console.log(`  @${tagName}:`);
      console.log(`    Module: ${info.moduleName}`);
      console.log(`    Line: ${info.lineNumber}`);
      console.log(`    Params:`, info.params);
      console.log(`    Available ports:`, Object.keys(info.ports?.outputs || {}));
    });

    if (this.errors.length > 0) {
      console.log('\nErrors:');
      this.errors.forEach(err => console.log(`  - ${err.message}`));
    }
  }
}

// Global singleton instance
export const tagRegistry = new TagRegistry();
