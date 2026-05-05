# PureClaw Design Specification

## Overview

PureClaw is an AI agent orchestration platform. The UI is dark-first, inspired by Linear, Raycast, and Railway — confident spacing, restrained color, fast-feeling interfaces.

**Typography:** Geist Sans, tight letter-spacing (-0.01em to -0.02em)
**Color palette:** Purple-Blue gradient on dark backgrounds
**Reference mockup:** `mockup.html` (open directly in a browser)

## Design Tokens

All tokens are defined in `design-tokens.css`. Import it as a single source of truth for colors, spacing, typography, and animation values.

### Color: Backgrounds (3-layer depth model)

| Token | Value | Usage |
|-------|-------|-------|
| `--bg-base` | `#0F1117` | App canvas, deepest layer |
| `--bg-sunken` | `#0B0D13` | Recessed areas: text inputs, code blocks |
| `--bg-surface` | `#161922` | Sidebar, panels |
| `--bg-elevated` | `#1E2235` | Pills, tooltips, hover cards |

Each layer differs by ~4-8% lightness. Depth comes from background tints and subtle borders, never drop shadows.

### Color: Accents

| Token | Value | Usage |
|-------|-------|-------|
| `--accent-primary` | `#7C6CF6` | Purple — primary actions, active states, selected borders |
| `--accent-secondary` | `#4F8EF7` | Blue — code highlights, secondary accents |
| `--needs-input` | `#FF6B6B` | Red — attention states requiring user action |
| `--success` | `#34D399` | Green — completed states |
| `--warning` | `#FBBF24` | Yellow — caution states |

### Color: Text

| Token | Value | Usage |
|-------|-------|-------|
| `--text-primary` | `#E8E9F0` | Headings, body text |
| `--text-muted` | `#6B7094` | Secondary text, labels |
| `--text-faint` | `rgba(107,112,148,0.5)` | Timestamps, tertiary info |

Text hierarchy is through opacity/lightness, not hue variation. The muted color has a blue-purple tint matching the accent palette.

## UI Layout

```
┌─────────────────────────────────────────────────────┐
│ Top Bar (52px): logo, task title, pause/stop, ver   │
├──────────┬──────────────────────────────────────────┤
│ Sidebar  │ Chat Area                                │
│ (240px)  │ ┌─ Chat Header ──────────────────────┐   │
│          │ │ dot · Agent · task · model · tokens │   │
│ dot Name │ ├────────────────────────────────────┤   │
│ dot Name │ │                                    │   │
│ dot Name │ │ Agent transcript (max-width 720px) │   │
│ dot Name │ │                                    │   │
│ dot Name │ │ Name    00:00:34                   │   │
│ dot Name │ │ Message body, code blocks, lists   │   │
│ dot Name │ │                                    │   │
│          │ ├────────────────────────────────────┤   │
│          │ │ [Input area]            [Send ⌘↵]  │   │
├──────────┴──────────────────────────────────────────┤
│ Bottom Bar (36px): tokens, budget, time, agents     │
└─────────────────────────────────────────────────────┘
```

### Sidebar (240px)

Flat agent list, no section headers. Sorted by status: needs-input → thinking → idle → completed. Status is communicated entirely through dot animation + color:

- **Needs input:** pulsing red dot, red description text
- **Thinking:** gradient-cycling purple-blue dot, shimmer on row background, muted description
- **Idle:** dim muted dot, muted name
- **Completed:** dim green dot (opacity 0.5), muted name (opacity 0.7), no description

**Density targets:**
- ~28px per completed row (dot + name + token count)
- ~40px per active row (adds description line)
- 15–20 agents visible without scrolling

Selected agent: left border accent-primary + bg-elevated background.

### Chat Area

Minimal transcript format. Each message:
```
AgentName  00:00:34      ← colored by agent status, 12px semibold
Message body text here    ← 14px regular, line-height 1.6
```

No avatars, no status pills on messages, no card wrappers. Agent names colored per status (accent-primary for completed agents, accent-secondary for thinking, needs-input red for waiting).

Code blocks use `--bg-sunken` background with `--border` border, syntax colors from accent palette.

Chat content max-width: 720px, centered in the available space.

### Bottom Bar (36px)

Single persistent status strip. Contains: token usage (with progress bar), budget (with progress bar), elapsed time, agent count summary. This is the **single source of truth** for aggregate stats — no other UI element should duplicate this information.

## Visual Design Principles

From [visualmess.com](https://www.visualmess.com/). Apply these to every design decision.

### 1. Size — identical function → identical appearance
Elements with the same logical role must look visually identical. Same padding, weight, shape. Only vary color per status. Slight unintentional differences force the brain to determine if they're meaningful.

### 2. Proximity — group through whitespace, not decoration
Closely-placed items form visual groups. The gap between groups must be unambiguously larger than the gap within groups. If spacing makes grouping clear, don't add borders or dividers.

### 3. Alignment — every element on an intentional edge
Left-align by default. Slight misalignments look messy. Center alignment is almost always weaker. Break alignment only intentionally.

### 4. Elimination — remove what other principles already communicate
If size, proximity, and alignment convey the structure, extra visual elements (borders, icons, labels) are noise. The fix for a crowded design is better use of the first three principles, not more decoration.

## Density & Redundancy Rules

### Implicit grouping via sort order + color
Don't use section headers when sort order and dot animations already communicate state. The pulsing red dot *is* "needs input."

### Description lines only when they carry unique info
Active agents (needs-input, thinking) get descriptions — they tell you what changed. Completed/idle agents don't — the dot says enough.

### Single source of truth
Every data point appears in exactly one location. If you're about to show the same fact twice, delete one instance.

### Earned screen space
Every persistent UI element must justify its pixel cost. If it duplicates information visible elsewhere, remove it.

## Animation Reference

| Animation | Used for | Duration | Easing |
|-----------|----------|----------|--------|
| `needsPulse` | Needs-input dot glow | 1.5s | ease-in-out |
| `thinkingGradient` | Thinking dot color cycle | 2s | ease |
| `shimmer` | Thinking row background | 2.5s | linear |
| `fadeIn` | New message entrance | 300ms | cubic-bezier(0.16, 1, 0.3, 1) |
| `typingDot` | Active generation indicator | 1.4s | ease-in-out, staggered 0.2s |
| `blink` | Cursor in input | 1s | step-end |

All interactive element transitions: 150ms background/color, `cubic-bezier(0.16, 1, 0.3, 1)`.

## Assets

- `assets/logo.svg` — PureClaw claw logo, no border (used in top bar at 28x28)
- `assets/logo-bordered.svg` — Same logo with hexagonal border

## Font Dependencies

- [Geist Sans](https://cdn.jsdelivr.net/npm/geist@1.3.1/dist/fonts/geist-sans/style.css) — primary typeface
- [Geist Mono](https://vercel.com/font) — code blocks (with SF Mono, Fira Code fallbacks)
