#!/usr/bin/env python3
"""Generate README figures from checked-in FluxCore artifacts."""

from __future__ import annotations

import math
import re
from pathlib import Path

import matplotlib.pyplot as plt
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "figures" / "readme_assets"

TEAL = "#0f766e"
SLATE = "#334155"
INK = "#0f172a"
MUTED = "#64748b"
LINE = "#cbd5e1"
PAPER = "#f8fafc"
PANEL = "#ffffff"
AMBER = "#d97706"


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8", errors="ignore")


def parse_utilization(path: str) -> dict[str, tuple[float, float, float]]:
    text = read(path)
    wanted = {
        "Slice LUTs": "Slice LUTs",
        "Slice Registers": "Slice Registers",
        "Block RAM Tile": "Block RAM",
        "DSPs": "DSPs",
    }
    values: dict[str, tuple[float, float, float]] = {}
    for line in text.splitlines():
        for key, label in wanted.items():
            if key in line and label not in values:
                nums = re.findall(r"[-+]?\d+(?:\.\d+)?", line)
                if len(nums) >= 3:
                    used = float(nums[0])
                    avail = float(nums[-2])
                    pct = float(nums[-1])
                    values[label] = (used, avail, pct)
    return values


def parse_wns(path: str) -> float:
    text = read(path)
    marker = "Design Timing Summary"
    start = text.find(marker)
    if start < 0:
        raise ValueError(f"missing timing summary in {path}")
    for line in text[start:].splitlines():
        nums = re.findall(r"[-+]?\d+\.\d+", line)
        if len(nums) >= 2:
            return float(nums[0])
    raise ValueError(f"missing WNS value in {path}")


def write_svg(path: Path, width: int, height: int, body: str) -> None:
    path.write_text(
        "\n".join(
            [
                f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
                '<style>text{font-family:Inter,Segoe UI,Arial,sans-serif;fill:#0f172a} .muted{fill:#64748b} .small{font-size:14px} .label{font-size:16px;font-weight:650} .title{font-size:24px;font-weight:750}</style>',
                f'<rect width="{width}" height="{height}" rx="24" fill="{PAPER}"/>',
                body,
                "</svg>",
            ]
        ),
        encoding="utf-8",
    )


def box(x: int, y: int, w: int, h: int, label: str, sub: str, fill: str = PANEL) -> str:
    return "\n".join(
        [
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{fill}" stroke="{LINE}" stroke-width="1.5"/>',
            f'<text x="{x + w / 2}" y="{y + 32}" text-anchor="middle" class="label">{label}</text>',
            f'<text x="{x + w / 2}" y="{y + 56}" text-anchor="middle" class="small muted">{sub}</text>',
        ]
    )


def arrow(x1: int, y1: int, x2: int, y2: int, color: str = TEAL) -> str:
    return (
        f'<path d="M{x1} {y1} L{x2} {y2}" stroke="{color}" stroke-width="3" fill="none" marker-end="url(#arrow)"/>'
    )


