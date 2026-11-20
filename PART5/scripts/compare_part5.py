#!/usr/bin/env python3
"""Compare Lab 5 RTL commit traces with the original MIPS-Simulator console logs.

Usage: python3 compare_part5.py iss_program1_output.txt rtl_program1_trace.txt
Uses the ORIGINAL simulator's execution/register snapshots; no ISS replacement.
Memory store addresses are reconstructed from the *encoded assembly operand*
(base register + signed offset) rather than its simulator's nonstandard memory map.
"""
import argparse
import re
import sys
from pathlib import Path

REGISTER_NAMES = ['zero', 'at', 'v0', 'v1', 'a0', 'a1', 'a2', 'a3',
                  't0', 't1', 't2', 't3', 't4', 't5', 't6', 't7',
                  's0', 's1', 's2', 's3', 's4', 's5', 's6', 's7',
                  't8', 't9', 'k0', 'k1', 'gp', 'sp', 'fp', 'ra']
REG_INDEX = {f'${name}': i for i, name in enumerate(REGISTER_NAMES)}
REG_INDEX.update({f'${i}': i for i in range(32)})
REG_RE = re.compile(r'(\$[A-Za-z0-9]+):\s*(-?\d+)')
EXEC_RE = re.compile(r'^Executing at 0x[0-9a-f]+:\s*(.*?)\s*$')


def extract_iss_events(path):
    lines = Path(path).read_text().splitlines()
    events = []
    current_instruction = None
    count = 0
    for line in lines:
        match = EXEC_RE.match(line)
        if match:
            current_instruction = match.group(1)
            count += 1
            continue
        if not current_instruction or not line.startswith('$zero:'):
            continue
        regs = {REG_INDEX[k]: int(v) for k, v in REG_RE.findall(line)}
        if len(regs) != 32:
            raise ValueError(f'Could not parse all 32 ISS registers in {path}')
        parts = current_instruction.replace(',', '').split()
        op = parts[0].lower()
        if op in ('add', 'and', 'addi', 'lw', 'sub', 'or', 'slt', 'ori', 'andi'):
            dest = REG_INDEX[parts[1]]
            if dest != 0:
                events.append(f'REG {dest} {regs[dest] & 0xffffffff:08x}')
        elif op == 'sw':
            source = REG_INDEX[parts[1]]
            m = re.fullmatch(r'(-?\d+)\((\$[A-Za-z0-9]+)\)', parts[2])
            if not m:
                raise ValueError(f'Unsupported SW operand in ISS output: {current_instruction}')
            addr = (regs[REG_INDEX[m.group(2)]] + int(m.group(1))) & 0xffffffff
            events.append(f'MEM {addr:08x} {regs[source] & 0xffffffff:08x}')
        elif op in ('beq', 'bne', 'nop'):
            pass
        else:
            raise ValueError(f'Unsupported ISS instruction in output: {current_instruction}')
        current_instruction = None
    if not count:
        raise ValueError(f'No ISS instructions found in {path}')
    return events, count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('iss_output', help='Original MIPS-Simulator console output')
    parser.add_argument('rtl_trace', help='RTL REG/MEM trace')
    args = parser.parse_args()
    try:
        iss_events, instr_count = extract_iss_events(args.iss_output)
        rtl_events = [line.strip().lower() for line in Path(args.rtl_trace).read_text().splitlines() if line.strip()]
        iss_events = [line.lower() for line in iss_events]
    except (ValueError, OSError, KeyError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2
    print(f'ISS executed {instr_count} instructions; ISS events={len(iss_events)}, RTL events={len(rtl_events)}')
    mismatches = 0
    for i in range(max(len(iss_events), len(rtl_events))):
        a = iss_events[i] if i < len(iss_events) else '<missing>'
        b = rtl_events[i] if i < len(rtl_events) else '<missing>'
        if a != b:
            print(f'MISMATCH event {i+1}: ISS {a} | RTL {b}')
            mismatches += 1
    if mismatches:
        print(f'FAIL: {mismatches} mismatched events')
        return 1
    print(f'PASS: all {len(iss_events)} architectural events match')
    return 0


if __name__ == '__main__':
    sys.exit(main())
