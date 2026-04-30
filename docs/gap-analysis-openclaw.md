# Gap Analysis: OpenClaw vs PureClaw

## Missing Functionality Categories

These are major categories of functionality where PureClaw has zero implementation,
not just missing integrations within an existing category. Items like "more channels"
or "more providers" are excluded since PureClaw already has the abstractions and
adding instances is mechanical.

### 1. Browser Automation

OpenClaw has a full browser tool — tab management, page snapshots, click/type/drag
via snapshot refs, form filling, screenshots, PDF export, cookie/storage
manipulation, file upload/download, and three profile modes (managed,
attach-to-existing-Chrome, remote CDP). PureClaw has nothing in this space. The
`HttpRequest` tool does bare GET requests, but there's no browser control, no DOM
interaction, no screenshots.

### 2. Voice / Speech I/O

OpenClaw supports bidirectional voice: wake-word detection (macOS/iOS), continuous
talk mode (Android), Whisper STT for transcription, and ElevenLabs TTS for speech
synthesis. PureClaw is text-only — no speech input, no speech output, no audio
processing of any kind.

### 3. Companion Devices / Nodes

OpenClaw has a node system where phones, tablets, and remote machines connect to the
gateway over WebSocket and expose device-specific capabilities — camera, screen
capture, canvas (render web content on device), and device commands. PureClaw's
gateway is pairing/OAuth-only with no concept of remote device nodes or their
capability surfaces.

### 4. MCP (Model Context Protocol) Server

OpenClaw exposes its tools via MCP, making it model-agnostic — any MCP-compatible
client can drive OpenClaw's capabilities. PureClaw has its own tool registry but
doesn't speak MCP, so it can't interoperate with the broader MCP ecosystem (and
can't consume external MCP tool servers either).

### 5. Sandboxed Execution / Containerization

OpenClaw sandboxes tool execution in Docker containers (with SSH and OpenShell
alternatives). Group chats and non-primary sessions get isolated sandboxes by
default. PureClaw relies on `SecurityPolicy` allow-lists and `SafePath` validation,
but has no container isolation — all tool execution happens directly on the host.

### 6. Skill Registry / Marketplace

OpenClaw has ClawHub with 13,000+ community skills that can be installed and
composed. Skills are self-describing (`SKILL.md`) and can be bundled, installed
globally, or scoped to a workspace. PureClaw has agent definitions and a rudimentary
bootstrap system, but no skill marketplace, no skill installation from a registry,
and no community sharing mechanism.

### 7. Webhook / Event-Driven Triggers

OpenClaw supports inbound webhooks and Gmail Pub/Sub as automation triggers —
external events can wake the agent and start workflows without a human message.
PureClaw has cron for time-based triggers but no webhook ingestion or
event-subscription system.

### 8. Multi-Agent Routing (Channel -> Agent)

OpenClaw routes different channels, contacts, or groups to isolated agent instances,
each with their own workspace, sessions, and permissions. PureClaw runs a single
agent per process. The `/agent` commands switch the active agent definition, but
there's no routing layer that maps inbound senders/channels to different agents
automatically.

### 9. Canvas / Visual Workspace

OpenClaw's Canvas lets the agent render arbitrary web content, dashboards, or
interactive UIs on companion devices, then snapshot or evaluate JS against them.
PureClaw has no equivalent — it can't present visual output beyond text in the
channel.

### 10. Image / Vision Input

OpenClaw's providers accept image content blocks and the browser/node systems can
feed screenshots into the model. PureClaw's `ContentBlock` type includes `CBImage`
but there's no tool or channel path that actually produces images for the model to
see (no screenshot tool, no camera integration, no image upload handling).