def architecture_svg() -> None:
    width, height = 1536, 1024

    def card(
        x: int,
        y: int,
        w: int,
        h: int,
        color: str,
        stage: str,
        title: str,
        icon: str,
        bullets: tuple[str, str],
    ) -> str:
        return f"""
        <g filter="url(#softGlow)">
          <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="url(#{color}Card)" stroke="url(#{color}Stroke)" stroke-width="1.2"/>
          <circle cx="{x + 58}" cy="{y + 72}" r="44" fill="none" stroke="var(--{color})" stroke-width="1.4"/>
          <text x="{x + 58}" y="{y + 82}" text-anchor="middle" class="icon {color}">{icon}</text>
          <text x="{x + 120}" y="{y + 70}" class="stage {color}">{stage}</text>
          <text x="{x + 120}" y="{y + 104}" class="cardText">{title}</text>
          <line x1="{x + 22}" y1="{y + 138}" x2="{x + w - 22}" y2="{y + 138}" stroke="var(--{color})" stroke-width="1.2"/>
          <text x="{x + 34}" y="{y + 184}" class="dot {color}">o</text>
          <text x="{x + 58}" y="{y + 184}" class="bullet">{bullets[0]}</text>
          <text x="{x + 34}" y="{y + 222}" class="dot {color}">o</text>
          <text x="{x + 58}" y="{y + 222}" class="bullet">{bullets[1]}</text>
        </g>
        """

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
<style>
  :root {{
    --teal:#14c8b8;
    --green:#8fd266;
    --blue:#2f9dff;
    --violet:#a879ff;
    --orange:#f08a12;
    --ink:#f8fafc;
    --muted:#cbd5e1;
    --panel:#070b12;
  }}
  text {{ font-family: Inter, Segoe UI, Arial, sans-serif; }}
  .title {{ font-size:76px; font-weight:800; letter-spacing:0; fill:#f8fafc; }}
  .titleCore {{ fill:url(#titleGrad); }}
  .kicker {{ font-size:28px; font-weight:750; letter-spacing:7px; fill:var(--teal); }}
  .subtitle {{ font-size:24px; fill:var(--muted); }}
  .accent {{ fill:var(--teal); font-weight:750; }}
  .stage {{ font-size:38px; font-weight:800; }}
  .cardText {{ font-size:18px; fill:#f8fafc; }}
  .bullet {{ font-size:22px; fill:#e5e7eb; }}
  .dot {{ font-size:26px; font-weight:800; }}
  .icon {{ font-size:21px; font-weight:800; }}
  .teal {{ fill:var(--teal); }}
  .green {{ fill:var(--green); }}
  .blue {{ fill:var(--blue); }}
  .violet {{ fill:var(--violet); }}
  .orange {{ fill:var(--orange); }}
  .mono {{ font-family: JetBrains Mono, SFMono-Regular, Consolas, monospace; }}
</style>
<defs>
  <radialGradient id="bgGlow" cx="50%" cy="40%" r="70%">
    <stop offset="0%" stop-color="#0b1826"/>
    <stop offset="58%" stop-color="#03070d"/>
    <stop offset="100%" stop-color="#010409"/>
  </radialGradient>
  <linearGradient id="titleGrad" x1="0" x2="1">
    <stop offset="0%" stop-color="#f8fafc"/>
    <stop offset="46%" stop-color="#f8fafc"/>
    <stop offset="47%" stop-color="#14c8b8"/>
    <stop offset="100%" stop-color="#0f9f91"/>
  </linearGradient>
  <filter id="softGlow" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="0" stdDeviation="6" flood-color="#0f172a" flood-opacity="0.85"/>
  </filter>
  <filter id="tealGlow" x="-30%" y="-30%" width="160%" height="160%">
    <feDropShadow dx="0" dy="0" stdDeviation="8" flood-color="#14c8b8" flood-opacity="0.55"/>
  </filter>
  <marker id="arrowTeal" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="11" markerHeight="11" orient="auto"><path d="M0 0 L12 6 L0 12 z" fill="#14c8b8"/></marker>
  <marker id="arrowGreen" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="11" markerHeight="11" orient="auto"><path d="M0 0 L12 6 L0 12 z" fill="#8fd266"/></marker>
  <marker id="arrowBlue" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="11" markerHeight="11" orient="auto"><path d="M0 0 L12 6 L0 12 z" fill="#2f9dff"/></marker>
  <marker id="arrowViolet" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="11" markerHeight="11" orient="auto"><path d="M0 0 L12 6 L0 12 z" fill="#a879ff"/></marker>
  <marker id="arrowOrange" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="11" markerHeight="11" orient="auto"><path d="M0 0 L12 6 L0 12 z" fill="#f08a12"/></marker>
  <linearGradient id="tealStroke"><stop stop-color="#14c8b8"/><stop offset="100%" stop-color="#0f766e"/></linearGradient>
  <linearGradient id="greenStroke"><stop stop-color="#8fd266"/><stop offset="100%" stop-color="#4d7c0f"/></linearGradient>
  <linearGradient id="blueStroke"><stop stop-color="#2f9dff"/><stop offset="100%" stop-color="#0b5fad"/></linearGradient>
  <linearGradient id="violetStroke"><stop stop-color="#a879ff"/><stop offset="100%" stop-color="#6d28d9"/></linearGradient>
  <linearGradient id="orangeStroke"><stop stop-color="#f08a12"/><stop offset="100%" stop-color="#9a3412"/></linearGradient>
  <linearGradient id="tealCard"><stop stop-color="#021918"/><stop offset="100%" stop-color="#05080d"/></linearGradient>
  <linearGradient id="greenCard"><stop stop-color="#10190b"/><stop offset="100%" stop-color="#05080d"/></linearGradient>
  <linearGradient id="blueCard"><stop stop-color="#07182b"/><stop offset="100%" stop-color="#05080d"/></linearGradient>
  <linearGradient id="violetCard"><stop stop-color="#160c29"/><stop offset="100%" stop-color="#05080d"/></linearGradient>
  <linearGradient id="orangeCard"><stop stop-color="#1f1204"/><stop offset="100%" stop-color="#05080d"/></linearGradient>
</defs>
<rect width="{width}" height="{height}" fill="url(#bgGlow)"/>
<rect width="{width}" height="{height}" fill="#000" opacity="0.18"/>

<g filter="url(#tealGlow)">
  <rect x="58" y="38" width="58" height="58" rx="8" fill="none" stroke="#14c8b8" stroke-width="5"/>
  <rect x="73" y="53" width="28" height="28" rx="3" fill="#061016" stroke="#14c8b8" stroke-width="3"/>
  <text x="87" y="76" text-anchor="middle" class="icon teal">F</text>
  <g stroke="#14c8b8" stroke-width="4" stroke-linecap="round">
    <path d="M52 46 h-8 M52 58 h-8 M52 70 h-8 M52 82 h-8"/>
    <path d="M122 46 h8 M122 58 h8 M122 70 h8 M122 82 h8"/>
    <path d="M66 32 v-8 M78 32 v-8 M90 32 v-8 M102 32 v-8"/>
    <path d="M66 102 v8 M78 102 v8 M90 102 v8 M102 102 v8"/>
  </g>
</g>

<text x="136" y="86" class="title">Flux<tspan class="titleCore">Core</tspan></text>
<text x="136" y="126" class="kicker">EXECUTION PATH</text>
<text x="46" y="172" class="subtitle">Five-stage <tspan class="accent">RV32IMXFlux</tspan> pipeline with instruction and data memories.</text>
<text x="46" y="212" class="subtitle">Optional one-word-line D-cache on the data path.</text>

{card(40, 252, 270, 265, "teal", "IF", "Instruction Fetch", "PC", ("Fetch instruction", "Update PC (next-PC)"))}
{card(346, 252, 274, 265, "green", "ID", "Instruction Decode", "DEC", ("Decode opcode", "Read registers"))}
{card(652, 252, 266, 265, "blue", "EX", "Execute", "ALU", ("ALU / branch", "Multiply / Divide"))}
{card(958, 252, 270, 265, "violet", "MEM", "Memory Access", "MEM", ("BRAM or D-cache", "Load / Store data"))}
{card(1264, 252, 232, 265, "orange", "WB", "Write Back", "WB", ("Write result", "Update CSR"))}

<path d="M312 328 L342 328" stroke="#14c8b8" stroke-width="6" marker-end="url(#arrowTeal)"/>
<path d="M622 328 L648 328" stroke="#8fd266" stroke-width="6" marker-end="url(#arrowGreen)"/>
<path d="M920 328 L954 328" stroke="#2f9dff" stroke-width="6" marker-end="url(#arrowBlue)"/>
<path d="M1230 328 L1260 328" stroke="#2f9dff" stroke-width="6" marker-end="url(#arrowBlue)"/>

<path d="M180 520 L180 590" stroke="#14c8b8" stroke-width="8" marker-end="url(#arrowTeal)"/>
<path d="M180 590 L180 522" stroke="#14c8b8" stroke-width="8" marker-end="url(#arrowTeal)" opacity="0.72"/>
<path d="M780 520 L780 585" stroke="#2f9dff" stroke-width="8" marker-end="url(#arrowBlue)"/>
<path d="M988 665 L1060 665" stroke="#f08a12" stroke-width="8" marker-end="url(#arrowOrange)"/>

<g filter="url(#softGlow)">
  <rect x="88" y="596" width="388" height="142" rx="13" fill="url(#tealCard)" stroke="#14c8b8" stroke-width="1.2"/>
  <text x="218" y="642" class="stage teal" style="font-size:26px">Instruction BRAM</text>
  <text x="218" y="682" class="subtitle" style="font-size:24px">4096 x 32-bit</text>
  <text x="218" y="714" class="subtitle" style="font-size:24px">Hex initialized</text>
  <rect x="126" y="632" width="56" height="56" rx="7" fill="none" stroke="#14c8b8" stroke-width="4"/>
  <circle cx="146" cy="652" r="6" fill="#14c8b8"/><circle cx="164" cy="652" r="6" fill="#14c8b8"/><circle cx="146" cy="672" r="6" fill="#14c8b8"/><circle cx="164" cy="672" r="6" fill="#14c8b8"/>
</g>
<g filter="url(#softGlow)">
  <rect x="574" y="596" width="412" height="142" rx="13" fill="url(#blueCard)" stroke="#2f9dff" stroke-width="1.2"/>
  <text x="714" y="642" class="stage blue" style="font-size:26px">Data BRAM</text>
  <text x="714" y="682" class="subtitle" style="font-size:24px">2048 x 32-bit,</text>
  <text x="714" y="714" class="subtitle" style="font-size:24px">Byte enables</text>
  <rect x="622" y="632" width="56" height="56" rx="7" fill="none" stroke="#2f9dff" stroke-width="4"/>
  <circle cx="640" cy="652" r="6" fill="#2f9dff"/><circle cx="660" cy="652" r="6" fill="#2f9dff"/><circle cx="640" cy="672" r="6" fill="#2f9dff"/><circle cx="660" cy="672" r="6" fill="#2f9dff"/>
</g>
<g filter="url(#softGlow)">
  <rect x="1064" y="596" width="394" height="142" rx="13" fill="url(#orangeCard)" stroke="#f08a12" stroke-width="1.2"/>
  <text x="1198" y="642" class="stage orange" style="font-size:26px">Optional D-cache</text>
  <text x="1198" y="682" class="subtitle" style="font-size:24px">64 direct-mapped</text>
  <text x="1198" y="714" class="subtitle" style="font-size:24px">word lines (1 word/line)</text>
  <rect x="1108" y="632" width="58" height="58" rx="7" fill="none" stroke="#f08a12" stroke-width="4"/>
  <g fill="#f08a12"><rect x="1118" y="642" width="16" height="8"/><rect x="1140" y="642" width="16" height="8"/><rect x="1118" y="658" width="16" height="8"/><rect x="1140" y="658" width="16" height="8"/><rect x="1118" y="674" width="16" height="8"/><rect x="1140" y="674" width="16" height="8"/></g>
</g>

<path d="M277 744 V776 Q277 790 291 790 H1248 Q1260 790 1260 776 V744" fill="none" stroke="#5f7899" stroke-width="2" stroke-dasharray="7 8" opacity="0.75"/>
<path d="M780 744 V790" stroke="#5f7899" stroke-width="2" stroke-dasharray="7 8" opacity="0.75"/>

<rect x="54" y="824" width="1428" height="144" rx="14" fill="#05080d" stroke="#334155" stroke-width="1.2"/>
<line x1="526" y1="852" x2="526" y2="944" stroke="#334155" stroke-width="1.2"/>
<circle cx="124" cy="892" r="35" fill="none" stroke="#14c8b8" stroke-width="2"/>
<path d="M98 898 H111 L119 876 L132 914 L143 892 H153" stroke="#14c8b8" stroke-width="3" fill="none"/>
<text x="184" y="874" class="stage teal" style="font-size:26px">Top-Level Signals</text>
<text x="184" y="912" class="subtitle mono" style="font-size:22px">clk, rst, dbg_*</text>
<circle cx="606" cy="892" r="35" fill="none" stroke="#a879ff" stroke-width="2"/>
<text x="606" y="904" text-anchor="middle" class="icon violet" style="font-size:34px">DBG</text>
<text x="670" y="874" class="stage violet" style="font-size:26px">Debug &amp; Visibility</text>
<text x="670" y="912" class="subtitle" style="font-size:22px">Debug nets preserve retirement and exception visibility</text>
<text x="670" y="940" class="subtitle" style="font-size:22px">for ILA hookup.</text>
</svg>
"""
    (OUT / "architecture.svg").write_text(svg, encoding="utf-8")


def memory_map_svg() -> None:
    width, height = 1792, 878
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
<style>
  text {{ font-family: Inter, Segoe UI, Arial, sans-serif; fill:#070b24; }}
  .title {{ font-size:58px; font-weight:820; letter-spacing:0; }}
  .subtitle {{ font-size:25px; fill:#475569; }}
  .cardTitle {{ font-size:42px; font-weight:820; }}
  .label {{ font-size:25px; font-weight:760; }}
  .value {{ font-size:25px; fill:#334155; }}
  .caption {{ font-size:23px; fill:#475569; }}
  .blue {{ fill:#1155bf; }}
  .green {{ fill:#15803d; }}
  .mono {{ font-family: JetBrains Mono, SFMono-Regular, Consolas, monospace; }}
</style>
<defs>
  <linearGradient id="pageBg" x1="0" y1="0" x2="1" y2="1">
    <stop stop-color="#ffffff"/>
    <stop offset="1" stop-color="#f8fafc"/>
  </linearGradient>
  <linearGradient id="blueCardBg" x1="0" x2="1">
    <stop stop-color="#ffffff"/>
    <stop offset="1" stop-color="#f8fbff"/>
  </linearGradient>
  <linearGradient id="greenCardBg" x1="0" x2="1">
    <stop stop-color="#ffffff"/>
    <stop offset="1" stop-color="#f8fff9"/>
  </linearGradient>
  <linearGradient id="blueBar" x1="0" x2="1">
    <stop stop-color="#0f4db8"/>
    <stop offset="1" stop-color="#0b55d9"/>
  </linearGradient>
  <linearGradient id="greenBar" x1="0" x2="1">
    <stop stop-color="#0f7a31"/>
    <stop offset="1" stop-color="#11843a"/>
  </linearGradient>
  <filter id="shadow" x="-10%" y="-10%" width="120%" height="120%">
    <feDropShadow dx="0" dy="10" stdDeviation="16" flood-color="#0f172a" flood-opacity="0.10"/>
  </filter>
</defs>
<rect x="1" y="1" width="1790" height="876" rx="14" fill="url(#pageBg)" stroke="#e2e8f0" stroke-width="2"/>

<g transform="translate(58 42)" stroke="#070b24" stroke-width="5" fill="none">
  <rect x="12" y="10" width="58" height="58" rx="4"/>
  <rect x="26" y="24" width="30" height="30" rx="2"/>
  <path d="M4 20 h-14 M4 34 h-14 M4 48 h-14 M4 62 h-14"/>
  <path d="M78 20 h14 M78 34 h14 M78 48 h14 M78 62 h14"/>
  <path d="M22 2 v-14 M36 2 v-14 M50 2 v-14 M64 2 v-14"/>
  <path d="M22 78 v14 M36 78 v14 M50 78 v14 M64 78 v14"/>
</g>
<text x="164" y="84" class="title">Harvard memory map</text>
<text x="164" y="130" class="subtitle">IMEM and DMEM both start at 0x00000000 because they are separate physical BRAM buses.</text>

<g filter="url(#shadow)">
  <rect x="50" y="175" width="830" height="582" rx="16" fill="url(#blueCardBg)" stroke="#72a7ff" stroke-width="1.6"/>
  <rect x="50" y="175" width="830" height="114" rx="16" fill="#f8fbff" stroke="#d8e8ff" stroke-width="1"/>
  <rect x="80" y="200" width="66" height="66" rx="14" fill="#0b55d9"/>
  <text x="113" y="244" text-anchor="middle" style="font-size:38px;font-weight:850;fill:#fff">&lt;/&gt;</text>
  <text x="178" y="250" class="cardTitle blue">IMEM</text>

  <text x="152" y="357" class="label">Address range</text>
  <text x="503" y="357" class="value mono">0x0000_0000 - 0x0000_3FFF</text>
  <path d="M108 326 a16 16 0 1 0 0.1 0 M108 350 l-18 28 l-18 -28" fill="#0b55d9"/>
  <circle cx="108" cy="342" r="6" fill="#fff"/>

  <text x="152" y="429" class="label">Size</text>
  <text x="503" y="429" class="value">16 KiB instruction BRAM</text>
  <ellipse cx="108" cy="402" rx="17" ry="7" fill="#0b55d9"/><path d="M91 402 v30 c0 9 34 9 34 0 v-30" fill="#0b55d9" opacity="0.92"/><ellipse cx="108" cy="432" rx="17" ry="7" fill="#0b55d9"/>

  <text x="152" y="502" class="label">Init image</text>
  <text x="503" y="502" class="value">.text + rodata image via imem.hex</text>
  <path d="M94 471 h27 l13 13 v29 h-40 z" fill="#0b55d9"/><path d="M121 471 v13 h13" fill="#89b7ff"/><path d="M104 496 h18 M104 506 h11" stroke="#fff" stroke-width="3"/>

  <line x1="72" y1="555" x2="854" y2="555" stroke="#b9d4ff" stroke-width="1.5"/>
  <text x="80" y="603" class="label blue">Capacity</text>
  <rect x="80" y="622" width="766" height="54" rx="27" fill="url(#blueBar)"/>
  <text x="696" y="658" style="font-size:25px;font-weight:760;fill:#fff">4096 words</text>
  <text x="633" y="713" class="caption">32-bit words (4 bytes)</text>
</g>

<g filter="url(#shadow)">
  <rect x="912" y="175" width="834" height="582" rx="16" fill="url(#greenCardBg)" stroke="#7bc989" stroke-width="1.6"/>
  <rect x="912" y="175" width="834" height="114" rx="16" fill="#f8fff9" stroke="#d8f3dc" stroke-width="1"/>
  <rect x="942" y="200" width="66" height="66" rx="14" fill="#15803d"/>
  <ellipse cx="975" cy="220" rx="20" ry="8" fill="none" stroke="#fff" stroke-width="4"/><path d="M955 220 v34 c0 11 40 11 40 0 v-34" fill="none" stroke="#fff" stroke-width="4"/><path d="M955 237 c0 11 40 11 40 0 M955 254 c0 11 40 11 40 0" stroke="#fff" stroke-width="4" fill="none"/>
  <text x="1032" y="250" class="cardTitle green">DMEM</text>

  <text x="1013" y="357" class="label">Address range</text>
  <text x="1362" y="357" class="value mono">0x0000_0000 - 0x0000_1FFF</text>
  <path d="M969 326 a16 16 0 1 0 0.1 0 M969 350 l-18 28 l-18 -28" fill="#15803d"/>
  <circle cx="969" cy="342" r="6" fill="#fff"/>

  <text x="1013" y="429" class="label">Size</text>
  <text x="1362" y="429" class="value">8 KiB data BRAM</text>
  <ellipse cx="969" cy="402" rx="17" ry="7" fill="#15803d"/><path d="M952 402 v30 c0 9 34 9 34 0 v-30" fill="#15803d" opacity="0.92"/><ellipse cx="969" cy="432" rx="17" ry="7" fill="#15803d"/>

  <text x="1013" y="502" class="label">Stack top</text>
  <text x="1362" y="502" class="value mono">0x0000_2000</text>
  <path d="M969 474 v36 M956 488 l13 -14 l13 14 M954 510 h30" stroke="#15803d" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>

  <line x1="934" y1="555" x2="1718" y2="555" stroke="#bddfc5" stroke-width="1.5"/>
  <text x="942" y="603" class="label green">Capacity</text>
  <rect x="942" y="622" width="770" height="54" rx="27" fill="#d7eadb"/>
  <rect x="942" y="622" width="662" height="54" rx="27" fill="url(#greenBar)"/>
  <line x1="1604" y1="622" x2="1604" y2="676" stroke="#0f7a31" stroke-width="3" stroke-dasharray="5 5"/>
  <text x="1375" y="718" class="caption">Result block: 0x1FE0 - 0x1FFF</text>
</g>

<rect x="50" y="794" width="50" height="48" rx="5" fill="#0f172a"/>
<text x="75" y="829" text-anchor="middle" style="font-size:31px;font-weight:850;fill:#fff">&gt;_</text>
<text x="132" y="831" style="font-size:30px;font-weight:780">Runtime reports</text>
<text x="377" y="831" class="caption">|</text>
<text x="407" y="831" class="caption">Write MAGIC, cycles, instret, checksum, extras, and DONE at the top of DMEM.</text>
</svg>
"""
    (OUT / "memory_map.svg").write_text(svg, encoding="utf-8")


def verification_svg() -> None:
    groups = [
        ("Leaf units", 8, "#0f766e"),
        ("Pipeline regs/control", 8, "#2563eb"),
        ("ISA integration", 9, "#7c3aed"),
        ("Memory/cache", 4, "#d97706"),
        ("SoC software", 2, "#0891b2"),
        ("Formal target", 1, "#475569"),
    ]
    total = sum(count for _, count, _ in groups)
    circumference = 2 * math.pi * 132
    offset = 0.0
    arcs: list[str] = []
    legend: list[str] = []
    for index, (label, count, color) in enumerate(groups):
        dash = circumference * count / total
        gap = 5.0
        arcs.append(
            f'<circle cx="370" cy="414" r="132" fill="none" stroke="{color}" stroke-width="34" stroke-linecap="round" stroke-dasharray="{max(dash - gap, 1):.2f} {circumference:.2f}" stroke-dashoffset="{-offset:.2f}" transform="rotate(-90 370 414)"/>'
        )
        lx = 712 + (index % 2) * 372
        ly = 210 + (index // 2) * 132
        legend.append(
            f'<g><rect x="{lx}" y="{ly}" width="320" height="92" rx="16" fill="#fff" stroke="#e2e8f0"/><circle cx="{lx + 34}" cy="{ly + 46}" r="12" fill="{color}"/><text x="{lx + 62}" y="{ly + 40}" class="cardTitle">{label}</text><text x="{lx + 62}" y="{ly + 68}" class="muted">{count} make target{"s" if count != 1 else ""}</text></g>'
        )
        offset += dash

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="1360" height="720" viewBox="0 0 1360 720">
<style>
  text {{ font-family: Inter, Segoe UI, Arial, sans-serif; fill:#0f172a; }}
  .title {{ font-size:48px; font-weight:820; }}
  .subtitle {{ font-size:22px; fill:#52637a; }}
  .metric {{ font-size:58px; font-weight:820; }}
  .label {{ font-size:20px; font-weight:740; }}
  .muted {{ font-size:18px; fill:#64748b; }}
  .cardTitle {{ font-size:20px; font-weight:760; }}
</style>
<defs>
  <linearGradient id="verifyBg" x1="0" y1="0" x2="1" y2="1">
    <stop stop-color="#ffffff"/>
    <stop offset="1" stop-color="#f8fafc"/>
  </linearGradient>
  <filter id="softShadow" x="-10%" y="-10%" width="120%" height="120%">
    <feDropShadow dx="0" dy="12" stdDeviation="18" flood-color="#0f172a" flood-opacity="0.10"/>
  </filter>
</defs>
<rect x="1" y="1" width="1358" height="718" rx="24" fill="url(#verifyBg)" stroke="#e2e8f0"/>
<text x="54" y="72" class="title">Verification surface</text>
<text x="54" y="112" class="subtitle">Makefile-exposed checks grouped by what they stress, from leaf RTL to full-SoC programs.</text>

<g filter="url(#softShadow)">
  <rect x="54" y="156" width="604" height="498" rx="24" fill="#ffffff" stroke="#e2e8f0"/>
  <circle cx="370" cy="414" r="132" fill="none" stroke="#e2e8f0" stroke-width="34"/>
  {"".join(arcs)}
  <text x="370" y="398" text-anchor="middle" class="metric">{total}</text>
  <text x="370" y="430" text-anchor="middle" class="label">documented</text>
  <text x="370" y="456" text-anchor="middle" class="label">targets</text>
  <text x="88" y="606" class="muted">Representative target groups. `make help` remains the authoritative command index.</text>
</g>

<g filter="url(#softShadow)">
  {"".join(legend)}
</g>

<g>
  <rect x="712" y="606" width="692" height="48" rx="12" fill="#f1f5f9"/>
  <text x="740" y="637" class="label">Full-SoC software targets require built IMEM images from `make sw-all`.</text>
</g>
</svg>
"""
    (OUT / "verification_surface.svg").write_text(svg, encoding="utf-8")


def resource_plot() -> None:
    soc = parse_utilization("reports/implementation/fluxcore_soc_utilization_route.rpt")
    cache = parse_utilization("reports/synthesis/direct_mapped_cache_utilization_synth.rpt")
    labels = ["Slice LUTs", "Slice Registers", "Block RAM", "DSPs"]
    soc_pct = [soc[label][2] for label in labels]
    cache_pct = [cache[label][2] for label in labels]
    x = range(len(labels))
    plt.figure(figsize=(10, 4.8), dpi=160)
    ax = plt.gca()
    ax.set_facecolor(PAPER)
    plt.gcf().patch.set_facecolor(PAPER)
    ax.bar([i - 0.18 for i in x], soc_pct, width=0.34, color=TEAL, label="fluxcore_soc routed")
    ax.bar([i + 0.18 for i in x], cache_pct, width=0.34, color=SLATE, label="direct_mapped_cache synth")
    ax.set_xticks(list(x), labels)
    ax.set_ylabel("Device utilization (%)")
    ax.set_ylim(0, max(soc_pct + cache_pct) + 2.0)
    ax.grid(axis="y", color="#dbe3ec", linewidth=1)
    ax.spines[:].set_visible(False)
    ax.legend(frameon=False, loc="upper right")
    ax.set_title("Zybo Z7-20 resource footprint", loc="left", fontweight="bold", color=INK)
    for i, pct in enumerate(soc_pct):
        ax.text(i - 0.18, pct + 0.16, f"{pct:.2f}%", ha="center", va="bottom", fontsize=8, color=INK)
    for i, pct in enumerate(cache_pct):
        ax.text(i + 0.18, pct + 0.16, f"{pct:.2f}%", ha="center", va="bottom", fontsize=8, color=INK)
    plt.tight_layout(pad=1.5)
    plt.savefig(OUT / "resource_utilization.svg", format="svg")
    plt.close()


def timing_plot() -> None:
    soc_wns = parse_wns("reports/implementation/fluxcore_soc_timing_summary_route.rpt")
    cache_wns = parse_wns("reports/synthesis/direct_mapped_cache_timing_summary_synth.rpt")
    labels = ["fluxcore_soc routed", "direct_mapped_cache synth"]
    vals = [soc_wns, cache_wns]
    plt.figure(figsize=(10, 3.8), dpi=160)
    ax = plt.gca()
    ax.set_facecolor(PAPER)
    plt.gcf().patch.set_facecolor(PAPER)
    colors = [TEAL, SLATE]
    ax.barh(labels, vals, color=colors, height=0.42)
    ax.axvline(0, color="#0f172a", linewidth=1)
    ax.set_xlabel("Worst negative slack at 50 MHz (ns)")
    ax.set_xlim(0, max(vals) + 2)
    ax.grid(axis="x", color="#dbe3ec", linewidth=1)
    ax.spines[:].set_visible(False)
    ax.set_title("Timing closure margin", loc="left", fontweight="bold", color=INK)
    for y, value in enumerate(vals):
        ax.text(value + 0.2, y, f"WNS {value:.3f} ns", va="center", fontsize=10, color=INK)
    plt.tight_layout(pad=1.5)
    plt.savefig(OUT / "timing_margin.svg", format="svg")
    plt.close()


def pipeline_gif() -> None:
    width, height = 980, 310
    frames = []
    stages = ["IF", "ID", "EX", "MEM", "WB"]
    subs = ["fetch", "decode", "execute", "memory", "retire"]
    try:
        font_title = ImageFont.truetype("DejaVuSans-Bold.ttf", 28)
        font_label = ImageFont.truetype("DejaVuSans-Bold.ttf", 24)
        font_small = ImageFont.truetype("DejaVuSans.ttf", 15)
    except OSError:
        font_title = font_label = font_small = ImageFont.load_default()
    for active in range(len(stages) + 2):
        img = Image.new("RGB", (width, height), PAPER)
        d = ImageDraw.Draw(img)
        d.text((38, 30), "Five-stage instruction flow", fill=INK, font=font_title)
        d.text((38, 66), "A single instruction moves left-to-right while older/newer instructions occupy adjacent stages.", fill=MUTED, font=font_small)
        x0, y0, w, h, gap = 56, 130, 142, 82, 46
        for i, (stage, sub) in enumerate(zip(stages, subs, strict=True)):
            x = x0 + i * (w + gap)
            is_active = i == active
            fill = "#ccfbf1" if is_active else PANEL
            outline = TEAL if is_active else LINE
            d.rounded_rectangle([x, y0, x + w, y0 + h], radius=16, fill=fill, outline=outline, width=3 if is_active else 2)
            d.text((x + w / 2, y0 + 26), stage, fill=INK, font=font_label, anchor="mm")
            d.text((x + w / 2, y0 + 56), sub, fill=MUTED, font=font_small, anchor="mm")
            if i < len(stages) - 1:
                ax = x + w + 10
                ay = y0 + h // 2
                d.line([ax, ay, ax + gap - 20, ay], fill=TEAL, width=3)
                d.polygon([(ax + gap - 20, ay - 6), (ax + gap - 20, ay + 6), (ax + gap - 8, ay)], fill=TEAL)
        d.text((56, 266), "Default memory path: BRAM. Optional D-cache can stall the same pipeline interface on a read miss.", fill=MUTED, font=font_small)
        frames.append(img)
    frames[0].save(
        OUT / "pipeline_flow.gif",
        save_all=True,
        append_images=frames[1:],
        duration=650,
        loop=0,
        optimize=True,
    )


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    architecture_svg()
    memory_map_svg()
    verification_svg()
    resource_plot()
    timing_plot()
    pipeline_gif()
    print(f"Generated README assets in {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
