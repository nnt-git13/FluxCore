#!/usr/bin/env python3
"""
scripts/elf2hex.py — Convert a bare-metal RISC-V ELF to a Verilog $readmemh hex file.

Extracts all PT_LOAD segments that cover the given memory base address into a
flat word-addressed hex file suitable for bram_imem / bram_dmem initialisation
via $readmemh.

Usage:
    python3 scripts/elf2hex.py <elf> <hex> [--base BASE] [--depth DEPTH]

Arguments:
    elf     Input ELF file (32-bit LE RISC-V)
    hex     Output hex file (one 8-hex-digit word per line, word 0 first)
    --base  Memory region base byte address (default 0x00000000)
    --depth Memory region depth in 32-bit words (default 4096 = 16 KB)

The output hex file starts from word 0 (at byte address BASE) and covers
exactly DEPTH words.  Words not covered by any ELF segment are output as
00000000.  Words beyond DEPTH bytes from BASE are silently discarded.

Example:
    python3 scripts/elf2hex.py build/spmv_csr.elf build/imem.hex
"""

import argparse
import struct
import sys


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('elf',   help='Input ELF file')
    p.add_argument('hex',   help='Output $readmemh hex file')
    p.add_argument('--base',  type=lambda x: int(x, 0), default=0x00000000,
                   help='Region base byte address (default 0x00000000)')
    p.add_argument('--depth', type=int, default=4096,
                   help='Region depth in 32-bit words (default 4096)')
    return p.parse_args()


def elf2hex(elf_path, hex_path, mem_base, depth):
    with open(elf_path, 'rb') as f:
        data = f.read()

    # --- ELF header ---
    if data[:4] != b'\x7fELF':
        sys.exit(f'error: {elf_path} is not an ELF file')
    ei_class = data[4]
    ei_data  = data[5]
    if ei_class != 1:
        sys.exit('error: expected 32-bit ELF (EI_CLASS=1)')
    if ei_data != 1:
        sys.exit('error: expected little-endian ELF (EI_DATA=1)')

    (e_phoff,)               = struct.unpack_from('<I',  data, 0x1c)
    (e_phentsize, e_phnum)   = struct.unpack_from('<HH', data, 0x2a)

    # --- Allocate flat memory image ---
    mem = [0] * depth

    # --- Walk PT_LOAD segments ---
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        (p_type, p_offset, p_vaddr, _p_paddr,
         p_filesz, p_memsz) = struct.unpack_from('<IIIIII', data, off)

        if p_type != 1:           # PT_LOAD
            continue
        if p_filesz == 0:
            continue

        seg_end = p_vaddr + p_filesz
        mem_end = mem_base + depth * 4

        # Clamp to our memory window
        load_start = max(p_vaddr, mem_base)
        load_end   = min(seg_end, mem_end)
        if load_start >= load_end:
            continue

        byte_off_in_seg = load_start - p_vaddr
        byte_off_in_mem = load_start - mem_base

        seg_data = data[p_offset + byte_off_in_seg :
                        p_offset + byte_off_in_seg + (load_end - load_start)]

        # Copy into word array
        for j in range(0, len(seg_data), 4):
            word_idx = (byte_off_in_mem + j) // 4
            chunk = seg_data[j:j+4]
            if len(chunk) < 4:
                chunk = chunk + b'\x00' * (4 - len(chunk))
            mem[word_idx] = struct.unpack_from('<I', chunk)[0]

    # --- Write hex file ---
    with open(hex_path, 'w') as f:
        for word in mem:
            f.write(f'{word:08x}\n')

    print(f'elf2hex: wrote {depth} words ({depth * 4} bytes) → {hex_path}')


def main():
    args = parse_args()
    elf2hex(args.elf, args.hex, args.base, args.depth)


if __name__ == '__main__':
    main()
