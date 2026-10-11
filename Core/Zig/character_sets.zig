//! Generated Foundation CharacterSet compatibility data; no host calls at runtime.
pub fn trim(scalar: u32) bool {
    return switch (scalar) {
        0x9...0xd => true,
        0x20 => true,
        0x85 => true,
        0xa0 => true,
        0x1680 => true,
        0x2000...0x200b => true,
        0x2028...0x2029 => true,
        0x202f => true,
        0x205f => true,
        0x3000 => true,
        else => false,
    };
}
pub fn whitespace(scalar: u32) bool {
    return switch (scalar) {
        0x9 => true,
        0x20 => true,
        0xa0 => true,
        0x1680 => true,
        0x2000...0x200b => true,
        0x202f => true,
        0x205f => true,
        0x3000 => true,
        else => false,
    };
}
