#!/usr/bin/env python3
"""
LLCache test stimulus generator.

Command encoding (variable width):
  width = paddr_width + 32
  [width-1 : paddr+24] opcode (8)
  [paddr+23 : paddr+16] tag (8, auto-derived from address)
  [paddr+15 : paddr]    arg (16)
  [paddr-1  : 0]        address
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import argparse


OP_END = 0x00
OP_SEND_REQ = 0x01
OP_EXPECT_MISS = 0x02
OP_SEND_FILL = 0x03
OP_EXPECT_RESP = 0x04
OP_EXPECT_NO_MISS = 0x05
OP_PASS = 0x06
OP_SEND_WRITE = 0x07
OP_EXPECT_WRITE_ACK = 0x08

MAX_ENTRIES = 1024

# Tag starts above: word offset (3) + block offset (3) + set index (6) = 12
TAG_SHIFT = 12

ADDR_A = 0xA5A5A5A5
ADDR_B = 0x5A5A5A5A
ADDR_C = 0x3C3C3C3C
ADDR_D = 0xC3C3C3C3
ADDR_FILL_BASE = 0x00010000


@dataclass(frozen=True)
class Step:
    opcode: int
    address: int = 0
    tag: int = 0
    arg: int = 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate LLCache test.mem command stream")
    parser.add_argument("--ways", type=int, required=True,
                        help="LLCache ways (same as `llcways`)")
    parser.add_argument(
        "--paddr-width",
        type=int,
        required=True,
        help="Physical address width (same as `paddr`)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("test.mem"),
        help="Output command memory file",
    )
    return parser.parse_args()


def tag_from_addr(address: int) -> int:
    return (address >> TAG_SHIFT) & 0xFF


def send_req(address: int, hart: int = 0) -> Step:
    return Step(OP_SEND_REQ, address, tag_from_addr(address), hart)


def expect_miss(address: int) -> Step:
    return Step(OP_EXPECT_MISS, address, tag_from_addr(address), 0)


def send_fill(address: int, hart: int = 0) -> Step:
    return Step(OP_SEND_FILL, address, tag_from_addr(address), hart)


def expect_resp(address: int, hart: int = 0) -> Step:
    return Step(OP_EXPECT_RESP, address, tag_from_addr(address), hart)


def send_write(address: int, hart: int = 0) -> Step:
    return Step(OP_SEND_WRITE, address, tag_from_addr(address), hart)


def expect_write_ack(address: int, hart: int = 0) -> Step:
    return Step(OP_EXPECT_WRITE_ACK, address, tag_from_addr(address), hart)


def expect_no_miss(cycles: int) -> Step:
    return Step(OP_EXPECT_NO_MISS, 0, 0, cycles)


def pass_marker(marker: int) -> Step:
    return Step(OP_PASS, 0, 0, marker)


def end_marker() -> Step:
    return Step(OP_END, 0, 0, 0)


def encode(step: Step, paddr_width: int) -> int:
    addr_mask = (1 << paddr_width) - 1
    if not (0 <= step.opcode <= 0xFF):
        raise ValueError(f"Opcode out of range: {step.opcode}")
    if not (0 <= step.tag <= 0xFF):
        raise ValueError(f"Tag out of range: {step.tag}")
    if not (0 <= step.arg <= 0xFFFF):
        raise ValueError(f"Arg out of range: {step.arg}")
    if not (0 <= step.address <= addr_mask):
        raise ValueError(
            f"Address 0x{step.address:x} exceeds paddr_width={paddr_width}")

    return (
        (step.opcode << (paddr_width + 24))
        | (step.tag << (paddr_width + 16))
        | (step.arg << paddr_width)
        | step.address
    )


def build_test0_basic() -> list[Step]:
    # Check that a read after processing a miss always hits
    return [
        send_req(ADDR_A),
        expect_miss(ADDR_A),
        send_fill(ADDR_A),
        expect_resp(ADDR_A),
        send_req(ADDR_A),
        expect_resp(ADDR_A),
        expect_no_miss(2),
        pass_marker(1),
    ]


def build_test1_nonblocking() -> list[Step]:
    # Check non blocking behaviour: subsequent hit is serviced before the pending miss
    return [
        send_req(ADDR_B),
        send_req(ADDR_A),
        expect_miss(ADDR_B),
        send_fill(ADDR_B),
        expect_resp(ADDR_A),
        expect_no_miss(2),
        expect_resp(ADDR_B),
        send_req(ADDR_B),
        expect_resp(ADDR_B),
        expect_no_miss(2),
        send_req(ADDR_B),
        expect_resp(ADDR_B),
        expect_no_miss(2),
        pass_marker(1),
    ]


def build_test2_fill_and_evict(ways: int) -> list[Step]:
    # Check eviction happens when the set is fully filled
    steps: list[Step] = []
    for i in range(ways):
        addr = ADDR_FILL_BASE + (i << 12)
        steps.extend(
            [
                send_req(addr),
                expect_miss(addr),
                send_fill(addr),
                expect_resp(addr),
            ]
        )

    steps.extend(
        [
            send_req(ADDR_FILL_BASE),
            expect_resp(ADDR_FILL_BASE),
            expect_no_miss(2),
            pass_marker(2),
        ]
    )
    return steps


def build_test3_same_line_hits() -> list[Step]:
    # Fill one line, then access another address in the same line and expect hit.
    addr_line_base = ADDR_C & ~0x3F
    addr_same_line = addr_line_base | 0x18
    return [
        send_req(addr_line_base),
        expect_miss(addr_line_base),
        send_fill(addr_line_base),
        expect_resp(addr_line_base),
        send_req(addr_same_line),
        expect_resp(addr_same_line),
        expect_no_miss(2),
        pass_marker(3),
    ]


def build_test4_hart_id_path() -> list[Step]:
    # Check that a non-zero hart id is preserved through fill + hit response path.
    hart = 2
    return [
        send_req(ADDR_D, hart=hart),
        expect_miss(ADDR_D),
        send_fill(ADDR_D, hart=hart),
        expect_resp(ADDR_D, hart=hart),
        send_req(ADDR_D, hart=hart),
        expect_resp(ADDR_D, hart=hart),
        expect_no_miss(2),
        pass_marker(4),
    ]


def build_test5_write_hit() -> list[Step]:
    # Fill a line, then write new data to it, then read to verify the written data.
    write_addr = 0xabcdabcd
    return [
        send_req(write_addr),
        expect_miss(write_addr),
        send_fill(write_addr),
        expect_resp(write_addr),
        send_write(write_addr),
        expect_write_ack(write_addr),
        send_req(write_addr),
        expect_resp(write_addr),
        expect_no_miss(2),
        pass_marker(5),
    ]


TEST_BUILDERS = {
    "test0": lambda ways: build_test0_basic(),
    "test1": lambda ways: build_test1_nonblocking(),
    "test2": lambda ways: build_test2_fill_and_evict(ways),
    "test3": lambda ways: build_test3_same_line_hits(),
    "test4": lambda ways: build_test4_hart_id_path(),
    "test5": lambda ways: build_test5_write_hit(),
}

ENABLED_TESTS = [
    "test0",
    "test1",
    "test2",
    "test3",
    "test4",
    "test5",
]


def get_enabled_tests() -> list[str]:
    if not ENABLED_TESTS:
        raise RuntimeError("ENABLED_TESTS is empty")
    unknown = [name for name in ENABLED_TESTS if name not in TEST_BUILDERS]
    if unknown:
        raise RuntimeError(
            f"Unknown test(s): {', '.join(unknown)}. Available: {
                ', '.join(TEST_BUILDERS.keys())}"
        )
    return ENABLED_TESTS


def build_steps(ways: int, selected_tests: list[str]) -> list[Step]:
    steps: list[Step] = []
    for name in selected_tests:
        steps.extend(TEST_BUILDERS[name](ways))
    steps.extend([pass_marker(99), end_marker()])
    return steps


def write_mem(steps: list[Step], out_path: Path, paddr_width: int) -> None:
    if len(steps) > MAX_ENTRIES:
        raise RuntimeError(
            f"Generated {len(steps)} entries, exceeds MAX_ENTRIES={MAX_ENTRIES}")

    words = [encode(step, paddr_width) for step in steps]
    words.extend([0] * (MAX_ENTRIES - len(words)))
    nibs = (paddr_width + 32 + 3) // 4

    with out_path.open("w", encoding="utf-8") as f:
        for word in words:
            f.write(f"{word:0{nibs}x}\n")


def main() -> None:
    args = parse_args()
    selected_tests = get_enabled_tests()
    steps = build_steps(args.ways, selected_tests)
    write_mem(steps, args.out, args.paddr_width)
    print(
        f"Wrote {len(steps)} active entries to {args.out} "
        f"(padded to {MAX_ENTRIES}); tests={','.join(selected_tests)}"
    )


if __name__ == "__main__":
    main()
